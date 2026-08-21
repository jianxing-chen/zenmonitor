//
//  ZhipuModels.swift
//  zenmux-monitor
//
//  智谱 GLM Coding Plan 配额数据模型与解析器
//  对应 GET https://open.bigmodel.cn/api/monitor/usage/quota/limit 响应。
//
//  注意：该端点为控制台内部监控接口（未收录于官方文档），字段命名参照
//  已验证的开源实现（cc-switch / glm-usage）并做防御式兼容；
//  结构漂移时解析返回空，由服务层展示错误而不是渲染假数据。
//

import Foundation

// MARK: - 窗口类型

/// GLM Coding Plan 配额窗口类别
enum ZhipuWindowKind {
    case session    // 5 小时滚动频控窗口
    case weekly     // 每周限额
}

/// 归一化后的配额窗口（纯值类型，解析逻辑见 ZhipuUsageParser）
struct ZhipuQuotaWindow {
    /// 窗口类别
    let kind: ZhipuWindowKind
    /// 已用百分比 0~100（超额时饱和到 100）
    let usedPercent: Double
    /// 重置时间（可选）
    let resetsAt: Date?
}

// MARK: - 解析器

/// `GET /api/monitor/usage/quota/limit` 防御式解析器。
///
/// 响应形态（cc-switch / glm-usage 实测，bigmodel.cn 与 z.ai 共用后端）：
/// ```
/// { "success": true, "data": { "level": "Pro", "limits": [
///     { "type": "TOKENS_LIMIT", "unit": 3, "percentage": 31.0, "nextResetTime": <epoch ms> },  // 5 小时窗口
///     { "type": "TOKENS_LIMIT", "unit": 6, "percentage": 6.0,  "nextResetTime": <epoch ms> },  // 每周窗口
///     { "type": "TIME_LIMIT",   ... }   // MCP 月度窗口（本应用暂不展示，跳过）
/// ] } }
/// ```
///
/// 窗口分类必须锚定 `unit` 字段（3=5h / 6=周）：周期末尾每周窗口会比
/// 5 小时窗口更早重置，按重置时间排序会把两桶标反（cc-switch issue #3036）。
/// `unit` 缺失时走兜底启发式：无重置时间的条目优先归 5h（0% 状态可能无 reset），
/// 其余按重置时间升序依次填入仍空缺的槽位。
///
/// 2026-02-12 起该端点只返回百分比、不再返回 Token 绝对值（官方为多模型
/// 差异化扣费做的调整），因此窗口仅承载百分比与重置时间。
enum ZhipuUsageParser {

    /// 解析响应体，返回按 session → weekly 排序的窗口列表；无法解析返回空
    static func parse(body: [String: Any]) -> [ZhipuQuotaWindow] {
        // 业务级失败：上游明确报错时不渲染假数据
        if let success = body["success"] as? Bool, !success { return [] }

        // 防御 data 信封
        let data = (body["data"] as? [String: Any]) ?? body
        guard let limits = pickArray(data, keys: ["limits", "limitInfos", "limit_infos", "windows"]) else {
            return []
        }

        // 槽位先存（百分比, 重置时间），窗口对象在槽位确定后按正确 kind 构造
        var fiveHour: (pct: Double, reset: Date?)?
        var weekly: (pct: Double, reset: Date?)?
        var unclassified: [(pct: Double, reset: Date?)] = []

        for entry in limits {
            // 只收配额条目；TIME_LIMIT（MCP 月度）等其他类型跳过（大小写不敏感）
            let type = pickString(entry, keys: ["type", "limitType", "limit_type"]).lowercased()
            if !type.isEmpty && type != "tokens_limit" && type != "credit_limit" {
                continue
            }
            guard let pct = usedPercent(from: entry) else { continue }
            let reset = parseDate(pickRaw(entry, keys: resetKeys))
            switch classify(entry) {
            case .session where fiveHour == nil:
                fiveHour = (pct, reset)
            case .weekly where weekly == nil:
                weekly = (pct, reset)
            default:
                unclassified.append((pct, reset))
            }
        }

        // 兜底启发式：无重置时间的优先归 5h，其余按重置升序填空槽
        unclassified.sort { lhs, rhs in
            switch (lhs.reset, rhs.reset) {
            case (nil, _?):      return true
            case (_?, nil):      return false
            case let (l?, r?):   return l < r
            case (nil, nil):     return false
            }
        }
        for slot in unclassified {
            if fiveHour == nil { fiveHour = slot }
            else if weekly == nil { weekly = slot }
            // 智谱当前最多两条 TOKENS_LIMIT，多余的忽略
        }

        // session 在前（与状态栏 windows[0]=5h 的约定一致）
        var windows: [ZhipuQuotaWindow] = []
        if let slot = fiveHour {
            windows.append(ZhipuQuotaWindow(kind: .session, usedPercent: slot.pct, resetsAt: slot.reset))
        }
        if let slot = weekly {
            windows.append(ZhipuQuotaWindow(kind: .weekly, usedPercent: slot.pct, resetsAt: slot.reset))
        }
        return windows
    }

    // MARK: - 窗口分类

    /// unit 字段显式分类：3=5 小时窗口，6=每周窗口（两种 number 取值都实测过，
    /// 故只锚定 unit 不绑 number）；缺失或不认识时返回 nil 由启发式兜底
    private static func classify(_ entry: [String: Any]) -> ZhipuWindowKind? {
        guard let unit = pickNumber(entry, keys: ["unit", "windowUnit", "window_unit"]) else {
            return nil
        }
        switch Int(unit) {
        case 3: return .session
        case 6: return .weekly
        default: return nil
        }
    }

    // MARK: - 百分比

    /// 已用百分比：优先百分比字段；端点若恢复返回 used/limit 绝对值也兼容推导
    private static func usedPercent(from entry: [String: Any]) -> Double? {
        if let percent = pickNumber(entry, keys: [
            "percentage", "percent", "usedPercent", "used_percent",
            "usagePercentage", "usage_percentage", "utilization"
        ]) {
            return clamp(percent)
        }
        let used = pickNumber(entry, keys: ["used", "usedValue", "used_value"])
        let limit = pickNumber(entry, keys: ["limit", "limitValue", "limit_value", "total", "max"])
        if let used, let limit, limit > 0 {
            return clamp(used / limit * 100)
        }
        return nil
    }

    private static func clamp(_ percent: Double) -> Double {
        min(max(percent, 0), 100)
    }

    // MARK: - 通用取值

    private static let resetKeys = [
        "nextResetTime", "next_reset_time", "resetTime", "reset_time", "resetAt", "reset_at"
    ]

    private static func pickArray(_ obj: [String: Any], keys: [String]) -> [[String: Any]]? {
        for key in keys {
            if let items = obj[key] as? [[String: Any]] { return items }
        }
        return nil
    }

    /// 按键名顺序取第一个数值（兼容字符串数字）
    private static func pickNumber(_ obj: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = obj[key] {
                if let number = value as? Double { return number }
                if let number = value as? Int { return Double(number) }
                if let text = value as? String, let number = Double(text.trimmingCharacters(in: .whitespaces)) {
                    return number
                }
            }
        }
        return nil
    }

    private static func pickString(_ obj: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let text = obj[key] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text
            }
        }
        return ""
    }

    private static func pickRaw(_ obj: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = obj[key] { return value }
        }
        return nil
    }

    /// 时间值兼容：ISO8601 字符串 / epoch 秒 / epoch 毫秒
    private static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? Double {
            return Date(timeIntervalSince1970: number < 20_000_000_000 ? number : number / 1000)
        }
        if let number = value as? Int {
            let ts = Double(number)
            return Date(timeIntervalSince1970: ts < 20_000_000_000 ? ts : ts / 1000)
        }
        if let text = value as? String {
            if let epoch = Double(text) {
                return Date(timeIntervalSince1970: epoch < 20_000_000_000 ? epoch : epoch / 1000)
            }
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: text) { return date }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.date(from: text)
        }
        return nil
    }
}

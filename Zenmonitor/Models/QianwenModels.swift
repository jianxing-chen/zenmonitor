//
//  QianwenModels.swift
//  zenmux-monitor
//
//  千问 AI Token Plan 用量数据模型与解析器
//  对应控制台网关响应：
//  POST https://cs-data.qianwenai.com/cli/api.json
//       ?action=BroadScopeAspnGateway&product=sfm_bailian
//       &api=zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage
//
//  说明：该端点未收录于公开文档，但由官方 CLI（@qianwenai/qianwen-cli 与
//  modelstudioai/cli 的 bl usage token-plan）使用，2026-11-13 已全链路实测
//  （阿里云 AK/SK 换 token + 一次性业务空间授权）。
//
//  窗口字段为通用模式 per{N}{Hour|Day|Week|Month}{Percentage|ResetTime}：
//  个人版实测仅返回月度窗口（per1Month*），其他档位可能有 5H/周窗口。
//  Percentage 为 0~1 小数（0.4887 = 已用 48.87%）；ResetTime 为毫秒时间戳。
//

import Foundation

/// 归一化后的配额窗口（纯值类型，解析逻辑见 QianwenUsageParser）
struct QianwenQuotaWindow {
    /// 窗口标识（如 "5h" / "7d" / "1m"），用于状态栏主窗口选择
    let id: String
    /// 展示标签（如 "5H" / "7D" / "1M"）
    let label: String
    /// SF Symbol 图标名
    let icon: String
    /// 已用百分比 0~100（已归一化并 clamp）
    let usedPercent: Double
    /// 重置时间（可选）
    let resetsAt: Date?
    /// 固定窗口时长；月度窗口为 nil（由服务层按重置时间倒推自然月）
    let fixedDuration: TimeInterval?
    /// 展示排序：短窗口在前（状态栏 windows[0] 约定）
    let sortRank: Int
}

// MARK: - 解析器

/// 控制台网关用量响应防御式解析器。
///
/// 信封层数可能随站点/版本变化（实测 data.DataV2.data.data），
/// 因此用递归收集所有 per* 叶子字段，不依赖固定路径。
/// 无法解析时返回空，由服务层展示错误而不是渲染假数据。
enum QianwenUsageParser {

    /// 解析响应体，返回按窗口时长从短到长排序的列表；无可用窗口返回空
    static func parse(body: [String: Any]) -> [QianwenQuotaWindow] {
        var fields: [String: Double] = [:]
        collectFields(body, into: &fields)

        // 按前缀分组：per1Month → (Percentage, ResetTime)
        var groups: [String: (pct: Double?, reset: Double?)] = [:]
        for (key, value) in fields {
            guard let parts = splitKey(key) else { continue }
            var group = groups[parts.prefix] ?? (nil, nil)
            if parts.isPercent {
                group.pct = value
            } else {
                group.reset = value
            }
            groups[parts.prefix] = group
        }

        var windows: [QianwenQuotaWindow] = []
        for (prefix, group) in groups {
            // 无百分比不构造窗口（不伪造 0%）
            guard let rawPct = group.pct else { continue }
            let meta = windowMeta(prefix)
            windows.append(QianwenQuotaWindow(
                id: meta.id,
                label: meta.label,
                icon: meta.icon,
                usedPercent: normalizePercent(rawPct),
                resetsAt: group.reset.flatMap(date),
                fixedDuration: meta.duration,
                sortRank: meta.rank
            ))
        }
        return windows.sorted {
            ($0.sortRank, $0.id) < ($1.sortRank, $1.id)
        }
    }

    // MARK: - 字段收集

    /// 递归收集 per* 数值叶子字段（兼容任意信封深度）
    private static func collectFields(_ obj: Any, into fields: inout [String: Double]) {
        if let dict = obj as? [String: Any] {
            for (key, value) in dict {
                if key.hasPrefix("per"), let num = number(value) {
                    fields[key] = num
                } else {
                    collectFields(value, into: &fields)
                }
            }
        } else if let array = obj as? [Any] {
            for item in array { collectFields(item, into: &fields) }
        }
    }

    /// 拆解 per{N}{Unit}{Percentage|ResetTime} 键名
    private static func splitKey(_ key: String) -> (prefix: String, isPercent: Bool)? {
        guard key.hasPrefix("per") else { return nil }
        let isPercent: Bool
        let core: String
        if key.hasSuffix("Percentage") {
            isPercent = true
            core = String(key.dropFirst(3).dropLast(10))
        } else if key.hasSuffix("ResetTime") {
            isPercent = false
            core = String(key.dropFirst(3).dropLast(9))
        } else {
            return nil
        }
        let digits = core.prefix { $0.isNumber }
        let unit = String(core.dropFirst(digits.count))
        guard !digits.isEmpty, ["Hour", "Day", "Week", "Month"].contains(unit) else { return nil }
        return ("per" + digits + unit, isPercent)
    }

    // MARK: - 归一化

    /// 百分比归一化：实测为 0~1 小数（0.4887 = 48.87%）；
    /// 防御性兼容 0~100 形态（>1 时视为已是百分比）
    private static func normalizePercent(_ value: Double) -> Double {
        let pct = value <= 1 ? value * 100 : value
        return min(max(pct, 0), 100)
    }

    /// 窗口元信息：标识 / 标签 / 图标 / 固定时长 / 排序
    private static func windowMeta(_ prefix: String)
        -> (id: String, label: String, icon: String, duration: TimeInterval?, rank: Int) {
        let core = String(prefix.dropFirst(3))
        let digits = core.prefix { $0.isNumber }
        let n = Int(digits) ?? 1
        let unit = String(core.dropFirst(digits.count))
        switch unit {
        case "Hour":
            return ("\(n)h", "\(n)H", "clock", TimeInterval(n) * 3600, 0)
        case "Day":
            return ("\(n)d", "\(n)D", "calendar", TimeInterval(n) * 24 * 3600, 1)
        case "Week":
            let id = n == 1 ? "7d" : "\(n)w"
            let label = n == 1 ? "7D" : "\(n)W"
            return (id, label, "calendar", TimeInterval(n) * 7 * 24 * 3600, 2)
        default: // Month：时长由服务层按重置时间倒推自然月
            return ("\(n)m", "\(n)M", "calendar", nil, 3)
        }
    }

    // MARK: - 通用取值

    /// 数值兼容：Int / Double / 字符串数字
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: return v.isFinite ? v : nil
        case let v as Int:    return Double(v)
        case let v as String: return Double(v.trimmingCharacters(in: .whitespaces))
        default:              return nil
        }
    }

    /// 时间值兼容：epoch 毫秒 / epoch 秒（字段名统一为 *ResetTime，实测毫秒）
    private static func date(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 20_000_000_000 ? value / 1000 : value)
    }
}

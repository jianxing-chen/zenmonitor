//
//  KimiModels.swift
//  zenmux-monitor
//
//  Kimi Code 配额数据模型与解析器
//  对应 GET https://api.kimi.com/coding/v1/usages 响应。
//
//  注意：该端点无公开文档，字段命名参照已验证的开源实现
//  （token-monitor）并做多拼写兼容；结构漂移时解析返回空，
//  由服务层展示错误而不是渲染假数据。
//

import Foundation

// MARK: - 窗口类型

/// Kimi Code 配额窗口类别
enum KimiWindowKind {
    case session    // 5 小时滚动频控窗口
    case weekly     // 7 天周额度
}

/// 归一化后的配额窗口（纯值类型，解析逻辑见 KimiUsageParser）
struct KimiQuotaWindow {
    /// 窗口类别
    let kind: KimiWindowKind
    /// 已用百分比 0~100（超额时饱和到 100）
    let usedPercent: Double
    /// 重置时间（可选）
    let resetsAt: Date?
    /// 窗口时长（秒，可选；缺失时由服务层按类别取默认值）
    let windowDuration: TimeInterval?
    /// 已用绝对值（可选，端点可能不返回）
    let used: Double?
    /// 上限绝对值（可选，端点可能不返回）
    let limit: Double?
}

// MARK: - 解析器

/// `GET /coding/v1/usages` 防御式解析器。
///
/// 响应形态（参照 token-monitor 实测）：
/// - 顶层 `usage`：FEATURE_CODING 周额度（used/limit/resetAt）
/// - `limits[]`：频控窗口数组，5 小时窗口报告为
///   `window.duration=300, timeUnit="TIME_UNIT_MINUTE"`
/// - 部分兼容代理会把整体包在 `data` 信封里
///
/// 所有字段名做 camelCase / snake_case / *Value 多拼写兼容。
enum KimiUsageParser {

    /// 解析响应体，返回按 session → weekly 排序的窗口列表；无法解析返回空
    static func parse(body: [String: Any]) -> [KimiQuotaWindow] {
        // 防御 data 信封
        let data = (body["data"] as? [String: Any]) ?? body

        var windows: [KimiQuotaWindow] = []
        var seenKinds = Set<KimiWindowKind>()

        // 顶层 usage = 权威周额度（控制台展示的数字），优先入列
        if let usage = data["usage"] as? [String: Any],
           let pct = usedPercent(from: usage) {
            let kind = classifyByName(pickString(usage, keys: nameKeys))
            let limit = pickNumber(usage, keys: limitKeys)
            windows.append(KimiQuotaWindow(
                kind: kind,
                usedPercent: pct,
                resetsAt: parseDate(pickRaw(usage, keys: resetKeys)),
                windowDuration: kind == .weekly ? 7 * 24 * 3600 : nil,
                used: usedValue(in: usage, limit: limit),
                limit: limit
            ))
            seenKinds.insert(kind)
        }

        // limits[] 补充：按时长分类，只补缺失的类别
        for entry in limitEntries(in: data) {
            guard let pct = entry.percent else { continue }
            let kind = classifyByMinutes(entry.windowMinutes)
            guard !seenKinds.contains(kind) else { continue }
            seenKinds.insert(kind)
            windows.append(KimiQuotaWindow(
                kind: kind,
                usedPercent: pct,
                resetsAt: entry.resetsAt,
                windowDuration: entry.windowMinutes.map { $0 * 60 },
                used: entry.used,
                limit: entry.limit
            ))
        }

        // session 在前（与状态栏 windows[0]=5h 的约定一致）
        return windows.sorted { kindRank($0.kind) < kindRank($1.kind) }
    }

    // MARK: - limits[] 解析

    private struct LimitEntry {
        let percent: Double?
        let used: Double?
        let limit: Double?
        let resetsAt: Date?
        let windowMinutes: Double?
    }

    private static func limitEntries(in data: [String: Any]) -> [LimitEntry] {
        let arrayKeys = ["limits", "limitInfos", "limit_infos", "rateLimits", "rate_limits", "windows"]
        var array: [[String: Any]] = []
        for key in arrayKeys {
            if let items = data[key] as? [[String: Any]] { array = items; break }
        }
        return array.map { entry in
            let detail = firstObject(in: entry, keys: ["detail", "usage", "quota"]) ?? entry
            let window = firstObject(in: entry, keys: ["window", "period", "rateLimit", "rate_limit", "timeWindow", "time_window"])
            let duration = window.flatMap { pickNumber($0, keys: ["duration", "windowDuration", "window_duration", "size", "length"]) }
            let unit = window.flatMap { pickString($0, keys: ["timeUnit", "time_unit", "unit", "windowUnit", "window_unit"]) }
            let resetRaw = pickRaw(detail, keys: resetKeys) ?? window.flatMap { pickRaw($0, keys: resetKeys) }
            return LimitEntry(
                percent: usedPercent(from: detail),
                used: usedValue(in: detail, limit: pickNumber(detail, keys: limitKeys)),
                limit: pickNumber(detail, keys: limitKeys),
                resetsAt: parseDate(resetRaw),
                windowMinutes: windowMinutes(duration: duration, unit: unit)
            )
        }
    }

    // MARK: - 百分比推导

    /// 已用绝对值：优先直接读 used 字段；端点只返回 limit+remaining 时
    /// （当前 /coding/v1/usages 即如此）推导 used = limit - remaining
    private static func usedValue(in detail: [String: Any], limit: Double?) -> Double? {
        if let used = pickNumber(detail, keys: usedKeys) { return used }
        if let limit, let remaining = pickNumber(detail, keys: ["remaining", "remainingValue", "remaining_value"]) {
            return max(limit - remaining, 0)
        }
        return nil
    }

    /// 从 detail 块推导已用百分比：优先 used+limit，其次 limit+remaining，
    /// 最后直接读百分比字段；均不可得返回 nil
    private static func usedPercent(from detail: [String: Any]) -> Double? {
        let used = pickNumber(detail, keys: usedKeys)
        let limit = pickNumber(detail, keys: limitKeys)
        if let used, let limit, limit > 0 {
            return clamp(used / limit * 100)
        }
        let remaining = pickNumber(detail, keys: ["remaining", "remainingValue", "remaining_value"])
        if let limit, limit > 0, let remaining {
            return clamp((limit - remaining) / limit * 100)
        }
        if let percent = pickNumber(detail, keys: ["percent", "percentage", "usedPercent", "used_percent", "usagePercentage", "usage_percentage"]) {
            return clamp(percent)
        }
        return nil
    }

    private static func clamp(_ percent: Double) -> Double {
        min(max(percent, 0), 100)
    }

    // MARK: - 窗口分类

    /// duration+timeUnit → 分钟。timeUnit 为 protobuf 风格枚举
    /// （如 TIME_UNIT_MINUTE），按子串匹配以容忍拼写变体
    private static func windowMinutes(duration: Double?, unit: String?) -> Double? {
        guard let duration, duration > 0 else { return nil }
        let u = (unit ?? "").uppercased()
        if u.contains("MIN") { return duration }
        if u.contains("HOUR") { return duration * 60 }
        if u.contains("DAY") { return duration * 24 * 60 }
        if u.contains("WEEK") { return duration * 7 * 24 * 60 }
        if u.contains("MONTH") { return duration * 30 * 24 * 60 }
        return nil
    }

    /// ≤6 小时视为 5h 频控窗口，其余视为周额度
    private static func classifyByMinutes(_ minutes: Double?) -> KimiWindowKind {
        guard let minutes else { return .weekly }
        return minutes <= 6 * 60 ? .session : .weekly
    }

    /// 名称含"小时/hour"字样视为频控窗口
    private static func classifyByName(_ name: String) -> KimiWindowKind {
        let lowered = name.lowercased()
        if lowered.contains("hour") || lowered.contains("小时") { return .session }
        return .weekly
    }

    private static func kindRank(_ kind: KimiWindowKind) -> Int {
        kind == .session ? 0 : 1
    }

    // MARK: - 通用取值

    private static let usedKeys = [
        "used", "usedValue", "used_value", "usedAmount", "used_amount",
        "currentValue", "current_value", "consumed", "consumedValue", "consumed_value"
    ]
    private static let limitKeys = [
        "limit", "limitValue", "limit_value", "total", "totalValue", "total_value",
        "quota", "quotaValue", "quota_value", "max", "maxValue", "max_value"
    ]
    private static let resetKeys = ["resetTime", "reset_time", "resetAt", "reset_at"]
    private static let nameKeys = ["name", "label", "title"]

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

    private static func firstObject(in entry: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let obj = entry[key] as? [String: Any] { return obj }
        }
        return nil
    }

    /// 时间值兼容：ISO8601 字符串 / epoch 秒 / epoch 毫秒
    /// 共享静态 ISO8601 格式化器（M2 优化：避免每次调用重建）
    private static let isoFmt = ISO8601DateFormatter()
    private static let isoFmtFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

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
            if let date = Self.isoFmt.date(from: text) { return date }
            return Self.isoFmtFrac.date(from: text)
        }
        return nil
    }
}

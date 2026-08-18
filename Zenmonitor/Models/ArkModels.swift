//
//  ArkModels.swift
//  zenmux-monitor
//
//  火山方舟 Agent Plan 配额数据模型与解析器
//  对应控制面 OpenAPI：POST /?Action=GetAFPUsage&Version=2024-01-01
//
//  说明：该端点为官方公开 API（火山方舟文档 Agent Plan API 分类），
//  返回 AFP（Agent Fuel Points）四窗口额度：5 小时 / 日 / 周 / 月。
//  Quota/Used 为 double 高精度浮点（无 Kimi 端点的整数粒度问题）。
//  字段名做 PascalCase / snake_case 多拼写兼容，结构漂移时返回空，
//  由服务层展示错误而不是渲染假数据。
//

import Foundation

// MARK: - 窗口模型

/// AFP 配额窗口（单窗口原始数据，百分比由 used/quota 推导）
struct ArkAFPWindow {
    /// 窗口标签（"5H" / "1D" / "7D" / "1M"）
    let label: String
    /// 计费周期内总配额（AFP）
    let quota: Double
    /// 计费周期内已使用（AFP）
    let used: Double
    /// 本计费周期开始时间（可选）
    let subscribeTime: Date?
    /// 下一次配额重置时间（可选）
    let resetTime: Date?

    /// 已用百分比 0~100（超额时饱和到 100）
    var usedPercent: Double {
        guard quota > 0 else { return 0 }
        return min(max(used / quota * 100, 0), 100)
    }
}

// MARK: - 解析器

/// GetAFPUsage 防御式解析器
enum ArkUsageParser {

    /// 四个窗口的定义：标签、候选字段名（PascalCase 官方名在前，snake_case/别名兼容）
    private static let windowDefs: [(label: String, keys: [String])] = [
        ("5H", ["AFPFiveHour", "afp_five_hour", "AFP5Hour", "afp5Hour", "fiveHour", "five_hour"]),
        ("1D", ["AFPDaily", "afp_daily", "AFPOneDay", "afp_one_day", "daily"]),
        ("7D", ["AFPWeekly", "afp_weekly", "AFP7Day", "afp7Day", "weekly"]),
        ("1M", ["AFPMonthly", "afp_monthly", "AFPOneMonth", "afp_one_month", "monthly"]),
    ]

    /// 解析响应体，返回按 5H → 1D → 7D → 1M 顺序的窗口列表；全部缺失时返回空
    static func parse(body: [String: Any]) -> [ArkAFPWindow] {
        // 防御 data/result 信封（官方为 ResponseMetadata + Result 结构）
        let payload = firstObject(in: body, keys: ["Result", "result", "data", "Data"]) ?? body

        var windows: [ArkAFPWindow] = []
        for def in windowDefs {
            guard let obj = firstObject(in: payload, keys: def.keys) else { continue }
            guard let quota = pickNumber(obj, keys: ["Quota", "quota", "totalQuota", "total_quota", "limit"]) else { continue }
            let used = pickNumber(obj, keys: ["Used", "used", "usedQuota", "used_quota", "consumed"]) ?? 0
            windows.append(ArkAFPWindow(
                label: def.label,
                quota: quota,
                used: used,
                subscribeTime: parseDate(pickRaw(obj, keys: ["SubscribeTime", "subscribe_time", "startTime", "start_time"])),
                resetTime: parseDate(pickRaw(obj, keys: ["ResetTime", "reset_time", "resetAt", "reset_at", "expireTime", "expire_time"]))
            ))
        }
        return windows
    }

    // MARK: - 通用取值

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

    private static func pickRaw(_ obj: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = obj[key] { return value }
        }
        return nil
    }

    private static func firstObject(in body: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let obj = body[key] as? [String: Any] { return obj }
        }
        return nil
    }

    /// 时间值兼容：epoch 毫秒 / epoch 秒 / ISO8601 字符串
    private static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? Double {
            guard number > 0 else { return nil }
            return Date(timeIntervalSince1970: number < 20_000_000_000 ? number : number / 1000)
        }
        if let number = value as? Int {
            guard number > 0 else { return nil }
            let ts = Double(number)
            return Date(timeIntervalSince1970: ts < 20_000_000_000 ? ts : ts / 1000)
        }
        if let text = value as? String {
            if let epoch = Double(text), epoch > 0 {
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

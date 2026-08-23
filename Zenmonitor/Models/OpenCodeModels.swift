//
//  OpenCodeModels.swift
//  zenmux-monitor
//
//  OpenCode Go 用量数据模型与解析器
//  对应 GET https://opencode.ai/zen/go/v1/usage 响应。
//
//  端点为 OpenCode Go 订阅网关的用量接口（与推理共用同一把 API Key），
//  字段形态参照社区实证实现（opencode-quota 插件）并做防御式兼容；
//  结构漂移时解析返回空，由服务层展示错误而不是渲染假数据。
//

import Foundation

// MARK: - 窗口类型

/// OpenCode Go 配额窗口类别
enum OpenCodeWindowKind: Int, CaseIterable {
    case rolling    // 5 小时滚动窗口（$12 额度，硬频控）
    case weekly     // 每周窗口（$30 额度）
    case monthly    // 每月窗口（$60 额度）
}

/// 归一化后的配额窗口（纯值类型，解析逻辑见 OpenCodeUsageParser）
struct OpenCodeQuotaWindow {
    /// 窗口类别
    let kind: OpenCodeWindowKind
    /// 已用百分比 0~100（浮点精度，超额时饱和到 100）
    let usedPercent: Double
    /// 重置时间（可选）
    let resetsAt: Date?
}

// MARK: - 解析器

/// `GET /zen/go/v1/usage` 防御式解析器。
///
/// 官方响应形态（社区实证）：
/// ```
/// { "usage": {
///     "rolling": { "status": "ok", "percent": 0~100, "resetsAt": "ISO8601+offset" },
///     "weekly":  { "status": "ok", "percent": ..., "resetsAt": ... },
///     "monthly": { "status": "ok", "percent": ..., "resetsAt": ... }
/// } }
/// ```
/// 窗口键名做多拼写兼容（rolling/5h/five_hour 等）；percent 兼容字符串数字；
/// 窗口对象缺失或百分比非法时丢弃该窗口，全部非法则返回空。
enum OpenCodeUsageParser {

    /// 各窗口键名的多拼写兼容清单（防御上游字段漂移）
    private static let keyAliases: [OpenCodeWindowKind: [String]] = [
        .rolling: ["rolling", "rollingWindow", "rolling_window", "5h", "fiveHour", "five_hour", "session"],
        .weekly: ["weekly", "weeklyWindow", "weekly_window", "7d", "week"],
        .monthly: ["monthly", "monthlyWindow", "monthly_window", "1m", "30d", "month"]
    ]

    /// 解析响应体，返回按 rolling → weekly → monthly 排序的窗口列表；无法解析返回空
    static func parse(body: [String: Any]) -> [OpenCodeQuotaWindow] {
        // 防御 data/usage 信封（官方为 usage 顶层字段，兜底直接挂根）
        let usage = (body["usage"] as? [String: Any])
            ?? (body["data"] as? [String: Any])
            ?? body

        var windows: [OpenCodeQuotaWindow] = []
        var seenKinds = Set<OpenCodeWindowKind>()

        // 按键名清单匹配窗口对象（一个键只认领一次）
        for (kind, aliases) in keyAliases {
            for alias in aliases {
                guard let obj = usage[alias] as? [String: Any] else { continue }
                guard !seenKinds.contains(kind), let window = parseWindow(kind, obj) else { break }
                seenKinds.insert(kind)
                windows.append(window)
                break
            }
        }

        // 兜底：数组形态（上游若改为列表，按出现顺序认领未出现的窗口）
        if windows.isEmpty, let list = (usage["windows"] ?? usage["limits"]) as? [[String: Any]] {
            var order = OpenCodeWindowKind.allCases.makeIterator()
            for obj in list {
                guard let kind = order.next(), let window = parseWindow(kind, obj) else { continue }
                windows.append(window)
            }
        }

        return windows.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    // MARK: - 单窗口解析

    /// 解析单个窗口对象；百分比非法或缺失时返回 nil（不渲染假数据）
    private static func parseWindow(_ kind: OpenCodeWindowKind, _ obj: [String: Any]) -> OpenCodeQuotaWindow? {
        guard let percent = pickNumber(obj, keys: ["percent", "percentage", "usedPercent", "used_percent", "usagePercent"]) else {
            return nil
        }
        return OpenCodeQuotaWindow(
            kind: kind,
            usedPercent: min(max(percent, 0), 100),
            resetsAt: parseDate(pickRaw(obj, keys: ["resetsAt", "resets_at", "resetTime", "reset_time", "resetAt", "reset_at"]))
        )
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

    /// 时间值兼容：ISO8601 字符串（含时区偏移）/ epoch 秒 / epoch 毫秒
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

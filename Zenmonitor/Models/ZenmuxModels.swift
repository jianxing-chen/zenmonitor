//
//  ZenmuxModels.swift
//  zenmux-monitor
//
//  Zenmux API 返回数据模型
//  对应 GET /api/v1/management/subscription/detail 响应结构
//

import Foundation

// MARK: - API 顶层响应

struct ZenmuxSubscriptionResponse: Codable {
    let success: Bool
    let data: ZenmuxSubscriptionData?
    let error: ZenmuxAPIError?
}

struct ZenmuxAPIError: Codable {
    let code: String?
    let message: String?
}

// MARK: - 订阅数据

struct ZenmuxSubscriptionData: Codable {
    let plan: ZenmuxPlan
    let currency: String
    let base_usd_per_flow: Double
    let effective_usd_per_flow: Double
    let account_status: String
    let quota_5_hour: ZenmuxQuotaWindow
    let quota_7_day: ZenmuxQuotaWindow
    let quota_monthly: ZenmuxQuotaMonthly
}

// MARK: - 套餐信息

struct ZenmuxPlan: Codable {
    let tier: String
    let amount_usd: Double
    let interval: String
    let expires_at: String
}

// MARK: - 滚动窗口配额（5小时 / 7天）

struct ZenmuxQuotaWindow: Codable {
    let usage_percentage: Double
    let resets_at: String?
    let max_flows: Double
    let used_flows: Double
    let remaining_flows: Double
    let used_value_usd: Double
    let max_value_usd: Double
}

// MARK: - 月度配额（仅上限，无实时用量）

struct ZenmuxQuotaMonthly: Codable {
    let max_flows: Double
    let max_value_usd: Double
}

// MARK: - 账号状态枚举

enum ZenmuxAccountStatus: String {
    case healthy    = "healthy"
    case monitored  = "monitored"
    case abusive    = "abusive"
    case suspended  = "suspended"
    case banned     = "banned"
    case unknown

    var displayName: String {
        switch self {
        case .healthy:   return "正常"
        case .monitored: return "监控中"
        case .abusive:   return "已限制"
        case .suspended: return "已暂停"
        case .banned:    return "已封禁"
        case .unknown:   return "未知"
        }
    }

    static func from(_ raw: String) -> ZenmuxAccountStatus {
        ZenmuxAccountStatus(rawValue: raw) ?? .unknown
    }
}

// MARK: - 共享日期格式化器

/// Zenmux API 返回的 ISO8601 时间（带毫秒）统一解析器。
/// 全局单例，避免在多处视图重复创建 Formatter（见 DEVELOPMENT.md 5.3）。
enum ZenmuxDateFormatters {
    /// 解析 ISO8601（含小数秒），如 `2026-06-25T12:34:56.789Z`。失败返回 nil。
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

extension String {
    /// 将 API 返回的 ISO8601 字符串解析为 `Date`，解析失败返回 nil。
    var iso8601Date: Date? { ZenmuxDateFormatters.iso8601.date(from: self) }
}

//
//  SourceSnapshot.swift
//  zenmux-monitor
//
//  多源监控统一数据快照
//  将 Zenmux（配额型）与 DeepSeek（余额型）等不同源的数据抽象为
//  UI 可直接消费的通用结构，实现「UI 与具体源 schema 解耦」。
//
//  设计要点：
//  - SourceSnapshot 是 enum 关联值，区分「配额型」与「余额型」两大类
//  - QuotaSnapshot / BalanceSnapshot 内部均为纯值类型，不含网络/业务逻辑
//  - 各 Source 负责把自己的原始模型转换为这些快照，UI 只消费快照
//

import Foundation
import SwiftUI

// MARK: - 状态指示器

/// 通用的健康度/状态指示，用于配额型与余额型源的头部展示。
/// 与 Zenmux 的 AccountStatus 解耦，各源自行映射。
enum StatusIndicator {
    case healthy        // 绿：正常
    case warning        // 黄：警告/监控中
    case limited        // 橙：已限制
    case suspended      // 红：已暂停/封禁
    case unknown        // 灰：未知/无数据

    var color: Color {
        switch self {
        case .healthy:   return .green
        case .warning:   return .yellow
        case .limited:   return .orange
        case .suspended: return .red
        case .unknown:   return .gray
        }
    }

    var displayName: String {
        switch self {
        case .healthy:   return "正常"
        case .warning:   return "监控中"
        case .limited:   return "已限制"
        case .suspended: return "已暂停"
        case .unknown:   return "未知"
        }
    }
}

// MARK: - 配额窗口数据

/// 单个配额窗口的展示数据（如 5 小时用量、7 天用量）。
/// 纯值类型，不包含任何业务计算（由 Source 负责算好）。
struct QuotaWindowData {
    /// 窗口唯一标识（如 "5h" / "7d" / "monthly"），用于状态栏主窗口选择
    let id: String
    /// 展示标签，如 "5 小时用量"
    let label: String
    /// SF Symbol 图标名
    let icon: String
    /// 用量占比 0~1（已 clamp）
    let pct: Double
    /// 已用/上限文本，如 "12.3/100 flows"
    let usedText: String
    /// USD 用量文本，如 "$1.23 / $5.00"（可选）
    let usedUSDText: String?
    /// 重置时间（可选，如月度配额无实时重置）
    let resetsAt: Date?
    /// 窗口总时长（秒），用于时间进度计算
    let windowDuration: TimeInterval
    /// 预测占比（可选）：若上游窗口用满，本窗口将达到的占比
    /// 仅 7d 这类有上游 5h 窗口的场景使用
    let projectedPct: Double?
}

// MARK: - 指标卡片

/// 配额区块底部的补充指标卡片（如月度上限、汇率）。
struct MetricCard {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color
}

// MARK: - 配额型快照

/// 配额型源（Zenmux）的统一数据快照。
struct QuotaSnapshot {
    /// 头部标题，如 "Zenmux Pro"
    let title: String
    /// 账号状态
    let status: StatusIndicator
    /// 到期时间文本，如 "到期 12/31"（可选）
    let expiryText: String?
    /// 所有配额窗口（5h / 7d / 月度等），按展示顺序
    let windows: [QuotaWindowData]
    /// 补充指标卡片（月度上限、汇率等）
    let extraMetrics: [MetricCard]
}

// MARK: - 余额型快照

/// 余额型源（DeepSeek）的统一数据快照。
struct BalanceSnapshot {
    /// 头部标题，如 "DeepSeek 余额"
    let title: String
    /// 货币符号，如 "¥" / "$"
    let currencySymbol: String
    /// 总余额文本，如 "123.45"
    let total: String
    /// 余额明细，如 [("赠金", "12.34"), ("充值", "111.11")]
    let breakdown: [(label: String, value: String)]
    /// 状态（可选，如余额不足预警）
    let status: StatusIndicator?
}

// MARK: - 统一源快照

/// UI 消费的统一数据快照，区分配额型与余额型。
enum SourceSnapshot {
    case quota(QuotaSnapshot)
    case balance(BalanceSnapshot)
}

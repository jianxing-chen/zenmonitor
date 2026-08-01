//
//  MonitoredSource.swift
//  zenmux-monitor
//
//  可监控数据源协议
//  所有接入 Zenmonitor 的监控源（Zenmux / DeepSeek / 未来新源）都实现此协议，
//  使 AppDelegate / 设置界面 / 状态栏可以统一遍历与刷新，而不感知具体源类型。
//

import Foundation

/// 可监控数据源协议。
///
/// 实现方负责：
/// - 维护自身网络请求与缓存
/// - 把原始数据模型转换为 `SourceSnapshot` 供 UI 消费
/// - 在数据/错误/刷新状态变化时通过 `@Observable` 驱动 UI 更新
///
/// 注意：本协议不强制刷新策略（定时轮询 / 菜单打开时拉取 / 手动刷新），
/// 由各实现方自行决定，并通过 `refresh()` 暴露「立即刷新一次」的能力。
@MainActor
protocol MonitoredSource {
    /// 源唯一标识（如 "zenmux" / "deepseek"），用于设置存储、日志等
    var sourceID: String { get }

    /// 展示名称（如 "Zenmux" / "DeepSeek"）
    var displayName: String { get }

    /// 资产目录中的 logo 图片名；nil 表示无专属 logo
    var logoImageName: String? { get }

    /// 最近一次成功更新时间
    var lastUpdated: Date? { get }

    /// 最近一次错误文案（成功后清空）
    var lastError: String? { get }

    /// 是否正在刷新
    var isRefreshing: Bool { get }

    /// 当前数据快照；nil 表示暂无数据（首次加载/未配置/请求失败）
    var snapshot: SourceSnapshot? { get }

    /// 立即刷新一次数据（不改变任何暂停/策略状态）
    func refresh() async
}

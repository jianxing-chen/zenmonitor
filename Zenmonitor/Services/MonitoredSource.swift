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
/// 由各实现方自行决定，并通过 `refresh(force:)` 暴露「立即刷新一次」的能力。
/// 自动定时调度统一由 SourceRegistry 的全局定时器驱动（见 startAutoRefresh），
/// 各源不应再各自维护定时循环。
@MainActor
protocol MonitoredSource: AnyObject {
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

    /// 状态变化回调（数据/错误更新时触发），AppDelegate 用它刷新状态栏项
    var onStateChange: (@MainActor () -> Void)? { get set }

    /// 立即刷新一次数据（不改变任何暂停/策略状态）
    /// - Parameter force: true = 手动触发（面板打开/刷新按钮），绕过暂停等策略；
    ///   false = 全局定时器自动触发，实现方应尊重自身的手动暂停状态
    func refresh(force: Bool) async
}

extension MonitoredSource {
    /// 默认实现：未区分手动/自动的源统一按手动语义处理
    func refresh() async { await refresh(force: true) }
}

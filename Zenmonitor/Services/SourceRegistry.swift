//
//  SourceRegistry.swift
//  zenmux-monitor
//
//  监控源注册中心
//  集中管理所有已接入的监控源，向 AppDelegate / 设置界面提供统一访问入口。
//
//  当前版本内置 Zenmux、DeepSeek、Kimi、智谱 GLM、火山方舟、Tavily、OpenCode、
//  StepFun 八个源；
//  未来支持「随时添加新源」时，可扩展为动态注册/注销与用户启用/禁用列表。
//

import Foundation
import Observation

@MainActor
@Observable
final class SourceRegistry {
    static let shared = SourceRegistry()

    /// 所有已注册的监控源（当前内置，未来可动态扩展）
    private(set) var sources: [any MonitoredSource] = []

    /// 全局自动刷新定时器：各源统一的自动刷新频率唯一来源，
    /// 间隔跟随 SettingsManager.refreshInterval（设置面板「自动刷新间隔」）
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?

    /// 每源最近一次自动刷新 tick 的时间戳（用于每源倍率调度：
    /// 实际周期 = 全局间隔 × 该源倍率，未到时机本轮跳过）
    @ObservationIgnored private var lastAutoTick: [String: Date] = [:]

    /// 全局自动刷新每轮 tick 完成后的回调（AppDelegate 用于同步打开中的下拉面板）
    @ObservationIgnored var onAutoRefreshTick: (@MainActor () -> Void)?

    private init() {
        // 内置源注册：Zenmux 为主（配额型），DeepSeek（余额型）、Kimi（配额型）、
        // 智谱 GLM（配额型）、火山方舟 Agent Plan（配额型）、Tavily（配额型）、
        // OpenCode Go（配额型）为辅
        sources = [
            ZenmuxAPIService.shared,
            DeepSeekAPIService.shared,
            KimiCodeAPIService.shared,
            ZhipuAPIService.shared,
            ArkAPIService.shared,
            TavilyAPIService.shared,
            OpenCodeAPIService.shared,
            StepFunAPIService.shared
        ]
    }

    /// 按 sourceID 查找源
    func source(withID id: String) -> (any MonitoredSource)? {
        sources.first { $0.sourceID == id }
    }

    /// 按用户自定义排序的源列表（下拉面板渲染顺序）；
    /// 未配置过排序时保持注册表默认顺序（Zenmux → DeepSeek → Kimi）
    var orderedSources: [any MonitoredSource] {
        let order = SettingsManager.shared.menuOrder(registrySources: sources.map { $0.sourceID })
        return order.compactMap { id in sources.first { $0.sourceID == id } }
    }

    /// 刷新所有已启用源（并行，互不阻断）
    /// - Parameter force: true = 手动触发（面板打开/刷新按钮），各源绕过暂停策略；
    ///   false = 全局定时器自动触发，源可尊重自身手动暂停状态（如 Zenmux）
    func refreshAll(force: Bool = true) async {
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { @MainActor in
                    await source.refresh(force: force)
                }
            }
        }
    }

    // MARK: - 全局自动刷新

    /// 启动（或按新间隔重启）全局自动刷新循环。
    /// 应用启动时调用一次；设置中修改刷新间隔后再次调用即以新间隔生效。
    /// force=false 触发，Zenmux 手动暂停时静默跳过，其余源未配置凭据时内部静默跳过。
    func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                // 每轮读取当前间隔：即使未重启循环，间隔变更也会在下一轮生效
                let interval = SettingsManager.shared.refreshInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.autoTick()
                guard !Task.isCancelled else { break }
                self?.onAutoRefreshTick?()
            }
        }
    }

    /// 全局定时器每轮 tick：按各源倍率判断是否到期（实际周期 = 全局间隔 × 倍率，
    /// 倍率可在设置卡片随时调整，下一轮即生效），到期的源并行刷新，
    /// 未到期的本轮跳过；首次未记录时间戳的源视为到期（与旧行为一致）
    private func autoTick() async {
        let interval = SettingsManager.shared.refreshInterval
        let now = Date()
        let due = sources.filter { source in
            let period = interval * Double(SettingsManager.shared.refreshMultiplier(for: source.sourceID))
            guard let last = lastAutoTick[source.sourceID] else { return true }
            return now.timeIntervalSince(last) >= period
        }
        guard !due.isEmpty else { return }
        for source in due {
            lastAutoTick[source.sourceID] = now
        }
        await withTaskGroup(of: Void.self) { group in
            for source in due {
                group.addTask { @MainActor in
                    await source.refresh(force: false)
                }
            }
        }
    }

    /// 停止全局自动刷新循环（应用退出清理用）
    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    /// 是否有任一源正在刷新（用于菜单「刷新」按钮状态）
    var isAnyRefreshing: Bool {
        sources.contains { $0.isRefreshing }
    }

    /// 最近一次的任一源更新时间（用于菜单 Header 显示「更新于 x 前」）
    var latestUpdateTime: Date? {
        sources.compactMap { $0.lastUpdated }.max()
    }
}

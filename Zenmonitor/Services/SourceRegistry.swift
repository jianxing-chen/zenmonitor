//
//  SourceRegistry.swift
//  zenmux-monitor
//
//  监控源注册中心
//  集中管理所有已接入的监控源，向 AppDelegate / 设置界面提供统一访问入口。
//
//  当前版本内置 Zenmux、DeepSeek、Kimi 三个源；
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

    private init() {
        // 内置源注册：Zenmux 为主（配额型），DeepSeek（余额型）、Kimi（配额型）为辅
        sources = [
            ZenmuxAPIService.shared,
            DeepSeekAPIService.shared,
            KimiCodeAPIService.shared
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
    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { @MainActor in
                    await source.refresh()
                }
            }
        }
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

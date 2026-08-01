//
//  SourceRegistry.swift
//  zenmux-monitor
//
//  监控源注册中心
//  集中管理所有已接入的监控源，向 AppDelegate / 设置界面提供统一访问入口。
//
//  当前版本内置 Zenmux 与 DeepSeek 两个源；
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
        // 内置源注册：Zenmux 为主（配额型），DeepSeek 为辅（余额型）
        sources = [
            ZenmuxAPIService.shared,
            DeepSeekAPIService.shared
        ]
    }

    /// 按 sourceID 查找源
    func source(withID id: String) -> (any MonitoredSource)? {
        sources.first { $0.sourceID == id }
    }

    /// 主源：用于菜单栏状态栏显示的配额型源（当前固定为 Zenmux）
    /// 未来支持多配额源时，改为用户可配置。
    var primaryQuotaSource: (any MonitoredSource)? {
        sources.first { source in
            guard let snapshot = source.snapshot else { return false }
            if case .quota = snapshot { return true }
            return false
        }
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

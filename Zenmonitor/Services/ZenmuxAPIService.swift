//
//  ZenmuxAPIService.swift
//  zenmux-monitor
//
//  Zenmux 管理 API 客户端
//  功能：获取订阅详情、用量配额等数据
//  接口：GET /api/v1/management/subscription/detail
//

import Foundation
import Observation
import SwiftUI

enum ZenmuxAPIErrorType: LocalizedError {
    case invalidURL
    case noAPIKey
    case networkError(Error)
    case httpError(Int)
    case decodeError(Error)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 API 地址"
        case .noAPIKey:
            return "未设置 Management API Key，请在设置中配置"
        case .networkError(let err):
            return "网络错误: \(err.localizedDescription)"
        case .httpError(let code):
            return "HTTP 错误: \(code)"
        case .decodeError(let err):
            return "数据解析失败: \(err.localizedDescription)"
        case .apiError(let msg):
            return "API 错误: \(msg)"
        }
    }
}

@MainActor
@Observable
final class ZenmuxAPIService: MonitoredSource {
    static let shared = ZenmuxAPIService()

    /// 当前 API 域名对应的 subscription detail 接口 URL，随 SettingsManager.apiDomain 联动。
    private var baseURL: URL { SettingsManager.shared.apiDomain.subscriptionDetailURL }
    private static let cacheMaxAge: TimeInterval = 4 * 60 * 60

    var subscriptionData: ZenmuxSubscriptionData? {
        didSet { notifyStateChange() }
    }
    var lastError: String? {
        didSet { notifyStateChange() }
    }
    var lastUpdated: Date? {
        didSet { notifyStateChange() }
    }
    var isPaused = false {
        didSet { notifyStateChange() }
    }
    var isRefreshing = false {
        didSet { notifyStateChange() }
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var activeRefreshInterval: TimeInterval?
    @ObservationIgnored private var isManuallyPaused = false
    @ObservationIgnored private var pendingStateNotify = false
    @ObservationIgnored private var isCleanedUp = false
    @ObservationIgnored var onStateChange: (@MainActor () -> Void)?

    private init() {
        restoreCachedSnapshotIfAvailable()
    }

    // MARK: - 公开方法

    /// 应用启动：直接开始按间隔刷新
    func handleAppLaunch() {
        guard let apiKey = SettingsManager.shared.apiKey, !apiKey.isEmpty else {
            clearForMissingAPIKey()
            stopRefreshLoop(markPaused: false)
            return
        }
        let interval = SettingsManager.shared.refreshInterval
        startRefreshLoop(interval: interval, immediateFetch: true)
    }

    /// 设置变更后重新应用刷新策略
    func settingsDidChange(forceFetch: Bool = true) {
        guard let apiKey = SettingsManager.shared.apiKey, !apiKey.isEmpty else {
            clearForMissingAPIKey()
            stopRefreshLoop(markPaused: false)
            return
        }
        guard !isManuallyPaused else {
            stopRefreshLoop(markPaused: true)
            return
        }
        let interval = SettingsManager.shared.refreshInterval
        startRefreshLoop(interval: interval, immediateFetch: forceFetch)
    }

    /// 手动暂停自动刷新
    func pauseAutoRefresh() {
        isManuallyPaused = true
        stopRefreshLoop(markPaused: true)
    }

    /// 手动恢复自动刷新
    func resumeAutoRefresh(forceFetch: Bool = true) {
        isManuallyPaused = false
        let interval = SettingsManager.shared.refreshInterval
        startRefreshLoop(interval: interval, immediateFetch: forceFetch)
    }

    /// 手动立即刷新一次，但不改变当前暂停状态（内部 force 绕过暂停检查，不翻转 isPaused）
    func refreshNow() async {
        await fetchSubscription(force: true, bypassPause: true)
    }

    /// 获取订阅详情
    func fetchSubscription(force: Bool = false, bypassPause: Bool = false) async {
        guard !isCleanedUp else { return }
        guard let apiKey = SettingsManager.shared.apiKey, !apiKey.isEmpty else {
            clearForMissingAPIKey()
            return
        }

        // bypassPause: 绕过暂停检查（refreshNow 使用），不改变 isPaused 状态
        if !force, !bypassPause, isPaused { return }
        if isRefreshing { return }

        if !bypassPause {
            isPaused = false
        }
        isRefreshing = true
        lastError = nil

        defer {
            isRefreshing = false
        }

        do {
            let url = baseURL
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ZenmuxAPIErrorType.httpError(0)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw ZenmuxAPIErrorType.httpError(httpResponse.statusCode)
            }

            let decoder = JSONDecoder()
            let result = try decoder.decode(ZenmuxSubscriptionResponse.self, from: data)

            if result.success, let subData = result.data {
                subscriptionData = subData
                let refreshedAt = Date()
                lastUpdated = refreshedAt
                SettingsManager.shared.cachedSubscriptionData = subData
                SettingsManager.shared.cachedLastUpdated = refreshedAt
            } else {
                throw ZenmuxAPIErrorType.apiError(result.error?.message ?? "未知错误")
            }
        } catch let error as ZenmuxAPIErrorType {
            if case .httpError(let code) = error, code == 401 || code == 403 {
                clearCachedSnapshotState()
            }
            lastError = error.localizedDescription
        } catch {
            lastError = ZenmuxAPIErrorType.networkError(error).localizedDescription
        }
    }

    private func startRefreshLoop(interval: TimeInterval, immediateFetch: Bool) {
        let shouldRestartTask = refreshTask == nil || activeRefreshInterval != interval

        if shouldRestartTask {
            stopRefreshLoop(markPaused: false)
            activeRefreshInterval = interval
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if Task.isCancelled { break }
                    await self?.fetchSubscription()
                }
            }
        }

        isPaused = false

        if immediateFetch {
            Task { [weak self] in
                await self?.fetchSubscription(force: true)
            }
        }
    }

    private func stopRefreshLoop(markPaused: Bool) {
        refreshTask?.cancel()
        refreshTask = nil
        activeRefreshInterval = nil
        isPaused = markPaused
    }

    private func clearForMissingAPIKey() {
        lastError = ZenmuxAPIErrorType.noAPIKey.localizedDescription
        clearCachedSnapshotState()
    }

    func cleanup() {
        guard !isCleanedUp else { return }
        isCleanedUp = true
        stopRefreshLoop(markPaused: false)
        isRefreshing = false
    }

    private func clearCachedSnapshotState() {
        lastUpdated = nil
        subscriptionData = nil
        SettingsManager.shared.clearCachedSubscriptionSnapshot()
    }

    private func notifyStateChange() {
        guard !pendingStateNotify else { return }
        pendingStateNotify = true
        Task { @MainActor [weak self] in
            self?.pendingStateNotify = false
            self?.onStateChange?()
        }
    }

    private func restoreCachedSnapshotIfAvailable() {
        guard let apiKey = SettingsManager.shared.apiKey, !apiKey.isEmpty else {
            return
        }

        guard let cachedAt = SettingsManager.shared.cachedLastUpdated,
              Date().timeIntervalSince(cachedAt) <= Self.cacheMaxAge,
              let cachedData = SettingsManager.shared.cachedSubscriptionData else {
            SettingsManager.shared.clearCachedSubscriptionSnapshot()
            return
        }

        subscriptionData = cachedData
        lastUpdated = cachedAt
    }

    // MARK: - MonitoredSource 协议实现

    var sourceID: String { "zenmux" }

    var displayName: String { "Zenmux" }

    var logoImageName: String? { nil }  // 使用 App 图标，无需单独资产

    var snapshot: SourceSnapshot? {
        guard let data = subscriptionData else { return nil }
        return .quota(makeQuotaSnapshot(from: data))
    }

    /// MonitoredSource 协议要求的统一刷新入口
    func refresh() async {
        await refreshNow()
    }

    /// 把 Zenmux 原始订阅数据转换为通用配额快照
    private func makeQuotaSnapshot(from data: ZenmuxSubscriptionData) -> QuotaSnapshot {
        QuotaSnapshot(
            title: "Zenmux \(data.plan.tier.capitalized)",
            status: mapStatus(data.account_status),
            expiryText: makeExpiryText(data.plan.expires_at),
            windows: [
                makeWindowData(
                    id: "5h",
                    label: "5 小时用量",
                    icon: "clock",
                    window: data.quota_5_hour,
                    duration: 5 * 3600,
                    projectedPct: nil
                ),
                makeWindowData(
                    id: "7d",
                    label: "7 天用量",
                    icon: "calendar",
                    window: data.quota_7_day,
                    duration: 7 * 24 * 3600,
                    projectedPct: makeProjected7dPct(data)
                )
            ],
            extraMetrics: [
                MetricCard(
                    title: "当月上限",
                    value: "\(formatNum(data.quota_monthly.max_flows)) flows",
                    detail: "$\(formatNum(data.quota_monthly.max_value_usd))",
                    icon: "chart.bar.fill",
                    tint: .purple
                ),
                MetricCard(
                    title: "汇率",
                    value: "$\(String(format: "%.4f", data.effective_usd_per_flow))",
                    detail: "per flow",
                    icon: "dollarsign.circle.fill",
                    tint: .green
                )
            ]
        )
    }

    private func makeWindowData(
        id: String,
        label: String,
        icon: String,
        window: ZenmuxQuotaWindow,
        duration: TimeInterval,
        projectedPct: Double?
    ) -> QuotaWindowData {
        QuotaWindowData(
            id: id,
            label: label,
            icon: icon,
            pct: window.usage_percentage,
            usedText: "\(formatNum(window.used_flows))/\(formatNum(window.max_flows)) flows",
            usedUSDText: "$\(formatNum(window.used_value_usd)) / $\(formatNum(window.max_value_usd))",
            resetsAt: window.resets_at?.iso8601Date,
            windowDuration: duration,
            projectedPct: projectedPct
        )
    }

    /// 7d 预测占比：当前 7d 用量 + 5h 剩余可用量（即 5h 用满的增量），占 7d 上限的比例
    private func makeProjected7dPct(_ data: ZenmuxSubscriptionData) -> Double? {
        let max7d = data.quota_7_day.max_flows
        guard max7d > 0 else { return nil }
        let projectedUsed = data.quota_7_day.used_flows
            + data.quota_5_hour.max_flows
            - data.quota_5_hour.used_flows
        return min(max(projectedUsed / max7d, 0), 1)
    }

    private func makeExpiryText(_ iso: String) -> String? {
        guard let date = iso.iso8601Date else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd"
        return "到期 \(fmt.string(from: date))"
    }

    private func mapStatus(_ raw: String) -> StatusIndicator {
        switch ZenmuxAccountStatus.from(raw) {
        case .healthy:   return .healthy
        case .monitored: return .warning
        case .abusive:   return .limited
        case .suspended, .banned: return .suspended
        case .unknown:   return .unknown
        }
    }

    private func formatNum(_ v: Double) -> String {
        v >= 10000 ? String(format: "%.2fk", v / 1000)
                   : String(format: "%.2f", v)
    }
}

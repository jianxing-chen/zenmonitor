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

    @ObservationIgnored private var pendingStateNotify = false
    @ObservationIgnored private var isCleanedUp = false
    @ObservationIgnored var onStateChange: (@MainActor () -> Void)?

    private init() {
        restoreCachedSnapshotIfAvailable()
    }

    // MARK: - 公开方法

    /// 应用启动：立即拉取一次；周期性自动刷新由 SourceRegistry 全局定时器统一驱动
    func handleAppLaunch() {
        isPaused = false
        guard let apiKey = SettingsManager.shared.apiKey, !apiKey.isEmpty else {
            clearForMissingAPIKey()
            return
        }
        Task { [weak self] in
            await self?.fetchSubscription(force: true)
        }
    }

    /// 设置变更后重新应用刷新策略（域名/Key 变更等）：
    /// 自动刷新间隔已移交 SourceRegistry 统一管理，此处仅处理立即拉取与无 Key 清理
    func settingsDidChange(forceFetch: Bool = true) {
        guard let apiKey = SettingsManager.shared.apiKey, !apiKey.isEmpty else {
            clearForMissingAPIKey()
            isPaused = false
            return
        }
        guard forceFetch else { return }
        // 立即拉取绕过暂停（与原行为一致），不改变暂停状态
        Task { [weak self] in
            await self?.fetchSubscription(force: true, bypassPause: true)
        }
    }

    /// 手动暂停自动刷新：全局定时器的自动触发（force=false）将静默跳过本源，
    /// 手动触发（面板打开/刷新按钮）仍可拉取
    func pauseAutoRefresh() {
        isPaused = true
    }

    /// 手动恢复自动刷新
    func resumeAutoRefresh(forceFetch: Bool = true) {
        isPaused = false
        if forceFetch {
            Task { [weak self] in
                await self?.fetchSubscription(force: true)
            }
        }
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

        // bypassPause: 绕过暂停检查（手动触发使用），不改变 isPaused 状态；
        // 自动定时触发（force=false 且未 bypassPause）在手动暂停时静默跳过。
        // isPaused 状态仅由 pauseAutoRefresh/resumeAutoRefresh 翻转
        if !force, !bypassPause, isPaused { return }
        if isRefreshing { return }

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

    private func clearForMissingAPIKey() {
        // 未配置 Key 时静默置空（与其他五源一致）：下拉面板不显示占位，
        // 仅「已配置但拉取失败」才透传错误；配置引导由设置面板承担
        lastError = nil
        clearCachedSnapshotState()
    }

    func cleanup() {
        guard !isCleanedUp else { return }
        isCleanedUp = true
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
    /// - Parameter force: true = 手动触发（面板打开/刷新按钮/保存 Key），绕过暂停；
    ///   false = 全局定时器自动触发，手动暂停时静默跳过
    func refresh(force: Bool) async {
        if force {
            await refreshNow()
        } else {
            await fetchSubscription()
        }
    }

    /// 把 Zenmux 原始订阅数据转换为通用配额快照
    private func makeQuotaSnapshot(from data: ZenmuxSubscriptionData) -> QuotaSnapshot {
        QuotaSnapshot(
            title: "Zenmux",
            status: mapStatus(data.account_status),
            expiryText: makeExpiryText(data.plan.expires_at),
            windows: [
                makeWindowData(
                    id: "5h",
                    label: "5H",
                    icon: "clock",
                    window: data.quota_5_hour,
                    duration: 5 * 3600,
                    projectedPct: nil
                ),
                makeWindowData(
                    id: "7d",
                    label: "7D",
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

    /// 映射服务端真实账户状态：monitored/abusive 属用量观察态（水位由进度条颜色表达），
    /// 归入正常；仅真实封禁/暂停才标红
    private func mapStatus(_ raw: String) -> StatusIndicator {
        switch ZenmuxAccountStatus.from(raw) {
        case .healthy, .monitored, .abusive: return .healthy
        case .suspended, .banned: return .suspended
        case .unknown:   return .unknown
        }
    }

    private func formatNum(_ v: Double) -> String {
        v >= 10000 ? String(format: "%.2fk", v / 1000)
                   : String(format: "%.2f", v)
    }
}

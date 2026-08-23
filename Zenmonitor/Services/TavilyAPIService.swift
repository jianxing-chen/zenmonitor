//
//  TavilyAPIService.swift
//  zenmux-monitor
//
//  Tavily 用量查询 API 客户端
//  接口：GET https://api.tavily.com/usage（官方 API Reference 收录）
//
//  说明：标准 Bearer 认证（与推理接口同一把 tvly- Key）；返回本计费周期
//  credits 消耗与套餐限额（整数精度）。映射为单月度窗口的 QuotaSnapshot，
//  重置时间端点不返回，按本地日历计算（下次月 1 日）。
//
//  ⚠️ /usage 端点有独立限流：10 次/10 分钟（超限 429 + retry-after），
//  服务层内置 60s 客户端节流——距上次成功请求不足节流间隔时静默复用
//  现有数据（手动/自动触发均适用），确保任何触发模式下都不会触限。
//

import Foundation
import Observation
import SwiftUI

enum TavilyAPIError: LocalizedError {
    case noAPIKey
    case networkError(Error)
    case unauthorized
    case rateLimited(String?)
    case httpError(Int)
    case decodeError
    case emptyData

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "未设置 Tavily API Key，请在设置中配置"
        case .networkError(let err):
            return "Tavily 网络错误: \(err.localizedDescription)"
        case .unauthorized:
            return "Tavily 鉴权失败，请检查 API Key 是否有效"
        case .rateLimited(let retryAfter):
            if let retryAfter, let seconds = Int(retryAfter) {
                return "Tavily 触发限流，请 \(seconds) 秒后重试"
            }
            return "Tavily 触发限流（/usage 限 10 次/10 分钟），请稍后重试"
        case .httpError(let code):
            return "Tavily HTTP 错误: \(code)"
        case .decodeError:
            return "Tavily 数据解析失败"
        case .emptyData:
            return "Tavily 未返回用量数据"
        }
    }
}

@MainActor
@Observable
final class TavilyAPIService: MonitoredSource {
    static let shared = TavilyAPIService()

    private let usageURL = URL(string: "https://api.tavily.com/usage")!
    private let cacheKey = "tavily_cached_usages"
    private let cacheUpdatedKey = "tavily_cached_updated"

    /// 客户端节流间隔：/usage 限流 10 次/10 分钟，取 60s 保证任何触发
    /// 模式（定时器 + 面板打开 + 手动按钮叠加）都不越过限流线
    private static let minFetchInterval: TimeInterval = 60

    /// 最近一次成功解析的用量信息
    private(set) var usage: TavilyUsageInfo?
    /// 最近一次错误文案（成功后清空）
    var lastError: String?
    /// 最近一次成功更新时间
    private(set) var lastUpdated: Date?
    /// 是否正在请求
    private(set) var isRefreshing = false

    /// MonitoredSource 协议：状态变化回调（AppDelegate 用于刷新状态栏项）
    @ObservationIgnored var onStateChange: (@MainActor () -> Void)?

    /// runloop 合并标记：fetch 过程中多个 @Observable 属性先后变化，
    /// 合并为一次状态栏同步，避免全量重渲染风暴
    @ObservationIgnored private var pendingStateNotify = false

    private func notifyStateChange() {
        guard !pendingStateNotify else { return }
        pendingStateNotify = true
        Task { @MainActor [weak self] in
            self?.pendingStateNotify = false
            self?.onStateChange?()
        }
    }

    private init() {
        restoreCachedUsage()
    }

    // MARK: - 缓存恢复/保存（存原始响应，解析逻辑升级后仍可复用旧缓存）

    private func restoreCachedUsage() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let parsed = TavilyUsageParser.parse(body: json) else { return }
        usage = parsed
        lastUpdated = UserDefaults.standard.object(forKey: cacheUpdatedKey) as? Date
    }

    private func saveCachedUsage(_ raw: Data) {
        UserDefaults.standard.set(raw, forKey: cacheKey)
        UserDefaults.standard.set(lastUpdated, forKey: cacheUpdatedKey)
    }

    /// Key 已删除/未配置：清空数据与缓存（同时重置节流状态）。
    /// 设置界面删除/更换 Key 时直接调用，无需等下次拉取即生效。
    func invalidateForMissingKey() {
        usage = nil
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: cacheUpdatedKey)
        lastError = nil
        lastUpdated = nil
        notifyStateChange()
    }

    // MARK: - 请求

    /// 拉取用量。无 Key 时静默置空（不报错），用户未配置时菜单不显示该区块。
    /// 节流：距上次成功请求不足 60s 且已有数据时静默跳过（复用现有数据），
    /// 避免自动定时器与手动触发叠加越过 /usage 的 10 次/10 分钟限流线。
    func fetchUsage() async {
        guard let apiKey = SettingsManager.shared.tavilyAPIKey,
              !apiKey.isEmpty else {
            invalidateForMissingKey()
            return
        }

        if usage != nil, let lastSuccess = lastUpdated,
           Date().timeIntervalSince(lastSuccess) < Self.minFetchInterval {
            return
        }

        guard !isRefreshing else { return }
        isRefreshing = true

        defer {
            isRefreshing = false
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw TavilyAPIError.unauthorized
                }
                if http.statusCode == 429 {
                    // 官方 429 携带 retry-after 头（秒），透传给用户
                    let retryAfter = http.value(forHTTPHeaderField: "retry-after")
                    throw TavilyAPIError.rateLimited(retryAfter)
                }
                throw TavilyAPIError.httpError(http.statusCode)
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw TavilyAPIError.decodeError
            }
            guard let parsed = TavilyUsageParser.parse(body: json) else {
                throw TavilyAPIError.emptyData
            }
            usage = parsed
            lastError = nil
            lastUpdated = Date()
            saveCachedUsage(data)
            notifyStateChange()
        } catch let error as TavilyAPIError {
            lastError = error.localizedDescription
            notifyStateChange()
        } catch {
            lastError = TavilyAPIError.networkError(error).localizedDescription
            notifyStateChange()
        }
    }

    // MARK: - MonitoredSource 协议实现

    var sourceID: String { "tavily" }

    var displayName: String { "Tavily" }

    /// 下拉面板区块头部使用 Tavily 品牌 Logo（与设置卡片一致）
    var logoImageName: String? { "TavilyLogo" }

    var snapshot: SourceSnapshot? {
        guard usage != nil else { return nil }
        return .quota(makeQuotaSnapshot())
    }

    /// MonitoredSource 协议要求的统一刷新入口（手动/自动语义一致：无 Key 静默跳过）
    func refresh(force: Bool) async {
        await fetchUsage()
    }

    // MARK: - 快照构造

    /// 把用量信息转换为通用配额快照：单月度窗口（1M）+ 套餐/端点明细指标卡。
    /// 重置时间端点不返回，按本地日历计算（下次月 1 日 00:00）。
    private func makeQuotaSnapshot() -> QuotaSnapshot {
        let info = usage!
        let pct: Double
        if let limit = info.limit, limit > 0 {
            pct = min(max(info.used / limit * 100, 0), 100)
        } else {
            pct = 0  // 无限制套餐：进度条不表达用量
        }
        return QuotaSnapshot(
            title: "Tavily",
            status: mapStatus(pct),
            expiryText: nil,
            windows: [makeWindowData(info, pct: pct)],
            extraMetrics: makeMetrics(info)
        )
    }

    private func makeWindowData(_ info: TavilyUsageInfo, pct: Double) -> QuotaWindowData {
        let usedText: String
        if let limit = info.limit, limit > 0 {
            usedText = "已用 \(formatNum(info.used))/\(formatNum(limit)) credits"
        } else {
            usedText = "已用 \(formatNum(info.used)) credits（无限制）"
        }
        return QuotaWindowData(
            id: "1m",
            label: "1M",
            icon: "calendar",
            pct: pct / 100,
            usedText: usedText,
            usedUSDText: nil,
            resetsAt: nextBillingReset(),
            windowDuration: 30 * 24 * 3600,
            projectedPct: nil,
            percentText: nil
        )
    }

    private func makeMetrics(_ info: TavilyUsageInfo) -> [MetricCard] {
        var metrics: [MetricCard] = []
        // 套餐卡：名称 + 按量超额状态
        let paygoDetail: String
        if let paygoUsage = info.paygoUsage, paygoUsage > 0 {
            paygoDetail = "按量超额 \(formatNum(paygoUsage)) 次"
        } else {
            paygoDetail = "本计费周期"
        }
        metrics.append(MetricCard(
            title: "当月套餐",
            value: info.planName ?? "—",
            detail: paygoDetail,
            icon: "creditcard.fill",
            tint: .blue
        ))
        // 端点消耗卡：五类端点按消耗排序取前两位展示，其余折叠进 detail
        if !info.endpoints.isEmpty {
            let sorted = info.endpoints.sorted { $0.used > $1.used }
            let head = sorted.first!
            let rest = sorted.dropFirst().prefix(2)
                .map { "\($0.name) \(formatNum($0.used))" }
                .joined(separator: " · ")
            metrics.append(MetricCard(
                title: "端点消耗",
                value: "\(head.name) \(formatNum(head.used))",
                detail: rest.isEmpty ? "credits" : rest,
                icon: "magnifyingglass",
                tint: .green
            ))
        }
        return metrics
    }

    /// 下次计费周期重置时间：下次月 1 日 00:00（本地时区）
    private func nextBillingReset() -> Date? {
        var comps = DateComponents()
        comps.month = 1
        return Calendar.current.date(byAdding: comps, to: startOfCurrentMonth())
    }

    private func startOfCurrentMonth() -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: Date())
        return cal.date(from: comps) ?? Date()
    }

    /// 三档精简：仅额度完全耗尽（请求被真实拒绝）才标已暂停；用量水位由进度条颜色表达
    private func mapStatus(_ percent: Double) -> StatusIndicator {
        percent >= 100 ? .suspended : .healthy
    }

    private func formatNum(_ v: Double) -> String {
        v >= 10000 ? String(format: "%.2fk", v / 1000)
                   : String(format: "%.0f", v)
    }
}

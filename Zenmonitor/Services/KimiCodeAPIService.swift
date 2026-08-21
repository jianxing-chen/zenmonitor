//
//  KimiCodeAPIService.swift
//  zenmux-monitor
//
//  Kimi Code 订阅配额查询 API 客户端
//  接口：GET https://api.kimi.com/coding/v1/usages
//
//  说明：该端点未收录于官方文档，但与推理接口同域名、同 Key（sk-kimi-）鉴权，
//  返回 5 小时滚动频控与 7 天周额度两个配额窗口。响应字段可能有漂移，
//  解析由 KimiUsageParser 做防御式兼容。
//
//  设计：与 DeepSeek 一致，「菜单打开时拉取」策略，不做后台轮询。
//

import Foundation
import Observation

enum KimiAPIError: LocalizedError {
    case noAPIKey
    case networkError(Error)
    case unauthorized
    case httpError(Int)
    case decodeError
    case emptyData

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "未设置 Kimi API Key，请在设置中配置"
        case .networkError(let err):
            return "Kimi 网络错误: \(err.localizedDescription)"
        case .unauthorized:
            return "Kimi 鉴权失败，请检查 API Key 是否有效"
        case .httpError(let code):
            return "Kimi HTTP 错误: \(code)"
        case .decodeError:
            return "Kimi 数据解析失败"
        case .emptyData:
            return "Kimi 未返回配额数据"
        }
    }
}

@MainActor
@Observable
final class KimiCodeAPIService: MonitoredSource {
    static let shared = KimiCodeAPIService()

    private let usagesURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    private let cacheKey = "kimi_cached_usages"
    private let cacheUpdatedKey = "kimi_cached_updated"

    /// 最近一次成功解析的配额窗口
    private(set) var windows: [KimiQuotaWindow] = []
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
        restoreCachedUsages()
    }

    // MARK: - 缓存恢复/保存（存原始响应，解析逻辑升级后仍可复用旧缓存）

    private func restoreCachedUsages() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let parsed = KimiUsageParser.parse(body: json)
        guard !parsed.isEmpty else { return }
        windows = parsed
        lastUpdated = UserDefaults.standard.object(forKey: cacheUpdatedKey) as? Date
    }

    private func saveCachedUsages(_ raw: Data) {
        UserDefaults.standard.set(raw, forKey: cacheKey)
        UserDefaults.standard.set(lastUpdated, forKey: cacheUpdatedKey)
    }

    /// Key 已删除/未配置：清空数据与缓存。
    /// 设置界面删除 Key 时直接调用，无需等下次拉取即生效。
    func invalidateForMissingKey() {
        windows = []
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: cacheUpdatedKey)
        lastError = nil
        lastUpdated = nil
        notifyStateChange()
    }

    // MARK: - 请求

    /// 拉取配额。无 Key 时静默置空（不报错），用户未配置时菜单不显示该区块。
    func fetchUsages() async {
        guard let apiKey = SettingsManager.shared.kimiAPIKey,
              !apiKey.isEmpty else {
            invalidateForMissingKey()
            return
        }

        guard !isRefreshing else { return }
        isRefreshing = true

        defer {
            isRefreshing = false
        }

        var request = URLRequest(url: usagesURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw http.statusCode == 401 || http.statusCode == 403
                    ? KimiAPIError.unauthorized
                    : KimiAPIError.httpError(http.statusCode)
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw KimiAPIError.decodeError
            }
            let parsed = KimiUsageParser.parse(body: json)
            guard !parsed.isEmpty else {
                throw KimiAPIError.emptyData
            }
            windows = parsed
            lastError = nil
            lastUpdated = Date()
            saveCachedUsages(data)
            notifyStateChange()
        } catch let error as KimiAPIError {
            lastError = error.localizedDescription
            notifyStateChange()
        } catch {
            lastError = KimiAPIError.networkError(error).localizedDescription
            notifyStateChange()
        }
    }

    // MARK: - MonitoredSource 协议实现

    var sourceID: String { "kimi" }

    var displayName: String { "Kimi" }

    /// 下拉面板区块头部使用 Kimi 品牌 Logo（与设置卡片一致）
    var logoImageName: String? { "KimiLogo" }

    var snapshot: SourceSnapshot? {
        guard !windows.isEmpty else { return nil }
        return .quota(makeQuotaSnapshot())
    }

    /// MonitoredSource 协议要求的统一刷新入口（手动/自动语义一致：无 Key 静默跳过）
    func refresh(force: Bool) async {
        await fetchUsages()
    }

    // MARK: - 快照构造

    /// 把解析后的配额窗口转换为通用配额快照（复用 Zenmux 的区块渲染）
    private func makeQuotaSnapshot() -> QuotaSnapshot {
        let maxPercent = windows.map(\.usedPercent).max() ?? 0
        return QuotaSnapshot(
            title: "Kimi Code",
            status: mapStatus(maxPercent),
            expiryText: nil,
            windows: windows.map(makeWindowData),
            extraMetrics: []
        )
    }

    private func makeWindowData(_ window: KimiQuotaWindow) -> QuotaWindowData {
        let isSession = window.kind == .session
        // /coding/v1/usages 端点为整数粒度（limit=100 单位，最小步进 1%），
        // 不足 1% 的消耗会被服务端取整为 0：优先展示绝对单位数（不受取整误导），
        // 有消耗但不足 1% 时标注 <1%
        let usedText: String
        if let used = window.used, let limit = window.limit, limit > 0 {
            let base = "已用 \(formatNum(used))/\(formatNum(limit)) 单位"
            usedText = (used > 0 && used < 1) ? base + "（<1%）" : base
        } else if window.usedPercent > 0 && window.usedPercent < 1 {
            usedText = "已用 <1%"
        } else {
            usedText = String(format: "已用 %.0f%%", window.usedPercent)
        }
        return QuotaWindowData(
            id: isSession ? "5h" : "7d",
            label: isSession ? "5H" : "7D",
            icon: isSession ? "clock" : "calendar",
            pct: min(max(window.usedPercent / 100, 0), 1),
            usedText: usedText,
            usedUSDText: nil,
            resetsAt: window.resetsAt,
            windowDuration: window.windowDuration ?? (isSession ? 5 * 3600 : 7 * 24 * 3600),
            projectedPct: nil,
            // 整数粒度源（limit=100 整数单位）：百分比恒为整数，
            // 直接显示整数格式（"25%"），避免 "25.00%" 的伪精度
            percentText: String(format: "%.0f%%", window.usedPercent)
        )
    }

    /// 按最高窗口用量映射状态：<50% 正常 / <80% 监控中 / <100% 已限制 / ≥100% 已暂停
    private func mapStatus(_ maxPercent: Double) -> StatusIndicator {
        if maxPercent >= 100 { return .suspended }
        if maxPercent >= 80 { return .limited }
        if maxPercent >= 50 { return .warning }
        return .healthy
    }

    private func formatNum(_ v: Double) -> String {
        v >= 10000 ? String(format: "%.2fk", v / 1000)
                   : String(format: "%.0f", v)
    }
}

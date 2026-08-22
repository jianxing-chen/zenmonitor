//
//  ZhipuAPIService.swift
//  zenmux-monitor
//
//  智谱 GLM Coding Plan 配额查询 API 客户端
//  接口：GET https://open.bigmodel.cn/api/monitor/usage/quota/limit
//
//  说明：该端点为控制台内部监控接口（未收录于官方文档），由 cc-switch /
//  glm-usage 等开源项目长期实证可用；与 Coding Plan 推理共用同一把 Key。
//  鉴权为裸 Key（Authorization 头不加 Bearer 前缀，与推理接口不同）。
//  返回 5 小时滚动频控与每周限额两个配额窗口（2026-02-12 起仅百分比）。
//  响应字段可能漂移，解析由 ZhipuUsageParser 做防御式兼容。
//

import Foundation
import Observation

enum ZhipuAPIError: LocalizedError {
    case noAPIKey
    case networkError(Error)
    case unauthorized
    case httpError(Int)
    case decodeError
    case emptyData
    /// 业务级错误：服务端 success=false，透传 msg（如账号未订阅 Coding Plan）
    case businessError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "未设置智谱 API Key，请在设置中配置"
        case .networkError(let err):
            return "智谱网络错误: \(err.localizedDescription)"
        case .unauthorized:
            return "智谱鉴权失败，请检查 API Key 是否有效（需 Coding Plan 专用 Key）"
        case .httpError(let code):
            return "智谱 HTTP 错误: \(code)"
        case .decodeError:
            return "智谱数据解析失败"
        case .emptyData:
            return "智谱未返回配额数据"
        case .businessError(let msg):
            return "智谱: \(msg)"
        }
    }
}

@MainActor
@Observable
final class ZhipuAPIService: MonitoredSource {
    static let shared = ZhipuAPIService()

    /// 国内版控制台监控端点（host 常量化，未来支持国际版 z.ai 只需加域名选项）
    private let quotaURL = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
    private let cacheKey = "zhipu_cached_usages"
    private let cacheUpdatedKey = "zhipu_cached_updated"

    /// 最近一次成功解析的配额窗口
    private(set) var windows: [ZhipuQuotaWindow] = []
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
        let parsed = ZhipuUsageParser.parse(body: json)
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
        guard let apiKey = SettingsManager.shared.zhipuAPIKey,
              !apiKey.isEmpty else {
            invalidateForMissingKey()
            return
        }

        guard !isRefreshing else { return }
        isRefreshing = true

        defer {
            isRefreshing = false
        }

        var request = URLRequest(url: quotaURL)
        request.httpMethod = "GET"
        // 注意：该监控端点鉴权为裸 Key，不加 Bearer 前缀
        // （与智谱推理接口不同，cc-switch / glm-usage 两个独立实现均确认）
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw http.statusCode == 401 || http.statusCode == 403
                    ? ZhipuAPIError.unauthorized
                    : ZhipuAPIError.httpError(http.statusCode)
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw ZhipuAPIError.decodeError
            }
            // 业务级失败（如账号未订阅 Coding Plan）时透传服务端 msg，
            // 便于用户在面板/设置卡片看到真实原因而非笼统的「无数据」
            let result = ZhipuUsageParser.parseWithMessage(json)
            guard !result.windows.isEmpty else {
                throw result.message.map { ZhipuAPIError.businessError($0) } ?? ZhipuAPIError.emptyData
            }
            windows = result.windows
            lastError = nil
            lastUpdated = Date()
            saveCachedUsages(data)
            notifyStateChange()
        } catch let error as ZhipuAPIError {
            lastError = error.localizedDescription
            notifyStateChange()
        } catch {
            lastError = ZhipuAPIError.networkError(error).localizedDescription
            notifyStateChange()
        }
    }

    // MARK: - MonitoredSource 协议实现

    var sourceID: String { "zhipu" }

    var displayName: String { "智谱 GLM" }

    /// 下拉面板区块头部使用智谱品牌 Logo（与设置卡片一致）
    var logoImageName: String? { "ZhipuLogo" }

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
            title: "GLM Coding Plan",
            status: mapStatus(maxPercent),
            expiryText: nil,
            windows: windows.map(makeWindowData),
            extraMetrics: []
        )
    }

    private func makeWindowData(_ window: ZhipuQuotaWindow) -> QuotaWindowData {
        let isSession = window.kind == .session
        // 2026-02-12 起端点仅返回百分比（无 Token 绝对值），文案只承载百分比；
        // 有消耗但不足 1% 时标注 <1%（与全局百分比展示规范一致）
        let usedText: String
        if window.usedPercent > 0 && window.usedPercent < 1 {
            usedText = "已用 <1%"
        } else {
            usedText = String(format: "已用 %.1f%%", window.usedPercent)
        }
        return QuotaWindowData(
            id: isSession ? "5h" : "7d",
            label: isSession ? "5H" : "7D",
            icon: isSession ? "clock" : "calendar",
            pct: min(max(window.usedPercent / 100, 0), 1),
            usedText: usedText,
            usedUSDText: nil,
            resetsAt: window.resetsAt,
            windowDuration: isSession ? 5 * 3600 : 7 * 24 * 3600,
            projectedPct: nil,
            percentText: nil
        )
    }

    /// 按最高窗口用量映射状态：<50% 正常 / <80% 监控中 / <100% 已限制 / ≥100% 已暂停
    /// （与 Kimi 同语义：GLM 5 小时窗口同为硬性频控，打满后请求会被真实拒绝）
    private func mapStatus(_ maxPercent: Double) -> StatusIndicator {
        if maxPercent >= 100 { return .suspended }
        if maxPercent >= 80 { return .limited }
        if maxPercent >= 50 { return .warning }
        return .healthy
    }
}

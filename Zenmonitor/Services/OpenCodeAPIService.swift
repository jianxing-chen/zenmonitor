//
//  OpenCodeAPIService.swift
//  zenmux-monitor
//
//  OpenCode Go 用量查询 API 客户端
//  接口：GET https://opencode.ai/zen/go/v1/usage
//
//  说明：OpenCode Go 是 opencode 官方的开源模型订阅网关
//  （$5 首月 / $10/月，限额按美元价值：5h $12 / 周 $30 / 月 $60）。
//  用量端点与推理共用同一把 API Key，标准 Bearer 认证。
//  响应为三窗口浮点配额（5h/周/月）+ 精确重置时间（ISO8601 含时区偏移），
//  字段防御式解析由 OpenCodeUsageParser 承担。
//

import Foundation
import Observation
import SwiftUI

enum OpenCodeAPIError: LocalizedError {
    case noAPIKey
    case networkError(Error)
    case unauthorized
    case httpError(Int)
    case decodeError
    case emptyData
    /// 业务级错误：响应体携带错误信息时透传（如订阅不存在）
    case businessError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "未设置 OpenCode API Key，请在设置中配置"
        case .networkError(let err):
            return "OpenCode 网络错误: \(err.localizedDescription)"
        case .unauthorized:
            return "OpenCode 鉴权失败，请检查 API Key 是否有效（需 Go 订阅的 Key）"
        case .httpError(let code):
            return "OpenCode HTTP 错误: \(code)"
        case .decodeError:
            return "OpenCode 数据解析失败"
        case .emptyData:
            return "OpenCode 未返回用量数据"
        case .businessError(let msg):
            return "OpenCode: \(msg)"
        }
    }
}

@MainActor
@Observable
final class OpenCodeAPIService: MonitoredSource {
    static let shared = OpenCodeAPIService()

    private let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    private let cacheKey = "opencode_cached_usages"
    private let cacheUpdatedKey = "opencode_cached_updated"

    /// 最近一次成功解析的配额窗口
    private(set) var windows: [OpenCodeQuotaWindow] = []
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
        let parsed = OpenCodeUsageParser.parse(body: json)
        guard !parsed.isEmpty else { return }
        windows = parsed
        lastUpdated = UserDefaults.standard.object(forKey: cacheUpdatedKey) as? Date
    }

    private func saveCachedUsages(_ raw: Data) {
        UserDefaults.standard.set(raw, forKey: cacheKey)
        UserDefaults.standard.set(lastUpdated, forKey: cacheUpdatedKey)
    }

    /// Key 已删除/未配置：清空数据与缓存。
    /// 设置界面删除/更换 Key 时直接调用，无需等下次拉取即生效。
    func invalidateForMissingKey() {
        windows = []
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: cacheUpdatedKey)
        lastError = nil
        lastUpdated = nil
        notifyStateChange()
    }

    // MARK: - 请求

    /// 拉取用量。无 Key 时静默置空（不报错），用户未配置时菜单不显示该区块。
    func fetchUsage() async {
        guard let apiKey = SettingsManager.shared.opencodeAPIKey,
              !apiKey.isEmpty else {
            invalidateForMissingKey()
            return
        }

        guard !isRefreshing else { return }
        isRefreshing = true

        defer {
            isRefreshing = false
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        // 标准 Bearer 认证（与推理接口共用同一把 Key）
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw OpenCodeAPIError.unauthorized
                }
                throw OpenCodeAPIError.httpError(http.statusCode)
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw OpenCodeAPIError.decodeError
            }
            // 业务级错误透传：响应携带 error 对象（如 {"type":"error","error":{"message":...}}）
            if let errObj = json["error"] as? [String: Any],
               let msg = errObj["message"] as? String, !msg.isEmpty {
                throw OpenCodeAPIError.businessError(msg)
            }
            let parsed = OpenCodeUsageParser.parse(body: json)
            guard !parsed.isEmpty else {
                throw OpenCodeAPIError.emptyData
            }
            windows = parsed
            lastError = nil
            lastUpdated = Date()
            saveCachedUsages(data)
            notifyStateChange()
        } catch let error as OpenCodeAPIError {
            lastError = error.localizedDescription
            notifyStateChange()
        } catch {
            lastError = OpenCodeAPIError.networkError(error).localizedDescription
            notifyStateChange()
        }
    }

    // MARK: - MonitoredSource 协议实现

    var sourceID: String { "opencode" }

    var displayName: String { "OpenCode" }

    /// 下拉面板区块头部使用 OpenCode 品牌 Logo（与设置卡片一致）
    var logoImageName: String? { "OpenCodeLogo" }

    var snapshot: SourceSnapshot? {
        guard !windows.isEmpty else { return nil }
        return .quota(makeQuotaSnapshot())
    }

    /// MonitoredSource 协议要求的统一刷新入口（手动/自动语义一致：无 Key 静默跳过）
    func refresh(force: Bool) async {
        await fetchUsage()
    }

    // MARK: - 快照构造

    /// 把解析后的配额窗口转换为通用配额快照（三窗口：5H / 7D / 1M）
    private func makeQuotaSnapshot() -> QuotaSnapshot {
        let maxPercent = windows.map(\.usedPercent).max() ?? 0
        return QuotaSnapshot(
            title: "OpenCode Go",
            status: mapStatus(maxPercent),
            expiryText: nil,
            windows: windows.map(makeWindowData),
            extraMetrics: []
        )
    }

    private func makeWindowData(_ window: OpenCodeQuotaWindow) -> QuotaWindowData {
        let (id, label, icon, duration): (String, String, String, TimeInterval)
        switch window.kind {
        case .rolling: (id, label, icon, duration) = ("5h", "5H", "clock", 5 * 3600)
        case .weekly:  (id, label, icon, duration) = ("7d", "7D", "calendar", 7 * 24 * 3600)
        case .monthly: (id, label, icon, duration) = ("1m", "1M", "calendar", 30 * 24 * 3600)
        }
        let usedText: String
        if window.usedPercent > 0 && window.usedPercent < 1 {
            usedText = "已用 <1%"
        } else {
            usedText = String(format: "已用 %.1f%%", window.usedPercent)
        }
        return QuotaWindowData(
            id: id,
            label: label,
            icon: icon,
            pct: min(max(window.usedPercent / 100, 0), 1),
            usedText: usedText,
            usedUSDText: nil,
            resetsAt: window.resetsAt,
            windowDuration: duration,
            projectedPct: nil,
            percentText: nil
        )
    }

    /// 三档精简：仅最高窗口打满（5h 硬频控真实生效）才标已暂停；用量水位由进度条颜色表达
    private func mapStatus(_ maxPercent: Double) -> StatusIndicator {
        maxPercent >= 100 ? .suspended : .healthy
    }
}

//
//  StepFunAPIService.swift
//  zenmux-monitor
//
//  StepFun Step Plan 用量查询 API 客户端
//  接口：GET {host}/step_plan/v1/usage
//    国内站 host = https://api.stepfun.com，海外站 host = https://api.stepfun.ai
//    （两站独立账号与订阅体系、Key 互不通用；端点路径与响应结构一致，
//     端点选择跟随 SettingsManager.stepfunRegion）
//
//  说明：该端点未收录于公开 API 参考，但由官方 Step Code 客户端依赖，
//  响应带 schema_version 契约（见 StepFunModels 注释）。认证与推理接口
//  共用同一把 Step API Key，标准 Bearer，无需 OAuth。
//
//  展示范围（按产品决定）：
//  - 当前 Token Plan 的月池额度（subscription 桶）：已用 % + 剩余/总量 + 重置时间
//  - quota.state = partial 时给出数据完整性提示
//  - 老 Coding Plan 的 5H/周额度双窗口不做展示，仅提示不支持
//

import Foundation
import Observation
import SwiftUI

enum StepFunAPIError: LocalizedError {
    case networkError(Error)
    case unauthorized
    case httpError(Int)
    case decodeError
    case parseError(String)
    case notSubscribed
    case unsupportedFamily

    var errorDescription: String? {
        switch self {
        case .networkError(let err):
            return "StepFun 网络错误: \(err.localizedDescription)"
        case .unauthorized:
            return "StepFun 鉴权失败，请检查 API Key 是否有效（需 Step Plan 订阅的 Key）"
        case .httpError(let code):
            return "StepFun HTTP 错误: \(code)"
        case .decodeError:
            return "StepFun 数据解析失败"
        case .parseError(let msg):
            return "StepFun: \(msg)"
        case .notSubscribed:
            return "StepFun 未检测到 Step Plan 订阅"
        case .unsupportedFamily:
            return "当前为老 Coding Plan（5H/周额度），暂不支持展示"
        }
    }
}

@MainActor
@Observable
final class StepFunAPIService: MonitoredSource {
    static let shared = StepFunAPIService()

    /// 用量端点：域名跟随站点选择（国内 / 海外），
    /// 两站路径与响应结构一致，仅 host 不同
    private var usageURL: URL { SettingsManager.shared.stepfunRegion.usageURL }
    private let cacheKey = "stepfun_cached_usage"
    private let cacheUpdatedKey = "stepfun_cached_updated"

    /// 最近一次成功解析的用量
    private(set) var usage: StepFunPlanUsage?
    /// 缓存的快照：数据变化时构建一次（避免状态栏/面板高频读取时重建）
    private(set) var snapshot: SourceSnapshot?
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
              let parsed = try? StepFunUsageParser.parse(body: json) else { return }
        usage = parsed
        lastUpdated = UserDefaults.standard.object(forKey: cacheUpdatedKey) as? Date
        snapshot = makeQuotaSnapshot(parsed)
    }

    private func saveCachedUsage(_ raw: Data) {
        UserDefaults.standard.set(raw, forKey: cacheKey)
        UserDefaults.standard.set(lastUpdated, forKey: cacheUpdatedKey)
    }

    /// Key 已删除/未配置：清空数据与缓存。
    /// 已处于干净态时直接返回，避免自动定时器每 tick 重复清理 + 触发重渲染
    func invalidateForMissingKey() {
        guard usage != nil || lastError != nil || lastUpdated != nil || snapshot != nil else { return }
        usage = nil
        snapshot = nil
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: cacheUpdatedKey)
        lastError = nil
        lastUpdated = nil
        notifyStateChange()
    }

    // MARK: - 请求

    /// 拉取用量。无 Key 时静默置空（不报错），用户未配置时菜单不显示该区块。
    func fetchUsage() async {
        guard let apiKey = SettingsManager.shared.stepfunAPIKey,
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
                    throw StepFunAPIError.unauthorized
                }
                throw StepFunAPIError.httpError(http.statusCode)
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw StepFunAPIError.decodeError
            }
            let parsed: StepFunPlanUsage
            do {
                parsed = try StepFunUsageParser.parse(body: json)
            } catch let error as StepFunParseError {
                throw StepFunAPIError.parseError(error.localizedDescription)
            }
            guard parsed.planState == "known", parsed.family != .none else {
                throw StepFunAPIError.notSubscribed
            }
            guard parsed.family == .token else {
                throw StepFunAPIError.unsupportedFamily
            }

            usage = parsed
            lastError = nil
            lastUpdated = Date()
            snapshot = makeQuotaSnapshot(parsed)
            saveCachedUsage(data)
            notifyStateChange()
        } catch let error as StepFunAPIError {
            lastError = error.localizedDescription
            notifyStateChange()
        } catch {
            lastError = StepFunAPIError.networkError(error).localizedDescription
            notifyStateChange()
        }
    }

    // MARK: - MonitoredSource 协议实现

    var sourceID: String { "stepfun" }

    var displayName: String { "StepFun" }

    /// 面板区块与设置卡片共用 StepFun 品牌 Logo
    var logoImageName: String? { "StepFunLogo" }

    /// 统一刷新入口（手动/自动语义一致：无 Key 静默跳过）
    func refresh(force: Bool) async {
        await fetchUsage()
    }

    // MARK: - 快照构造

    /// Token Plan 的主额度桶：优先月池（subscription），缺失时回退首个受支持的桶。
    /// 加油包（topup）按产品决定不单列，因此不参与窗口构建。
    private func primaryBucket(_ usage: StepFunPlanUsage) -> StepFunCreditBucket? {
        let supported = usage.creditBuckets.filter { !$0.unsupported }
        return supported.first { $0.type == "subscription" } ?? supported.first
    }

    private func makeQuotaSnapshot(_ usage: StepFunPlanUsage) -> SourceSnapshot? {
        guard let bucket = primaryBucket(usage) else { return nil }

        let window = makeWindowData(bucket)
        var metrics: [MetricCard] = []

        // 数据完整性：partial 表示部分额度桶取数失败，不能当成 0 展示
        if usage.quotaState == "partial" {
            metrics.append(MetricCard(
                title: "数据完整性",
                value: "部分缺失",
                detail: "部分额度桶取数失败",
                icon: "exclamationmark.triangle",
                tint: .orange
            ))
        }

        // 额度不可用时只由头部状态灯表达（红点「已暂停」），
        // 不再额外占用一张指标卡 —— 面板保持精简
        return .quota(QuotaSnapshot(
            title: "Step Plan",
            status: usage.allowed ? .healthy : .suspended,
            expiryText: expiryText(usage.subscriptionExpiresAt),
            windows: [window],
            extraMetrics: metrics
        ))
    }

    private func makeWindowData(_ bucket: StepFunCreditBucket) -> QuotaWindowData {
        let period = monthlyPeriod(bucket)
        let remainingText = StepFunFormat.credits(bucket.remaining)
        let totalText = StepFunFormat.credits(bucket.total)

        let usedText: String
        let pct: Double
        let percentText: String?
        if let used = bucket.usedPercent {
            usedText = "剩余 \(remainingText) / \(totalText) Credits"
            pct = min(max(used / 100, 0), 1)
            percentText = nil
        } else {
            // 服务端未给百分比（含总量为 0 的桶）：不伪造 0%，直接标注不可用
            usedText = "剩余 \(remainingText) Credits"
            pct = 0
            percentText = "—"
        }

        return QuotaWindowData(
            id: "1m",
            label: "1M",
            icon: "calendar",
            pct: pct,
            usedText: usedText,
            usedUSDText: nil,
            resetsAt: period.resetsAt,
            windowDuration: period.duration,
            projectedPct: nil,
            percentText: percentText
        )
    }

    /// 时间进度标记的窗口区间：终点 = 月池下次清零时间，起点按自然月倒推。
    ///
    /// 该端点只给终点、不给周期起点；而 Token Plan 的 Credit 恒按月发放
    /// （月付/季付/年付一致），故起点按自然月倒推是准确的。
    /// resets_at_ms 缺失时不画标记 —— 宁可不显示，也不猜测一个假区间。
    private func monthlyPeriod(_ bucket: StepFunCreditBucket) -> (resetsAt: Date?, duration: TimeInterval) {
        guard let end = bucket.resetsAt, end > Date() else { return (nil, 0) }
        let start = Calendar.current.date(byAdding: .month, value: -1, to: end)
            ?? end.addingTimeInterval(-30 * 24 * 3600)
        let duration = end.timeIntervalSince(start)
        return duration > 0 ? (end, duration) : (nil, 0)
    }

    private func expiryText(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return "到期 " + formatter.string(from: date)
    }
}

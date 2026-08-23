//
//  DeepSeekAPIService.swift
//  zenmux-monitor
//
//  DeepSeek 余额查询 API 客户端
//  接口：GET https://api.deepseek.com/user/balance
//
//  设计：余额变化低频，采用「菜单打开时拉取 + 整点静默采样」策略；
//  整点采样用于本地余额差值统计今日用量（DeepSeekUsageStore），
//  不接入 ProcessMonitor 条件刷新，开销可忽略。
//

import Foundation
import Observation

enum DeepSeekAPIError: LocalizedError {
    case invalidURL
    case noAPIKey
    case networkError(Error)
    case httpError(Int)
    case decodeError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 API 地址"
        case .noAPIKey:
            return "未设置 DeepSeek API Key，请在设置中配置"
        case .networkError(let err):
            return "DeepSeek 网络错误: \(err.localizedDescription)"
        case .httpError(let code):
            return "DeepSeek HTTP 错误: \(code)"
        case .decodeError(let err):
            return "DeepSeek 数据解析失败: \(err.localizedDescription)"
        }
    }
}

@MainActor
@Observable
final class DeepSeekAPIService: MonitoredSource {
    static let shared = DeepSeekAPIService()

    private let baseURL = URL(string: "https://api.deepseek.com/user/balance")!
    private let cacheKey = "deepseek_cached_balance"

    /// 今日用量本地统计（余额差值推算）
    private let usageStore = DeepSeekUsageStore()

    /// 最近一次成功获取的余额数据
    var balanceData: DeepSeekBalanceResponse?
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
        restoreCachedBalance()
        startHourlySampling()
    }

    // MARK: - 整点采样（今日用量统计）

    /// 对齐到下一个整点后，每小时静默拉取一次余额。
    /// 整点采样保证 00:00 后首次采样即建立新日基线，精确区分日期。
    /// 未配置 Key 时 fetchBalance 内部静默跳过，无额外开销。
    private func startHourlySampling() {
        Task { [weak self] in
            while !Task.isCancelled {
                let delay = Self.secondsUntilNextHour()
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                await self.fetchBalance()
            }
        }
    }

    /// 距下一个整点的秒数（1~3600）
    private static func secondsUntilNextHour() -> TimeInterval {
        let comps = Calendar.current.dateComponents([.minute, .second], from: Date())
        let elapsed = (comps.minute ?? 0) * 60 + (comps.second ?? 0)
        return TimeInterval(3600 - elapsed)
    }

    // MARK: - 缓存恢复/保存

    /// 启动时从 UserDefaults 恢复上次余额，使首次打开菜单即有数据、布局高度正确。
    private func restoreCachedBalance() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data) else { return }
        balanceData = decoded
        lastUpdated = UserDefaults.standard.object(forKey: "deepseek_cached_updated") as? Date
    }

    private func saveCachedBalance() {
        guard let data = try? JSONEncoder().encode(balanceData) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
        UserDefaults.standard.set(lastUpdated, forKey: "deepseek_cached_updated")
    }

    // MARK: - 请求

    /// Key 已删除/未配置：清空余额数据、缓存与用量采样历史。
    /// 设置界面删除 Key 时直接调用，无需等下次拉取即生效。
    func invalidateForMissingKey() {
        if balanceData != nil { balanceData = nil }
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: "deepseek_cached_updated")
        lastError = nil
        usageStore.reset()
        notifyStateChange()
    }

    /// 拉取余额。无 Key 时静默置空（不报错），便于用户未配置时菜单不显示该区块。
    func fetchBalance() async {
        guard let apiKey = SettingsManager.shared.deepseekAPIKey,
              !apiKey.isEmpty else {
            // 未配置 Key：清空数据与缓存，不当作错误
            invalidateForMissingKey()
            return
        }

        guard !isRefreshing else { return }
        isRefreshing = true

        defer {
            isRefreshing = false
        }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw DeepSeekAPIError.httpError(http.statusCode)
            }
            let decoded = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
            balanceData = decoded
            lastError = nil
            lastUpdated = Date()
            saveCachedBalance()
            // 采样入账：记录当前余额用于今日用量差值统计（Key 更换时 store 自动清空历史）
            if let info = decoded.balance_infos.first {
                usageStore.record(total: info.total, keyFingerprint: DeepSeekUsageStore.fingerprint(of: apiKey))
            }
            notifyStateChange()
        } catch let error as DeepSeekAPIError {
            lastError = error.localizedDescription
            notifyStateChange()
        } catch {
            lastError = DeepSeekAPIError.networkError(error).localizedDescription
            notifyStateChange()
        }
    }

    // MARK: - MonitoredSource 协议实现

    var sourceID: String { "deepseek" }

    var displayName: String { "DeepSeek" }

    var logoImageName: String? { "DeepSeekLogo" }

    var snapshot: SourceSnapshot? {
        guard let data = balanceData, !data.balance_infos.isEmpty else { return nil }
        return .balance(makeBalanceSnapshot(from: data))
    }

    /// MonitoredSource 协议要求的统一刷新入口（手动/自动语义一致：无 Key 静默跳过）
    /// 注：今日用量的整点采样（startHourlySampling）为独立统计链路，与此处无关
    func refresh(force: Bool) async {
        await fetchBalance()
    }

    /// 把 DeepSeek 原始余额数据转换为通用余额快照
    private func makeBalanceSnapshot(from data: DeepSeekBalanceResponse) -> BalanceSnapshot {
        // 取第一个币种（通常 CNY）；多币种场景后续可扩展为多行展示
        let info = data.balance_infos[0]
        var snapshot = BalanceSnapshot(
            title: "DeepSeek 余额",
            currencySymbol: info.symbol,
            total: String(format: "%.2f", info.total),
            breakdown: [
                (label: "赠金", value: String(format: "%.2f", info.granted)),
                (label: "充值", value: String(format: "%.2f", info.toppedUp))
            ],
            status: data.is_available ? .healthy : .suspended
        )
        // 今日用量：本地余额差值推算，无当日采样记录时保持 nil（UI 不渲染该行）
        if let stats = usageStore.todayStats() {
            snapshot.todayUsageText = info.symbol + String(format: "%.2f", stats.usage)
            snapshot.todayUsageDetail = "自 \(Self.hourMinuteFmt.string(from: stats.since)) 起"
        }
        return snapshot
    }

    private static let hourMinuteFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}

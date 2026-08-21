//
//  ArkAPIService.swift
//  zenmux-monitor
//
//  火山方舟 Agent Plan 配额查询 API 客户端
//  接口：POST https://open.volcengineapi.com/?Action=GetAFPUsage&Version=2024-01-01
//
//  认证：火山引擎 V4 签名（HMAC-SHA256 派生密钥链，AWS SigV4 变体），
//  凭据为账号级 AccessKey/SecretKey（IAM 控制台创建），
//  非 ark- 开头的推理 API Key——两者不通用。
//
//  注意：控制面签名请求必须走统一 OpenAPI 网关 open.volcengineapi.com；
//  ark.cn-beijing.volces.com 仅接受 Bearer 推理请求，签名请求会被拒（401）。
//
//  设计：与 Kimi/DeepSeek 一致，「菜单打开时拉取」策略，不做后台轮询。
//

import Foundation
import Observation
import CryptoKit

enum ArkAPIError: LocalizedError {
    case noCredentials
    case networkError(Error)
    case unauthorized
    case httpError(Int)
    case decodeError
    case emptyData

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "未设置火山引擎 AccessKey/SecretKey，请在设置中配置"
        case .networkError(let err):
            return "火山方舟网络错误: \(err.localizedDescription)"
        case .unauthorized:
            return "火山方舟鉴权失败，请检查 AK/SK 是否有效"
        case .httpError(let code):
            return "火山方舟 HTTP 错误: \(code)"
        case .decodeError:
            return "火山方舟数据解析失败"
        case .emptyData:
            return "火山方舟未返回配额数据"
        }
    }
}

@MainActor
@Observable
final class ArkAPIService: MonitoredSource {
    static let shared = ArkAPIService()

    // 控制面 OpenAPI 统一网关（实测：签名请求只有此域名返回 200；
    // ark.cn-beijing.volces.com 仅接受 Bearer 推理请求，签名请求 401）
    private let host = "open.volcengineapi.com"
    private let action = "GetAFPUsage"
    private let version = "2024-01-01"
    private let region = "cn-beijing"
    private let service = "ark"
    private let cacheKey = "ark_cached_usages"
    private let cacheUpdatedKey = "ark_cached_updated"

    /// 最近一次成功解析的 AFP 窗口
    private(set) var windows: [ArkAFPWindow] = []
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
        let parsed = ArkUsageParser.parse(body: json)
        guard !parsed.isEmpty else { return }
        windows = parsed
        lastUpdated = UserDefaults.standard.object(forKey: cacheUpdatedKey) as? Date
    }

    private func saveCachedUsages(_ raw: Data) {
        UserDefaults.standard.set(raw, forKey: cacheKey)
        UserDefaults.standard.set(lastUpdated, forKey: cacheUpdatedKey)
    }

    /// 凭据已删除/未配置：清空数据与缓存。
    /// 设置界面删除凭据时直接调用，无需等下次拉取即生效。
    func invalidateForMissingCredentials() {
        windows = []
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: cacheUpdatedKey)
        lastError = nil
        lastUpdated = nil
        notifyStateChange()
    }

    // MARK: - 请求

    /// 拉取 AFP 配额。无凭据时静默置空（不报错），用户未配置时菜单不显示该区块。
    func fetchUsages() async {
        let settings = SettingsManager.shared
        guard let accessKey = settings.arkAccessKey, !accessKey.isEmpty,
              let secretKey = settings.arkSecretKey, !secretKey.isEmpty else {
            invalidateForMissingCredentials()
            return
        }

        guard !isRefreshing else { return }
        isRefreshing = true

        defer {
            isRefreshing = false
        }

        do {
            let request = try makeSignedRequest(accessKey: accessKey, secretKey: secretKey)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw http.statusCode == 401 || http.statusCode == 403
                    ? ArkAPIError.unauthorized
                    : ArkAPIError.httpError(http.statusCode)
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw ArkAPIError.decodeError
            }
            // 官方错误响应带 ResponseMetadata.Error（如签名错误也返回 200 之外的状态码）
            if let meta = json["ResponseMetadata"] as? [String: Any], meta["Error"] != nil {
                throw ArkAPIError.decodeError
            }
            let parsed = ArkUsageParser.parse(body: json)
            guard !parsed.isEmpty else {
                throw ArkAPIError.emptyData
            }
            windows = parsed
            lastError = nil
            lastUpdated = Date()
            saveCachedUsages(data)
            notifyStateChange()
        } catch let error as ArkAPIError {
            lastError = error.localizedDescription
            notifyStateChange()
        } catch {
            lastError = ArkAPIError.networkError(error).localizedDescription
            notifyStateChange()
        }
    }

    // MARK: - 火山 V4 签名

    /// 构造带 V4 签名的请求。
    /// 签名结构（官方示例：Authorization: HMAC-SHA256 Credential=.../{date}/cn-beijing/ark/request）：
    ///   CanonicalRequest = METHOD\nURI\nQUERY\nCanonicalHeaders\n\nSignedHeaders\nHashedPayload
    ///   StringToSign = HMAC-SHA256\n{X-Date}\n{Scope}\nHexSHA256(CanonicalRequest)
    ///   SigningKey = HMAC(HMAC(HMAC(HMAC(SK, date), region), service), "request")
    private func makeSignedRequest(accessKey: String, secretKey: String) throws -> URLRequest {
        let url = URL(string: "https://\(host)/?Action=\(action)&Version=\(version)")!
        let body = "{}"
        let bodyData = Data(body.utf8)

        // UTC 时间：X-Date=yyyyMMddTHHmmssZ，scope 日期=yyyyMMdd
        let now = Date()
        let xDate = Self.xDateFmt.string(from: now)
        let dateStamp = Self.dateStampFmt.string(from: now)

        let hashedBody = Self.hexSHA256(bodyData)
        let scope = "\(dateStamp)/\(region)/\(service)/request"

        // Canonical 头按字母序：host < x-content-sha256 < x-date（与官方示例 SignedHeaders 一致）
        let signedHeaders = "host;x-content-sha256;x-date"
        let canonicalHeaders = """
        host:\(host)
        x-content-sha256:\(hashedBody)
        x-date:\(xDate)

        """

        let canonicalRequest = """
        POST
        /
        Action=\(action)&Version=\(version)
        \(canonicalHeaders)
        \(signedHeaders)
        \(hashedBody)
        """

        let stringToSign = """
        HMAC-SHA256
        \(xDate)
        \(scope)
        \(Self.hexSHA256(Data(canonicalRequest.utf8)))
        """

        // 派生签名密钥链
        let kDate = Self.hmacSHA256(key: Data(secretKey.utf8), data: Data(dateStamp.utf8))
        let kRegion = Self.hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = Self.hmacSHA256(key: kRegion, data: Data(service.utf8))
        let kSigning = Self.hmacSHA256(key: kService, data: Data("request".utf8))
        let signature = Self.hex(Self.hmacSHA256(key: kSigning, data: Data(stringToSign.utf8)))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = 15
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(xDate, forHTTPHeaderField: "X-Date")
        request.setValue(hashedBody, forHTTPHeaderField: "X-Content-Sha256")
        request.setValue(
            "HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private static let xDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private static let dateStampFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private static func hexSHA256(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    private static func hmacSHA256(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - MonitoredSource 协议实现

    var sourceID: String { "ark" }

    var displayName: String { "火山方舟" }

    /// 下拉面板区块头部使用火山引擎品牌 Logo（与设置卡片一致）
    var logoImageName: String? { "VolcanoArkLogo" }

    var snapshot: SourceSnapshot? {
        guard !windows.isEmpty else { return nil }
        return .quota(makeQuotaSnapshot())
    }

    /// MonitoredSource 协议要求的统一刷新入口（手动/自动语义一致：无 AK/SK 静默跳过）
    func refresh(force: Bool) async {
        await fetchUsages()
    }

    // MARK: - 快照构造

    /// 把解析后的 AFP 窗口转换为通用配额快照（复用 Zenmux/Kimi 的区块渲染）
    private func makeQuotaSnapshot() -> QuotaSnapshot {
        // 1D 日窗口实测无有意义数据（AFPDaily 恒为 0），服务层跳过；
        // 解析器保留 1D 解析能力，未来该窗口有数据时去掉此过滤即可恢复
        let visible = windows.filter { $0.label != "1D" }
        let maxPercent = visible.map(\.usedPercent).max() ?? 0
        return QuotaSnapshot(
            title: "方舟 Agent Plan",
            status: mapStatus(maxPercent),
            expiryText: nil,
            windows: visible.map(makeWindowData),
            extraMetrics: []
        )
    }

    private func makeWindowData(_ window: ArkAFPWindow) -> QuotaWindowData {
        QuotaWindowData(
            id: window.label.lowercased(),
            label: window.label,
            icon: windowIcon(window.label),
            pct: min(max(window.usedPercent / 100, 0), 1),
            usedText: "已用 \(formatNum(window.used))/\(formatNum(window.quota)) AFP",
            usedUSDText: nil,
            resetsAt: window.resetTime,
            windowDuration: windowDuration(window.label),
            projectedPct: nil
        )
    }

    /// 状态点语义：GetAFPUsage 响应不含账户状态字段，无法判断「受限/暂停」；
    /// 用量高低已由进度条颜色三档表达，状态点仅反映数据完整性，
    /// 避免高用量（如 5H 87%）被误标为「已限制」（实测 API 仍可正常调用）
    private func mapStatus(_ maxPercent: Double) -> StatusIndicator {
        maxPercent > 0 ? .healthy : .unknown
    }

    private func windowIcon(_ label: String) -> String {
        switch label {
        case "5H": return "clock"
        case "1D": return "sun.max"
        case "7D": return "calendar"
        default: return "calendar.badge.clock"
        }
    }

    /// 窗口时长（秒）：供 QuotaRow 时间进度三角形计算（月度按 30 天近似）
    private func windowDuration(_ label: String) -> TimeInterval {
        switch label {
        case "5H": return 5 * 3600
        case "1D": return 24 * 3600
        case "7D": return 7 * 24 * 3600
        default: return 30 * 24 * 3600
        }
    }

    private func formatNum(_ v: Double) -> String {
        v >= 10000 ? String(format: "%.2fk", v / 1000)
                   : String(format: "%.1f", v)
    }
}

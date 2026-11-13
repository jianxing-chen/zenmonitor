//
//  QianwenAPIService.swift
//  zenmux-monitor
//
//  千问 AI Token Plan 用量查询 API 客户端
//  链路（2026-11-13 全链路实测，与官方 bl usage token-plan 同构）：
//  1. 阿里云 AK/SK → ACS3-HMAC-SHA256 签名 →
//     POST https://modelstudio.cn-beijing.aliyuncs.com/modelstudio/cli/generateAccessToken
//     → 临时 cliAccessToken（内存缓存，NotLogined 时自动刷新重试）
//  2. Bearer token → POST https://cs-data.qianwenai.com/cli/api.json（控制台网关）
//     → per* 配额窗口（解析见 QianwenUsageParser）
//  3. 首次遇到 Team.NotAuthorised 时自动执行业务空间授权
//     （官方 workspace init 步骤 0-5，不含任何计费开通操作）：
//     loginInfo → CreateUser → ListWorkspaces → ChangeUserPermissions
//
//  凭据要求：阿里云 RAM 子账号 AK/SK，需授予 AliyunModelStudioFullAccess
//  （ReadOnly 策略不含 Generate*，会一直 403）。套餐 sk-sp- Key 查不了该网关。
//  签名算法逐行对齐官方 modelstudioai/cli 的 packages/core/src/client/acs.ts。
//

import Foundation
import Observation
import CryptoKit

enum QianwenAPIError: LocalizedError {
    case networkError(Error)
    /// 换 token 被拒（403 等），附 RAM 策略提示
    case tokenDenied(String)
    case httpError(Int)
    case decodeError
    case emptyData
    case businessError(String)
    case workspaceAuthFailed(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let err):
            return "千问网络错误: \(err.localizedDescription)"
        case .tokenDenied(let detail):
            return "千问换 token 失败: \(detail)（RAM 子账号需 AliyunModelStudioFullAccess 策略）"
        case .httpError(let code):
            return "千问 HTTP 错误: \(code)"
        case .decodeError:
            return "千问数据解析失败"
        case .emptyData:
            return "千问未返回配额数据"
        case .businessError(let msg):
            return "千问: \(msg)"
        case .workspaceAuthFailed(let msg):
            return "千问业务空间授权失败: \(msg)"
        }
    }
}

@MainActor
@Observable
final class QianwenAPIService: MonitoredSource {
    static let shared = QianwenAPIService()

    // MARK: - 端点（均为官方域名，来源：官方 CLI 源码 + 实测验证）

    private let tokenHost = "modelstudio.cn-beijing.aliyuncs.com"
    private let tokenPath = "/modelstudio/cli/generateAccessToken"
    private let controlHost = "bailiancontrol.cn-beijing.aliyuncs.com"
    private let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    private let loginAPI = "zeldaEasy.cornerstone-portal.cs-console.loginInfo"

    private let cacheKey = "qianwen_cached_usage"
    private let cacheUpdatedKey = "qianwen_cached_updated"

    /// 最近一次成功解析的配额窗口
    private(set) var windows: [QianwenQuotaWindow] = []
    /// 缓存的快照：数据变化时构建一次（状态栏/面板高频读取时零分配）
    private(set) var snapshot: SourceSnapshot?
    /// 最近一次错误文案（成功后清空）
    var lastError: String?
    /// 最近一次成功更新时间
    private(set) var lastUpdated: Date?
    /// 是否正在请求
    private(set) var isRefreshing = false

    /// MonitoredSource 协议：状态变化回调（AppDelegate 用于刷新状态栏项）
    @ObservationIgnored var onStateChange: (@MainActor () -> Void)?

    /// 临时 token 仅存内存：短时效敏感凭据，不落盘；启动后首次刷新重新签发
    @ObservationIgnored private var cachedToken: String?
    /// 空间授权每凭据周期只尝试一次，避免失败循环
    @ObservationIgnored private var workspaceAuthAttempted = false

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
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let parsed = QianwenUsageParser.parse(body: json)
        guard !parsed.isEmpty else { return }
        windows = parsed
        lastUpdated = UserDefaults.standard.object(forKey: cacheUpdatedKey) as? Date
        snapshot = .quota(makeQuotaSnapshot())
    }

    private func saveCachedUsage(_ raw: Data) {
        UserDefaults.standard.set(raw, forKey: cacheKey)
        UserDefaults.standard.set(lastUpdated, forKey: cacheUpdatedKey)
    }

    /// 凭据已删除/未配置：清空数据、缓存与内存 token。
    /// 已处于干净态时直接返回，避免自动定时器每 tick 重复清理 + 触发重渲染
    func invalidateForMissingCredentials() {
        cachedToken = nil
        workspaceAuthAttempted = false
        guard !windows.isEmpty || lastError != nil || lastUpdated != nil || snapshot != nil else { return }
        windows = []
        snapshot = nil
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: cacheUpdatedKey)
        lastError = nil
        lastUpdated = nil
        notifyStateChange()
    }

    // MARK: - MonitoredSource 协议实现

    var sourceID: String { "qianwen" }

    var displayName: String { "千问" }

    /// 面板区块与设置卡片共用千问品牌 Logo
    var logoImageName: String? { "QianwenLogo" }

    /// 统一刷新入口（手动/自动语义一致：无凭据静默跳过）
    func refresh(force: Bool) async {
        await fetchUsage()
    }

    // MARK: - 请求主流程

    /// 拉取用量。无凭据时静默置空（不报错），用户未配置时菜单不显示该区块。
    func fetchUsage() async {
        guard let ak = SettingsManager.shared.qianwenAccessKey, !ak.isEmpty,
              let sk = SettingsManager.shared.qianwenSecretKey, !sk.isEmpty else {
            invalidateForMissingCredentials()
            return
        }

        guard !isRefreshing else { return }
        isRefreshing = true

        defer {
            isRefreshing = false
        }

        do {
            let data = try await fetchUsageData(ak: ak, sk: sk)
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw QianwenAPIError.decodeError
            }
            let parsed = QianwenUsageParser.parse(body: json)
            guard !parsed.isEmpty else {
                throw QianwenAPIError.emptyData
            }
            windows = parsed
            lastError = nil
            lastUpdated = Date()
            snapshot = .quota(makeQuotaSnapshot())
            saveCachedUsage(data)
            notifyStateChange()
        } catch let error as QianwenAPIError {
            lastError = error.localizedDescription
            notifyStateChange()
        } catch {
            lastError = QianwenAPIError.networkError(error).localizedDescription
            notifyStateChange()
        }
    }

    /// 带 token 刷新与空间授权重试的用量请求
    private func fetchUsageData(ak: String, sk: String) async throws -> Data {
        var token = try await ensureToken(ak: ak, sk: sk)
        var (data, json) = try await queryUsage(token: token)

        // token 过期：重新签发并重试一次
        if gatewayErrorCode(json) == "BailianGateway.Login.NotLogined" {
            cachedToken = nil
            token = try await ensureToken(ak: ak, sk: sk)
            (data, json) = try await queryUsage(token: token)
        }

        // RAM 子账号未进业务空间：自动授权一次后重试
        if gatewayErrorCode(json) == "BailianGateway.Team.NotAuthorised", !workspaceAuthAttempted {
            workspaceAuthAttempted = true
            do {
                try await authorizeWorkspace(ak: ak, sk: sk, token: token)
            } catch {
                // 授权失败不锁死：下一轮刷新可重试（瞬时网络错误等）
                workspaceAuthAttempted = false
                throw error
            }
            // 授权后换新 token 再查（与实测脚本一致，避免服务端缓存旧授权状态）
            cachedToken = nil
            token = try await ensureToken(ak: ak, sk: sk)
            (data, json) = try await queryUsage(token: token)
        }

        if let code = gatewayErrorCode(json) {
            let msg = ((json["data"] as? [String: Any])?["errorMsg"] as? String) ?? code
            throw QianwenAPIError.businessError(msg)
        }
        return data
    }

    /// 网关业务错误码（data.success == false 时取 errorCode）
    private func gatewayErrorCode(_ json: [String: Any]) -> String? {
        guard let data = json["data"] as? [String: Any],
              let success = data["success"] as? Bool, !success else { return nil }
        return (data["errorCode"] as? String) ?? "Unknown"
    }

    // MARK: - token 签发（ACS3-HMAC-SHA256）

    private func ensureToken(ak: String, sk: String) async throws -> String {
        if let cachedToken { return cachedToken }
        let headers = acsSignedHeaders(
            ak: ak, sk: sk, host: tokenHost, path: tokenPath,
            action: "GenerateCLIAccessToken", version: "2026-02-10",
            method: "POST", body: Data(), queryPairs: [])
        var request = URLRequest(url: URL(string: "https://\(tokenHost)\(tokenPath)")!)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = Data()
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // 403 多为 RAM 策略缺失：提取被拒动作辅助定位
            var detail = "HTTP \(http.statusCode)"
            if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let denied = json["AccessDeniedDetail"] as? [String: Any],
               let action = denied["AuthAction"] as? String {
                detail = "缺少 \(action) 权限"
            }
            throw QianwenAPIError.tokenDenied(detail)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = json["cliAccessToken"] as? String, !token.isEmpty else {
            throw QianwenAPIError.decodeError
        }
        cachedToken = token
        return token
    }

    // MARK: - 用量查询（控制台网关）

    private func queryUsage(token: String) async throws -> (Data, [String: Any]) {
        try await gatewayCall(api: usageAPI, token: token)
    }

    /// 控制台网关统一调用（cs-data.qianwenai.com，QIANWENAI 站）
    private func gatewayCall(api: String, token: String) async throws -> (Data, [String: Any]) {
        var comps = URLComponents(string: "https://cs-data.qianwenai.com/cli/api.json")!
        comps.queryItems = [
            URLQueryItem(name: "action", value: "BroadScopeAspnGateway"),
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "api", value: api)
        ]
        let params: [String: Any] = [
            "Api": api,
            "V": "1.0",
            "Data": [
                "cornerstoneParam": [
                    "protocol": "V2",
                    "console": "ONE_CONSOLE",
                    "productCode": "p_efm",
                    "switchUserType": 3,
                    "consoleSite": "QIANWENAI"
                ] as [String: Any]
            ] as [String: Any]
        ]
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        let paramsStr = String(data: paramsData, encoding: .utf8) ?? "{}"
        var bodyComps = URLComponents()
        bodyComps.queryItems = [
            URLQueryItem(name: "params", value: paramsStr),
            URLQueryItem(name: "region", value: "cn-beijing")
        ]

        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data((bodyComps.percentEncodedQuery ?? "").utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw QianwenAPIError.httpError(http.statusCode)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QianwenAPIError.decodeError
        }
        return (data, json)
    }

    // MARK: - 业务空间授权（官方 workspace init 步骤 0-5，跳过计费开通）

    /// RAM 子账号首次查用量会返回 Team.NotAuthorised：
    /// 需为其创建控制台用户并加入默认业务空间。全流程幂等，绑定 RAM 用户 UID，
    /// 与 AK/SK 本身无关（轮换 Key 不影响已完成的授权）。
    private func authorizeWorkspace(ak: String, sk: String, token: String) async throws {
        // 1. loginInfo → RAM 用户 uid
        let (_, loginJSON) = try await gatewayCall(api: loginAPI, token: token)
        guard let uid = findString(forKey: "uid", in: loginJSON), !uid.isEmpty else {
            throw QianwenAPIError.workspaceAuthFailed("无法获取账号 uid")
        }

        // 2. CreateUser（幂等：已存在则继续）
        let createPayload = ["data": jsonString(["reqDTO": ["outerKey": uid,
                                                           "nickName": uid,
                                                           "userName": uid]])]
        let (createStatus, createJSON) = try await controlCall(
            ak: ak, sk: sk, action: "CreateUser",
            path: "/bailianControl/User/createUser", method: "POST", payload: createPayload)
        let createMsg = jsonString(createJSON)
        if createStatus != 200,
           !createMsg.lowercased().contains("already exists"),
           !createMsg.contains("已存在") {
            throw QianwenAPIError.workspaceAuthFailed("CreateUser HTTP \(createStatus)")
        }

        // 3. ListWorkspaces → 默认空间 agentId（tenantId）
        let listQuery = jsonString(["reqDTO": [String: Any](), "cornerstoneParam": [String: Any]()])
        let (listStatus, listJSON) = try await controlCall(
            ak: ak, sk: sk, action: "ListWorkspaces",
            path: "/bailianControl/workspaces", method: "GET", queryPairs: [("data", listQuery)])
        guard listStatus == 200, let workspaces = findWorkspaceArray(listJSON), !workspaces.isEmpty else {
            throw QianwenAPIError.workspaceAuthFailed("无法列出业务空间（HTTP \(listStatus)）")
        }
        let chosen = workspaces.first { ($0["defaultAgent"] as? Bool) == true } ?? workspaces[0]
        let agentId: Int
        switch chosen["tenantId"] {
        case let n as Int:    agentId = n
        case let n as Double: agentId = Int(n)
        case let s as String: agentId = Int(s) ?? -1
        default:              agentId = -1
        }
        guard agentId > 0 else {
            throw QianwenAPIError.workspaceAuthFailed("无法解析空间 tenantId")
        }

        // 4. ChangeUserPermissions（policyIndexList=[1]，官方默认代理策略）
        let resetPayload = ["data": jsonString(["cornerstoneParam": [String: Any](),
                                                "outerKey": uid,
                                                "policyIndexList": [1],
                                                "agentId": agentId])]
        let (resetStatus, resetJSON) = try await controlCall(
            ak: ak, sk: sk, action: "ChangeUserPermissions",
            path: "/bailianControl/serviserAuthorityPolicy/resetPolicies4Agent",
            method: "POST", payload: resetPayload)
        let resetSuccess = (resetJSON["success"] as? Bool) == true
            || ((resetJSON["data"] as? Bool) == true)
        guard resetStatus == 200, resetSuccess else {
            throw QianwenAPIError.workspaceAuthFailed("ChangeUserPermissions HTTP \(resetStatus)")
        }
    }

    /// bailiancontrol OpenAPI 调用（ROA 风格，version 2024-08-16，AK/SK ACS3 签名）
    private func controlCall(ak: String, sk: String, action: String, path: String,
                             method: String, payload: [String: Any]? = nil,
                             queryPairs: [(String, String)] = []) async throws -> (Int, [String: Any]) {
        let bodyData: Data
        if let payload {
            bodyData = try JSONSerialization.data(withJSONObject: payload)
        } else {
            bodyData = Data()
        }
        let headers = acsSignedHeaders(
            ak: ak, sk: sk, host: controlHost, path: path,
            action: action, version: "2024-08-16",
            method: method, body: bodyData, queryPairs: queryPairs)
        var urlStr = "https://\(controlHost)\(path)"
        if !queryPairs.isEmpty {
            let query = queryPairs.sorted { $0.0 < $1.0 }
                .map { "\(rfc3986($0.0))=\(rfc3986($0.1))" }
                .joined(separator: "&")
            urlStr += "?" + query
        }
        var request = URLRequest(url: URL(string: urlStr)!)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if method == "POST" { request.httpBody = bodyData }
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    // MARK: - ACS3-HMAC-SHA256 签名（对齐官方 acs.ts）

    private func acsSignedHeaders(ak: String, sk: String, host: String, path: String,
                                  action: String, version: String, method: String,
                                  body: Data, queryPairs: [(String, String)]) -> [String: String] {
        let hashedBody = sha256Hex(body)
        var headers: [String: String] = [
            "host": host,
            "x-acs-action": action,
            "x-acs-version": version,
            "x-acs-date": Self.acsDateFormatter.string(from: Date()),
            "x-acs-signature-nonce": UUID().uuidString,
            "x-acs-content-sha256": hashedBody,
            "content-type": "application/json"
        ]
        let signedKeys = headers.keys
            .filter { $0 == "host" || $0 == "content-type" || $0.hasPrefix("x-acs-") }
            .sorted()
        let canonicalHeaders = signedKeys.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeadersStr = signedKeys.joined(separator: ";")
        let canonicalQuery = queryPairs.sorted { $0.0 < $1.0 }
            .map { "\(rfc3986($0.0))=\(rfc3986($0.1))" }
            .joined(separator: "&")
        let canonicalRequest = [method, path, canonicalQuery, canonicalHeaders,
                                signedHeadersStr, hashedBody].joined(separator: "\n")
        let stringToSign = "ACS3-HMAC-SHA256\n" + sha256Hex(Data(canonicalRequest.utf8))
        let key = SymmetricKey(data: Data(sk.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        let signature = mac.map { String(format: "%02x", $0) }.joined()
        headers["authorization"] =
            "ACS3-HMAC-SHA256 Credential=\(ak),SignedHeaders=\(signedHeadersStr),Signature=\(signature)"
        return headers
    }

    /// 共享日期格式化器（ACS3 要求 ISO8601 UTC 秒级，无毫秒）
    private static let acsDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// RFC3986 编码（仅保留 unreserved 字符，对齐官方 encodeRFC3986）
    private func rfc3986(_ string: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    // MARK: - 通用工具

    private func jsonString(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    /// 递归查找字符串/数值字段（uid 可能为 String 或 Int）
    private func findString(forKey key: String, in obj: Any) -> String? {
        if let dict = obj as? [String: Any] {
            if let value = dict[key] {
                if let s = value as? String { return s }
                if let n = value as? Int { return String(n) }
                if let n = value as? Double { return String(Int(n)) }
            }
            for value in dict.values {
                if let found = findString(forKey: key, in: value) { return found }
            }
        } else if let array = obj as? [Any] {
            for item in array {
                if let found = findString(forKey: key, in: item) { return found }
            }
        }
        return nil
    }

    /// 递归查找工作空间数组（首个元素含 tenantId 的字典数组）
    private func findWorkspaceArray(_ obj: Any) -> [[String: Any]]? {
        if let dict = obj as? [String: Any] {
            for value in dict.values {
                if let array = value as? [[String: Any]], array.first?["tenantId"] != nil {
                    return array
                }
                if let found = findWorkspaceArray(value) { return found }
            }
        } else if let array = obj as? [Any] {
            for item in array {
                if let found = findWorkspaceArray(item) { return found }
            }
        }
        return nil
    }

    // MARK: - 快照构造

    private func makeQuotaSnapshot() -> QuotaSnapshot {
        let maxPercent = windows.map(\.usedPercent).max() ?? 0
        return QuotaSnapshot(
            title: "千问Plan",
            status: maxPercent >= 100 ? .suspended : .healthy,
            expiryText: nil,
            windows: windows.map(makeWindowData),
            extraMetrics: []
        )
    }

    private func makeWindowData(_ window: QianwenQuotaWindow) -> QuotaWindowData {
        let duration: TimeInterval
        if let fixed = window.fixedDuration {
            duration = fixed
        } else if let reset = window.resetsAt, reset > Date() {
            // 月度窗口：Credit 恒按月发放，起点按自然月从重置时间倒推
            let start = Calendar.current.date(byAdding: .month, value: -1, to: reset)
                ?? reset.addingTimeInterval(-30 * 24 * 3600)
            duration = max(reset.timeIntervalSince(start), 1)
        } else {
            duration = 0
        }
        return QuotaWindowData(
            id: window.id,
            label: window.label,
            icon: window.icon,
            pct: min(max(window.usedPercent / 100, 0), 1),
            usedText: String(format: "已用 %.1f%%", window.usedPercent),
            usedUSDText: nil,
            // duration 为 0 时不传 resetsAt：时间标记会除零，宁可不画
            resetsAt: duration > 0 ? window.resetsAt : nil,
            windowDuration: duration,
            projectedPct: nil,
            percentText: nil
        )
    }
}

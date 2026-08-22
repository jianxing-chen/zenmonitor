//
//  SettingsManager.swift
//  zenmux-monitor
//
//  应用设置管理器
//  所有配置均使用 UserDefaults 持久化
//

import Foundation

extension Notification.Name {
    /// 状态栏显示开关变更（设置面板 Toggle 触发），AppDelegate 监听后重建状态栏项
    static let statusBarSettingsChanged = Notification.Name("ZenmonitorStatusBarSettingsChanged")
}

/// Zenmux API 可用域名。Zenmux 同时提供 zenmux.ai 与 zenmux.dev 两个入口，
/// 用户可在设置中切换，便于在不同网络环境/区域下选择可达的域名。
enum ZenmuxAPIDomain: String, CaseIterable, Codable {
    case zenmuxAI = "zenmux.ai"
    case zenmuxDEV = "zenmux.dev"

    /// 对应控制台页面 URL（用于设置中的外链）
    var consoleURL: URL { URL(string: "https://\(rawValue)/platform/management")! }

    /// 对应 subscription detail 接口完整 URL
    var subscriptionDetailURL: URL {
        URL(string: "https://\(rawValue)/api/v1/management/subscription/detail")!
    }
}

/// 智谱 GLM 所属平台。国内版（bigmodel.cn）与国际版（z.ai）为独立账号体系，
/// API Key 互不通用，需使用对应平台的 Key；两平台的监控端点路径与响应结构一致。
enum ZhipuRegion: String, CaseIterable, Codable {
    case domestic = "bigmodel.cn"
    case international = "z.ai"

    /// 配额监控端点 host（两平台共用路径 /api/monitor/usage/quota/limit）
    var quotaHost: String {
        switch self {
        case .domestic:       return "https://open.bigmodel.cn"
        case .international:  return "https://api.z.ai"
        }
    }

    /// 对应平台的 Key 管理页（用于设置中的外链）
    var consoleURL: URL {
        switch self {
        case .domestic:       return URL(string: "https://bigmodel.cn/usercenter/proj-mgmt/apikeys")!
        case .international:  return URL(string: "https://z.ai/manage-apikey/apikey-list")!
        }
    }
}

final class SettingsManager {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let apiKey = "api_key"
        static let refreshInterval = "refresh_interval"
        static let launchAtLogin = "launch_at_login"
        static let cachedSubscriptionData = "cached_subscription_data"
        static let cachedLastUpdated = "cached_last_updated"
        static let deepseekAPIKey = "deepseek_api_key"
        static let kimiAPIKey = "kimi_api_key"
        static let zhipuAPIKey = "zhipu_api_key"
        static let zhipuRegion = "zhipu_region"
        static let arkAccessKey = "ark_access_key"
        static let arkSecretKey = "ark_secret_key"
        static let statusBarPrefix = "statusbar_enabled_"
        static let menuOrder = "menu_source_order"
        static let apiDomain = "api_domain"
    }

    /// 刷新间隔下限（秒）。低于此值会触发忙循环与高频请求，写入时强制钳制。
    static let minRefreshInterval: TimeInterval = 10

    private init() {
        defaults.register(defaults: [
            Keys.refreshInterval: 60.0,
        ])
    }

    // MARK: - API Key

    var apiKey: String? {
        get { defaults.string(forKey: Keys.apiKey) }
        set {
            let previousValue = defaults.string(forKey: Keys.apiKey)
            defaults.set(newValue, forKey: Keys.apiKey)

            if previousValue != newValue {
                clearCachedSubscriptionSnapshot()
            }
        }
    }

    // MARK: - API 域名

    /// Zenmux API 域名选择，默认 zenmux.ai。切换后立即生效（下次刷新走新域名）。
    var apiDomain: ZenmuxAPIDomain {
        get {
            if let raw = defaults.string(forKey: Keys.apiDomain),
               let value = ZenmuxAPIDomain(rawValue: raw) {
                return value
            }
            return .zenmuxAI
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.apiDomain) }
    }

    // MARK: - DeepSeek API Key

    /// DeepSeek 平台 API Key（sk-...），用于查询余额。与 Zenmux Management Key 独立。
    var deepseekAPIKey: String? {
        get { defaults.string(forKey: Keys.deepseekAPIKey) }
        set { defaults.set(newValue, forKey: Keys.deepseekAPIKey) }
    }

    // MARK: - Kimi Code API Key

    /// Kimi Code API Key（sk-kimi-...），与推理共用同一把 Key，用于查询订阅配额。
    /// 与 Zenmux / DeepSeek Key 相互独立。
    var kimiAPIKey: String? {
        get { defaults.string(forKey: Keys.kimiAPIKey) }
        set { defaults.set(newValue, forKey: Keys.kimiAPIKey) }
    }

    /// 智谱开放平台 API Key（GLM Coding Plan 专用 Key，与推理共用），
    /// 用于查询控制台监控端点的订阅配额。与其他源 Key 相互独立。
    var zhipuAPIKey: String? {
        get { defaults.string(forKey: Keys.zhipuAPIKey) }
        set { defaults.set(newValue, forKey: Keys.zhipuAPIKey) }
    }

    /// 智谱平台选择，默认国内版。切换后需使用对应平台的 Key（两者不通用），
    /// 服务层下次刷新即走新平台端点。
    var zhipuRegion: ZhipuRegion {
        get {
            if let raw = defaults.string(forKey: Keys.zhipuRegion),
               let value = ZhipuRegion(rawValue: raw) {
                return value
            }
            return .domestic
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.zhipuRegion) }
    }

    // MARK: - 火山方舟 AK/SK

    /// 火山引擎账号级 AccessKey（IAM 控制台创建），用于控制面 OpenAPI 的 V4 签名。
    /// 注意：非 ark- 开头的推理 API Key，两者不通用。
    var arkAccessKey: String? {
        get { defaults.string(forKey: Keys.arkAccessKey) }
        set { defaults.set(newValue, forKey: Keys.arkAccessKey) }
    }

    /// 火山引擎账号级 SecretKey，与 arkAccessKey 配对使用
    var arkSecretKey: String? {
        get { defaults.string(forKey: Keys.arkSecretKey) }
        set { defaults.set(newValue, forKey: Keys.arkSecretKey) }
    }

    // MARK: - 状态栏显示开关

    /// 某源是否在菜单栏拥有独立状态栏项。
    /// 默认仅 Zenmux 开启（保持历史行为）；显式设置过的值优先。
    func statusBarEnabled(for sourceID: String) -> Bool {
        if let stored = defaults.object(forKey: Keys.statusBarPrefix + sourceID) as? Bool {
            return stored
        }
        return sourceID == "zenmux"
    }

    func setStatusBarEnabled(_ enabled: Bool, for sourceID: String) {
        defaults.set(enabled, forKey: Keys.statusBarPrefix + sourceID)
    }

    // MARK: - 下拉面板区块排序

    /// 用户自定义的源排序（sourceID 列表）；从未设置过时返回 nil，
    /// 由调用方回退注册表默认顺序（Zenmux → DeepSeek → Kimi）
    var storedMenuOrder: [String]? {
        defaults.stringArray(forKey: Keys.menuOrder)
    }

    /// 下拉面板区块排序（完整且合法）：以用户自定义顺序为主，
    /// 过滤已不存在的源、补齐未列入的新源（追加到尾部），
    /// 保证任意时刻返回值与注册表源集一致
    func menuOrder(registrySources: [String]) -> [String] {
        let stored = storedMenuOrder ?? []
        var ordered = stored.filter { registrySources.contains($0) }
        for id in registrySources where !ordered.contains(id) {
            ordered.append(id)
        }
        return ordered
    }

    func setMenuOrder(_ order: [String]) {
        defaults.set(order, forKey: Keys.menuOrder)
    }

    // MARK: - UserDefaults 操作

    var refreshInterval: TimeInterval {
        get { max(Self.minRefreshInterval, defaults.double(forKey: Keys.refreshInterval)) }
        set { defaults.set(max(Self.minRefreshInterval, newValue), forKey: Keys.refreshInterval) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    var cachedSubscriptionData: ZenmuxSubscriptionData? {
        get {
            guard let data = defaults.data(forKey: Keys.cachedSubscriptionData) else {
                return nil
            }
            return try? JSONDecoder().decode(ZenmuxSubscriptionData.self, from: data)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Keys.cachedSubscriptionData)
                return
            }

            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.cachedSubscriptionData)
            }
        }
    }

    var cachedLastUpdated: Date? {
        get { defaults.object(forKey: Keys.cachedLastUpdated) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.cachedLastUpdated)
            } else {
                defaults.removeObject(forKey: Keys.cachedLastUpdated)
            }
        }
    }

    func clearCachedSubscriptionSnapshot() {
        defaults.removeObject(forKey: Keys.cachedSubscriptionData)
        defaults.removeObject(forKey: Keys.cachedLastUpdated)
    }
}

//
//  SettingsManager.swift
//  zenmux-monitor
//
//  应用设置管理器
//  所有配置均使用 UserDefaults 持久化
//

import Foundation

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

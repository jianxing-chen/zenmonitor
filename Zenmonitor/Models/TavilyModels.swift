//
//  TavilyModels.swift
//  zenmux-monitor
//
//  Tavily 用量数据模型与解析器
//  对应 GET https://api.tavily.com/usage 响应（官方 API Reference 收录）。
//
//  响应为 key/account 双信封：
//  - key：单 Key 维度的本计费周期 credits 消耗与限额
//  - account：账户套餐（current_plan/plan_usage/plan_limit/paygo）维度
//  展示以 account 套餐维度为主，account 缺失时回退 key 维度。
//  字段漂移时解析返回 nil，由服务层展示错误而不是渲染假数据。
//

import Foundation

/// 端点消耗明细条目（Search / Extract / Crawl / Map / Research）
struct TavilyEndpointUsage {
    let name: String
    let used: Double
}

/// 归一化后的用量信息（纯值类型，解析逻辑见 TavilyUsageParser）
struct TavilyUsageInfo {
    /// 套餐名称（如 Researcher / Bootstrap）
    let planName: String?
    /// 本计费周期已用 credits（账户套餐维度，回退单 Key 维度）
    let used: Double
    /// 配额上限（nil = 无限制）
    let limit: Double?
    /// 超额按量（pay-as-you-go）已用次数
    let paygoUsage: Double?
    /// 超额按量上限
    let paygoLimit: Double?
    /// 各端点消耗明细
    let endpoints: [TavilyEndpointUsage]
}

// MARK: - 解析器

/// `GET /usage` 防御式解析器。
///
/// 官方 OpenAPI 形态：
/// ```
/// { "key": { "usage": 150, "limit": 1000, "search_usage": 100, ... },
///   "account": { "current_plan": "Bootstrap", "plan_usage": 500,
///                "plan_limit": 15000, "paygo_usage": 25, "paygo_limit": 100,
///                "search_usage": 350, ... } }
/// ```
/// 所有数值字段兼容字符串数字；`limit` 允许 null（无限制套餐）。
enum TavilyUsageParser {

    /// 端点明细字段 → 展示名（按官方五类端点）
    private static let endpointKeys: [(key: String, name: String)] = [
        ("search_usage", "Search"),
        ("extract_usage", "Extract"),
        ("crawl_usage", "Crawl"),
        ("map_usage", "Map"),
        ("research_usage", "Research")
    ]

    /// 解析响应体；无法解析（缺少数值主线）返回 nil
    static func parse(body: [String: Any]) -> TavilyUsageInfo? {
        let account = body["account"] as? [String: Any]
        let key = body["key"] as? [String: Any]

        // 主维度：账户套餐；回退：单 Key 维度
        let used = pickNumber(account, keys: ["plan_usage", "planUsage"])
            ?? pickNumber(key, keys: ["usage", "used"])
        guard let used else { return nil }

        let limit = pickNumber(account, keys: ["plan_limit", "planLimit"])
            ?? pickNumber(key, keys: ["limit", "quota"])
        let planName = pickString(account, keys: ["current_plan", "currentPlan", "plan"])

        // 端点明细：账户维度优先，回退 Key 维度
        let source = account ?? key
        let endpoints = endpointKeys.compactMap { entry -> TavilyEndpointUsage? in
            guard let value = pickNumber(source, keys: [entry.key]) else { return nil }
            return TavilyEndpointUsage(name: entry.name, used: value)
        }

        return TavilyUsageInfo(
            planName: planName.isEmpty ? nil : planName,
            used: used,
            limit: limit,
            paygoUsage: pickNumber(account, keys: ["paygo_usage", "paygoUsage"]),
            paygoLimit: pickNumber(account, keys: ["paygo_limit", "paygoLimit"]),
            endpoints: endpoints
        )
    }

    // MARK: - 通用取值

    /// 按键名顺序取第一个数值（兼容字符串数字）；显式 null 返回 nil
    private static func pickNumber(_ obj: [String: Any]?, keys: [String]) -> Double? {
        guard let obj else { return nil }
        for key in keys {
            if let value = obj[key] {
                if value is NSNull { return nil }
                if let number = value as? Double { return number }
                if let number = value as? Int { return Double(number) }
                if let text = value as? String, let number = Double(text.trimmingCharacters(in: .whitespaces)) {
                    return number
                }
            }
        }
        return nil
    }

    private static func pickString(_ obj: [String: Any]?, keys: [String]) -> String {
        guard let obj else { return "" }
        for key in keys {
            if let text = obj[key] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text
            }
        }
        return ""
    }
}

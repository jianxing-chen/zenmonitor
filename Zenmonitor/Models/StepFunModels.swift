//
//  StepFunModels.swift
//  zenmux-monitor
//
//  StepFun Step Plan 用量数据模型与解析器
//  对应 GET https://api.stepfun.com/step_plan/v1/usage
//
//  说明：该端点未收录于公开 API 参考，但由官方 Step Code 客户端
//  （stepfun-ai/Step-Code）依赖并有显式契约 —— 响应必须携带
//  `schema_version: 1`，否则客户端拒绝解析。字段定义取自其
//  packages/coding-agent/src/step/usage/types.ts。
//
//  两类套餐族结构不同：
//  - coding（老 Coding Plan）：quota.windows[] 恰好两条，5H + 周额度
//  - token（当前 Token Plan）：quota.windows 为空，额度在 quota.credit_buckets[]
//

import Foundation

// MARK: - 套餐族

/// Step Plan 套餐族。决定额度信息落在 windows 还是 credit_buckets。
enum StepFunPlanFamily: String {
    case coding     // 老 Coding Plan：5H 滚动频控 + 周额度
    case token      // 当前 Token Plan：月度 Credit 月池（+ 加油包）
    case none       // 未订阅
}

// MARK: - 配额窗口（coding 族）

/// coding 族的单个频控窗口（five_hour / weekly）。
struct StepFunUsageWindow {
    /// 窗口标识："five_hour" / "weekly"
    let id: String
    /// false 表示上游不限量（此时 usedPercent 必为 nil）
    let limited: Bool
    /// 已用百分比 0~100
    let usedPercent: Double?
    /// 重置时间
    let resetsAt: Date?
}

// MARK: - Credit 桶（token 族）

/// token 族的单个 Credit 桶：subscription = 月池，topup = 加油包。
struct StepFunCreditBucket {
    /// "subscription"（月池）/ "topup"（加油包）；未知类型标记 unsupported
    let type: String
    /// 总量（十进制字符串，Credits）。量级可达 40,000M，禁止用浮点参与运算
    let total: String
    /// 剩余量（十进制字符串，Credits）
    let remaining: String
    /// 已用百分比 0~100；nil 表示服务端未给出（含总量为 0 的桶）
    let usedPercent: Double?
    /// 月池清零时间
    let resetsAt: Date?
    /// 加油包到期时间
    let expiresAt: Date?
    /// 未知桶类型：不参与展示，避免把不认识的额度当成 0
    let unsupported: Bool
}

// MARK: - 解析结果

/// 归一化后的 Step Plan 用量快照（纯值类型，不含网络逻辑）。
struct StepFunPlanUsage {
    /// plan.state："known" / "unavailable"
    let planState: String
    /// 套餐族
    let family: StepFunPlanFamily
    /// 套餐档位名，如 "Pro"
    let planName: String?
    /// 订阅到期时间
    let subscriptionExpiresAt: Date?
    /// quota.state："known" / "partial"（partial = 部分额度桶取数失败）
    let quotaState: String
    /// 额度是否可用；false 时调用会被拒绝
    let allowed: Bool
    /// 不可用原因（allowed=false 时可能有）
    let reason: String?
    /// coding 族窗口
    let windows: [StepFunUsageWindow]
    /// token 族 Credit 桶
    let creditBuckets: [StepFunCreditBucket]
    /// 服务端观测时间
    let observedAt: Date?
}

// MARK: - 解析错误

enum StepFunParseError: LocalizedError {
    /// schema_version 不是 1（官方客户端同样拒绝未知版本）
    case unsupportedSchema(Int?)
    /// 顶层结构缺失或并非本接口响应
    case malformed

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "StepFun 接口版本不支持（schema_version = \(version.map(String.init) ?? "无")）"
        case .malformed:
            return "StepFun 响应结构异常"
        }
    }
}

// MARK: - 解析器

/// `GET /step_plan/v1/usage` 防御式解析器。
///
/// 与官方客户端的强校验保持一致的门槛只有两条：`schema_version == 1`、
/// `scope == "personal_account"`；其余字段尽量宽容，字段漂移时宁可少显示
/// 也不要整卡空白。
enum StepFunUsageParser {

    static func parse(body: [String: Any]) throws -> StepFunPlanUsage {
        guard number(body["schema_version"]).map({ Int($0) }) == 1 else {
            throw StepFunParseError.unsupportedSchema(number(body["schema_version"]).map { Int($0) })
        }
        guard (body["scope"] as? String) == "personal_account" else {
            throw StepFunParseError.malformed
        }

        let plan = body["plan"] as? [String: Any] ?? [:]
        let quota = body["quota"] as? [String: Any] ?? [:]

        let family = StepFunPlanFamily(rawValue: plan["family"] as? String ?? "none") ?? .none

        var subscriptionExpiresAt: Date?
        if let sub = plan["subscription"] as? [String: Any] {
            subscriptionExpiresAt = date(millis: sub["expires_at_ms"])
        }

        let windows = (quota["windows"] as? [[String: Any]] ?? []).compactMap { raw -> StepFunUsageWindow? in
            guard let id = raw["id"] as? String, ["five_hour", "weekly"].contains(id) else { return nil }
            let limited = raw["limited"] as? Bool ?? false
            let pct = number(raw["used_percent"])
            return StepFunUsageWindow(
                id: id,
                limited: limited,
                usedPercent: pct,
                resetsAt: date(millis: raw["resets_at_ms"])
            )
        }

        let buckets = (quota["credit_buckets"] as? [[String: Any]] ?? []).map { raw -> StepFunCreditBucket in
            let type = raw["type"] as? String ?? ""
            let supported = (type == "subscription" || type == "topup")
            return StepFunCreditBucket(
                type: type,
                total: decimalString(raw["total"]),
                remaining: decimalString(raw["remaining"]),
                usedPercent: number(raw["used_percent"]),
                resetsAt: date(millis: raw["resets_at_ms"]),
                expiresAt: date(millis: raw["expires_at_ms"]),
                unsupported: !supported
            )
        }

        return StepFunPlanUsage(
            planState: plan["state"] as? String ?? "unavailable",
            family: family,
            planName: (plan["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            subscriptionExpiresAt: subscriptionExpiresAt,
            quotaState: quota["state"] as? String ?? "known",
            allowed: quota["allowed"] as? Bool ?? false,
            reason: (quota["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            windows: windows,
            creditBuckets: buckets,
            observedAt: date(millis: body["observed_at_ms"])
        )
    }

    // MARK: - 取值

    /// 数值兼容：Int / Double / 字符串数字
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: return v.isFinite ? v : nil
        case let v as Int:    return Double(v)
        case let v as String: return Double(v.trimmingCharacters(in: .whitespaces))
        default:              return nil
        }
    }

    /// Credit 量保持十进制字符串：量级可达 40,000M，不转浮点以免丢精度。
    /// 服务端若给数字则按整数字面量回落。
    private static func decimalString(_ value: Any?) -> String {
        switch value {
        case let v as String: return v.trimmingCharacters(in: .whitespaces)
        case let v as Int:    return String(v)
        case let v as Double: return String(format: "%.0f", v)
        default:              return "0"
        }
    }

    /// 毫秒时间戳 → Date（字段名统一为 *_at_ms）
    private static func date(millis value: Any?) -> Date? {
        guard let ms = number(value), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

// MARK: - Credits 展示格式化

enum StepFunFormat {

    /// Credits 量级换算为 M（百万）单位展示，与 StepFun 官网表述一致（如 8,000M）。
    /// 只用于显示，不参与任何计算。
    static func credits(_ raw: String) -> String {
        guard let value = Double(raw), value.isFinite else { return raw }
        if value >= 1_000_000 {
            return grouped(value / 1_000_000) + "M"
        }
        return grouped(value)
    }

    private static func grouped(_ value: Double) -> String {
        let formatter = value < 100 ? formatterOneDecimal : formatterZeroDecimal
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }

    /// 共享格式化器（避免每次构建快照都重建）
    private static let formatterOneDecimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        return f
    }()

    private static let formatterZeroDecimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
}

//
//  DeepSeekModels.swift
//  zenmux-monitor
//
//  DeepSeek API 返回数据模型
//  对应 GET /user/balance 响应结构
//

import Foundation

// MARK: - 余额响应

struct DeepSeekBalanceResponse: Codable {
    /// 当前账户是否有余额可供 API 调用
    let is_available: Bool
    /// 各币种余额明细（可能含 CNY / USD 多条）
    let balance_infos: [DeepSeekBalanceInfo]
}

struct DeepSeekBalanceInfo: Codable {
    /// 货币：CNY 或 USD
    let currency: String
    /// 总可用余额（赠金 + 充值），字符串型数字
    let total_balance: String
    /// 未过期的赠金余额
    let granted_balance: String
    /// 充值余额
    let topped_up_balance: String

    /// 总余额转 Double，解析失败为 0
    var total: Double { Double(total_balance) ?? 0 }
    /// 赠金余额转 Double
    var granted: Double { Double(granted_balance) ?? 0 }
    /// 充值余额转 Double
    var toppedUp: Double { Double(topped_up_balance) ?? 0 }

    /// 货币符号
    var symbol: String { currency == "USD" ? "$" : "¥" }
}

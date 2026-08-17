//
//  DeepSeekUsageStore.swift
//  zenmux-monitor
//
//  DeepSeek 今日用量本地统计存储
//  DeepSeek 官方无按时间段查询用量的接口，此处基于「余额差值」本地推算：
//  以当日首次采样余额为基线，今日用量 ≈ 基线 − 当前余额。
//
//  已知限制：
//  - 仅能统计应用运行且成功采样期间的消耗
//  - 当日基线建立前的消耗不可见（UI 以「自 HH:mm 起」如实标注）
//  - 余额上升（充值/赠金）时重置基线，用量不为负
//

import Foundation
import CryptoKit

/// DeepSeek 每日余额采样存储。
///
/// 每天最多一条记录：`baseline` 为当日基线（首次采样或充值后重置），
/// `latest` 为最近一次采样。数据持久化在 UserDefaults，仅保留最近 7 天。
@MainActor
final class DeepSeekUsageStore {
    /// 单日采样记录（纯值类型，可 Codable 持久化）
    struct DailySample: Codable {
        /// 当日基线余额（当日首次采样值；充值后重置为充值后余额）
        var baseline: Double
        /// 基线建立时间
        var baselineTime: Date
        /// 最近一次采样余额
        var latest: Double
        /// 最近一次采样时间
        var latestTime: Date
    }

    private let storageKey = "deepseek_usage_samples"
    private let fingerprintKey = "deepseek_usage_key_fingerprint"
    /// 采样历史保留天数（超出部分写入时清理）
    private let retentionDays = 7

    private let calendar = Calendar.current

    private static let dayKeyFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 记录一次余额采样。
    /// - Parameters:
    ///   - total: 当前总余额（赠金 + 充值）
    ///   - keyFingerprint: API Key 指纹，Key 变化时自动清空历史，避免串账
    ///   - at: 采样时间（默认当前）
    func record(total: Double, keyFingerprint: String, at: Date = Date()) {
        if UserDefaults.standard.string(forKey: fingerprintKey) != keyFingerprint {
            UserDefaults.standard.set(keyFingerprint, forKey: fingerprintKey)
            UserDefaults.standard.removeObject(forKey: storageKey)
        }

        var samples = load()
        let dayKey = Self.dayKeyFmt.string(from: at)

        if var sample = samples[dayKey] {
            if total > sample.baseline {
                // 余额上升：视为充值/赠金到账，重置基线，用量归零重新累计
                // latest 同步重置，避免旧低值与新基线做差产生虚假用量
                sample.baseline = total
                sample.baselineTime = at
                sample.latest = total
                sample.latestTime = at
            } else {
                sample.latest = total
                sample.latestTime = at
            }
            samples[dayKey] = sample
        } else {
            // 当日首次采样：建立基线
            samples[dayKey] = DailySample(baseline: total, baselineTime: at, latest: total, latestTime: at)
        }

        // 清理超出保留期的历史记录
        let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: at) ?? at
        samples = samples.filter { key, _ in
            guard let date = Self.dayKeyFmt.date(from: key) else { return false }
            return date >= cutoff
        }

        save(samples)
    }

    /// 当日用量统计：今日已消耗金额与基线建立时间；当日尚无采样记录时返回 nil。
    func todayStats(at: Date = Date()) -> (usage: Double, since: Date)? {
        let dayKey = Self.dayKeyFmt.string(from: at)
        guard let sample = load()[dayKey] else { return nil }
        // 余额差值推算消耗；充值重置基线后理论上不为负，仍做钳制兜底
        return (max(0, sample.baseline - sample.latest), sample.baselineTime)
    }

    /// API Key 指纹：取 SHA256 前 8 位，仅用于识别 Key 是否更换，不可还原 Key。
    static func fingerprint(of apiKey: String) -> String {
        let digest = SHA256.hash(data: Data(apiKey.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// 清空全部采样历史与指纹（删除 Key 时调用，避免残留旧 Key 的用量数据）
    func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: fingerprintKey)
    }

    // MARK: - 持久化

    private func load() -> [String: DailySample] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: DailySample].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func save(_ samples: [String: DailySample]) {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

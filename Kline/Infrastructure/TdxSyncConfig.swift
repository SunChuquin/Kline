//
//  TdxSyncConfig.swift
//  Kline
//
//  行情更新调度配置：UserDefaults 持久化。
//  与 ChartConfigStore / KlineThemeStore 同惯例：ObservableObject 单例，@Published 写入即持久化。
//
//  只服务**设备侧腾讯直连链路**的到点调度（`TdxSyncManager.checkSchedule`）：
//  到点先补「清单并集」范围缺口、再写当日 bar（17:30 档为全市场补缺口，含自动合并主库）。
//  默认 **开启**（enabled = true）；App 内已不再提供修改开关 / 时刻表的入口（云端分片链路已删除）。
//

import Foundation
import Combine

/// 同步配置（单例）
final class TdxSyncConfig: ObservableObject {
    static let shared = TdxSyncConfig()

    // MARK: - 默认值

    /// 默认更新时刻（北京时间，交易日）：11:00 / 14:30 为盘中快照，15:05 为收盘后完整K线，17:30 为当日兜底
    static let defaultScheduleTimes: [String] = ["11:00", "14:30", "15:05", "17:30"]

    /// 旧版默认时刻（三档）。仅用于**一次性迁移**：已装机用户读回的历史值与它恰好相等 → 升级为新默认值；
    /// 用户自己改过的值不在此列，保持不变。
    static let legacyDefaultScheduleTimes: [String] = ["11:00", "14:30", "15:05"]

    // MARK: - UserDefaults 键

    static let enabledKey = "kline.tdxsync.enabled"
    static let scheduleTimesKey = "kline.tdxsync.scheduleTimes"
    static let tradingDaysOnlyKey = "kline.tdxsync.tradingDaysOnly"
    static let checkIntervalKey = "kline.tdxsync.foregroundCheckInterval"

    // MARK: - 持久化项

    /// 是否启用自动更新（**默认开启**：本功能的目的就是"自动盯盘"，装好即生效；用户可随时关闭）
    @Published var enabled: Bool = true {
        didSet { if enabled != oldValue { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) } }
    }

    /// 更新时刻（"HH:mm"，24 小时制）
    @Published var scheduleTimes: [String] = TdxSyncConfig.defaultScheduleTimes {
        didSet { if scheduleTimes != oldValue { Self.save(scheduleTimes, key: Self.scheduleTimesKey) } }
    }

    /// 仅在周一至周五（交易日）更新
    @Published var tradingDaysOnly: Bool = true {
        didSet { if tradingDaysOnly != oldValue { UserDefaults.standard.set(tradingDaysOnly, forKey: Self.tradingDaysOnlyKey) } }
    }

    /// 前台轮询间隔（秒）：用于「到点触发」的检查频率
    @Published var foregroundCheckInterval: TimeInterval = 60 {
        didSet { if foregroundCheckInterval != oldValue { UserDefaults.standard.set(Double(foregroundCheckInterval), forKey: Self.checkIntervalKey) } }
    }

    private init() {
        let d = UserDefaults.standard
        // 注：init 内的赋值不会触发 didSet，因此不会反向写回 UserDefaults
        // enabled 默认 true（本功能目的就是自动更新）；用 object(forKey:) 区分"从未设置过"与"用户显式关掉"
        enabled = (d.object(forKey: Self.enabledKey) as? Bool) ?? true
        // 时刻表：一次性迁移（老用户读回旧三档默认值 → 升级为四档并落盘；用户自改值不动）
        let storedTimes = Self.load([String].self, key: Self.scheduleTimesKey)
        if storedTimes == Self.legacyDefaultScheduleTimes {
            scheduleTimes = Self.defaultScheduleTimes
            Self.save(Self.defaultScheduleTimes, key: Self.scheduleTimesKey)
            DebugLogger.shared.log("[TdxSync] 时刻表迁移：旧默认 \(Self.legacyDefaultScheduleTimes.joined(separator: ",")) → 新默认 \(Self.defaultScheduleTimes.joined(separator: ","))")
        } else {
            scheduleTimes = storedTimes ?? Self.defaultScheduleTimes
        }
        tradingDaysOnly = (d.object(forKey: Self.tradingDaysOnlyKey) as? Bool) ?? true
        foregroundCheckInterval = (d.object(forKey: Self.checkIntervalKey) as? Double) ?? 60
    }

    // MARK: - UserDefaults 读写工具

    private static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

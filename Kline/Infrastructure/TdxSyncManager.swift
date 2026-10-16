//
//  TdxSyncManager.swift
//  Kline
//
//  设备侧「到点调度」：按配置的四个时刻（默认 11:00 / 14:30 / 15:05 / 17:30，北京时间、交易日）
//  触发腾讯直连更新链路 ——
//    · 11:00 / 14:30 / 15:05：**先补「清单并集」范围缺口，再写清单当日 bar**（腾讯源）；
//    · 17:30：全市场补缺口（含自动合并主库）。
//  取数与写入分别由 `GapBackfill` 与 `WatchlistSyncManager` 完成，本类只做「到点判定 + 触发 + 串接」。
//
//  关键约束：
//   - 同一时刻只允许一条链路在跑（主线程 `isRunning` 守卫 + 当天已跑时刻集合 `ranSlots`）：
//     链路进行中来的触发一律忽略，且**不占用该时刻**，链路结束后的下一轮检查仍会补上；
//   - 定时器只在前台 run loop 上走，切后台自然停摆；回前台由通知补一次检查（幂等，重复调用只生效一次）；
//   - 时刻 / 交易日 / 日期工具（minutes / slotText / isTradingDay / todayYMD / naturalDaysSince /
//     nextSlotDescription / dayKey）对外公开，供 GapBackfill / WatchlistSyncManager /
//     TencentQuoteFetcher / 面板复用。
//

import Foundation
import Combine
import UIKit

// MARK: - 同步管理器

final class TdxSyncManager: ObservableObject {
    static let shared = TdxSyncManager()

    private let config = TdxSyncConfig.shared

    // MARK: - 对外只读状态（一律在主线程发布）

    /// 下一个计划时刻文案，形如 "今日 14:30" / "明日 11:00"
    @Published private(set) var nextScheduledText: String?

    /// 是否已启用（透传配置）
    var isEnabled: Bool { config.enabled }

    // MARK: - 内部状态（**只在主线程访问**）

    /// 链路进行中守卫（true 时到点触发被忽略，且不占用该时刻）
    private var isRunning = false

    /// 定时器（**只在主线程访问**）
    private var timer: Timer?
    /// 当前定时器使用的间隔，用于配置变更后重建
    private var timerInterval: TimeInterval = 0
    private var foregroundObserver: NSObjectProtocol?
    private var isStarted = false
    /// 当天已执行过的时刻（键 = "yyyyMMdd 分钟数"），保证"到点触发且当天不重复"
    private var ranSlots: Set<String> = []
    private var ranSlotsDayKey = ""

    private init() {}

    // MARK: - 启动调度（由 KlineApp 调用，紧跟 LiveDataStore.startWatching 之后）

    /// 启动前台调度：每 `foregroundCheckInterval` 检查一次"今天该跑的时刻是否已到且未跑"，
    /// 并在回前台时补一次检查（幂等，重复调用只生效一次）
    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isStarted else { return }
            self.isStarted = true
            self.installForegroundObserver()
            self.scheduleTimer()
            self.checkSchedule(trigger: "启动检查")
            DebugLogger.shared.log("[TdxSync] 调度启动 enabled=\(self.config.enabled) 间隔=\(Int(self.config.foregroundCheckInterval))s 时刻=\(self.config.scheduleTimes.joined(separator: ",")) 交易日限制=\(self.config.tradingDaysOnly) 局域网地址=\(LocalNetworkAddress.currentIPv4() ?? "未连接")")
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = Swift.max(15, config.foregroundCheckInterval)
        timerInterval = interval
        // Timer 只在前台 run loop 上走，App 切后台自然停摆；回前台由通知补一次检查
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkSchedule(trigger: "定时检查")
        }
        t.tolerance = 5
        timer = t
    }

    private func installForegroundObserver() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            self?.checkSchedule(trigger: "回前台检查")
        }
    }

    // MARK: - 到点调度（主线程）

    /// 到点检查：enabled 且（交易日限制下）当天最新已过时刻尚未执行 → 触发一次更新链路
    private func checkSchedule(trigger: String) {
        // 配置里改了轮询间隔 → 重建定时器
        if isStarted, abs(config.foregroundCheckInterval - timerInterval) > 0.5 { scheduleTimer() }
        updateNextScheduledText()

        guard config.enabled else { return }
        let now = Date()
        if config.tradingDaysOnly, !Self.isTradingDay(now) {
            DebugLogger.shared.log("[TdxSync] \(trigger)：非交易日，跳过")
            return
        }
        // 链路进行中：本次触发忽略，且不占用时刻（链路结束后下一轮仍会补上）
        guard !isRunning else { return }

        // 跨天重置「当天已跑」记录
        let dayKey = Self.dayKey(now)
        if ranSlotsDayKey != dayKey {
            ranSlotsDayKey = dayKey
            ranSlots.removeAll()
        }
        let nowMinutes = Self.minutesOfDay(now)
        // 只取「已到点」中最晚的一个：避免冷启动时把 11:00 / 14:30 / 15:05 / 17:30 四个都跑一遍
        let passed = config.scheduleTimes.compactMap { Self.minutes(of: $0) }.filter { $0 <= nowMinutes }
        guard let slot = passed.max() else { return }
        let slotKey = dayKey + " " + String(slot)
        guard !ranSlots.contains(slotKey) else { return }
        ranSlots.insert(slotKey)
        let slotText = Self.slotText(slot)
        DebugLogger.shared.log("[TdxSync] \(trigger)：已到点 \(slotText)，触发更新")
        isRunning = true

        // 17:30 档：清单盘中快照已无意义（完整K线 15:05 档已覆盖）→ 改为全市场补缺口
        // （拉主库最新日 → 今天的日线并自动合并入主库）；
        // 其余档位【2026-10-16 修正】：**先补「清单并集」范围缺口，再写当日 bar**——
        // 否则被跳过的中间交易日永远补不上（真机实证：自选股 13 号直接跨到 16 号，缺 14/15）。
        if slotText == "17:30" {
            DebugLogger.shared.log("[TdxSync] 17:30 档 → 触发全市场补缺口（含自动合并主库）")
            GapBackfill.shared.run { [weak self] in
                self?.isRunning = false
            }
        } else {
            DebugLogger.shared.log("[TdxSync] \(slotText) 档 → 先补清单范围缺口，再日更（腾讯源）")
            // 清单 file 集**延迟解析**（冷启动窗口内 metaList 可能为空 → 提前快照会得到空集）
            GapBackfill.shared.run(resolveFiles: { WatchlistSymbols.unionFiles() }) { [weak self] in
                WatchlistSyncManager.shared.sync(reason: trigger, slot: slotText) {
                    self?.isRunning = false
                }
            }
        }
    }

    /// 刷新「下次计划时刻」文案（未启用时也展示，便于用户理解时刻表）
    private func updateNextScheduledText() {
        let text = Self.nextSlotDescription(for: config.scheduleTimes,
                                            now: Date(),
                                            tradingDaysOnly: config.tradingDaysOnly)
        if nextScheduledText != text { nextScheduledText = text }
    }

    // MARK: - 时刻 / 交易日工具

    /// "HH:mm" → 当天分钟数
    static func minutes(of time: String) -> Int? {
        let segs = time.split(separator: ":")
        guard segs.count == 2, let h = Int(segs[0]), let m = Int(segs[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    static func minutesOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    static func slotText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// 交易日 = 周一至周五（不含法定节假日判断）
    static func isTradingDay(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)   // 1=周日 … 7=周六
        return weekday >= 2 && weekday <= 6
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    /// 今天（设备本地日期，YYYYMMDD）
    static func todayYMD() -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return Int(f.string(from: Date())) ?? 0
    }

    /// 距今天然天数（date8 为 0 / 非法 → 0）
    static func naturalDaysSince(_ date8: Int) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        guard date8 > 0, let date = f.date(from: String(date8)) else { return 0 }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
    }

    /// 下一个计划时刻文案："今日 14:30" / "明日 11:00" / "周三 11:00"
    static func nextSlotDescription(for times: [String], now: Date, tradingDaysOnly: Bool) -> String? {
        let slots = times.compactMap { t -> (String, Int)? in
            guard let m = minutes(of: t) else { return nil }
            return (t, m)
        }.sorted { $0.1 < $1.1 }
        guard !slots.isEmpty else { return nil }

        let cal = Calendar.current
        let nowMinutes = minutesOfDay(now)
        for offset in 0...7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { break }
            if tradingDaysOnly, !isTradingDay(day) { continue }
            let prefix = cal.isDate(day, inSameDayAs: now) ? "今日" : dayLabel(day, now: now)
            for (text, m) in slots where offset > 0 || m > nowMinutes {
                return prefix + " " + text
            }
        }
        return nil
    }

    private static func dayLabel(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           cal.isDate(date, inSameDayAs: tomorrow) { return "明日" }
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let weekday = cal.component(.weekday, from: date)
        return names[Swift.max(0, Swift.min(6, weekday - 1))]
    }
}

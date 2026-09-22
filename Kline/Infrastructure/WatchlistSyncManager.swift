//
//  WatchlistSyncManager.swift
//  Kline
//
//  设备侧「清单标的当日K线」自动更新编排（单例 + ObservableObject）：
//    清单并集（WatchlistSymbols） → 东财直连拉取当日K线（EastmoneyQuoteFetcher）
//    → 直写增量库（LiveDataStore.upsertDaily）→ 走既有热刷新链路（dataVersion 自增 → 监控重扫）
//
//  硬约束：
//   - **不依赖云端 manifest**：与 TdxSyncManager 各自独立触发、成败互不影响（云端源不可达也能跑）；
//   - 门禁复用 TdxSyncConfig.enabled（总开关）与 tradingDaysOnly（交易日限制，由 TdxSyncManager 统一判定）；
//   - 并集为空 → 记状态「跳过：清单为空」并直接返回，不写库、不报错；
//   - 不新增任何监控触发机制：写入后只调 LiveDataStore.upsertDaily + reloadAsync，
//     由既有 `reloadPublisher` → `DatabaseManager.dataVersion` → `MarketRowCache` / `SimStore.sweepConditions`；
//   - UI 状态一律在主线程写。
//
//  线程：`sync(reason:slot:)` 须在主线程调用（内部再切主线程执行）；东财 completion 在它自己的串行队列，
//  本类在回调处显式切回主线程。
//

import Foundation
import Combine

// MARK: - 结果分类

/// 一次「清单标的自动更新」的结果分类（供状态展示：成功 / 跳过 / 失败）
enum WatchlistSyncOutcome: String {
    case success
    case skipped
    case failed

    var text: String {
        switch self {
        case .success: return "成功"
        case .skipped: return "跳过"
        case .failed:  return "失败"
        }
    }
}

// MARK: - 管理器

final class WatchlistSyncManager: ObservableObject {
    static let shared = WatchlistSyncManager()

    private let config = TdxSyncConfig.shared

    // MARK: - 对外只读状态（一律在主线程写）

    /// 是否进行中（true 时重复触发被忽略）
    @Published private(set) var isRunning = false
    /// 最近一次完成时间
    @Published private(set) var lastRunAt: Date?
    /// 最近一次拿到的交易日（YYYYMMDD；0 / nil 表示未取到）
    @Published private(set) var lastTradeDate: Int?
    /// 最近一次清单并集标的数
    @Published private(set) var unionCount = 0
    /// 最近一次命中（成功写入）标的数
    @Published private(set) var hitCount = 0
    /// 最近一次跳过 / 失败标的数
    @Published private(set) var skippedCount = 0
    /// 最近一次批次失败数
    @Published private(set) var batchFailureCount = 0
    /// 最近一次结果分类（nil = 尚未执行过）
    @Published private(set) var lastOutcome: WatchlistSyncOutcome?
    /// 最近一次结果文案（成功 / 跳过 / 失败 + 原因）
    @Published private(set) var lastResultText: String?
    /// 四个时刻 → 各自最近一次结果文案（键为 "HH:mm"；手动触发为 "手动"）
    @Published private(set) var slotResults: [String: String] = [:]

    private init() {}

    // MARK: - 对外入口（主线程）

    /// 触发一次「清单标的当日K线」更新。
    /// - Parameters:
    ///   - reason: 触发来源（"定时检查" / "回前台检查" / "启动检查"）
    ///   - slot: 触发时刻文案（"11:00" 等）；nil → 记为「手动」
    ///
    /// 与 TdxSyncManager 独立：本方法不读写任何云端 manifest 状态。
    func sync(reason: String, slot: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.config.enabled else {
                DebugLogger.shared.log("[WatchlistSync] \(reason)：总开关未启用，跳过")
                return
            }
            guard !self.isRunning else {
                DebugLogger.shared.log("[WatchlistSync] \(reason)：已在执行中，忽略本次触发")
                return
            }
            self.isRunning = true
            self.performSync(reason: reason, slot: slot)
        }
    }

    // MARK: - 主流程（主线程）

    private func performSync(reason: String, slot: String?) {
        // ① 清单并集（@MainActor，故必须在主线程取）
        let files = WatchlistSymbols.unionFiles().sorted()
        if unionCount != files.count { unionCount = files.count }

        guard !files.isEmpty else {
            DebugLogger.shared.log("[WatchlistSync] \(reason)：清单并集为空 → 跳过（不写库、不报错）")
            finish(outcome: .skipped, text: "跳过：清单为空", reason: reason, slot: slot,
                   tradeDate: nil, hit: 0, skipped: 0, batchFailures: 0)
            return
        }
        DebugLogger.shared.log("[WatchlistSync] \(reason)：清单并集 \(files.count) 只 → 开始拉取当日K线")

        // ② 东财直连（completion 在它自己的串行队列 → 显式切回主线程）
        EastmoneyQuoteFetcher.shared.fetch(files: files) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.handle(result: result, reason: reason, slot: slot)
            }
        }
    }

    /// ④ 拉取结果 → 状态 / 日志 → 写入增量库
    private func handle(result: EastmoneyFetchResult, reason: String, slot: String?) {
        let skipSample = Self.skipSummary(result.skipped)
        DebugLogger.shared.log("[WatchlistSync] \(reason)：并集 \(unionCount) 只 → 命中 \(result.hitCount) 只"
            + " → 跳过 \(result.skipped.count) 只（\(skipSample)）→ 批次失败 \(result.batchFailures.count)"
            + " → 交易日 \(result.tradeDate)")

        // 无命中 → 失败 / 跳过并按原因收尾（不写库）
        guard !result.bars.isEmpty else {
            let text: String
            if !result.batchFailures.isEmpty {
                text = "失败：全部批次失败（\(result.batchFailures.count) 批）"
            } else if result.tradeDate <= 0 {
                text = "失败：交易日缺失（f124 均无效）"
            } else {
                text = "跳过：无命中标的（\(result.skipped.count) 只被跳过）"
            }
            DebugLogger.shared.log("[WatchlistSync] \(reason)：\(text)")
            finish(outcome: .failed, text: text, reason: reason, slot: slot,
                   tradeDate: result.tradeDate > 0 ? result.tradeDate : nil,
                   hit: 0, skipped: result.skipped.count, batchFailures: result.batchFailures.count)
            return
        }

        // ③ 组装 meta（按 file 查主库 code/name/type）与日线；date 即 result.tradeDate
        var metaByFile: [String: MetaItem] = [:]
        for m in DatabaseManager.shared.metaList where metaByFile[m.file] == nil { metaByFile[m.file] = m }
        let metas: [LiveUpsertMeta] = result.bars.keys.sorted().map { file in
            let m = metaByFile[file]
            return LiveUpsertMeta(file: file,
                                  code: m?.code ?? "",
                                  name: m?.name ?? "",
                                  type: m?.type ?? "")
        }
        let bars: [LiveUpsertBar] = result.bars.map { file, bar in
            LiveUpsertBar(file: file, date: bar.date,
                          open: bar.open, high: bar.high, low: bar.low, close: bar.close,
                          vol: bar.vol, amo: bar.amo)
        }
        let updatedAt = Self.utcMidnightEpoch(result.tradeDate)

        // ④ 直写增量库（成功后由既有热刷新链路自增 dataVersion → 监控重扫）
        LiveDataStore.shared.upsertDaily(metas: metas, bars: bars, updatedAt: updatedAt) { [weak self] merge in
            guard let self = self else { return }
            if merge.ok {
                DebugLogger.shared.log("[WatchlistSync] \(reason)：写入增量库成功 \(merge.message)")
                LiveDataStore.shared.reloadAsync(completion: { summary in
                    DebugLogger.shared.log("[WatchlistSync] 热刷新完成 可用=\(summary.isAvailable)"
                        + " 内容变化=\(summary.contentChanged) 最新=\(summary.latestDateAfter)")
                })
                self.finish(outcome: .success,
                            text: "成功：写入 \(merge.dailyRows) 行 / \(result.hitCount) 只",
                            reason: reason, slot: slot, tradeDate: result.tradeDate,
                            hit: result.hitCount, skipped: result.skipped.count,
                            batchFailures: result.batchFailures.count)
            } else {
                DebugLogger.shared.log("[WatchlistSync] \(reason)：写入增量库失败 \(merge.message)")
                self.finish(outcome: .failed, text: "失败：\(merge.message)", reason: reason, slot: slot,
                            tradeDate: result.tradeDate, hit: 0, skipped: result.skipped.count,
                            batchFailures: result.batchFailures.count)
            }
        }
    }

    // MARK: - 收尾（主线程）

    /// 统一收尾：写状态（值未变不写，避免无谓的 @Published 发布）+ 记日志
    private func finish(outcome: WatchlistSyncOutcome, text: String, reason: String, slot: String?,
                        tradeDate: Int?, hit: Int, skipped: Int, batchFailures: Int) {
        let now = Date()
        lastRunAt = now
        if lastOutcome != outcome { lastOutcome = outcome }
        if lastResultText != text { lastResultText = text }
        if let t = tradeDate, lastTradeDate != t { lastTradeDate = t }
        if hitCount != hit { hitCount = hit }
        if skippedCount != skipped { skippedCount = skipped }
        if batchFailureCount != batchFailures { batchFailureCount = batchFailures }
        let key = slot ?? "手动"
        if slotResults[key] != text {
            var next = slotResults
            next[key] = text
            slotResults = next
        }
        if isRunning { isRunning = false }
        DebugLogger.shared.log("[WatchlistSync] \(reason)：\(outcome.text) — \(text)")
    }

    // MARK: - 工具

    /// 跳过原因分布 + 前 3 条样例（供日志 / 状态面板一眼看出失败原因）
    private static func skipSummary(_ skipped: [EastmoneySkip]) -> String {
        guard !skipped.isEmpty else { return "无" }
        var counts: [String: Int] = [:]
        for s in skipped { counts[s.reason.text, default: 0] += 1 }
        let dist = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        let samples = skipped.prefix(3).map { "\($0.file)(\($0.reason.text))" }.joined(separator: ",")
        return "分布 \(dist)；样例 \(samples)"
    }

    /// YYYYMMDD → 该交易日的 **UTC 零点** epoch 秒（0 / 非法 → 0）
    private static func utcMidnightEpoch(_ date8: Int) -> Int {
        guard date8 > 0 else { return 0 }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd"
        guard let date = f.date(from: String(date8)) else { return 0 }
        return Int(date.timeIntervalSince1970)
    }
}
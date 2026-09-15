//
//  MarketRowCache.swift
//  Kline
//
//  字段行缓存与后台预取器：惰性拉取每只标的最近 N 根日线并转成 MarketRow（@MainActor 单例）。从 MarketFieldKit.swift 拆分。
//

import Foundation
import SwiftUI
import Combine

// MARK: - 缓存 + 后台预取器

/// 字段行缓存：负责从 DatabaseManager 异步拉每只标的最近 N 根日线并转成 MarketRow
@MainActor
final class MarketRowCache: ObservableObject {
    static let shared = MarketRowCache()
    private let db: DatabaseManager = DatabaseManager.shared

    /// 每只标的需要最近多少根（MA60 + YTD 要够用，取 80 足够覆盖常规字段；换手/股本缺）
    private let lookback = 80

    /// key: metaID
    @Published private(set) var rows: [Int: MarketRow] = [:]

    /// 正在预取中的 metaID 集合（防止同一标的多连查询）
    private var inFlight: Set<Int> = []

    /// 后台计算队列（公式条件分组 / 批量字段值也用这）
    let computeQueue = DispatchQueue(label: "com.sunck.kline.market.compute",
                                     qos: .utility,
                                     attributes: .concurrent)

    /// 每轮预取完成后是否已做过一次"补试空行"。避免陷入无限重试
    private var didEmergencyRetry = false

    // MARK: - App 启动预热（行情数值改为启动时即加载）

    /// 启动预热是否已执行（幂等，只取一次全部行情 bars）
    private var didPrewarm = false
    /// 观察数据库就绪信号
    private var isLoadedCancellable: AnyCancellable?

    /// 行情页顶部三个分类对应的 meta.type 取值
    private static let marketTypes: Set<String> = ["沪深主板", "沪深京指数", "扩展行情指数"]

    private init() {
        // 数据库就绪后预热行情数值，无需等行情页首次打开
        isLoadedCancellable = db.$isLoaded
            .filter { $0 }
            .first()
            .sink { [weak self] _ in self?.prewarmMarketData(isLoaded: true) }
        // 若先于本对象创建时数据库已就绪，立即补一次
        if db.isLoaded { prewarmMarketData(isLoaded: true) }
    }

    /// 对外入口：App 启动 / 数据库就绪时调用，幂等（只在首次真正预取）。
    /// - Parameter isLoaded: 数据库就绪标志。调用方（如 onReceive）已确认就绪时传入 true，
    ///   避免预热内部再依赖读 `db.isLoaded`（已验证 @Published 值与属性读取存在时序差异）。
    func prewarmMarketData(isLoaded: Bool? = nil) {
        prewarmMarketBars(isLoaded: isLoaded)
    }

    /// App 启动预热：行情页所需所有分类的 bars，在启动时即预取（置顶优先）。
    private func prewarmMarketBars(isLoaded: Bool? = nil) {
        let loaded = isLoaded ?? db.isLoaded
        guard !didPrewarm, loaded else { return }
        didPrewarm = true
        let metas = db.metaList.filter { Self.marketTypes.contains($0.type) }
        guard !metas.isEmpty else {
            // 数据库就绪但暂时没拉到标的（极早时机），交回下轮观察重试不影响
            didPrewarm = false
            return
        }
        // 关键：必须先为每只标的注册行壳，否则 prefetchPrioritized 回写时
        // `rows[m.id]?.setBars(arr)` 因 rows[id] 为 nil（可选链）被静默丢弃。
        for m in metas { _ = row(for: m, prefetch: false) }
        let faved = metas.filter { FavoritesStore.shared.isFavorited($0.id) }
        let others = metas.filter { !FavoritesStore.shared.isFavorited($0.id) }
        DebugLogger.shared.log("[Cache] prewarmMarketBars: total=\(metas.count) faved=\(faved.count) others=\(others.count)")
        prefetchPrioritized(high: faved, low: others)
    }

    // MARK: - 入口：取一行（若缓存已有直接给；否则后台预取）

    /// 获取某 metaID 的行对象。
    /// - prefetch: true → bars 为空时立即触发后台预取；false → 仅注册空壳（用于"已在外部安排好预取顺序"的场景）。
    func row(for meta: MetaItem, prefetch: Bool = true) -> MarketRow {
        if let r = rows[meta.id] {
            // bars 为空（nil 或空数组）→ 可能 DB 未就绪或上次查询为空，再触发一次
            if prefetch, !r.hasBars, db.isLoaded {
                self.prefetch(metas: [meta])
            }
            return r
        }
        let r = MarketRow(meta: meta)
        rows[meta.id] = r
        if prefetch, db.isLoaded { self.prefetch(metas: [meta]) }
        return r
    }

    /// 批量行（用于行情/自选列表批量预取，避免逐只异步）
    /// - prefetch: true → 未就绪的会主动触发后台 prefetch；false → 仅注册空壳（调用方自行安排预取顺序）。
    func rows(for metas: [MetaItem], prefetch: Bool = true) -> [MarketRow] {
        guard !metas.isEmpty else { return [] }
        // 新一轮可见列表 → 允许后续对本轮空行补试一次（切页/重进后恢复补试能力）
        didEmergencyRetry = false
        var result: [MarketRow] = []
        var needFetch: [MetaItem] = []
        for m in metas {
            if let r = rows[m.id] {
                result.append(r)
                if prefetch, !r.hasBars { needFetch.append(m) }
            } else {
                let r = MarketRow(meta: m)
                rows[m.id] = r
                result.append(r)
                if prefetch { needFetch.append(m) }
            }
        }
        if prefetch, db.isLoaded, !needFetch.isEmpty { self.prefetch(metas: needFetch) }
        return result
    }

    /// 整体刷新：标记所有行的 bars 过期，重新预取给定列表（比如 DB 重建后）
    func refresh(metas: [MetaItem]) {
        for m in metas { rows[m.id]?.setBars([]) }
        rows.removeAll()
        guard db.isLoaded, !metas.isEmpty else { return }
        prefetch(metas: metas)
    }

    // MARK: - ObservedObject 级别取值（SwiftUI 才会在 objectWillChange 后真正重算）

    /// 用 metaID 取某字段的文本值。必须通过 ObservedObject（rowCache）访问，
    /// 否则引用类型 MarketRow 的值变化不会让 SwiftUI 重算 Text（一直显示 "-"）。
    func textFor(_ metaID: Int, _ field: MarketField) -> String {
        guard let row = rows[metaID] else { return "—" }
        return row.text(field)
    }

    func numberFor(_ metaID: Int, _ field: MarketField) -> Double? {
        guard let row = rows[metaID] else { return nil }
        return row.number(field)
    }

    func colorFor(_ metaID: Int, _ field: MarketField) -> Color {
        guard let row = rows[metaID] else { return Color.primary }
        return Color(row.tintColor(field))
    }

    /// 主动重试：对仍未就绪（空）的行补取一次。
    /// - force: true 立即补（无去重）；false 且本轮已补过则跳过，避免连环重试。
    func retryEmptyRows(force: Bool = false) {
        guard db.isLoaded else { return }
        let pending = rows.values.filter { !$0.hasBars }.map { $0.meta }
        guard !pending.isEmpty, force || !didEmergencyRetry else { return }
        didEmergencyRetry = true
        prefetch(metas: pending)
    }

    // MARK: - 预取实现（每只标的查最近 lookback 根 DESC，翻转为 ASC 存入行）

    /// 整批预取入口：把传入列表当低优先级，串行 for 循环 + 逐只回写 + 单只刷新 UI。
    /// 置顶/自选标的请用 `prefetchPrioritized(high:low:)` 先放高优先级。
    private func prefetch(metas: [MetaItem]) {
        guard !metas.isEmpty else { return }
        var targets: [MetaItem] = []
        for m in metas {
            guard !inFlight.contains(m.id) else { continue }
            inFlight.insert(m.id)
            targets.append(m)
        }
        guard !targets.isEmpty else { return }
        runPrefetchBatch(targets: targets, label: "low")
    }

    /// 置顶/自选预取：高优先级先跑，每只完成即立即回写刷新 UI（不攒整批），
    /// 置顶加载完后再跑 low（非置顶）。避免置顶被压在非置顶后面迟迟不显示。
    func prefetchPrioritized(high: [MetaItem], low: [MetaItem]) {
        // 本方法本身在 MainActor：先在主线程做 inFlight 去重，切到后台后不能再碰 inFlight。
        guard !high.isEmpty || !low.isEmpty else { return }
        var highTargets: [MetaItem] = []
        for m in high {
            guard !inFlight.contains(m.id) else { continue }
            inFlight.insert(m.id)
            highTargets.append(m)
        }
        var lowTargets: [MetaItem] = []
        for m in low {
            guard !inFlight.contains(m.id) else { continue }
            inFlight.insert(m.id)
            lowTargets.append(m)
        }
        DebugLogger.shared.log("[Cache] prefetchPrioritized scheduled: high=\(highTargets.count)(in: \(high.count)), low=\(lowTargets.count)(in: \(low.count))")
        guard !highTargets.isEmpty || !lowTargets.isEmpty else { return }

        let lookback = self.lookback
        let dbm = db
        computeQueue.async { [weak self] in
            DebugLogger.shared.log("[Cache] computeQueue: HIGH BATCH START n=\(highTargets.count)")
            // ------ 高优先级：逐只取 → 立即回写刷新 UI ------
            for m in highTargets {
                let all = dbm.fetchPeriodLimited(metaId: m.id, table: "daily", limit: lookback)
                let arr = Array(all.reversed())
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.inFlight.remove(m.id)
                    self.rows[m.id]?.setBars(arr)
                    if arr.isEmpty {
                        DebugLogger.shared.log("[Cache] prefetch(high) empty metaID=\(m.id) code=\(m.code)")
                    } else {
                        DebugLogger.shared.log("[Cache] prefetch(high) OK metaID=\(m.id) code=\(m.code) bars=\(arr.count) lastClose=\(arr.last!.close)")
                    }
                    self.objectWillChange.send()
                }
            }
            DebugLogger.shared.log("[Cache] computeQueue: HIGH BATCH END; LOW BATCH n=\(lowTargets.count)")
            // ------ 低优先级：已在主线程入 targets，直接丢 runPrefetchBatch ------
            if !lowTargets.isEmpty {
                DispatchQueue.main.async {
                    self?.runPrefetchBatch(targets: lowTargets, label: "low")
                }
            }
        }
    }

    /// 共用的"批量串行取 + 逐只回写 + 逐只 notify"实现。
    /// 每只查完立刻 setBars + objectWillChange.send()，不再攒完整批一次性刷新。
    private func runPrefetchBatch(targets: [MetaItem], label: String) {
        DebugLogger.shared.log("[Cache] runPrefetchBatch(\(label)) START n=\(targets.count)")
        let lookback = self.lookback
        let dbm = db
        computeQueue.async { [weak self] in
            for m in targets {
                let all = dbm.fetchPeriodLimited(metaId: m.id, table: "daily", limit: lookback)
                let arr = Array(all.reversed())
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.inFlight.remove(m.id)
                    self.rows[m.id]?.setBars(arr)
                    if arr.isEmpty {
                        DebugLogger.shared.log("[MarketRowCache] prefetch(\(label)) empty metaID=\(m.id) code=\(m.code)")
                    }
                    // 逐只刷新：用户能看到行一个个出来，置顶先行
                    self.objectWillChange.send()
                }
            }
        }
    }

    // MARK: - 指标公式条件分组的计算（给自动分组用）

    /// 计算「某条件公式」在某只标的上的最新结果。
    /// 规则：
    ///   - 公式必须有至少 1 条 OUTPUT 语句（或无冒号赋值 := 的最后一行）
    ///   - 取「最后一条输出线 values.last ?? 0」> 0 → 命中
    ///   - 解析/求值出错 → 未命中（默认未命中，日志丢到 DebugLogger）
    nonisolated func matchFormula(metaID: Int, formulaRaw: String, completion: @escaping (Bool) -> Void) {
        // rows / prefetch 都在 MainActor 隔离下；本方法被 computeQueue 后台闭包调用，
        // 先切到 MainActor 读取行并触发预取，耗时求值再丢回 computeQueue，避免阻塞主线程。
        Task { @MainActor in
            guard let row = rows[metaID] else {
                completion(false)
                return
            }
            if let bars = row.recentBars, !bars.isEmpty {
                // bars 已就绪：直接跑（耗时求值在 computeQueue 上串行推进）
                computeQueue.async {
                    do {
                        let outputs = try TDXFormulaEngine.evaluate(formula: formulaRaw, data: bars)
                        guard let first = outputs.first else {
                            completion(false); return
                        }
                        let v = first.values.last ?? 0
                        completion(v > 0)
                    } catch {
                        DebugLogger.shared.log("[MarketRowCache] matchFormula failed meta=\(metaID) err=\(error.localizedDescription)")
                        completion(false)
                    }
                }
            } else {
                // bars 还没好：先触发一次预取，之后返回 false；
                // 用户刷新时会再来一次（下一轮可能 bars 就有了）。
                prefetch(metas: [row.meta])
                completion(false)
            }
        }
    }
}


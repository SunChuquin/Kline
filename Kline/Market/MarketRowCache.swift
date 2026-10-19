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

    /// 阶段 C：等待 Python 引擎计算快照的标的 bars（key: metaID，value: bars）
    private var pythonSnapshotPending: [Int: [KlineItem]] = [:]
    /// 阶段 C：Python 快照计算防抖定时器
    private var pythonSnapshotTimer: Timer?
    /// 阶段 C：防抖间隔（收集多个标的后一次性批量计算）
    private let pythonSnapshotDebounce: TimeInterval = 0.2
    /// 单批上限：待算标的达到此数即**立即结算**。
    /// §11.41：字段计算已只有引擎一个来源，而长预取（3354 只 × 引擎读 ~12ms ≈ 40s）会让 0.2s
    /// 防抖被每只重置 → 结算被饿死、数值列一路空到整批结束。达到上限即结算可让可见行先出值。
    private let pythonSnapshotMaxBatch = 40

    /// 单次引擎**读**调用带的标的数（§11.42：`db_query_batch` 按批摊薄传输开销）。
    /// 50 只 × 80 根 ≈ 2.8 万数值 ≈ 300KB JSON，单次往返 ~15-20ms。
    private let engineBatchSize = 50

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
    /// 观察增量库数据版本信号（热刷新）
    private var dataVersionCancellable: AnyCancellable?

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
        // 增量库内容变化（dataVersion 仅在内容确实变化时自增）→ 只重取受影响的行
        dataVersionCancellable = db.$dataVersion
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleDataVersionChange() }
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

    /// 增量库内容变化（`DatabaseManager.dataVersion` 自增）→ 只对**受影响的行**重新预取。
    /// - 受影响 = 增量库覆盖的 file 对应的行（行缓存是 file 维度热刷新的最小集合）；
    /// - 增量库不可用/覆盖为空（含「删除增量库」回退场景）→ 全部已建行都受影响；
    /// - 不清空 bars 再重取，避免整屏闪白：后台取完直接 setBars 覆盖。
    private func handleDataVersionChange() {
        guard db.isLoaded else { return }
        let covered = LiveDataStore.shared.coveredFiles()
        let affected = rows.values.map { $0.meta }
            .filter { covered.isEmpty || covered.contains($0.file) }
        guard !affected.isEmpty else { return }
        DebugLogger.shared.log("[Cache] dataVersion 变化 → 重取行 n=\(affected.count) coveredFile=\(covered.count)")
        prefetch(metas: affected)
    }

    // MARK: - 阶段 C：Python 引擎行情快照批量计算

    /// 将标的加入 Python 快照计算 pending 队列，启动 debounce 定时器。
    /// 达到 debounce 间隔后，一次性批量调用 Python 引擎计算所有 pending 标的的字段值。
    private func enqueuePythonSnapshot(metaID: Int, bars: [KlineItem]) {
        pythonSnapshotPending[metaID] = bars
        pythonSnapshotTimer?.invalidate()
        // §11.41：长预取期间防抖会被每只重置（结算饿死）→ 达到单批上限立即结算，
        // 保证用户可见的行先拿到引擎字段值（而不是空到整批预取结束）。
        guard pythonSnapshotPending.count < pythonSnapshotMaxBatch else {
            pythonSnapshotTimer = nil
            flushPythonSnapshot()
            return
        }
        pythonSnapshotTimer = Timer.scheduledTimer(withTimeInterval: pythonSnapshotDebounce, repeats: false) { [weak self] _ in
            // Timer 回调非隔离，显式切回主线程再执行快照批量计算
            guard let self else { return }
            Task { @MainActor in
                self.flushPythonSnapshot()
            }
        }
    }

    /// 执行 Python 快照批量计算：收集所有 pending 标的，一次性调用 quote_snapshot_batch，
    /// 计算结果写入对应 MarketRow.pythonValues，并通知 UI 重绘。
    private func flushPythonSnapshot() {
        guard !pythonSnapshotPending.isEmpty else { return }
        pythonSnapshotTimer = nil

        let batch = pythonSnapshotPending
        pythonSnapshotPending.removeAll()

        // 构建符合 quote_snapshot_batch 输入格式的 symbols 数组
        let allFields: [String] = [
            "latestPrice", "prevClose", "open", "high", "low", "volume", "turnover",
            "change", "changePct", "amplitude", "volRatio",
            "pct3d", "pct5d", "pct10d", "pct20d", "pct60d", "pctYTD",
            "ma5", "ma10", "ma20", "ma60",
        ]
        let symbols: [[String: Any]] = batch.map { (metaID, bars) in
            let barsDict = bars.map { ["date": $0.date, "open": $0.open, "high": $0.high,
                                       "low": $0.low, "close": $0.close,
                                       "volume": $0.volume, "turnover": $0.turnover] }
            return ["metaID": metaID, "bars": barsDict]
        }

        QuoteSnapshotBridge.snapshotBatch(symbols: symbols, fields: allFields) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let results):
                for (metaIDStr, fieldValues) in results {
                    guard let metaID = Int(metaIDStr),
                          let row = self.rows[metaID] else { continue }
                    for (fieldName, value) in fieldValues {
                        guard let field = MarketField(rawValue: fieldName) else { continue }
                        row.setPythonValue(value as? Double, for: field)
                    }
                }
                // §11.41：字段值全部来自引擎；此处对象变化即「引擎值已写入」→ 需 UI 重绘
                self.objectWillChange.send()
                DebugLogger.shared.log("[Cache] Python 快照批量计算完成 n=\(results.count)")
            case .failure(let f):
                DebugLogger.shared.log("[Cache] Python 快照批量计算失败：\(f)——呈显式空态（不做 Swift 兜底）")
                // §11.41：清空引擎字段值 → 该批标的的数值列渲染 "-"（显式空态）；
                // 不再回落到 Swift 现状计算（Swift 算法已随本批次删除）。
                for metaID in batch.keys {
                    self.rows[metaID]?.clearPythonValues()
                }
                self.objectWillChange.send()
            }
        }
    }

    /// 清空所有 Python 快照 pending 和计算结果（引擎不可用时调用）。
    func clearPythonSnapshotCache() {
        pythonSnapshotTimer?.invalidate()
        pythonSnapshotTimer = nil
        pythonSnapshotPending.removeAll()
        for row in rows.values {
            row.clearPythonValues()
        }
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
        // §11.42：按批预取（drop 到后台队列；批内逐只回写）
        runPrefetchBatch(targets: targets, label: "low")
    }

    /// 整批预取入口（后台派发）：`prefetch` 与 dataVersion 热刷新共用。
    private func runPrefetchBatch(targets: [MetaItem], label: String) {
        guard !targets.isEmpty else { return }
        let lookback = self.lookback
        let batchSize = self.engineBatchSize
        let dbm = db
        computeQueue.async { [weak self] in
            let read: ([(metaID: Int, limit: Int)]) -> [Int: [KlineItem]] = { requests in
                dbm.fetchPeriodLimitedViaEngineBatch(table: "daily", requests: requests)
            }
            self?.runEngineBatches(targets: targets, label: label, lookback: lookback,
                                   batchSize: batchSize, verbose: false, read: read)
        }
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
        let batchSize = self.engineBatchSize
        let dbm = db
        computeQueue.async { [weak self] in
            // 引擎读闭包在本闭包内构造（MainActor 上下文）→ 由 nonisolated 的 runEngineBatches 调用
            let read: ([(metaID: Int, limit: Int)]) -> [Int: [KlineItem]] = { requests in
                dbm.fetchPeriodLimitedViaEngineBatch(table: "daily", requests: requests)
            }
            DebugLogger.shared.log("[Cache] computeQueue: HIGH BATCH START n=\(highTargets.count)")
            // 高优先级：按批取 → 批内逐只立即回写刷新 UI
            self?.runEngineBatches(targets: highTargets, label: "high", lookback: lookback,
                                   batchSize: batchSize, verbose: true, read: read)
            DebugLogger.shared.log("[Cache] computeQueue: HIGH BATCH END; LOW BATCH n=\(lowTargets.count)")
            // 低优先级：接着同一后台线程跑（inFlight 已在主线程登记，无需回主线程）
            self?.runEngineBatches(targets: lowTargets, label: "low", lookback: lookback,
                                   batchSize: batchSize, verbose: false, read: read)
        }
    }

    /// 共用的"按批取 + 逐只合并/回写 + 逐只 notify"实现（§11.42）。
    /// 每批一次引擎调用（`db_query_batch`，摊薄单只 ~12ms 的传输开销），
    /// 批内每只查完立刻 setBars + objectWillChange.send()，用户能看到行一个个出来。
    /// ⚠️ 必须由**后台队列**调用（内部是同步阻塞的引擎调用）→ 本方法 `nonisolated`；
    /// 引擎读以闭包（`read`）传入——闭包在 MainActor 调用点构造，故不产生隔离告警；
    /// UI 侧写入一律显式 `Task { @MainActor in }` 跳回主线程。
    private nonisolated func runEngineBatches(targets: [MetaItem], label: String, lookback: Int,
                                              batchSize: Int, verbose: Bool,
                                              read: ([(metaID: Int, limit: Int)]) -> [Int: [KlineItem]]) {
        guard !targets.isEmpty else { return }
        var start = 0
        while start < targets.count {
            let end = min(start + batchSize, targets.count)
            let chunk = Array(targets[start..<end])
            let requests = chunk.map { (metaID: $0.id, limit: lookback) }
            let barsByMeta = read(requests)
            for m in chunk {
                let arr = Array((barsByMeta[m.id] ?? []).reversed())
                Task { @MainActor in
                    MarketRowCache.shared.applyPrefetchedBars(metaID: m.id, bars: arr, label: label, verbose: verbose)
                }
            }
            start = end
        }
    }

    /// 预取结果主线程回写（`inFlight` 摘除 + setBars + 快照入队 + 逐只刷新）。
    /// 与 `runEngineBatches` 配对：读取在后台、写入在主线程。
    private func applyPrefetchedBars(metaID: Int, bars: [KlineItem], label: String, verbose: Bool) {
        inFlight.remove(metaID)
        rows[metaID]?.setBars(bars)
        if bars.isEmpty {
            DebugLogger.shared.log("[Cache] prefetch(\(label)) empty metaID=\(metaID)")
        } else if verbose, let last = bars.last {
            DebugLogger.shared.log("[Cache] prefetch(\(label)) OK metaID=\(metaID) bars=\(bars.count) lastClose=\(last.close)")
        }
        // 阶段 C：将该标的加入 Python 快照计算 pending 队列（批量 debounce）
        enqueuePythonSnapshot(metaID: metaID, bars: bars)
        // 逐只刷新：用户能看到行一个个出来，置顶先行
        objectWillChange.send()
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
                    switch PyTDXFormulaBridge.evaluateText(formulas: [formulaRaw], data: bars).first {
                    case .some(.success(let outputs)):
                        guard let first = outputs.first else {
                            completion(false); return
                        }
                        let v = first.values.last ?? 0
                        completion(v > 0)
                    case .some(.failure(let msg)):
                        DebugLogger.shared.log("[MarketRowCache] matchFormula failed meta=\(metaID) err=\(msg)")
                        completion(false)
                    case .none:
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


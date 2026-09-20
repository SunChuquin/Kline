//
//  StrategyPickRunner.swift
//  Kline
//
//  策略「跑选股」执行器：按候选池批量跑选股公式（两段式先备行情再错峰求值），后台计算 + 主线程进度，可取消。
//
//  Created by 孙楚昆 on 2026/9/20.
//

import Foundation
import Combine

// MARK: - 候选池

/// 跑选股的候选池：全市场（模拟用全部标的）/ 自选（「全部」虚拟分组的成员）
enum StrategyPickPool: String, CaseIterable, Identifiable {
    case market
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .market:    return "全市场"
        case .favorites: return "自选"
        }
    }
}

// MARK: - 命中项

/// 一只命中的标的（命中文案口径与自选「刷新选股」一致：公式最后一条输出线的最新值 > 0）
struct StrategyPickHit: Identifiable, Equatable {
    var id: Int { metaID }
    var metaID: Int
    var code: String
    var name: String
    var lastPrice: Double?
    var changePct: Double?
}

// MARK: - 执行器

/// 跑选股执行器（全局单例，同一时刻只跑一个任务）
///
/// 与 `FavoritesStore.refreshFormulaGroup` 的区别：本执行器只产出命中清单，不写任何持久化，
/// 也不复用它的 `cachedMatches`；命中语义（最后一条输出行末值 > 0）与错峰范式完全一致。
@MainActor
final class StrategyPickRunner: ObservableObject {
    static let shared = StrategyPickRunner()

    /// 阶段：准备行情 → 逐只扫描 → 结束 / 取消
    enum Phase: Equatable {
        case idle
        case preparing(done: Int, total: Int)
        case running(done: Int, total: Int)
        case finished
        case cancelled
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hits: [StrategyPickHit] = []
    /// 准备阶段是否 15 秒超时（超时后用已就绪的行继续跑，未就绪标的会被当成未命中 → 结果可能遗漏）
    @Published private(set) var prepareTimedOut: Bool = false

    var isRunning: Bool {
        switch phase {
        case .preparing, .running: return true
        case .idle, .finished, .cancelled: return false
        }
    }

    /// 准备阶段最长等待（秒）：超时就用已就绪的行继续，不无限等
    private let prepareTimeout: TimeInterval = 15
    /// 准备阶段轮询间隔（秒）
    private let preparePollInterval: TimeInterval = 0.3

    private let cache = MarketRowCache.shared
    private let db = DatabaseManager.shared

    /// 取消标志盒（后台队列与主线程共用，锁保护；不挂在 actor 上以便后台直接读）
    private let cancelBox = PickCancelBox()
    /// 任务序号：start / cancel 都会递增，旧一轮的回调据此整体失效
    private var runToken = 0

    private init() {}

    // MARK: - 入口

    /// 开始跑选股：同一时刻只允许一个任务，再次 start 会先让旧任务失效
    func start(doc: FormulaDoc, pool: StrategyPickPool) {
        cancelBox.cancel()      // 让旧一轮的回调立刻停手
        runToken += 1
        cancelBox.reset()       // 新的一轮重新开始（旧轮回调已按 token 失效）
        let token = runToken

        // 公式文本：优先 PICKREF 引用的选股公式，取不到再回退内嵌 PICK 文本
        let refText = FormulaLibraryStore.shared.formulaText(id: doc.pickRef) ?? ""
        let formula = refText.isEmpty ? doc.pickBody : refText
        let candidates = self.candidates(pool: pool)

        // 新任务开始先清空上一次的结果与进度、超时标记：
        // 否则切换到另一个策略后仍会看到上一个策略的命中，可能给新策略生成旧标的的条件单
        if !hits.isEmpty { hits = [] }
        if prepareTimedOut { prepareTimedOut = false }
        if phase != .idle { phase = .idle }

        // 公式与候选池都为空 → 直接给空结果（不进入准备 / 扫描）
        guard !formula.isEmpty, !candidates.isEmpty else {
            phase = .finished
            return
        }

        // 两段式第一段：批量注册行 + 触发 bars 预取，然后轮询等就绪
        _ = cache.rows(for: candidates)
        let next = Phase.preparing(done: 0, total: candidates.count)
        if phase != next { phase = next }
        pollPrepare(token: token, candidates: candidates, formula: formula, startedAt: Date())
    }

    /// 取消当前任务（未在跑时无副作用）
    func cancel() {
        guard isRunning else { return }
        cancelBox.cancel()
        runToken += 1
        if phase != .cancelled { phase = .cancelled }
    }

    // MARK: - 候选池

    private func candidates(pool: StrategyPickPool) -> [MetaItem] {
        let all = db.metaList
        switch pool {
        case .market:
            return all
        case .favorites:
            // 复用既有反查范式：「全部」虚拟分组的 manual 成员去重并集
            return FavoritesStore.shared.resolveMetaItems(groupID: FavoritesStore.allGroupID, allMeta: all)
        }
    }

    // MARK: - 第一段：等行情就绪

    private func pollPrepare(token: Int, candidates: [MetaItem], formula: String, startedAt: Date) {
        guard token == runToken else { return }
        guard !cancelBox.isCancelled else { return }

        let ready = candidates.reduce(0) { $0 + ((cache.rows[$1.id]?.hasBars ?? false) ? 1 : 0) }
        let next = Phase.preparing(done: ready, total: candidates.count)
        if phase != next { phase = next }

        // 全部就绪，或等待超时（用已就绪的继续）→ 进入扫描
        if ready == candidates.count || Date().timeIntervalSince(startedAt) >= prepareTimeout {
            // 超时且仍有未就绪标的：置超时标记，让清单页提示「结果可能遗漏命中」（start 时重置）
            if ready < candidates.count, !prepareTimedOut { prepareTimedOut = true }
            startScanning(token: token, candidates: candidates, formula: formula)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + preparePollInterval) { [weak self] in
            self?.pollPrepare(token: token, candidates: candidates, formula: formula, startedAt: startedAt)
        }
    }

    // MARK: - 第二段：逐只错峰求值

    private func startScanning(token: Int, candidates: [MetaItem], formula: String) {
        guard token == runToken else { return }
        guard !cancelBox.isCancelled else { return }

        let total = candidates.count
        let running = Phase.running(done: 0, total: total)
        if phase != running { phase = running }

        let cache = self.cache
        let cancelBox = self.cancelBox
        let collect = PickCollectBox()
        let group = DispatchGroup()

        for (i, meta) in candidates.enumerated() {
            group.enter()
            // 错峰：与 FavoritesStore.refreshFormulaGroup 同款，避免 computeQueue 瞬时被打满
            let deadline: DispatchTime = .now() + 0.0001 * Double(i)
            cache.computeQueue.asyncAfter(deadline: deadline) {
                cache.matchFormula(metaID: meta.id, formulaRaw: formula) { hit in
                    let cancelled = cancelBox.isCancelled
                    let isHit = hit && !cancelled
                    let done = collect.add(hit: isHit, meta: meta)
                    // 进度回调在主线程更新 @Published（取消后由 token 与标志双重拦截）
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        guard token == self.runToken else { return }
                        guard !self.cancelBox.isCancelled else { return }
                        let next = Phase.running(done: done, total: total)
                        if self.phase != next { self.phase = next }
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            guard token == self.runToken else { return }
            // 已取消：phase 由 cancel() 置位，这里不再覆盖
            guard !self.cancelBox.isCancelled else { return }
            self.publishHits(collect.snapshot())
            if self.phase != .finished { self.phase = .finished }
        }
    }

    /// 命中的标的补上最新价 / 涨跌幅（取 MarketRowCache 的行缓存，主线程），按代码升序发布
    private func publishHits(_ matched: [MetaItem]) {
        let list = matched.map { meta in
            StrategyPickHit(metaID: meta.id,
                            code: meta.code,
                            name: meta.name,
                            lastPrice: cache.numberFor(meta.id, .latestPrice),
                            changePct: cache.numberFor(meta.id, .changePct))
        }.sorted { $0.code < $1.code }
        // 同值不赋值：@Published 同值赋值也会发布
        if hits != list { hits = list }
    }
}

// MARK: - 后台 / 主线程共享的小盒子（不挂 actor，锁保护）

/// 取消标志盒（非 actor 隔离，供后台队列直接读）
private final class PickCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock(); value = true; lock.unlock()
    }

    func reset() {
        lock.lock(); value = false; lock.unlock()
    }
}

/// 本轮扫描的收集盒：后台队列写进度与命中，主线程读快照
private final class PickCollectBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private var matched: [MetaItem] = []

    /// 记一只的完成情况，返回累计完成数
    func add(hit: Bool, meta: MetaItem) -> Int {
        lock.lock(); defer { lock.unlock() }
        done += 1
        if hit { matched.append(meta) }
        return done
    }

    /// 取命中列表的快照（保持候选池顺序，排序交给调用方）
    func snapshot() -> [MetaItem] {
        lock.lock(); defer { lock.unlock() }
        return matched
    }
}
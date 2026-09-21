//
//  HomePageModel.swift
//  Kline
//
//  首页共享数据模型：B/C/D 三档布局与内容区共用的只读快照
//  （指数条 / 沪深主板涨跌家数 / 我的自选 Top5 / 沪深主板涨幅榜 Top5 / 模拟账户汇总与持仓）。
//  数据全部取自既有单例（DatabaseManager / MarketRowCache / FavoritesStore / SimStore），
//  不新增数据源、不改持久化结构。
//  设计要点：
//  - 全表遍历与 O(n) 聚合只在本模型内做：行数据陆续到位时经 250ms 防抖合并重算
//    （写法对齐 MarketPageModel.scheduleOverviewRefresh），布局视图只读快照，
//    body 内不做任何遍历 / 聚合（否则会拖慢滚动并造成重复计算）；
//  - 所有 @Published 赋值同值不写（项目既有教训：同值赋值也会发布 → 无谓重绘）；
//  - 模型 @MainActor：行缓存 / 库加载 / 自选 / 模拟均在主线程发布，订阅内不跨线程碰 rows。
//

import Foundation
import Combine

// MARK: - 沪深主板涨跌家数

/// 沪深主板聚合快照（口径与行情页 D 档概览一致）
struct HomeBreadth: Equatable {
    var validCount = 0
    var up = 0
    var down = 0
    var flat = 0
    var limitUp = 0
    var limitDown = 0
}

// MARK: - 首页状态模型（三档共用）

@MainActor
final class HomePageModel: ObservableObject {

    // MARK: 共享数据源（全部是既有单例，不新增数据源）
    private let db = DatabaseManager.shared
    private let rowCache = MarketRowCache.shared
    private let fav = FavoritesStore.shared
    private let sim = SimStore.shared

    // MARK: 只读快照（聚合结果写在这里，视图只读）
    /// 前 4 只「沪深京指数」（行数据由 App 启动预热负责，首页不重复预取）
    @Published private(set) var indexQuotes: [MarketRow] = []
    /// 沪深主板涨跌家数；尚无有效聚合时为 nil（界面显示「加载中」，不伪造数值）
    @Published private(set) var breadth: HomeBreadth? = nil
    /// 我的自选 Top 5（「全部」虚拟分组的前 5 只）
    @Published private(set) var favoriteRows: [MarketRow] = []
    /// 沪深主板涨幅榜 Top 5（按涨跌幅降序）
    @Published private(set) var topGainers: [MarketRow] = []
    /// 是否已有可用的主板聚合（决定内容区「加载中」占位）
    @Published private(set) var isMarketReady: Bool = false

    // MARK: 内部
    /// 行数据到位后的防抖重算任务（合并高频 rows 回写）
    private var marketDebounce: DispatchWorkItem? = nil
    private var cancellables = Set<AnyCancellable>()

    /// meta.type 口径（与行情页 / 启动预热一致）
    private static let indexType = "沪深京指数"
    private static let boardType = "沪深主板"

    init() {
        // 行数据陆续到位（启动预热 / 自选预取）→ 250ms 合并重算，避免逐行到位都做一次全表聚合
        rowCache.$rows
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleMarketRefresh() }
            .store(in: &cancellables)

        // 自选增删改 / 分组变更 → 立即重算自选块
        // （objectWillChange 在写入前发布，跳一帧再读，保证拿到最新分组）
        fav.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.refreshFavorites() }
            }
            .store(in: &cancellables)

        // 模拟账户 / 持仓 / 条件单变化 → 转发一次（汇总按需读取，便宜，不缓存）
        sim.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // 数据库就绪 → 首次重算（预热随后写入 bars，再经 $rows 防抖补算）
        db.$isLoaded
            .sink { [weak self] loaded in if loaded { self?.scheduleMarketRefresh() } }
            .store(in: &cancellables)

        // 订阅建立时若数据已就绪，立即补一次首算
        refreshAll()
    }

    // MARK: - 刷新时机

    /// 行数据到位后的防抖重算（250ms 合并）
    private func scheduleMarketRefresh() {
        marketDebounce?.cancel()
        // 显式切回 MainActor 再调用（DispatchWorkItem 的 block 不保证隔离继承）
        let m = self
        let item = DispatchWorkItem {
            Task { @MainActor in m.refreshAll() }
        }
        marketDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// 一次性重算全部快照（全部在主线程、只读已就绪行）
    private func refreshAll() {
        refreshIndexQuotes()
        refreshFavorites()
        refreshMarketAggregates()
    }

    // MARK: - 指数条

    /// 前 4 只「沪深京指数」：用 `prefetch: false` 只注册行壳 ——
    /// 指数 bars 由 App 启动预热统一负责，首页不再触发预取（避免抢占预热队列）；
    /// 未就绪的行照常展示（行内部显示占位符），绝不伪造数值。
    private func refreshIndexQuotes() {
        let metas = Array(db.metaList.lazy.filter { $0.type == Self.indexType }.prefix(4))
        let rows = metas.map { rowCache.row(for: $0, prefetch: false) }
        // 同值不写：按 metaID 比较，避免引用比较永远不等导致的无谓重绘
        if rows.map({ $0.meta.id }) != indexQuotes.map({ $0.meta.id }) {
            indexQuotes = rows
        }
    }

    // MARK: - 我的自选

    /// 我的自选 Top 5：「全部」虚拟分组（已合并所有手动分组并去重）的前 5 只，触发行预取
    private func refreshFavorites() {
        let items = fav.resolveMetaItems(groupID: fav.allGroup.id, allMeta: db.metaList)
        let rows = rowCache.rows(for: Array(items.prefix(5)), prefetch: true)
        if rows.map({ $0.meta.id }) != favoriteRows.map({ $0.meta.id }) {
            favoriteRows = rows
        }
    }

    // MARK: - 沪深主板聚合（涨跌家数 + 涨幅榜）

    /// 只对「已就绪（hasBars）且涨跌幅非 nil」的主板行算一次：
    /// 涨 / 跌 / 平 = pct > 0 / < 0 / == 0；涨停 >= 9.8、跌停 <= -9.8（主板 10% 口径）；
    /// 涨幅榜按 `number(.changePct)` 降序、过滤 nil 后取前 5。
    private func refreshMarketAggregates() {
        var next = HomeBreadth()
        var ranked: [(row: MarketRow, pct: Double)] = []
        for row in rowCache.rows.values where row.meta.type == Self.boardType && row.hasBars {
            guard let pct = row.number(.changePct) else { continue }
            next.validCount += 1
            if pct > 0 { next.up += 1 } else if pct < 0 { next.down += 1 } else { next.flat += 1 }
            if pct >= 9.8 { next.limitUp += 1 }
            if pct <= -9.8 { next.limitDown += 1 }
            ranked.append((row, pct))
        }
        // 尚无有效聚合 → 保持 nil（内容区显示「加载中」），不伪造数值
        let ready = next.validCount > 0
        let nextBreadth: HomeBreadth? = ready ? next : nil
        if breadth != nextBreadth { breadth = nextBreadth }
        if isMarketReady != ready { isMarketReady = ready }

        let top = ready ? ranked.sorted(by: { $0.pct > $1.pct }).prefix(5).map(\.row) : []
        if top.map({ $0.meta.id }) != topGainers.map({ $0.meta.id }) {
            topGainers = top
        }
    }

    // MARK: - 模拟账户（只读转发；金额口径由 SimStore 负责，模型不缓存）

    /// 全部账户汇总
    var simSummary: SimStore.SimAccountSummary { sim.summary(accountID: nil) }

    /// 持仓前 5
    var simTopPositions: [SimPosition] { Array(sim.positions.prefix(5)) }

    /// 单笔持仓快照（现价 / 市值 / 盈亏）
    func simSnapshot(for p: SimPosition) -> SimStore.SimPositionSnapshot { sim.snapshot(for: p) }
}
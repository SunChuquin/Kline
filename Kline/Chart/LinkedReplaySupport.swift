//
//  LinkedReplaySupport.swift
//  Kline
//
//  联动「历史时点复盘」支撑类型与后台求值。
//  从 KlineChartView.swift 拆分而来，KlineChartView 与 SubChartCanvas 共享这些类型；
//  依赖 FormulaEngine.swift（TDXOutputLine / TDXFormulaEngine / tdxAllNaN）。
//

import Foundation
import SwiftUI
import Combine

// MARK: - 主/副图单点合成替换结构

/// 主图 Canvas 的单点合成K线替换：index 为可见切片(slice)本地索引，item 已按镜像需要取负。
/// 联动复盘态下，光标所在的大周期 K 线用来源周期数据实时合成，由该结构在绘制时单点替换。
struct SyntheticBar: Equatable {
    let index: Int
    let item: KlineItem

    // 自定义相等：忽略 KlineItem 每次合成新生成的 UUID（仅比 OHLCV 内容），
    // 保证 MainChartCanvas.equatable() 在合成内容未变时不做无意义重绘
    static func == (l: SyntheticBar, r: SyntheticBar) -> Bool {
        l.index == r.index
            && l.item.date == r.item.date
            && l.item.open == r.item.open
            && l.item.high == r.item.high
            && l.item.low == r.item.low
            && l.item.close == r.item.close
            && l.item.volume == r.item.volume
            && l.item.turnover == r.item.turnover
    }
}

/// 副图 Canvas 的单点合成柱替换（VOL/AMO）：index 为可见切片本地索引，value 已按镜像需要取负。
struct SyntheticStick: Equatable {
    let index: Int
    let value: Double
    let isUp: Bool

    static func == (l: SyntheticStick, r: SyntheticStick) -> Bool {
        l.index == r.index && l.value == r.value && l.isUp == r.isUp
    }
}

// MARK: - 来源周期 K 线懒加载缓存

/// 联动复盘用：按 (标的, 来源周期) 懒加载来源周期K线（升序），同进程多个 tile 共享
/// （月线、季线视图合成同一标的的周线时只查一次 DB）。行情库在会话内不变，进程内缓存不做失效；
/// 切换周期/标的导致图表 .id 重建后，新实例直接命中。
final class LinkSourceBarCache: ObservableObject {
    static let shared = LinkSourceBarCache()

    struct Key: Hashable {
        let metaID: Int
        let period: KlinePeriod
    }

    /// 每次有新的一组数据加载完成即递增，驱动各图表重新派生合成K线
    @Published private(set) var revision = 0

    private var storage: [Key: [KlineItem]] = [:]
    private var inflight = Set<Key>()
    private let lock = NSLock()

    /// 同步读取已缓存的来源周期K线（升序）；未加载返回空数组（不区分"无数据"与"加载中"，
    /// 两种情况下调用方都先按真实K线绘制，request 完成后经 revision 刷新为合成形态）
    func bars(metaID: Int, period: KlinePeriod) -> [KlineItem] {
        lock.lock(); defer { lock.unlock() }
        return storage[Key(metaID: metaID, period: period)] ?? []
    }

    /// 命中缓存或已在途时无操作；否则后台查询一次，完成后在主线程递增 revision
    func request(metaID: Int, period: KlinePeriod) {
        let key = Key(metaID: metaID, period: period)
        lock.lock()
        if storage[key] != nil || inflight.contains(key) { lock.unlock(); return }
        inflight.insert(key)
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            // fetchBars 返回 date DESC，统一排序为升序供二分与聚合
            let sorted = DatabaseManager.shared.fetchBars(metaId: metaID, period: period)
                .sorted { $0.date < $1.date }
            DispatchQueue.main.async {
                self.lock.lock()
                self.storage[key] = sorted
                self.inflight.remove(key)
                self.lock.unlock()
                self.revision += 1
            }
        }
    }
}

// MARK: - 训练态「时点合成」：训练日所在大周期 K 线的「形成中」形态

/// 训练态时点合成：与联动复盘的 `synthesizeBar` **同口径**，只是把「光标日」换成「训练日」——
/// 训练日落在某根大周期 K 线覆盖区间内时，那根应按「本标的日线从该周期起点聚合到训练日」的形态显示：
/// 开 = 区间首根日线开、收 = 训练日（区间末根日线）收、高/低 = 包络、量/额 = 累加。
///
/// 为什么不做「按训练日重新切片再喂给图表」：那样每推进一个训练日都要重查库 + 重建视图实例，
/// 表现为整屏闪烁（图表先白屏转圈、指标曲线又从头算）。本函数只产出**一根合成 K 线**，
/// 由图表在绘制时做单点替换（与联动复盘 SyntheticBar 同一机制），训练日推进因此退化为
/// 「窗口右移一根」——与非训练态手拖主图完全同一条廉价路径。
enum TrainingAsOfSeries {

    /// - Parameters:
    ///   - targetDate: 目标大周期 K 线自身的日期（= 该周期首个交易日）
    ///   - period: 目标周期（日线无需合成，调用方自行跳过）
    ///   - trainingDate: 训练日 YYYYMMDD
    ///   - daily: **该标的自己的**日线，**date 升序**（与 LinkSourceBarCache 同约定）
    /// - Returns: 合成 K 线（date 沿用 targetDate）；区间内无日线 / 参数非法 → nil（回退显示库内真实 K 线）
    static func formingBar(targetDate: Int, period: KlinePeriod,
                           trainingDate: Int, daily: [KlineItem]) -> KlineItem? {
        guard trainingDate > 0, !daily.isEmpty else { return nil }
        let (periodStart, _) = KlinePeriod.periodDateRange(period, date: targetDate)
        // 升序日线中二分定位聚合区间 [periodStart, trainingDate]
        var lo = 0, hi = daily.count - 1, start = daily.count
        while lo <= hi {
            let mid = (lo + hi) / 2
            if daily[mid].date >= periodStart { start = mid; hi = mid - 1 } else { lo = mid + 1 }
        }
        guard start < daily.count else { return nil }
        var end = -1
        lo = start; hi = daily.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if daily[mid].date <= trainingDate { end = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard end >= start else { return nil }   // 区间内无日线（停牌/无数据）→ 回退真实 K 线
        var high = -Double.greatestFiniteMagnitude
        var low = Double.greatestFiniteMagnitude
        var volume = 0.0
        var turnover = 0.0
        for k in start...end {
            let bar = daily[k]
            if bar.high > high { high = bar.high }
            if bar.low < low { low = bar.low }
            volume += bar.volume
            turnover += bar.turnover
        }
        return KlineItem(date: targetDate, open: daily[start].open, high: high, low: low,
                         close: daily[end].close, volume: volume, turnover: turnover)
    }
}

// MARK: - 联动复盘：合成点指标 as-of 单点重算（后台异步 + 进程内缓存）

/// 一次 as-of 结果的缓存键：同一(标的,目标周期,来源周期,光标日期,指标配置)只算一次，
/// 拖回去时零开销；配置/周期/标的变化自动 miss
struct AsOfKey: Hashable {
    let metaID: Int
    let targetPeriod: KlinePeriod
    let sourcePeriod: KlinePeriod
    let date: Int
    let fingerprint: String
}

/// as-of 求值结果：主图与三个副图分别按「曲线数组下标 → 合成点值」存储。
/// 下标与 mainCurves / SubChartModel.curves 的行顺序严格同源（同过滤规则），只覆盖合成点一个值。
struct AsOfResult {
    var main: [Int: Double] = [:]
    var subs: [[Int: Double]] = [[:], [:], [:]]
}

/// as-of 结果进程内缓存（LRU 上限保护，光标来回拖动命中零计算；不写入 ChartCacheStore，
/// 避免污染正常指标体系与后台预计算）
final class AsOfValueCache {
    static let shared = AsOfValueCache()
    private var storage: [AsOfKey: AsOfResult] = [:]
    private var order: [AsOfKey] = []
    private let limit = 240
    private let lock = NSLock()

    func get(_ key: AsOfKey) -> AsOfResult? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func put(_ key: AsOfKey, _ result: AsOfResult) {
        lock.lock(); defer { lock.unlock() }
        if storage[key] == nil {
            order.append(key)
            while order.count > limit, let old = order.first {
                order.removeFirst()
                storage[old] = nil
            }
        }
        storage[key] = result
    }
}

/// 联动复盘 as-of 结算模型：KlineChartView 每实例一份（@StateObject 持有），收敛原本散落的三个 @State。
/// 主图曲线按数组下标的合成点值（仅合成索引一个点）+ 三个副图各自的结果 + 后台任务序号。
/// 全部为低频异步写入（合成内容/光标日期/指标配置变化时才调度），写入触发本视图重绘（与原 @State 一致，性能中性）。
final class ReplayAsOfModel: ObservableObject {
    /// 主图 as-of 结果：曲线数组下标 → 合成点值（仅合成索引一个点）
    @Published var main: [Int: Double] = [:]
    /// 三个副图各自 as-of 结果：槽位下标 → 曲线数组下标 → 合成点值
    @Published var subs: [[Int: Double]] = [[:], [:], [:]]
    /// 上述结果对应的**合成点全局索引**（nil = 无结果）。用于区分"这个点已有 as-of 值"与
    /// "新目标点位的 as-of 还在引擎回包路上"——后者绝不能用库内（可能含未来数据）的值顶上，
    /// 否则就是"先显示未来数据、过一会才跳到 as-of 值"的闪烁。
    @Published var appliedIndex: Int?
    /// **在途**的 as-of 目标索引（不够 = nil）：调度了一次未命中缓存的求值时置位，
    /// 结果回包/清场时归 nil。仅用于渲染判定"该点该留空而不是拿库内值顶上"。
    @Published var pendingIndex: Int?
    /// as-of 后台任务序号：只接受最新一次调度的结果，快速拖动时过期结果直接丢弃
    @Published var ticket = 0
}

/// as-of 后台求值请求（主线程构造：公式文本与数据在此取齐，后台只做纯计算，不碰任何 ObservableObject）
struct AsOfRequest {
    let key: AsOfKey
    /// [0...合成索引] 的K线，末项已替换为合成K线
    let data: [KlineItem]
    /// 主图启用指标公式（顺序与 mainIndicatorEntries 一致：.tdx defs → 自定义）
    let mainFormulas: [String]
    /// 副图三槽：VOL/AMO/无指标为 nil；自定义/系统公式带 isCustom 标记
    struct Sub {
        let formula: String
        let isCustom: Bool
    }
    let subs: [Sub?]
}

/// 后台执行 as-of 求值：主图 + 副图公式文本合并为**一次** Python 调用（text_eval，
/// 解析+拆分+求值全在 Python；单元级错误隔离），**只取每条输出行末点值**。
/// 行的保留/跳过规则必须与前台 recomputeMainCurves / recomputeSub 严格一致，
/// 结果下标才能与当前 curves 数组一一对齐：
/// - 主图：每输出行单元成功（末值非 NaN）才占一个曲线位；
/// - 副图自定义：全部输出行；
/// - 副图系统指标：过滤全 NaN 行（recomputeSub 的 guard !allNaN）；
/// - VOL/AMO：不入此通道（合成量/额在阶段 A 处理）。
/// 线程约束：调用方在后台线程（evaluateFormulasWithUnits 内部 assert）。
func evaluateAsOf(_ req: AsOfRequest) -> AsOfResult {
    var result = AsOfResult()

    // 收集全部公式文本：主图条目 + 副图槽位（槽位下标对齐）
    enum Slot {
        case main                 // 主图：每单元成功才占一个 mainCurves 位
        case sub(slot: Int, isCustom: Bool)
    }
    var texts: [String] = []
    var slots: [Slot] = []
    for formula in req.mainFormulas where !formula.isEmpty {
        texts.append(formula)
        slots.append(.main)
    }
    for (slot, sub) in req.subs.enumerated() {
        guard let sub, !sub.formula.isEmpty else { continue }
        texts.append(sub.formula)
        slots.append(.sub(slot: slot, isCustom: sub.isCustom))
    }

    // 一次 Python 批量求值（后台线程；引擎未就绪 → 整体失败，各槽不占位）
    guard !texts.isEmpty else { return result }
    let perFormula = PyTDXFormulaBridge.evaluateFormulasWithUnits(formulas: texts, data: req.data)

    // 回填：主图成功单元按序占位；副图行按保留规则逐行占位（规则与前台一致）
    var mainIndex = 0
    for (k, slot) in slots.enumerated() {
        guard k < perFormula.count, case .success(let units) = perFormula[k] else { continue }
        switch slot {
        case .main:
            for unit in units {
                // 与 mainRows 同源：每个单元成功（目标行末值有效）才占一个 mainCurves 位
                if unit.error == nil, let out = unit.lines.last,
                   !tdxAllNaN(out.values),
                   let v = out.values.last, !v.isNaN {
                    result.main[mainIndex] = v
                    mainIndex += 1
                }
            }
        case .sub(let slotIdx, let isCustom):
            var curveIndex = 0
            for unit in units {
                // 自定义行全部保留；系统行过滤全 NaN（与前台同一规则）
                guard isCustom || unit.error != nil || !tdxAllNaN(unit.lines.last?.values ?? []) else { continue }
                if let v = unit.lines.last?.values.last, !v.isNaN {
                    result.subs[slotIdx][curveIndex] = v
                }
                curveIndex += 1
            }
        }
    }
    return result
}

// MARK: - KlineChartView 联动复盘核心派生与调度（跨文件 extension，从 KlineChartView.swift 拆分）

/// 一次复盘的核心状态：光标所在的本周期K线全局索引 + 该索引的合成K线（同周期/数据未就绪为 nil）。
/// 纯渲染派生：cursorDate 消失即整体为 nil，合成/淡化零残留。
struct LinkReplay: Equatable {
    let idx: Int
    let synthetic: KlineItem?
    /// 未来淡化起始全局索引（合成/光标K线的下一根）
    var dimFrom: Int { idx + 1 }
}

/// as-of 重算触发签名：光标日期/位置、合成OHLCV内容、指标配置任一变化都重新求值；
/// 同周期（synthetic=nil）/范围框/无光标时为 nil（真实库值即显示值，无需重算）
struct AsOfTrigger: Equatable {
    let date: Int
    let idx: Int
    let sourcePeriod: KlinePeriod
    let open, high, low, close, volume, turnover: Double
    let fingerprint: String
    let targetCount: Int
}

extension KlineChartView {

    // MARK: - 联动「历史时点复盘」（目标周期 ≥ 来源周期）

    /// 当前是否处于复盘态及其内容。与双竖轴范围框（rank <）互斥：
    /// - rank 严格大于来源周期：合成"形成中K线"（需本标的来源周期数据，已懒加载则即时合成），其后K线淡化；
    /// - rank 相等（同周期，含跨标的）：**不进入复盘**（返回 nil），保持普通十字光标联动——
    ///   光标那根本就是真实K线，不合成、其后K线也不淡化（2026-09-14 用户确认调整，推翻早期"同周期也淡化"）；
    /// - 来源数据未加载/区间无K线（停牌）：synthetic=nil，回退真实K线显示，淡化仍生效。
    var linkReplayState: LinkReplay? {
        guard cursorLinkEnabled, !drag.cursorDragging, !linkUserDragging,
              linkRangeIndices == nil,
              let date = linkSync.cursorDate,
              self.period.granularityRank > linkSync.sourcePeriod.granularityRank,
              let idx = linkedTargetIndex(for: date),
              idx >= 0, idx < sortedData.count else { return nil }
        var synth: KlineItem?
        if self.period.granularityRank > linkSync.sourcePeriod.granularityRank, let meta = linkedMetaID {
            synth = synthesizeBar(targetIndex: idx, asOf: date,
                                  source: linkSourceBars(for: meta, period: linkSync.sourcePeriod))
        }
        return LinkReplay(idx: idx, synthetic: synth)
    }

    /// 合成所需的来源周期 K 线（**升序**）。
    /// 训练态且来源周期为日线、标的与训练会话一致时，优先取会话**常驻内存的同步日线**
    /// （`TrainingSessionController.dailyBars`）——否则首帧异步缓存未就绪 → synthetic=nil →
    /// 那一帧只能画库内完整大周期K线，表现为"先闪未来数据那根"（用户实证：点光标时被联动大周期闪烁）。
    /// 其余情况（非训练态 / 来源不是日线 / 别的标的）走 `LinkSourceBarCache` 的异步缓存。
    func linkSourceBars(for meta: Int, period srcPeriod: KlinePeriod) -> [KlineItem] {
        if srcPeriod == .daily, let sync = TrainingSessionController.shared.dailyBars(for: meta) {
            return sync
        }
        return linkSourceCache.bars(metaID: meta, period: srcPeriod)
    }

    /// 【临时诊断，定位"点光标先闪完整大周期K线"用】训练态合成链路状态签名：
    /// 每次变化（含异步缓存从 0 → N）都会打一条日志，据此可判断是"形成中K线缺失"还是"复盘合成源为空"。
    /// 定位完成后应移除本属性与对应 onChange。
    var trainingSynthesisDiag: String? {
        guard trainingMaxDate != nil else { return nil }
        let meta = linkedMetaID ?? metaId ?? 0
        let srcPeriod = linkSync.sourcePeriod
        let syncCount = TrainingSessionController.shared.dailyBars(for: meta)?.count ?? 0
        let asyncCount = linkSourceCache.bars(metaID: meta, period: srcPeriod).count
        let replay = linkReplayState
        return "周期=\(period.rawValue) 训练日=\(trainingMaxDate ?? 0) 形成点=\(trainingFormingIndex.map(String.init) ?? "-")"
            + " 形成K线=\(trainingFormingBar != nil ? "有" : "无")"
            + " 复盘合点=\(replay?.synthetic != nil ? "有" : "无") 复盘idx=\(replay.map { String($0.idx) } ?? "-")"
            + " as-of应用点=\(asOfModel.appliedIndex.map(String.init) ?? "-") as-of在途点=\(asOfModel.pendingIndex.map(String.init) ?? "-")"
            + " 光标日=\(linkSync.cursorDate.map(String.init) ?? "-") 来源周期=\(srcPeriod.rawValue)"
            + " 同步日线=\(syncCount) 异步源[\(srcPeriod.rawValue)]=\(asyncCount)"
            + " 窗口=[\(startIndex),\(endIndex)]"
    }

    /// 可交互光标在某索引处用于显示/读数的 K 线：复盘合成态取合成K线，训练态右缘那根取形成中K线，其余取真实K线。
    /// 固定光标（pinned）索引与复盘 idx 不可能相同（联动态无 pin），故该函数可被共用读数点直接调用。
    func cursorDisplayItem(at index: Int) -> KlineItem {
        if let r = linkReplayState, r.idx == index, let s = r.synthetic { return s }
        // 训练态：右缘那根按「形成中」合成形态读数（训练日收盘 / 区间包络 / 累加量额）
        if let i = trainingFormingIndex, i == index, let s = trainingFormingBar { return s }
        return sortedData[index]
    }

    /// 确保复盘所需的（本标的, 来源周期）数据已发起加载；命中/在途时不重复查询。
    /// 在光标日期到达与图表 onAppear（切周期/标的后重建）两个入口调用。
    func ensureLinkSourceBars() {
        // cursorDate 为 nil（无活动光标）时绝不请求，否则 onAppear 会用默认 sourcePeriod 误取
        guard cursorLinkEnabled, linkSync.cursorDate != nil,
              self.period.granularityRank > linkSync.sourcePeriod.granularityRank,
              let meta = linkedMetaID else { return }
        linkSourceCache.request(metaID: meta, period: linkSync.sourcePeriod)
    }

    /// 用来源周期K线合成目标大周期光标所在那根"形成中K线"。
    /// 聚合区间 = [本目标K线所属大周期的起始边界 …… ≤asOf 的最后一根来源K线]：
    /// 开=首根开、收=末根收、高/低=包络、量/额=累加；合成K线日期沿用目标周期K线起始日。
    /// source 为空（未加载/无数据）或区间内无K线时返回 nil。
    func synthesizeBar(targetIndex idx: Int, asOf date: Int, source src: [KlineItem]) -> KlineItem? {
        guard !src.isEmpty, idx >= 0, idx < sortedData.count else { return nil }
        let target = sortedData[idx]
        let (periodStart, _) = KlinePeriod.periodDateRange(self.period, date: target.date)
        guard let lo = lowerBoundSorted(src, periodStart),
              let hi = lastIndexNotAfter(src, date), hi >= lo else { return nil }
        var open = 0.0
        var close = 0.0
        var high = -Double.greatestFiniteMagnitude
        var low = Double.greatestFiniteMagnitude
        var volume = 0.0
        var turnover = 0.0
        for k in lo...hi {
            let it = src[k]
            if k == lo { open = it.open }
            close = it.close
            if it.high > high { high = it.high }
            if it.low < low { low = it.low }
            volume += it.volume
            turnover += it.turnover
        }
        return KlineItem(date: target.date, open: open, high: high, low: low,
                         close: close, volume: volume, turnover: turnover)
    }

    /// 升序 K 线序列中第一个 date >= target 的下标（无则 nil）
    func lowerBoundSorted(_ src: [KlineItem], _ target: Int) -> Int? {
        var lo = 0
        var hi = src.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if src[mid].date < target { lo = mid + 1 } else { hi = mid }
        }
        return src[lo].date >= target ? lo : nil
    }

    /// 升序 K 线序列中最后一个 date <= target 的下标（无则 nil）
    func lastIndexNotAfter(_ src: [KlineItem], _ target: Int) -> Int? {
        var lo = 0
        var hi = src.count - 1
        var ans: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if src[mid].date <= target { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    // MARK: - 训练态「形成中大周期K线」（与联动复盘同一套单点合成机制，**不重载数据**）

    /// 训练日所在的本周期 K 线全局索引（= 右缘上界；非训练态 / 训练日早于本周期第一根 → nil）
    var trainingFormingIndex: Int? { trainingMaxDate == nil ? nil : trainingEndIndex }

    /// 训练态形成中K线：训练日落在某根大周期 K 线覆盖区间内时，用**本标的**日线聚合到训练日合成该根。
    /// 非训练态 / 日线周期 / 该周期在训练日之前就已走完（库内那根即完整形态）/ 日线未加载 → nil。
    ///
    /// ⚠️ 日线取 `linkedMetaID ?? metaId`，即**该格/该图自己的标的**：多图各格标的可能不同，绝不串数据。
    /// ⚠️ 数据源**优先取训练会话常驻内存的同步日线**（`TrainingSessionController.dailyBars`）：
    /// 否则首帧异步缓存未就绪时，本函数返回 nil → 该格先画库内那根完整大周期K线（含训练日之后的数据），
    /// 表现为"先闪一根未来数据、过一会才变成训练日聚合"（用户实证）。非训练标的（多图里别的标的）才回退异步缓存。
    var trainingFormingBar: KlineItem? {
        guard let maxDate = trainingMaxDate, period != .daily,
              let idx = trainingEndIndex, idx >= 0, idx < sortedData.count,
              let meta = linkedMetaID ?? metaId else { return nil }
        let target = sortedData[idx]
        let (start, end) = KlinePeriod.periodDateRange(period, date: target.date)
        // 训练日必须仍落在这根 K 线的覆盖区间内；该周期已走完时库内那根就是真实完整形态，无需合成
        guard maxDate >= start, maxDate <= end else { return nil }
        let src: [KlineItem]
        if let sync = TrainingSessionController.shared.dailyBars(for: meta) {
            src = sync
        } else {
            src = linkSourceCache.bars(metaID: meta, period: .daily)
        }
        guard !src.isEmpty else { return nil }
        return TrainingAsOfSeries.formingBar(targetDate: target.date, period: period,
                                             trainingDate: maxDate, daily: src)
    }

    /// 确保形成中K线所需的（本标的, 日线）数据已发起加载（命中缓存 / 已在途 → 零开销）。
    /// 在图表 onAppear 与训练日推进两个入口调用；数据到达后由 linkSourceCache.revision 驱动重绘。
    func ensureTrainingSourceBars() {
        guard trainingMaxDate != nil, period != .daily, let meta = linkedMetaID ?? metaId else { return }
        linkSourceCache.request(metaID: meta, period: .daily)
    }

    /// 画布（蜡烛 / 曲线 / 量柱）的合成点全局索引：合成点必须落在可见窗口内才谈得上绘制。
    /// 联动复盘光标点优先（语义与改动前完全一致），其次是训练态形成中K线。
    var asOfCanvasIndex: Int? {
        if let r = linkReplayState, r.synthetic != nil, r.idx >= startIndex, r.idx <= endIndex {
            return r.idx
        }
        if let i = trainingFormingIndex, trainingFormingBar != nil, i >= startIndex, i <= endIndex {
            return i
        }
        return nil
    }

    /// 图例数值栏 / 行情读数行的合成点索引：只有"正在读的就是合成点那根"时才覆盖读数。
    /// 无光标时图例读 `endIndex`（见 `legendValue`），故训练态要求形成中K线恰好在右缘。
    var asOfLegendIndex: Int? {
        if let r = linkReplayState, r.synthetic != nil, r.idx == renderCursorIndex { return r.idx }
        if let i = trainingFormingIndex, trainingFormingBar != nil, i == (legendCursorIndex ?? endIndex) {
            return i
        }
        return nil
    }

    /// 训练态 as-of 触发（与联动复盘 `asOfTrigger` 同构；联动态已有光标时以光标为准）
    var trainingAsOfTrigger: AsOfTrigger? {
        guard let idx = trainingFormingIndex, let s = trainingFormingBar else { return nil }
        return AsOfTrigger(date: trainingMaxDate ?? s.date, idx: idx, sourcePeriod: .daily,
                           open: s.open, high: s.high, low: s.low, close: s.close,
                           volume: s.volume, turnover: s.turnover,
                           fingerprint: Self.currentConfigFingerprint(period: period),
                           targetCount: sortedData.count)
    }

    /// 当前生效的 as-of 触发：联动复盘光标优先 → 训练态训练日
    var effectiveAsOfTrigger: AsOfTrigger? { asOfTrigger ?? trainingAsOfTrigger }

    // MARK: 复盘指标 as-of 调度

    var asOfTrigger: AsOfTrigger? {
        guard let r = linkReplayState, let s = r.synthetic else { return nil }
        return AsOfTrigger(date: linkSync.cursorDate ?? s.date, idx: r.idx,
                           sourcePeriod: linkSync.sourcePeriod,
                           open: s.open, high: s.high, low: s.low, close: s.close,
                           volume: s.volume, turnover: s.turnover,
                           fingerprint: Self.currentConfigFingerprint(period: period),
                           targetCount: sortedData.count)
    }

    /// 合成点在途判定：该点位的 as-of 已调度但尚未回包，且没有可复用的同点位结果。
    /// 渲染侧据此把这个点**留空**（而不是拿库内完整大周期K线算出的值顶上再跳变）。
    /// 同根 K 线内继续拖动光标时（`appliedIndex == idx`）返回 false —— 保留上一次结果，
    /// 与联动复盘既有行为一致（避免拖动过程中该点反复空白）。
    func asOfWaiting(at idx: Int) -> Bool {
        asOfModel.appliedIndex == idx ? false : (asOfModel.pendingIndex == idx)
    }

    /// 主图某条曲线的 as-of 读数（仅当图例正在读合成点那根时返回；联动复盘 / 训练态共用）。
    /// 合成点在途 → 返回 **NaN**：图例只显示名称、不显示数值，避免"先显示库内（含未来数据）的值
    /// → 回包后再跳变"的闪烁。
    func asOfMainOverride(_ lineIndex: Int) -> Double? {
        guard let idx = asOfLegendIndex else { return nil }
        if asOfModel.appliedIndex == idx { return asOfModel.main[lineIndex] }
        if asOfModel.pendingIndex == idx { return .nan }
        return nil
    }

    /// 某副图槽位某条曲线的 as-of 读数（联动复盘 / 训练态共用；在途同样返回 NaN 抑制跳变）
    func asOfSubOverride(slot: Int, lineIndex: Int) -> Double? {
        guard slot >= 0, slot < asOfModel.subs.count, let idx = asOfLegendIndex else { return nil }
        if asOfModel.appliedIndex == idx { return asOfModel.subs[slot][lineIndex] }
        if asOfModel.pendingIndex == idx { return .nan }
        return nil
    }

    /// 按 trigger 调度 as-of 重算（缓存命中即时应用；否则后台求值、序号防过期）。
    /// trigger 为 nil 时清空所有 override（同周期/范围框/无光标/退联动）。
    func scheduleAsOf(_ t: AsOfTrigger?) {
        asOfModel.ticket += 1
        guard let t else {
            asOfModel.main = [:]
            asOfModel.subs = [[:], [:], [:]]
            asOfModel.appliedIndex = nil
            asOfModel.pendingIndex = nil
            return
        }
        let metaID = linkedMetaID ?? metaId ?? 0
        let key = AsOfKey(metaID: metaID, targetPeriod: period, sourcePeriod: t.sourcePeriod,
                          date: t.date, fingerprint: t.fingerprint)
        if let cached = AsOfValueCache.shared.get(key) {
            asOfModel.main = cached.main
            asOfModel.subs = cached.subs
            asOfModel.appliedIndex = t.idx
            asOfModel.pendingIndex = nil
            return
        }
        guard t.idx >= 0, t.idx < sortedData.count else { return }
        // 未命中缓存 → 标记"该点在途"：渲染侧据此把该曲线点留空（NaN），
        // 而不是显示基于库内完整大周期K线（含未来数据）的值再跳变
        asOfModel.pendingIndex = t.idx
        // 主线程构造请求：取齐公式文本与[0...idx]截断数据（末项替换为合成K线）
        let synth = KlineItem(date: sortedData[t.idx].date, open: t.open, high: t.high, low: t.low,
                              close: t.close, volume: t.volume, turnover: t.turnover)
        var data = Array(sortedData[0...t.idx])
        data[data.count - 1] = synth
        let customFormula = activeCustomIndicator?.formula
        let entries = mainIndicatorEntries(store: SystemIndicatorStore.shared,
                                           customStore: customStore, config: config,
                                           customFormula: customFormula, period: period)
        var subs: [AsOfRequest.Sub?] = []
        for m in [subTop, subBottom, subThird] {
            if m.kind == "VOL" || m.kind == "AMO" {
                subs.append(nil)   // 合成量/额走阶段 A 通道
            } else if let cid = m.activeCustomID,
                      let c = customStore.indicators.first(where: { $0.id == cid }) {
                subs.append(.init(formula: c.formula, isCustom: true))
            } else if let f = SystemIndicatorStore.shared.formula(for: m.kind, values: [:], period: period) {
                subs.append(.init(formula: f, isCustom: false))
            } else {
                subs.append(nil)
            }
        }
        let req = AsOfRequest(key: key, data: data,
                              mainFormulas: entries.map(\.formula), subs: subs)
        let ticket = asOfModel.ticket
        DispatchQueue.global(qos: .userInitiated).async {
            let result = evaluateAsOf(req)
            DispatchQueue.main.async {
                // 期间已有更新的调度（或光标消失/清场）→ 丢弃本次结果
                guard ticket == self.asOfModel.ticket else { return }
                AsOfValueCache.shared.put(key, result)
                self.asOfModel.main = result.main
                self.asOfModel.subs = result.subs
                self.asOfModel.appliedIndex = t.idx
                self.asOfModel.pendingIndex = nil
            }
        }
    }

    // MARK: - 联动视图形态判定与光标读数（从 KlineChartView.swift 拆分）

    /// 二分下界：第一个 date >= target 的下标；找不到返回 nil。
    /// 与 nearestIndex 不同，它不做「更近者」回退 —— 只返回严格下界，
    /// 用于精确框出 [range.0, range.1] 两竖轴各自对应的 K 线下标。
    func lowerBound(_ target: Int) -> Int? {
        guard !sortedData.isEmpty else { return nil }
        var lo = 0
        var hi = sortedData.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedData[mid].date < target { lo = mid + 1 } else { hi = mid }
        }
        return sortedData[lo].date >= target ? lo : nil
    }

    /// 联动来源为「更大周期」时，本视图（更小周期）要框出来的日期范围对应的两个 K 线下标。
    /// 仅当开启光标联动、非本地拖动、来源日期存在、来源周期严格大于本视图周期时才生效。
    /// 生效时本视图不显示十字光标，而由 linkRangeAxisOverlay 画两根无标签竖轴框住该范围。
    var linkRangeIndices: (left: Int, right: Int)? {
        guard cursorLinkEnabled, !drag.cursorDragging, !linkUserDragging,
              linkSync.cursorDate != nil,
              let rng = linkSync.sourceRange,
              self.period.granularityRank < linkSync.sourcePeriod.granularityRank else { return nil }
        let left = lowerBound(rng.0) ?? 0
        guard let rb = lowerBound(rng.1 + 1) else { return nil }   // 范围右边界越出本视图数据 → 无法框出
        let right = rb - 1
        guard right >= left else { return nil }                     // 本视图完全没有落在范围内的K线
        return (left, right)
    }

    /// 联动会话进行中（已有来源光标）且本视图**不是来源视图**：本视图的点击/拖动不得接管来源。
    /// 注意必须用 linkSync.sourceID 判定来源身份，而非"谁的 selectedIndex 非空"——
    /// 被联动视图不写 selectedIndex，且来源切换/取消后来源身份只由共享对象唯一维护。
    var isLinkedNonSource: Bool {
        cursorLinkEnabled && linkSync.cursorDate != nil && linkSync.sourceID != selfIndex
    }

    /// 非来源的**大周期复盘视图**（本视图周期严格大于来源周期）：
    /// 单指拖动恢复为正常平移 / 上下缩放窗口；主图区域轻点可放纯本地「第二个十字光标」；
    /// 不发布联动、不接管来源，再点也不会取消整组联动（只有来源视图再点一下才能取消）。
    var isLinkedReplayView: Bool {
        isLinkedNonSource
            && linkRangeIndices == nil
            && self.period.granularityRank > linkSync.sourcePeriod.granularityRank
    }

    /// 非来源且支持本地「第二个十字光标」的视图：**小周期范围框视图**（linkRangeIndices 非空）
    /// 或 **大周期复盘视图**（isLinkedReplayView）。
    /// 第二光标不存在时单指拖动照常平移 / 上下缩放；存在时拖动只移动第二光标；
    /// 主图区域轻点放置 / 取消第二光标；不发布联动、不接管来源。
    var isLinkedSecondCursorView: Bool {
        isLinkedNonSource && (linkRangeIndices != nil || isLinkedReplayView)
    }

    /// 非来源的**同周期视图**：忽略一切单指点击与拖动，
    /// 保持联动十字光标的既有画面（双指平移 / 缩放照常）。
    var isLinkedFrozenView: Bool {
        // ⚠️ 主格（悬浮按钮驱动的那一格）**永不冻结**：它必须始终能像「手拖主图」那样驱动光标，
        // 并在拖动过程中自然接管为联动来源。否则一旦联动态下已存在光标、且来源是别的格，
        // 主格就会被判为冻结视图 —— 手势第一帧直接 return，光标纹丝不动（像被冻住），
        // 也与规格「多图联动时以该视图为驱动、等同手拖主图」以及「点击 B' 把来源交给主格」冲突。
        // 其余非来源格保持冻结：避免多个视图互相抢着居中而打架
        isLinkedNonSource && !isLinkedSecondCursorView && !isMainTile
    }

    /// 非来源复盘 / 范围框视图中本地第二光标已存在：指标数值栏与底部行情行一律读
    /// 第二光标所指 K 线的**真实数据**（复盘视图此时不读联动复盘光标的合成 as-of 值）。
    var legendFollowsSecondCursor: Bool {
        isLinkedSecondCursorView && secondCursorIndex != nil
    }

    /// 指标数值栏 / 底部行情行读数所用光标索引：
    /// - 复盘 / 范围框视图第二光标存在 → 优先读第二光标；
    /// - 否则复盘 / 同周期视图读联动光标（renderCursorIndex），无光标时为 nil。
    var legendCursorIndex: Int? {
        if legendFollowsSecondCursor, let sIdx = secondCursorIndex { return sIdx }
        if let idx = renderCursorIndex { return idx }
        return nil
    }

    /// 清除本视图纯本地的「第二个十字光标」
    func clearSecondCursor() {
        secondCursorIndex = nil
        secondCursorY = nil
        drag.secondCursorDragging = false
    }

    /// 当前用于渲染十字光标/行情信息/时序数值栏的索引。
    /// 联动接收态（开启联动且非本地拖动）时，直接由共享 linkSync.cursorDate 解析：
    ///   联动的被联动视图无需再把联动日期写回本地 selectedIndex（那会在 @ObservedObject 触发整树
    ///   重绘之后，再叠一次 setState 重绘 → 联动拖动卡顿的根源）。改为纯渲染派生，每帧只重绘一次。
    /// 本地拖动中 / 单图模式（cursorLinkEnabled=false）时，退回本地 selectedIndex，行为与原来一致。
    var renderCursorIndex: Int? {
        // 更大周期源的联动范围模式下不显示单一十字光标（改由双竖轴框范围）
        if linkRangeIndices != nil { return nil }
        if cursorLinkEnabled, !drag.cursorDragging, !linkUserDragging {
            if let d = linkSync.cursorDate { return linkedTargetIndex(for: d) }
            return nil
        }
        return selectedIndex
    }

    /// 联动接收态下，可交互光标横线应对准的价格 = 联动到的那根K线**收盘价**
    /// （复盘合成时为合成K线收盘价，即光标所指来源K线收盘价）。
    /// 手指不在本视图，横线不再固定主图垂直中点（中点价格没有指向意义），而是精确落在该K线收盘价位。
    /// 镜像（"空"）模式下随 mir() 取负，与镜像后的价格域、蜡烛绘制保持一致；
    /// 本地手指拖动 / 单图 / 双竖轴范围框模式下返回 nil（保持原有手指跟手行为）。
    var linkedCursorClose: Double? {
        guard cursorLinkEnabled, !drag.cursorDragging, !linkUserDragging,
              let idx = renderCursorIndex, idx >= 0, idx < sortedData.count else { return nil }
        let close = cursorDisplayItem(at: idx).close
        return close > 0 ? mir(close) : nil
    }

    // MARK: - 联动光标发布 / 应用 / 定位（从 KlineChartView.swift 拆分）

    /// 把本视图光标位置（日期，YYYYMMDD 整数）发布到共享联动对象。
    /// 仅当 cursorLinkEnabled 为 true（用户显式开启了联动态的光标联动）才真正发布。
    /// 对称联动语义：任一视图只要 linkUserDragging=true 或正由用户拖动光标（drag.cursorDragging）即为来源端，
    /// 其余所有视图收到后一律滚动居中（DualLinkSync.lastCursorFromRightUser 为早期左右不对称
    /// 联动的遗留字段，当前已无任何读写方）。
    func publishLinkCursor(index: Int?) {
        guard cursorLinkEnabled else { return }
        // 只有"用户直接操作"的视图（即来源）才真正对外发布联动光标。
        // 联动接收端在 applyLinkCursor 里同步了光标位置后，会经 onChange(selectedIndex)
        // 再次走到这里；若也发布，会形成回声：接收端按各自更小周期解析出的不同 date 回传，
        // 导致来源视图收到与自己日期不一致的回声而在自己的视图里多此一举地居中。
        // 只要非用户手势触发，就视为回声、直接跳过发布。
        // 注意必须同时看 drag.cursorDragging：手指**按住不动**期间（光标贴边自动滚动）
        // 不会再有触摸事件、linkUserDragging 早已被上一次发布消费为 false，若只看它，
        // 自动滚动中每根K线的光标推进都不会广播，被联动视图整段不跟随。
        guard linkUserDragging || drag.cursorDragging else { return }
        linkUserDragging = false
        let date: Int?
        if let index, index < sortedData.count { date = sortedData[index].date } else { date = nil }
        // 记录来源周期与范围：更小周期的联动视图据此用双竖轴框出来源K线覆盖的时间范围
        linkSync.sourcePeriod = self.period
        linkSync.sourceRange = date.map { KlinePeriod.periodDateRange(self.period, date: $0) }
        // 记录来源视图身份：非来源小周期视图据此放置本地第二光标、大周期/同周期视图据此忽略手势；
        // 来源视图「再点一下」发布 nil（取消整组联动）时同步清空
        linkSync.sourceID = date == nil ? nil : selfIndex
        if linkSync.cursorDate != date { linkSync.cursorDate = date }
    }

    /// 应用另一视图发布的联动光标：把本视图光标移动到对应日期最近的 K 线。
    /// 仅当 cursorLinkEnabled=true 才响应；拖动中/同日期防回声守卫保持不变。
    /// 当前居中语义：每次联动到达（含来源端持续拖动）都把目标K线滚动到屏幕水平中央，
    /// 不再判断它是否原本就在可视窗口内——保证多个视图的同一时间点始终横向对齐。
    /// （newOffset 与当前窗口恰好一致时自然跳过滚动，不会无意义重算。）
    func applyLinkCursor(_ date: Int?) {
        // 总开关：未开启光标联动时直接忽略
        guard cursorLinkEnabled else { return }
        // 其他视图接管了联动来源（本视图不再是来源）时，本视图进行中的「光标贴边自动滚动」
        // 立即让位：否则两边各按自己的光标发布，会互相抢着居中而打架
        if drag.edgeAutoScrollDir != 0, linkSync.sourceID != selfIndex {
            stopEdgeAutoScroll()
        }
        // 本视图正在被用户直接拖动光标（手势进行中 / 贴边自动滚动中）：忽略联动。
        // 否则回声会把光标拽到别的K线，下一帧手指又拉回，产生闪烁
        if drag.cursorDragging { return }
        // 正在应用联动（非用户直接拖动）；复位来源标记，防止手势中断后粘滞
        linkUserDragging = false
        // 本视图不再属于「可承载第二光标」的形态（小周期范围框 / 大周期复盘）——
        // 如来源取消整组光标、变为同周期画面、关闭联动等——时撤销纯本地第二光标；
        // 仍是范围框 / 复盘形态时保留：来源在其视图内移动光标不应清掉它
        if !isLinkedSecondCursorView { clearSecondCursor() }
        // 更大周期源的联动范围：本视图不显示十字光标，改为自动放大可见窗口让「双竖轴」框范围并居中
        if let rg = linkRangeIndices {
            linkCursorActive = true
            centerLinkRange(left: rg.left, right: rg.right)
            notifyHasCursor()
            return
        }
        // 该日期正是本视图**本地**光标所在日期（自己发布的）→ 忽略，避免回环。
        // 注意必须用本地 selectedIndex 判断，而不能用 renderCursorIndex：
        // 被联动视图的 renderCursorIndex 直接由 linkSync.cursorDate 派生、恒等于该 date，
        // 若用它判断会永远 return，导致联动光标无法居中。
        if let li = selectedIndex, li < sortedData.count, sortedData[li].date == date { return }
        guard let date, let idx = linkedTargetIndex(for: date) else {
            // 来源光标消失 → 本次联动会话结束，下次出现再居中
            linkCursorActive = false
            notifyHasCursor()
            return
        }
        // 复盘态（本视图周期严格大于来源周期）：确保本标的来源周期数据已加载，
        // 到达后经 LinkSourceBarCache.revision 驱动合成K线重绘（同周期无需来源数据）
        ensureLinkSourceBars()
        // 被联动视图始终居中显示联动光标：每次联动更新都滚动窗口让该K线居中。
        let half = count / 2
        let targetEnd = min(sortedData.count - 1, max(count - 1, idx + half))
        let newOffset = max(0, (sortedData.count - 1) - targetEnd)
        if newOffset != endOffset {
            endOffset = newOffset
            refreshCurves()
            startPrefetch()
        }
        linkCursorActive = true
        notifyHasCursor()
    }

    /// 让 [left, right] 两根竖轴范围内的K线全部进入屏幕并尽量居中。
    /// 若范围大于当前可见数量则自动放大可见数（封顶全部K线）；否则沿用当前可见数只做居中。
    /// 双指缩放进行中时忽略（避免与手指锚定冲突）。
    func centerLinkRange(left: Int, right: Int) {
        guard !drag.twoFingerActive else { return }
        let maxEnd = sortedData.count - 1
        guard left >= 0, right >= left, right <= maxEnd else { return }
        let span = right - left + 1
        // 目标可见数：至少能容纳整个范围，但不超过本视图全部K线
        let need = min(max(span, count), capVisibleCount)
        // 范围中心对准屏幕中心：目标 end = right + (need - span) / 2，再夹到合法区间
        let slack = need - span
        let targetEnd = min(maxEnd, max(need - 1, right + slack / 2))
        let newOffset = max(0, maxEnd - targetEnd)
        // 只在有变化时刷新，避免每次来源移动都无意义重算
        if Int(visibleCount.rounded()) != need || newOffset != endOffset {
            visibleCount = CGFloat(need)
            endOffset = newOffset
            refreshCurves()
            startPrefetch()
        }
    }

    /// 联动接收态下，光标日期在本视图应定位到的 K 线索引：
    /// - 本视图周期**严格大于**来源周期（复盘态，如周→季）：取「**包含该日期的那根大周期 K 线**」
    ///   （containingIndex）——大周期 K 线日期是区间起始日，6/3 属于 Q2 就必须落在 Q2，
    ///   不能用几何最近（6/3 距 7/1 仅 28 天、距 4/1 有 63 天，最近匹配会错误跳到 Q3，
    ///   导致合成区间为空而回退显示真实完整季 K 线）；
    /// - 同周期（含跨标的）：保持"时间最近交易日"语义（nearestIndex），兼容一方停牌无当日 K 线。
    func linkedTargetIndex(for date: Int) -> Int? {
        self.period.granularityRank > linkSync.sourcePeriod.granularityRank
            ? containingIndex(to: date)
            : nearestIndex(to: date)
    }

    /// 「所属周期」匹配：最后一个起始日 date <= target 的 K 线下标——
    /// 即 target 落在该 K 线代表的周期区间内（季线存起始日 4/1，则 4/1~6/30 任意日期都归这根）。
    /// target 早于数据中第一根 K 线时回退到第一根（与 nearestIndex 的边界兜底一致）。
    func containingIndex(to target: Int) -> Int? {
        guard !sortedData.isEmpty else { return nil }
        var lo = 0
        var hi = sortedData.count - 1
        var ans = 0
        var found = false
        while lo <= hi {
            let mid = (lo + hi) / 2
            if sortedData[mid].date <= target {
                ans = mid; found = true; lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found ? ans : 0
    }

    /// 找到日期与 target 最接近的 K 线索引（日/周视图跨周期联动用）。
    /// sortedData 已按 date 升序排序 → 用二分查找定位（O(log n)），代替拖动十字光标时每帧的全量线性扫描，
    /// 显著降低联动小周期视图在持续拖动时的卡顿。
    func nearestIndex(to target: Int) -> Int? {
        guard !sortedData.isEmpty else { return nil }
        var lo = 0
        var hi = sortedData.count - 1
        // 二分找第一个 date >= target 的下标
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedData[mid].date < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        let idx = lo
        // 精确命中直接返回
        if sortedData[idx].date == target { return idx }
        // 未命中：在 idx(>=target) 与 idx-1(<target) 中取更近者
        if idx > 0 {
            if abs(sortedData[idx - 1].date - target) <= abs(sortedData[idx].date - target) {
                return idx - 1
            }
        }
        return idx
    }

    // MARK: - 联动覆盖层：第二光标横线 / 范围框双竖轴（从 KlineChartView.swift 拆分，纯渲染 struct 在下方）
}

// MARK: - MainChartCanvas 联动复盘绘制辅助（跨文件 extension，从 KlineChartView.swift 拆分）

extension MainChartCanvas {

    // MARK: 联动复盘：单点替换 / 未来淡化的绘制辅助（本地索引）

    /// 某本地索引实际用于绘制的 K 线（合成点替换）
    func effectiveItem(_ li: Int) -> KlineItem {
        if let sb = syntheticBar, sb.index == li { return sb.item }
        return slice[li]
    }

    /// 未来淡化区索引判定
    func isDimmed(_ li: Int) -> Bool {
        guard let d = dimFromIndex else { return false }
        return li >= d
    }

    /// 按淡化状态调整颜色
    func dimmed(_ color: Color, _ li: Int) -> Color {
        isDimmed(li) ? color.opacity(dimAlpha) : color
    }
}

// MARK: - 联动覆盖层纯渲染组件（props 驱动 + Equatable，配合调用点 .equatable() 跳过无效重绘）

/// 联动小周期范围框视图的本地「第二个十字光标」横线 + 左侧数值标签：
/// 只有横线与左侧标签（无右侧涨幅、无底部距今），颜色统一蓝色，横线在顶部日期标签处断开。
/// 竖线（分段贯穿主图与全部副图）与顶部日期标签由 mainCursorVLine/subCursorVLine(secondary:) 绘制。
/// 数值文本与横线避让区间由调用点计算传入（valueText / gapRanges），本组件保持纯渲染。
struct SecondCursorHorizontalOverlay: View, Equatable {
    let startIndex: Int
    let endIndex: Int
    let index: Int
    /// 横线 y（调用点已按 height clamp）
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let candleSpacing: CGFloat
    let mainTop: CGFloat, mainBottom: CGFloat, mainHeight: CGFloat
    let s1Top: CGFloat, s1Bottom: CGFloat, s1Height: CGFloat
    let s2Top: CGFloat, s2Bottom: CGFloat, s2Height: CGFloat
    let s3Top: CGFloat, s3Bottom: CGFloat, s3Height: CGFloat
    let valueText: String
    let gapRanges: [ClosedRange<CGFloat>]

    var body: some View {
        if index >= startIndex, index <= endIndex,
           isInPanel(y, mainTop, mainBottom) || isInPanel(y, s1Top, s1Bottom)
            || isInPanel(y, s2Top, s2Bottom) || isInPanel(y, s3Top, s3Bottom) {
            CrosshairLineOverlay(width: width, height: height, y: y, valueText: valueText,
                                 gapRanges: gapRanges, bgColor: Color.blue, lineColor: Color.blue)
        }
    }
}

/// 更大周期源的联动范围：在 [left, right] 两根K线处画两根无标签竖轴（含两轴间的淡色填充示意范围）。
/// 坐标与 mainCursorVLine 一致（(index-startIndex+0.5)*candleSpacing）；纵向按 panels 给出的
/// 图表面板区间分段绘制（与十字光标竖线一样被指标栏自然断开），不覆盖指标栏、时间轴与行情数据栏。
/// 水平方向按可见窗口裁剪：只要范围与窗口有重叠就绘制屏内部分——某一根竖轴被平移出屏时，
/// 另一根轴与底纹（贴屏幕边缘截断）仍然显示，而不是整个范围框消失。
struct LinkRangeAxisOverlay: View, Equatable {
    let startIndex: Int
    let endIndex: Int
    let left: Int
    let right: Int
    let candleSpacing: CGFloat
    /// 跟随亚像素平移，与蜡烛 Canvas 的 .offset(x: panOffset) 同基准
    let panOffset: CGFloat
    let panels: [(top: CGFloat, bottom: CGFloat)]

    // panels 为元组数组，元组不遵循 Equatable，无法自动合成 ==，手动逐面板比较
    static func == (l: LinkRangeAxisOverlay, r: LinkRangeAxisOverlay) -> Bool {
        l.startIndex == r.startIndex && l.endIndex == r.endIndex
            && l.left == r.left && l.right == r.right
            && l.candleSpacing == r.candleSpacing && l.panOffset == r.panOffset
            && l.panels.count == r.panels.count
            && zip(l.panels, r.panels).allSatisfy { $0.top == $1.top && $0.bottom == $1.bottom }
    }

    var body: some View {
        // 范围与可见窗口的重叠部分（全局索引）；完全无重叠则不绘制
        let visL = max(left, startIndex)
        let visR = min(right, endIndex)
        if visR >= visL {
            let xL = (CGFloat(left - startIndex) + 0.5) * candleSpacing
            let xR = (CGFloat(right - startIndex) + 0.5) * candleSpacing
            // 两根轴各自只在仍位于可见窗口内时绘制（贴边时随 panOffset 自然移出并被外层裁剪）
            let showLAxis = left >= startIndex && left <= endIndex
            let showRAxis = right >= startIndex && right <= endIndex
            ZStack {
                ForEach(Array(panels.enumerated()), id: \.offset) { _, panel in
                    if panel.bottom > panel.top {
                        let regionHeight = panel.bottom - panel.top
                        let midY = (panel.top + panel.bottom) / 2
                        // 两轴之间淡色填充，示意被框住的范围（越界部分由外层 .clipped() 裁掉）
                        if xR > xL {
                            Rectangle()
                                .fill(Color.blue.opacity(0.06))
                                .frame(width: xR - xL, height: regionHeight)
                                .position(x: (xL + xR) / 2, y: midY)
                        }
                        // 两根竖轴（无标签）；线宽 0.5 与十字光标竖轴统一，比K线上下影线（1pt）细一半
                        if showLAxis {
                            Rectangle().fill(Color.blue.opacity(0.55)).frame(width: 0.5, height: regionHeight)
                                .position(x: xL, y: midY)
                        }
                        if showRAxis {
                            Rectangle().fill(Color.blue.opacity(0.55)).frame(width: 0.5, height: regionHeight)
                                .position(x: xR, y: midY)
                        }
                    }
                }
            }
            .offset(x: panOffset)
        }
    }
}

//
//  MarketFieldKit.swift
//  Kline
//
//  Created by AI on 2026/09/01.
//
//  行情/自选页面共用的「表单字段引擎」。
//  - 每个字段 (MarketField) 定义了：key / 表头 / 对齐 / 宽度 / 颜色 / 排序方向
//  - MarketRow 是单只股票一行的全部字段值 (字典缓存)
//  - MarketFieldCache 负责根据 MetaItem + 最近 N 根日线，惰性求值并缓存字段值
//

import Foundation
import SwiftUI
import Combine
import SQLite3

// MARK: - 字段定义

/// 所有可选行级字段的枚举（通达信「表头」）
enum MarketField: String, CaseIterable, Codable, Identifiable, Hashable {
    case code           // 代码
    case name           // 名称
    case latestPrice    // 现价
    case prevClose      // 昨收
    case change         // 涨跌额
    case changePct      // 涨跌幅 (%)
    case open           // 今开
    case high           // 最高
    case low            // 最低
    case volume         // 成交量
    case turnover       // 成交额
    case amplitude      // 振幅 (%)
    case turnoverRate   // 换手率 (%)  → 没有流通股本数据时显示 "-"
    case pct3d          // 近3日涨幅
    case pct5d          // 近5日涨幅
    case pct10d         // 近10日涨幅
    case pct20d         // 近20日涨幅
    case pct60d         // 近60日涨幅
    case pctYTD         // 年初至今涨幅
    case volRatio       // 量比（当日成交量 / 过去5日均量）
    case ma5            // MA5
    case ma10           // MA10
    case ma20           // MA20
    case ma60           // MA60
    case type           // 板块类型
    case lastDate       // 数据日期

    var id: String { rawValue }

    /// 表头中文字
    var title: String {
        switch self {
        case .code: return "代码"
        case .name: return "名称"
        case .latestPrice: return "现价"
        case .prevClose: return "昨收"
        case .change: return "涨跌额"
        case .changePct: return "涨跌幅"
        case .open: return "今开"
        case .high: return "最高"
        case .low: return "最低"
        case .volume: return "成交量"
        case .turnover: return "成交额"
        case .amplitude: return "振幅"
        case .turnoverRate: return "换手"
        case .pct3d: return "3日%"
        case .pct5d: return "5日%"
        case .pct10d: return "10日%"
        case .pct20d: return "20日%"
        case .pct60d: return "60日%"
        case .pctYTD: return "今年%"
        case .volRatio: return "量比"
        case .ma5: return "MA5"
        case .ma10: return "MA10"
        case .ma20: return "MA20"
        case .ma60: return "MA60"
        case .type: return "板块"
        case .lastDate: return "数据日期"
        }
    }

    /// 默认列宽（pt，用户可配置列顺序，宽度按字段类型估）
    var defaultWidth: CGFloat {
        switch self {
        case .code: return 66
        case .name: return 84
        case .latestPrice, .prevClose, .open, .high, .low,
             .ma5, .ma10, .ma20, .ma60:
            return 70
        case .change: return 60
        case .changePct, .amplitude, .turnoverRate,
             .pct3d, .pct5d, .pct10d, .pct20d, .pct60d, .pctYTD, .volRatio:
            return 62
        case .volume, .turnover: return 78
        case .type: return 70
        case .lastDate: return 78
        }
    }

    /// 文本对齐
    var alignRight: Bool {
        switch self {
        case .code, .name, .type, .lastDate: return false
        default: return true
        }
    }

    /// 数值涨跌着色：true=上涨红色/下跌绿色
    var isTintedByChange: Bool {
        switch self {
        case .latestPrice, .prevClose, .change, .changePct,
             .open, .high, .low,
             .amplitude, .volRatio,
             .pct3d, .pct5d, .pct10d, .pct20d, .pct60d, .pctYTD:
            return true
        default:
            return false
        }
    }

    /// 默认启用的字段（用户首次进入看到的最小集合）
    static let defaultsVisible: [MarketField] = [
        .code, .name, .latestPrice, .changePct, .change,
        .volume, .turnover, .high, .low, .prevClose
    ]

    /// 仅展示文本（不需要 K 线计算的字段）
    var isMetadataOnly: Bool {
        switch self {
        case .code, .name, .type: return true
        default: return false
        }
    }
}

// MARK: - 排序键（支持升/降序 + 字段）

enum SortOrder: String, Codable {
    case ascending, descending
    var toggled: SortOrder { self == .ascending ? .descending : .ascending }
    var symbol: String { self == .ascending ? "↑" : "↓" }
}

struct MarketSortRule: Codable, Equatable, Hashable {
    var field: MarketField
    var order: SortOrder
}

// MARK: - 单只股票的一行数据（包含值缓存）

/// 一行数据：字段值通过 subscript 取值；nil 表示该字段当前无有效值（比如 K线不足、数据还没加载完）
final class MarketRow: Identifiable, Hashable {
    let metaID: Int
    let meta: MetaItem
    /// 预取最近 N 根 K 线（升序，旧→新）。nil = 尚未完成预取
    private(set) var recentBars: [KlineItem]?

    /// K 线是否已就绪（非 nil 且非空）。空数组也被视为未就绪，便于触发重取
    var hasBars: Bool { (recentBars?.isEmpty ?? true) == false }

    /// 缓存字典：计算过一次的字段 Double 值
    private var cache: [MarketField: Any] = [:]
    /// 文本渲染缓存：字段 key 是 rawValue + _txt 后缀
    private var textCache: [String: String] = [:]

    init(meta: MetaItem) {
        self.metaID = meta.id
        self.meta = meta
    }

    var id: Int { metaID }

    /// 使用最近 bars 填充（用于预取之后的一次性写入）。写入后清空之前缓存。
    func setBars(_ bars: [KlineItem]) {
        recentBars = bars
        cache.removeAll(keepingCapacity: true)
        textCache.removeAll(keepingCapacity: true)
    }

    static func == (lhs: MarketRow, rhs: MarketRow) -> Bool {
        lhs.metaID == rhs.metaID
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(metaID)
    }

    // MARK: - 字段取值入口

    /// 获取字段的 Double 值（数值字段）；非数值字段/不可用返回 nil
    func number(_ f: MarketField) -> Double? {
        if let v = cache[f] as? Double { return v }
        guard let v = Self.compute(f, meta: meta, bars: recentBars) else { return nil }
        cache[f] = v
        return v
    }

    /// 获取字段的文本值（用于表格显示）
    func text(_ f: MarketField) -> String {
        let key = "\(f.rawValue)_txt"
        if let s = textCache[key] { return s }
        let s = Self.render(f, meta: meta, number: number(f), bars: recentBars)
        textCache[key] = s
        return s
    }

    /// 字段颜色：根据 changePct 的正负给出红/绿/灰
    func tintColor(_ f: MarketField) -> UIColor {
        guard f.isTintedByChange else { return .label }
        let pct = number(.changePct) ?? 0
        if pct > 0 { return .systemRed }
        if pct < 0 { return .systemGreen }
        return .label
    }

    // MARK: - 纯函数计算

    /// 给定 meta + bars（升序）→ 返回字段数值
    static func compute(_ f: MarketField, meta: MetaItem, bars: [KlineItem]?) -> Double? {
        guard let bars = bars, !bars.isEmpty else { return nil }
        let count = bars.count
        let last = bars[count - 1]
        switch f {
        // 现价
        case .latestPrice: return last.close
        // 昨收 = 倒数第二根 close；不足则退化为 open（通达信在首日时的惯例）
        case .prevClose:
            return count >= 2 ? bars[count - 2].close : nil
        case .open: return last.open
        case .high: return last.high
        case .low: return last.low
        case .volume: return last.volume
        case .turnover: return last.turnover

        // 涨跌额 / 涨跌幅
        case .change:
            guard let pc = Self.compute(.prevClose, meta: meta, bars: bars), pc > 0 else { return nil }
            return last.close - pc
        case .changePct:
            guard let pc = Self.compute(.prevClose, meta: meta, bars: bars), pc > 0 else { return nil }
            return (last.close - pc) / pc * 100.0
        case .amplitude:
            guard let pc = Self.compute(.prevClose, meta: meta, bars: bars), pc > 0 else { return nil }
            return (last.high - last.low) / pc * 100.0
        case .volRatio:
            // 当日成交量 / 前5日平均成交量（不足则尽量取到的天数）
            guard count >= 2 else { return nil }
            let today = last.volume
            let before = bars[0..<(count-1)]
            let base = Array(before.suffix(5))
            let avg = base.reduce(0.0) { $0 + $1.volume } / Double(max(base.count, 1))
            guard avg > 0 else { return nil }
            return today / avg

        // 区间涨幅
        case .pct3d:  return rangePct(bars: bars, window: 3)
        case .pct5d:  return rangePct(bars: bars, window: 5)
        case .pct10d: return rangePct(bars: bars, window: 10)
        case .pct20d: return rangePct(bars: bars, window: 20)
        case .pct60d: return rangePct(bars: bars, window: 60)
        case .pctYTD: return ytdPct(bars: bars)

        // 均线值
        case .ma5:  return ma(bars: bars, n: 5)
        case .ma10: return ma(bars: bars, n: 10)
        case .ma20: return ma(bars: bars, n: 20)
        case .ma60: return ma(bars: bars, n: 60)

        // 换手：没有流通股本 → 无法计算，保持 nil，渲染为"-"
        case .turnoverRate: return nil

        // 纯元数据（不支持数字）
        case .code, .name, .type, .lastDate: return nil
        }
    }

    /// 给定 meta + bars → 渲染成字符串
    static func render(_ f: MarketField, meta: MetaItem, number: Double?, bars: [KlineItem]?) -> String {
        switch f {
        case .code: return meta.displayCode
        case .name: return meta.name
        case .type: return meta.type
        case .lastDate:
            guard let bars = bars, let last = bars.last else { return "-" }
            return last.formattedDate
        case .volume:
            guard let v = number else { return "-" }
            return formatVolume(v)
        case .turnover:
            guard let v = number else { return "-" }
            return formatTurnover(v)
        case .changePct, .amplitude, .turnoverRate,
             .pct3d, .pct5d, .pct10d, .pct20d, .pct60d, .pctYTD:
            guard let v = number else { return "-" }
            let sign = v > 0 ? "+" : ""
            return "\(sign)\(String(format: "%.2f", v))%"
        case .change:
            guard let v = number else { return "-" }
            let sign = v > 0 ? "+" : ""
            return "\(sign)\(String(format: "%.2f", v))"
        case .volRatio:
            guard let v = number else { return "-" }
            return String(format: "%.2f", v)
        case .latestPrice, .prevClose, .open, .high, .low,
             .ma5, .ma10, .ma20, .ma60:
            guard let v = number else { return "-" }
            return String(format: "%.2f", v)
        }
    }

    // MARK: - 辅助

    /// window 日区间涨跌幅：(当日收盘 / window 前一日收盘 - 1) * 100。
    /// 不足 window 根时取到的全部（至少2根才返回）。
    static func rangePct(bars: [KlineItem], window: Int) -> Double? {
        let count = bars.count
        guard count >= 2 else { return nil }
        let start = max(0, count - window - 1)
        // start 为"起点前一根收盘"（即 window 前一日）；极端情况下 window 太大时 start=0 作为 base
        // 但若 count - 1 - start < 1（即 start == count-1），至少得往前挪1根
        let baseIdx = min(start, count - 2)
        let base = bars[baseIdx].close
        guard base > 0 else { return nil }
        let last = bars[count - 1].close
        return (last - base) / base * 100.0
    }

    static func ytdPct(bars: [KlineItem]) -> Double? {
        let count = bars.count
        guard count >= 2 else { return nil }
        let last = bars[count - 1]
        let yearOfLast = last.date / 10000
        // 找当年第一根
        var baseIdx = count - 1
        for i in stride(from: count - 1, through: 0, by: -1) {
            if bars[i].date / 10000 == yearOfLast { baseIdx = i } else { break }
        }
        // 昨收 = 当年第一根的前一根收盘（若存在），否则当年第一根的 open
        let base: Double
        if baseIdx > 0 {
            base = bars[baseIdx - 1].close
        } else {
            base = bars[baseIdx].open
        }
        guard base > 0 else { return nil }
        return (last.close - base) / base * 100.0
    }

    static func ma(bars: [KlineItem], n: Int) -> Double? {
        let tail = Array(bars.suffix(n))
        guard tail.count == n else { return nil }
        let sum = tail.reduce(0.0) { $0 + $1.close }
        return sum / Double(n)
    }

    static func formatVolume(_ v: Double) -> String {
        if v >= 100_000_000 { return String(format: "%.2f亿", v / 100_000_000) }
        if v >= 10_000 { return String(format: "%.2f万", v / 10_000) }
        return String(format: "%.0f", v)
    }
    static func formatTurnover(_ v: Double) -> String { formatVolume(v) }
}

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

    private init() {}

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
    func matchFormula(metaID: Int, formulaRaw: String, completion: @escaping (Bool) -> Void) {
        guard let row = rows[metaID] else {
            completion(false)
            return
        }
        if let bars = row.recentBars, !bars.isEmpty {
            // bars 已就绪：直接跑
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

// MARK: - 排序：给 [MarketRow] 按规则排序

extension Array where Element == MarketRow {
    func sorted(by rule: MarketSortRule?) -> [MarketRow] {
        guard let rule = rule else { return self }
        return sorted { a, b in
            let av = a.number(rule.field) ?? -Double.greatestFiniteMagnitude
            let bv = b.number(rule.field) ?? -Double.greatestFiniteMagnitude
            switch rule.order {
            case .descending: return av > bv
            case .ascending:  return av < bv
            }
        }
    }
}

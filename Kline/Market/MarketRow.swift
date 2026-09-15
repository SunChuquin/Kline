//
//  MarketRow.swift
//  Kline
//
//  单只股票一行的字段值模型（subscript 取值 + 最近 N 根日线缓存 + 格式化）。从 MarketFieldKit.swift 拆分。
//

import Foundation
import SwiftUI
import UIKit

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


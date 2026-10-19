//
//  QuoteSnapshotOracle.swift
//  KlineTests
//
//  行情快照字段的**对拍 oracle**（口径基准）—— 2026-10-19 §11.41。
//
//  背景：行情/自选字段计算已下沉为「引擎唯一来源」（`quote_snapshot.py`）。用户拍板
//  「引擎实现后严禁保留回退到 Swift 实现的方式」→ app 侧 `MarketRow` 里的 Swift 现状算法
//  **已整体删除**（含 `cache`/`compute`/`rangePct`/`ytdPct`/`ma` 与其运行时回退）。
//
//  本文件是该算法的**逐字副本**，只存在于测试目标：
//  · 生产代码不可达 → 不构成运行时回退（与 `SimRulesProjection` 的 `.swift` 对拍模式同性质）；
//  · 唯一用途：让 `QuoteSnapshotParityTests` 能把「引擎产物」与「Swift 现状口径」逐字段对拍，
//    引擎若有偏离会立刻红——按用户要求，**修在引擎侧**，不在这里改基准。
//
//  ⚠️ 修改本文件 = 修改口径基准：必须在同一提交里说明「Swift 现状确实变了」并同步改引擎。
//

import Foundation
@testable import Kline

enum QuoteSnapshotOracle {

    /// 给定 bars（升序，旧→新）→ 字段数值（与已删除的 `MarketRow.compute` 逐字同口径）。
    static func value(_ f: MarketField, bars: [KlineItem]?) -> Double? {
        guard let bars = bars, !bars.isEmpty else { return nil }
        let count = bars.count
        let last = bars[count - 1]
        switch f {
        case .latestPrice: return last.close
        case .prevClose: return count >= 2 ? bars[count - 2].close : nil
        case .open: return last.open
        case .high: return last.high
        case .low: return last.low
        case .volume: return last.volume
        case .turnover: return last.turnover

        case .change:
            guard let pc = value(.prevClose, bars: bars), pc > 0 else { return nil }
            return last.close - pc
        case .changePct:
            guard let pc = value(.prevClose, bars: bars), pc > 0 else { return nil }
            return (last.close - pc) / pc * 100.0
        case .amplitude:
            guard let pc = value(.prevClose, bars: bars), pc > 0 else { return nil }
            return (last.high - last.low) / pc * 100.0
        case .volRatio:
            guard count >= 2 else { return nil }
            let today = last.volume
            let before = bars[0..<(count - 1)]
            let base = Array(before.suffix(5))
            let avg = base.reduce(0.0) { $0 + $1.volume } / Double(max(base.count, 1))
            guard avg > 0 else { return nil }
            return today / avg

        case .pct3d:  return rangePct(bars: bars, window: 3)
        case .pct5d:  return rangePct(bars: bars, window: 5)
        case .pct10d: return rangePct(bars: bars, window: 10)
        case .pct20d: return rangePct(bars: bars, window: 20)
        case .pct60d: return rangePct(bars: bars, window: 60)
        case .pctYTD: return ytdPct(bars: bars)

        case .ma5:  return ma(bars: bars, n: 5)
        case .ma10: return ma(bars: bars, n: 10)
        case .ma20: return ma(bars: bars, n: 20)
        case .ma60: return ma(bars: bars, n: 60)

        case .turnoverRate: return nil
        case .code, .name, .type, .lastDate: return nil
        }
    }

    /// window 日区间涨跌幅：(当日收盘 / window 前一日收盘 - 1) * 100；不足 window 根时取到的全部。
    static func rangePct(bars: [KlineItem], window: Int) -> Double? {
        let count = bars.count
        guard count >= 2 else { return nil }
        let start = max(0, count - window - 1)
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
        var baseIdx = count - 1
        for i in stride(from: count - 1, through: 0, by: -1) {
            if bars[i].date / 10000 == yearOfLast { baseIdx = i } else { break }
        }
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
}

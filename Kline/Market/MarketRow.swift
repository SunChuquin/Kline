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

    /// 近 N 根日线收盘价（升序，旧→新），供卡片 / 磁贴的迷你走势使用；无数据返回空数组
    var recentCloses: [Double] { (recentBars ?? []).map(\.close) }

    /// 引擎计算的字段值缓存（阶段 C / §11.41：**字段计算的唯一来源**）
    private var pythonValues: [MarketField: Double?] = [:]
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
        pythonValues.removeAll(keepingCapacity: true)
        textCache.removeAll(keepingCapacity: true)
    }

    /// 写入 Python 引擎计算的字段值（阶段 C：行情快照下沉）。
    /// 供 MarketRowCache 在通过 Python 引擎批量计算后调用。
    ///
    /// ⚠️ §11.41 回归点：**必须同时失效该字段的文本缓存**。引擎值到达前 UI 已经渲染过一次，
    /// 那时 `number()` 为空 → `text()` 把 `"-"` 写进 `textCache`；若不失效，
    /// 之后引擎真值写入也不会让 `text()` 更新（`textCache` 只在 `setBars` 时整体清），
    /// 表现为**行情表/卡片全列恒显 "-"**（2026-10-19 实测）。
    func setPythonValue(_ value: Double?, for field: MarketField) {
        pythonValues[field] = value
        textCache.removeValue(forKey: field.rawValue + "_txt")
    }

    /// 清空引擎计算的字段值（引擎不可用 / 失败时调用）→ UI 呈**显式空态**（渲染 "-"）。
    /// §11.41：不做 Swift 兜底计算（Swift 现状算法已删除）；同样需失效文本缓存。
    func clearPythonValues() {
        pythonValues.removeAll()
        textCache.removeAll(keepingCapacity: true)
    }

    static func == (lhs: MarketRow, rhs: MarketRow) -> Bool {
        lhs.metaID == rhs.metaID
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(metaID)
    }

    // MARK: - 字段取值入口

    /// 获取字段的 Double 值（数值字段）；非数值字段 / 引擎尚未给出该字段返回 nil。
    /// §11.41：**引擎为字段计算的唯一来源**（`quote_snapshot_batch` → `setPythonValue`）。
    /// Swift 现状算法（compute / rangePct / ytdPct / ma）与其运行时回退已整体删除；
    /// 对拍基准移到测试目标 `QuoteSnapshotOracle`（仅回归网用，生产不可达）。
    func number(_ f: MarketField) -> Double? {
        guard let v = pythonValues[f] else { return nil }
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

    // MARK: - 纯函数渲染（只做展示格式化，不做数值计算）

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

    // MARK: - 辅助（展示格式化）

    static func formatVolume(_ v: Double) -> String {
        if v >= 100_000_000 { return String(format: "%.2f亿", v / 100_000_000) }
        if v >= 10_000 { return String(format: "%.2f万", v / 10_000) }
        return String(format: "%.0f", v)
    }
    static func formatTurnover(_ v: Double) -> String { formatVolume(v) }
}


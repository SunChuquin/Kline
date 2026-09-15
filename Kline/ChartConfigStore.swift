//
  ChartConfigStore.swift
  Kline
//
  图表配置持久化仓库：指标启用集合/裸K/镜像/分栏位置等跨页面持久化。
  从 KlineChartView.swift 拆分而来（纯类型移动）。
//

import SwiftUI
import Combine

// MARK: - 图表配置持久化仓库

/// 图表配置持久化仓库：K 线页重建（切换周期 / 返回行情重新进入）时保持指标与设置不重置。
final class ChartConfigStore: ObservableObject {
    static let shared = ChartConfigStore()

    /// 主图叠加指标（按周期独立，key = 周期；缺省用默认集合）。数据驱动，key 为 .tdx 指标 id。
    @Published var mainIndicatorsByPeriod: [KlinePeriod: Set<String>] = [:]
    /// 当前周期启用的主图指标（缺省 MA + CMK）
    func mainIndicators(for period: KlinePeriod) -> Set<String> {
        mainIndicatorsByPeriod[period] ?? ["MA", "CMK"]
    }
    /// 切换某主图指标的启用状态并保存到对应周期
    func toggleMainIndicator(_ id: String, period: KlinePeriod) {
        var cur = mainIndicators(for: period)
        if cur.contains(id) { cur.remove(id) } else { cur.insert(id) }
        var copy = mainIndicatorsByPeriod
        copy[period] = cur
        mainIndicatorsByPeriod = copy
    }
    @Published var showBareK = false {
        didSet { UserDefaults.standard.set(showBareK, forKey: Self.showBareKKey) }
    }
    // 当前行情周期（跨页面/跨标的持久，返回行情再进入时保持上次选择）
    @Published var selectedPeriod: KlinePeriod = .daily
    // K线类型与图层显示（设置面板）；显示组配置全标的统一持久记忆
    @Published var chartStyle: ChartStyle = .bare {
        didSet { UserDefaults.standard.set(chartStyle.rawValue, forKey: Self.chartStyleKey) }
    }
    @Published var displaySettings = ChartDisplaySettings() {
        didSet {
            if let data = try? JSONEncoder().encode(displaySettings) {
                UserDefaults.standard.set(data, forKey: Self.displaySettingsKey)
            }
        }
    }
    // 主图自定义指标（按周期独立）
    @Published var activeCustomByPeriod: [KlinePeriod: UUID] = [:]
    /// 当前周期激活的自定义指标 id
    func activeCustomIndicatorID(for period: KlinePeriod) -> UUID? {
        activeCustomByPeriod[period]
    }
    func setActiveCustom(_ id: UUID?, for period: KlinePeriod) {
        var copy = activeCustomByPeriod
        if let id { copy[period] = id } else { copy.removeValue(forKey: period) }
        activeCustomByPeriod = copy
    }
    // 全局多/空镜像（顶部导航栏按钮控制）：开启后主图与所有副图图形取负镜像（空头）
    @Published var mainMirrored = false
    /// 双联动的各分隔线位置（归一化 0..1，长度为 视图数-1；2视图=[左分界]，3=[左,中]，4=[左,中,右]）。
    /// 每靠一条分隔线独立持久记忆，点击「边」后可拖动调整对应视图宽度。
    @Published var dualSplitPositions: [Double] = [0.5] {
        didSet {
            if let data = try? JSONEncoder().encode(dualSplitPositions) {
                UserDefaults.standard.set(data, forKey: Self.splitPositionsKey)
            }
        }
    }
    /// UserDefaults 键：双联动各分隔线位置
    static let splitPositionsKey = "kline.dualLink.splitPositions"
    /// 旧版单一占比键（兼容迁移到新数组模型）
    static let legacySplitRatioKey = "kline.dualLink.splitRatio"

    /// UserDefaults 键：显示组（K线类型 / 图层显示 / 裸K）。全标的统一，persist 于本 store。
    static let chartStyleKey = "kline.config.chartStyle"
    static let showBareKKey = "kline.config.showBareK"
    static let displaySettingsKey = "kline.config.displaySettings"

    /// 取 N 个视图的分隔线位置；长度不足时补齐到 N-1 个（默认均分）
    func dualDividers(for count: Int) -> [Double] {
        let need = max(0, count - 1)
        guard need > 0 else { return [] }
        if dualSplitPositions.count == need { return dualSplitPositions }
        // 长度不匹配：重建为均分
        return (1...need).map { Double($0) / Double(count) }
    }

    // 三个副图（跨周期共享实例，但选择按周期记忆）
    let subTop = SubChartModel()
    let subBottom = SubChartModel()
    let subThird = SubChartModel()

    /// 三副图按周期记忆（key = 周期，value = 三副图选择；无记忆时用默认 CDJ/COL/MACD）
    private var subscriptByPeriod: [KlinePeriod: [SubChartSelection]] = [:]

    /// 三副图默认选择
    private static let defaultSubSelections: [SubChartSelection] = [
        SubChartSelection(kind: "CDJ", customID: nil),
        SubChartSelection(kind: "COL", customID: nil),
        SubChartSelection(kind: "MACD", customID: nil),
    ]

    /// 取某周期的三副图记忆（无记忆时返回默认选择），不修改共享模型。
    /// 后台预计算、双联动隔离视图等"不落地共享模型"的读取统一走这里，保证副图按周期完全独立。
    func subSelections(for period: KlinePeriod) -> [SubChartSelection] {
        if let s = subscriptByPeriod[period], s.count == 3 { return s }
        return Self.defaultSubSelections
    }

    /// 把某周期的三副图记忆应用进共享 subTop/subBottom/subThird（无记忆时用默认）
    func applySubKinds(for period: KlinePeriod) {
        let sels = subSelections(for: period)
        apply(sels[0], to: subTop)
        apply(sels[1], to: subBottom)
        apply(sels[2], to: subThird)
    }
    /// 记录当前三副图的选择（含自定义指标 id）到某周期
    func recordSubKinds(for period: KlinePeriod) {
        subscriptByPeriod[period] = [sel(from: subTop), sel(from: subBottom), sel(from: subThird)]
    }
    private func apply(_ s: SubChartSelection, to m: SubChartModel) {
        if m.kind != s.kind || m.activeCustomID != s.customID {
            m.kind = s.kind
            m.activeCustomID = s.customID
        }
    }
    private func sel(from m: SubChartModel) -> SubChartSelection {
        SubChartSelection(kind: m.kind, customID: m.activeCustomID)
    }

    private init() {
        // 恢复显示组配置（K线类型 / 图层显示 / 裸K）：全标的统一记忆，重启保留。
        // 注意：通用组（行情周期/联动视图数量）由各自 store 负责持久化，本 init 不触碰。
        if let raw = UserDefaults.standard.string(forKey: Self.chartStyleKey),
           let style = ChartStyle(rawValue: raw) {
            chartStyle = style
        }
        showBareK = UserDefaults.standard.bool(forKey: Self.showBareKKey)
        if let data = UserDefaults.standard.data(forKey: Self.displaySettingsKey),
           let ds = try? JSONDecoder().decode(ChartDisplaySettings.self, from: data) {
            displaySettings = ds
        }
        subTop.kind = "CDJ"
        subBottom.kind = "COL"
        subThird.kind = "MACD"
        // 恢复双联动分隔线位置记忆（优先新数组 key；旧单一占比 key 迁移为 [ratio]）
        if let data = UserDefaults.standard.data(forKey: Self.splitPositionsKey),
           let arr = try? JSONDecoder().decode([Double].self, from: data), !arr.isEmpty {
            dualSplitPositions = arr
        } else {
            let legacy = UserDefaults.standard.double(forKey: Self.legacySplitRatioKey)
            if legacy > 0 { dualSplitPositions = [legacy] }
        }
    }
}

//
//  IndicatorPipeline.swift
//  Kline
//
//  指标/预计算域：IndicatorComputationStore 状态模型 + 计算管线（3b 起包含 extension 方法）。
//  从 KlineChartView.swift 拆分而来：按"低频写入、无 .onChange 挂钩"原则打包，
//  收敛视图属性区；写入仍触发本视图 body 重绘（与原 @State 行为一致，性能中性）。
//  全部状态写入收敛在主线程（预计算循环 Task { @MainActor in } 包裹，detached 只跑纯函数）。
//

import Foundation
import SwiftUI
import Combine

/// 指标/预计算状态模型：KlineChartView 每实例一份（@StateObject 持有），
/// init 内完成跳空缺口一次性计算与 (标的, 周期) 缓存恢复（指纹一致时）。
final class IndicatorComputationStore: ObservableObject {
    // MARK: @Published（body 直接读 / 动画挂钩——若降为普通 var 渲染/动画会静默失效）
    /// 主图叠加指标曲线（渲染直接来源：mainCanvas / mainLegendRow / priceRange）
    @Published var mainCurves: [IndicatorLine] = []
    /// 后台正确计算的覆盖末端（绝对索引）：从数据开头（最左）向右逐块推进，
    /// 保证 EMA/SMA 等递归指标从第一根开始累积、数值最正确；覆盖到可见窗口末端后才替换前台近似结果。
    /// 进度条（showCoverageBar/coverageProgressBar）与 .animation(value:) 依赖此值
    @Published var bgCoverageEnd = 0

    // MARK: 普通 var（body 零读，写入不触发 objectWillChange；若未来进 body/onChange 须升 @Published）
    /// 指标已计算的覆盖区间（绝对索引，随滑动/缩放单调扩展）：
    /// 左右滑动时，只要可见窗口仍落在已覆盖范围内就复用曲线不重算，保证"已经计算过的部分不丢失"。
    /// 覆盖区间跨度超上限时（超大幅滑动）重置为当前需要区间，避免退化为全量计算
    var indicatorCoverageStart = 0
    var indicatorCoverageEnd = -1
    /// 历史指标预计算任务 token（nil = 无任务）：打开标的后分块向更久远历史预计算指标，
    /// 切换周期/标的/指标或用户交互时更新使其失效。仅管线方法读写，纯取消哨兵
    var prefetchToken: UUID? = nil
    /// 主图各指标结果缓存（class 引用，原地改 units 本就不触发重绘——原设计保留；
    /// 引用替换仅发生在缓存恢复路径，必伴随 mainCurves @Published 写）
    var mainCache = MainIndicatorCache()

    // MARK: let（init 一次定，此后只读）
    /// 全数据集预计算的跳空缺口（只在数据加载时计算一次，避免每次重绘全量扫描）
    let gaps: [GapInfo]
    /// 指标覆盖区间最大跨度：防止一次滑到很老的历史后覆盖区间扩展到全量
    let maxCoverageSpan = 2000
    /// 预计算每块向右推进的根数（单块毫秒级，块间让出主线程，不阻塞 UI）
    let prefetchBlockSize = 500
    /// 指标计算左侧预热根数：往前多算这一段历史，保证 MA（需前 N 根）与 EMA/SMA 等递归指标
    /// 在可见窗口内已收敛、数值准确；也避免每次拖动/缩放后全量重算。
    /// 取 50 使前台近似总计算量 ≈ 可见窗口(默认100) + 预热(50) ≈ 150 根，降低打开标的时的卡顿；
    /// 长周期指标在可见窗口前段的收敛精度会略降，由后台分块预计算随后覆盖为正确值
    let indicatorWarmup = 50

    /// - Parameters:
    ///   - all: 全量K线（升序）
    ///   - metaId: 标的 id；nil 时跳过缓存恢复（无标的预览等场景）
    ///   - period: 当前周期（缺口计算无关周期；缓存按 (标的, 周期) 维度恢复）
    init(all: [KlineItem], metaId: Int?, period: KlinePeriod) {
        // 全数据集预计算跳空缺口（一次计算，绘制时只按可见区间过滤）
        self.gaps = Self.computeGaps(all)
        // 同一标的内切换周期：从 (标的, 周期) 缓存恢复上次的计算结果与覆盖状态，
        // 保证切回该周期时已算过的部分不重算、不丢失（LRU 保留最近 3 个标的的所有周期）。
        // 仅当缓存所用指标配置指纹与当前一致时才恢复，否则视为无效、按新配置重新计算
        if let metaId {
            let entry = ChartCacheStore.shared.entry(for: metaId, period: period)
            let fingerprint = KlineChartView.currentConfigFingerprint(period: period)
            if entry.configFingerprint == fingerprint {
                mainCurves = entry.mainCurves
                mainCache = entry.mainCache
                indicatorCoverageStart = entry.coverageStart
                indicatorCoverageEnd = entry.coverageEnd
                bgCoverageEnd = entry.bgCoverageEnd
            }
        }
    }

    /// 跳空缺口计算（采用维护缺口列表的线性算法：缺口形成后，某根后续K线价格触及缺口区间即视为回补，
    /// 记录该K线索引为 filledIdx；从未被回补的缺口 filledIdx 为 nil（持续显示））。
    static func computeGaps(_ items: [KlineItem]) -> [GapInfo] {
        guard items.count > 1 else { return [] }
        struct Pending {
            let startIdx: Int
            let top: Double
            let bottom: Double
            let isUp: Bool
        }
        var pending: [Pending] = []
        var result: [GapInfo] = []
        for (i, cur) in items.enumerated() {
            // 当前K线触及缺口区间即回补完成，记录回补位置
            var filled: [Pending] = []
            pending.removeAll { g in
                let isFilled = cur.high >= g.bottom && cur.low <= g.top
                if isFilled { filled.append(g) }
                return isFilled
            }
            for g in filled {
                result.append(GapInfo(startIdx: g.startIdx, top: g.top, bottom: g.bottom, isUp: g.isUp, filledIdx: i))
            }
            // 与上一根K线之间形成新缺口
            if i > 0 {
                let prev = items[i - 1]
                if cur.low > prev.high {
                    pending.append(Pending(startIdx: i, top: cur.low, bottom: prev.high, isUp: true))
                } else if cur.high < prev.low {
                    pending.append(Pending(startIdx: i, top: prev.low, bottom: cur.high, isUp: false))
                }
            }
        }
        // 遍历结束后仍未回补的缺口（一直显示）
        for g in pending {
            result.append(GapInfo(startIdx: g.startIdx, top: g.top, bottom: g.bottom, isUp: g.isUp, filledIdx: nil))
        }
        return result
    }
}

// MARK: - 后台预计算（分块向历史扩展指标覆盖区间）

/// 预计算每块的指标计算请求（主线程构造，Sendable，可跨线程传给后台求值）
struct PrefetchCalcRequest {
    let calcStart: Int
    let calcEnd: Int
    let data: [KlineItem]        // 裁剪区间数据
    /// 完整基础序列（整个标的的 C/H/L/O/V/AMOUNT），各块共享引用，避免重复 map
    let series: TDXSharedSeries
    let volumes: [Double]        // 裁剪区间成交量
    let turnovers: [Double]      // 裁剪区间成交额
    /// 主图公式文本（仅启用的指标，按顺序；空串表示未启用/无自定义指标）
    let mainFormulas: [String]
    /// 主图公式对应的指标 id（与 mainFormulas 一一对应；.tdx id 或 MainIndicatorCache.customKey），
    /// 供主线程按 id 决定颜色/样式组装
    let mainIDs: [String]
    /// 副图请求（3 个，与 subTop/subBottom/subThird 对应）
    let subs: [SubPrefetchRequest]
    /// 各主图公式上一块的增量求值状态（与 mainFormulas 一一对应；nil = 从头算）
    let resumingMain: [TDXIncrementalState?]
    /// 各副图公式上一块的增量求值状态（与 subs 一一对应；nil = 从头算）
    let resumingSubs: [TDXIncrementalState?]
}

struct SubPrefetchRequest {
    let kind: String
    /// 自定义指标公式（启用自定义时非空，优先于系统公式）
    let customFormula: String?
    /// 系统指标公式（已替换参数）
    let formula: String?
    /// VOL/AMO 的均线周期
    let volPeriods: [Int]
}

/// 后台求值结果（原始输出行，主线程再组装为 IndicatorLine）
struct PrefetchCalcResult {
    /// 与 mainFormulas 一一对应
    let main: [[TDXOutputLine]]
    /// 与 subs 一一对应（VOL/AMO 为空，主线程用成交量/成交额组装）
    let subs: [[TDXOutputLine]]
    /// 各主图公式算完后的最新增量状态（供下一块延续）
    let newMainStates: [TDXIncrementalState]
    /// 各副图公式算完后的最新增量状态（供下一块延续）
    let newSubStates: [TDXIncrementalState]
}

// MARK: - 后台预计算辅助（文件级私有）
// 后台预计算（prefetchOtherPeriod/makeFullRequest/commitToCache）为 static 上下文，
// 而本工程构建配置下实例方法无法用「裸名」引用 static 成员，故用文件级函数复用，
// 与 KlineChartView 实例内配色/命名/参数逻辑保持一致。

private let prefetchUpColor = Color(red: 0.85, green: 0.16, blue: 0.16)
private let prefetchDownColor = Color(red: 0.0, green: 0.55, blue: 0.35)
private let prefetchMa10Color = Color.orange
private let prefetchBollColor = Color(red: 0.4, green: 0.4, blue: 0.9)

private func prefetchMaColor(_ i: Int) -> Color {
    let colors = [Color(.label).opacity(0.75), Color.orange, Color.pink, Color.blue,
                  Color(red: 0.9, green: 0.6, blue: 0), Color.teal, Color.purple, Color.brown]
    return colors[i % colors.count]
}

private func prefetchDisplayName(_ raw: String) -> String { raw.replacingOccurrences(of: "NOTEXT_", with: "") }

private func prefetchCustomLineColor(_ index: Int, line: TDXOutputLine, indicatorColor: Color?) -> Color {
    if let hex = line.colorHex, let c = Color(hex: hex) { return c }
    if let indicatorColor { return indicatorColor }
    let palette = [Color.blue, Color(red: 0.9, green: 0.35, blue: 0.1), Color(red: 0.2, green: 0.55, blue: 0.85),
                   Color(red: 0.6, green: 0.25, blue: 0.7), Color.teal, Color.pink]
    return palette[index % palette.count]
}

private func prefetchLineColor(from line: TDXOutputLine, fallback: Color) -> Color {
    if let hex = line.colorHex, let c = Color(hex: hex) { return c }
    return fallback
}

// MARK: - 主图数据驱动辅助（主图指标集合来自 .tdx，SCOPE=main）

/// 主图指标条目：启用的 .tdx 主图指标 + 主图自定义指标
struct MainIndicatorEntry {
    let id: String       // .tdx 文件名 id，或 MainIndicatorCache.customKey
    let formula: String
    let isCustom: Bool
}

/// 计算当前启用的主图指标条目（顺序：.tdx 主图 defs → 自定义）
func mainIndicatorEntries(store: SystemIndicatorStore,
                                  customStore: CustomIndicatorStore,
                                  config: ChartConfigStore,
                                  customFormula: String?,
                                  period: KlinePeriod) -> [MainIndicatorEntry] {
    guard !config.showBareK else { return [] }
    var entries: [MainIndicatorEntry] = []
    for def in store.mainIndicatorDefs(period: period) where config.mainIndicators(for: period).contains(def.id) {
        entries.append(MainIndicatorEntry(id: def.id,
                                          formula: store.formula(for: def.id, values: [:], period: period) ?? "",
                                          isCustom: false))
    }
    if let customFormula {
        entries.append(MainIndicatorEntry(id: MainIndicatorCache.customKey,
                                          formula: customFormula, isCustom: true))
    }
    return entries
}

/// 主图指标默认颜色（未被公式 COLORXXX 覆盖时使用）
private func mainLineDefaultColor(_ id: String, _ i: Int) -> Color {
    switch id {
    case "BOLL": return i == 0 ? prefetchMa10Color : prefetchBollColor
    case "SAR": return prefetchUpColor
    default: return prefetchMaColor(i)
    }
}

/// 主图输出行组装为 IndicatorLine：方向性标记（如 SAR）画红绿点，其余按公式样式/颜色
private func buildMainLine(id: String, isCustom: Bool, customColor: Color?,
                           i: Int, out: TDXOutputLine) -> IndicatorLine? {
    guard !tdxAllNaN(out.values) else { return nil }
    let name = prefetchDisplayName(out.name)
    if out.markerDirections != nil {
        return IndicatorLine(name: name, values: out.values, color: prefetchUpColor,
                             style: .pointdot, lineWidth: 1, hideValue: out.hideValue,
                             markerColors: out.markerDirections?.map { $0 ? prefetchUpColor : prefetchDownColor })
    }
    let color: Color
    if isCustom {
        color = prefetchCustomLineColor(i, line: out, indicatorColor: customColor)
    } else {
        color = prefetchLineColor(from: out, fallback: mainLineDefaultColor(id, i))
    }
    return IndicatorLine(name: name, values: out.values, color: color,
                         style: out.style, lineWidth: out.lineWidth, hideValue: out.hideValue)
}

/// VOL/AMO 量均线固定周期（0=隐藏，公式固定值，不再支持编辑）
private let volMAFixedPeriods: [Int] = [5, 10, 0, 0, 0, 0, 0, 0]

/// 主图各指标按「输出行」缓存计算结果：每个输出行（如一条 MA）独立缓存，
/// 只重算公式文本（含参数）变化的行，其余输出行直接复用缓存结果。
/// 例如 MA 组加一根 MA120，只有那一行的单元文本变化，其余 9 条均线复用缓存。
/// 数据变化（切换周期/标的）会重建 K 线页并重置此缓存，天然全量重算。
final class MainIndicatorCache {
    /// 单个指标的缓存：公式快照 + 拆分的输出行单元 + 每行结果
    struct UnitSet {
        /// 上次生成 units 时的完整公式文本（参数变则变，触发重新拆分）
        var formulaKey = ""
        var units: [TDXOutputLineUnit] = []
        var rows: [Row] = []
    }
    /// 单行缓存：该行单元文本 + 计算结果
    struct Row {
        var key = ""
        var line: IndicatorLine? = nil
    }
    /// 按指标 id（.tdx 文件名）缓存各主图指标的单元结果；数据驱动，新增指标自动加入
    var units: [String: UnitSet] = [:]
    /// 主图自定义指标的固定缓存 key（区别于 .tdx 系统指标）
    static let customKey = "__custom__"
}


// MARK: - KlineChartView 指标/预计算管线方法（3b 从 KlineChartView.swift 拆分，private 放宽为 internal）

extension KlineChartView {

    func displayName(_ raw: String) -> String { raw.replacingOccurrences(of: "NOTEXT_", with: "") }

    func customLineColor(_ index: Int, line: TDXOutputLine, indicatorColor: Color?) -> Color {
        if let hex = line.colorHex, let c = Color(hex: hex) { return c }
        if let indicatorColor { return indicatorColor }
        let palette = [Color.blue, Color(red: 0.9, green: 0.35, blue: 0.1), Color(red: 0.2, green: 0.55, blue: 0.85),
                       Color(red: 0.6, green: 0.25, blue: 0.7), Color.teal, Color.pink]
        return palette[index % palette.count]
    }

    // MARK: - 指标计算区间（裁剪）

    /// 指标计算区间的起点索引（绝对，需要区间）：可见窗口起点往前推预热长度，最小为 0
    var indicatorCalcStart: Int { max(0, startIndex - computation.indicatorWarmup) }
    /// 指标计算区间的终点索引（绝对，需要区间）：覆盖到可见窗口末端即可
    var indicatorCalcEnd: Int { max(indicatorCalcStart, endIndex) }

    /// 本次指标计算区间：与已覆盖区间合并（只扩不缩），并更新覆盖状态。
    /// 可见窗口落在已覆盖范围内时直接复用已覆盖区间 → 缓存键不变 → 不重算、不倒退；
    /// 需要区间超出已覆盖且扩展后跨度超上限时保持已覆盖区间，避免丢弃已算的全量历史
    func mergedCalcRange(needStart: Int, needEnd: Int) -> (start: Int, end: Int) {
        if computation.indicatorCoverageEnd >= 0 {
            // 需要区间完全落在已覆盖范围内：直接复用已覆盖区间（不重算、不倒退）
            if needStart >= computation.indicatorCoverageStart && needEnd <= computation.indicatorCoverageEnd {
                return (computation.indicatorCoverageStart, computation.indicatorCoverageEnd)
            }
            // 需要区间超出已覆盖：尝试扩展（只扩不缩）；扩展后跨度超上限时保持已覆盖区间
            let mergedStart = min(computation.indicatorCoverageStart, needStart)
            let mergedEnd = max(computation.indicatorCoverageEnd, needEnd)
            if mergedEnd - mergedStart + 1 <= computation.maxCoverageSpan {
                computation.indicatorCoverageStart = mergedStart
                computation.indicatorCoverageEnd = mergedEnd
                return (mergedStart, mergedEnd)
            }
            return (computation.indicatorCoverageStart, computation.indicatorCoverageEnd)
        }
        computation.indicatorCoverageStart = needStart
        computation.indicatorCoverageEnd = needEnd
        return (needStart, needEnd)
    }

    /// 取 [start...end] 一段作为指标计算数据（越界/空数据安全）
    func calcData(from start: Int, to end: Int) -> [KlineItem] {
        guard !sortedData.isEmpty, start <= end, end < sortedData.count else { return [] }
        return Array(sortedData[start...end])
    }

    /// 把「裁剪区间」的计算结果填充回全量长度：前段/后段用 NaN 占位（markerColors 用透明色占位），
    /// 绘制与取值处本就跳过 NaN，因此既有索引逻辑保持不变，只是计算量大幅下降
    func padToFull(_ line: IndicatorLine, calcStart: Int, calcEnd: Int) -> IndicatorLine {
        guard calcStart > 0 || calcEnd < sortedData.count - 1 else { return line }
        var values = Array(repeating: Double.nan, count: calcStart) + line.values
        let missing = sortedData.count - values.count
        if missing > 0 { values += Array(repeating: Double.nan, count: missing) }
        var result = line
        result.values = values
        if let mc = line.markerColors {
            var colors = Array(repeating: Color.clear, count: calcStart) + mc
            let colorMissing = sortedData.count - colors.count
            if colorMissing > 0 { colors += Array(repeating: Color.clear, count: colorMissing) }
            result.markerColors = colors
        }
        return result
    }

    func recomputeMainCurves(force: Bool = false) {
        // 指标/设置面板打开期间不计算（全量计算开销大），只标记主图待重算，关闭返回后再算
        if menuIsOpen { editorUI.pendingMainRefresh = true; return }
        // 拖拽期间禁止任何指标重算（重算随总 K 数线性增长，是拖拽卡顿根源）；
        // force=true 用于用户显式切换/修改指标，确保立即生效
        if !force, drag.isDragging { drag.needsRefreshAfterDrag = true; return }
        // 主图放大（全屏裸K）：不计算任何主图指标
        if mainFullscreen { computation.mainCurves = []; return }
        // 后台正确计算已覆盖整个可见窗口且指标配置未变（如退出放大恢复显示）：
        // 直接从缓存恢复完整曲线，避免在主线程全量重算所有主图指标造成明显卡顿。
        // 配置真正变化时指纹不一致，不会命中恢复，照常走下方 force 重算
        if computation.bgCoverageEnd >= endIndex, let metaId = metaId {
            let entry = ChartCacheStore.shared.entry(for: metaId, period: period)
            if entry.configFingerprint == Self.currentConfigFingerprint(period: self.period),
               entry.bgCoverageEnd >= endIndex, !entry.mainCurves.isEmpty {
                computation.mainCurves = entry.mainCurves
                computation.mainCache = entry.mainCache
                return
            }
        }
        // 后台正确计算已覆盖整个可见窗口（从数据开头起算，数值最正确）：
        // 未强制重算时直接复用后台结果；指标配置变化（force）时用正确覆盖区间重算，避免退化为近似
        let bgCovered = computation.bgCoverageEnd >= endIndex
        if bgCovered, !force, !computation.mainCurves.isEmpty { return }
        // 后台尚未覆盖可见窗口（如缩放到全部 / 滑到未算区域）：不在此同步计算近似指标，
        // 同步计算量随可见 K 数线性增长，显示全部时会阻塞主线程卡顿；保持当前已覆盖曲线，
        // 未覆盖部分渲染时因 NaN 自然显示裸K，由后台 prefetch 继续推进覆盖后替换
        if !force, !bgCovered, !computation.mainCurves.isEmpty { return }
        var curves: [IndicatorLine] = []
        if !config.showBareK {
            let store = SystemIndicatorStore.shared
            let custom = activeCustomIndicator
            // 计算区间选择（同 recomputeSub）：
            // - 联动隔离 + force（搜索切标首次 onAppear）：全量 [0..<count]，保证 warmup 完整、
            //   指标曲线与 K 线数据一一对应，避免短窗口前台近似造成主图指标缺失/错位，用户观感"数据不对"。
            // - 否则：正确覆盖用 bgCovered 全量；否则 mergedCalcRange 近似前台。
            let (calcStart, calcEnd): (Int, Int)
            if force && isolatedSubs && !sortedData.isEmpty {
                calcStart = 0
                calcEnd = sortedData.count - 1
            } else if bgCovered {
                calcStart = 0
                calcEnd = computation.bgCoverageEnd
            } else {
                (calcStart, calcEnd) = mergedCalcRange(needStart: indicatorCalcStart, needEnd: indicatorCalcEnd)
            }

            // 数据驱动：主图指标集合来自 .tdx（SCOPE=main），只计算已启用的，按输出行缓存
            let entries = mainIndicatorEntries(store: store, customStore: customStore,
                                               config: config, customFormula: custom?.formula,
                                               period: self.period)
            let customColor = customStore.indicators.first { $0.id == config.activeCustomIndicatorID(for: self.period) }?.color
            let activeIDs = Set(entries.map { $0.id })
            for entry in entries {
                curves += mainRows(for: entry.id, enabled: true, formula: entry.formula,
                                   calcStart: calcStart, calcEnd: calcEnd,
                                   build: { i, out in
                                       buildMainLine(id: entry.id, isCustom: entry.isCustom,
                                                     customColor: entry.isCustom ? customColor : nil,
                                                     i: i, out: out)
                                   })
            }
            // 清理已禁用/不再使用的指标缓存，避免残留占用
            for key in computation.mainCache.units.keys where !activeIDs.contains(key) {
                computation.mainCache.units[key] = nil
            }
        } else {
            // 裸K：不显示指标，清空自定义缓存（其余指标缓存保留，切回裸K时复用）
            computation.mainCache.units[MainIndicatorCache.customKey] = nil
        }
        computation.mainCurves = curves
        // 写回 (标的, 周期) 缓存：切走再回来时恢复主图曲线与覆盖状态，不重复计算
        if let metaId = metaId {
            let store = ChartCacheStore.shared
            let fp = Self.currentConfigFingerprint(period: self.period)
            // 配置已变：先失效旧缓存（清完成标记/覆盖/曲线），避免旧配置的“已完成”被误用
            if store.invalidateIfConfigChanged(metaId: metaId, period: period, currentFingerprint: fp) {
                // 本视图预计算进度也归零，避免写回 max 把缓存覆盖末端顶回旧值（否则恢复后 bgCovered 误判、副图空白）
                computation.bgCoverageEnd = 0
                // 取消仍在跑的旧后台任务（其 request/增量状态属于旧配置），并立即用新配置重启，
                // 否则旧任务会以旧配置结果覆盖新配置曲线（切换指标后点击主图副图被清空/错乱）
                klineDebug("[KlineDebug] 主图配置变化 bgCoverageEnd=0 重启prefetch")
                computation.prefetchToken = nil
                startPrefetch()
            }
            let e = store.entry(for: metaId, period: period)
            e.mainCurves = computation.mainCurves
            e.mainCache = computation.mainCache
            e.coverageStart = computation.indicatorCoverageStart
            e.coverageEnd = computation.indicatorCoverageEnd
            // 覆盖末端只增不减，避免后台/旧任务已算得更远时被本次写回往回推
            e.bgCoverageEnd = max(e.bgCoverageEnd, computation.bgCoverageEnd)
            e.configFingerprint = fp
        }
    }

    /// 主图单指标按「输出行」缓存求值：仅某行单元文本（含参数）变化才重算该行，其余行复用缓存。
    /// 计算使用「裁剪区间」数据（可见窗口+预热），计算量≈可见窗口+预热，与总 K 数无关
    func mainRows(for id: String,
                          enabled: Bool,
                          formula: String?,
                          calcStart: Int, calcEnd: Int,
                          build: (Int, TDXOutputLine) -> IndicatorLine?) -> [IndicatorLine] {
        guard enabled, let formula else { return [] }
        var cache = computation.mainCache.units[id] ?? MainIndicatorCache.UnitSet()
        // 公式文本变化（参数/开关外内容变）→ 重新拆分输出行单元；计算区间变化也须重建
        let formulaKey = "\(formula)|\(calcStart)|\(calcEnd)"
        if cache.formulaKey != formulaKey {
            cache.formulaKey = formulaKey
            cache.units = (try? TDXFormulaEngine.splitOutputUnits(formula: formula)) ?? []
            cache.rows = Array(repeating: MainIndicatorCache.Row(), count: cache.units.count)
        }
        let calcData = calcData(from: calcStart, to: calcEnd)
        var lines: [IndicatorLine] = []
        for (i, unit) in cache.units.enumerated() {
            // 该行单元文本与缓存一致 → 直接复用；否则只重算这一行
            if cache.rows[i].key != unit.text {
                cache.rows[i].key = unit.text
                // 单元内可能含前置输出行（如 BOLL 的 UP 依赖输出行 MID），目标行是最后一个输出行
                if let outs = try? TDXFormulaEngine.evaluate(statements: unit.statements, data: calcData),
                   let out = outs.last, let built = build(i, out), !allNaN(built.values) {
                    cache.rows[i].line = padToFull(built, calcStart: calcStart, calcEnd: calcEnd)
                } else {
                    cache.rows[i].line = nil
                }
            }
            if let line = cache.rows[i].line { lines.append(line) }
        }
        computation.mainCache.units[id] = cache
        return lines
    }

    /// 整行是否全为 NaN（周期为 0 的 MA 行等）
    func allNaN(_ values: [Double]) -> Bool { values.allSatisfy { $0.isNaN } }

    /// 公式输出行颜色：优先公式 COLORXXX，否则用默认配色
    func lineColor(from line: TDXOutputLine, fallback: Color) -> Color {
        if let hex = line.colorHex, let c = Color(hex: hex) { return c }
        return fallback
    }

    func recomputeSub(_ m: SubChartModel, force: Bool = false) {
        // 诊断：每次调用都打印（含调用来源栈），定位曲线被清空的具体路径
        klineDebug("[KlineDebug] recomputeSub调用 \(m.kind) 现curves=\(m.curves.count) force=\(force) bgEnd=\(computation.bgCoverageEnd) endIdx=\(endIndex) mainFS=\(mainFullscreen) 栈:\(Thread.callStackSymbols.prefix(3).joined(separator:" < "))")
        // 指标/设置面板打开期间不计算（全量计算开销大），只标记该副图待重算，关闭返回后再算
        if menuIsOpen {
            if !editorUI.pendingSubCharts.contains(where: { $0 === m }) { editorUI.pendingSubCharts.append(m) }
            return
        }
        // 拖拽期间禁止任何指标重算（重算随总 K 数线性增长，是拖拽卡顿根源）；
        // force=true 用于用户显式切换/修改指标，确保立即生效
        if !force, drag.isDragging { drag.needsRefreshAfterDrag = true; return }
        // 主图放大模式：副图不显示也不计算指标值（退出放大时重新计算）
        if mainFullscreen {
            if !m.curves.isEmpty { klineDebug("[KlineDebug] 清空(mainFullscreen): \(m.kind)") }
            m.curves = []
            m.titleName = m.kind
            return
        }
        // 诊断：进入 recomputeSub 时曲线已为空（说明之前被某路径清空）
        if m.curves.isEmpty { klineDebug("[KlineDebug] recomputeSub进入时空: \(m.kind) bgEnd=\(computation.bgCoverageEnd) endIdx=\(endIndex) force=\(force)") }
        // 后台正确计算已覆盖整个可见窗口且指标配置未变（如退出放大恢复显示）：
        // 直接从缓存恢复该槽位完整曲线，避免在主线程全量重算副图指标造成明显卡顿。
        // 配置真正变化时指纹不一致，不会命中恢复，照常走下方 force 重算
        if computation.bgCoverageEnd >= endIndex, let metaId = metaId {
            let entry = ChartCacheStore.shared.entry(for: metaId, period: period)
            let slot = m === subTop ? 0 : (m === subBottom ? 1 : 2)
            if entry.configFingerprint == Self.currentConfigFingerprint(period: self.period),
               entry.bgCoverageEnd >= endIndex,
               let curves = entry.subCurves[slot], !curves.isEmpty,
               curves.allSatisfy({ $0.values.count == sortedData.count }) {
                klineDebug("[KlineDebug] 恢复缓存: \(m.kind) curves=\(curves.count)")
                m.curves = curves
                let customInd = customStore.indicators.first { $0.id == m.activeCustomID }
                m.titleName = (m.isCustom ? customInd?.name : nil) ?? m.kind
                m.color = customInd?.color ?? Color(hex: "0050FF")!
                return
            }
        }
        // 后台正确计算已覆盖整个可见窗口：未强制重算时直接复用；指标变化（force）时用正确覆盖区间重算。
        // 注意：m.curves 是跨周期共享的副图模型曲线，切换周期/配置变更后可能残留其它周期的旧曲线
        // （长度与当前数据不一致）。此时绝不能因 bgCovered 提前返回，必须按当前周期数据重算，
        // 否则副图曲线空白、十字光标不更新副图指标值
        let bgCovered = computation.bgCoverageEnd >= endIndex
        let curvesMatchCurrentData = m.curves.allSatisfy { $0.values.count == sortedData.count }
        if bgCovered, !force, !m.curves.isEmpty, curvesMatchCurrentData {
            klineDebug("[KlineDebug] return(bgCovered) \(m.kind) curves=\(m.curves.count)")
            return
        }
        // 后台尚未覆盖可见窗口：不在此同步计算近似指标（显示全部时会卡顿），
        // 保持当前已覆盖曲线，未覆盖部分渲染时因 NaN 自然显示为空，由后台 prefetch 补齐
        if !force, !bgCovered, !m.curves.isEmpty, curvesMatchCurrentData {
            klineDebug("[KlineDebug] return(未覆盖) \(m.kind) curves=\(m.curves.count)")
            return
        }
        klineDebug("[KlineDebug] 进入计算 \(m.kind) 旧curves=\(m.curves.count) bgCovered=\(bgCovered) 匹配=\(curvesMatchCurrentData) force=\(force)")
        let custom = customStore.indicators.first { $0.id == m.activeCustomID }
        // 计算区间选择：
        // - 联动隔离模式 + 强制重算（搜索切标后的首次 onAppear refreshCurves(force:true)）：
        //   直接用全量数据 [0...count-1] 计算，既保证指标 warmup 完整（MACD/EMA 等递归指标
        //   从首根 K 线开始累积，数值最准），又绕开 mergedCalcRange 的有限窗口 + 覆盖率推进
        //   机制，避免数据量 < warmup 时 merged 区间只覆盖可见部分导致公式求值全 NaN、
        //   副图最终显示为空。该场景只在切换标的时触发一次，是可接受的一次性开销。
        // - 否则：优先走正确覆盖区间（bgCovered），否则用 mergedCalcRange 合并已覆盖区间
        //   的近似前台计算，后台 prefetch 随后补齐。
        let (calcStart, calcEnd): (Int, Int)
        if force && isolatedSubs && !sortedData.isEmpty {
            calcStart = 0
            calcEnd = sortedData.count - 1
        } else if bgCovered {
            calcStart = 0
            calcEnd = computation.bgCoverageEnd
        } else {
            (calcStart, calcEnd) = mergedCalcRange(needStart: indicatorCalcStart, needEnd: indicatorCalcEnd)
        }
        let calcData = calcData(from: calcStart, to: calcEnd)
        var curves: [IndicatorLine] = []
        if m.activeCustomID != nil, let custom,
           let lines = try? TDXFormulaEngine.evaluate(formula: custom.formula, data: calcData) {
            for (i, line) in lines.enumerated() {
                let built = IndicatorLine(name: displayName(line.name), values: line.values,
                                          color: customLineColor(i, line: line, indicatorColor: custom.color),
                                          style: line.style, lineWidth: line.lineWidth, hideValue: line.hideValue)
                curves.append(padToFull(built, calcStart: calcStart, calcEnd: calcEnd))
            }
        } else if m.kind == "VOL" || m.kind == "AMO" {
            let isAmo = m.kind == "AMO"
            let baseAll = isAmo ? turnovers : volumes
            // 始终裁剪到 [calcStart...calcEnd]，padToFull 会补齐前后 NaN 到全量长度
            let baseSlice = baseAll.isEmpty ? [] : Array(baseAll[calcStart...min(calcEnd, baseAll.count - 1)])
            curves.append(padToFull(IndicatorLine(name: m.kind, values: baseSlice,
                                                  color: isAmo ? upColor : downColor,
                                                  style: .stick, lineWidth: 1, hideValue: false, barColor: .candle),
                                    calcStart: calcStart, calcEnd: calcEnd))
            for (i, p) in volMAFixedPeriods.enumerated() where p > 0 {
                curves.append(padToFull(IndicatorLine(name: "MA\(p)", values: ChartSeries.ma(values: baseSlice, period: p),
                                                      color: maColor(i), style: .solid, lineWidth: 1, hideValue: false),
                                        calcStart: calcStart, calcEnd: calcEnd))
            }
        } else {
                // 其余系统指标：按内置/可覆盖的 .tdx 公式模板求值
                if let formula = SystemIndicatorStore.shared.formula(for: m.kind, values: [:], period: self.period),
                   let lines = try? TDXFormulaEngine.evaluate(formula: formula, data: calcData) {
                    for (i, line) in lines.enumerated() {
                        guard !allNaN(line.values) else { continue }
                        let built = IndicatorLine(name: displayName(line.name), values: line.values,
                                                  color: lineColor(from: line, fallback: maColor(i)),
                                                  style: line.style, lineWidth: line.lineWidth,
                                                  hideValue: line.hideValue,
                                                  barColor: line.colorStick ? .sign : .fixed,
                                                  markerColors: line.markerDirections?.map { $0 ? upColor : downColor })
                        curves.append(padToFull(built, calcStart: calcStart, calcEnd: calcEnd))
                    }
                }
        }
        // 防空保护：重算结果为空（如公式在裁剪区间求值失败/裁剪数据异常）时保留旧曲线，
        // 避免副图被清空变空白；后台分块预计算随后会用正确结果覆盖
        if !curves.isEmpty || m.curves.isEmpty {
            if curves.isEmpty { klineDebug("[DualLink] recomputeSub 计算空将覆盖 \(m.kind) isolated=\(isolatedSubs) 旧=\(m.curves.count) win=[\(startIndex)...\(endIndex)] calc=\(calcStart)...\(calcEnd)") }
            m.curves = curves
            m.titleName = (m.isCustom ? custom?.name : nil) ?? m.kind
            m.color = custom?.color ?? Color(hex: "0050FF")!
        } else {
            klineDebug("[KlineDebug] 防空:计算空保留旧 \(m.kind) 旧=\(m.curves.count) bgCovered=\(bgCovered) calc=\(calcStart)...\(calcEnd) calcData=\(calcData.count)")
        }
        // 写回 (标的, 周期) 缓存：副图曲线按槽位存储，切回该周期时直接恢复
        if let metaId = metaId {
            let store = ChartCacheStore.shared
            let fp = Self.currentConfigFingerprint(period: self.period)
            // 配置已变：失效旧缓存并同步本地覆盖状态，取消旧后台任务后用新配置重启，
            // 否则本地 bgCoverageEnd 保持旧大值会导致 startPrefetch 误判已算完而跳过重算
            if store.invalidateIfConfigChanged(metaId: metaId, period: period, currentFingerprint: fp) {
                klineDebug("[KlineDebug] 副图配置变化(\(m.kind)) bgCoverageEnd=0 重启prefetch | 三副图count=[\(subTop.curves.count),\(subBottom.curves.count),\(subThird.curves.count)] 当前m=\(m.curves.count)")
                computation.bgCoverageEnd = 0
                computation.prefetchToken = nil
                startPrefetch()
            }
            let e = store.entry(for: metaId, period: period)
            let slot = m === subTop ? 0 : (m === subBottom ? 1 : 2)
            e.subCurves[slot] = m.curves
            e.configFingerprint = fp
        }
    }

    /// 打开标的后，在后台分块正确计算全部历史指标：
    /// 前台已先显示当前可见窗口的近似值（从可见起点往前预热一段起算，偏差很小）；
    /// 随后后台从数据开头（最左）向右逐块推进计算，EMA/SMA 等递归指标从第一根开始累积，
    /// 数值最正确；覆盖到当前可见窗口末端后才替换前台近似曲线（最新部分被重算为正确值）。
    /// 用户交互（拖动/缩放）或切换周期/标的/指标时 token 失效，任务自动停止
    func startPrefetch() {
        guard !sortedData.isEmpty, !mainFullscreen, computation.prefetchToken == nil else { return }
        // 该周期已完成全量正确预计算（可能由上次会话/后台链式预计算完成）：无需再算。
        // 仅当缓存确实已覆盖到数据末尾、且所用指标配置与当前一致才跳过，
        // 防止「完成标记」与「实际覆盖/配置」不一致时进度条卡住或指标不更新
        if let metaId = metaId {
            let entry = ChartCacheStore.shared.entry(for: metaId, period: period)
            if entry.prefetchDone, entry.bgCoverageEnd >= sortedData.count - 1,
               entry.configFingerprint == Self.currentConfigFingerprint(period: self.period) { return }
        }
        // 标记缓存条目正在预计算，避免后台「其它周期预计算」对该周期重复启动
        if let metaId = metaId {
            ChartCacheStore.shared.entry(for: metaId, period: period).isPrefetching = true
        }
        let token = UUID()
        computation.prefetchToken = token
        // 完整基础序列只构建一次，各块共享引用（避免每块重复 map 全部基础数据）
        let series = TDXSharedSeries(data: sortedData)
        // 上一块算完后的增量状态（供下一块只算新增区间、复用前缀，避免每块从数据开头整段重算）；
        // 空数组 = 从头算。公式与上一块不一致（配置中途变化）时清空状态，防止新旧公式状态错位
        var resumingMain: [TDXIncrementalState?] = []
        var resumingSubs: [TDXIncrementalState?] = []
        var lastMainFormulas: [String] = []
        var lastSubFormulas: [String?] = []
        Task { @MainActor in
            while self.computation.prefetchToken == token {
                // 指标/设置面板打开期间暂停预计算，避免空转与干扰面板操作
                if self.menuIsOpen {
                    await Task.yield()
                    continue
                }
                // 从数据开头（最左）向右推进：块大小随覆盖推进呈几何增长（每次约翻倍）。
                // 结合增量求值（上一块状态延续，每块只算新增区间）使总计算量 ≈ O(N)，
                // 接近一次全量，大幅缩短总耗时
                let currentEnd = max(0, self.computation.bgCoverageEnd)
                let step = max(self.computation.prefetchBlockSize, currentEnd)
                let bgEnd = min(self.sortedData.count - 1, currentEnd + step)
                guard bgEnd > currentEnd else {
                    // 已全部算完：标记周期预计算完成，并让外层继续预计算其它未计算周期
                    self.finishPrefetch()
                    break
                }
                // 主线程构造计算请求（携带共享序列与上一块增量状态；从数据开头起算保证递归指标数值最正确）
                guard let request = self.makePrefetchRequest(calcStart: 0, calcEnd: bgEnd, series: series,
                                                             resumingMain: resumingMain,
                                                             resumingSubs: resumingSubs) else { break }
                // 后台线程执行指标求值（纯计算，不触碰任何 UI/状态）
                let result = await Task.detached(priority: .utility) {
                    Self.evaluatePrefetch(request)
                }.value
                // 回主线程：token 仍有效才提交；仅当正确覆盖推进到可见窗口末端时才更新曲线，
                // 否则保持前台近似的立即显示（避免后台未覆盖时指标变空白）。
                // 拖动/缩放进行中跳过曲线组装（只推进 bgCoverageEnd/进度条），
                // 避免全量曲线组装占用主线程影响手势流畅度；松手后下一块会补上
                guard self.computation.prefetchToken == token else { break }
                let shouldCommit = bgEnd >= self.endIndex && !self.drag.isDragging
                // 拖动中会跳过曲线提交；但若这一整块已覆盖到数据末尾（prefetch 即将结束），
                // 即使在拖动中也强制提交，否则覆盖末端已到末尾、曲线却因拖动中跳过提交而陈旧，
                // 退出拖动后 bgCovered 误判为已覆盖、prefetchDone 又跳过重启 → 指标永不补齐
                let isLastBlock = bgEnd >= self.sortedData.count - 1
                klineDebug("[KlineDebug] 后台块: bgEnd=\(bgEnd)/\(self.sortedData.count-1) shouldCommit=\(shouldCommit) isLast=\(isLastBlock) endIdx=\(self.endIndex) dragging=\(self.drag.isDragging)")
                self.commitPrefetch(request, result, updateCurves: shouldCommit || isLastBlock)
                self.computation.bgCoverageEnd = bgEnd
                // 诊断：每块推进后副图状态（排查曲线是否在 bgEnd 更新后被清空）
                klineDebug("[KlineDebug] 块后快照(bgEnd=\(bgEnd)) | [\(subTop.kind):\(subTop.curves.count), \(subBottom.kind):\(subBottom.curves.count), \(subThird.kind):\(subThird.curves.count)]")
                // 仅在曲线真正提交时推进缓存的覆盖末端，保证缓存 bgCoverageEnd 与实际存储曲线
                // 的覆盖一致；否则会出现「声称已覆盖」但曲线未覆盖可见窗口，切回该周期后
                // bgCovered 误判为真、recomputeSub 提前返回 → 副图空白
                if (shouldCommit || isLastBlock), let metaId = self.metaId {
                    let entry = ChartCacheStore.shared.entry(for: metaId, period: self.period)
                    entry.bgCoverageEnd = max(entry.bgCoverageEnd, bgEnd)
                }
                // 把本块最新增量状态传给下一块；公式与上一块不一致（配置中途变化）时从头算
                let subsFormulas = request.subs.map { $0.customFormula ?? $0.formula }
                if request.mainFormulas == lastMainFormulas, subsFormulas == lastSubFormulas {
                    resumingMain = result.newMainStates.map { Optional($0) }
                    resumingSubs = result.newSubStates.map { Optional($0) }
                } else {
                    resumingMain = []
                    resumingSubs = []
                    lastMainFormulas = request.mainFormulas
                    lastSubFormulas = subsFormulas
                }
                // 让出主线程，先刷新 UI 再算下一块
                await Task.yield()
            }
            // 仅当仍是自己在运行时才清理 token / 占用标记：
            // 拖动等交互会把 prefetchToken 置 nil 或让后续 startPrefetch 换成新 token，
            // 此时绝不能清掉新任务的 token，否则会把新任务误杀，导致进度条卡死不再推进
            if self.computation.prefetchToken == token {
                self.computation.prefetchToken = nil
                if let metaId = self.metaId {
                    ChartCacheStore.shared.entry(for: metaId, period: self.period).isPrefetching = false
                }
            }
        }
    }

    /// 当前周期全量正确预计算完成：标记缓存并回调外层继续预计算其它未计算周期
    func finishPrefetch() {
        guard let metaId = metaId else { return }
        let cache = ChartCacheStore.shared
        let entry = cache.entry(for: metaId, period: period)
        entry.prefetchDone = true
        entry.isPrefetching = false
        // 让外层（详情页）拿到其它未计算周期的数据并后台预计算，不切换可见周期
        onPeriodPrefetched?(period)
    }

    /// 主线程构造预计算每块的请求：快照裁剪数据、启用的指标公式与参数（全部 Sendable，可跨线程）。
    /// series 为完整基础序列（各块共享，避免重复 map）；resumingMain/resumingSubs 为上一块算完的
    /// 增量状态（与公式一一对应；空数组 = 从头算），后台只算新增区间、复用前缀
    func makePrefetchRequest(calcStart: Int, calcEnd: Int, series: TDXSharedSeries,
                                     resumingMain: [TDXIncrementalState?] = [],
                                     resumingSubs: [TDXIncrementalState?] = []) -> PrefetchCalcRequest? {
        guard !sortedData.isEmpty, calcStart >= 0, calcStart <= calcEnd, calcEnd < sortedData.count else { return nil }
        let data = Array(sortedData[calcStart...calcEnd])
        let volumes = Array(self.volumes[calcStart...calcEnd])
        let turnovers = Array(self.turnovers[calcStart...calcEnd])
        let store = SystemIndicatorStore.shared
        // 主图：数据驱动，条目来自 .tdx（SCOPE=main）+ 自定义，按顺序生成公式与 id，
        // 保证后台结果与提交组装的索引严格一一对应，避免中途配置变化导致错位
        let entries = mainIndicatorEntries(store: store, customStore: customStore,
                                           config: config, customFormula: activeCustomIndicator?.formula,
                                           period: self.period)
        let main = entries.map { $0.formula }
        let mainIDs = entries.map { $0.id }
        // 副图（3 个，与 subTop/subBottom/subThird 对应）
        var subs: [SubPrefetchRequest] = []
        for m in [subTop, subBottom, subThird] {
            let customInd = customStore.indicators.first { $0.id == m.activeCustomID }
            let isCustom = m.activeCustomID != nil && customInd != nil
            let customFormula = isCustom ? customInd?.formula : nil
            let formula = (m.kind == "VOL" || m.kind == "AMO") ? nil : store.formula(for: m.kind, values: [:], period: self.period)
            subs.append(SubPrefetchRequest(kind: m.kind, customFormula: customFormula, formula: formula, volPeriods: volMAFixedPeriods))
        }
        return PrefetchCalcRequest(calcStart: calcStart, calcEnd: calcEnd, data: data,
                                   series: series,
                                   volumes: volumes, turnovers: turnovers, mainFormulas: main, mainIDs: mainIDs,
                                   subs: subs,
                                   resumingMain: resumingMain, resumingSubs: resumingSubs)
    }

    /// 后台线程：对请求中的每个公式求值（纯计算，无任何 UI/状态访问，线程安全）。
    /// 使用增量求值：携带上一块状态，只算新增区间，返回最新状态供下一块延续
    nonisolated static func evaluatePrefetch(_ req: PrefetchCalcRequest) -> PrefetchCalcResult {
        var newMainStates: [TDXIncrementalState] = []
        let main: [[TDXOutputLine]] = req.mainFormulas.enumerated().map { i, formula in
            guard !formula.isEmpty else { newMainStates.append(TDXIncrementalState()); return [] }
            let resuming = i < req.resumingMain.count ? req.resumingMain[i] : nil
            let r = (try? TDXFormulaEngine.evaluateIncremental(formula: formula, series: req.series,
                                                               barCount: req.data.count, resuming: resuming))
            newMainStates.append(r?.state ?? TDXIncrementalState())
            return r?.lines ?? []
        }
        var newSubStates: [TDXIncrementalState] = []
        let subs: [[TDXOutputLine]] = req.subs.enumerated().map { i, s in
            let f = s.customFormula ?? s.formula
            guard let f, !f.isEmpty else { newSubStates.append(TDXIncrementalState()); return [] }
            let resuming = i < req.resumingSubs.count ? req.resumingSubs[i] : nil
            let r = (try? TDXFormulaEngine.evaluateIncremental(formula: f, series: req.series,
                                                               barCount: req.data.count, resuming: resuming))
            newSubStates.append(r?.state ?? TDXIncrementalState())
            return r?.lines ?? []
        }
        return PrefetchCalcResult(main: main, subs: subs, newMainStates: newMainStates, newSubStates: newSubStates)
    }

    /// 主线程：把后台求得的原始输出行组装为 IndicatorLine，更新主图/副图曲线（含标题与颜色）。
    /// updateCurves=false 时只更新进度（bgCoverageEnd 由调用方设置），保持前台近似曲线不变，
    /// 直到正确覆盖推进到可见窗口末端才替换为正确结果
    func commitPrefetch(_ req: PrefetchCalcRequest, _ result: PrefetchCalcResult, updateCurves: Bool) {
        guard updateCurves else { return }
        // ===== 进入commit时的副图快照（任何修改前，诊断用）=====
        klineDebug("[KlineDebug] commit进入快照 | [\(subTop.kind):\(subTop.curves.count), \(subBottom.kind):\(subBottom.curves.count), \(subThird.kind):\(subThird.curves.count)] cursor=\(selectedIndex == nil ? "无" : "有") bgEnd=\(computation.bgCoverageEnd)")
        let cs = req.calcStart, ce = req.calcEnd
        // ---- 主图（数据驱动，与 makePrefetchRequest 的 mainFormulas/mainIDs 一一对应）----
        var curves: [IndicatorLine] = []
        let customColor = customStore.indicators.first { $0.id == config.activeCustomIndicatorID(for: self.period) }?.color
        for (idx, id) in req.mainIDs.enumerated() {
            guard idx < result.main.count else { continue }
            let isCustom = id == MainIndicatorCache.customKey
            for (i, out) in result.main[idx].enumerated() {
                guard !allNaN(out.values) else { continue }
                if let built = buildMainLine(id: id, isCustom: isCustom,
                                             customColor: isCustom ? customColor : nil, i: i, out: out) {
                    curves.append(padToFull(built, calcStart: cs, calcEnd: ce))
                }
            }
        }
        computation.mainCurves = curves
        // ---- 副图 ----
        for (i, m) in [subTop, subBottom, subThird].enumerated() {
            guard i < req.subs.count, i < result.subs.count else { continue }
            let subReq = req.subs[i]
            let raw = result.subs[i]
            var subCurves: [IndicatorLine] = []
            if subReq.customFormula != nil {
                let customInd = customStore.indicators.first { $0.id == m.activeCustomID }
                for (j, out) in raw.enumerated() {
                    guard !allNaN(out.values) else { continue }
                    subCurves.append(padToFull(IndicatorLine(name: displayName(out.name), values: out.values,
                                                             color: customLineColor(j, line: out, indicatorColor: customInd?.color),
                                                             style: out.style, lineWidth: out.lineWidth, hideValue: out.hideValue),
                                               calcStart: cs, calcEnd: ce))
                }
            } else if subReq.kind == "VOL" || subReq.kind == "AMO" {
                let isAmo = subReq.kind == "AMO"
                let baseSlice = isAmo ? req.turnovers : req.volumes
                subCurves.append(padToFull(IndicatorLine(name: subReq.kind, values: baseSlice,
                                                         color: isAmo ? upColor : downColor,
                                                         style: .stick, lineWidth: 1, hideValue: false, barColor: .candle),
                                           calcStart: cs, calcEnd: ce))
                for (p, period) in subReq.volPeriods.enumerated() where period > 0 {
                    subCurves.append(padToFull(IndicatorLine(name: "MA\(period)", values: ChartSeries.ma(values: baseSlice, period: period),
                                                             color: maColor(p), style: .solid, lineWidth: 1, hideValue: false),
                                               calcStart: cs, calcEnd: ce))
                }
            } else if subReq.formula != nil {
                for (j, out) in raw.enumerated() {
                    guard !allNaN(out.values) else { continue }
                    subCurves.append(padToFull(IndicatorLine(name: displayName(out.name), values: out.values,
                                                             color: lineColor(from: out, fallback: maColor(j)),
                                                             style: out.style, lineWidth: out.lineWidth,
                                                             hideValue: out.hideValue,
                                                             barColor: out.colorStick ? .sign : .fixed,
                                                             markerColors: out.markerDirections?.map { $0 ? upColor : downColor }),
                                               calcStart: cs, calcEnd: ce))
                }
            }
            // 后台求值失败（subCurves 为空，如增量求值对某指标抛错）时保持前台/上次曲线，
            // 避免后台失败结果把副图清空（副图空白）；前台 recomputeSub(force:true) 已用非增量
            // 求值算好当前指标曲线，此时保留它比覆盖为空更合理
            if !subCurves.isEmpty || m.curves.isEmpty {
                let old = m.curves.count
                klineDebug("[KlineDebug] commit覆盖 \(subReq.kind) \(old)->\(subCurves.count)")
                if old > 0 && subCurves.isEmpty {
                    klineDebug("[KlineDebug]   ↑ 非空被清空！调用栈:\(Thread.callStackSymbols.prefix(6).joined(separator:" | "))")
                }
                m.curves = subCurves
                let customInd = customStore.indicators.first { $0.id == m.activeCustomID }
                m.titleName = (m.isCustom ? customInd?.name : nil) ?? m.kind
                m.color = customInd?.color ?? Color(hex: "0050FF")!
            } else {
                klineDebug("[KlineDebug] commit保留旧 \(subReq.kind) 旧=\(m.curves.count)")
            }
        }
        // 写回 (标的, 周期) 缓存：后台正确结果落盘，切走再回来直接恢复
        if let metaId = metaId {
            let store = ChartCacheStore.shared
            let fp = Self.currentConfigFingerprint(period: self.period)
            store.invalidateIfConfigChanged(metaId: metaId, period: period, currentFingerprint: fp)
            let e = store.entry(for: metaId, period: period)
            e.mainCurves = computation.mainCurves
            e.mainCache = computation.mainCache
            e.coverageStart = computation.indicatorCoverageStart
            e.coverageEnd = computation.indicatorCoverageEnd
            // 覆盖末端只增不减
            e.bgCoverageEnd = max(e.bgCoverageEnd, computation.bgCoverageEnd)
            e.configFingerprint = fp
            for (i, m) in [subTop, subBottom, subThird].enumerated() {
                e.subCurves[i] = m.curves
            }
        }
    }

    // MARK: - 后台预计算其它周期（写入全局缓存，不触碰可见视图）

    /// 当前指标配置指纹：主图开关/参数 + 三个副图指标与参数（含自定义指标公式）。
    /// 用于判断某 (标的, 周期) 的缓存是否仍与当前配置一致：配置变了 → 缓存视为无效、重算。
    static func currentConfigFingerprint(period: KlinePeriod) -> String {
        let config = ChartConfigStore.shared
        let customStore = CustomIndicatorStore.shared
        let store = SystemIndicatorStore.shared
        var parts: [String] = []
        // 主图：数据驱动，条目来自 .tdx（SCOPE=main）+ 自定义，按 id+公式 参与指纹
        let customID = config.activeCustomIndicatorID(for: period)
        let custom = customStore.indicators.first { $0.id == customID }
        let entries = mainIndicatorEntries(store: store, customStore: customStore, config: config,
                                           customFormula: custom?.formula, period: period)
        parts.append(entries.map { "\($0.id)::\($0.formula)" }.joined(separator: "§"))
        // 副图：3 个槽位，按该周期记忆读取，含指标类型、公式（VOL/AMO 量均线周期）
        for sel in config.subSelections(for: period) {
            let customInd = sel.customID.flatMap { id in customStore.indicators.first { $0.id == id } }
            var s = sel.kind
            if let customInd {
                s += "|CUSTOM|" + customInd.formula
            } else if sel.kind == "VOL" || sel.kind == "AMO" {
                s += "|" + volMAFixedPeriods.map(String.init).joined(separator: ",")
            } else {
                s += "|" + (store.formula(for: sel.kind, values: [:], period: period) ?? "")
            }
            parts.append(s)
        }
        return parts.joined(separator: "\u{1F}")
    }

    /// 后台预计算指定 (标的, 周期) 的完整指标并写入缓存。
    /// 用于「当前周期算完后，继续计算其它未计算周期」：不依赖可见视图，
    /// 结果写入 ChartCacheStore，用户切换到该周期时由 init 直接恢复、无需等待。
    /// 幂等：该周期已标记完成或正在预计算时直接返回。
    static func prefetchOtherPeriod(metaId: Int, period: KlinePeriod, data: [KlineItem]) {
        guard !data.isEmpty else { return }
        let cache = ChartCacheStore.shared
        let currentFP = currentConfigFingerprint(period: period)
        // 配置已变化：先使旧缓存失效，避免旧配置的「已完成」被误判为无需计算
        cache.invalidateIfConfigChanged(metaId: metaId, period: period, currentFingerprint: currentFP)
        let entry = cache.entry(for: metaId, period: period)
        // 已按当前配置完成全量预计算 → 无需再算
        if entry.prefetchDone, entry.bgCoverageEnd >= data.count - 1 { return }
        guard !entry.isPrefetching else { return }
        entry.isPrefetching = true
        // 记录本次计算所用的配置指纹，供恢复时校验是否已过期
        let fingerprint = currentFP
        guard let req = makeFullRequest(data: data, period: period) else { entry.isPrefetching = false; return }
        let result = Task.detached(priority: .utility) {
            Self.evaluatePrefetch(req)
        }
        Task { @MainActor in
            let r = await result.value
            // 计算期间指标配置可能已变化：与本次快照不一致时丢弃旧配置结果，避免污染缓存
            guard currentConfigFingerprint(period: period) == fingerprint else {
                entry.isPrefetching = false
                return
            }
            Self.commitToCache(req, r, entry: entry, data: data, fingerprint: fingerprint, period: period)
            entry.isPrefetching = false
            entry.prefetchDone = true
        }
    }

    /// 构造指定 (标的, 周期) 全量指标计算请求（公式与可见视图完全一致，读取共享配置）
    static func makeFullRequest(data: [KlineItem], period: KlinePeriod) -> PrefetchCalcRequest? {
        guard !data.isEmpty else { return nil }
        let config = ChartConfigStore.shared
        let customStore = CustomIndicatorStore.shared
        let store = SystemIndicatorStore.shared
        let volumes = data.map(\.volume)
        let turnovers = data.map(\.turnover)
        // 主图：数据驱动，条目来自 .tdx（SCOPE=main）+ 自定义
        let customID = config.activeCustomIndicatorID(for: period)
        let custom = customStore.indicators.first { $0.id == customID }
        let entries = mainIndicatorEntries(store: store, customStore: customStore, config: config,
                                           customFormula: custom?.formula, period: period)
        let main = entries.map { $0.formula }
        let mainIDs = entries.map { $0.id }
        // 副图（3 个，按该周期记忆，与 subTop/subBottom/subThird 对应）
        var subs: [SubPrefetchRequest] = []
        for sel in config.subSelections(for: period) {
            let customInd = sel.customID.flatMap { id in customStore.indicators.first { $0.id == id } }
            let customFormula = customInd?.formula
            let formula = (sel.kind == "VOL" || sel.kind == "AMO") ? nil : store.formula(for: sel.kind, values: [:], period: period)
            subs.append(SubPrefetchRequest(kind: sel.kind, customFormula: customFormula, formula: formula, volPeriods: volMAFixedPeriods))
        }
        return PrefetchCalcRequest(calcStart: 0, calcEnd: data.count - 1, data: data,
                                   series: TDXSharedSeries(data: data),
                                   volumes: volumes, turnovers: turnovers, mainFormulas: main, mainIDs: mainIDs,
                                   subs: subs,
                                   resumingMain: [], resumingSubs: [])
    }

    /// 主线程：把后台求得的原始输出行组装为 IndicatorLine 并写入全局缓存。
    /// 全量覆盖（calcStart=0、calcEnd=末尾），无需 NaN 填充
    @MainActor
    static func commitToCache(_ req: PrefetchCalcRequest, _ result: PrefetchCalcResult,
                                      entry: ChartCacheStore.Entry, data: [KlineItem], fingerprint: String, period: KlinePeriod) {
        let config = ChartConfigStore.shared
        var curves: [IndicatorLine] = []
        let customStore = CustomIndicatorStore.shared
        let customColor = customStore.indicators.first { $0.id == config.activeCustomIndicatorID(for: period) }?.color
        for (idx, id) in req.mainIDs.enumerated() {
            guard idx < result.main.count else { continue }
            let isCustom = id == MainIndicatorCache.customKey
            for (i, out) in result.main[idx].enumerated() {
                guard !tdxAllNaN(out.values) else { continue }
                if let built = buildMainLine(id: id, isCustom: isCustom,
                                             customColor: isCustom ? customColor : nil, i: i, out: out) {
                    curves.append(built)
                }
            }
        }
        entry.mainCurves = curves
        // 副图
        var subCurves: [Int: [IndicatorLine]] = [:]
        let subSels = config.subSelections(for: period)
        for (i, sel) in subSels.enumerated() {
            guard i < req.subs.count, i < result.subs.count else { continue }
            let subReq = req.subs[i]
            let raw = result.subs[i]
            var sc: [IndicatorLine] = []
            if subReq.customFormula != nil {
                let customInd = sel.customID.flatMap { id in CustomIndicatorStore.shared.indicators.first { $0.id == id } }
                for (j, out) in raw.enumerated() {
                    guard !tdxAllNaN(out.values) else { continue }
                    sc.append(IndicatorLine(name: prefetchDisplayName(out.name), values: out.values,
                                            color: prefetchCustomLineColor(j, line: out, indicatorColor: customInd?.color),
                                            style: out.style, lineWidth: out.lineWidth, hideValue: out.hideValue))
                }
            } else if subReq.kind == "VOL" || subReq.kind == "AMO" {
                let isAmo = subReq.kind == "AMO"
                let baseSlice = isAmo ? req.turnovers : req.volumes
                sc.append(IndicatorLine(name: subReq.kind, values: baseSlice,
                                        color: isAmo ? prefetchUpColor : prefetchDownColor,
                                        style: .stick, lineWidth: 1, hideValue: false, barColor: .candle))
                for (p, period) in subReq.volPeriods.enumerated() where period > 0 {
                    sc.append(IndicatorLine(name: "MA\(period)", values: ChartSeries.ma(values: baseSlice, period: period),
                                            color: prefetchMaColor(p), style: .solid, lineWidth: 1, hideValue: false))
                }
            } else if subReq.formula != nil {
                for (j, out) in raw.enumerated() {
                    guard !tdxAllNaN(out.values) else { continue }
                    sc.append(IndicatorLine(name: prefetchDisplayName(out.name), values: out.values,
                                            color: prefetchLineColor(from: out, fallback: prefetchMaColor(j)),
                                            style: out.style, lineWidth: out.lineWidth, hideValue: out.hideValue,
                                            barColor: out.colorStick ? .sign : .fixed,
                                            markerColors: out.markerDirections?.map { $0 ? prefetchUpColor : prefetchDownColor }))
                }
            }
            subCurves[i] = sc
        }
        entry.subCurves = subCurves
        entry.coverageStart = 0
        entry.coverageEnd = data.count - 1
        entry.bgCoverageEnd = data.count - 1
        entry.configFingerprint = fingerprint
    }

}

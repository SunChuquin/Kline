//
//  KlineChartView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/8/5.
//

import SwiftUI
import Combine

/// 副图可选指标类型（两个副图均可任选）
enum SubChartKind: String, CaseIterable, Identifiable {
    // 量能
    case vol = "VOL"
    case amo = "AMO"
    case vmacd = "VMACD"
    case vr = "VR"
    case vrsi = "VRSI"
    case obv = "OBV"
    case col = "COL"
    // 趋向
    case macd = "MACD"
    case dmi = "DMI"
    case trix = "TRIX"
    // 超买超卖
    case kdj = "KDJ"
    case rsi = "RSI"
    case cci = "CCI"
    case kd = "KD"
    case lwr = "LWR"
    case marsi = "MARSI"
    case brar = "BRAR"
    case cr = "CR"
    case mass = "MASS"
    case cdj = "CDJ"
    var id: String { rawValue }
}

/// 主图显示类型
enum ChartStyle: String, CaseIterable, Identifiable {
    case bare  = "空心K线"   // 红K空心，绿K实心
    case solid = "实心K线"
    case close = "收盘线"
    case ohlc  = "美国线"
    var id: String { rawValue }
}

/// 无光标时的拖动模式：水平=平移，垂直=缩放
enum DragMode {
    case none, pan, zoom
}

/// 拖动手势过程变量容器：改用 class 引用存储，避免手势 onChanged 频繁写入 @State 触发整页重绘导致缓慢拖动卡顿
final class DragState {
    var lastTouchX: CGFloat = 0
    var lastPanWidth: CGFloat = 0
    var lastPanHeight: CGFloat = 0
    var dragMode: DragMode = .none
    var cursorDragging: Bool = false
    var isDragging = false
    var needsRefreshAfterDrag = false
}

/// 区间统计可拖动的边界（起点/终点）
enum StatsEdge: Equatable {
    case start, end
}

/// 公式编辑器针对的目标图表
enum EditorTarget {
    case main, sub
}

/// 副图槽位（第1/第2个副图）
enum SubSlot: Hashable {
    case top, bottom
}

/// 全屏参数编辑页目标
enum ParamEditorTarget: Equatable {
    case main
    case sub(SubSlot)
}

/// 指标柱状曲线颜色规则
enum BarColorMode: Equatable {
    case fixed       // 使用曲线自身颜色
    case sign        // 按柱值正负着色（MACD）
    case candle      // 按对应K线涨跌着色（量柱）
}

// MARK: - 指标参数配置（可编辑）

/// MA/EMA 计算数据源
enum MAValueSource: String, CaseIterable, Identifiable {
    case close = "CLOSE"
    case open = "OPEN"
    case high = "HIGH"
    case low = "LOW"
    case avg = "平均值"
    var id: String { rawValue }
}

struct MAConfig: Equatable {
    var periods: [Int] = [5, 10, 20, 60, 0, 0, 0, 0]
    var sources: [MAValueSource] = Array(repeating: .close, count: 8)
    mutating func sanitize() {
        if periods.count != 8 { periods = Array(repeating: 0, count: 8) }
        if sources.count != 8 { sources = Array(repeating: .close, count: 8) }
        periods = periods.map { min(max($0, 0), 1000) }
    }
}

struct EMAConfig: Equatable {
    var periods: [Int] = [5, 10, 20, 60, 0, 0, 0, 0]
    var sources: [MAValueSource] = Array(repeating: .close, count: 8)
    mutating func sanitize() {
        if periods.count != 8 { periods = Array(repeating: 0, count: 8) }
        if sources.count != 8 { sources = Array(repeating: .close, count: 8) }
        periods = periods.map { min(max($0, 0), 1000) }
    }
}

/// 图表配置持久化仓库：K 线页重建（切换周期 / 返回行情重新进入）时保持指标与设置不重置。
final class ChartConfigStore: ObservableObject {
    static let shared = ChartConfigStore()

    // 主图叠加指标开关
    @Published var showMA = true
    @Published var showEMA = false
    @Published var showBOLL = false
    @Published var showBareK = false
    @Published var showCMK = false
    @Published var showSAR = false
    // K线类型与图层显示（设置面板）
    @Published var chartStyle: ChartStyle = .bare
    @Published var displaySettings = ChartDisplaySettings()
    // 主图指标参数
    @Published var cmkN = 10
    @Published var sarStep: Double = 0.02
    @Published var sarMax: Double = 0.2
    @Published var maConfig = MAConfig()
    @Published var emaConfig = EMAConfig()
    @Published var bollConfig = BOLLConfig()
    // 主图自定义指标
    @Published var activeCustomIndicatorID: UUID? = nil

    // 两个副图（跨页面保留同一实例，避免重建）
    let subTop = SubChartModel()
    let subBottom = SubChartModel()

    private init() {
        subTop.kind = .vol
        subTop.resetParams()
        subBottom.kind = .macd
        subBottom.resetParams()
    }
}

struct BOLLConfig: Equatable {
    var period: Int = 20
    var mult: Double = 2
}

// MARK: - 通用指标线

struct IndicatorLine: Equatable {
    let name: String
    let values: [Double]
    let color: Color
    let style: TDXLineStyle
    let lineWidth: Double
    let hideValue: Bool
    var barColor: BarColorMode = .fixed
    /// 逐点着色（SAR 红/绿圆点）；nil 时用 color 统一着色
    var markerColors: [Color]? = nil
}

struct CanvasCurve: Equatable {
    var color: Color
    var values: [Double]
    var style: TDXLineStyle
    var lineWidth: Double
    var barColor: BarColorMode = .fixed
    var markerColors: [Color]? = nil
}

// MARK: - 副图模型

final class SubChartModel: ObservableObject {
    @Published var kind: SubChartKind = .vol
    @Published var activeCustomID: UUID? = nil
    @Published var titleName: String = "VOL"
    @Published var curves: [IndicatorLine] = []
    @Published var color: Color = Color(hex: "0050FF")!
    /// 系统副图指标的整数参数（键 → 值）
    @Published var params: [String: Int] = [:]
    /// VOL/AMO 的量均线周期（0=隐藏）
    @Published var volPeriods: [Int] = [5, 10, 0, 0, 0, 0, 0, 0]

    var isCustom: Bool { activeCustomID != nil }

    func resetParams() {
        params = kind.defaultParams
    }

    func param(_ key: String) -> Int { params[key] ?? 0 }
}

/// 仅缓存排序后的 K 线数据；指标一律用静态方法按需(可见配置)计算，不再整表预计算未用指标。
struct ChartSeries {
    let sorted: [KlineItem]

    init(data: [KlineItem]) {
        self.sorted = Array(data.reversed())
    }

    /// 滑动均值：跳过 NaN/无效点，只有窗口内全部为有效值时输出，避免首个 NaN 永久污染滚动和。
    static func ma(values: [Double], period: Int) -> [Double] {
        var result = Array(repeating: Double.nan, count: values.count)
        guard period > 0 else { return result }
        var sum = 0.0
        var valid = 0
        for i in 0..<values.count {
            let v = values[i]
            if v.isFinite { sum += v; valid += 1 }
            let outIdx = i - period
            if outIdx >= 0, values[outIdx].isFinite { sum -= values[outIdx]; valid -= 1 }
            if valid >= period { result[i] = sum / Double(period) }
        }
        return result
    }

    static func ema(values: [Double], period: Int) -> [Double] {
        var result = Array(repeating: Double.nan, count: values.count)
        guard period > 0 else { return result }
        let k = 2.0 / Double(period + 1)
        var prev: Double?
        for (i, v) in values.enumerated() {
            if let p = prev { result[i] = v * k + p * (1 - k); prev = result[i] }
            else { result[i] = v; prev = v }
        }
        return result
    }

    static func rollingStd(_ values: [Double], period: Int) -> [Double] {
        var result = Array(repeating: Double.nan, count: values.count)
        guard period > 0, values.count >= period else { return result }
        for i in (period - 1)..<values.count {
            let window = Array(values[(i - period + 1)...i])
            let mean = window.reduce(0, +) / Double(period)
            let variance = window.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(period)
            result[i] = sqrt(variance)
        }
        return result
    }

    static func boll(values: [Double], period: Int, mult: Double) -> (mid: [Double], up: [Double], lo: [Double]) {
        let mid = ma(values: values, period: period)
        let sd = rollingStd(values, period: period)
        return (mid, zip(mid, sd).map { $0 + mult * $1 }, zip(mid, sd).map { $0 - mult * $1 })
    }

    static func macd(values: [Double], fast: Int, slow: Int, signal: Int) -> (dif: [Double], dea: [Double], hist: [Double]) {
        let dif = zip(ema(values: values, period: fast), ema(values: values, period: slow)).map { $0 - $1 }
        let dea = ema(values: dif, period: signal)
        return (dif, dea, zip(dif, dea).map { 2 * ($0 - $1) })
    }

    static func kdj(highs: [Double], lows: [Double], closes: [Double], n: Int, kN: Int, dN: Int) -> (k: [Double], d: [Double], j: [Double]) {
        var kArr: [Double] = []; var dArr: [Double] = []; var jArr: [Double] = []
        var prevK = 50.0; var prevD = 50.0
        for i in 0..<closes.count {
            let loIndex = max(0, i - n + 1)
            let lo = lows[loIndex...i].min() ?? 0
            let hi = highs[loIndex...i].max() ?? 0
            let rsv = (hi - lo) == 0 ? 50 : (closes[i] - lo) / (hi - lo) * 100
            let k = (Double(kN - 1) * prevK + rsv) / Double(kN)
            let d = (Double(dN - 1) * prevD + k) / Double(dN)
            kArr.append(k); dArr.append(d); jArr.append(3 * k - 2 * d)
            prevK = k; prevD = d
        }
        return (kArr, dArr, jArr)
    }

    static func rsi(values: [Double], period: Int) -> [Double] {
        var result = Array(repeating: Double.nan, count: values.count)
        guard values.count > period, period > 0 else { return result }
        var avgGain = 0.0; var avgLoss = 0.0
        for i in 1...period {
            let c = values[i] - values[i - 1]
            avgGain += max(c, 0) / Double(period)
            avgLoss += max(-c, 0) / Double(period)
        }
        func rv(_ g: Double, _ l: Double) -> Double { l == 0 ? 100 : 100 - 100 / (1 + g / l) }
        result[period] = rv(avgGain, avgLoss)
        for i in (period + 1)..<values.count {
            let c = values[i] - values[i - 1]
            avgGain = (avgGain * Double(period - 1) + max(c, 0)) / Double(period)
            avgLoss = (avgLoss * Double(period - 1) + max(-c, 0)) / Double(period)
            result[i] = rv(avgGain, avgLoss)
        }
        return result
    }
}

/// 跳空缺口（预计算一次，绘制时按可见区间过滤）
struct GapInfo: Equatable {
    /// 缺口形成位置（startIdx-1 与 startIdx 两根K线之间）
    let startIdx: Int
    let top: Double
    let bottom: Double
    let isUp: Bool
    /// 回补位置（该索引的K线价格触及缺口区间；nil = 未回补，一直显示）
    let filledIdx: Int?
}

/// 行情 K 线图。
struct KlineChartView: View {
    private let series: ChartSeries
    /// 当前行情周期（用于主图指标名称按钮显示 "日线: MA" 之类前缀）
    let period: KlinePeriod
    /// 第一副图左右滑动切换周期（传入更大/更小级别周期，由外层决定是否应用）
    let onPeriodSwitch: ((KlinePeriod) -> Void)?
    /// 第二副图左右滑动切换标的（dir = -1 上一个 / +1 下一个）
    let onSwitchItem: ((Int) -> Void)?
    @Binding var chartStyle: ChartStyle
    @Binding var displaySettings: ChartDisplaySettings

    // 交互状态
    @State private var selectedIndex: Int? = nil
    @State private var showMainSheet = false
    @State private var showSubSheet = false
    @State private var editingSlot: SubSlot = .top
    @State private var visibleCount: CGFloat = 100
    @State private var endOffset: Int = 0
    @State private var zoomBase: CGFloat = 100
    // 缩放锚点：以双指位置对应的K线为基线缩放（而非屏幕最右端）
    @State private var zoomAnchorIndex: Int? = nil
    @State private var zoomAnchorOffset: CGFloat = 0
    @State private var drag = DragState()
    /// 亚像素平移偏移（px）：缓慢拖动时画面平滑跟手，累计满一根K线间距才进位移动可见窗口
    @State private var panOffset: CGFloat = 0
    @State private var crosshairY: CGFloat? = nil
    // 区间统计自定义边界（nil = 跟随屏幕可见区间）
    @State private var statsStartIndex: Int? = nil
    @State private var statsEndIndex: Int? = nil
    @State private var statsDragEdge: StatsEdge? = nil
    /// 全数据集预计算的跳空缺口（只在数据加载时计算一次，避免每次重绘全量扫描）
    @State private var gaps: [GapInfo] = []
    @ObservedObject private var customStore = CustomIndicatorStore.shared
    @ObservedObject private var config = ChartConfigStore.shared

    // 主图叠加指标（配置来自共享仓库，跨页面持久化）
    @State private var mainCurves: [IndicatorLine] = []

    // 两个副图（同一实例跨页面复用，配置不重置）
    @ObservedObject private var subTop: SubChartModel
    @ObservedObject private var subBottom: SubChartModel

    /// 自定义指标公式编辑器是否打开（由详情页持有状态，打开时隐藏顶部栏实现真全屏）
    @Binding var showCustomEditor: Bool
    @State private var editorTarget: EditorTarget = .main
    /// 系统指标参数编辑页目标（与选择指标页同尺寸的底部面板，非全屏）
    @State private var paramEditorTarget: ParamEditorTarget? = nil

    // 基础序列一次性缓存（供指标按需计算复用，避免拖拽/重算时反复整表 map）
    private let sortedAll: [KlineItem]
    private let baseCloses, baseHighs, baseLows, baseOpens, baseVolumes, baseTurnovers: [Double]

    init(series: ChartSeries, chartStyle: Binding<ChartStyle>,
         displaySettings: Binding<ChartDisplaySettings> = .constant(ChartDisplaySettings()),
         showCustomEditor: Binding<Bool> = .constant(false),
         period: KlinePeriod = .daily,
         onPeriodSwitch: ((KlinePeriod) -> Void)? = nil,
         onSwitchItem: ((Int) -> Void)? = nil) {
        self.series = series
        self.period = period
        self.onPeriodSwitch = onPeriodSwitch
        self.onSwitchItem = onSwitchItem
        self._chartStyle = chartStyle
        self._displaySettings = displaySettings
        self._showCustomEditor = showCustomEditor
        let all = series.sorted
        self.sortedAll = all
        self.baseCloses = all.map(\.close)
        self.baseHighs = all.map(\.high)
        self.baseLows = all.map(\.low)
        self.baseOpens = all.map(\.open)
        self.baseVolumes = all.map(\.volume)
        self.baseTurnovers = all.map(\.turnover)
        // 全数据集预计算跳空缺口（一次计算，绘制时只按可见区间过滤）
        self._gaps = State(initialValue: Self.computeGaps(all))
        // 副图复用共享仓库中的同一实例，保证切换周期/重新进入后指标不重置
        let store = ChartConfigStore.shared
        self._subTop = ObservedObject(wrappedValue: store.subTop)
        self._subBottom = ObservedObject(wrappedValue: store.subBottom)
    }

    /// 当前主图自定义指标（从共享仓库中的 ID 派生）
    private var activeCustomIndicator: CustomIndicator? {
        customStore.indicators.first { $0.id == config.activeCustomIndicatorID }
    }

    // MARK: - 配色

    private var upColor: Color { Color(red: 0.85, green: 0.16, blue: 0.16) }
    private var downColor: Color { Color(red: 0.0, green: 0.55, blue: 0.35) }
    private var gridColor: Color { Color.gray.opacity(0.22) }
    private var axisTextColor: Color { Color.black.opacity(0.55) }
    private var bollColor: Color { Color(red: 0.4, green: 0.4, blue: 0.9) }
    private var ma5Color: Color { Color.black.opacity(0.75) }
    private var ma10Color: Color { Color.orange }
    private var ma20Color: Color { Color.pink }

    private func maColor(_ i: Int) -> Color {
        let colors = [Color.black.opacity(0.75), Color.orange, Color.pink, Color.blue,
                      Color(red: 0.9, green: 0.6, blue: 0), Color.teal, Color.purple, Color.brown]
        return colors[i % colors.count]
    }

    private var sortedData: [KlineItem] { sortedAll }
    private var closes: [Double] { baseCloses }
    private var highs: [Double] { baseHighs }
    private var lows: [Double] { baseLows }
    private var opens: [Double] { baseOpens }
    private var volumes: [Double] { baseVolumes }
    private var turnovers: [Double] { baseTurnovers }

    // MARK: - 可见窗口

    private var count: Int { min(max(20, Int(visibleCount.rounded())), maxVisibleCount) }
    private var maxVisibleCount: Int { sortedData.count }
    private var endIndex: Int {
        let maxEnd = sortedData.count - 1
        let minEnd = max(0, count - 1)
        return min(maxEnd, max(minEnd, maxEnd - endOffset))
    }
    private var startIndex: Int { max(0, endIndex - count + 1) }
    private var slice: [KlineItem] {
        guard startIndex <= endIndex, startIndex >= 0, endIndex < sortedData.count else { return [] }
        return Array(sortedData[startIndex...endIndex])
    }
    private func sliceArr(_ arr: [Double]) -> [Double] {
        guard !arr.isEmpty, startIndex <= endIndex, endIndex < arr.count else { return [] }
        return Array(arr[startIndex...endIndex])
    }
    private func sliceColors(_ arr: [Color]?) -> [Color]? {
        guard let arr, !arr.isEmpty, startIndex <= endIndex, endIndex < arr.count else { return arr }
        return Array(arr[startIndex...endIndex])
    }

    /// MA/EMA 数据源序列：CLOSE/OPEN/HIGH/LOW/平均值(开收高低均值)
    private func sourceSeries(_ source: MAValueSource) -> [Double] {
        switch source {
        case .close: return closes
        case .open: return opens
        case .high: return highs
        case .low: return lows
        case .avg:
            var out = [Double](repeating: 0, count: closes.count)
            for i in 0..<closes.count { out[i] = (opens[i] + closes[i] + highs[i] + lows[i]) / 4 }
            return out
        }
    }

    /// 指标栏取值：有光标时取光标值，否则取可见窗口最右侧值。
    /// 全部改为 O(1)/有界查找，避免拖拽时对整表做 O(n) 反向扫描（卡顿根源之一）。
    private func legendValue(_ arr: [Double]) -> Double? {
        if let idx = selectedIndex, idx >= 0, idx < arr.count, !arr[idx].isNaN { return arr[idx] }
        let start = min(endIndex, arr.count - 1)
        guard start >= 0 else { return nil }
        for i in Swift.max(0, start - 250)...start {
            let v = arr[i]
            if v.isFinite { return v }
        }
        return nil
    }
    private func legendValueFor(_ line: IndicatorLine) -> Double? { legendValue(line.values) }
    private func displayName(_ raw: String) -> String { raw.replacingOccurrences(of: "NOTEXT_", with: "") }

    // MARK: - 指标序列计算

    private func customLineColor(_ index: Int, line: TDXOutputLine, indicatorColor: Color?) -> Color {
        if let hex = line.colorHex, let c = Color(hex: hex) { return c }
        if let indicatorColor { return indicatorColor }
        let palette = [Color.blue, Color(red: 0.9, green: 0.35, blue: 0.1), Color(red: 0.2, green: 0.55, blue: 0.85),
                       Color(red: 0.6, green: 0.25, blue: 0.7), Color.teal, Color.pink]
        return palette[index % palette.count]
    }

    private func recomputeMainCurves(force: Bool = false) {
        // 拖拽期间禁止任何指标重算（重算随总 K 数线性增长，是拖拽卡顿根源）；
        // force=true 用于用户显式切换/修改指标，确保立即生效
        if !force, drag.isDragging { drag.needsRefreshAfterDrag = true; return }
        var curves: [IndicatorLine] = []
        if !config.showBareK {
            if config.showMA {
                for (i, p) in config.maConfig.periods.enumerated() where p > 0 {
                    let src = config.maConfig.sources.indices.contains(i) ? config.maConfig.sources[i] : .close
                    curves.append(IndicatorLine(name: "MA\(p)", values: ChartSeries.ma(values: sourceSeries(src), period: p),
                                                color: maColor(i), style: .solid, lineWidth: 1, hideValue: false))
                }
            }
            if config.showEMA {
                for (i, p) in config.emaConfig.periods.enumerated() where p > 0 {
                    let src = config.emaConfig.sources.indices.contains(i) ? config.emaConfig.sources[i] : .close
                    curves.append(IndicatorLine(name: "EMA\(p)", values: ChartSeries.ema(values: sourceSeries(src), period: p),
                                                color: maColor(i), style: .solid, lineWidth: 1, hideValue: false))
                }
            }
            if config.showBOLL {
                let b = ChartSeries.boll(values: closes, period: config.bollConfig.period, mult: config.bollConfig.mult)
                curves.append(IndicatorLine(name: "MID", values: b.mid, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "UP", values: b.up, color: bollColor, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "LOW", values: b.lo, color: bollColor, style: .solid, lineWidth: 1, hideValue: false))
            }
            if config.showCMK, let lines = try? TDXFormulaEngine.evaluate(formula: SystemFormulas.cmk(n: config.cmkN), data: sortedData) {
                for (i, line) in lines.enumerated() {
                    curves.append(IndicatorLine(name: displayName(line.name), values: line.values,
                                                color: customLineColor(i, line: line, indicatorColor: nil),
                                                style: line.style, lineWidth: line.lineWidth, hideValue: line.hideValue))
                }
            }
            if config.showSAR {
                let r = ChartSeries.sar(highs: highs, lows: lows, step: config.sarStep, maxStep: config.sarMax)
                curves.append(IndicatorLine(name: "SAR", values: r.values, color: upColor, style: .pointdot, lineWidth: 1,
                                            hideValue: false, markerColors: r.isUp.map { $0 ? upColor : downColor }))
            }
            if let custom = activeCustomIndicator,
               let lines = try? TDXFormulaEngine.evaluate(formula: custom.formula, data: sortedData) {
                for (i, line) in lines.enumerated() {
                    curves.append(IndicatorLine(name: displayName(line.name), values: line.values,
                                                color: customLineColor(i, line: line, indicatorColor: custom.color),
                                                style: line.style, lineWidth: line.lineWidth, hideValue: line.hideValue))
                }
            }
        }
        mainCurves = curves
    }

    private func recomputeSub(_ m: SubChartModel, force: Bool = false) {
        // 拖拽期间禁止任何指标重算（重算随总 K 数线性增长，是拖拽卡顿根源）；
        // force=true 用于用户显式切换/修改指标，确保立即生效
        if !force, drag.isDragging { drag.needsRefreshAfterDrag = true; return }
        let custom = customStore.indicators.first { $0.id == m.activeCustomID }
        var curves: [IndicatorLine] = []
        if m.activeCustomID != nil, let custom,
           let lines = try? TDXFormulaEngine.evaluate(formula: custom.formula, data: sortedData) {
            for (i, line) in lines.enumerated() {
                curves.append(IndicatorLine(name: displayName(line.name), values: line.values,
                                            color: customLineColor(i, line: line, indicatorColor: custom.color),
                                            style: line.style, lineWidth: line.lineWidth, hideValue: line.hideValue))
            }
        } else {
            switch m.kind {
            case .vol, .amo:
                let isAmo = m.kind == .amo
                let base = isAmo ? turnovers : volumes
                curves.append(IndicatorLine(name: m.kind.rawValue, values: base,
                                            color: isAmo ? upColor : downColor,
                                            style: .stick, lineWidth: 1, hideValue: false, barColor: .candle))
                for (i, p) in m.volPeriods.enumerated() where p > 0 {
                    curves.append(IndicatorLine(name: "MA\(p)", values: ChartSeries.ma(values: base, period: p),
                                                color: maColor(i), style: .solid, lineWidth: 1, hideValue: false))
                }
            case .vmacd:
                let r = ChartSeries.vmacd(volumes: volumes, short: m.param("short"), long: m.param("long"), m: m.param("m"))
                curves.append(IndicatorLine(name: "DIFF", values: r.diff, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "DEA", values: r.dea, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "VMACD", values: r.hist, color: ma20Color, style: .stick, lineWidth: 1, hideValue: false, barColor: .sign))
            case .vr:
                let r = ChartSeries.vr(closes: closes, volumes: volumes, n: m.param("n"), m: m.param("m"))
                curves.append(IndicatorLine(name: "VR", values: r.vr, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "MAVR", values: r.ma, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
            case .vrsi:
                let r = ChartSeries.vrsi(volumes: volumes, n1: m.param("n1"), n2: m.param("n2"), n3: m.param("n3"))
                curves.append(IndicatorLine(name: "VRSI\(m.param("n1"))", values: r.r1, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "VRSI\(m.param("n2"))", values: r.r2, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "VRSI\(m.param("n3"))", values: r.r3, color: ma20Color, style: .solid, lineWidth: 1, hideValue: false))
            case .obv:
                let r = ChartSeries.obv(closes: closes, volumes: volumes, m: m.param("m"))
                curves.append(IndicatorLine(name: "OBV", values: r.obv, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "MAOBV", values: r.ma, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
            case .macd:
                let mres = ChartSeries.macd(values: closes, fast: m.param("fast"), slow: m.param("slow"), signal: m.param("signal"))
                curves.append(IndicatorLine(name: "DIF", values: mres.dif, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "DEA", values: mres.dea, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "MACD", values: mres.hist, color: ma20Color, style: .stick, lineWidth: 1, hideValue: false, barColor: .sign))
            case .dmi:
                let r = ChartSeries.dmi(highs: highs, lows: lows, closes: closes, n: m.param("n"), m: m.param("m"))
                curves.append(IndicatorLine(name: "PDI", values: r.pdi, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "MDI", values: r.mdi, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "ADX", values: r.adx, color: ma20Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "ADXR", values: r.adxr, color: Color(red: 0.9, green: 0.6, blue: 0), style: .solid, lineWidth: 1, hideValue: false))
            case .trix:
                let r = ChartSeries.trix(closes: closes, n: m.param("n"), m: m.param("m"))
                curves.append(IndicatorLine(name: "TRIX", values: r.trix, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "MATRIX", values: r.ma, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
            case .kdj:
                let k = ChartSeries.kdj(highs: highs, lows: lows, closes: closes,
                                        n: m.param("n"), kN: m.param("k"), dN: m.param("d"))
                curves.append(IndicatorLine(name: "K", values: k.k, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "D", values: k.d, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "J", values: k.j, color: ma20Color, style: .solid, lineWidth: 1, hideValue: false))
            case .rsi:
                let r1 = ChartSeries.rsi(values: closes, period: m.param("p1"))
                let r2 = ChartSeries.rsi(values: closes, period: m.param("p2"))
                let r3 = ChartSeries.rsi(values: closes, period: m.param("p3"))
                curves.append(IndicatorLine(name: "RSI\(m.param("p1"))", values: r1, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "RSI\(m.param("p2"))", values: r2, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "RSI\(m.param("p3"))", values: r3, color: ma20Color, style: .solid, lineWidth: 1, hideValue: false))
            case .cci:
                curves.append(IndicatorLine(name: "CCI", values: ChartSeries.cci(highs: highs, lows: lows, closes: closes, n: m.param("n")),
                                            color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
            case .kd:
                let r = ChartSeries.kd(highs: highs, lows: lows, closes: closes, n: m.param("n"), m1: m.param("m1"), m2: m.param("m2"))
                curves.append(IndicatorLine(name: "K", values: r.k, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "D", values: r.d, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
            case .lwr:
                let r = ChartSeries.lwr(highs: highs, lows: lows, closes: closes, n: m.param("n"), m1: m.param("m1"), m2: m.param("m2"))
                curves.append(IndicatorLine(name: "LWR1", values: r.l1, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "LWR2", values: r.l2, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
            case .marsi:
                let r = ChartSeries.marsi(closes: closes, n1: m.param("n1"), n2: m.param("n2"))
                curves.append(IndicatorLine(name: "MARSI\(m.param("n1"))", values: r.r1, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "MARSI\(m.param("n2"))", values: r.r2, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
            case .brar:
                let r = ChartSeries.brar(highs: highs, lows: lows, opens: opens, closes: closes, n: m.param("n"))
                curves.append(IndicatorLine(name: "BR", values: r.br, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "AR", values: r.ar, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
            case .cr:
                let r = ChartSeries.cr(highs: highs, lows: lows, closes: closes, n: m.param("n"),
                                       m1: m.param("m1"), m2: m.param("m2"), m3: m.param("m3"))
                curves.append(IndicatorLine(name: "CR", values: r.cr, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "MA\(m.param("m1"))", values: r.ma1, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "MA\(m.param("m2"))", values: r.ma2, color: ma20Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "MA\(m.param("m3"))", values: r.ma3, color: Color(red: 0.9, green: 0.6, blue: 0), style: .solid, lineWidth: 1, hideValue: false))
            case .mass:
                let r = ChartSeries.mass(highs: highs, lows: lows, n: m.param("n"), n1: m.param("n1"), m: m.param("m"))
                curves.append(IndicatorLine(name: "MASS", values: r.mass, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "MAMASS", values: r.ma, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
            case .cdj, .col:
                if let formula = m.kind.formula(with: m.params),
                   let lines = try? TDXFormulaEngine.evaluate(formula: formula, data: sortedData) {
                    for (i, line) in lines.enumerated() {
                        curves.append(IndicatorLine(name: displayName(line.name), values: line.values,
                                                    color: customLineColor(i, line: line, indicatorColor: nil),
                                                    style: line.style, lineWidth: line.lineWidth, hideValue: line.hideValue))
                    }
                }
            }
        }
        m.curves = curves
        m.titleName = (m.isCustom ? custom?.name : nil) ?? m.kind.rawValue
        m.color = custom?.color ?? Color(hex: "0050FF")!
    }

    // MARK: - 主图价格区间

    /// 全数据集扫描，预计算所有跳空缺口及回补位置（数据加载时计算一次）。
    /// 采用维护缺口列表的线性算法：缺口形成后，某根后续K线价格触及缺口区间即视为回补，
    /// 记录该K线索引为 filledIdx；从未被回补的缺口 filledIdx 为 nil（持续显示）。
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

    private var priceRange: ClosedRange<Double> {
        guard !slice.isEmpty else { return 0...100 }
        var minLow = slice.map(\.low).min() ?? 0
        var maxHigh = slice.map(\.high).max() ?? 100
        // 默认打开"指标不挤压K线"：范围只按K线自身计算；关闭时才纳入指标线范围（K线被挤压）
        if !displaySettings.indicatorNotSqueezeKline {
            let offsets = Array(startIndex...endIndex).filter { $0 < closes.count }
            var all: [Double] = []
            for line in mainCurves {
                for idx in offsets where idx < line.values.count {
                    let v = line.values[idx]
                    if !v.isNaN { all.append(v) }
                }
            }
            if let minV = all.min() { minLow = min(minLow, minV) }
            if let maxV = all.max() { maxHigh = max(maxHigh, maxV) }
        }
        let padding = (maxHigh - minLow) * 0.05
        return (minLow - padding)...(maxHigh + padding)
    }

    // MARK: - 副图坐标范围

    private func subRange(_ m: SubChartModel) -> (min: Double, max: Double) {
        let offsets = Array(startIndex...endIndex)
        var values: [Double] = []
        for line in m.curves {
            for idx in offsets where idx < line.values.count {
                let v = line.values[idx]
                if !v.isNaN { values.append(v) }
            }
        }
        switch m.kind {
        case .vol, .amo:
            let mx = values.max() ?? 1
            return (0, mx * 1.08)
        case .macd, .vmacd:
            let mx = values.map { abs($0) }.max() ?? 1
            let mm = max(mx * 1.15, 0.0001)
            return (-mm, mm)
        case .rsi, .vrsi:
            return (0, 100)
        case .kdj, .kd, .lwr, .marsi, .cdj, .col:
            let lo = min(values.min() ?? 0, 0)
            let hi = max(values.max() ?? 100, 100)
            return (lo, hi)
        default:
            guard let mn = values.min(), let mx = values.max(), mn != mx else { return (0, 100) }
            let pad = (mx - mn) * 0.05
            return (mn - pad, mx + pad)
        }
    }

    // MARK: - 手势

    private var menuIsOpen: Bool { showMainSheet || showSubSheet || showCustomEditor || paramEditorTarget != nil }

    private func isInPanel(_ y: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> Bool { y >= top && y <= bottom }

    private func clamp<V: Comparable>(_ v: V, _ lo: V, _ hi: V) -> V { min(max(v, lo), hi) }

    private func chartDragGesture(candleSpacing: CGFloat,
                                  mainTop: CGFloat, mainBottom: CGFloat,
                                  s1Top: CGFloat, s1Bottom: CGFloat,
                                  s2Top: CGFloat, s2Bottom: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !menuIsOpen else { return }
                drag.isDragging = true
                // 记录最近触摸位置，作为双指缩放时的锚点（双指质心）
                drag.lastTouchX = value.location.x
                let y = value.location.y
                let inMain = isInPanel(y, mainTop, mainBottom)
                // 区间统计边界拖动：命中边界线附近（或已处于边界拖动中）且在主图区域时，优先调整统计区间
                if inMain && displaySettings.showRangeStats {
                    let edge = statsDragEdge ?? statsEdge(atX: value.location.x, candleSpacing: candleSpacing)
                    if let edge {
                        statsDragEdge = edge
                        let col = Int((value.location.x / candleSpacing).rounded())
                        let idx = clamp(startIndex + col, 0, sortedData.count - 1)
                        switch edge {
                        case .start: statsStartIndex = min(idx, statsRangeIndices.end - 1)
                        case .end: statsEndIndex = max(idx, statsRangeIndices.start + 1)
                        }
                        return
                    }
                }
                let inS1 = isInPanel(y, s1Top, s1Bottom)
                let inS2 = isInPanel(y, s2Top, s2Bottom)
                guard inMain || inS1 || inS2 else { return }

                if selectedIndex != nil {
                    let col = Int((value.location.x / candleSpacing).rounded(.down))
                    let idx = startIndex + col
                    if idx >= startIndex && idx <= endIndex {
                        selectedIndex = idx
                        crosshairY = value.location.y
                    }
                    if abs(value.translation.width) > 6 || abs(value.translation.height) > 6 { drag.cursorDragging = true }
                } else if inMain && drag.dragMode == .none {
                    if abs(value.translation.height) > abs(value.translation.width) && abs(value.translation.height) > 4 {
                        drag.dragMode = .zoom
                    } else if abs(value.translation.width) > 4 {
                        drag.dragMode = .pan
                    }
                    drag.lastPanWidth = 0; drag.lastPanHeight = 0
                }

                if drag.dragMode == .zoom {
                    let deltaY = value.translation.height - drag.lastPanHeight
                    drag.lastPanHeight = value.translation.height
                    visibleCount = clamp(visibleCount + deltaY * 0.5, 20, CGFloat(maxVisibleCount))
                } else if drag.dragMode == .pan {
                    let delta = value.translation.width - drag.lastPanWidth
                    drag.lastPanWidth = value.translation.width
                    // 亚像素平滑平移：先累计像素偏移，累计满一根K线间距才进位移动窗口，保证缓慢拖动也平滑跟手
                    panOffset += delta
                    let shift = Int((panOffset / candleSpacing).rounded())
                    if shift != 0 {
                        let newOffset = clamp(endOffset + shift, 0, max(0, sortedData.count - count))
                        let applied = newOffset - endOffset
                        endOffset = newOffset
                        panOffset -= CGFloat(applied) * candleSpacing
                    }
                }
            }
            .onEnded { value in
                drag.lastPanWidth = 0; drag.lastPanHeight = 0; drag.dragMode = .none
                panOffset = 0
                statsDragEdge = nil
                // 关键：无论手势如何结束（含提前 return 的分支），都必须重置拖拽状态，
                // 否则 isDragging 一直为 true，后续切换/修改指标的重算都会被跳过
                drag.isDragging = false
                if drag.needsRefreshAfterDrag {
                    drag.needsRefreshAfterDrag = false
                    refreshCurves()
                }
                guard !menuIsOpen else { drag.cursorDragging = false; return }
                // 副图横向滑动：第一副图切换周期，第二副图切换标的（明显横向滑动时优先，忽略纵向）
                let startY = value.startLocation.y
                let inS1Start = isInPanel(startY, s1Top, s1Bottom)
                let inS2Start = isInPanel(startY, s2Top, s2Bottom)
                let w = value.translation.width
                let isHSwipe = abs(w) > 30 && abs(w) > abs(value.translation.height) * 1.5
                if isHSwipe && (inS1Start || inS2Start) {
                    selectedIndex = nil; crosshairY = nil
                    if inS1Start {
                        switchPeriod(direction: w > 0 ? -1 : 1)
                    } else {
                        onSwitchItem?(w > 0 ? -1 : 1)
                    }
                    return
                }
                if drag.cursorDragging { drag.cursorDragging = false; return }
                let y = value.location.y
                let inPanel = isInPanel(y, mainTop, mainBottom) || isInPanel(y, s1Top, s1Bottom) || isInPanel(y, s2Top, s2Bottom)
                let isTap = abs(value.translation.width) < 6 && abs(value.translation.height) < 6
                if isTap && inPanel {
                    let col = Int((value.location.x / candleSpacing).rounded(.down))
                    let idx = startIndex + col
                    if selectedIndex != nil {
                        selectedIndex = nil; crosshairY = nil
                    } else if idx >= startIndex && idx <= endIndex {
                        selectedIndex = idx; crosshairY = value.location.y
                    }
                }
            }
    }

    /// 第一副图横向滑动切换周期：direction = 1 更大级别（右滑）/ -1 更小级别（左滑）；无对应周期时忽略
    private func switchPeriod(direction: Int) {
        guard let onPeriodSwitch else { return }
        let cases = KlinePeriod.allCases
        guard let cur = cases.firstIndex(of: period) else { return }
        let target = cur + direction
        guard target >= 0, target < cases.count else { return }
        onPeriodSwitch(cases[target])
    }

    /// 双指缩放：以双指位置（lastTouchX 质心）对应的K线为基线，保持该K线的屏幕位置不变
    private func magnificationGesture(width: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                selectedIndex = nil; crosshairY = nil
                let newCountF = clamp(zoomBase / value, 20, CGFloat(maxVisibleCount))
                let newCount = max(1, Int(newCountF.rounded()))
                // 缩放开始：以最近触摸位置（双指质心）确定锚点K线
                if zoomAnchorIndex == nil {
                    let spacing = width / CGFloat(max(1, count))
                    let anchor = startIndex + Int((drag.lastTouchX / spacing).rounded(.down))
                    zoomAnchorIndex = clamp(anchor, 0, max(0, sortedData.count - 1))
                    zoomAnchorOffset = (CGFloat(zoomAnchorIndex! - startIndex) + 0.5) * spacing
                }
                visibleCount = newCountF
                // 保持锚点K线屏幕位置不变：反推新的可见窗口起点
                if let anchor = zoomAnchorIndex {
                    let spacing1 = width / CGFloat(newCount)
                    let newStartF = CGFloat(anchor) - zoomAnchorOffset / spacing1 + 0.5
                    let newStart = Int(newStartF.rounded())
                    let newEnd = newStart + newCount - 1
                    let maxEnd = sortedData.count - 1
                    let minEnd = max(0, newCount - 1)
                    let clampedEnd = min(maxEnd, max(minEnd, newEnd))
                    endOffset = maxEnd - clampedEnd
                }
            }
            .onEnded { _ in
                zoomBase = visibleCount
                zoomAnchorIndex = nil
            }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let candleSpacing = width / CGFloat(max(1, count))
            let legendHeight: CGFloat = 18
            // 时间轴固定紧凑高度，把剩余空间全部还给主图，消除底部大块空白
            let timeHeight: CGFloat = 18
            let chartHeight = max(1, geometry.size.height - 3 * legendHeight - timeHeight)
            let sub1Height = chartHeight * 0.15
            let sub2Height = chartHeight * 0.19
            let mainHeight = max(1, chartHeight - sub1Height - sub2Height)

            let mainTop = legendHeight
            let mainBottom = mainTop + mainHeight
            let s1Top = mainBottom + legendHeight
            let s1Bottom = s1Top + sub1Height
            let s2Top = s1Bottom + legendHeight
            let s2Bottom = s2Top + sub2Height

            VStack(spacing: 0) {
                mainLegendRow(height: legendHeight).zIndex(30)
                mainChart(width: width, candleSpacing: candleSpacing, height: mainHeight)
                subLegendRow(model: subTop, height: legendHeight).zIndex(30)
                subChart(model: subTop, width: width, candleSpacing: candleSpacing, height: sub1Height,
                         slot: .top)
                subLegendRow(model: subBottom, height: legendHeight).zIndex(30)
                subChart(model: subBottom, width: width, candleSpacing: candleSpacing, height: sub2Height,
                         slot: .bottom)
                timeAxis(width: width, candleSpacing: candleSpacing, height: timeHeight)
            }
            .contentShape(Rectangle())
            .gesture(chartDragGesture(candleSpacing: candleSpacing, mainTop: mainTop, mainBottom: mainBottom,
                                      s1Top: s1Top, s1Bottom: s1Bottom, s2Top: s2Top, s2Bottom: s2Bottom))
            .simultaneousGesture(magnificationGesture(width: width))
            .overlay {
                if let crosshairY, isInPanel(crosshairY, mainTop, mainBottom) || isInPanel(crosshairY, s1Top, s1Bottom) || isInPanel(crosshairY, s2Top, s2Bottom) {
                    let y = min(max(crosshairY, 0), geometry.size.height)
                    let valueText = crosshairValueText(at: crosshairY, mainTop: mainTop, mainBottom: mainBottom,
                                                       mainHeight: mainHeight, s1Top: s1Top, s1Bottom: s1Bottom,
                                                       s1Height: sub1Height, s2Top: s2Top, s2Bottom: s2Bottom,
                                                       s2Height: sub2Height)
                    ZStack(alignment: .topLeading) {
                        crosshairLineOverlay(width: width, height: geometry.size.height, y: y, valueText: valueText)
                        // 主图横线右边：光标K线收盘 → 屏幕最后那根K线收盘 的涨幅
                        if let idx = selectedIndex, isInPanel(crosshairY, mainTop, mainBottom),
                           idx >= startIndex, idx <= endIndex, endIndex >= 0, endIndex < sortedData.count {
                            let cursorItem = sortedData[idx]
                            let screenLast = sortedData[endIndex]
                            if cursorItem.close > 0, screenLast.close > 0 {
                                let pct = (screenLast.close - cursorItem.close) / cursorItem.close * 100
                                // 周期数：光标K线 → 当前屏幕最后一根K线
                                let periodCount = max(0, endIndex - idx)
                                // 使用整宽右对齐容器，让标签右边缘精确贴合屏幕最右侧
                                Text(String(format: "%+.2f%%  %d", pct, periodCount))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .background(pct >= 0 ? upColor : downColor)
                                    .frame(width: width, alignment: .trailing)
                                    .position(x: width / 2, y: y)
                            }
                        }
                    }
                }
            }
            .overlay {
                if showCustomEditor {
                    FormulaEditorView(data: sortedData) {
                        showCustomEditor = false
                    } onSaved: { ind in
                        switch editorTarget {
                        case .main: activateCustom(ind)
                        case .sub:
                            let m = model(for: editingSlot)
                            activateSubCustom(m, ind)
                        }
                    }
                    .zIndex(50)
                }
            }
            .overlay {
                if showMainSheet {
                    bottomSheet(geometry: geometry, heightFraction: 0.8) {
                        mainSheetContent
                    } onClose: { showMainSheet = false }
                } else if showSubSheet {
                    bottomSheet(geometry: geometry, heightFraction: 0.8) {
                        subSheetContent
                    } onClose: { showSubSheet = false }
                }
            }
            .overlay {
                if let target = paramEditorTarget {
                    bottomSheet(geometry: geometry, heightFraction: 0.8) {
                        paramEditorView(for: target)
                    } onClose: { paramEditorTarget = nil }
                    .zIndex(60)
                }
            }
        }
        .background(Color.white)
        .onAppear {
            // 副图配置已持久化在共享仓库，无需重置
            refreshCurves()
        }
        .onChange(of: config.showBareK) { _ in
            // 顶部栏裸K按钮切换后立即重算（隐藏/恢复主图指标）
            recomputeMainCurves(force: true)
        }
        .onChange(of: customStore.indicators) { _ in
            syncCustomAfterStoreChange()
            refreshCurves()
        }
    }

    private func refreshCurves() {
        recomputeMainCurves()
        recomputeSub(subTop)
        recomputeSub(subBottom)
    }

    private func model(for slot: SubSlot) -> SubChartModel { slot == .top ? subTop : subBottom }

    private func activateCustom(_ ind: CustomIndicator?) {
        config.activeCustomIndicatorID = ind?.id
        recomputeMainCurves(force: true)
    }

    private func activateSubCustom(_ m: SubChartModel, _ ind: CustomIndicator?) {
        m.activeCustomID = ind?.id
        recomputeSub(m, force: true)
    }

    private func syncCustomAfterStoreChange() {
        if config.activeCustomIndicatorID != nil,
           !customStore.indicators.contains(where: { $0.id == config.activeCustomIndicatorID }) {
            config.activeCustomIndicatorID = nil
        }
        for m in [subTop, subBottom] {
            if m.activeCustomID != nil,
               !customStore.indicators.contains(where: { $0.id == m.activeCustomID }) {
                m.activeCustomID = nil
            }
        }
    }

    // MARK: - 主图

    /// 根据光标 y 所在面板计算对应的数值文本（主图价格 / 副图指标值）
    private func crosshairValueText(at y: CGFloat, mainTop: CGFloat, mainBottom: CGFloat, mainHeight: CGFloat,
                                    s1Top: CGFloat, s1Bottom: CGFloat, s1Height: CGFloat,
                                    s2Top: CGFloat, s2Bottom: CGFloat, s2Height: CGFloat) -> String {
        if y >= mainTop && y <= mainBottom {
            let ratio = Double((y - mainTop) / mainHeight)
            let v = priceRange.upperBound - (priceRange.upperBound - priceRange.lowerBound) * ratio
            return String(format: "%.2f", v)
        }
        if y >= s1Top && y <= s1Bottom {
            let r = subRange(subTop)
            let ratio = Double((y - s1Top) / s1Height)
            let v = r.max - (r.max - r.min) * ratio
            return subFormatter(for: subTop.kind)(v)
        }
        if y >= s2Top && y <= s2Bottom {
            let r = subRange(subBottom)
            let ratio = Double((y - s2Top) / s2Height)
            let v = r.max - (r.max - r.min) * ratio
            return subFormatter(for: subBottom.kind)(v)
        }
        return ""
    }

    /// 十字光标横线 + 天蓝色背景数值标签（横线从数值背景的最左边开始画起，贯穿全宽）
    private func crosshairLineOverlay(width: CGFloat, height: CGFloat, y: CGFloat, valueText: String) -> some View {
        ZStack(alignment: .topLeading) {
            // 横轴虚线：从数值背景的最左边（x=0）开始画起
            Rectangle().fill(Color.black.opacity(0.45)).frame(width: width, height: 1.0)
                .position(x: width / 2, y: y)
            // 光标数值：天蓝色矩形背景（高=字体高度、宽=内容宽度），白字加粗，比主图坐标数值大一号
            Text(valueText)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .background(Color(red: 0.35, green: 0.75, blue: 1.0))
                .offset(y: y - 6)
        }
    }

    private func mainChart(width: CGFloat, candleSpacing: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.white
            mainCanvas(width: width, candleSpacing: candleSpacing, height: height)
                .offset(x: panOffset)
            // 主图价格坐标：网格线仍为5条，数值只显示顶底两个（中间三个不显示）
            overlayPriceLabels(width: width, height: height, min: priceRange.lowerBound, max: priceRange.upperBound,
                               ratios: [0, 1], formatter: { String(format: "%.2f", $0) })
            // 最新价：只保留虚线（在 Canvas 中绘制），不显示数值，避免与虚线重叠
            if let selectedIndex, selectedIndex >= startIndex, selectedIndex <= endIndex {
                let item = sortedData[selectedIndex]
                let xPosition = (CGFloat(selectedIndex - startIndex) + 0.5) * candleSpacing
                // 主图竖线：从顶部日期标签背景下沿开始画到底部（竖线完全从背景底下开始，顶部无露出）
                let topCut = clampedAxisY(0, in: height) + 8
                let lineHeight = max(0, height - topCut)
                Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1.0, height: lineHeight)
                    .position(x: xPosition, y: topCut + lineHeight / 2)
                // 顶部日期+星期标签：位于主图顶部坐标值那一行、跟随竖线位置，样式与横轴数值一致（天蓝色背景、白字加粗）；
                // 靠近左右边界时向内收敛，避免超出屏幕
                let dateHalfW: CGFloat = 48
                let dateX = min(max(xPosition, dateHalfW), max(dateHalfW, width - dateHalfW))
                Text(item.formattedDateWithWeekday)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .background(Color(red: 0.35, green: 0.75, blue: 1.0))
                    .position(x: dateX, y: clampedAxisY(0, in: height))
                // 主图竖线下方（底部）：距今涨幅（光标K线收盘 → 整个数据集最后一根K线收盘）+ 距今周期数，白字、背景红涨绿跌
                if let last = sortedData.last, last.close > 0 {
                    let pct = (last.close - item.close) / item.close * 100
                    let periodCount = max(0, (sortedData.count - 1) - selectedIndex)
                    let pctHalfW: CGFloat = 70
                    let pctX = min(max(xPosition, pctHalfW), max(pctHalfW, width - pctHalfW))
                    Text(String(format: "%+.2f%%  %d", pct, periodCount))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .background(pct >= 0 ? upColor : downColor)
                        .position(x: pctX, y: height - 9)
                }
            }
            // 区间统计：绘制可拖动的统计区间边界线（起点/终点）
            if displaySettings.showRangeStats {
                let s = statsRangeIndices.start
                let e = statsRangeIndices.end
                let sx = min(max((CGFloat(s - startIndex) + 0.5) * candleSpacing, 0), width)
                let ex = min(max((CGFloat(e - startIndex) + 0.5) * candleSpacing, 0), width)
                Rectangle().fill(Color.blue.opacity(0.55)).frame(width: 1.5, height: height).position(x: sx, y: height / 2)
                Rectangle().fill(Color.blue.opacity(0.55)).frame(width: 1.5, height: height).position(x: ex, y: height / 2)
            }
            if displaySettings.showRangeStats, let stats = rangeStats {
                rangeStatsView(stats) {
                    // 重置为跟随屏幕可见区间
                    statsStartIndex = nil
                    statsEndIndex = nil
                }
                .padding(.trailing, 6).padding(.top, 2)
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    /// 实际统计区间：自定义边界未设置时跟随屏幕可见区间，设置了则用手动拖动的边界
    private var statsRangeIndices: (start: Int, end: Int) {
        let lo = statsStartIndex ?? startIndex
        let hi = statsEndIndex ?? endIndex
        let minIdx = 0
        let maxIdx = max(0, sortedData.count - 1)
        return (clamp(min(lo, hi), minIdx, maxIdx), clamp(max(lo, hi), minIdx, maxIdx))
    }

    /// 判断某个横向位置是否命中统计区间的起点/终点边界线（用于拖动调整）
    private func statsEdge(atX x: CGFloat, candleSpacing: CGFloat) -> StatsEdge? {
        let s = statsRangeIndices.start
        let e = statsRangeIndices.end
        guard s <= e else { return nil }
        let sx = (CGFloat(s - startIndex) + 0.5) * candleSpacing
        let ex = (CGFloat(e - startIndex) + 0.5) * candleSpacing
        let tol: CGFloat = 16
        if abs(x - sx) <= tol { return .start }
        if abs(x - ex) <= tol { return .end }
        return nil
    }

    /// 区间统计（通达信风格）：按统计区间计算涨跌幅、高低、量额
    private var rangeStats: (start: String, end: String, change: Double, high: Double, low: Double, vol: Double, amo: Double)? {
        let s = statsRangeIndices.start
        let e = statsRangeIndices.end
        guard s <= e, s >= 0, e < sortedData.count else { return nil }
        let statSlice = sortedData[s...e]
        guard let first = statSlice.first, let last = statSlice.last else { return nil }
        let prevClose = s > 0 ? sortedData[s - 1].close : first.open
        let change = prevClose > 0 ? (last.close - prevClose) / prevClose * 100 : 0
        let high = statSlice.map(\.high).max() ?? 0
        let low = statSlice.map(\.low).min() ?? 0
        let vol = statSlice.reduce(0.0) { $0 + $1.volume }
        let amo = statSlice.reduce(0.0) { $0 + $1.turnover }
        return (first.formattedDate, last.formattedDate, change, high, low, vol, amo)
    }

    private func rangeStatsView(_ s: (start: String, end: String, change: Double, high: Double, low: Double, vol: Double, amo: Double),
                                onReset: @escaping () -> Void) -> some View {
        let changeColor: Color = s.change >= 0 ? upColor : downColor
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("区间统计").font(.system(size: 9, weight: .semibold)).foregroundColor(.black)
                Spacer()
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
            }
            Text("\(s.start) ~ \(s.end)").font(.system(size: 9)).foregroundColor(.gray)
            HStack(spacing: 8) {
                Text("涨跌幅").font(.system(size: 9)).foregroundColor(.gray)
                Text(String(format: "%+.2f%%", s.change)).font(.system(size: 9)).foregroundColor(changeColor)
            }
            HStack(spacing: 8) {
                kv("高", s.high, upColor)
                kv("低", s.low, downColor)
            }
            HStack(spacing: 8) {
                Text("量").font(.system(size: 9)).foregroundColor(.gray)
                Text(formatVolume(s.vol)).font(.system(size: 9)).foregroundColor(.black)
                Text("额").font(.system(size: 9)).foregroundColor(.gray)
                Text(formatVolume(s.amo)).font(.system(size: 9)).foregroundColor(.black)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .topTrailing)
        .background(Color.white.opacity(0.9)).cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
    }

    private func mainCanvas(width: CGFloat, candleSpacing: CGFloat, height: CGFloat) -> some View {
        MainChartCanvas(slice: slice, chartStyle: chartStyle, candleSpacing: candleSpacing, height: height,
                        priceMin: priceRange.lowerBound, priceMax: priceRange.upperBound,
                        curves: mainCurves.map { CanvasCurve(color: $0.color, values: sliceArr($0.values), style: $0.style, lineWidth: $0.lineWidth, barColor: $0.barColor, markerColors: sliceColors($0.markerColors)) },
                        upColor: upColor, downColor: downColor, gridColor: gridColor,
                        showGap: displaySettings.showGap, showLatestPriceLine: displaySettings.showLatestPriceLine,
                        gapDisappearAfterFill: displaySettings.gapDisappearAfterFill,
                        gaps: gaps, sliceStart: startIndex,
                        latest: sortedAll.last)
            .equatable()
    }

    // MARK: - 副图

    private func subChart(model m: SubChartModel, width: CGFloat, candleSpacing: CGFloat,
                          height: CGFloat, slot: SubSlot) -> some View {
        let range = subRange(m)
        let subFmt: (Double) -> String = subFormatter(for: m.kind)
        return ZStack(alignment: .topLeading) {
            Color.white
            SubChartCanvas(slice: slice, candleSpacing: candleSpacing, height: height,
                           curves: m.curves.map { CanvasCurve(color: $0.color, values: sliceArr($0.values), style: $0.style, lineWidth: $0.lineWidth, barColor: $0.barColor) },
                           rangeMin: range.min, rangeMax: range.max,
                           upColor: upColor, downColor: downColor, gridColor: gridColor)
                .equatable()
                .offset(x: panOffset)
            // 顶底坐标值：VOL/AMO 最低值恒为 0，底部"0"无需显示；其他指标保留顶底两个值
            let labelRatios: [CGFloat] = (m.kind == .vol || m.kind == .amo) ? [0] : [0, 1]
            overlayPriceLabels(width: width, height: height, min: range.min, max: range.max,
                               ratios: labelRatios, formatter: subFmt)

            if let selectedIndex, selectedIndex >= startIndex, selectedIndex <= endIndex {
                let xPosition = (CGFloat(selectedIndex - startIndex) + 0.5) * candleSpacing
                Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1.0, height: height).position(x: xPosition, y: height / 2)
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private func subLegendRow(model m: SubChartModel, height: CGFloat) -> some View {
        ZStack {
            HStack(spacing: 8) {
                IndicatorNameButton(title: m.titleName, onTap: {
                    editingSlot = (m === subTop) ? .top : .bottom
                    showMainSheet = false
                    withAnimation { showSubSheet.toggle() }
                })
                ForEach(Array(m.curves.enumerated()), id: \.offset) { _, line in
                    legendItem(line)
                }
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(Color.white)
        }
        .frame(height: height)
    }

    // MARK: - 主图指标栏

    private func mainLegendRow(height: CGFloat) -> some View {
        ZStack {
            HStack(spacing: 8) {
                IndicatorNameButton(title: mainLegendTitle, onTap: {
                    showSubSheet = false
                    withAnimation { showMainSheet.toggle() }
                })
                if config.showBareK { legendText("裸K") }
                ForEach(Array(mainCurves.enumerated()), id: \.offset) { _, line in
                    legendItem(line)
                }
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(Color.white)
        }
        .frame(height: height)
    }

    private var mainLegendTitle: String {
        if config.showBareK { return "\(period.rawValue): 裸K" }
        var parts: [String] = []
        if config.showMA { parts.append("MA") }
        if config.showEMA { parts.append("EMA") }
        if config.showBOLL { parts.append("BOLL") }
        if config.showCMK { parts.append("CMK") }
        if config.showSAR { parts.append("SAR") }
        if let a = activeCustomIndicator { parts.append(a.name) }
        if parts.isEmpty { return "\(period.rawValue): 裸K" }
        return "\(period.rawValue): \(parts.joined(separator: "/"))"
    }

    /// 副图坐标数值格式化
    private func subFormatter(for kind: SubChartKind) -> (Double) -> String {
        switch kind {
        case .vol, .amo: return { formatVolume($0) }
        case .macd, .vmacd: return { String(format: "%.3f", $0) }
        case .obv, .brar: return { String(format: "%.2f", $0) }
        default: return { String(format: "%.1f", $0) }
        }
    }

    private func legendItem(_ line: IndicatorLine, format: String = "%.2f") -> some View {
        // NOTEXT_ 前缀的输出线：不显示名称也不显示数值（仅保留线条）
        if line.hideValue { return AnyView(EmptyView()) }
        let name = legendName(line)
        let color = line.color
        if let value = legendValueFor(line), !value.isNaN {
            return AnyView(Text("\(name):\(String(format: format, value))")
                .font(.system(size: 12))
                .foregroundColor(color))
        } else {
            return AnyView(Text(name)
                .font(.system(size: 11))
                .foregroundColor(color))
        }
    }

    /// 均线类指标名称直接显示参数数值（MA5/EMA5 → 5），用于主图 MA/EMA、VOL/AMO/CR 的量均线；其余指标保留原名
    private func legendName(_ line: IndicatorLine) -> String {
        let n = line.name
        for prefix in ["EMA", "MA"] {
            if n.hasPrefix(prefix) {
                let rest = n.dropFirst(prefix.count)
                if Int(rest) != nil { return String(rest) }
            }
        }
        return n
    }

    private func legendText(_ text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(Color.gray).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11)).foregroundColor(.gray)
        }
    }

    private func overlayPriceLabels(width: CGFloat, height: CGFloat, min: Double, max: Double, ratios: [CGFloat], formatter: @escaping (Double) -> String) -> some View {
        ZStack {
            ForEach(ratios, id: \.self) { ratio in
                let value = max - (max - min) * Double(ratio)
                Text(formatter(value))
                    .font(.system(size: 9))
                    .foregroundColor(axisTextColor)
                    .position(x: 22, y: clampedAxisY(height * CGFloat(ratio), in: height))
            }
        }
        .frame(width: width, height: height)
    }
    private func formatVolume(_ v: Double) -> String {
        if v >= 100000000 { return String(format: "%.2f亿", v / 100000000) }
        else if v >= 10000 { return String(format: "%.2f万", v / 10000) }
        else { return String(format: "%.0f", v) }
    }

    private func clampedAxisY(_ y: CGFloat, in height: CGFloat) -> CGFloat {
        let half: CGFloat = 8
        return min(max(y, half), max(half, height - half))
    }

    private func timeAxis(width: CGFloat, candleSpacing: CGFloat, height: CGFloat) -> some View {
        let left = sortedData[startIndex].formattedDateWithWeekday
        let right = sortedData[endIndex].formattedDateWithWeekday
        return ZStack {
            HStack(spacing: 0) {
                Text(left).font(.system(size: 10)).foregroundColor(.gray)
                Text("   周期数\(count)个").font(.system(size: 10)).foregroundColor(.gray)
                Spacer()
            }
            Text(right).font(.system(size: 10)).foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .trailing)
            // 光标出现时：在时间轴上覆盖显示 开/收/高/低/涨/额（涨为百分比），替代浮动行情窗口
            if let selectedIndex, selectedIndex >= startIndex, selectedIndex <= endIndex {
                let item = sortedData[selectedIndex]
                let prev = prevClose(of: selectedIndex)
                let changePct = prev > 0 ? (item.close - prev) / prev * 100 : 0
                HStack(spacing: 6) {
                    axisKV("开", String(format: "%.2f", item.open), .black)
                    axisKV("收", String(format: "%.2f", item.close), item.isUp ? upColor : downColor)
                    axisKV("高", String(format: "%.2f", item.high), upColor)
                    axisKV("低", String(format: "%.2f", item.low), downColor)
                    axisKV("涨", String(format: "%+.2f%%", changePct), changePct >= 0 ? upColor : downColor)
                    axisKV("额", item.formattedTurnover, .black)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.95))
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(width: width, height: height)
        .background(Color.white)
    }

    /// 时间轴上紧凑的"标题:值"单元（标题灰色小字、值带色）
    private func axisKV(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundColor(.gray)
            Text(value).font(.system(size: 10)).foregroundColor(color)
        }
    }

    // MARK: - 全屏参数编辑页（双击指标名称打开）

    private func paramEditorView(for target: ParamEditorTarget) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(editorTitle(for: target)).font(.system(size: 16, weight: .bold)).foregroundColor(.black)
                Spacer()
                if canResetParams(for: target) {
                    Button("重置") { resetParams(for: target) }
                        .font(.system(size: 14)).foregroundColor(.orange)
                        .padding(.trailing, 12)
                }
                // 返回：关闭参数编辑面板并回到对应的选择指标页面
                Button("返回") {
                    paramEditorTarget = nil
                    switch target {
                    case .main:
                        withAnimation { showMainSheet = true }
                    case .sub(let slot):
                        editingSlot = slot
                        withAnimation { showSubSheet = true }
                    }
                }
                .font(.system(size: 14)).foregroundColor(.blue)
                .padding(.trailing, 12)
                Button("完成") { paramEditorTarget = nil }
                    .font(.system(size: 14)).foregroundColor(.blue)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch target {
                    case .main:
                        if config.showMA {
                            paramRow(title: "MA 周期与数据源（0=隐藏）") {
                                maSourceEditor($config.maConfig.periods, $config.maConfig.sources) { recomputeMainCurves(force: true) }
                            }
                        }
                        if config.showEMA {
                            paramRow(title: "EMA 周期与数据源（0=隐藏）") {
                                maSourceEditor($config.emaConfig.periods, $config.emaConfig.sources) { recomputeMainCurves(force: true) }
                            }
                        }
                        if config.showBOLL {
                            paramRow(title: "BOLL 参数") {
                                HStack(spacing: 12) {
                                    numberField("周期", $config.bollConfig.period, range: 1...1000) { recomputeMainCurves(force: true) }
                                    numberField("倍数", $config.bollConfig.mult, range: 0.1...10) { recomputeMainCurves(force: true) }
                                }
                            }
                        }
                        if config.showCMK {
                            paramRow(title: "CMK 参数") {
                                HStack(spacing: 12) {
                                    numberField("N", $config.cmkN, range: 1...300) { recomputeMainCurves(force: true) }
                                }
                            }
                        }
                        if config.showSAR {
                            paramRow(title: "SAR 参数") {
                                HStack(spacing: 12) {
                                    numberField("步长", $config.sarStep, range: 0.001...0.1) { recomputeMainCurves(force: true) }
                                    numberField("极限", $config.sarMax, range: 0.01...1) { recomputeMainCurves(force: true) }
                                }
                            }
                        }
                        if !config.showMA && !config.showEMA && !config.showBOLL && !config.showCMK
                            && !config.showSAR {
                            Text("当前没有可编辑的系统指标").font(.system(size: 13)).foregroundColor(.gray).padding(24)
                        }
                    case .sub(let slot):
                        let m = model(for: slot)
                        if m.isCustom {
                            Text("自定义指标请通过公式编辑器修改").font(.system(size: 13)).foregroundColor(.gray).padding(24)
                        } else {
                            subParamsEditor(m)
                        }
                    }
                    Spacer(minLength: 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    private func editorTitle(for target: ParamEditorTarget) -> String {
        switch target {
        case .main: return "主图指标参数"
        case .sub(let slot): return "\(model(for: slot).titleName) 参数"
        }
    }

    /// 是否有可重置的系统参数（自定义指标无系统参数，隐藏重置按钮）
    private func canResetParams(for target: ParamEditorTarget) -> Bool {
        switch target {
        case .main: return true
        case .sub(let slot): return !model(for: slot).isCustom
        }
    }

    /// 重置系统指标参数为默认值
    private func resetParams(for target: ParamEditorTarget) {
        switch target {
        case .main:
            config.maConfig = MAConfig()
            config.emaConfig = EMAConfig()
            config.bollConfig = BOLLConfig()
            config.cmkN = 10
            config.sarStep = 0.02
            config.sarMax = 0.2
            recomputeMainCurves(force: true)
        case .sub(let slot):
            let m = model(for: slot)
            m.resetParams()
            if m.kind == .vol || m.kind == .amo {
                m.volPeriods = [5, 10, 0, 0, 0, 0, 0, 0]
            }
            recomputeSub(m, force: true)
        }
    }

    private func subParamsEditor(_ m: SubChartModel) -> some View {
        Group {
            if m.kind == .vol || m.kind == .amo {
                paramRow(title: "量均线周期（0=隐藏）") {
                    periodsEditor(Binding(get: { m.volPeriods },
                                           set: { v in m.volPeriods = v; recomputeSub(m, force: true) })) { }
                }
            } else {
                let specs = m.kind.paramSpecs
                if specs.isEmpty {
                    Text("该指标无参数可调").font(.system(size: 13)).foregroundColor(.gray).padding(24)
                } else {
                    paramRow(title: "\(m.kind.rawValue) 参数") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 12)], spacing: 10) {
                            ForEach(specs) { spec in
                                let binding = Binding(
                                    get: { m.params[spec.key] ?? spec.defaultValue },
                                    set: { v in m.params[spec.key] = v; recomputeSub(m, force: true) }
                                )
                                numberField(spec.label, binding, range: spec.range)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 底部面板容器

    private func bottomSheet<Content: View>(geometry: GeometryProxy, heightFraction: CGFloat,
                                            @ViewBuilder content: () -> Content,
                                            onClose: @escaping () -> Void) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.35).ignoresSafeArea().frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { onClose() } }
            VStack(spacing: 0) {
                content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: geometry.size.width, height: min(geometry.size.height * heightFraction, 660))
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 主图选择页（紧凑分组 + 编辑图标）

    private var mainSheetContent: some View {
        VStack(spacing: 0) {
            sheetHeader(title: "主图指标") { showMainSheet = false }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    groupHeader("均线型")
                    LazyVGrid(columns: gridColumns, spacing: 8) {
                        mainTile("MA", on: config.showMA) { toggleMain(.ma) }
                        mainTile("EMA", on: config.showEMA) { toggleMain(.ema) }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 6)

                    groupHeader("路径型")
                    LazyVGrid(columns: gridColumns, spacing: 8) {
                        mainTile("BOLL", on: config.showBOLL) { toggleMain(.boll) }
                        mainTile("CMK", on: config.showCMK) { toggleMain(.cmk) }
                        mainTile("SAR", on: config.showSAR) { toggleMain(.sar) }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 6)

                    // 系统指标参数入口
                    if config.showMA || config.showEMA || config.showBOLL || config.showCMK
                        || config.showSAR {
                        paramEntryRow(title: "参数设置") {
                            showMainSheet = false
                            paramEditorTarget = .main
                        }
                    }

                    groupHeader("自定义指标（主图）")
                    HStack {
                        Button("+ 新增/管理") { showMainSheet = false; editorTarget = .main; showCustomEditor = true }
                            .font(.system(size: 13)).foregroundColor(.blue)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    if mainCustoms.isEmpty {
                        Text("暂无主图自定义指标").font(.system(size: 12)).foregroundColor(.gray)
                            .padding(.horizontal, 16).padding(.bottom, 12)
                    } else {
                        ForEach(mainCustoms) { ind in mainCustomRow(ind) }
                    }
                    Spacer(minLength: 24)
                }
            }
        }
    }

    private var gridColumns: [GridItem] { [GridItem(.adaptive(minimum: 80), spacing: 8)] }

    private enum MainRowKey { case ma, ema, boll, cmk, sar }
    private var mainCustoms: [CustomIndicator] { customStore.indicators.filter { $0.scope == .main } }

    private func toggleMain(_ group: MainRowKey) {
        switch group {
        case .ma: config.showMA.toggle()
        case .ema: config.showEMA.toggle()
        case .boll: config.showBOLL.toggle()
        case .cmk: config.showCMK.toggle()
        case .sar: config.showSAR.toggle()
        }
        recomputeMainCurves(force: true)
    }

    /// 主图指标格：复选框（多选）
    private func mainTile(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundColor(on ? .blue : .gray.opacity(0.6))
                Text(title).font(.system(size: 13)).foregroundColor(.black)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color(uiColor: .systemGray6).opacity(on ? 1 : 0.45))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.blue : Color.gray.opacity(0.25), lineWidth: on ? 1.5 : 1))
        }
    }

    private func mainCustomRow(_ ind: CustomIndicator) -> some View {
        HStack {
            Button {
                if activeCustomIndicator?.id == ind.id { activateCustom(nil) } else { activateCustom(ind) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: activeCustomIndicator?.id == ind.id ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(activeCustomIndicator?.id == ind.id ? .blue : .gray)
                    RoundedRectangle(cornerRadius: 2).fill(ind.color).frame(width: 14, height: 5)
                    Text(ind.name).font(.system(size: 14)).foregroundColor(.black)
                }
            }
            Spacer()
            Button {
                showMainSheet = false; editorTarget = .main; showCustomEditor = true
            } label: {
                Image(systemName: "pencil").font(.system(size: 13)).foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    // MARK: - 副图选择页（紧凑分组 + 编辑图标）

    private var subSheetContent: some View {
        let m = model(for: editingSlot)
        return VStack(spacing: 0) {
            sheetHeader(title: "选择副图指标 · \(slotTitle(editingSlot))") { showSubSheet = false }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SubChartKind.groupOrder, id: \.self) { g in
                        let kinds = SubChartKind.allCases.filter { $0.group == g }
                        if !kinds.isEmpty {
                            groupHeader(g)
                            LazyVGrid(columns: gridColumns, spacing: 8) {
                                ForEach(kinds) { k in
                                    subTile(k.rawValue, selected: !m.isCustom && m.kind == k) {
                                        m.activeCustomID = nil
                                        m.kind = k
                                        m.resetParams()
                                        recomputeSub(m, force: true)
                                    }
                                }
                            }
                            .padding(.horizontal, 16).padding(.bottom, 6)
                        }
                    }

                    // 系统指标参数入口
                    if !m.isCustom {
                        paramEntryRow(title: "\(m.kind.rawValue) 参数设置") {
                            showSubSheet = false
                            paramEditorTarget = .sub(editingSlot)
                        }
                    }

                    groupHeader("自定义指标（副图）")
                    HStack {
                        Button("+ 新增/管理") { showSubSheet = false; editorTarget = .sub; showCustomEditor = true }
                            .font(.system(size: 13)).foregroundColor(.blue)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    if subCustoms.isEmpty {
                        Text("暂无副图自定义指标").font(.system(size: 12)).foregroundColor(.gray)
                            .padding(.horizontal, 16).padding(.bottom, 12)
                    } else {
                        ForEach(subCustoms) { ind in subCustomRow(ind, model: m) }
                    }
                    Spacer(minLength: 24)
                }
            }
        }
    }

    /// 副图指标格：单选，选中名称蓝色
    private func subTile(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .blue : .black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(uiColor: .systemGray6).opacity(selected ? 1 : 0.45))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.blue : Color.gray.opacity(0.25), lineWidth: selected ? 1.5 : 1))
        }
    }

    private var subCustoms: [CustomIndicator] { customStore.indicators.filter { $0.scope == .sub } }
    private func slotTitle(_ slot: SubSlot) -> String { slot == .top ? "副图一" : "副图二" }

    private func subCustomRow(_ ind: CustomIndicator, model m: SubChartModel) -> some View {
        HStack {
            Button {
                activateSubCustom(m, ind)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: m.activeCustomID == ind.id ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(m.activeCustomID == ind.id ? .blue : .gray)
                    RoundedRectangle(cornerRadius: 2).fill(ind.color).frame(width: 14, height: 5)
                    Text(ind.name).font(.system(size: 14)).foregroundColor(.black)
                    if m.activeCustomID == ind.id {
                        Text("当前").font(.system(size: 10)).foregroundColor(.blue)
                    }
                }
            }
            Spacer()
            Button {
                showSubSheet = false; editorTarget = .sub; showCustomEditor = true
            } label: {
                Image(systemName: "pencil").font(.system(size: 13)).foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    // MARK: - 主体 UI 组件

    /// 全宽参数入口按钮行（打开全屏参数编辑页）
    private func paramEntryRow(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.blue.opacity(0.06))
            .cornerRadius(8)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.gray)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
    }

    private func sheetHeader(title: String, onClose: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 16, weight: .bold)).foregroundColor(.black)
            Spacer()
            Button("完成") { onClose() }.font(.system(size: 14)).foregroundColor(.blue)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func paramRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundColor(.gray)
            content()
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func periodsEditor(_ periods: Binding<[Int]>, _ onChange: @escaping () -> Void) -> some View {
        let list = Array(0..<8)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: 8, by: 4)), id: \.self) { rowStart in
                HStack(spacing: 12) {
                    ForEach(list[rowStart..<min(rowStart + 4, 8)], id: \.self) { idx in
                        smallNumberFieldPe(label: "\(idx + 1)", value: Binding(
                            get: { periods.wrappedValue.indices.contains(idx) ? String(periods.wrappedValue[idx]) : "0" },
                            set: { nv in
                                var arr = periods.wrappedValue
                                if arr.count != 8 { arr = Array(repeating: 0, count: 8) }
                                arr[idx] = min(max(Int(nv) ?? 0, 0), 1000)
                                periods.wrappedValue = arr
                                onChange()
                            }
                        ))
                    }
                }
            }
        }
    }

    /// MA/EMA 参数编辑：每个周期字段右侧带数据源下拉（CLOSE/OPEN/HIGH/LOW/平均值）
    private func maSourceEditor(_ periods: Binding<[Int]>, _ sources: Binding<[MAValueSource]>, _ onChange: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(0..<8), id: \.self) { idx in
                HStack(spacing: 8) {
                    Text("\(idx + 1)")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                        .frame(width: 16, alignment: .leading)
                    TextField("", text: Binding(
                        get: { periods.wrappedValue.indices.contains(idx) ? String(periods.wrappedValue[idx]) : "0" },
                        set: { nv in
                            var arr = periods.wrappedValue
                            if arr.count != 8 { arr = Array(repeating: 0, count: 8) }
                            arr[idx] = min(max(Int(nv) ?? 0, 0), 1000)
                            periods.wrappedValue = arr
                            onChange()
                        }
                    ))
                    .font(.system(size: 12)).keyboardType(.numberPad)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(Color(uiColor: .systemGray6)).cornerRadius(4)
                    .frame(width: 60)
                    Picker("", selection: Binding(
                        get: { sources.wrappedValue.indices.contains(idx) ? sources.wrappedValue[idx] : .close },
                        set: { nv in
                            var arr = sources.wrappedValue
                            if arr.count != 8 { arr = Array(repeating: .close, count: 8) }
                            arr[idx] = nv
                            sources.wrappedValue = arr
                            onChange()
                        }
                    )) {
                        ForEach(MAValueSource.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func smallNumberFieldPe(label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundColor(.gray)
            TextField("", text: value)
                .font(.system(size: 12)).keyboardType(.numberPad)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(Color(uiColor: .systemGray6)).cornerRadius(4)
        }
        .frame(maxWidth: .infinity)
    }

    private func numberField(_ label: String, _ value: Binding<Int>, range: ClosedRange<Int>, _ onChange: @escaping () -> Void = {}) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundColor(.gray)
            TextField("", text: Binding(
                get: { String(value.wrappedValue) },
                set: { nv in value.wrappedValue = min(max(Int(nv) ?? value.wrappedValue, range.lowerBound), range.upperBound); onChange() }
            ))
            .font(.system(size: 13)).keyboardType(.numberPad)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Color(uiColor: .systemGray6)).cornerRadius(4)
        }
        .frame(maxWidth: .infinity)
    }

    private func numberField(_ label: String, _ value: Binding<Double>, range: ClosedRange<Double>, _ onChange: @escaping () -> Void = {}) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundColor(.gray)
            TextField("", text: Binding(
                get: { String(format: "%.1f", value.wrappedValue) },
                set: { nv in value.wrappedValue = min(max(Double(nv) ?? value.wrappedValue, range.lowerBound), range.upperBound); onChange() }
            ))
            .font(.system(size: 13)).keyboardType(.decimalPad)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Color(uiColor: .systemGray6)).cornerRadius(4)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 十字光标辅助

    private func prevClose(of index: Int) -> Double {
        guard index > 0, index < sortedData.count else { return index < sortedData.count ? sortedData[index].close : 0 }
        return sortedData[index - 1].close
    }

    private func kv(_ title: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundColor(.gray)
            Text(String(format: "%.2f", value)).font(.system(size: 9)).foregroundColor(color)
        }
    }

    private func yPosition(for price: Double, in height: CGFloat) -> CGFloat {
        yPos(price, min: priceRange.lowerBound, max: priceRange.upperBound, height: height)
    }
    private func yPos(_ value: Double, min minValue: Double, max maxValue: Double, height: CGFloat) -> CGFloat {
        let range = maxValue - minValue
        guard range > 0 else { return height }
        return height * CGFloat(1 - (value - minValue) / range)
    }
}

// MARK: - 主图 Canvas

struct MainChartCanvas: View, Equatable {
    let slice: [KlineItem]
    let chartStyle: ChartStyle
    let candleSpacing: CGFloat
    let height: CGFloat
    let priceMin: Double
    let priceMax: Double
    let curves: [CanvasCurve]
    let upColor, downColor, gridColor: Color
    let showGap: Bool
    let showLatestPriceLine: Bool
    /// 缺口回补后是否整体隐藏（关闭时仅截止到回补位置、保留形成到截止区域）
    let gapDisappearAfterFill: Bool
    /// 预计算的跳空缺口（全数据集一次计算，绘制时按可见区间过滤）
    let gaps: [GapInfo]
    /// 可见区间的绝对起点索引（用于把缺口绝对索引换算为画布坐标）
    let sliceStart: Int
    /// 整个数据集的最后一根K线（最新价线固定在最新收盘价位置，与屏幕滚动位置无关）
    let latest: KlineItem?

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            for ratio: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                let y = h * ratio
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
            }

            // 可见 K 数很大时，绘制开销只与屏幕列宽成正比，与总/可见 K 数无关
            let cols = max(Int(w / 2.0), 1)
            let lineStep = max(1, (slice.count + cols - 1) / cols)
            let candleWidth = max(1.5, candleSpacing * 0.7)

            if showGap {
                drawGaps(ctx, h: h)
            }

            switch chartStyle {
            case .bare, .solid:
                drawCandles(ctx, h: h, candleWidth: candleWidth, hollow: chartStyle == .bare, cols: cols)
            case .close:
                strokeLine(ctx, values: slice.map(\.close), color: Color(red: 0.2, green: 0.4, blue: 0.9), h: h, style: .solid, lineWidth: 1, step: lineStep)
            case .ohlc:
                drawOHLC(ctx, h: h, candleWidth: candleWidth, step: lineStep)
            }

            for curve in curves { drawCurve(ctx, curve: curve, h: h, step: lineStep) }

            if showLatestPriceLine, let latest {
                let y = yPos(latest.close, h: h)
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                ctx.stroke(p, with: .color(latest.isUp ? upColor.opacity(0.6) : downColor.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [12, 6]))
            }
        }
    }

    /// 跳空缺口：使用预计算的缺口列表，仅绘制位于当前可见区间内的缺口。
    /// - 关闭"缺口回补后消失"（默认）：已回补的缺口延长到回补K线位置即截止，保留形成到截止区域
    /// - 开启：已回补的缺口整体隐藏；未回补的缺口从形成位置延长到可见末尾
    /// 每次重绘只遍历缺口列表（数量很少），不对可见K线全量扫描，拖拽/缩放不卡顿。
    private func drawGaps(_ ctx: GraphicsContext, h: CGFloat) {
        guard !gaps.isEmpty else { return }
        let lastVisibleIdx = sliceStart + slice.count - 1
        for gap in gaps {
            // 缺口形成位置必须在可见区间内
            guard gap.startIdx >= sliceStart && gap.startIdx <= lastVisibleIdx else { continue }
            let endIdx: Int
            if gapDisappearAfterFill {
                // 开启：已回补（截止）的缺口整体隐藏
                if gap.filledIdx != nil { continue }
                endIdx = lastVisibleIdx
            } else {
                // 关闭（默认）：已回补的缺口延长到回补位置截止；未回补延长到可见末尾
                endIdx = gap.filledIdx.map { min($0, lastVisibleIdx) } ?? lastVisibleIdx
            }
            guard endIdx >= gap.startIdx else { continue }
            let xStart = CGFloat(gap.startIdx - sliceStart) * candleSpacing
            let width = CGFloat(endIdx - gap.startIdx + 1) * candleSpacing
            let y0 = yPos(gap.top, h: h)
            let y1 = yPos(gap.bottom, h: h)
            let rect = CGRect(x: xStart, y: min(y0, y1), width: max(0.5, width), height: max(0.5, abs(y1 - y0)))
            let color = gap.isUp ? upColor.opacity(0.18) : downColor.opacity(0.18)
            ctx.fill(Path(rect), with: .color(color))
            ctx.stroke(Path(rect), with: .color(color.opacity(0.8)), lineWidth: 0.5)
        }
    }

    /// 按屏幕列数对 K 线聚合绘制：列足够宽时分笔绘制，否则按块合并保留开收高低极值。
    private func drawCandles(_ ctx: GraphicsContext, h: CGFloat, candleWidth: CGFloat, hollow: Bool, cols: Int) {
        let n = slice.count
        guard n > 0 else { return }
        let blockLen = max(1, (n + cols - 1) / cols)
        if blockLen == 1 {
            for (li, item) in slice.enumerated() {
                let x = (CGFloat(li) + 0.5) * candleSpacing
                drawOneCandle(ctx, open: item.open, close: item.close, low: item.low, high: item.high,
                              x: x, candleWidth: candleWidth, h: h, hollow: hollow, color: item.isUp ? upColor : downColor)
            }
            return
        }
        var lo = 0
        while lo < n {
            let hi = min(n, lo + blockLen)
            var low = Double.greatestFiniteMagnitude
            var high = -Double.greatestFiniteMagnitude
            for k in lo..<hi {
                let it = slice[k]
                if it.low < low { low = it.low }
                if it.high > high { high = it.high }
            }
            let open = slice[lo].open
            let close = slice[hi - 1].close
            let span = hi - lo
            let x = (CGFloat(lo) + CGFloat(span) * 0.5) * candleSpacing
            let color = slice[hi - 1].isUp ? upColor : downColor
            drawOneCandle(ctx, open: open, close: close, low: low, high: high,
                          x: x, candleWidth: max(1.5, candleWidth), h: h, hollow: hollow, color: color)
            lo = hi
        }
    }

    private func drawOneCandle(_ ctx: GraphicsContext, open: Double, close: Double, low: Double, high: Double,
                               x: CGFloat, candleWidth: CGFloat, h: CGFloat, hollow: Bool, color: Color) {
        let yH = yPos(high, h: h)
        let yL = yPos(low, h: h)
        var wick = Path(); wick.move(to: CGPoint(x: x, y: yH)); wick.addLine(to: CGPoint(x: x, y: yL))
        ctx.stroke(wick, with: .color(color), lineWidth: 1)
        let bodyTop = yPos(max(open, close), h: h)
        let bodyBottom = yPos(min(open, close), h: h)
        let rect = CGRect(x: x - candleWidth / 2, y: bodyTop, width: candleWidth, height: max(1, bodyBottom - bodyTop))
        if hollow && close >= open {
            ctx.fill(Path(rect), with: .color(Color.white))
            ctx.stroke(Path(rect), with: .color(color), lineWidth: 1)
        } else {
            ctx.fill(Path(rect), with: .color(color))
        }
    }

    /// 美国线：K 数过多时按步长采样，保留首尾点。
    private func drawOHLC(_ ctx: GraphicsContext, h: CGFloat, candleWidth: CGFloat, step: Int) {
        for li in decimatedIndices(count: slice.count, step: step) {
            let item = slice[li]
            let x = (CGFloat(li) + 0.5) * candleSpacing
            let color = item.isUp ? upColor : downColor
            let yH = yPos(item.high, h: h)
            let yL = yPos(item.low, h: h)
            var bar = Path(); bar.move(to: CGPoint(x: x, y: yH)); bar.addLine(to: CGPoint(x: x, y: yL))
            ctx.stroke(bar, with: .color(color), lineWidth: max(1, candleWidth * 0.12))
            let oy = yPos(item.open, h: h)
            var op = Path(); op.move(to: CGPoint(x: x - candleSpacing * 0.18, y: oy)); op.addLine(to: CGPoint(x: x, y: oy))
            ctx.stroke(op, with: .color(color), lineWidth: 1)
            let cy = yPos(item.close, h: h)
            var cl = Path(); cl.move(to: CGPoint(x: x, y: cy)); cl.addLine(to: CGPoint(x: x + candleSpacing * 0.18, y: cy))
            ctx.stroke(cl, with: .color(color), lineWidth: 1)
        }
    }

    private func drawCurve(_ ctx: GraphicsContext, curve: CanvasCurve, h: CGFloat, step: Int) {
        switch curve.style {
        case .dotline:
            strokeLine(ctx, values: curve.values, color: curve.color, h: h, style: .dotline, lineWidth: curve.lineWidth, step: step)
        case .pointdot:
            let colors = curve.markerColors
            for idx in decimatedIndices(count: curve.values.count, step: step) {
                let v = curve.values[idx]
                guard !v.isNaN else { continue }
                let x = (CGFloat(idx) + 0.5) * candleSpacing
                let y = yPos(v, h: h)
                let c = colors?[idx] ?? curve.color
                var dot = Path()
                dot.addEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                ctx.fill(dot, with: .color(c))
            }
        case .stick:
            let barWidth = max(0.6, candleSpacing * 0.55)
            let yBase = yPos(0, h: h)
            for i in decimatedIndices(count: curve.values.count, step: step) {
                let v = curve.values[i]
                guard !v.isNaN else { continue }
                let x = (CGFloat(i) + 0.5) * candleSpacing
                let yv = yPos(v, h: h)
                let rect = CGRect(x: x - barWidth / 2, y: min(yBase, yv), width: barWidth, height: max(0.5, abs(yBase - yv)))
                ctx.fill(Path(rect), with: .color(curve.color))
            }
        case .solid:
            strokeLine(ctx, values: curve.values, color: curve.color, h: h, style: .solid, lineWidth: curve.lineWidth, step: step)
        case .nodraw:
            break
        }
    }

    private func strokeLine(_ ctx: GraphicsContext, values: [Double], color: Color, h: CGFloat, style: TDXLineStyle, lineWidth: Double, step: Int = 1) {
        var path = Path(); var started = false
        for i in decimatedIndices(count: values.count, step: step) {
            let v = values[i]
            guard !v.isNaN else { continue }
            let x = (CGFloat(i) + 0.5) * candleSpacing
            let y = yPos(v, h: h)
            if started { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)); started = true }
        }
        let s: StrokeStyle = style == .dotline ? StrokeStyle(lineWidth: lineWidth, dash: [3, 3]) : StrokeStyle(lineWidth: lineWidth)
        ctx.stroke(path, with: .color(color), style: s)
    }

    private func yPos(_ v: Double, h: CGFloat) -> CGFloat {
        let range = priceMax - priceMin
        guard range > 0 else { return h }
        return h * CGFloat(1 - (v - priceMin) / range)
    }
}

/// 采样索引：当数据量超过屏幕能力时按 step 抽样并保留末点；step<=1 时返回全部。
func decimatedIndices(count: Int, step: Int) -> [Int] {
    guard count > 0 else { return [] }
    if step <= 1 { return Array(0..<count) }
    var res: [Int] = []
    res.reserveCapacity(count / step + 2)
    var i = 0
    while i < count {
        res.append(i)
        i += step
    }
    if let last = res.last, last != count - 1 {
        res.append(count - 1)
    }
    return res
}

/// 指标名称按钮：单击立即切换选择面板；参数编辑入口在面板内
private struct IndicatorNameButton: View {
    let title: String
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 10, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.gray.opacity(0.12)).cornerRadius(4)
        }
    }
}

// MARK: - 副图 Canvas（VOL/AMO/MACD/KDJ/RSI/自定义通用）

struct SubChartCanvas: View, Equatable {
    let slice: [KlineItem]
    let candleSpacing: CGFloat
    let height: CGFloat
    let curves: [CanvasCurve]
    let rangeMin: Double
    let rangeMax: Double
    let upColor, downColor, gridColor: Color

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            // 可见 K 数很大时按步长采样，绘制开销与屏幕列宽成正比
            let cols = max(Int(w / 2.0), 1)
            let step = max(1, (slice.count + cols - 1) / cols)
            for curve in curves {
                switch curve.style {
                case .stick:
                    drawBars(ctx, curve: curve, h: h, step: step)
                case .dotline, .pointdot, .solid:
                    drawLine(ctx, curve: curve, h: h, step: step)
                case .nodraw:
                    break
                }
            }
        }
    }

    private func drawBars(_ ctx: GraphicsContext, curve: CanvasCurve, h: CGFloat, step: Int) {
        let barWidth = max(0.6, candleSpacing * 0.55)
        let yZero = yPos(0, h: h)
        for i in decimatedIndices(count: curve.values.count, step: step) {
            let v = curve.values[i]
            guard !v.isNaN else { continue }
            let x = (CGFloat(i) + 0.5) * candleSpacing
            let yv = yPos(v, h: h)
            let rect = CGRect(x: x - barWidth / 2, y: min(yZero, yv), width: barWidth, height: max(0.5, abs(yZero - yv)))
            let color: Color
            switch curve.barColor {
            case .sign: color = v >= 0 ? upColor.opacity(0.85) : downColor.opacity(0.85)
            case .candle:
                if i < slice.count { color = slice[i].isUp ? upColor.opacity(0.85) : downColor.opacity(0.85) } else { color = curve.color }
            case .fixed: color = curve.color
            }
            ctx.fill(Path(rect), with: .color(color))
        }
    }

    private func drawLine(_ ctx: GraphicsContext, curve: CanvasCurve, h: CGFloat, step: Int) {
        if curve.style == .pointdot {
            let colors = curve.markerColors
            for idx in decimatedIndices(count: curve.values.count, step: step) {
                let v = curve.values[idx]
                guard !v.isNaN else { continue }
                let x = (CGFloat(idx) + 0.5) * candleSpacing
                let y = yPos(v, h: h)
                let c = colors?[idx] ?? curve.color
                var dot = Path()
                dot.addEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                ctx.fill(dot, with: .color(c))
            }
            return
        }
        var path = Path(); var started = false
        for i in decimatedIndices(count: curve.values.count, step: step) {
            let v = curve.values[i]
            guard !v.isNaN else { continue }
            let x = (CGFloat(i) + 0.5) * candleSpacing
            let y = yPos(v, h: h)
            if started { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)); started = true }
        }
        let s: StrokeStyle = curve.style == .dotline ? StrokeStyle(lineWidth: curve.lineWidth, dash: [3, 3]) : StrokeStyle(lineWidth: curve.lineWidth)
        ctx.stroke(path, with: .color(curve.color), style: s)
    }

    private func yPos(_ v: Double, h: CGFloat) -> CGFloat {
        let range = rangeMax - rangeMin
        guard range > 0 else { return h }
        return h * CGFloat(1 - (v - rangeMin) / range)
    }
}

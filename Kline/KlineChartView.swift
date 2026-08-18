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
    case vol = "VOL"
    case amo = "AMO"
    case macd = "MACD"
    case kdj = "KDJ"
    case rsi = "RSI"
    var id: String { rawValue }
    var group: String {
        switch self {
        case .vol, .amo: return "量能"
        case .macd: return "趋向"
        case .kdj, .rsi: return "摆动"
        }
    }
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

/// 公式编辑器针对的目标图表
enum EditorTarget {
    case main, sub
}

/// 副图槽位（第1/第2个副图）
enum SubSlot: Hashable {
    case top, bottom
}

/// 指标柱状曲线颜色规则
enum BarColorMode: Equatable {
    case fixed       // 使用曲线自身颜色
    case sign        // 按柱值正负着色（MACD）
    case candle      // 按对应K线涨跌着色（量柱）
}

// MARK: - 指标参数配置（可编辑）

struct MAConfig: Equatable {
    var periods: [Int] = [5, 10, 20, 60, 0, 0, 0, 0]
    mutating func sanitize() {
        if periods.count != 8 { periods = Array(repeating: 0, count: 8) }
        periods = periods.map { min(max($0, 0), 1000) }
    }
}

struct EMAConfig: Equatable {
    var periods: [Int] = [5, 10, 20, 60, 0, 0, 0, 0]
    mutating func sanitize() {
        if periods.count != 8 { periods = Array(repeating: 0, count: 8) }
        periods = periods.map { min(max($0, 0), 1000) }
    }
}

struct BOLLConfig: Equatable {
    var period: Int = 20
    var mult: Double = 2
}

struct MACDConfig: Equatable { var fast = 12; var slow = 26; var signal = 9 }
struct KDJConfig: Equatable { var n = 9; var kN = 3; var dN = 3 }
struct RSIConfig: Equatable { var p1 = 6; var p2 = 12; var p3 = 24 }
struct VolConfig: Equatable { var periods: [Int] = [5, 10] }

// MARK: - 通用指标线

struct IndicatorLine: Equatable {
    let name: String
    let values: [Double]
    let color: Color
    let style: TDXLineStyle
    let lineWidth: Double
    let hideValue: Bool
    var barColor: BarColorMode = .fixed
}

struct CanvasCurve: Equatable {
    var color: Color
    var values: [Double]
    var style: TDXLineStyle
    var lineWidth: Double
    var barColor: BarColorMode = .fixed
}

// MARK: - 副图模型

final class SubChartModel: ObservableObject {
    @Published var kind: SubChartKind = .vol
    @Published var volConfig = VolConfig()
    @Published var macdConfig = MACDConfig()
    @Published var kdjConfig = KDJConfig()
    @Published var rsiConfig = RSIConfig()
    @Published var activeCustomID: UUID? = nil
    @Published var titleName: String = "VOL"
    @Published var curves: [IndicatorLine] = []
    @Published var color: Color = Color(hex: "0050FF")!

    var isCustom: Bool { activeCustomID != nil }
}

/// 仅缓存排序后的 K 线数据；指标一律用静态方法按需(可见配置)计算，不再整表预计算未用指标。
struct ChartSeries {
    let sorted: [KlineItem]

    init(data: [KlineItem]) {
        self.sorted = Array(data.reversed())
    }

    static func ma(values: [Double], period: Int) -> [Double] {
        var result = Array(repeating: Double.nan, count: values.count)
        guard period > 0, values.count >= period else { return result }
        var sum = 0.0
        for i in 0..<values.count {
            sum += values[i]
            if i >= period { sum -= values[i - period] }
            if i >= period - 1 { result[i] = sum / Double(period) }
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

/// 行情 K 线图。
struct KlineChartView: View {
    private let series: ChartSeries
    @Binding var chartStyle: ChartStyle

    // 交互状态
    @State private var selectedIndex: Int? = nil
    @State private var showMainSheet = false
    @State private var showSubSheet = false
    @State private var editingSlot: SubSlot = .top
    @State private var visibleCount: CGFloat = 100
    @State private var endOffset: Int = 0
    @State private var zoomBase: CGFloat = 100
    @State private var lastPanWidth: CGFloat = 0
    @State private var lastPanHeight: CGFloat = 0
    @State private var dragMode: DragMode = .none
    @State private var cursorDragging: Bool = false
    @State private var hasInteracted: Bool = false
    @State private var crosshairY: CGFloat? = nil
    @ObservedObject private var customStore = CustomIndicatorStore.shared

    // 主图叠加指标
    @State private var showMA = true
    @State private var showEMA = false
    @State private var showBOLL = false
    @State private var showBareK = false
    @State private var maConfig = MAConfig()
    @State private var emaConfig = EMAConfig()
    @State private var bollConfig = BOLLConfig()
    @State private var activeCustomIndicator: CustomIndicator? = nil
    @State private var customOutputs: [TDXOutputLine] = []
    @State private var mainCurves: [IndicatorLine] = []

    // 两个副图
    @StateObject private var subTop = SubChartModel()
    @StateObject private var subBottom = SubChartModel()

    @State private var showCustomEditor = false
    @State private var editorTarget: EditorTarget = .main
    @State private var isDragging = false
    @State private var needsRefreshAfterDrag = false

    // 基础序列一次性缓存（供指标按需计算复用，避免拖拽/重算时反复整表 map）
    private let sortedAll: [KlineItem]
    private let baseCloses, baseHighs, baseLows, baseVolumes, baseTurnovers: [Double]

    init(series: ChartSeries, chartStyle: Binding<ChartStyle>) {
        self.series = series
        self._chartStyle = chartStyle
        let all = series.sorted
        self.sortedAll = all
        self.baseCloses = all.map(\.close)
        self.baseHighs = all.map(\.high)
        self.baseLows = all.map(\.low)
        self.baseVolumes = all.map(\.volume)
        self.baseTurnovers = all.map(\.turnover)
        // 初始副图：1 上为 VOL，2 下为 MACD（onAppear 中设定）
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

    private func recomputeMainCurves() {
        // 拖拽期间禁止任何指标重算（重算随总 K 数线性增长，是拖拽卡顿根源）
        if isDragging { needsRefreshAfterDrag = true; return }
        var curves: [IndicatorLine] = []
        if !showBareK {
            if showMA {
                for (i, p) in maConfig.periods.enumerated() where p > 0 {
                    curves.append(IndicatorLine(name: "MA\(p)", values: ChartSeries.ma(values: closes, period: p),
                                                color: maColor(i), style: .solid, lineWidth: 1, hideValue: false))
                }
            }
            if showEMA {
                for (i, p) in emaConfig.periods.enumerated() where p > 0 {
                    curves.append(IndicatorLine(name: "EMA\(p)", values: ChartSeries.ema(values: closes, period: p),
                                                color: maColor(i), style: .solid, lineWidth: 1, hideValue: false))
                }
            }
            if showBOLL {
                let b = ChartSeries.boll(values: closes, period: bollConfig.period, mult: bollConfig.mult)
                curves.append(IndicatorLine(name: "MID", values: b.mid, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "UP", values: b.up, color: bollColor, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "LOW", values: b.lo, color: bollColor, style: .solid, lineWidth: 1, hideValue: false))
            }
            for (i, line) in customOutputs.enumerated() {
                curves.append(IndicatorLine(name: displayName(line.name), values: line.values,
                                            color: customLineColor(i, line: line, indicatorColor: activeCustomIndicator?.color),
                                            style: line.style, lineWidth: line.lineWidth, hideValue: line.hideValue))
            }
        }
        mainCurves = curves
    }

    private func recomputeSub(_ m: SubChartModel) {
        // 拖拽期间禁止任何指标重算（重算随总 K 数线性增长，是拖拽卡顿根源）
        if isDragging { needsRefreshAfterDrag = true; return }
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
                for (i, p) in m.volConfig.periods.enumerated() where p > 0 {
                    curves.append(IndicatorLine(name: "MA\(p)", values: ChartSeries.ma(values: base, period: p),
                                                color: maColor(i), style: .solid, lineWidth: 1, hideValue: false))
                }
            case .macd:
                let mres = ChartSeries.macd(values: closes, fast: m.macdConfig.fast, slow: m.macdConfig.slow, signal: m.macdConfig.signal)
                curves.append(IndicatorLine(name: "DIF", values: mres.dif, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "DEA", values: mres.dea, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "MACD", values: mres.hist, color: ma20Color, style: .stick, lineWidth: 1, hideValue: false, barColor: .sign))
            case .kdj:
                let k = ChartSeries.kdj(highs: highs, lows: lows, closes: closes,
                                        n: m.kdjConfig.n, kN: m.kdjConfig.kN, dN: m.kdjConfig.dN)
                curves.append(IndicatorLine(name: "K", values: k.k, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "D", values: k.d, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "J", values: k.j, color: ma20Color, style: .solid, lineWidth: 1, hideValue: false))
            case .rsi:
                let r1 = ChartSeries.rsi(values: closes, period: m.rsiConfig.p1)
                let r2 = ChartSeries.rsi(values: closes, period: m.rsiConfig.p2)
                let r3 = ChartSeries.rsi(values: closes, period: m.rsiConfig.p3)
                curves.append(IndicatorLine(name: "RSI\(m.rsiConfig.p1)", values: r1, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "RSI\(m.rsiConfig.p2)", values: r2, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "RSI\(m.rsiConfig.p3)", values: r3, color: ma20Color, style: .solid, lineWidth: 1, hideValue: false))
            }
        }
        m.curves = curves
        m.titleName = (m.isCustom ? custom?.name : nil) ?? m.kind.rawValue
        m.color = custom?.color ?? Color(hex: "0050FF")!
    }

    // MARK: - 主图价格区间

    private var priceRange: ClosedRange<Double> {
        guard !slice.isEmpty else { return 0...100 }
        var minLow = slice.map(\.low).min() ?? 0
        var maxHigh = slice.map(\.high).max() ?? 100
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
        case .macd:
            let mx = values.map { abs($0) }.max() ?? 1
            let mm = max(mx * 1.15, 0.0001)
            return (-mm, mm)
        case .rsi:
            return (0, 100)
        case .kdj:
            let lo = min(values.min() ?? 0, 0)
            let hi = max(values.max() ?? 100, 100)
            return (lo, hi)
        }
    }

    // MARK: - 手势

    private var menuIsOpen: Bool { showMainSheet || showSubSheet || showCustomEditor }

    private func isInPanel(_ y: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> Bool { y >= top && y <= bottom }

    private func clamp<V: Comparable>(_ v: V, _ lo: V, _ hi: V) -> V { min(max(v, lo), hi) }

    private func chartDragGesture(candleSpacing: CGFloat,
                                  mainTop: CGFloat, mainBottom: CGFloat,
                                  s1Top: CGFloat, s1Bottom: CGFloat,
                                  s2Top: CGFloat, s2Bottom: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !menuIsOpen else { return }
                hasInteracted = true
                isDragging = true
                let y = value.location.y
                let inMain = isInPanel(y, mainTop, mainBottom)
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
                    if abs(value.translation.width) > 6 || abs(value.translation.height) > 6 { cursorDragging = true }
                } else if inMain && dragMode == .none {
                    if abs(value.translation.height) > abs(value.translation.width) && abs(value.translation.height) > 4 {
                        dragMode = .zoom
                    } else if abs(value.translation.width) > 4 {
                        dragMode = .pan
                    }
                    lastPanWidth = 0; lastPanHeight = 0
                }

                if dragMode == .zoom {
                    let deltaY = value.translation.height - lastPanHeight
                    lastPanHeight = value.translation.height
                    visibleCount = clamp(visibleCount + deltaY * 0.5, 20, CGFloat(maxVisibleCount))
                } else if dragMode == .pan {
                    let delta = value.translation.width - lastPanWidth
                    lastPanWidth = value.translation.width
                    let cols = Int((delta / candleSpacing).rounded())
                    if cols != 0 { endOffset = clamp(endOffset + cols, 0, max(0, sortedData.count - count)) }
                }
            }
            .onEnded { value in
                lastPanWidth = 0; lastPanHeight = 0; dragMode = .none
                guard !menuIsOpen else { cursorDragging = false; return }
                if cursorDragging { cursorDragging = false; return }
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

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                hasInteracted = true
                selectedIndex = nil; crosshairY = nil
                visibleCount = clamp(zoomBase / value, 20, CGFloat(maxVisibleCount))
            }
            .onEnded { _ in zoomBase = visibleCount }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let candleSpacing = width / CGFloat(max(1, count))
            let legendHeight: CGFloat = 12
            // 时间轴取剩余高度，紧贴最下方副图，不留缝隙
            let chartHeight = max(1, geometry.size.height - 3 * legendHeight)
            let mainHeight = chartHeight * 0.52
            let sub1Height = chartHeight * 0.13
            let sub2Height = chartHeight * 0.16
            let timeHeight = max(0, chartHeight - mainHeight - sub1Height - sub2Height)

            let mainTop = legendHeight
            let mainBottom = mainTop + mainHeight
            let s1Top = mainBottom + legendHeight
            let s1Bottom = s1Top + sub1Height
            let s2Top = s1Bottom + legendHeight
            let s2Bottom = s2Top + sub2Height

            VStack(spacing: 0) {
                mainLegendRow(height: legendHeight).zIndex(30)
                mainChart(width: width, candleSpacing: candleSpacing, height: mainHeight, panelTop: mainTop)
                subLegendRow(model: subTop, height: legendHeight).zIndex(30)
                subChart(model: subTop, width: width, candleSpacing: candleSpacing, height: sub1Height,
                         panelTop: s1Top, slot: .top)
                subLegendRow(model: subBottom, height: legendHeight).zIndex(30)
                subChart(model: subBottom, width: width, candleSpacing: candleSpacing, height: sub2Height,
                         panelTop: s2Top, slot: .bottom)
                timeAxis(width: width, candleSpacing: candleSpacing, height: timeHeight)
            }
            .contentShape(Rectangle())
            .gesture(chartDragGesture(candleSpacing: candleSpacing, mainTop: mainTop, mainBottom: mainBottom,
                                      s1Top: s1Top, s1Bottom: s1Bottom, s2Top: s2Top, s2Bottom: s2Bottom))
            .simultaneousGesture(magnificationGesture)
            .overlay(alignment: .top) {
                if !hasInteracted {
                    Text("主图拖动平移/上下缩放 · 双指缩放 · 轻点切换光标")
                        .font(.system(size: 10)).foregroundColor(.gray)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.white.opacity(0.85)).cornerRadius(4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
                        .padding(.top, 5).transition(.opacity)
                }
            }
            .overlay {
                if let crosshairY, isInPanel(crosshairY, mainTop, mainBottom) || isInPanel(crosshairY, s1Top, s1Bottom) || isInPanel(crosshairY, s2Top, s2Bottom) {
                    let y = min(max(crosshairY, 0), geometry.size.height)
                    Rectangle().fill(Color.black.opacity(0.35)).frame(width: width, height: 0.5)
                        .position(x: width / 2, y: y)
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
        }
        .background(Color.white)
        .onAppear {
            subBottom.kind = .macd
            subBottom.titleName = "MACD"
            refreshCurves()
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
        activeCustomIndicator = ind
        if let ind, let lines = try? TDXFormulaEngine.evaluate(formula: ind.formula, data: sortedData) {
            customOutputs = lines
        } else { customOutputs = [] }
        recomputeMainCurves()
    }

    private func activateSubCustom(_ m: SubChartModel, _ ind: CustomIndicator?) {
        m.activeCustomID = ind?.id
        recomputeSub(m)
    }

    private func syncCustomAfterStoreChange() {
        if let active = activeCustomIndicator,
           let updated = customStore.indicators.first(where: { $0.id == active.id }) {
            activateCustom(updated)
        } else if activeCustomIndicator != nil {
            activeCustomIndicator = nil; customOutputs = []; recomputeMainCurves()
        }
        for m in [subTop, subBottom] {
            if m.activeCustomID != nil,
               !customStore.indicators.contains(where: { $0.id == m.activeCustomID }) {
                m.activeCustomID = nil
            }
        }
    }

    // MARK: - 主图

    private func mainChart(width: CGFloat, candleSpacing: CGFloat, height: CGFloat, panelTop: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.white
            mainCanvas(width: width, candleSpacing: candleSpacing, height: height)
            overlayPriceLabels(width: width, height: height, min: priceRange.lowerBound, max: priceRange.upperBound,
                               ratios: [0, 0.25, 0.5, 0.75, 1], formatter: { String(format: "%.2f", $0) })
            if let latest = slice.last {
                Text(String(format: "%.2f", latest.close))
                    .font(.system(size: 9)).foregroundColor(latest.isUp ? upColor : downColor)
                    .padding(.horizontal, 3)
                    .position(x: 20, y: yPosition(for: latest.close, in: height))
            }
            if let selectedIndex, selectedIndex >= startIndex, selectedIndex <= endIndex {
                let item = sortedData[selectedIndex]
                let xPosition = (CGFloat(selectedIndex - startIndex) + 0.5) * candleSpacing
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: 0.5, height: height).position(x: xPosition, y: height / 2)
                if let crosshairY, crosshairY >= panelTop, crosshairY <= panelTop + height {
                    let clampedY = min(max(crosshairY - panelTop, 0), height)
                    let priceAtY = priceRange.upperBound - (priceRange.upperBound - priceRange.lowerBound) * Double(clampedY / height)
                    Text(String(format: "%.2f", priceAtY))
                        .font(.system(size: 9)).foregroundColor(.black)
                        .padding(.horizontal, 3)
                        .position(x: 20, y: clampedY)
                }
                infoPanel(index: selectedIndex, item: item).padding(.leading, 6).padding(.top, 2)
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private func mainCanvas(width: CGFloat, candleSpacing: CGFloat, height: CGFloat) -> some View {
        MainChartCanvas(slice: slice, chartStyle: chartStyle, candleSpacing: candleSpacing, height: height,
                        priceMin: priceRange.lowerBound, priceMax: priceRange.upperBound,
                        curves: mainCurves.map { CanvasCurve(color: $0.color, values: sliceArr($0.values), style: $0.style, lineWidth: $0.lineWidth, barColor: $0.barColor) },
                        upColor: upColor, downColor: downColor, gridColor: gridColor)
            .equatable()
    }

    // MARK: - 副图

    private func subChart(model m: SubChartModel, width: CGFloat, candleSpacing: CGFloat,
                          height: CGFloat, panelTop: CGFloat, slot: SubSlot) -> some View {
        let range = subRange(m)
        let subFmt: (Double) -> String
        switch m.kind {
        case .macd: subFmt = { String(format: "%.3f", $0) }
        case .vol, .amo: subFmt = { formatVolume($0) }
        case .kdj, .rsi: subFmt = { String(format: "%.0f", $0) }
        }
        return ZStack(alignment: .topLeading) {
            Color.white
            SubChartCanvas(slice: slice, candleSpacing: candleSpacing, height: height,
                           curves: m.curves.map { CanvasCurve(color: $0.color, values: sliceArr($0.values), style: $0.style, lineWidth: $0.lineWidth, barColor: $0.barColor) },
                           rangeMin: range.min, rangeMax: range.max,
                           upColor: upColor, downColor: downColor, gridColor: gridColor)
                .equatable()
            // 顶底两个坐标值，透明背景
            overlayPriceLabels(width: width, height: height, min: range.min, max: range.max,
                               ratios: [0, 1], formatter: subFmt)

            if let selectedIndex, selectedIndex >= startIndex, selectedIndex <= endIndex {
                let xPosition = (CGFloat(selectedIndex - startIndex) + 0.5) * candleSpacing
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: 0.5, height: height).position(x: xPosition, y: height / 2)
                if let crosshairY, crosshairY >= panelTop, crosshairY <= panelTop + height {
                    let localY = min(max(crosshairY - panelTop, 0), height)
                    let value = range.max - (range.max - range.min) * Double(localY / height)
                    let fmt = m.kind == .macd ? "%.3f" : "%.2f"
                    Text(String(format: fmt, value))
                        .font(.system(size: 9)).foregroundColor(.black)
                        .padding(.horizontal, 3)
                        .position(x: 20, y: localY)
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private func subLegendRow(model m: SubChartModel, height: CGFloat) -> some View {
        ZStack {
            HStack(spacing: 8) {
                nameButtonView(title: m.titleName, isOpen: $showSubSheet) {
                    editingSlot = (m === subTop) ? .top : .bottom
                    showMainSheet = false
                }
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
                nameButtonView(title: mainLegendTitle, isOpen: $showMainSheet) {
                    showSubSheet = false
                }
                if showBareK { legendText("裸K") }
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
        if showBareK { return "裸K" }
        var parts: [String] = []
        if showMA { parts.append("MA") }
        if showEMA { parts.append("EMA") }
        if showBOLL { parts.append("BOLL") }
        if let a = activeCustomIndicator { parts.append(a.name) }
        return parts.isEmpty ? "主图" : parts.joined(separator: "/")
    }

    private func nameButtonView(title: String, isOpen: Binding<Bool>, onTap: @escaping () -> Void) -> some View {
        Button {
            withAnimation { isOpen.wrappedValue.toggle(); onTap() }
        } label: {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 9, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.gray.opacity(0.12)).cornerRadius(4)
        }
    }

    private func legendItem(_ line: IndicatorLine, format: String = "%.2f") -> some View {
        HStack(spacing: 2) {
            if line.style == .stick {
                Rectangle().fill(line.color).frame(width: 3, height: 5)
            } else {
                Circle().fill(line.color).frame(width: 5, height: 5)
            }
            Text(line.name).font(.system(size: 9)).foregroundColor(.gray)
            if !line.hideValue, let value = legendValueFor(line), !value.isNaN {
                Text(String(format: format, value)).font(.system(size: 9)).foregroundColor(line.color)
            }
        }
    }

    private func legendText(_ text: String) -> some View {
        HStack(spacing: 2) {
            Circle().fill(Color.gray).frame(width: 5, height: 5)
            Text(text).font(.system(size: 9)).foregroundColor(.gray)
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
        let left = sortedData[startIndex].formattedDate
        let right = sortedData[endIndex].formattedDate
        return ZStack {
            HStack(spacing: 0) {
                Text(left).font(.system(size: 9)).foregroundColor(.gray)
                Text("   周期数\(count)个").font(.system(size: 9)).foregroundColor(.gray)
                Spacer()
            }
            Text(right).font(.system(size: 9)).foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: width, height: height)
        .background(Color.white)
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
                        mainTile("裸K", on: showBareK) { toggleMain(.bare) }
                        mainTile("MA", on: showMA) { toggleMain(.ma) }
                        mainTile("EMA", on: showEMA) { toggleMain(.ema) }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 6)
                    if showMA { paramRow(title: "MA 周期（0=隐藏）") { maPeriodsEditor } }
                    if showEMA { paramRow(title: "EMA 周期（0=隐藏）") { emaPeriodsEditor } }

                    groupHeader("路径型")
                    LazyVGrid(columns: gridColumns, spacing: 8) {
                        mainTile("BOLL", on: showBOLL) { toggleMain(.boll) }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 6)
                    if showBOLL {
                        paramRow(title: "BOLL 参数") {
                            HStack(spacing: 12) {
                                numberField("周期", $bollConfig.period, range: 1...1000) { recomputeMainCurves() }
                                numberField("倍数", $bollConfig.mult, range: 0.1...10) { recomputeMainCurves() }
                            }
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
    private var maPeriodsEditor: some View { periodsEditor($maConfig.periods) { recomputeMainCurves() } }
    private var emaPeriodsEditor: some View { periodsEditor($emaConfig.periods) { recomputeMainCurves() } }

    private enum MainRowKey { case bare, ma, ema, boll }
    private var mainCustoms: [CustomIndicator] { customStore.indicators.filter { $0.scope == .main } }

    private func toggleMain(_ group: MainRowKey) {
        switch group {
        case .bare: showBareK.toggle()
        case .ma: showMA.toggle()
        case .ema: showEMA.toggle()
        case .boll: showBOLL.toggle()
        }
        recomputeMainCurves()
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
                    ForEach(["量能", "趋向", "摆动"], id: \.self) { g in
                        let kinds = SubChartKind.allCases.filter { $0.group == g }
                        if !kinds.isEmpty {
                            groupHeader(g)
                            LazyVGrid(columns: gridColumns, spacing: 8) {
                                ForEach(kinds) { k in
                                    subTile(k.rawValue, selected: !m.isCustom && m.kind == k) {
                                        m.activeCustomID = nil
                                        m.kind = k
                                        recomputeSub(m)
                                    }
                                }
                            }
                            .padding(.horizontal, 16).padding(.bottom, 6)
                        }
                    }
                    // 选中指标参数
                    if let cur = currentSubKind(m) {
                        subParamEditor(k: cur, model: m)
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

    private func currentSubKind(_ m: SubChartModel) -> SubChartKind? {
        m.isCustom ? nil : m.kind
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

    @ViewBuilder
    private func subParamEditor(k: SubChartKind, model m: SubChartModel) -> some View {
        switch k {
        case .vol, .amo:
            paramRow(title: "量均线周期（0=隐藏）") {
                periodsEditor(Binding(get: { m.volConfig.periods },
                                       set: { v in m.volConfig.periods = v; recomputeSub(m) })) { }
            }
        case .macd:
            paramRow(title: "MACD 参数") {
                HStack(spacing: 12) {
                    numberField("快", Binding(get: { m.macdConfig.fast }, set: { m.macdConfig.fast = $0; recomputeSub(m) }), range: 1...300)
                    numberField("慢", Binding(get: { m.macdConfig.slow }, set: { m.macdConfig.slow = $0; recomputeSub(m) }), range: 1...300)
                    numberField("信号", Binding(get: { m.macdConfig.signal }, set: { m.macdConfig.signal = $0; recomputeSub(m) }), range: 1...300)
                }
            }
        case .kdj:
            paramRow(title: "KDJ 参数") {
                HStack(spacing: 12) {
                    numberField("N", Binding(get: { m.kdjConfig.n }, set: { m.kdjConfig.n = $0; recomputeSub(m) }), range: 1...300)
                    numberField("K", Binding(get: { m.kdjConfig.kN }, set: { m.kdjConfig.kN = $0; recomputeSub(m) }), range: 1...100)
                    numberField("D", Binding(get: { m.kdjConfig.dN }, set: { m.kdjConfig.dN = $0; recomputeSub(m) }), range: 1...100)
                }
            }
        case .rsi:
            paramRow(title: "RSI 参数") {
                HStack(spacing: 12) {
                    numberField("P1", Binding(get: { m.rsiConfig.p1 }, set: { m.rsiConfig.p1 = $0; recomputeSub(m) }), range: 1...300)
                    numberField("P2", Binding(get: { m.rsiConfig.p2 }, set: { m.rsiConfig.p2 = $0; recomputeSub(m) }), range: 1...300)
                    numberField("P3", Binding(get: { m.rsiConfig.p3 }, set: { m.rsiConfig.p3 = $0; recomputeSub(m) }), range: 1...300)
                }
            }
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

    // MARK: - 十字光标信息面板

    private func infoPanel(index: Int, item: KlineItem) -> some View {
        let changeAmount = prevClose(of: index) > 0 ? item.close - prevClose(of: index) : 0
        let changeColor: Color = changeAmount >= 0 ? upColor : downColor
        return VStack(alignment: .leading, spacing: 2) {
            Text(item.formattedDateWithWeekday).font(.system(size: 10, weight: .medium)).foregroundColor(.black)
            HStack(spacing: 8) {
                kv("开", item.open, .black)
                kv("收", item.close, item.isUp ? upColor : downColor)
                kv("高", item.high, upColor)
                kv("低", item.low, downColor)
            }
            HStack(spacing: 8) {
                kv("涨", changeAmount, changeColor)
                textPill("额", item.formattedTurnover)
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.92)).cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
    }

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
    private func textPill(_ title: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundColor(.gray)
            Text(value).font(.system(size: 9)).foregroundColor(.black)
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
            switch chartStyle {
            case .bare, .solid:
                drawCandles(ctx, h: h, candleWidth: candleWidth, hollow: chartStyle == .bare, cols: cols)
            case .close:
                strokeLine(ctx, values: slice.map(\.close), color: Color(red: 0.2, green: 0.4, blue: 0.9), h: h, style: .solid, lineWidth: 1, step: lineStep)
            case .ohlc:
                drawOHLC(ctx, h: h, candleWidth: candleWidth, step: lineStep)
            }

            for curve in curves { drawCurve(ctx, curve: curve, h: h, step: lineStep) }

            if let latest = slice.last {
                let y = yPos(latest.close, h: h)
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                ctx.stroke(p, with: .color(latest.isUp ? upColor.opacity(0.6) : downColor.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            }
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
            var points = Path()
            for i in decimatedIndices(count: curve.values.count, step: step) {
                let v = curve.values[i]
                guard !v.isNaN else { continue }
                let x = (CGFloat(i) + 0.5) * candleSpacing
                let y = yPos(v, h: h)
                points.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
            }
            ctx.fill(points, with: .color(curve.color))
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
            var points = Path()
            for i in decimatedIndices(count: curve.values.count, step: step) {
                let v = curve.values[i]
                guard !v.isNaN else { continue }
                let x = (CGFloat(i) + 0.5) * candleSpacing
                points.addEllipse(in: CGRect(x: x - 1, y: yPos(v, h: h) - 1, width: 2, height: 2))
            }
            ctx.fill(points, with: .color(curve.color))
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
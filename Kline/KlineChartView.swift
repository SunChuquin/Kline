//
//  KlineChartView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/8/5.
//

import SwiftUI

/// 副图（指标幅图）可选系统指标
enum SubIndicator: String, CaseIterable, Identifiable {
    case macd = "MACD"
    case kdj = "KDJ"
    case rsi = "RSI"
    var id: String { rawValue }
}

/// 主图显示类型
enum ChartStyle: String, CaseIterable, Identifiable {
    case bare  = "空心K线"   // 红K空心，绿K实心
    case solid = "实心K线"   // 红绿均实心
    case close = "收盘线"
    case ohlc  = "美国线"
    var id: String { rawValue }
}

/// 成交量幅图可选类型
enum VolumeIndicator: String, CaseIterable, Identifiable {
    case volume = "VOL"
    case amount = "AMO"
    var id: String { rawValue }
}

/// 无光标时的拖动模式：水平=平移，垂直=缩放
enum DragMode {
    case none, pan, zoom
}

/// 公式编辑器针对的目标图表（主图/副图）
enum EditorTarget {
    case main, sub
}

// MARK: - 指标参数配置（可编辑）

/// MA 参数：最多 8 个周期，0 = 不显示对应均线
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

/// MACD / KDJ / RSI 参数
struct MACDConfig: Equatable { var fast = 12; var slow = 26; var signal = 9 }
struct KDJConfig: Equatable { var n = 9; var kN = 3; var dN = 3 }
struct RSIConfig: Equatable { var p1 = 6; var p2 = 12; var p3 = 24 }

// MARK: - 通用指标线

/// 一条可绘制的指标线/柱（主图、副图、公式输出线通用）
struct IndicatorLine: Equatable {
    let name: String
    let values: [Double]
    let color: Color
    let style: TDXLineStyle
    let lineWidth: Double
    let hideValue: Bool
}

/// Canvas 内的曲线描述（Equatable，用于 Equatable Canvas 结构体）
struct CanvasCurve: Equatable {
    var color: Color
    var values: [Double]
    var style: TDXLineStyle
    var lineWidth: Double
}

/// 缓存 K 线指标计算的结果，避免每次渲染重复计算。
struct ChartSeries {
    let sorted: [KlineItem]
    let ma5, ma10, ma20, ma60: [Double]
    let ema5, ema10, ema20, ema60: [Double]
    let bollMid, bollUpper, bollLower: [Double]
    let volMa5, volMa10: [Double]
    let amoMa5, amoMa10: [Double]
    let rsi6, rsi12, rsi24: [Double]

    init(data: [KlineItem]) {
        let sorted = Array(data.reversed())
        self.sorted = sorted

        func ma(_ period: Int, _ keyPath: KeyPath<KlineItem, Double>) -> [Double] {
            var result: [Double] = []
            for i in 0..<sorted.count {
                if i < period - 1 {
                    result.append(.nan)
                } else {
                    var sum = 0.0
                    for j in (i - period + 1)...i { sum += sorted[j][keyPath: keyPath] }
                    result.append(sum / Double(period))
                }
            }
            return result
        }
        self.ma5 = ma(5, \.close)
        self.ma10 = ma(10, \.close)
        self.ma20 = ma(20, \.close)
        self.ma60 = ma(60, \.close)
        self.volMa5 = ma(5, \.volume)
        self.volMa10 = ma(10, \.volume)
        self.amoMa5 = ma(5, \.turnover)
        self.amoMa10 = ma(10, \.turnover)

        self.ema5 = Self.ema(values: sorted.map(\.close), period: 5)
        self.ema10 = Self.ema(values: sorted.map(\.close), period: 10)
        self.ema20 = Self.ema(values: sorted.map(\.close), period: 20)
        self.ema60 = Self.ema(values: sorted.map(\.close), period: 60)

        self.bollMid = Self.ma(values: sorted.map(\.close), period: 20)
        let sd = Self.rollingStd(sorted.map(\.close), period: 20)
        self.bollUpper = zip(self.bollMid, sd).map { $0 + 2 * $1 }
        self.bollLower = zip(self.bollMid, sd).map { $0 - 2 * $1 }

        self.rsi6 = Self.rsi(values: sorted.map(\.close), period: 6)
        self.rsi12 = Self.rsi(values: sorted.map(\.close), period: 12)
        self.rsi24 = Self.rsi(values: sorted.map(\.close), period: 24)
    }

    // MARK: 供参数化计算复用的静态方法（输入为 最新一根在末尾 的数组）

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
        let fastE = ema(values: values, period: fast)
        let slowE = ema(values: values, period: slow)
        let dif = zip(fastE, slowE).map { $0 - $1 }
        let dea = ema(values: dif, period: signal)
        let hist = zip(dif, dea).map { 2 * ($0 - $1) }
        return (dif, dea, hist)
    }

    static func kdj(highs: [Double], lows: [Double], closes: [Double], n: Int, kN: Int, dN: Int) -> (k: [Double], d: [Double], j: [Double]) {
        var kArr: [Double] = []
        var dArr: [Double] = []
        var jArr: [Double] = []
        var prevK = 50.0
        var prevD = 50.0
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
        var avgGain = 0.0
        var avgLoss = 0.0
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

/// 行情 K 线图，参考同花顺/通达信的日间（浅色）风格布局。
struct KlineChartView: View {
    let data: [KlineItem]
    @Binding var chartStyle: ChartStyle
    private let series: ChartSeries

    // 交互状态
    @State private var selectedIndex: Int? = nil
    @State private var indicator: SubIndicator = .macd
    @State private var volumeIndicator: VolumeIndicator = .volume
    @State private var showMainSheet = false
    @State private var showVolumeMenu = false
    @State private var showIndicatorSheet = false
    @State private var visibleCount: CGFloat = 100
    @State private var endOffset: Int = 0          // 0 = 最新一根贴右边缘
    @State private var zoomBase: CGFloat = 100
    @State private var lastPanWidth: CGFloat = 0
    @State private var lastPanHeight: CGFloat = 0
    @State private var dragMode: DragMode = .none
    @State private var cursorDragging: Bool = false
    @State private var hasInteracted: Bool = false
    @State private var crosshairY: CGFloat? = nil
    @ObservedObject private var customStore = CustomIndicatorStore.shared

    // 主图叠加指标（可同时叠加多个）
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

    // 副图指标参数与自定义
    @State private var macdConfig = MACDConfig()
    @State private var kdjConfig = KDJConfig()
    @State private var rsiConfig = RSIConfig()
    @State private var activeSubCustom: CustomIndicator? = nil
    @State private var subCustomOutputs: [TDXOutputLine] = []
    @State private var subCurves: [IndicatorLine] = []

    @State private var showCustomEditor = false
    @State private var editorTarget: EditorTarget = .main

    init(data: [KlineItem], chartStyle: Binding<ChartStyle>) {
        self.data = data
        self._chartStyle = chartStyle
        self.series = ChartSeries(data: data)
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

    /// MA/EMA 各周期线条颜色
    private func maColor(_ i: Int) -> Color {
        let colors = [Color.black.opacity(0.75), Color.orange, Color.pink, Color.blue,
                      Color(red: 0.9, green: 0.6, blue: 0), Color.teal, Color.purple, Color.brown]
        return colors[i % colors.count]
    }

    // MARK: - 数据（从缓存读取）

    private var sortedData: [KlineItem] { series.sorted }
    private var volMa5: [Double] { series.volMa5 }
    private var volMa10: [Double] { series.volMa10 }
    private var amoMa5: [Double] { series.amoMa5 }
    private var amoMa10: [Double] { series.amoMa10 }

    // MARK: - 可见窗口

    private var count: Int { min(max(20, Int(visibleCount.rounded())), sortedData.count) }

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

    /// 指标栏取值：有光标时显示光标对应的值，否则显示最新值
    private func legendValue(_ arr: [Double]) -> Double? {
        if let idx = selectedIndex, idx >= 0, idx < arr.count, !arr[idx].isNaN {
            return arr[idx]
        }
        return arr.last(where: { !$0.isNaN })
    }

    private func legendValueFor(_ line: IndicatorLine) -> Double? {
        legendValue(line.values)
    }

    // MARK: - 指标序列计算（系统指标 + 自定义）

    private var closes: [Double] { sortedData.map(\.close) }

    /// 自定义指标默认配色（优先公式 COLORX，其次指标默认色，再轮换调色板）
    private func customLineColor(_ index: Int, line: TDXOutputLine, indicatorColor: Color?) -> Color {
        if let hex = line.colorHex, let c = Color(hex: hex) { return c }
        if let indicatorColor { return indicatorColor }
        let palette = [Color.blue, Color(red: 0.9, green: 0.35, blue: 0.1), Color(red: 0.2, green: 0.55, blue: 0.85),
                       Color(red: 0.6, green: 0.25, blue: 0.7), Color.teal, Color.pink]
        return palette[index % palette.count]
    }

    /// 重新计算主图叠加线与自定义输出
    private func recomputeMainCurves() {
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
        }
        if !showBareK {
            for (i, line) in customOutputs.enumerated() {
                curves.append(IndicatorLine(name: displayName(line.name), values: line.values, color: customLineColor(i, line: line, indicatorColor: activeCustomIndicator?.color),
                                            style: line.style, lineWidth: line.lineWidth, hideValue: line.hideValue))
            }
        }
        mainCurves = curves
    }

    /// 重新计算副图曲线（系统指标或自定义）
    private func recomputeSubCurves() {
        if let active = activeSubCustom,
           let lines = try? TDXFormulaEngine.evaluate(formula: active.formula, data: sortedData) {
            subCustomOutputs = lines
        } else if activeSubCustom == nil {
            subCustomOutputs = []
        }

        var curves: [IndicatorLine] = []
        if activeSubCustom != nil, !subCustomOutputs.isEmpty {
            for (i, line) in subCustomOutputs.enumerated() {
                curves.append(IndicatorLine(name: displayName(line.name), values: line.values, color: customLineColor(i, line: line, indicatorColor: activeSubCustom?.color),
                                            style: line.style, lineWidth: line.lineWidth, hideValue: line.hideValue))
            }
        } else {
            switch indicator {
            case .macd:
                let m = ChartSeries.macd(values: closes, fast: macdConfig.fast, slow: macdConfig.slow, signal: macdConfig.signal)
                curves.append(IndicatorLine(name: "DIF", values: m.dif, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "DEA", values: m.dea, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "MACD", values: m.hist, color: ma20Color, style: .stick, lineWidth: 1, hideValue: false))
            case .kdj:
                let k = ChartSeries.kdj(highs: sortedData.map(\.high), lows: sortedData.map(\.low), closes: closes,
                                        n: kdjConfig.n, kN: kdjConfig.kN, dN: kdjConfig.dN)
                curves.append(IndicatorLine(name: "K", values: k.k, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "D", values: k.d, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "J", values: k.j, color: ma20Color, style: .solid, lineWidth: 1, hideValue: false))
            case .rsi:
                let r1 = ChartSeries.rsi(values: closes, period: rsiConfig.p1)
                let r2 = ChartSeries.rsi(values: closes, period: rsiConfig.p2)
                let r3 = ChartSeries.rsi(values: closes, period: rsiConfig.p3)
                curves.append(IndicatorLine(name: "RSI\(rsiConfig.p1)", values: r1, color: ma5Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "RSI\(rsiConfig.p2)", values: r2, color: ma10Color, style: .solid, lineWidth: 1, hideValue: false))
                curves.append(IndicatorLine(name: "RSI\(rsiConfig.p3)", values: r3, color: ma20Color, style: .solid, lineWidth: 1, hideValue: false))
            }
        }
        subCurves = curves
    }

    private func displayName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "NOTEXT_", with: "")
    }

    // MARK: - 主图价格区间（基于可见窗口，含所有叠加线）

    private var priceRange: ClosedRange<Double> {
        guard !slice.isEmpty else { return 0...100 }
        var minLow = slice.map(\.low).min() ?? 0
        var maxHigh = slice.map(\.high).max() ?? 100

        let offsets = Array(startIndex...endIndex).filter { $0 < closes.count }
        var all: [Double] = []
        for line in mainCurves {
            for idx in offsets {
                let v = line.values[idx]
                if !v.isNaN { all.append(v) }
            }
        }
        if let minV = all.min() { minLow = min(minLow, minV) }
        if let maxV = all.max() { maxHigh = max(maxHigh, maxV) }

        let padding = (maxHigh - minLow) * 0.05
        return (minLow - padding)...(maxHigh + padding)
    }

    // MARK: - 成交量

    private var volumeMax: Double {
        let maA = volumeIndicator == .amount ? amoMa5 : volMa5
        let maB = volumeIndicator == .amount ? amoMa10 : volMa10
        let values: [Double] = offsetsMap { index in [maA[index], maB[index]].filter { !$0.isNaN } }
        let sliceMax = slice.map(volumeIndicator == .amount ? \.turnover : \.volume).max() ?? 1
        return max(sliceMax, values.max() ?? 1)
    }

    private func offsetsMap(_ body: (Int) -> [Double]) -> [Double] {
        var result: [Double] = []
        for i in startIndex...endIndex { result.append(contentsOf: body(i)) }
        return result
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let candleSpacing = width / CGFloat(max(1, count))
            let legendHeight: CGFloat = 13
            // 减少顶底空白：缩小指标栏与时间轴占比
            let chartHeight = max(1, geometry.size.height - 3 * legendHeight)
            let mainHeight = chartHeight * 0.56
            let volumeHeight = chartHeight * 0.12
            let indicatorHeight = chartHeight * 0.19
            let timeHeight = chartHeight * 0.13

            let mainTop = legendHeight
            let mainBottom = legendHeight + mainHeight
            let volTop = mainBottom + legendHeight
            let volBottom = volTop + volumeHeight
            let indTop = volBottom + legendHeight
            let indBottom = indTop + indicatorHeight

            VStack(spacing: 0) {
                mainLegendRow(height: legendHeight)
                    .zIndex(30)
                mainChart(width: width, candleSpacing: candleSpacing, height: mainHeight, panelTop: mainTop)
                volumeLegendRow(height: legendHeight)
                    .zIndex(30)
                volumeChart(width: width, candleSpacing: candleSpacing, height: volumeHeight,
                            crosshairY: crosshairY, panelTop: volTop)
                indicatorLegendRow(height: legendHeight)
                    .zIndex(30)
                indicatorChart(width: width, candleSpacing: candleSpacing, height: indicatorHeight,
                               crosshairY: crosshairY, panelTop: indTop)
                timeAxis(width: width, candleSpacing: candleSpacing, height: timeHeight)
            }
            .contentShape(Rectangle())
            .gesture(chartDragGesture(candleSpacing: candleSpacing,
                                      mainTop: mainTop, mainBottom: mainBottom,
                                      volTop: volTop, volBottom: volBottom,
                                      indTop: indTop, indBottom: indBottom))
            .simultaneousGesture(magnificationGesture)
            .overlay(alignment: .top) {
                if !hasInteracted {
                    Text("主图拖动平移/上下缩放 · 双指缩放 · 轻点切换光标")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.white.opacity(0.85)).cornerRadius(4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
                        .padding(.top, 5)
                        .transition(.opacity)
                }
            }
            .overlay {
                if let crosshairY, isInChartPanel(crosshairY, mainTop, mainBottom)
                    || isInChartPanel(crosshairY, volTop, volBottom)
                    || isInChartPanel(crosshairY, indTop, indBottom) {
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
                        case .sub: activateSubCustom(ind)
                        }
                    }
                    .zIndex(50)
                }
            }
            .overlay {
                if showMainSheet {
                    bottomSheet(geometry: geometry, heightFraction: 0.78) {
                        mainSheetContent
                    } onClose: {
                        showMainSheet = false
                    }
                } else if showIndicatorSheet {
                    bottomSheet(geometry: geometry, heightFraction: 0.78) {
                        subSheetContent
                    } onClose: {
                        showIndicatorSheet = false
                    }
                }
            }
        }
        .background(Color.white)
        .onAppear {
            recomputeMainCurves()
            recomputeSubCurves()
        }
        .onChange(of: customStore.indicators) { _ in
            syncActiveCustomAfterStoreChange()
            recomputeMainCurves()
            recomputeSubCurves()
        }
    }

    /// 自定义指标仓库变化后，同步主/副图激活的指标引用
    private func syncActiveCustomAfterStoreChange() {
        if let active = activeCustomIndicator,
           let updated = customStore.indicators.first(where: { $0.id == active.id }) {
            activateCustom(updated)
        } else if activeCustomIndicator != nil {
            activeCustomIndicator = nil
            customOutputs = []
            recomputeMainCurves()
        }
        if let active = activeSubCustom,
           let updated = customStore.indicators.first(where: { $0.id == active.id }) {
            activateSubCustom(updated)
        } else if activeSubCustom != nil {
            activeSubCustom = nil
            subCustomOutputs = []
            recomputeSubCurves()
        }
    }

    private func isInChartPanel(_ y: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> Bool {
        y >= top && y <= bottom
    }

    /// 任一面板是否打开（打开时禁用图表拖拽手势）
    private var menuIsOpen: Bool { showMainSheet || showIndicatorSheet || showVolumeMenu || showCustomEditor }

    // MARK: - 自定义指标激活

    private func activateCustom(_ ind: CustomIndicator?) {
        activeCustomIndicator = ind
        if let ind, let lines = try? TDXFormulaEngine.evaluate(formula: ind.formula, data: sortedData) {
            customOutputs = lines
        } else {
            customOutputs = []
        }
        recomputeMainCurves()
    }

    private func activateSubCustom(_ ind: CustomIndicator?) {
        activeSubCustom = ind
        recomputeSubCurves()
    }

    // MARK: - 手势

    private func chartDragGesture(candleSpacing: CGFloat,
                                  mainTop: CGFloat, mainBottom: CGFloat,
                                  volTop: CGFloat, volBottom: CGFloat,
                                  indTop: CGFloat, indBottom: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !menuIsOpen else { return }
                hasInteracted = true
                let y = value.location.y
                let inMain = isInChartPanel(y, mainTop, mainBottom)
                let inVol = isInChartPanel(y, volTop, volBottom)
                let inInd = isInChartPanel(y, indTop, indBottom)
                guard inMain || inVol || inInd else { return }

                if selectedIndex != nil {
                    let col = Int((value.location.x / candleSpacing).rounded(.down))
                    let idx = startIndex + col
                    if idx >= startIndex && idx <= endIndex {
                        selectedIndex = idx
                        crosshairY = value.location.y
                    }
                    if abs(value.translation.width) > 6 || abs(value.translation.height) > 6 {
                        cursorDragging = true
                    }
                } else if inMain && dragMode == .none {
                    if abs(value.translation.height) > abs(value.translation.width)
                        && abs(value.translation.height) > 4 {
                        dragMode = .zoom
                    } else if abs(value.translation.width) > 4 {
                        dragMode = .pan
                    }
                    lastPanWidth = 0
                    lastPanHeight = 0
                }

                if dragMode == .zoom {
                    let deltaY = value.translation.height - lastPanHeight
                    lastPanHeight = value.translation.height
                    visibleCount = clamp(visibleCount + deltaY * 0.5, 20, CGFloat(sortedData.count))
                } else if dragMode == .pan {
                    let delta = value.translation.width - lastPanWidth
                    lastPanWidth = value.translation.width
                    let cols = Int((delta / candleSpacing).rounded())
                    if cols != 0 {
                        endOffset = clamp(endOffset + cols, 0, max(0, sortedData.count - count))
                    }
                }
            }
            .onEnded { value in
                lastPanWidth = 0
                lastPanHeight = 0
                dragMode = .none
                guard !menuIsOpen else { cursorDragging = false; return }
                if cursorDragging {
                    cursorDragging = false
                    return
                }
                let y = value.location.y
                let inPanel = isInChartPanel(y, mainTop, mainBottom)
                    || isInChartPanel(y, volTop, volBottom)
                    || isInChartPanel(y, indTop, indBottom)
                let isTap = abs(value.translation.width) < 6 && abs(value.translation.height) < 6
                if isTap && inPanel {
                    let col = Int((value.location.x / candleSpacing).rounded(.down))
                    let idx = startIndex + col
                    if selectedIndex != nil {
                        selectedIndex = nil
                        crosshairY = nil
                    } else if idx >= startIndex && idx <= endIndex {
                        selectedIndex = idx
                        crosshairY = value.location.y
                    }
                }
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                hasInteracted = true
                selectedIndex = nil
                crosshairY = nil
                visibleCount = clamp(zoomBase / value, 20, CGFloat(sortedData.count))
            }
            .onEnded { _ in zoomBase = visibleCount }
    }

    private func clamp<V: Comparable>(_ v: V, _ lo: V, _ hi: V) -> V {
        min(max(v, lo), hi)
    }

    // MARK: - 主图

    private func mainChart(width: CGFloat, candleSpacing: CGFloat, height: CGFloat, panelTop: CGFloat) -> some View {
        return ZStack(alignment: .topLeading) {
            Color.white
            mainCanvas(width: width, candleSpacing: candleSpacing, height: height)
            overlayPriceLabels(width: width, height: height, min: priceRange.lowerBound, max: priceRange.upperBound,
                               ratios: [0, 0.25, 0.5, 0.75, 1], format: "%.2f")
            if let latest = slice.last {
                Text(String(format: "%.2f", latest.close))
                    .font(.system(size: 9))
                    .foregroundColor(latest.isUp ? upColor : downColor)
                    .padding(.horizontal, 3)
                    .background(Color.white.opacity(0.6))
                    .position(x: 20, y: yPosition(for: latest.close, in: height))
            }
            if let selectedIndex, selectedIndex >= startIndex, selectedIndex <= endIndex {
                let item = sortedData[selectedIndex]
                let xPosition = (CGFloat(selectedIndex - startIndex) + 0.5) * candleSpacing
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: 0.5, height: height)
                    .position(x: xPosition, y: height / 2)
                if let crosshairY, crosshairY >= panelTop, crosshairY <= panelTop + height {
                    let clampedY = min(max(crosshairY - panelTop, 0), height)
                    let priceAtY = priceRange.upperBound - (priceRange.upperBound - priceRange.lowerBound) * Double(clampedY / height)
                    Text(String(format: "%.2f", priceAtY))
                        .font(.system(size: 9))
                        .foregroundColor(.black)
                        .padding(.horizontal, 3)
                        .background(Color.white.opacity(0.6))
                        .position(x: 20, y: clampedY)
                }
                infoPanel(index: selectedIndex, item: item)
                    .padding(.leading, 6)
                    .padding(.top, 2)
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private func mainCanvas(width: CGFloat, candleSpacing: CGFloat, height: CGFloat) -> some View {
        MainChartCanvas(
            slice: slice, chartStyle: chartStyle, candleSpacing: candleSpacing, height: height,
            priceMin: priceRange.lowerBound, priceMax: priceRange.upperBound,
            curves: mainCurves.map { CanvasCurve(color: $0.color, values: sliceArr($0.values), style: $0.style, lineWidth: $0.lineWidth) },
            upColor: upColor, downColor: downColor, gridColor: gridColor
        )
        .equatable()
    }

    private func volumeCanvas(width: CGFloat, candleSpacing: CGFloat, height: CGFloat) -> some View {
        let isAmount = volumeIndicator == .amount
        return VolumeChartCanvas(
            slice: slice,
            values: slice.map(isAmount ? \.turnover : \.volume),
            maxValue: volumeMax,
            candleSpacing: candleSpacing, height: height,
            ma5: isAmount ? sliceArr(amoMa5) : sliceArr(volMa5),
            ma10: isAmount ? sliceArr(amoMa10) : sliceArr(volMa10),
            upColor: upColor, downColor: downColor, gridColor: gridColor,
            ma5Color: ma5Color, ma10Color: ma10Color
        )
        .equatable()
    }

    // MARK: - 成交量幅图

    private func volumeChart(width: CGFloat, candleSpacing: CGFloat, height: CGFloat,
                             crosshairY: CGFloat?, panelTop: CGFloat) -> some View {
        return ZStack(alignment: .topLeading) {
            Color.white
            volumeCanvas(width: width, candleSpacing: candleSpacing, height: height)
            volumeAxisLabels(width: width, height: height)
            if let selectedIndex, selectedIndex >= startIndex, selectedIndex <= endIndex {
                let xPosition = (CGFloat(selectedIndex - startIndex) + 0.5) * candleSpacing
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: 0.5, height: height)
                    .position(x: xPosition, y: height / 2)
                if let crosshairY, crosshairY >= panelTop, crosshairY <= panelTop + height {
                    let localY = min(max(crosshairY - panelTop, 0), height)
                    let volAtY = volumeMax * Double(1 - localY / height)
                    Text(formatVolume(volAtY))
                        .font(.system(size: 9))
                        .foregroundColor(.black)
                        .padding(.horizontal, 3)
                        .background(Color.white.opacity(0.6))
                        .position(x: 20, y: localY)
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private func volumeAxisLabels(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(formatVolume(volumeMax))
                .font(.system(size: 9)).foregroundColor(axisTextColor)
                .padding(.horizontal, 2).padding(.vertical, 1)
                .background(Color.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            Text("0")
                .font(.system(size: 9)).foregroundColor(axisTextColor)
                .padding(.horizontal, 2).padding(.vertical, 1)
                .background(Color.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 4)
        .frame(width: width, height: height)
    }

    // MARK: - 指标副图

    private func indicatorChart(width: CGFloat, candleSpacing: CGFloat, height: CGFloat,
                                crosshairY: CGFloat?, panelTop: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.white
            indicatorCanvas(width: width, candleSpacing: candleSpacing, height: height)
            indicatorAxisLabels(width: width, height: height)
            if let selectedIndex, selectedIndex >= startIndex, selectedIndex <= endIndex {
                let xPosition = (CGFloat(selectedIndex - startIndex) + 0.5) * candleSpacing
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: 0.5, height: height)
                    .position(x: xPosition, y: height / 2)
                if let crosshairY, crosshairY >= panelTop, crosshairY <= panelTop + height {
                    let localY = min(max(crosshairY - panelTop, 0), height)
                    let range = indicatorRange
                    let value = range.max - (range.max - range.min) * Double(localY / height)
                    let fmt = (isMacdMode || isCustomSubMode) ? "%.3f" : "%.1f"
                    Text(String(format: fmt, value))
                        .font(.system(size: 9)).foregroundColor(.black)
                        .padding(.horizontal, 3)
                        .background(Color.white.opacity(0.6))
                        .position(x: 20, y: localY)
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private var isCustomSubMode: Bool { activeSubCustom != nil && !subCustomOutputs.isEmpty }
    private var isMacdMode: Bool { !isCustomSubMode && indicator == .macd }

    @ViewBuilder
    private func indicatorAxisLabels(width: CGFloat, height: CGFloat) -> some View {
        let range = indicatorRange
        if isMacdMode {
            overlayPriceLabels(width: width, height: height, min: range.min, max: range.max,
                               ratios: [0, 0.5, 1], format: "%.3f")
        } else if indicator == .rsi && !isCustomSubMode {
            overlayPriceLabels(width: width, height: height, min: range.min, max: range.max,
                               ratios: [0, 0.25, 0.5, 0.75, 1], format: "%.0f")
        } else if isCustomSubMode {
            overlayPriceLabels(width: width, height: height, min: range.min, max: range.max,
                               ratios: [0, 0.5, 1], format: "%.3f")
        } else {
            overlayPriceLabels(width: width, height: height, min: range.min, max: range.max,
                               ratios: [0, 0.5, 1], format: "%.1f")
        }
    }

    /// 副图基于可见窗口的动态坐标范围
    private var indicatorRange: (min: Double, max: Double) {
        let offsets = Array(startIndex...endIndex)
        var values: [Double] = []
        for line in subCurves {
            for idx in offsets where idx < line.values.count {
                let v = line.values[idx]
                if !v.isNaN { values.append(v) }
            }
        }
        if isMacdMode {
            let m = values.map { abs($0) }.max() ?? 1
            let mm = max(m * 1.15, 0.0001)
            return (-mm, mm)
        }
        if indicator == .rsi && !isCustomSubMode { return (0, 100) }
        let lo = values.min() ?? 0
        let hi = values.max() ?? 100
        guard hi > lo else { return (lo - 1, hi + 1) }
        let pad = (hi - lo) * 0.1
        return (lo - pad, hi + pad)
    }

    private func indicatorCanvas(width: CGFloat, candleSpacing: CGFloat, height: CGFloat) -> some View {
        let range = indicatorRange
        return IndicatorChartCanvas(
            candleSpacing: candleSpacing, height: height,
            curves: subCurves.map { CanvasCurve(color: $0.color, values: sliceArr($0.values), style: $0.style, lineWidth: $0.lineWidth) },
            macdSignColor: isMacdMode,
            rangeMin: range.min, rangeMax: range.max,
            upColor: upColor, downColor: downColor, gridColor: gridColor
        )
        .equatable()
    }

    // MARK: - 指标栏（名称按钮打开底部面板）

    private func mainLegendRow(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 8) {
                nameButtonView(title: mainLegendTitle, isOpen: $showMainSheet) {
                    showVolumeMenu = false
                    showIndicatorSheet = false
                }
                if showBareK {
                    legendText("裸K", hideValue: false)
                }
                ForEach(Array(mainCurves.enumerated()), id: \.offset) { idx, line in
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

    private func volumeLegendRow(height: CGFloat) -> some View {
        let isAmount = volumeIndicator == .amount
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 8) {
                nameButtonView(title: isAmount ? "AMO" : "VOL", isOpen: $showVolumeMenu) {
                    showMainSheet = false
                    showIndicatorSheet = false
                }
                legendItem(IndicatorLine(name: "MA5", values: isAmount ? amoMa5 : volMa5, color: ma5Color,
                                         style: .solid, lineWidth: 1, hideValue: false))
                legendItem(IndicatorLine(name: "MA10", values: isAmount ? amoMa10 : volMa10, color: ma10Color,
                                         style: .solid, lineWidth: 1, hideValue: false))
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(Color.white)

            if showVolumeMenu {
                volumeMenuView(height: height)
                    .offset(y: height + 2)
                    .padding(.leading, 6)
                    .transition(.opacity)
            }
        }
        .frame(height: height)
    }

    /// 量图下拉菜单（VOL/AMO）
    private func volumeMenuView(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(VolumeIndicator.allCases) { opt in
                Button {
                    volumeIndicator = opt
                    showVolumeMenu = false
                } label: {
                    HStack {
                        Text(opt.rawValue).font(.system(size: 11)).foregroundColor(.black)
                        Spacer()
                        if volumeIndicator == opt {
                            Image(systemName: "checkmark").font(.system(size: 10)).foregroundColor(.blue)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                }
            }
        }
        .background(Color.white)
        .cornerRadius(6)
        .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
    }

    private func indicatorLegendRow(height: CGFloat) -> some View {
        let title = isCustomSubMode ? activeSubCustom?.name ?? "自定义" : subLegendTitle
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 8) {
                nameButtonView(title: title, isOpen: $showIndicatorSheet) {
                    showMainSheet = false
                    showVolumeMenu = false
                }
                ForEach(Array(subCurves.enumerated()), id: \.offset) { idx, line in
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

    private var subLegendTitle: String { indicator.rawValue }

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
            Circle().fill(line.style == .nodraw ? Color.clear : line.color).frame(width: line.style == .stick ? 3 : 5, height: 5)
            Text(line.name).font(.system(size: 9)).foregroundColor(.gray)
            if !line.hideValue, let value = legendValueFor(line), !value.isNaN {
                Text(String(format: format, value)).font(.system(size: 9)).foregroundColor(line.color)
            }
        }
    }

    private func legendText(_ text: String, hideValue: Bool) -> some View {
        HStack(spacing: 2) {
            Circle().fill(Color.gray).frame(width: 5, height: 5)
            Text(text).font(.system(size: 9)).foregroundColor(.gray)
        }
    }

    // MARK: - 底部选择面板（指标选择 + 参数编辑）

    private func bottomSheet<Content: View>(geometry: GeometryProxy, heightFraction: CGFloat,
                                            @ViewBuilder content: () -> Content,
                                            onClose: @escaping () -> Void) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { onClose() } }

            VStack(spacing: 0) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: geometry.size.width, height: min(geometry.size.height * heightFraction, 640))
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 主图面板

    private var mainSheetContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("主图指标")
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.black)
                Spacer()
                Button("关闭") { showMainSheet = false }
                    .font(.system(size: 14)).foregroundColor(.gray)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    toggleRow("裸K（隐藏全部叠加线）", on: $showBareK) { recomputeMainCurves() }
                    Divider()
                    toggleRow("MA 均线", on: $showMA) { recomputeMainCurves() }
                    if showMA {
                        paramRow(title: "MA 周期（0=隐藏，最多8个）") {
                            periodsEditor(periods: $maConfig.periods)
                        }
                    }
                    Divider()
                    toggleRow("EMA 均线", on: $showEMA) { recomputeMainCurves() }
                    if showEMA {
                        paramRow(title: "EMA 周期（0=隐藏，最多8个）") {
                            periodsEditor(periods: $emaConfig.periods)
                        }
                    }
                    Divider()
                    toggleRow("BOLL 布林带", on: $showBOLL) { recomputeMainCurves() }
                    if showBOLL {
                        paramRow(title: "BOLL 参数") {
                            HStack(spacing: 12) {
                                numberField("周期", $bollConfig.period, range: 1...1000)
                                numberField("倍数", $bollConfig.mult, range: 0.1...10)
                            }
                        }
                    }
                    Divider()
                    // 自定义指标叠加
                    HStack(spacing: 8) {
                        Image(systemName: "function")
                            .font(.system(size: 13)).foregroundColor(.blue)
                        Text("自定义叠加指标").font(.system(size: 14, weight: .medium)).foregroundColor(.black)
                        Spacer()
                        Button("管理/新增") { showMainSheet = false; editorTarget = .main; showCustomEditor = true }
                            .font(.system(size: 12)).foregroundColor(.blue)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)

                    if customStore.indicators.isEmpty {
                        Text("暂无自定义指标，点右上“管理/新增”创建")
                            .font(.system(size: 12)).foregroundColor(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.bottom, 12)
                    } else {
                        ForEach(customStore.indicators) { ind in
                            HStack {
                                Button {
                                    if activeCustomIndicator?.id == ind.id {
                                        activateCustom(nil)
                                    } else {
                                        activateCustom(ind)
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: activeCustomIndicator?.id == ind.id ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(activeCustomIndicator?.id == ind.id ? .blue : .gray)
                                        RoundedRectangle(cornerRadius: 2).fill(ind.color).frame(width: 16, height: 5)
                                        Text(ind.name).font(.system(size: 14)).foregroundColor(.black)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                    }
                    Spacer(minLength: 20)
                }
            }
        }
    }

    // MARK: 副图面板

    private var subSheetContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("副图指标")
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.black)
                Spacer()
                Button("关闭") { showIndicatorSheet = false }
                    .font(.system(size: 14)).foregroundColor(.gray)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    // 系统指标
                    ForEach(SubIndicator.allCases) { sub in
                        Button {
                            if activeSubCustom != nil { activeSubCustom = nil }
                            indicator = sub
                            recomputeSubCurves()
                        } label: {
                            HStack {
                                Text(sub.rawValue).font(.system(size: 14)).foregroundColor(.black)
                                Spacer()
                                if !isCustomSubMode && indicator == sub {
                                    Image(systemName: "checkmark").font(.system(size: 13)).foregroundColor(.blue)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        if !isCustomSubMode && indicator == sub {
                            subParamEditor
                        }
                        Divider()
                    }

                    // 自定义指标
                    HStack(spacing: 8) {
                        Image(systemName: "function").font(.system(size: 13)).foregroundColor(.blue)
                        Text("自定义副图指标").font(.system(size: 14, weight: .medium)).foregroundColor(.black)
                        Spacer()
                        Button("管理/新增") { showIndicatorSheet = false; editorTarget = .sub; showCustomEditor = true }
                            .font(.system(size: 12)).foregroundColor(.blue)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)

                    if customStore.indicators.isEmpty {
                        Text("暂无自定义指标，点“管理/新增”创建")
                            .font(.system(size: 12)).foregroundColor(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.bottom, 12)
                    } else {
                        ForEach(customStore.indicators) { ind in
                            HStack {
                                Button {
                                    if activeSubCustom?.id == ind.id {
                                        activateSubCustom(nil)
                                    } else {
                                        activateSubCustom(ind)
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: activeSubCustom?.id == ind.id ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(activeSubCustom?.id == ind.id ? .blue : .gray)
                                        RoundedRectangle(cornerRadius: 2).fill(ind.color).frame(width: 16, height: 5)
                                        Text(ind.name).font(.system(size: 14)).foregroundColor(.black)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                    }
                    Spacer(minLength: 20)
                }
            }
        }
    }

    @ViewBuilder
    private var subParamEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch indicator {
            case .macd:
                HStack(spacing: 12) {
                    numberField("快线", $macdConfig.fast, range: 1...300)
                    numberField("慢线", $macdConfig.slow, range: 1...300)
                    numberField("信号", $macdConfig.signal, range: 1...300)
                }
            case .kdj:
                HStack(spacing: 12) {
                    numberField("周期", $kdjConfig.n, range: 1...300)
                    numberField("K", $kdjConfig.kN, range: 1...100)
                    numberField("D", $kdjConfig.dN, range: 1...100)
                }
            case .rsi:
                HStack(spacing: 12) {
                    numberField("P1", $rsiConfig.p1, range: 1...300)
                    numberField("P2", $rsiConfig.p2, range: 1...300)
                    numberField("P3", $rsiConfig.p3, range: 1...300)
                }
            }
            // 参数输入可能被 onEnded 触发的 onEditingChanged 回调里重新计算
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .onChange(of: macdConfig) { _ in recomputeSubCurves() }
        .onChange(of: kdjConfig) { _ in recomputeSubCurves() }
        .onChange(of: rsiConfig) { _ in recomputeSubCurves() }
    }

    // MARK: 通用 UI 组件

    private func toggleRow(_ title: String, on: Binding<Bool>, onChange: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 14)).foregroundColor(.black)
            Spacer()
            Toggle("", isOn: on).labelsHidden()
                .onChange(of: on.wrappedValue) { _ in onChange() }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func paramRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundColor(.gray)
            content()
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    /// 最多 8 个周期输入框
    private func periodsEditor(periods: Binding<[Int]>) -> some View {
        let list = Array(0..<8)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: 8, by: 4)), id: \.self) { rowStart in
                HStack(spacing: 12) {
                    ForEach(list[rowStart..<min(rowStart + 4, 8)], id: \.self) { idx in
                        smallNumberField(label: "\(idx + 1)", value: periodBinding(periods, idx))
                    }
                }
            }
        }
    }

    private func periodBinding(_ periods: Binding<[Int]>, _ idx: Int) -> Binding<String> {
        Binding(
            get: { String(periods.wrappedValue.indices.contains(idx) ? periods.wrappedValue[idx] : 0) },
            set: { newValue in
                var arr = periods.wrappedValue
                if arr.count != 8 { arr = Array(repeating: 0, count: 8) }
                let n = Int(newValue) ?? 0
                arr[idx] = min(max(n, 0), 1000)
                periods.wrappedValue = arr
            }
        )
    }

    private func smallNumberField(label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundColor(.gray)
            TextField("", text: value)
                .font(.system(size: 12))
                .keyboardType(.numberPad)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(Color(uiColor: .systemGray6)).cornerRadius(4)
        }
        .frame(maxWidth: .infinity)
    }

    private func numberField(_ label: String, _ value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundColor(.gray)
            TextField("", text: Binding(
                get: { String(value.wrappedValue) },
                set: { nv in value.wrappedValue = min(max(Int(nv) ?? value.wrappedValue, range.lowerBound), range.upperBound) }
            ))
            .font(.system(size: 13))
            .keyboardType(.numberPad)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Color(uiColor: .systemGray6)).cornerRadius(4)
        }
        .frame(maxWidth: .infinity)
    }

    private func numberField(_ label: String, _ value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundColor(.gray)
            TextField("", text: Binding(
                get: { String(format: "%.1f", value.wrappedValue) },
                set: { nv in
                    let n = Double(nv) ?? value.wrappedValue
                    value.wrappedValue = min(max(n, range.lowerBound), range.upperBound)
                }
            ))
            .font(.system(size: 13))
            .keyboardType(.decimalPad)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Color(uiColor: .systemGray6)).cornerRadius(4)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 时间轴

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

    // MARK: - 通用绘制辅助

    private func overlayPriceLabels(width: CGFloat, height: CGFloat, min: Double, max: Double, ratios: [CGFloat], format: String) -> some View {
        ZStack {
            ForEach(ratios, id: \.self) { ratio in
                let value = max - (max - min) * Double(ratio)
                Text(String(format: format, value))
                    .font(.system(size: 9))
                    .foregroundColor(axisTextColor)
                    .padding(.horizontal, 2).padding(.vertical, 1)
                    .background(Color.white.opacity(0.55))
                    .position(x: 22, y: clampedAxisY(height * CGFloat(ratio), in: height))
            }
        }
        .frame(width: width, height: height)
    }

    private func clampedAxisY(_ y: CGFloat, in height: CGFloat) -> CGFloat {
        let half: CGFloat = 8
        return min(max(y, half), max(half, height - half))
    }

    // MARK: - 十字光标信息面板

    private func infoPanel(index: Int, item: KlineItem) -> some View {
        let changeAmount = prevClose(of: index) > 0 ? item.close - prevClose(of: index) : 0
        let changeColor: Color = changeAmount >= 0 ? upColor : downColor
        return VStack(alignment: .leading, spacing: 2) {
            Text(item.formattedDateWithWeekday)
                .font(.system(size: 10, weight: .medium)).foregroundColor(.black)
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
        guard index > 0, index < sortedData.count else {
            return index < sortedData.count ? sortedData[index].close : 0
        }
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

    private func formatVolume(_ v: Double) -> String {
        if v >= 100000000 { return String(format: "%.2f亿", v / 100000000) }
        else if v >= 10000 { return String(format: "%.2f万", v / 10000) }
        else { return String(format: "%.0f", v) }
    }

    // MARK: - 坐标换算

    private func yPosition(for price: Double, in height: CGFloat) -> CGFloat {
        yPos(price, min: priceRange.lowerBound, max: priceRange.upperBound, height: height)
    }

    private func yPos(_ value: Double, min minValue: Double, max maxValue: Double, height: CGFloat) -> CGFloat {
        let range = maxValue - minValue
        guard range > 0 else { return height }
        let ratio = (value - minValue) / range
        return height * CGFloat(1 - ratio)
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
            for i in 0..<8 {
                let x = w * CGFloat(i) / 8
                var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
            }

            let candleWidth = max(1.5, candleSpacing * 0.7)
            switch chartStyle {
            case .bare, .solid:
                let hollow = chartStyle == .bare  // 空心K：红K空、绿K实
                for (li, item) in slice.enumerated() {
                    let x = (CGFloat(li) + 0.5) * candleSpacing
                    let color = item.isUp ? upColor : downColor
                    let yH = yPos(item.high, h: h)
                    let yL = yPos(item.low, h: h)
                    var wick = Path()
                    wick.move(to: CGPoint(x: x, y: yH)); wick.addLine(to: CGPoint(x: x, y: yL))
                    ctx.stroke(wick, with: .color(color), lineWidth: 1)
                    let bodyTop = yPos(max(item.open, item.close), h: h)
                    let bodyBottom = yPos(min(item.open, item.close), h: h)
                    let rect = CGRect(x: x - candleWidth / 2, y: bodyTop, width: candleWidth, height: max(1, bodyBottom - bodyTop))
                    if hollow && item.isUp {
                        // 红K空心：仅描边
                        ctx.stroke(Path(rect), with: .color(color), lineWidth: 1)
                    } else {
                        ctx.fill(Path(rect), with: .color(color))
                    }
                }
            case .close:
                strokeLine(ctx, values: slice.map(\.close), color: Color(red: 0.2, green: 0.4, blue: 0.9), h: h, style: .solid, lineWidth: 1)
            case .ohlc:
                for (li, item) in slice.enumerated() {
                    let x = (CGFloat(li) + 0.5) * candleSpacing
                    let color = item.isUp ? upColor : downColor
                    let yH = yPos(item.high, h: h)
                    let yL = yPos(item.low, h: h)
                    var bar = Path()
                    bar.move(to: CGPoint(x: x, y: yH)); bar.addLine(to: CGPoint(x: x, y: yL))
                    ctx.stroke(bar, with: .color(color), lineWidth: max(1, candleWidth * 0.12))
                    let oy = yPos(item.open, h: h)
                    var op = Path(); op.move(to: CGPoint(x: x - candleSpacing * 0.18, y: oy)); op.addLine(to: CGPoint(x: x, y: oy))
                    ctx.stroke(op, with: .color(color), lineWidth: 1)
                    let cy = yPos(item.close, h: h)
                    var cl = Path(); cl.move(to: CGPoint(x: x, y: cy)); cl.addLine(to: CGPoint(x: x + candleSpacing * 0.18, y: cy))
                    ctx.stroke(cl, with: .color(color), lineWidth: 1)
                }
            }

            // 叠加指标/自定义线
            for curve in curves {
                drawCurve(ctx, curve: curve, h: h)
            }

            if let latest = slice.last {
                let y = yPos(latest.close, h: h)
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                ctx.stroke(p, with: .color(latest.isUp ? upColor.opacity(0.6) : downColor.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            }
        }
    }

    private func drawCurve(_ ctx: GraphicsContext, curve: CanvasCurve, h: CGFloat) {
        switch curve.style {
        case .dotline:
            strokeLine(ctx, values: curve.values, color: curve.color, h: h, style: .dotline, lineWidth: curve.lineWidth)
        case .pointdot:
            var points = Path()
            for (i, v) in curve.values.enumerated() {
                guard !v.isNaN else { continue }
                let x = (CGFloat(i) + 0.5) * candleSpacing
                let y = yPos(v, h: h)
                points.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
            }
            ctx.fill(points, with: .color(curve.color))
        case .stick:
            let barWidth = max(0.6, candleSpacing * 0.55)
            for (i, v) in curve.values.enumerated() {
                guard !v.isNaN else { continue }
                let x = (CGFloat(i) + 0.5) * candleSpacing
                let y = yPos(0, h: h)  // 从 0 值起点
                let yv = yPos(v, h: h)
                let rect = CGRect(x: x - barWidth / 2, y: min(y, yv), width: barWidth, height: max(0.5, abs(y - yv)))
                ctx.fill(Path(rect), with: .color(curve.color))
            }
        case .solid:
            strokeLine(ctx, values: curve.values, color: curve.color, h: h, style: .solid, lineWidth: curve.lineWidth)
        case .nodraw:
            break
        }
    }

    private func strokeLine(_ ctx: GraphicsContext, values: [Double], color: Color, h: CGFloat, style: TDXLineStyle, lineWidth: Double) {
        var path = Path()
        var started = false
        for (i, v) in values.enumerated() {
            guard !v.isNaN else { continue }
            let x = (CGFloat(i) + 0.5) * candleSpacing
            let y = yPos(v, h: h)
            if started { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)); started = true }
        }
        let strokeStyle: StrokeStyle
        switch style {
        case .dotline: strokeStyle = StrokeStyle(lineWidth: lineWidth, dash: [3, 3])
        default: strokeStyle = StrokeStyle(lineWidth: lineWidth)
        }
        ctx.stroke(path, with: .color(color), style: strokeStyle)
    }

    private func yPos(_ v: Double, h: CGFloat) -> CGFloat {
        let range = priceMax - priceMin
        guard range > 0 else { return h }
        return h * CGFloat(1 - (v - priceMin) / range)
    }
}

// MARK: - 成交量 Canvas

struct VolumeChartCanvas: View, Equatable {
    let slice: [KlineItem]
    let values: [Double]
    let maxValue: Double
    let candleSpacing: CGFloat
    let height: CGFloat
    let ma5, ma10: [Double]
    let upColor, downColor, gridColor, ma5Color, ma10Color: Color

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            for ratio: CGFloat in [0, 0.5, 1] {
                let y = h * ratio
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
            }
            let barWidth = max(1.5, candleSpacing * 0.7)
            for (li, item) in slice.enumerated() {
                let x = (CGFloat(li) + 0.5) * candleSpacing
                let v = li < values.count ? values[li] : 0
                let barHeight = maxValue > 0 ? CGFloat(v / maxValue) * (h - 2) : 0
                let rect = CGRect(x: x - barWidth / 2, y: h - barHeight, width: barWidth, height: max(0.5, barHeight))
                ctx.fill(Path(rect), with: .color(item.isUp ? upColor.opacity(0.8) : downColor.opacity(0.8)))
            }
            strokeLine(ctx, values: ma5, color: ma5Color, h: h, lo: 0, hi: maxValue)
            strokeLine(ctx, values: ma10, color: ma10Color, h: h, lo: 0, hi: maxValue)
        }
    }

    private func yPos(_ v: Double, h: CGFloat, lo: Double, hi: Double) -> CGFloat {
        let range = hi - lo
        guard range > 0 else { return h }
        return h * CGFloat(1 - (v - lo) / range)
    }

    private func strokeLine(_ ctx: GraphicsContext, values: [Double], color: Color, h: CGFloat, lo: Double, hi: Double) {
        var path = Path()
        var started = false
        for (i, v) in values.enumerated() {
            guard !v.isNaN else { continue }
            let x = (CGFloat(i) + 0.5) * candleSpacing
            let y = yPos(v, h: h, lo: lo, hi: hi)
            if started { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)); started = true }
        }
        ctx.stroke(path, with: .color(color), lineWidth: 1)
    }
}

// MARK: - 指标副图 Canvas

struct IndicatorChartCanvas: View, Equatable {
    let candleSpacing: CGFloat
    let height: CGFloat
    let curves: [CanvasCurve]
    let macdSignColor: Bool
    let rangeMin: Double
    let rangeMax: Double
    let upColor, downColor, gridColor: Color

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            // 网格
            for ratio: CGFloat in [0, 0.5, 1] {
                let y = h * ratio
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
            }
            // 0 轴
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: h / 2)); zero.addLine(to: CGPoint(x: w, y: h / 2))
            ctx.stroke(zero, with: .color(Color.black.opacity(0.4)), lineWidth: 0.5)

            for curve in curves {
                switch curve.style {
                case .stick:
                    let barWidth = max(1.0, candleSpacing * 0.55)
                    let midY = h / 2
                    let half = max(abs(rangeMin), abs(rangeMax))
                    for (i, v) in curve.values.enumerated() {
                        guard !v.isNaN else { continue }
                        let x = (CGFloat(i) + 0.5) * candleSpacing
                        let barHeight = half > 0 ? abs(v) / half * (h / 2) : 0
                        let color = macdSignColor ? (v >= 0 ? upColor.opacity(0.8) : downColor.opacity(0.8)) : curve.color
                        let topY = v >= 0 ? (midY - barHeight) : midY
                        let rect = CGRect(x: x - barWidth / 2, y: topY, width: barWidth, height: max(0.5, barHeight))
                        ctx.fill(Path(rect), with: .color(color))
                    }
                case .dotline, .pointdot, .solid:
                    drawLine(ctx, curve: curve, h: h)
                case .nodraw:
                    break
                }
            }
        }
    }

    private func drawLine(_ ctx: GraphicsContext, curve: CanvasCurve, h: CGFloat) {
        if curve.style == .pointdot {
            var points = Path()
            for (i, v) in curve.values.enumerated() {
                guard !v.isNaN else { continue }
                let x = (CGFloat(i) + 0.5) * candleSpacing
                let y = yPos(v, h: h)
                points.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
            }
            ctx.fill(points, with: .color(curve.color))
            return
        }
        var path = Path()
        var started = false
        for (i, v) in curve.values.enumerated() {
            guard !v.isNaN else { continue }
            let x = (CGFloat(i) + 0.5) * candleSpacing
            let y = yPos(v, h: h)
            if started { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)); started = true }
        }
        let strokeStyle: StrokeStyle = curve.style == .dotline ? StrokeStyle(lineWidth: curve.lineWidth, dash: [3, 3]) : StrokeStyle(lineWidth: curve.lineWidth)
        ctx.stroke(path, with: .color(curve.color), style: strokeStyle)
    }

    private func yPos(_ v: Double, h: CGFloat) -> CGFloat {
        let range = rangeMax - rangeMin
        guard range > 0 else { return h }
        return h * CGFloat(1 - (v - rangeMin) / range)
    }
}
//
//  KlineChartView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/8/5.
//

import SwiftUI

/// 副图（指标幅图）可选类型
enum SubIndicator: String, CaseIterable, Identifiable {
    case macd = "MACD"
    case kdj = "KDJ"
    case rsi = "RSI"
    var id: String { rawValue }
}

/// 主图显示类型
enum ChartStyle: String, CaseIterable, Identifiable {
    case kline = "K线"
    case close = "收盘线"
    case ohlc = "美国线"
    var id: String { rawValue }
}

/// 成交量幅图可选类型
enum VolumeIndicator: String, CaseIterable, Identifiable {
    case volume = "量"
    case amount = "额"
    var id: String { rawValue }
}

/// 主图叠加指标类型
enum MainIndicator: String, CaseIterable, Identifiable {
    case ma = "MA"
    case ema = "EMA"
    case boll = "BOLL"
    var id: String { rawValue }
}

/// 无光标时的拖动模式：水平=平移，垂直=缩放
enum DragMode {
    case none, pan, zoom
}

/// 缓存 K 线指标计算的结果，避免每次渲染重复计算。
struct ChartSeries {
    let sorted: [KlineItem]
    let ma5, ma10, ma20, ma60: [Double]
    let ema5, ema10, ema20, ema60: [Double]
    let bollMid, bollUpper, bollLower: [Double]
    let volMa5, volMa10: [Double]
    let amoMa5, amoMa10: [Double]
    let dif, dea, macdHist: [Double]
    let kdjK, kdjD, kdjJ: [Double]
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

        func ema(_ values: [Double], _ period: Int) -> [Double] {
            var result: [Double] = []
            let k = 2.0 / Double(period + 1)
            var prev: Double?
            for v in values {
                if let p = prev { result.append(v * k + p * (1 - k)) } else { result.append(v) }
                prev = result.last
            }
            return result
        }
        let closes = sorted.map(\.close)
        self.ema5 = ema(closes, 5)
        self.ema10 = ema(closes, 10)
        self.ema20 = ema(closes, 20)
        self.ema60 = ema(closes, 60)

        // BOLL(20,2)：中轨=MA20，上下轨=中轨 ± 2*标准差
        func std(_ period: Int) -> [Double] {
            var result = Array(repeating: Double.nan, count: sorted.count)
            for i in (period - 1)..<sorted.count {
                let window = (i - period + 1)...i
                let vals = Array(window).map { sorted[$0].close }
                let mean = vals.reduce(0, +) / Double(period)
                let variance = vals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(period)
                result[i] = sqrt(variance)
            }
            return result
        }
        self.bollMid = ma(20, \.close)
        let sd = std(20)
        self.bollUpper = zip(self.bollMid, sd).map { $0 + 2 * $1 }
        self.bollLower = zip(self.bollMid, sd).map { $0 - 2 * $1 }

        let dif = zip(ema(closes, 12), ema(closes, 26)).map { $0 - $1 }
        self.dif = dif
        self.dea = ema(dif, 9)
        self.macdHist = zip(self.dif, self.dea).map { 2 * ($0 - $1) }

        // KDJ (9,3,3)
        var kArr: [Double] = []
        var dArr: [Double] = []
        var jArr: [Double] = []
        var prevK = 50.0
        var prevD = 50.0
        for i in 0..<sorted.count {
            let loIndex = max(0, i - 9 + 1)
            let lo = sorted[loIndex...i].map(\.low).min() ?? 0
            let hi = sorted[loIndex...i].map(\.high).max() ?? 0
            let rsv = (hi - lo) == 0 ? 50 : (sorted[i].close - lo) / (hi - lo) * 100
            let k = (2.0 * prevK + rsv) / 3.0
            let d = (2.0 * prevD + k) / 3.0
            kArr.append(k); dArr.append(d); jArr.append(3 * k - 2 * d)
            prevK = k; prevD = d
        }
        self.kdjK = kArr
        self.kdjD = dArr
        self.kdjJ = jArr

        // RSI
        func rsi(_ period: Int) -> [Double] {
            var result = Array(repeating: Double.nan, count: sorted.count)
            guard sorted.count > period else { return result }
            var avgGain = 0.0
            var avgLoss = 0.0
            for i in 1...period {
                let c = sorted[i].close - sorted[i - 1].close
                avgGain += max(c, 0) / Double(period)
                avgLoss += max(-c, 0) / Double(period)
            }
            func rv(_ g: Double, _ l: Double) -> Double {
                if l == 0 { return 100 }
                return 100 - 100 / (1 + g / l)
            }
            result[period] = rv(avgGain, avgLoss)
            for i in (period + 1)..<sorted.count {
                let c = sorted[i].close - sorted[i - 1].close
                avgGain = (avgGain * Double(period - 1) + max(c, 0)) / Double(period)
                avgLoss = (avgLoss * Double(period - 1) + max(-c, 0)) / Double(period)
                result[i] = rv(avgGain, avgLoss)
            }
            return result
        }
        self.rsi6 = rsi(6)
        self.rsi12 = rsi(12)
        self.rsi24 = rsi(24)
    }
}

/// 行情 K 线图，参考同花顺/通达信的日间（浅色）风格布局：
/// 主图（K线 + MA + 右侧价格轴与网格）+ 成交量幅图 + 指标幅图 + 时间轴。
/// 支持可见窗口平移、双指缩放、十字光标联动。
struct KlineChartView: View {
    let data: [KlineItem]
    @Binding var chartStyle: ChartStyle
    private let series: ChartSeries

    // 交互状态
    @State private var selectedIndex: Int? = nil
    @State private var indicator: SubIndicator = .macd
    @State private var volumeIndicator: VolumeIndicator = .volume
    @State private var mainIndicator: MainIndicator = .ma
    @State private var showMainMenu = false
    @State private var showVolumeMenu = false
    @State private var showIndicatorMenu = false
    @State private var visibleCount: CGFloat = 100
    @State private var endOffset: Int = 0          // 0 = 最新一根贴右边缘
    @State private var zoomBase: CGFloat = 100
    @State private var lastPanWidth: CGFloat = 0
    @State private var lastPanHeight: CGFloat = 0
    @State private var dragMode: DragMode = .none
    @State private var cursorDragging: Bool = false
    @State private var hasInteracted: Bool = false
    @State private var crosshairY: CGFloat? = nil

    init(data: [KlineItem], chartStyle: Binding<ChartStyle>) {
        self.data = data
        self._chartStyle = chartStyle
        // 指标计算只在初始化时执行一次，避免每次渲染都重复计算
        self.series = ChartSeries(data: data)
    }

    // MARK: - 配色

    private var upColor: Color { Color(red: 0.85, green: 0.16, blue: 0.16) }
    private var downColor: Color { Color(red: 0.0, green: 0.55, blue: 0.35) }
    private var ma5Color: Color { Color.black.opacity(0.75) }
    private var ma10Color: Color { Color.orange }
    private var ma20Color: Color { Color.pink }
    private var ma60Color: Color { Color.blue }
    private var gridColor: Color { Color.gray.opacity(0.22) }
    private var axisTextColor: Color { Color.black.opacity(0.55) }
    private var bollColor: Color { Color(red: 0.4, green: 0.4, blue: 0.9) }

    // MARK: - 数据（从缓存读取）

    private var sortedData: [KlineItem] { series.sorted }
    private var ma5: [Double] { series.ma5 }
    private var ma10: [Double] { series.ma10 }
    private var ma20: [Double] { series.ma20 }
    private var ma60: [Double] { series.ma60 }
    private var ema5: [Double] { series.ema5 }
    private var ema10: [Double] { series.ema10 }
    private var ema20: [Double] { series.ema20 }
    private var ema60: [Double] { series.ema60 }
    private var bollMid: [Double] { series.bollMid }
    private var bollUpper: [Double] { series.bollUpper }
    private var bollLower: [Double] { series.bollLower }
    private var volMa5: [Double] { series.volMa5 }
    private var volMa10: [Double] { series.volMa10 }
    private var amoMa5: [Double] { series.amoMa5 }
    private var amoMa10: [Double] { series.amoMa10 }
    private var dif: [Double] { series.dif }
    private var dea: [Double] { series.dea }
    private var macdHistogram: [Double] { series.macdHist }
    private var kdj: (k: [Double], d: [Double], j: [Double]) { (series.kdjK, series.kdjD, series.kdjJ) }
    private var rsi6: [Double] { series.rsi6 }
    private var rsi12: [Double] { series.rsi12 }
    private var rsi24: [Double] { series.rsi24 }

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

    // MARK: - 主图价格区间（基于可见窗口）

    private var priceRange: ClosedRange<Double> {
        guard !slice.isEmpty else { return 0...100 }
        var minLow = slice.map(\.low).min() ?? 0
        var maxHigh = slice.map(\.high).max() ?? 100

        let offsets = Array(startIndex...endIndex)
        let allValues = offsets.enumerated().flatMap { localIndex, absIndex -> [Double] in
            let vals: [Double]
            switch mainIndicator {
            case .ma: vals = [ma5[absIndex], ma10[absIndex], ma20[absIndex], ma60[absIndex]]
            case .ema: vals = [ema5[absIndex], ema10[absIndex], ema20[absIndex], ema60[absIndex]]
            case .boll: vals = [bollMid[absIndex], bollUpper[absIndex], bollLower[absIndex]]
            }
            return vals.filter { !$0.isNaN }
        }

        if let minV = allValues.min() { minLow = min(minLow, minV) }
        if let maxV = allValues.max() { maxHigh = max(maxHigh, maxV) }

        let padding = (maxHigh - minLow) * 0.05
        return (minLow - padding)...(maxHigh + padding)
    }

    // MARK: - 成交量

    private var volumeMax: Double {
        let maA = volumeIndicator == .amount ? amoMa5 : volMa5
        let maB = volumeIndicator == .amount ? amoMa10 : volMa10
        let values: [Double] = offsetsMap { index in
            [maA[index], maB[index]].filter { !$0.isNaN }
        }
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
            let legendHeight: CGFloat = 16
            // 每个图表上方各占一行指标栏，其余高度按 52/13/22/13 分配，减少空白
            let chartHeight = max(1, geometry.size.height - 3 * legendHeight)
            let mainHeight = chartHeight * 0.52
            let volumeHeight = chartHeight * 0.13
            let indicatorHeight = chartHeight * 0.22
            let timeHeight = chartHeight * 0.13

            // 各面板的纵向边界（用于手势限制与光标面板判断）
            let mainTop = legendHeight
            let mainBottom = legendHeight + mainHeight
            let volTop = mainBottom + legendHeight
            let volBottom = volTop + volumeHeight
            let indTop = volBottom + legendHeight
            let indBottom = indTop + indicatorHeight

            VStack(spacing: 0) {
                mainLegendRow(height: legendHeight)
                    .zIndex(20)
                mainChart(width: width, candleSpacing: candleSpacing, height: mainHeight, panelTop: mainTop)
                volumeLegendRow(height: legendHeight)
                    .zIndex(20)
                volumeChart(width: width, candleSpacing: candleSpacing, height: volumeHeight,
                            crosshairY: crosshairY, panelTop: volTop)
                indicatorLegendRow(height: legendHeight)
                    .zIndex(20)
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
                    Text("主图左右拖动平移 / 上下滑动缩放 · 双指缩放 · 轻点切换光标")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.85))
                        .cornerRadius(4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
                        .padding(.top, 6)
                        .transition(.opacity)
                }
            }
            .overlay {
                // 横线跟随触摸 Y，仅当落在图表面板内时显示
                if let crosshairY, isInChartPanel(crosshairY, mainTop, mainBottom)
                    || isInChartPanel(crosshairY, volTop, volBottom)
                    || isInChartPanel(crosshairY, indTop, indBottom) {
                    let totalHeight = geometry.size.height
                    let y = min(max(crosshairY, 0), totalHeight)
                    Rectangle().fill(Color.black.opacity(0.35)).frame(width: width, height: 0.5)
                        .position(x: width / 2, y: y)
                }
            }
        }
        .background(Color.white)
    }

    private func isInChartPanel(_ y: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> Bool {
        y >= top && y <= bottom
    }

    /// 任一指标下拉菜单是否打开（打开时禁用图表拖拽手势，避免误触光标）
    private var menuIsOpen: Bool { showMainMenu || showVolumeMenu || showIndicatorMenu }

    // MARK: - 手势

    private func chartDragGesture(candleSpacing: CGFloat,
                                  mainTop: CGFloat, mainBottom: CGFloat,
                                  volTop: CGFloat, volBottom: CGFloat,
                                  indTop: CGFloat, indBottom: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                // 下拉菜单打开时，不响应任何图表手势
                guard !menuIsOpen else { return }
                hasInteracted = true
                let y = value.location.y
                let inMain = isInChartPanel(y, mainTop, mainBottom)
                let inVol = isInChartPanel(y, volTop, volBottom)
                let inInd = isInChartPanel(y, indTop, indBottom)

                // 指标栏、时间轴区域不响应光标/平移/缩放
                guard inMain || inVol || inInd else { return }

                if selectedIndex != nil {
                    // 光标已显示：拖动只移动光标，不平移窗口（任一图表面板均可）
                    let col = Int((value.location.x / candleSpacing).rounded(.down))
                    let idx = startIndex + col
                    if idx >= startIndex && idx <= endIndex {
                        selectedIndex = idx
                        crosshairY = value.location.y
                    }
                    // 只有真正移动超过阈值才算拖动；轻点（无位移）不置位，便于 onEnded 关闭光标
                    if abs(value.translation.width) > 6 || abs(value.translation.height) > 6 {
                        cursorDragging = true
                    }
                } else if inMain && dragMode == .none {
                    // 仅主图内触发平移/缩放：首次判定方向（垂直=缩放，水平=平移）
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
                    // 上下滑动：模拟双指捏合/放开，向上=放大（可见根数减少），向下=缩小
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
                // 下拉菜单打开时，不响应任何图表手势
                guard !menuIsOpen else { cursorDragging = false; return }
                if cursorDragging {
                    // 刚才是拖动着移动光标，保持光标显示
                    cursorDragging = false
                    return
                }
                // 轻点：切换光标（仅限图表面板内）
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

            // 价格坐标（叠加在左侧，半透明不遮挡线条）
            overlayPriceLabels(width: width, height: height, min: priceRange.lowerBound, max: priceRange.upperBound,
                               ratios: [0, 0.25, 0.5, 0.75, 1], format: "%.2f")

            // 最新价标签
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

                // 竖线
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: 0.5, height: height)
                    .position(x: xPosition, y: height / 2)

                // 光标价格标签仅在光标落在主图内时显示
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

    // MARK: - Canvas 绘制

    private func mainCanvas(width: CGFloat, candleSpacing: CGFloat, height: CGFloat) -> some View {
        MainChartCanvas(
            slice: slice, chartStyle: chartStyle, mainIndicator: mainIndicator,
            candleSpacing: candleSpacing, height: height,
            priceMin: priceRange.lowerBound, priceMax: priceRange.upperBound,
            ma5: sliceArr(ma5), ma10: sliceArr(ma10), ma20: sliceArr(ma20), ma60: sliceArr(ma60),
            ema5: sliceArr(ema5), ema10: sliceArr(ema10), ema20: sliceArr(ema20), ema60: sliceArr(ema60),
            bollMid: sliceArr(bollMid), bollUpper: sliceArr(bollUpper), bollLower: sliceArr(bollLower),
            upColor: upColor, downColor: downColor, gridColor: gridColor,
            ma5Color: ma5Color, ma10Color: ma10Color, ma20Color: ma20Color,
            ma60Color: ma60Color, bollColor: Color(red: 0.4, green: 0.4, blue: 0.9)
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

            // 左侧坐标值（最大量/0）
            volumeAxisLabels(width: width, height: height)

            if let selectedIndex, selectedIndex >= startIndex, selectedIndex <= endIndex {
                let xPosition = (CGFloat(selectedIndex - startIndex) + 0.5) * candleSpacing
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: 0.5, height: height)
                    .position(x: xPosition, y: height / 2)

                // 光标值标签仅在光标落在量图内时显示
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

    /// 量图左侧坐标：顶部为最大量，底部为 0
    private func volumeAxisLabels(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(formatVolume(volumeMax))
                .font(.system(size: 9))
                .foregroundColor(axisTextColor)
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
                .background(Color.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            Text("0")
                .font(.system(size: 9))
                .foregroundColor(axisTextColor)
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
                .background(Color.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 4)
        .frame(width: width, height: height)
    }

    // MARK: - 指标幅图

    private func indicatorChart(width: CGFloat, candleSpacing: CGFloat, height: CGFloat,
                                crosshairY: CGFloat?, panelTop: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.white

            indicatorCanvas(width: width, candleSpacing: candleSpacing, height: height)
            indicatorAxisLabels(width: width, height: height)

            // 指标图例已移到独立的指标栏（indicatorLegendRow）

            // 十字光标竖线
            if let selectedIndex, selectedIndex >= startIndex, selectedIndex <= endIndex {
                let xPosition = (CGFloat(selectedIndex - startIndex) + 0.5) * candleSpacing
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: 0.5, height: height)
                    .position(x: xPosition, y: height / 2)

                // 光标值标签仅在光标落在指标图内时显示
                if let crosshairY, crosshairY >= panelTop, crosshairY <= panelTop + height {
                    let localY = min(max(crosshairY - panelTop, 0), height)
                    let range = indicatorRange
                    let value = range.max - (range.max - range.min) * Double(localY / height)
                    let fmt = indicator == .macd ? "%.3f" : "%.0f"
                    Text(String(format: fmt, value))
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

    @ViewBuilder
    private func indicatorAxisLabels(width: CGFloat, height: CGFloat) -> some View {
        let range = indicatorRange
        switch indicator {
        case .macd:
            overlayPriceLabels(width: width, height: height, min: range.min, max: range.max,
                               ratios: [0, 0.5, 1], format: "%.3f")
        case .kdj, .rsi:
            overlayPriceLabels(width: width, height: height, min: range.min, max: range.max,
                               ratios: [0, 0.25, 0.5, 0.75, 1], format: "%.0f")
        }
    }

    /// 副图基于可见窗口的动态坐标范围，保证线条不越界
    private var indicatorRange: (min: Double, max: Double) {
        switch indicator {
        case .macd:
            let m = macdMax
            return (-m, m)
        case .kdj:
            let vals = offsetsMap { [kdj.k[$0], kdj.d[$0], kdj.j[$0]] }
            let lo = vals.min() ?? 0
            let hi = vals.max() ?? 100
            return (min(lo, 0), max(hi, 100))
        case .rsi:
            return (0, 100)
        }
    }

    /// 副图基于可见窗口的动态最大绝对值（MACD）
    private var macdMax: Double {
        let vals: [Double] = offsetsMap { index in
            [dif[index], dea[index], macdHistogram[index]].map { abs($0) }
        }
        let m = vals.max() ?? 1
        return max(m * 1.15, 0.0001)
    }

    // MARK: - 指标栏（独立一行，名称可点击弹下拉菜单）

    private func mainLegendRow(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 10) {
                nameButtonView(title: mainIndicator.rawValue, isOpen: $showMainMenu) {
                    showVolumeMenu = false
                    showIndicatorMenu = false
                }
                switch mainIndicator {
                case .ma:
                    legendItem("MA5", legendValue(ma5), color: ma5Color)
                    legendItem("MA10", legendValue(ma10), color: ma10Color)
                    legendItem("MA20", legendValue(ma20), color: ma20Color)
                    legendItem("MA60", legendValue(ma60), color: ma60Color)
                case .ema:
                    legendItem("EMA5", legendValue(ema5), color: ma5Color)
                    legendItem("EMA10", legendValue(ema10), color: ma10Color)
                    legendItem("EMA20", legendValue(ema20), color: ma20Color)
                    legendItem("EMA60", legendValue(ema60), color: ma60Color)
                case .boll:
                    legendItem("MID", legendValue(bollMid), color: ma10Color)
                    legendItem("UP", legendValue(bollUpper), color: bollColor)
                    legendItem("LOW", legendValue(bollLower), color: bollColor)
                }
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(Color.white)

            if showMainMenu {
                indicatorMenuView(options: MainIndicator.allCases.map { ($0.rawValue, mainIndicator == $0) },
                                  onSelect: { opt in
                    mainIndicator = MainIndicator(rawValue: opt) ?? .ma
                    showMainMenu = false
                })
                .offset(y: height + 2)
                .padding(.leading, 6)
                .transition(.opacity)
            }
        }
        .frame(height: height)
    }

    private func volumeLegendRow(height: CGFloat) -> some View {
        let isAmount = volumeIndicator == .amount
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 8) {
                nameButtonView(title: isAmount ? "AMO" : "VOL", isOpen: $showVolumeMenu) {
                    showMainMenu = false
                    showIndicatorMenu = false
                }
                legendItem("MA5", legendValue(isAmount ? amoMa5 : volMa5), color: ma5Color)
                legendItem("MA10", legendValue(isAmount ? amoMa10 : volMa10), color: ma10Color)
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(Color.white)

            if showVolumeMenu {
                indicatorMenuView(options: VolumeIndicator.allCases.map { ($0.rawValue, volumeIndicator == $0) },
                                  onSelect: { opt in
                    volumeIndicator = VolumeIndicator(rawValue: opt) ?? .volume
                    showVolumeMenu = false
                })
                .offset(y: height + 2)
                .padding(.leading, 6)
                .transition(.opacity)
            }
        }
        .frame(height: height)
    }

    private func indicatorLegendRow(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 8) {
                nameButtonView(title: indicator.rawValue, isOpen: $showIndicatorMenu) {
                    showMainMenu = false
                    showVolumeMenu = false
                }
                switch indicator {
                case .macd:
                    legendItem("DIF", legendValue(dif), color: ma5Color, format: "%.3f")
                    legendItem("DEA", legendValue(dea), color: ma10Color, format: "%.3f")
                    legendItem("MACD", legendValue(macdHistogram), color: ma20Color, format: "%.3f")
                case .kdj:
                    legendItem("K", legendValue(kdj.k), color: ma5Color)
                    legendItem("D", legendValue(kdj.d), color: ma10Color)
                    legendItem("J", legendValue(kdj.j), color: ma20Color)
                case .rsi:
                    legendItem("RSI6", legendValue(rsi6), color: ma5Color)
                    legendItem("RSI12", legendValue(rsi12), color: ma10Color)
                    legendItem("RSI24", legendValue(rsi24), color: ma20Color)
                }
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(Color.white)

            if showIndicatorMenu {
                indicatorMenuView(options: SubIndicator.allCases.map { ($0.rawValue, indicator == $0) },
                                  onSelect: { opt in
                    indicator = SubIndicator(rawValue: opt) ?? .macd
                    showIndicatorMenu = false
                })
                .offset(y: height + 2)
                .padding(.leading, 6)
                .transition(.opacity)
            }
        }
        .frame(height: height)
    }

    /// 指标名称按钮（点击展开下拉菜单）
    private func nameButtonView(title: String, isOpen: Binding<Bool>, onTap: @escaping () -> Void) -> some View {
        Button {
            withAnimation { isOpen.wrappedValue.toggle(); onTap() }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.gray.opacity(0.12))
            .cornerRadius(4)
        }
    }

    /// 下拉菜单
    private func indicatorMenuView(options: [(String, Bool)], onSelect: @escaping (String) -> Void) -> some View {
        VStack(spacing: 0) {
            ForEach(options, id: \.0) { opt in
                Button {
                    onSelect(opt.0)
                } label: {
                    HStack {
                        Text(opt.0)
                            .font(.system(size: 11))
                        Spacer()
                        if opt.1 {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10))
                                .foregroundColor(.blue)
                        }
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
            }
        }
        .background(Color.white)
        .cornerRadius(6)
        .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
    }

    private func indicatorCanvas(width: CGFloat, candleSpacing: CGFloat, height: CGFloat) -> some View {
        let range = indicatorRange
        return IndicatorChartCanvas(
            indicator: indicator,
            candleSpacing: candleSpacing, height: height,
            dif: sliceArr(dif), dea: sliceArr(dea), macdHist: sliceArr(macdHistogram),
            kdjK: sliceArr(kdj.k), kdjD: sliceArr(kdj.d), kdjJ: sliceArr(kdj.j),
            rsi6: sliceArr(rsi6), rsi12: sliceArr(rsi12), rsi24: sliceArr(rsi24),
            rangeMin: range.min, rangeMax: range.max,
            upColor: upColor, downColor: downColor, gridColor: gridColor,
            ma5Color: ma5Color, ma10Color: ma10Color, ma20Color: ma20Color
        )
        .equatable()
    }

    // MARK: - 时间轴

    private func timeAxis(width: CGFloat, candleSpacing: CGFloat, height: CGFloat) -> some View {
        let left = sortedData[startIndex].formattedDate
        let right = sortedData[endIndex].formattedDate
        return ZStack {
            HStack(spacing: 0) {
                Text(left)
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                // 最左日期右侧追加三个空格的间距，再显示当前可见 K 线周期数
                Text("   周期数\(count)个")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                Spacer()
            }
            Text(right)
                .font(.system(size: 9))
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: width, height: height)
        .background(Color.white)
    }

    // MARK: - 通用绘制辅助

    /// 叠加在图表右侧的价格标签（不单独占列）
    private func overlayPriceLabels(width: CGFloat, height: CGFloat, min: Double, max: Double, ratios: [CGFloat], format: String) -> some View {
        ZStack {
            ForEach(ratios, id: \.self) { ratio in
                let value = max - (max - min) * Double(ratio)
                Text(String(format: format, value))
                    .font(.system(size: 9))
                    .foregroundColor(axisTextColor)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                    // 半透明背景，避免遮挡指标线条
                    .background(Color.white.opacity(0.55))
                    // 顶/底标签向内偏移半个标签高，避免被面板边界裁掉一半
                    .position(x: 22, y: clampedAxisY(height * CGFloat(ratio), in: height))
            }
        }
        .frame(width: width, height: height)
    }

    /// 让标签 Y 始终落在面板内，保证顶/底标签完整显示
    private func clampedAxisY(_ y: CGFloat, in height: CGFloat) -> CGFloat {
        let half: CGFloat = 8
        return min(max(y, half), max(half, height - half))
    }

    private func legendItem(_ name: String, _ value: Double?, color: Color, format: String = "%.2f") -> some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(name).font(.system(size: 9)).foregroundColor(.gray)
            if let value, !value.isNaN {
                Text(String(format: format, value))
                    .font(.system(size: 9)).foregroundColor(color)
            }
        }
    }

    // MARK: - 十字光标信息面板

    private func infoPanel(index: Int, item: KlineItem) -> some View {
        // 涨跌额 = 收盘 - 前收盘
        let changeAmount = prevClose(of: index) > 0 ? item.close - prevClose(of: index) : 0
        let changeColor: Color = changeAmount >= 0 ? upColor : downColor

        return VStack(alignment: .leading, spacing: 2) {
            Text(item.formattedDateWithWeekday)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.black)

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
        .background(Color.white.opacity(0.92))
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
    }

    private func prevClose(of index: Int) -> Double {
        guard index > 0, index < sortedData.count else {
            return index < sortedData.count ? sortedData[index].close : 0
        }
        return sortedData[index - 1].close
    }

    private func kv(_ title: String, _ value: Double, _ color: Color) -> some View {
        valuePill(title, value, color)
    }

    private func valuePill(_ title: String, _ value: Double?, _ color: Color, format: String = "%.2f") -> some View {
        HStack(spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundColor(.gray)
            if let value, !value.isNaN {
                Text(String(format: format, value)).font(.system(size: 9)).foregroundColor(color)
            }
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

// MARK: - 主图 Canvas（Equatable，光标拖动时不重绘）

struct MainChartCanvas: View, Equatable {
    let slice: [KlineItem]
    let chartStyle: ChartStyle
    let mainIndicator: MainIndicator
    let candleSpacing: CGFloat
    let height: CGFloat
    let priceMin: Double
    let priceMax: Double
    let ma5, ma10, ma20, ma60: [Double]
    let ema5, ema10, ema20, ema60: [Double]
    let bollMid, bollUpper, bollLower: [Double]
    let upColor, downColor, gridColor, ma5Color, ma10Color, ma20Color, ma60Color, bollColor: Color

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height

            for ratio: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                let y = h * ratio
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
            }
            for i in 0..<8 {
                let x = w * CGFloat(i) / 8
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
            }

            let candleWidth = max(1.5, candleSpacing * 0.7)

            switch chartStyle {
            case .kline:
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
                    ctx.fill(Path(rect), with: .color(color))
                }
            case .close:
                strokeLine(ctx, values: slice.map(\.close), color: Color(red: 0.2, green: 0.4, blue: 0.9), h: h)
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
                    var op = Path()
                    op.move(to: CGPoint(x: x - candleSpacing * 0.18, y: oy)); op.addLine(to: CGPoint(x: x, y: oy))
                    ctx.stroke(op, with: .color(color), lineWidth: 1)
                    let cy = yPos(item.close, h: h)
                    var cl = Path()
                    cl.move(to: CGPoint(x: x, y: cy)); cl.addLine(to: CGPoint(x: x + candleSpacing * 0.18, y: cy))
                    ctx.stroke(cl, with: .color(color), lineWidth: 1)
                }
            }

            switch mainIndicator {
            case .ma:
                strokeLine(ctx, values: ma5, color: ma5Color, h: h)
                strokeLine(ctx, values: ma10, color: ma10Color, h: h)
                strokeLine(ctx, values: ma20, color: ma20Color, h: h)
                strokeLine(ctx, values: ma60, color: ma60Color, h: h)
            case .ema:
                strokeLine(ctx, values: ema5, color: ma5Color, h: h)
                strokeLine(ctx, values: ema10, color: ma10Color, h: h)
                strokeLine(ctx, values: ema20, color: ma20Color, h: h)
                strokeLine(ctx, values: ema60, color: ma60Color, h: h)
            case .boll:
                strokeLine(ctx, values: bollMid, color: ma10Color, h: h)
                strokeLine(ctx, values: bollUpper, color: bollColor, h: h)
                strokeLine(ctx, values: bollLower, color: bollColor, h: h)
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

    private func yPos(_ v: Double, h: CGFloat) -> CGFloat {
        let range = priceMax - priceMin
        guard range > 0 else { return h }
        return h * CGFloat(1 - (v - priceMin) / range)
    }

    private func strokeLine(_ ctx: GraphicsContext, values: [Double], color: Color, h: CGFloat) {
        var path = Path()
        var started = false
        for (i, v) in values.enumerated() {
            guard !v.isNaN else { continue }
            let x = (CGFloat(i) + 0.5) * candleSpacing
            let y = yPos(v, h: h)
            if started { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)); started = true }
        }
        ctx.stroke(path, with: .color(color), lineWidth: 1)
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
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
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

// MARK: - 指标 Canvas

struct IndicatorChartCanvas: View, Equatable {
    let indicator: SubIndicator
    let candleSpacing: CGFloat
    let height: CGFloat
    let dif, dea, macdHist: [Double]
    let kdjK, kdjD, kdjJ: [Double]
    let rsi6, rsi12, rsi24: [Double]
    let rangeMin: Double
    let rangeMax: Double
    let upColor, downColor, gridColor, ma5Color, ma10Color, ma20Color: Color

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height

            switch indicator {
            case .macd:
                for ratio: CGFloat in [0, 0.5, 1] {
                    let y = h * ratio
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                    ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
                }
                var zero = Path()
                zero.move(to: CGPoint(x: 0, y: h / 2)); zero.addLine(to: CGPoint(x: w, y: h / 2))
                ctx.stroke(zero, with: .color(Color.black.opacity(0.4)), lineWidth: 0.5)
                // 以动态范围的最大绝对值作为柱的满刻度
                let half = max(abs(rangeMin), abs(rangeMax))
                let barWidth = max(1.5, candleSpacing * 0.7)
                for (li, value) in macdHist.enumerated() {
                    let x = (CGFloat(li) + 0.5) * candleSpacing
                    let barHeight = half > 0 ? abs(value) / half * (h / 2) : 0
                    let color = value >= 0 ? upColor.opacity(0.8) : downColor.opacity(0.8)
                    // 柱子从 0 轴（中心线）开始，正值向上、负值向下生长，而不是以 0 轴为中心居中
                    let topY = value >= 0 ? (h / 2 - barHeight) : h / 2
                    let rect = CGRect(x: x - barWidth / 2, y: topY, width: barWidth, height: max(0.5, barHeight))
                    ctx.fill(Path(rect), with: .color(color))
                }
                strokeLine(ctx, values: dif, color: ma5Color, h: h, lo: rangeMin, hi: rangeMax)
                strokeLine(ctx, values: dea, color: ma10Color, h: h, lo: rangeMin, hi: rangeMax)
            case .kdj:
                drawOscillator(ctx, w: w, h: h, lines: [kdjK, kdjD, kdjJ], colors: [ma5Color, ma10Color, ma20Color])
            case .rsi:
                drawOscillator(ctx, w: w, h: h, lines: [rsi6, rsi12, rsi24], colors: [ma5Color, ma10Color, ma20Color])
            }
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

    private func drawOscillator(_ ctx: GraphicsContext, w: CGFloat, h: CGFloat, lines: [[Double]], colors: [Color]) {
        for ratio: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            let y = h * ratio
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
            ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
        }
        for ref: Double in [20, 80] {
            let y = yPos(ref, h: h, lo: rangeMin, hi: rangeMax)
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
            ctx.stroke(p, with: .color(Color.gray.opacity(0.4)), lineWidth: 0.5)
        }
        for (idx, values) in lines.enumerated() {
            strokeLine(ctx, values: values, color: colors[idx], h: h, lo: rangeMin, hi: rangeMax)
        }
    }
}
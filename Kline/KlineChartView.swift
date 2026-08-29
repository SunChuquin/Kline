//
//  KlineChartView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/8/5.
//

import SwiftUI
import Combine
import UIKit

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
    case wmacd = "WMACD"
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

/// 副图左右滑动切换的拖动反馈动画状态
struct SwipeFeedback: Equatable {
    let slot: SubSlot
    var offset: CGFloat      // 当前横向位移（右正左负）
    let canLeft: Bool        // 左滑方向是否可切换
    let canRight: Bool       // 右滑方向是否可切换
}

/// 区间统计可拖动的边界（起点/终点）
enum StatsEdge: Equatable {
    case start, end
}

/// 公式编辑器针对的目标图表
enum EditorTarget {
    case main, sub
}

/// 副图槽位（第1/第2/第3个副图）
enum SubSlot: Hashable {
    case top, bottom, third
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
    @Published var showCMK = true
    @Published var showSAR = false
    // 当前行情周期（跨页面/跨标的持久，返回行情再进入时保持上次选择）
    @Published var selectedPeriod: KlinePeriod = .daily
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
    // 主图镜像（空）：开启后主图图形取负镜像
    @Published var mainMirrored = false

    // 三个副图（跨页面保留同一实例，避免重建）
    let subTop = SubChartModel()
    let subBottom = SubChartModel()
    let subThird = SubChartModel()

    private init() {
        subTop.kind = .cdj
        subTop.resetParams()
        subBottom.kind = .col
        subBottom.resetParams()
        subThird.kind = .macd
        subThird.resetParams()
    }
}

struct BOLLConfig: Equatable {
    var period: Int = 20
    var mult: Double = 2
}

// MARK: - 通用指标线

struct IndicatorLine: Equatable {
    let name: String
    var values: [Double]
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

// MARK: - 后台预计算（分块向历史扩展指标覆盖区间）

/// 预计算每块的指标计算请求（主线程构造，Sendable，可跨线程传给后台求值）
struct PrefetchCalcRequest {
    let calcStart: Int
    let calcEnd: Int
    let data: [KlineItem]        // 裁剪区间数据
    let volumes: [Double]        // 裁剪区间成交量
    let turnovers: [Double]      // 裁剪区间成交额
    /// 主图公式文本（仅启用的指标，按固定顺序；空串表示未启用/无自定义指标）
    let mainFormulas: [String]
    /// 副图请求（3 个，与 subTop/subBottom/subThird 对应）
    let subs: [SubPrefetchRequest]
}

struct SubPrefetchRequest {
    let kind: SubChartKind
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
    let colors = [Color.black.opacity(0.75), Color.orange, Color.pink, Color.blue,
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

private func prefetchAllNaN(_ values: [Double]) -> Bool { values.allSatisfy { $0.isNaN } }

private func prefetchLineColor(from line: TDXOutputLine, fallback: Color) -> Color {
    if let hex = line.colorHex, let c = Color(hex: hex) { return c }
    return fallback
}

private func prefetchFmt(_ v: Double) -> String { String(format: "%g", v) }

private func prefetchStringParams(_ params: [String: Int]) -> [String: String] {
    var d: [String: String] = [:]
    for (k, v) in params { d[k] = "\(v)" }
    return d
}

private func prefetchSourceValue(_ s: MAValueSource) -> Int {
    switch s {
    case .close: return 1
    case .open: return 2
    case .high: return 3
    case .low: return 4
    case .avg: return 5
    }
}

private func prefetchMainMAValues(periods: [Int], sources: [MAValueSource]) -> [String: String] {
    var d: [String: String] = [:]
    for i in 0..<8 {
        let p = periods.indices.contains(i) ? periods[i] : 0
        let src = sources.indices.contains(i) ? sources[i] : .close
        d["p\(i + 1)"] = "\(p)"
        d["src\(i + 1)"] = "\(prefetchSourceValue(src))"
    }
    return d
}

private func prefetchMainMAValues(_ cfg: MAConfig) -> [String: String] {
    prefetchMainMAValues(periods: cfg.periods, sources: cfg.sources)
}

private func prefetchMainBOLLValues() -> [String: String] {
    let config = ChartConfigStore.shared
    return ["period": "\(config.bollConfig.period)", "mult": prefetchFmt(config.bollConfig.mult)]
}

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
    var ma = UnitSet()
    var ema = UnitSet()
    var boll = UnitSet()
    var cmk = UnitSet()
    var sar = UnitSet()
    var custom = UnitSet()
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
    /// 副图镜像（空）：开启后本副图图形取负镜像；VOL/AMO 不支持
    @Published var mirrored = false

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

    /// WMACD（空头视角 MACD）：DIF 改为 慢周期 EMA - 快周期 EMA，其余同 MACD
    static func wmacd(values: [Double], fast: Int, slow: Int, signal: Int) -> (dif: [Double], dea: [Double], hist: [Double]) {
        let dif = zip(ema(values: values, period: slow), ema(values: values, period: fast)).map { $0 - $1 }
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
    /// 当前标的 ID（用于按 (标的, 周期) 读写指标计算缓存；nil 时不使用缓存）
    let metaId: Int?
    /// 当前行情周期（用于主图指标名称按钮显示 "日线: MA" 之类前缀）
    let period: KlinePeriod
    /// 第一副图左右滑动切换周期（传入更大/更小级别周期，由外层决定是否应用）
    let onPeriodSwitch: ((KlinePeriod) -> Void)?
    /// 当前周期后台预计算全部完成后的回调（用于外层继续预计算其它未计算周期）
    let onPeriodPrefetched: ((KlinePeriod) -> Void)?
    /// 第二副图左右滑动切换标的（dir = -1 上一个 / +1 下一个）
    let onSwitchItem: ((Int) -> Void)?
    /// 第二副图某方向是否可切换标的（dir = -1 上一个 / +1 下一个），用于滑动提示
    let canSwitchItem: ((Int) -> Bool)?
    /// 📌 固定光标模式开关（由详情页顶部按钮持有；开启时固定第一个光标，点击切换第二个光标）
    @Binding var pinEnabled: Bool
    /// 是否有任意光标在屏幕上（供详情页控制 📌 按钮可点/高亮）
    let onHasCursorChange: ((Bool) -> Void)?
    @Binding var chartStyle: ChartStyle
    @Binding var displaySettings: ChartDisplaySettings

    // 交互状态
    @State private var selectedIndex: Int? = nil
    /// 📌 开启时固定下来的第一个光标（不可被点击清除；只随 pinEnabled 关闭而清除）
    @State private var pinnedIndex: Int? = nil
    @State private var pinnedY: CGFloat? = nil
    /// 固定光标固定时刻的横轴价格（仅主图区域有效）：平移/缩放后横轴价格不随可见窗口价格范围变化
    @State private var pinnedPrice: Double? = nil
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
    /// 副图左右滑动切换的拖动反馈动画状态（nil = 未在拖动副图）
    @State private var swipeFeedback: SwipeFeedback? = nil
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
    /// 主图各指标结果缓存（class 引用，修改内部属性不触发重绘；周期/标的切换重建页面时自动重置）
    @State private var mainCache = MainIndicatorCache()
    /// 主图放大模式：隐藏三个副图 K 线区域（副图名称/指标栏保留并挤到最下方），主图占满剩余空间
    @State private var mainFullscreen = false
    /// 指标已计算的覆盖区间（绝对索引，随滑动/缩放单调扩展）：
    /// 左右滑动时，只要可见窗口仍落在已覆盖范围内就复用曲线不重算，保证"已经计算过的部分不丢失"。
    /// 覆盖区间跨度超上限时（超大幅滑动）重置为当前需要区间，避免退化为全量计算
    @State private var indicatorCoverageStart = 0
    @State private var indicatorCoverageEnd = -1
    /// 指标覆盖区间最大跨度：防止一次滑到很老的历史后覆盖区间扩展到全量
    private let maxCoverageSpan = 2000
    /// 历史指标预计算任务 token（nil = 无任务）：打开标的后分块向更久远历史预计算指标，
    /// 切换周期/标的/指标或用户交互时更新使其失效
    @State private var prefetchToken: UUID? = nil
    /// 后台正确计算的覆盖末端（绝对索引）：从数据开头（最左）向右逐块推进，
    /// 保证 EMA/SMA 等递归指标从第一根开始累积、数值最正确；覆盖到可见窗口末端后才替换前台近似结果
    @State private var bgCoverageEnd = 0
    /// 预计算每块向右推进的根数（单块毫秒级，块间让出主线程，不阻塞 UI）
    private let prefetchBlockSize = 500

    // 三个副图（同一实例跨页面复用，配置不重置）
    @ObservedObject private var subTop: SubChartModel
    @ObservedObject private var subBottom: SubChartModel
    @ObservedObject private var subThird: SubChartModel

    /// 自定义指标公式编辑器是否打开（由详情页持有状态，打开时隐藏顶部栏实现真全屏）
    @Binding var showCustomEditor: Bool
    @State private var editorTarget: EditorTarget = .main
    /// 系统指标参数编辑页目标（与选择指标页同尺寸的底部面板，非全屏）
    @State private var paramEditorTarget: ParamEditorTarget? = nil
    /// 指标/设置面板打开期间挂起指标重算：分别记录"主图 / 具体副图"哪些需要重算，
    /// 关闭返回 K 线页时只重算被改动的对象，避免把未修改的指标也全量重算
    @State private var pendingMainRefresh = false
    @State private var pendingSubCharts: [SubChartModel] = []

    // 基础序列一次性缓存（供指标按需计算复用，避免拖拽/重算时反复整表 map）
    private let sortedAll: [KlineItem]
    private let baseCloses, baseHighs, baseLows, baseOpens, baseVolumes, baseTurnovers: [Double]

    init(series: ChartSeries, chartStyle: Binding<ChartStyle>,
         displaySettings: Binding<ChartDisplaySettings> = .constant(ChartDisplaySettings()),
         showCustomEditor: Binding<Bool> = .constant(false),
         metaId: Int? = nil,
         period: KlinePeriod = .daily,
         onPeriodSwitch: ((KlinePeriod) -> Void)? = nil,
         onPeriodPrefetched: ((KlinePeriod) -> Void)? = nil,
         onSwitchItem: ((Int) -> Void)? = nil,
         canSwitchItem: ((Int) -> Bool)? = nil,
         pinEnabled: Binding<Bool> = .constant(false),
         onHasCursorChange: ((Bool) -> Void)? = nil) {
        self.series = series
        self.metaId = metaId
        self.period = period
        self.onPeriodSwitch = onPeriodSwitch
        self.onPeriodPrefetched = onPeriodPrefetched
        self.onSwitchItem = onSwitchItem
        self.canSwitchItem = canSwitchItem
        self._pinEnabled = pinEnabled
        self.onHasCursorChange = onHasCursorChange
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
        self._subThird = ObservedObject(wrappedValue: store.subThird)
        // 同一标的内切换周期：从 (标的, 周期) 缓存恢复上次的计算结果与覆盖状态，
        // 保证切回该周期时已算过的部分不重算、不丢失（LRU 保留最近 3 个标的的所有周期）。
        // 仅当缓存所用指标配置指纹与当前一致时才恢复，否则视为无效、按新配置重新计算
        if let metaId {
            let entry = ChartCacheStore.shared.entry(for: metaId, period: period)
            let fingerprint = Self.currentConfigFingerprint()
            if entry.configFingerprint == fingerprint {
                _mainCurves = State(initialValue: entry.mainCurves)
                _mainCache = State(initialValue: entry.mainCache)
                _indicatorCoverageStart = State(initialValue: entry.coverageStart)
                _indicatorCoverageEnd = State(initialValue: entry.coverageEnd)
                _bgCoverageEnd = State(initialValue: entry.bgCoverageEnd)
            }
            if entry.configFingerprint == fingerprint {
                let subs = [store.subTop, store.subBottom, store.subThird]
                for (i, m) in subs.enumerated() {
                    if let curves = entry.subCurves[i], !curves.isEmpty {
                        m.curves = curves
                    } else {
                        // 缓存无该槽位曲线（如配置变更后缓存被清空）：清掉共享模型里
                        // 其它周期（如周线）残留的旧曲线，避免 recomputeSub 误判为已算好而跳过重算
                        m.curves = []
                    }
                }
            }
        }
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

    private var count: Int { min(max(20, Int(visibleCount.rounded())), capVisibleCount) }
    private var maxVisibleCount: Int { sortedData.count }
    /// 非放大模式下屏幕最多显示的 K 线数（放大模式下才允许显示全部）
    private let normalMaxVisible = 250
    /// 当前可用的最大可见 K 线数：放大模式显示全部，非放大模式最多 250 根
    private var capVisibleCount: Int { mainFullscreen ? maxVisibleCount : min(maxVisibleCount, normalMaxVisible) }
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

    // MARK: - 镜像（多/空）

    /// 主图是否开启空头镜像（纯取负）
    private var mainMirrored: Bool { config.mainMirrored }

    /// 取负：主图开启镜像时把数值取负
    private func mir(_ v: Double) -> Double { mainMirrored ? -v : v }

    /// 可见窗口曲线的取负版本（用于画布），未镜像时原样返回
    private func mirroredSliceArr(_ values: [Double]) -> [Double] {
        let s = sliceArr(values)
        guard mainMirrored else { return s }
        return s.map { -$0 }
    }

    /// 副图可见窗口曲线的取负版本（副图开启镜像时）
    private func subMirroredSliceArr(_ m: SubChartModel, _ values: [Double]) -> [Double] {
        let s = sliceArr(values)
        guard m.mirrored else { return s }
        return s.map { -$0 }
    }

    /// 镜像后的可见 K 线（OHLC 取负；日期/量额不变，仅供画布绘制）
    private var mirroredSlice: [KlineItem] {
        guard mainMirrored else { return slice }
        return slice.map { it in
            KlineItem(date: it.date, open: -it.open, high: -it.high, low: -it.low,
                      close: -it.close, volume: it.volume, turnover: it.turnover)
        }
    }

    /// 镜像后的跳空缺口（top/bottom 取负）
    private var mirroredGaps: [GapInfo] {
        guard mainMirrored else { return gaps }
        return gaps.map { g in GapInfo(startIdx: g.startIdx, top: -g.top, bottom: -g.bottom, isUp: g.isUp, filledIdx: g.filledIdx) }
    }

    /// 镜像后的最新一根 K 线（最新价线用）
    private var mirroredLatest: KlineItem? {
        guard mainMirrored, let last = sortedAll.last else { return sortedAll.last }
        return KlineItem(date: last.date, open: -last.open, high: -last.high, low: -last.low,
                         close: -last.close, volume: last.volume, turnover: last.turnover)
    }

    /// 主图价格范围：开启镜像时取负（数值与坐标标签都会镜像为负）
    private func mirroredRange(_ r: ClosedRange<Double>) -> ClosedRange<Double> {
        guard mainMirrored else { return r }
        return (-r.upperBound)...(-r.lowerBound)
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

    /// 主图是否裸K：用户手动设置 或 主图放大模式（全屏裸K，不计算任何指标）
    private var isBareK: Bool { config.showBareK || mainFullscreen }

    // MARK: - 指标计算区间（裁剪）

    /// 指标预热长度：往前多算这一段历史，保证 MA（需前 N 根）与 EMA/SMA 等递归指标
    /// 在可见窗口内已收敛、数值准确；也避免每次拖动/缩放后全量重算
    private let indicatorWarmup = 500
    /// 指标计算区间的起点索引（绝对，需要区间）：可见窗口起点往前推预热长度，最小为 0
    private var indicatorCalcStart: Int { max(0, startIndex - indicatorWarmup) }
    /// 指标计算区间的终点索引（绝对，需要区间）：覆盖到可见窗口末端即可
    private var indicatorCalcEnd: Int { max(indicatorCalcStart, endIndex) }

    /// 本次指标计算区间：与已覆盖区间合并（只扩不缩），并更新覆盖状态。
    /// 可见窗口落在已覆盖范围内时直接复用已覆盖区间 → 缓存键不变 → 不重算、不倒退；
    /// 需要区间超出已覆盖且扩展后跨度超上限时保持已覆盖区间，避免丢弃已算的全量历史
    private func mergedCalcRange(needStart: Int, needEnd: Int) -> (start: Int, end: Int) {
        if indicatorCoverageEnd >= 0 {
            // 需要区间完全落在已覆盖范围内：直接复用已覆盖区间（不重算、不倒退）
            if needStart >= indicatorCoverageStart && needEnd <= indicatorCoverageEnd {
                return (indicatorCoverageStart, indicatorCoverageEnd)
            }
            // 需要区间超出已覆盖：尝试扩展（只扩不缩）；扩展后跨度超上限时保持已覆盖区间
            let mergedStart = min(indicatorCoverageStart, needStart)
            let mergedEnd = max(indicatorCoverageEnd, needEnd)
            if mergedEnd - mergedStart + 1 <= maxCoverageSpan {
                indicatorCoverageStart = mergedStart
                indicatorCoverageEnd = mergedEnd
                return (mergedStart, mergedEnd)
            }
            return (indicatorCoverageStart, indicatorCoverageEnd)
        }
        indicatorCoverageStart = needStart
        indicatorCoverageEnd = needEnd
        return (needStart, needEnd)
    }

    /// 取 [start...end] 一段作为指标计算数据（越界/空数据安全）
    private func calcData(from start: Int, to end: Int) -> [KlineItem] {
        guard !sortedData.isEmpty, start <= end, end < sortedData.count else { return [] }
        return Array(sortedData[start...end])
    }

    /// 把「裁剪区间」的计算结果填充回全量长度：前段/后段用 NaN 占位（markerColors 用透明色占位），
    /// 绘制与取值处本就跳过 NaN，因此既有索引逻辑保持不变，只是计算量大幅下降
    private func padToFull(_ line: IndicatorLine, calcStart: Int, calcEnd: Int) -> IndicatorLine {
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

    private func recomputeMainCurves(force: Bool = false) {
        // 指标/设置面板打开期间不计算（全量计算开销大），只标记主图待重算，关闭返回后再算
        if menuIsOpen { pendingMainRefresh = true; return }
        // 拖拽期间禁止任何指标重算（重算随总 K 数线性增长，是拖拽卡顿根源）；
        // force=true 用于用户显式切换/修改指标，确保立即生效
        if !force, drag.isDragging { drag.needsRefreshAfterDrag = true; return }
        // 主图放大（全屏裸K）：不计算任何主图指标
        if mainFullscreen { mainCurves = []; return }
        // 后台正确计算已覆盖整个可见窗口（从数据开头起算，数值最正确）：
        // 未强制重算时直接复用后台结果；指标配置变化（force）时用正确覆盖区间重算，避免退化为近似
        let bgCovered = bgCoverageEnd >= endIndex
        if bgCovered, !force, !mainCurves.isEmpty { return }
        var curves: [IndicatorLine] = []
        if !config.showBareK {
            let store = SystemIndicatorStore.shared
            let custom = activeCustomIndicator
            // 计算区间：后台已覆盖窗口时用后台正确覆盖 [0...bgCoverageEnd]，否则前台近似（窗口+预热，合并已算区间）
            let (calcStart, calcEnd) = bgCovered
                ? (0, bgCoverageEnd)
                : mergedCalcRange(needStart: indicatorCalcStart, needEnd: indicatorCalcEnd)

            // 每个指标按「输出行」缓存：仅该行公式文本（含参数）变化才重算那一行，其余行复用缓存

            curves += mainRows(&mainCache.ma, enabled: config.showMA,
                               formula: store.formula(for: "MA", values: mainMAValues(config.maConfig)),
                               calcStart: calcStart, calcEnd: calcEnd,
                               build: { i, out in
                                   IndicatorLine(name: displayName(out.name), values: out.values,
                                                 color: lineColor(from: out, fallback: maColor(i)),
                                                 style: out.style, lineWidth: out.lineWidth, hideValue: out.hideValue)
                               })
            curves += mainRows(&mainCache.ema, enabled: config.showEMA,
                               formula: store.formula(for: "EMA", values: mainMAValues(periods: config.emaConfig.periods, sources: config.emaConfig.sources)),
                               calcStart: calcStart, calcEnd: calcEnd,
                               build: { i, out in
                                   IndicatorLine(name: displayName(out.name), values: out.values,
                                                 color: lineColor(from: out, fallback: maColor(i)),
                                                 style: out.style, lineWidth: out.lineWidth, hideValue: out.hideValue)
                               })
            curves += mainRows(&mainCache.boll, enabled: config.showBOLL,
                               formula: store.formula(for: "BOLL", values: mainBOLLValues()),
                               calcStart: calcStart, calcEnd: calcEnd,
                               build: { i, out in
                                   IndicatorLine(name: displayName(out.name), values: out.values,
                                                 color: lineColor(from: out, fallback: i == 0 ? ma10Color : bollColor),
                                                 style: out.style, lineWidth: out.lineWidth, hideValue: out.hideValue)
                               })
            curves += mainRows(&mainCache.cmk, enabled: config.showCMK,
                               formula: store.formula(for: "CMK", values: ["cmkN": "\(config.cmkN)"]),
                               calcStart: calcStart, calcEnd: calcEnd,
                               build: { i, out in
                                   IndicatorLine(name: displayName(out.name), values: out.values,
                                                 color: lineColor(from: out, fallback: maColor(i)),
                                                 style: out.style, lineWidth: out.lineWidth, hideValue: out.hideValue)
                               })
            // SAR：红绿点（方向由公式引擎的 SAR 函数提供）
            curves += mainRows(&mainCache.sar, enabled: config.showSAR,
                               formula: store.formula(for: "SAR", values: [
                                   "step": fmt(config.sarStep), "maxstep": fmt(config.sarMax)
                               ]),
                               calcStart: calcStart, calcEnd: calcEnd,
                               build: { _, out in
                                   IndicatorLine(name: "SAR", values: out.values, color: upColor,
                                                 style: .pointdot, lineWidth: 1, hideValue: false,
                                                 markerColors: out.markerDirections?.map { $0 ? upColor : downColor })
                               })
            // 自定义指标（切换或公式/颜色编辑后重算）
            if let custom {
                curves += mainRows(&mainCache.custom, enabled: true,
                                   formula: custom.formula,
                                   calcStart: calcStart, calcEnd: calcEnd,
                                   build: { i, out in
                                       IndicatorLine(name: displayName(out.name), values: out.values,
                                                     color: customLineColor(i, line: out, indicatorColor: custom.color),
                                                     style: out.style, lineWidth: out.lineWidth, hideValue: out.hideValue)
                                   })
            } else {
                mainCache.custom = MainIndicatorCache.UnitSet()
            }
        } else {
            // 裸K：不显示指标，清空自定义缓存（其余指标缓存保留，切回裸K时复用）
            mainCache.custom = MainIndicatorCache.UnitSet()
        }
        mainCurves = curves
        // 写回 (标的, 周期) 缓存：切走再回来时恢复主图曲线与覆盖状态，不重复计算
        if let metaId = metaId {
            let store = ChartCacheStore.shared
            let fp = Self.currentConfigFingerprint()
            // 配置已变：先失效旧缓存（清完成标记/覆盖/曲线），避免旧配置的“已完成”被误用
            if store.invalidateIfConfigChanged(metaId: metaId, period: period, currentFingerprint: fp) {
                // 本视图预计算进度也归零，避免写回 max 把缓存覆盖末端顶回旧值（否则恢复后 bgCovered 误判、副图空白）
                bgCoverageEnd = 0
            }
            let e = store.entry(for: metaId, period: period)
            e.mainCurves = mainCurves
            e.mainCache = mainCache
            e.coverageStart = indicatorCoverageStart
            e.coverageEnd = indicatorCoverageEnd
            // 覆盖末端只增不减，避免后台/旧任务已算得更远时被本次写回往回推
            e.bgCoverageEnd = max(e.bgCoverageEnd, bgCoverageEnd)
            e.configFingerprint = fp
        }
    }

    /// 主图单指标按「输出行」缓存求值：仅某行单元文本（含参数）变化才重算该行，其余行复用缓存。
    /// 计算使用「裁剪区间」数据（可见窗口+预热），计算量≈可见窗口+预热，与总 K 数无关
    private func mainRows(_ cache: inout MainIndicatorCache.UnitSet,
                          enabled: Bool,
                          formula: String?,
                          calcStart: Int, calcEnd: Int,
                          build: (Int, TDXOutputLine) -> IndicatorLine?) -> [IndicatorLine] {
        guard enabled, let formula else { return [] }
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
        return lines
    }

    /// 主图 MA/EMA 参数（周期与数据源）
    private func mainMAValues(_ cfg: MAConfig) -> [String: String] {
        mainMAValues(periods: cfg.periods, sources: cfg.sources)
    }

    private func mainMAValues(periods: [Int], sources: [MAValueSource]) -> [String: String] {
        var d: [String: String] = [:]
        for i in 0..<8 {
            let p = periods.indices.contains(i) ? periods[i] : 0
            let src = sources.indices.contains(i) ? sources[i] : .close
            d["p\(i + 1)"] = "\(p)"
            d["src\(i + 1)"] = "\(sourceValue(src))"
        }
        return d
    }

    private func mainBOLLValues() -> [String: String] {
        ["period": "\(config.bollConfig.period)", "mult": fmt(config.bollConfig.mult)]
    }

    /// 数据源 → 公式参数值（1=收盘 2=开盘 3=最高 4=最低 5=平均值）
    private func sourceValue(_ s: MAValueSource) -> Int {
        switch s {
        case .close: return 1
        case .open: return 2
        case .high: return 3
        case .low: return 4
        case .avg: return 5
        }
    }

    /// Double 转公式常量字符串（去除多余尾零）
    private func fmt(_ v: Double) -> String { String(format: "%g", v) }

    /// 参数字典 Int → String
    private func stringParams(_ params: [String: Int]) -> [String: String] {
        var d: [String: String] = [:]
        for (k, v) in params { d[k] = "\(v)" }
        return d
    }

    /// 整行是否全为 NaN（周期为 0 的 MA 行等）
    private func allNaN(_ values: [Double]) -> Bool { values.allSatisfy { $0.isNaN } }

    /// 公式输出行颜色：优先公式 COLORXXX，否则用默认配色
    private func lineColor(from line: TDXOutputLine, fallback: Color) -> Color {
        if let hex = line.colorHex, let c = Color(hex: hex) { return c }
        return fallback
    }

    private func recomputeSub(_ m: SubChartModel, force: Bool = false) {
        // 指标/设置面板打开期间不计算（全量计算开销大），只标记该副图待重算，关闭返回后再算
        if menuIsOpen {
            if !pendingSubCharts.contains(where: { $0 === m }) { pendingSubCharts.append(m) }
            return
        }
        // 拖拽期间禁止任何指标重算（重算随总 K 数线性增长，是拖拽卡顿根源）；
        // force=true 用于用户显式切换/修改指标，确保立即生效
        if !force, drag.isDragging { drag.needsRefreshAfterDrag = true; return }
        // 主图放大模式：副图不显示也不计算指标值（退出放大时重新计算）
        if mainFullscreen {
            m.curves = []
            m.titleName = m.kind.rawValue
            return
        }
        // 后台正确计算已覆盖整个可见窗口：未强制重算时直接复用；指标变化（force）时用正确覆盖区间重算。
        // 注意：m.curves 是跨周期共享的副图模型曲线，切换周期/配置变更后可能残留其它周期的旧曲线
        // （长度与当前数据不一致）。此时绝不能因 bgCovered 提前返回，必须按当前周期数据重算，
        // 否则副图曲线空白、十字光标不更新副图指标值
        let bgCovered = bgCoverageEnd >= endIndex
        let curvesMatchCurrentData = m.curves.allSatisfy { $0.values.count == sortedData.count }
        if bgCovered, !force, !m.curves.isEmpty, curvesMatchCurrentData { return }
        let custom = customStore.indicators.first { $0.id == m.activeCustomID }
        // 计算区间：后台已覆盖窗口时用后台正确覆盖 [0...bgCoverageEnd]，否则前台近似（合并已算区间）
        let (calcStart, calcEnd) = bgCovered
            ? (0, bgCoverageEnd)
            : mergedCalcRange(needStart: indicatorCalcStart, needEnd: indicatorCalcEnd)
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
        } else {
            switch m.kind {
            case .vol, .amo:
                let isAmo = m.kind == .amo
                let baseAll = isAmo ? turnovers : volumes
                // 始终裁剪到 [calcStart...calcEnd]，padToFull 会补齐前后 NaN 到全量长度
                let baseSlice = baseAll.isEmpty ? [] : Array(baseAll[calcStart...min(calcEnd, baseAll.count - 1)])
                curves.append(padToFull(IndicatorLine(name: m.kind.rawValue, values: baseSlice,
                                                      color: isAmo ? upColor : downColor,
                                                      style: .stick, lineWidth: 1, hideValue: false, barColor: .candle),
                                        calcStart: calcStart, calcEnd: calcEnd))
                for (i, p) in m.volPeriods.enumerated() where p > 0 {
                    curves.append(padToFull(IndicatorLine(name: "MA\(p)", values: ChartSeries.ma(values: baseSlice, period: p),
                                                          color: maColor(i), style: .solid, lineWidth: 1, hideValue: false),
                                            calcStart: calcStart, calcEnd: calcEnd))
                }
            default:
                // 其余系统指标：按内置/可覆盖的 .tdx 公式模板求值
                if let formula = SystemIndicatorStore.shared.formula(for: m.kind.rawValue, values: stringParams(m.params)),
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
        }
        m.curves = curves
        m.titleName = (m.isCustom ? custom?.name : nil) ?? m.kind.rawValue
        m.color = custom?.color ?? Color(hex: "0050FF")!
        // 写回 (标的, 周期) 缓存：副图曲线按槽位存储，切回该周期时直接恢复
        if let metaId = metaId {
            let store = ChartCacheStore.shared
            let fp = Self.currentConfigFingerprint()
            store.invalidateIfConfigChanged(metaId: metaId, period: period, currentFingerprint: fp)
            let e = store.entry(for: metaId, period: period)
            let slot = m === subTop ? 0 : (m === subBottom ? 1 : 2)
            e.subCurves[slot] = m.curves
            e.configFingerprint = fp
        }
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
        let range = (minLow - padding)...(maxHigh + padding)
        // 空头镜像：价格范围取负，K线与指标随之镜像
        return mirroredRange(range)
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
        let r: (min: Double, max: Double)
        switch m.kind {
        case .vol, .amo:
            let mx = values.max() ?? 1
            r = (0, mx * 1.08)
        case .macd, .vmacd, .wmacd:
            let mx = values.map { abs($0) }.max() ?? 1
            let mm = max(mx * 1.15, 0.0001)
            r = (-mm, mm)
        case .rsi, .vrsi:
            r = (0, 100)
        case .kdj, .kd, .lwr, .marsi, .cdj, .col:
            let lo = min(values.min() ?? 0, 0)
            let hi = max(values.max() ?? 100, 100)
            r = (lo, hi)
        default:
            guard let mn = values.min(), let mx = values.max(), mn != mx else { r = (0, 100); break }
            let pad = (mx - mn) * 0.05
            r = (mn - pad, mx + pad)
        }
        // 空头镜像（取负）：范围镜像为 (-max)...(-min)，曲线随之镜像
        if m.mirrored { return (-r.max, -r.min) }
        return r
    }

    // MARK: - 手势

    private var menuIsOpen: Bool { showMainSheet || showSubSheet || showCustomEditor || paramEditorTarget != nil }

    private func isInPanel(_ y: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> Bool { y >= top && y <= bottom }

    private func clamp<V: Comparable>(_ v: V, _ lo: V, _ hi: V) -> V { min(max(v, lo), hi) }

    /// 标签文本实际渲染宽度（含左右各 4pt 内边距）：用于贴边判定，避免用估算半宽导致提前贴边
    private func labelTextWidth(_ text: String, fontSize: CGFloat, bold: Bool = true) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        return w + 8
    }

    /// 十字光标竖线标签的横向定位：标签中心跟随竖线，只有标签真正会超出屏幕时才对齐贴边
    private func crosshairLabelAlignment(x: CGFloat, labelWidth: CGFloat, width: CGFloat) -> (Alignment, CGFloat) {
        if x - labelWidth / 2 < 0 { return (.leading, 0) }        // 左边缘贴屏幕最左侧
        if x + labelWidth / 2 > width { return (.trailing, 0) }    // 右边缘贴屏幕最右侧
        return (.center, x - width / 2)                            // 跟随竖线
    }

    private func chartDragGesture(width: CGFloat, candleSpacing: CGFloat,
                                  mainTop: CGFloat, mainBottom: CGFloat,
                                  s1Top: CGFloat, s1Bottom: CGFloat,
                                  s2Top: CGFloat, s2Bottom: CGFloat,
                                  s3Top: CGFloat, s3Bottom: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !menuIsOpen else { return }
                // 手势作用域固定为起点所在区域：主图/副图1/副图2/副图3；滑出起点区域后仍以起点区域处理
                let sy = value.startLocation.y
                let startInMain = isInPanel(sy, mainTop, mainBottom)
                let startInS1 = isInPanel(sy, s1Top, s1Bottom)
                let startInS2 = isInPanel(sy, s2Top, s2Bottom)
                let startInS3 = isInPanel(sy, s3Top, s3Bottom)
                guard startInMain || startInS1 || startInS2 || startInS3 else { return }
                drag.isDragging = true
                // 记录最近触摸位置，作为双指缩放时的锚点（双指质心）
                drag.lastTouchX = value.location.x
                // 区间统计边界拖动：命中边界线附近（或已处于边界拖动中）且起点在主图区域时，优先调整统计区间
                if startInMain && displaySettings.showRangeStats {
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

                // 副图左右滑动切换：起点在副图且无光标时实时更新拖动反馈动画（显示方向提示/滑轨/阈值）
                if (startInS1 || startInS2) && selectedIndex == nil {
                    let slot: SubSlot = startInS1 ? .top : .bottom
                    swipeFeedback = SwipeFeedback(slot: slot, offset: value.translation.width,
                                                  canLeft: slot == .top ? canSwitchPeriod(-1) : (canSwitchItem?(-1) ?? false),
                                                  canRight: slot == .top ? canSwitchPeriod(1) : (canSwitchItem?(1) ?? false))
                    return
                }

                if selectedIndex != nil {
                    // 仅当真正拖动（移动超过阈值）时光标跟随手指；纯点击不移动光标，
                    // 避免"点击取消光标"时先跳到触摸位置再消失
                    if abs(value.translation.width) > 6 || abs(value.translation.height) > 6 {
                        let col = Int((value.location.x / candleSpacing).rounded(.down))
                        let idx = startIndex + col
                        if idx >= startIndex && idx <= endIndex {
                            selectedIndex = idx
                            crosshairY = value.location.y
                        }
                        drag.cursorDragging = true
                    }
                } else if startInMain && drag.dragMode == .none {
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
                    visibleCount = clamp(visibleCount + deltaY * 0.5, 20, CGFloat(capVisibleCount))
                } else if drag.dragMode == .pan {
                    let delta = value.translation.width - drag.lastPanWidth
                    drag.lastPanWidth = value.translation.width
                    // 亚像素平滑平移：先累计像素偏移，累计满一根K线间距才进位移动窗口，保证缓慢拖动也平滑跟手
                    panOffset += delta
                    // 到达数据边界时最多滑出屏幕宽度 1/10 的空白，避免把 K 线拖出大片空白
                    let maxOver = width / 10
                    panOffset = clamp(panOffset, -maxOver, maxOver)
                    let shift = Int((panOffset / candleSpacing).rounded())
                    if shift != 0 {
                        let newOffset = clamp(endOffset + shift, 0, max(0, sortedData.count - count))
                        let applied = newOffset - endOffset
                        endOffset = newOffset
                        panOffset -= CGFloat(applied) * candleSpacing
                    }
                }
                // 手势不暂停后台预计算：进度条持续推进到消失；
                // 松开后 startPrefetch 会因 token 仍在（任务在跑）而直接跳过，不会重复启动
            }
            .onEnded { value in
                drag.lastPanWidth = 0; drag.lastPanHeight = 0; drag.dragMode = .none
                panOffset = 0
                statsDragEdge = nil
                // 关键：无论手势如何结束（含提前 return 的分支），都必须重置拖拽状态，
                // 否则 isDragging 一直为 true，后续切换/修改指标的重算都会被跳过
                drag.isDragging = false
                // 平移/缩放会改变可见窗口，指标裁剪区间需跟随；这里无条件重算一次。
                // 无窗口变化（如轻点）时裁剪区间缓存键不变，直接复用缓存，开销几乎为零
                drag.needsRefreshAfterDrag = false
                refreshCurves()
                // 拖动结束，恢复后台历史预计算（从当前已覆盖区间继续向历史扩展）
                startPrefetch()
                guard !menuIsOpen else { drag.cursorDragging = false; return }
                // 副图滑动切换结算：超过阈值触发切换，否则回弹取消（动画由 overlay 呈现）
                if let fb = swipeFeedback {
                    let threshold: CGFloat = 70
                    let dir = fb.offset > 0 ? -1 : 1   // 右滑=更小周期/上一个标的，左滑=更大周期/下一个标的
                    if abs(fb.offset) > threshold {
                        selectedIndex = nil; crosshairY = nil
                        if fb.slot == .top {
                            switchPeriod(direction: dir)
                        } else {
                            onSwitchItem?(dir)
                        }
                    }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { swipeFeedback = nil }
                    return
                }
                if drag.cursorDragging { drag.cursorDragging = false; return }
                let y = value.location.y
                let inPanel = isInPanel(y, mainTop, mainBottom) || isInPanel(y, s1Top, s1Bottom) || isInPanel(y, s2Top, s2Bottom) || isInPanel(y, s3Top, s3Bottom)
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

    /// 某方向是否存在可切换的周期（-1 更小 / +1 更大），用于副图滑动方向提示
    private func canSwitchPeriod(_ dir: Int) -> Bool {
        let cases = KlinePeriod.allCases
        guard let cur = cases.firstIndex(of: period) else { return false }
        let target = cur + dir
        return target >= 0 && target < cases.count
    }

    /// 双指缩放：以双指位置（lastTouchX 质心）对应的K线为基线，保持该K线的屏幕位置不变
    private func magnificationGesture(width: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                selectedIndex = nil; crosshairY = nil
                let newCountF = clamp(zoomBase / value, 20, CGFloat(capVisibleCount))
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
                // 手势（含双指缩放）不暂停后台预计算：进度条持续推进到消失
            }
            .onEnded { _ in
                zoomBase = visibleCount
                zoomAnchorIndex = nil
                // 双指缩放结束，恢复后台历史预计算（避免 DragGesture 被抢占时漏重启）
                startPrefetch()
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
            // 底部区域：新增的行情数据行 + 时间轴各占一行（同高）
            let chartHeight = max(1, geometry.size.height - 4 * legendHeight - 2 * timeHeight)
            // 主图放大模式下副图（含名称/指标栏）完全不显示，主图占满全部剩余空间
            let sub1Height = mainFullscreen ? 0 : chartHeight * 0.15
            let sub2Height = sub1Height
            let sub3Height = sub1Height
            let mainHeight = max(1, chartHeight - sub1Height - sub2Height - sub3Height)

            let mainTop = legendHeight
            let mainBottom = mainTop + mainHeight
            let s1Top = mainBottom + legendHeight
            let s1Bottom = s1Top + sub1Height
            let s2Top = s1Bottom + legendHeight
            let s2Bottom = s2Top + sub2Height
            let s3Top = s2Bottom + legendHeight
            let s3Bottom = s3Top + sub3Height

            VStack(spacing: 0) {
                mainLegendRow(height: legendHeight).zIndex(30)
                mainChart(width: width, candleSpacing: candleSpacing, height: mainHeight)
                if !mainFullscreen {
                    subLegendRow(model: subTop, height: legendHeight).zIndex(30)
                    subChart(model: subTop, width: width, candleSpacing: candleSpacing, height: sub1Height,
                             slot: .top)
                    subLegendRow(model: subBottom, height: legendHeight).zIndex(30)
                    subChart(model: subBottom, width: width, candleSpacing: candleSpacing, height: sub2Height,
                             slot: .bottom)
                    subLegendRow(model: subThird, height: legendHeight).zIndex(30)
                    subChart(model: subThird, width: width, candleSpacing: candleSpacing, height: sub3Height,
                             slot: .third)
                }
                // 时间轴上方新增一行：十字光标出现时显示 开/收/高/低/涨/额 行情数据
                axisQuoteRow(width: width, height: timeHeight)
                timeAxis(width: width, candleSpacing: candleSpacing, height: timeHeight)
            }
            .contentShape(Rectangle())
            .gesture(chartDragGesture(width: width, candleSpacing: candleSpacing, mainTop: mainTop, mainBottom: mainBottom,
                                      s1Top: s1Top, s1Bottom: s1Bottom, s2Top: s2Top, s2Bottom: s2Bottom,
                                      s3Top: s3Top, s3Bottom: s3Bottom))
            .simultaneousGesture(magnificationGesture(width: width))
            .overlay {
                // 可交互光标（pin 开启时即第二个光标）与固定光标（pin 开启时的第一个）都绘制
                ZStack(alignment: .topLeading) {
                    cursorOverlay(index: selectedIndex, y: crosshairY, compare: pinnedIndex, fixedPrice: nil, width: width, height: geometry.size.height,
                                  candleSpacing: candleSpacing,
                                  mainTop: mainTop, mainBottom: mainBottom, mainHeight: mainHeight,
                                  s1Top: s1Top, s1Bottom: s1Bottom, s1Height: sub1Height,
                                  s2Top: s2Top, s2Bottom: s2Bottom, s2Height: sub2Height,
                                  s3Top: s3Top, s3Bottom: s3Bottom, s3Height: sub3Height)
                    // 固定光标：横线 y 用固定价格反算（主图），平移/缩放后价格不随可见窗口变化
                    let pinnedCY = pinnedPrice.map { priceToY($0, mainTop: mainTop, mainBottom: mainBottom, mainHeight: mainHeight) } ?? pinnedY
                    cursorOverlay(index: pinnedIndex, y: pinnedCY, compare: nil, fixedPrice: pinnedPrice, width: width, height: geometry.size.height,
                                  candleSpacing: candleSpacing,
                                  mainTop: mainTop, mainBottom: mainBottom, mainHeight: mainHeight,
                                  s1Top: s1Top, s1Bottom: s1Bottom, s1Height: sub1Height,
                                  s2Top: s2Top, s2Bottom: s2Bottom, s2Height: sub2Height,
                                  s3Top: s3Top, s3Bottom: s3Bottom, s3Height: sub3Height)
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
            .onChange(of: pinEnabled) { enabled in
                if enabled {
                    // 开启：把当前屏幕上那一个光标固定下来，准备点击产生第二个光标
                    guard let idx = selectedIndex else { return }
                    pinnedIndex = idx
                    pinnedY = crosshairY
                    // 记录固定时刻的横轴价格（仅主图区域有效）：平移/缩放后固定光标的横线仍位于该价格处
                    if let cy = crosshairY, isInPanel(cy, mainTop, mainBottom) {
                        pinnedPrice = priceAtY(cy, mainTop: mainTop, mainBottom: mainBottom, mainHeight: mainHeight)
                    } else {
                        pinnedPrice = nil
                    }
                    selectedIndex = nil
                    crosshairY = nil
                } else {
                    // 关闭：清除所有光标
                    selectedIndex = nil
                    crosshairY = nil
                    pinnedIndex = nil
                    pinnedY = nil
                    pinnedPrice = nil
                }
                notifyHasCursor()
            }
        }
        .background(Color.white)
        .onAppear {
            // 副图配置已持久化在共享仓库，无需重置
            refreshCurves()
            // 先显示当前可见窗口（不卡），随后分块预计算更久远历史指标
            startPrefetch()
            notifyHasCursor()
        }
        .onDisappear {
            // 视图被移除（切换周期/退出详情页）时停止本视图的预计算任务：
            // 否则任务会继续向「共享的副图模型」写曲线，与切换后的新视图抢写，
            // 导致副图曲线错位/变空。其它周期由后台 prefetchOtherPeriod 独立补齐
            prefetchToken = nil
        }
        .onChange(of: selectedIndex) { _ in notifyHasCursor() }
        .onChange(of: pinnedIndex) { _ in notifyHasCursor() }
        .onChange(of: config.showBareK) { _ in
            // 顶部栏裸K按钮切换后立即重算（隐藏/恢复主图指标）
            recomputeMainCurves(force: true)
        }
        .onChange(of: customStore.indicators) { _ in
            syncCustomAfterStoreChange()
            // 自定义指标被新增/编辑/删除，必须强制重算；
            // 否则后台已覆盖全量（bgCovered）时 refreshCurves 会被 `!force` 提前 return，
            // 导致编辑后的指标不更新
            refreshCurves(force: true)
        }
        .onChange(of: menuIsOpen) { isOpen in
            // 面板关闭返回 K 线页：重算期间被挂起的指标（主图/具体副图）。
            // 被挂起说明用户在面板里改了指标/参数，必须 force 重算；
            // 否则后台已覆盖全量（bgCovered）时 `!force` 会提前 return，导致切换指标无反应
            if !isOpen {
                if pendingMainRefresh {
                    pendingMainRefresh = false
                    recomputeMainCurves(force: true)
                }
                if !pendingSubCharts.isEmpty {
                    let subs = pendingSubCharts
                    pendingSubCharts.removeAll()
                    for m in subs { recomputeSub(m, force: true) }
                }
            }
        }
    }

    /// 屏幕上是否有任意光标（固定光标或可交互光标），通知详情页用于控制 📌 按钮
    private func notifyHasCursor() {
        onHasCursorChange?(selectedIndex != nil || pinnedIndex != nil)
    }

    private func refreshCurves(force: Bool = false) {
        recomputeMainCurves(force: force)
        recomputeSub(subTop, force: force)
        recomputeSub(subBottom, force: force)
        recomputeSub(subThird, force: force)
    }

    /// 打开标的后，在后台分块正确计算全部历史指标：
    /// 前台已先显示当前可见窗口的近似值（从可见起点往前预热一段起算，偏差很小）；
    /// 随后后台从数据开头（最左）向右逐块推进计算，EMA/SMA 等递归指标从第一根开始累积，
    /// 数值最正确；覆盖到当前可见窗口末端后才替换前台近似曲线（最新部分被重算为正确值）。
    /// 用户交互（拖动/缩放）或切换周期/标的/指标时 token 失效，任务自动停止
    private func startPrefetch() {
        guard !sortedData.isEmpty, !mainFullscreen, prefetchToken == nil else { return }
        // 该周期已完成全量正确预计算（可能由上次会话/后台链式预计算完成）：无需再算。
        // 仅当缓存确实已覆盖到数据末尾、且所用指标配置与当前一致才跳过，
        // 防止「完成标记」与「实际覆盖/配置」不一致时进度条卡住或指标不更新
        if let metaId = metaId {
            let entry = ChartCacheStore.shared.entry(for: metaId, period: period)
            if entry.prefetchDone, entry.bgCoverageEnd >= sortedData.count - 1,
               entry.configFingerprint == Self.currentConfigFingerprint() { return }
        }
        // 标记缓存条目正在预计算，避免后台「其它周期预计算」对该周期重复启动
        if let metaId = metaId {
            ChartCacheStore.shared.entry(for: metaId, period: period).isPrefetching = true
        }
        let token = UUID()
        prefetchToken = token
        Task { @MainActor in
            while self.prefetchToken == token {
                // 指标/设置面板打开期间暂停预计算，避免空转与干扰面板操作
                if self.menuIsOpen {
                    await Task.yield()
                    continue
                }
                // 从数据开头（最左）向右推进：下一块覆盖到 bgCoverageEnd + block
                let currentEnd = max(0, self.bgCoverageEnd)
                let bgEnd = min(self.sortedData.count - 1, currentEnd + self.prefetchBlockSize)
                guard bgEnd > currentEnd else {
                    // 已全部算完：标记周期预计算完成，并让外层继续预计算其它未计算周期
                    self.finishPrefetch()
                    break
                }
                // 主线程构造计算请求（从数据开头起算，保证递归指标数值最正确）
                guard let request = self.makePrefetchRequest(calcStart: 0, calcEnd: bgEnd) else { break }
                // 后台线程执行指标求值（纯计算，不触碰任何 UI/状态）
                let result = await Task.detached(priority: .utility) {
                    Self.evaluatePrefetch(request)
                }.value
                // 回主线程：token 仍有效才提交；仅当正确覆盖推进到可见窗口末端时才更新曲线，
                // 否则保持前台近似的立即显示（避免后台未覆盖时指标变空白）。
                // 拖动/缩放进行中跳过曲线组装（只推进 bgCoverageEnd/进度条），
                // 避免全量曲线组装占用主线程影响手势流畅度；松手后下一块会补上
                guard self.prefetchToken == token else { break }
                let shouldCommit = bgEnd >= self.endIndex && !self.drag.isDragging
                self.commitPrefetch(request, result, updateCurves: shouldCommit)
                self.bgCoverageEnd = bgEnd
                // 仅在曲线真正提交时推进缓存的覆盖末端，保证缓存 bgCoverageEnd 与实际存储曲线
                // 的覆盖一致；否则会出现「声称已覆盖」但曲线未覆盖可见窗口，切回该周期后
                // bgCovered 误判为真、recomputeSub 提前返回 → 副图空白
                if shouldCommit, let metaId = self.metaId {
                    let entry = ChartCacheStore.shared.entry(for: metaId, period: self.period)
                    entry.bgCoverageEnd = max(entry.bgCoverageEnd, bgEnd)
                }
                // 让出主线程，先刷新 UI 再算下一块
                await Task.yield()
            }
            // 仅当仍是自己在运行时才清理 token / 占用标记：
            // 拖动等交互会把 prefetchToken 置 nil 或让后续 startPrefetch 换成新 token，
            // 此时绝不能清掉新任务的 token，否则会把新任务误杀，导致进度条卡死不再推进
            if self.prefetchToken == token {
                self.prefetchToken = nil
                if let metaId = self.metaId {
                    ChartCacheStore.shared.entry(for: metaId, period: self.period).isPrefetching = false
                }
            }
        }
    }

    /// 当前周期全量正确预计算完成：标记缓存并回调外层继续预计算其它未计算周期
    private func finishPrefetch() {
        guard let metaId = metaId else { return }
        let cache = ChartCacheStore.shared
        let entry = cache.entry(for: metaId, period: period)
        entry.prefetchDone = true
        entry.isPrefetching = false
        // 让外层（详情页）拿到其它未计算周期的数据并后台预计算，不切换可见周期
        onPeriodPrefetched?(period)
    }

    /// 主线程构造预计算每块的请求：快照裁剪数据、启用的指标公式与参数（全部 Sendable，可跨线程）
    private func makePrefetchRequest(calcStart: Int, calcEnd: Int) -> PrefetchCalcRequest? {
        guard !sortedData.isEmpty, calcStart >= 0, calcStart <= calcEnd, calcEnd < sortedData.count else { return nil }
        let data = Array(sortedData[calcStart...calcEnd])
        let volumes = Array(self.volumes[calcStart...calcEnd])
        let turnovers = Array(self.turnovers[calcStart...calcEnd])
        let store = SystemIndicatorStore.shared
        // 主图：固定顺序（MA/EMA/BOLL/CMK/SAR/自定义），未启用用空串占位，
        // 保证后台结果与提交组装的索引严格一一对应，避免中途配置变化导致错位
        var main: [String] = ["", "", "", "", "", ""]
        if !config.showBareK {
            if config.showMA { main[0] = store.formula(for: "MA", values: mainMAValues(config.maConfig)) ?? "" }
            if config.showEMA { main[1] = store.formula(for: "EMA", values: mainMAValues(periods: config.emaConfig.periods, sources: config.emaConfig.sources)) ?? "" }
            if config.showBOLL { main[2] = store.formula(for: "BOLL", values: mainBOLLValues()) ?? "" }
            if config.showCMK { main[3] = store.formula(for: "CMK", values: ["cmkN": "\(config.cmkN)"]) ?? "" }
            if config.showSAR { main[4] = store.formula(for: "SAR", values: ["step": fmt(config.sarStep), "maxstep": fmt(config.sarMax)]) ?? "" }
            if let custom = activeCustomIndicator { main[5] = custom.formula }
        }
        // 副图（3 个，与 subTop/subBottom/subThird 对应）
        var subs: [SubPrefetchRequest] = []
        for m in [subTop, subBottom, subThird] {
            let customInd = customStore.indicators.first { $0.id == m.activeCustomID }
            let isCustom = m.activeCustomID != nil && customInd != nil
            let customFormula = isCustom ? customInd?.formula : nil
            let formula = (m.kind == .vol || m.kind == .amo) ? nil : store.formula(for: m.kind.rawValue, values: stringParams(m.params))
            subs.append(SubPrefetchRequest(kind: m.kind, customFormula: customFormula, formula: formula, volPeriods: m.volPeriods))
        }
        return PrefetchCalcRequest(calcStart: calcStart, calcEnd: calcEnd, data: data,
                                   volumes: volumes, turnovers: turnovers, mainFormulas: main, subs: subs)
    }

    /// 后台线程：对请求中的每个公式求值（纯计算，无任何 UI/状态访问，线程安全）
    nonisolated static func evaluatePrefetch(_ req: PrefetchCalcRequest) -> PrefetchCalcResult {
        let main: [[TDXOutputLine]] = req.mainFormulas.map { formula in
            guard !formula.isEmpty else { return [] }
            return (try? TDXFormulaEngine.evaluate(formula: formula, data: req.data)) ?? []
        }
        let subs: [[TDXOutputLine]] = req.subs.map { s in
            let f = s.customFormula ?? s.formula
            guard let f, !f.isEmpty else { return [] }
            return (try? TDXFormulaEngine.evaluate(formula: f, data: req.data)) ?? []
        }
        return PrefetchCalcResult(main: main, subs: subs)
    }

    /// 主线程：把后台求得的原始输出行组装为 IndicatorLine，更新主图/副图曲线（含标题与颜色）。
    /// updateCurves=false 时只更新进度（bgCoverageEnd 由调用方设置），保持前台近似曲线不变，
    /// 直到正确覆盖推进到可见窗口末端才替换为正确结果
    private func commitPrefetch(_ req: PrefetchCalcRequest, _ result: PrefetchCalcResult, updateCurves: Bool) {
        guard updateCurves else { return }
        let cs = req.calcStart, ce = req.calcEnd
        // ---- 主图（固定顺序，与 makePrefetchRequest 的 mainFormulas 一一对应）----
        var curves: [IndicatorLine] = []
        func appendMain(_ idx: Int, color: (Int, TDXOutputLine) -> Color,
                        sar: Bool = false, name: String? = nil, lineWidth: Double? = nil) {
            guard idx < result.main.count else { return }
            for (i, out) in result.main[idx].enumerated() {
                guard !allNaN(out.values) else { continue }
                curves.append(padToFull(IndicatorLine(name: name ?? displayName(out.name), values: out.values,
                                                      color: color(i, out),
                                                      // SAR 固定小圆点（与 recomputeMainCurves 保持一致），
                                                      // 否则公式输出行默认 solid 会被画成线条
                                                      style: sar ? .pointdot : out.style,
                                                      lineWidth: lineWidth ?? out.lineWidth,
                                                      hideValue: out.hideValue,
                                                      markerColors: sar ? out.markerDirections?.map { $0 ? upColor : downColor } : nil),
                                        calcStart: cs, calcEnd: ce))
            }
        }
        appendMain(0, color: { lineColor(from: $1, fallback: maColor($0)) })                                        // MA
        appendMain(1, color: { lineColor(from: $1, fallback: maColor($0)) })                                        // EMA
        appendMain(2, color: { lineColor(from: $1, fallback: $0 == 0 ? ma10Color : bollColor) })                   // BOLL
        appendMain(3, color: { lineColor(from: $1, fallback: maColor($0)) })                                        // CMK
        appendMain(4, color: { _, _ in upColor }, sar: true, name: "SAR", lineWidth: 1)                            // SAR
        if let custom = activeCustomIndicator {
            appendMain(5, color: { customLineColor($0, line: $1, indicatorColor: custom.color) })                  // 自定义
        }
        mainCurves = curves
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
            } else if subReq.kind == .vol || subReq.kind == .amo {
                let isAmo = subReq.kind == .amo
                let baseSlice = isAmo ? req.turnovers : req.volumes
                subCurves.append(padToFull(IndicatorLine(name: subReq.kind.rawValue, values: baseSlice,
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
            m.curves = subCurves
            let customInd = customStore.indicators.first { $0.id == m.activeCustomID }
            m.titleName = (m.isCustom ? customInd?.name : nil) ?? m.kind.rawValue
            m.color = customInd?.color ?? Color(hex: "0050FF")!
        }
        // 写回 (标的, 周期) 缓存：后台正确结果落盘，切走再回来直接恢复
        if let metaId = metaId {
            let store = ChartCacheStore.shared
            let fp = Self.currentConfigFingerprint()
            store.invalidateIfConfigChanged(metaId: metaId, period: period, currentFingerprint: fp)
            let e = store.entry(for: metaId, period: period)
            e.mainCurves = mainCurves
            e.mainCache = mainCache
            e.coverageStart = indicatorCoverageStart
            e.coverageEnd = indicatorCoverageEnd
            // 覆盖末端只增不减
            e.bgCoverageEnd = max(e.bgCoverageEnd, bgCoverageEnd)
            e.configFingerprint = fp
            for (i, m) in [subTop, subBottom, subThird].enumerated() {
                e.subCurves[i] = m.curves
            }
        }
    }

    // MARK: - 后台预计算其它周期（写入全局缓存，不触碰可见视图）

    /// 当前指标配置指纹：主图开关/参数 + 三个副图指标与参数（含自定义指标公式）。
    /// 用于判断某 (标的, 周期) 的缓存是否仍与当前配置一致：配置变了 → 缓存视为无效、重算。
    static func currentConfigFingerprint() -> String {
        let config = ChartConfigStore.shared
        let customStore = CustomIndicatorStore.shared
        let store = SystemIndicatorStore.shared
        var parts: [String] = []
        // 主图：固定顺序（MA/EMA/BOLL/CMK/SAR/自定义）
        var main = ["", "", "", "", "", ""]
        if !config.showBareK {
            if config.showMA { main[0] = store.formula(for: "MA", values: prefetchMainMAValues(config.maConfig)) ?? "" }
            if config.showEMA { main[1] = store.formula(for: "EMA", values: prefetchMainMAValues(periods: config.emaConfig.periods, sources: config.emaConfig.sources)) ?? "" }
            if config.showBOLL { main[2] = store.formula(for: "BOLL", values: prefetchMainBOLLValues()) ?? "" }
            if config.showCMK { main[3] = store.formula(for: "CMK", values: ["cmkN": "\(config.cmkN)"]) ?? "" }
            if config.showSAR { main[4] = store.formula(for: "SAR", values: ["step": prefetchFmt(config.sarStep), "maxstep": prefetchFmt(config.sarMax)]) ?? "" }
            if let customID = config.activeCustomIndicatorID,
               let custom = customStore.indicators.first(where: { $0.id == customID }) {
                main[5] = custom.formula
            }
        }
        parts.append(main.joined(separator: "§"))
        // 副图：3 个槽位，含指标类型、参数（VOL/AMO 量均线周期）
        for m in [config.subTop, config.subBottom, config.subThird] {
            let customInd = customStore.indicators.first { $0.id == m.activeCustomID }
            let isCustom = m.activeCustomID != nil && customInd != nil
            var s = m.kind.rawValue
            if isCustom, let customInd {
                s += "|CUSTOM|" + customInd.formula
            } else if m.kind == .vol || m.kind == .amo {
                s += "|" + m.volPeriods.map(String.init).joined(separator: ",")
            } else {
                s += "|" + (store.formula(for: m.kind.rawValue, values: prefetchStringParams(m.params)) ?? "")
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
        let currentFP = currentConfigFingerprint()
        // 配置已变化：先使旧缓存失效，避免旧配置的「已完成」被误判为无需计算
        cache.invalidateIfConfigChanged(metaId: metaId, period: period, currentFingerprint: currentFP)
        let entry = cache.entry(for: metaId, period: period)
        // 已按当前配置完成全量预计算 → 无需再算
        if entry.prefetchDone, entry.bgCoverageEnd >= data.count - 1 { return }
        guard !entry.isPrefetching else { return }
        entry.isPrefetching = true
        // 记录本次计算所用的配置指纹，供恢复时校验是否已过期
        let fingerprint = currentFP
        guard let req = makeFullRequest(data: data) else { entry.isPrefetching = false; return }
        let result = Task.detached(priority: .utility) {
            Self.evaluatePrefetch(req)
        }
        Task { @MainActor in
            let r = await result.value
            // 计算期间指标配置可能已变化：与本次快照不一致时丢弃旧配置结果，避免污染缓存
            guard currentConfigFingerprint() == fingerprint else {
                entry.isPrefetching = false
                return
            }
            Self.commitToCache(req, r, entry: entry, data: data, fingerprint: fingerprint)
            entry.isPrefetching = false
            entry.prefetchDone = true
        }
    }

    /// 构造指定 (标的, 周期) 全量指标计算请求（公式与可见视图完全一致，读取共享配置）
    private static func makeFullRequest(data: [KlineItem]) -> PrefetchCalcRequest? {
        guard !data.isEmpty else { return nil }
        let config = ChartConfigStore.shared
        let customStore = CustomIndicatorStore.shared
        let store = SystemIndicatorStore.shared
        let volumes = data.map(\.volume)
        let turnovers = data.map(\.turnover)
        // 主图：固定顺序（MA/EMA/BOLL/CMK/SAR/自定义），未启用用空串占位
        var main: [String] = ["", "", "", "", "", ""]
        if !config.showBareK {
            if config.showMA { main[0] = store.formula(for: "MA", values: prefetchMainMAValues(config.maConfig)) ?? "" }
            if config.showEMA { main[1] = store.formula(for: "EMA", values: prefetchMainMAValues(periods: config.emaConfig.periods, sources: config.emaConfig.sources)) ?? "" }
            if config.showBOLL { main[2] = store.formula(for: "BOLL", values: prefetchMainBOLLValues()) ?? "" }
            if config.showCMK { main[3] = store.formula(for: "CMK", values: ["cmkN": "\(config.cmkN)"]) ?? "" }
            if config.showSAR { main[4] = store.formula(for: "SAR", values: ["step": prefetchFmt(config.sarStep), "maxstep": prefetchFmt(config.sarMax)]) ?? "" }
            if let customID = config.activeCustomIndicatorID,
               let custom = customStore.indicators.first(where: { $0.id == customID }) {
                main[5] = custom.formula
            }
        }
        // 副图（3 个，与 subTop/subBottom/subThird 对应）
        var subs: [SubPrefetchRequest] = []
        for m in [config.subTop, config.subBottom, config.subThird] {
            let customInd = customStore.indicators.first { $0.id == m.activeCustomID }
            let isCustom = m.activeCustomID != nil && customInd != nil
            let customFormula = isCustom ? customInd?.formula : nil
            let formula = (m.kind == .vol || m.kind == .amo) ? nil : store.formula(for: m.kind.rawValue, values: prefetchStringParams(m.params))
            subs.append(SubPrefetchRequest(kind: m.kind, customFormula: customFormula, formula: formula, volPeriods: m.volPeriods))
        }
        return PrefetchCalcRequest(calcStart: 0, calcEnd: data.count - 1, data: data,
                                   volumes: volumes, turnovers: turnovers, mainFormulas: main, subs: subs)
    }

    /// 主线程：把后台求得的原始输出行组装为 IndicatorLine 并写入全局缓存。
    /// 全量覆盖（calcStart=0、calcEnd=末尾），无需 NaN 填充
    @MainActor
    private static func commitToCache(_ req: PrefetchCalcRequest, _ result: PrefetchCalcResult,
                                      entry: ChartCacheStore.Entry, data: [KlineItem], fingerprint: String) {
        let config = ChartConfigStore.shared
        var curves: [IndicatorLine] = []
        func appendMain(_ idx: Int, color: (Int, TDXOutputLine) -> Color,
                        sar: Bool = false, name: String? = nil, lineWidth: Double? = nil) {
            guard idx < result.main.count else { return }
            for (i, out) in result.main[idx].enumerated() {
                guard !prefetchAllNaN(out.values) else { continue }
                curves.append(IndicatorLine(name: name ?? prefetchDisplayName(out.name), values: out.values,
                                            color: color(i, out),
                                            // SAR 固定小圆点，避免默认 solid 被画成线条
                                            style: sar ? .pointdot : out.style,
                                            lineWidth: lineWidth ?? out.lineWidth, hideValue: out.hideValue,
                                            markerColors: sar ? out.markerDirections?.map { $0 ? prefetchUpColor : prefetchDownColor } : nil))
            }
        }
        appendMain(0, color: { prefetchLineColor(from: $1, fallback: prefetchMaColor($0)) })                            // MA
        appendMain(1, color: { prefetchLineColor(from: $1, fallback: prefetchMaColor($0)) })                            // EMA
        appendMain(2, color: { prefetchLineColor(from: $1, fallback: $0 == 0 ? prefetchMa10Color : prefetchBollColor) }) // BOLL
        appendMain(3, color: { prefetchLineColor(from: $1, fallback: prefetchMaColor($0)) })                            // CMK
        appendMain(4, color: { _, _ in prefetchUpColor }, sar: true, name: "SAR", lineWidth: 1)                        // SAR
        if let customID = config.activeCustomIndicatorID,
           let custom = CustomIndicatorStore.shared.indicators.first(where: { $0.id == customID }) {
            appendMain(5, color: { prefetchCustomLineColor($0, line: $1, indicatorColor: custom.color) })               // 自定义
        }
        entry.mainCurves = curves
        // 副图
        var subCurves: [Int: [IndicatorLine]] = [:]
        for (i, m) in [config.subTop, config.subBottom, config.subThird].enumerated() {
            guard i < req.subs.count, i < result.subs.count else { continue }
            let subReq = req.subs[i]
            let raw = result.subs[i]
            var sc: [IndicatorLine] = []
            if subReq.customFormula != nil {
                let customInd = CustomIndicatorStore.shared.indicators.first { $0.id == m.activeCustomID }
                for (j, out) in raw.enumerated() {
                    guard !prefetchAllNaN(out.values) else { continue }
                    sc.append(IndicatorLine(name: prefetchDisplayName(out.name), values: out.values,
                                            color: prefetchCustomLineColor(j, line: out, indicatorColor: customInd?.color),
                                            style: out.style, lineWidth: out.lineWidth, hideValue: out.hideValue))
                }
            } else if subReq.kind == .vol || subReq.kind == .amo {
                let isAmo = subReq.kind == .amo
                let baseSlice = isAmo ? req.turnovers : req.volumes
                sc.append(IndicatorLine(name: subReq.kind.rawValue, values: baseSlice,
                                        color: isAmo ? prefetchUpColor : prefetchDownColor,
                                        style: .stick, lineWidth: 1, hideValue: false, barColor: .candle))
                for (p, period) in subReq.volPeriods.enumerated() where period > 0 {
                    sc.append(IndicatorLine(name: "MA\(period)", values: ChartSeries.ma(values: baseSlice, period: period),
                                            color: prefetchMaColor(p), style: .solid, lineWidth: 1, hideValue: false))
                }
            } else if subReq.formula != nil {
                for (j, out) in raw.enumerated() {
                    guard !prefetchAllNaN(out.values) else { continue }
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

    private func model(for slot: SubSlot) -> SubChartModel {
        switch slot {
        case .top: return subTop
        case .bottom: return subBottom
        case .third: return subThird
        }
    }

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
        for m in [subTop, subBottom, subThird] {
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
                                    s2Top: CGFloat, s2Bottom: CGFloat, s2Height: CGFloat,
                                    s3Top: CGFloat, s3Bottom: CGFloat, s3Height: CGFloat) -> String {
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
        if y >= s3Top && y <= s3Bottom {
            let r = subRange(subThird)
            let ratio = Double((y - s3Top) / s3Height)
            let v = r.max - (r.max - r.min) * ratio
            return subFormatter(for: subThird.kind)(v)
        }
        return ""
    }

    /// 十字光标横线 + 背景数值标签（横线从数值背景的最左边开始画起，贯穿全宽）
    /// secondLine 非 nil 时，第二行显示光标对比多出的内容（如两光标间涨幅）；
    /// gapRanges 非 nil 时，横线在这些横向区间断开（不画在竖线顶部日期标签/底部涨幅标签上）
    private func crosshairLineOverlay(width: CGFloat, height: CGFloat, y: CGFloat, valueText: String,
                                      secondLine: String? = nil,
                                      gapRanges: [ClosedRange<CGFloat>]? = nil,
                                      bgColor: Color = Color(red: 0.35, green: 0.75, blue: 1.0),
                                      lineColor: Color = Color.black.opacity(0.45)) -> some View {
        // 先算出横线需要绘制的非标签区间（合并重叠的标签区间后，取其余部分；无标签时整条）
        let segments: [ClosedRange<CGFloat>] = {
            guard let gaps = gapRanges, !gaps.isEmpty else { return [0...width] }
            var merged: [ClosedRange<CGFloat>] = []
            for g in gaps.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                let g0 = min(max(0, g.lowerBound), width)
                let g1 = min(max(0, g.upperBound), width)
                guard g1 > g0 else { continue }
                if let last = merged.last, g0 <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, g1)
                } else {
                    merged.append(g0...g1)
                }
            }
            var result: [ClosedRange<CGFloat>] = []
            var x: CGFloat = 0
            for g in merged {
                if g.lowerBound > x { result.append(x...g.lowerBound) }
                x = max(x, g.upperBound)
            }
            if x < width { result.append(x...width) }
            return result
        }()
        return ZStack(alignment: .topLeading) {
            // 横轴虚线：从数值背景的最左边（x=0）开始画起；按区间逐段绘制，跳过所有标签区间
            ForEach(segments, id: \.lowerBound) { seg in
                Rectangle().fill(lineColor)
                    .frame(width: max(0, seg.upperBound - seg.lowerBound), height: 1.0)
                    .position(x: (seg.lowerBound + seg.upperBound) / 2, y: y)
            }
            if let secondLine {
                // 两行：第一行价格/数值，第二行光标对比信息
                VStack(spacing: 1) {
                    Text(valueText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.top, 1)
                    Text(secondLine)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 1)
                }
                .background(bgColor)
                .offset(y: y - 15)
            } else {
                // 光标数值：背景矩形（高=字体高度、宽=内容宽度），白字加粗，比主图坐标数值大一号
                Text(valueText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .background(bgColor)
                    .offset(y: y - 6)
            }
        }
    }

    /// 单个十字光标在整图上的绘制：横线 + 左侧数值标签 + 主图横轴右侧涨幅标签
    /// （可交互光标与固定光标共用；只有光标 y 落在任一图表面板内才绘制；
    /// fixedPrice 非 nil 表示固定光标的主图横轴价格已固定，数值与横线位置都按该价格）
    @ViewBuilder
    private func cursorOverlay(index: Int?, y: CGFloat?, compare: Int?, fixedPrice: Double?, width: CGFloat, height: CGFloat,
                               candleSpacing: CGFloat,
                               mainTop: CGFloat, mainBottom: CGFloat, mainHeight: CGFloat,
                               s1Top: CGFloat, s1Bottom: CGFloat, s1Height: CGFloat,
                               s2Top: CGFloat, s2Bottom: CGFloat, s2Height: CGFloat,
                               s3Top: CGFloat, s3Bottom: CGFloat, s3Height: CGFloat) -> some View {
        if let index, let y,
           isInPanel(y, mainTop, mainBottom) || isInPanel(y, s1Top, s1Bottom) || isInPanel(y, s2Top, s2Bottom) || isInPanel(y, s3Top, s3Bottom) {
            let cy = min(max(y, 0), height)
            // 固定光标主图横轴价格超出当前可见价格范围时，横线不显示（与竖轴移出屏幕的行为一致），
            // 直到价格范围重新覆盖该价格才恢复显示
            if fixedPrice.map({ $0 >= priceRange.lowerBound && $0 <= priceRange.upperBound }) ?? true {
                // 第二个光标且位于主图区域时：左侧标签第二行追加 第一个光标横轴价格→第二个光标横轴价格 的涨幅
                let priceChange = (compare != nil && isInPanel(y, mainTop, mainBottom))
                    ? secondCursorPriceChange(y: y, pinnedY: pinnedY, pinnedPrice: pinnedPrice, mainTop: mainTop, mainBottom: mainBottom, mainHeight: mainHeight)
                    : nil
                let valueText: String = {
                    if let fp = fixedPrice {
                        // 固定光标的主图横轴价格已固定：数值保持不变
                        return String(format: "%.2f", fp)
                    }
                    return crosshairValueText(at: y, mainTop: mainTop, mainBottom: mainBottom, mainHeight: mainHeight,
                                              s1Top: s1Top, s1Bottom: s1Bottom, s1Height: s1Height,
                                              s2Top: s2Top, s2Bottom: s2Bottom, s2Height: s2Height,
                                              s3Top: s3Top, s3Bottom: s3Bottom, s3Height: s3Height)
                }()
                // 第二个光标比固定光标多出的横轴价格涨幅 → 第二行；固定光标无第二行
                let secondLineText = (fixedPrice == nil) ? (priceChange.map { String(format: "%+.2f%%", $0) } ?? "") : ""
                // 第二个光标时：左侧标签整体背景红涨绿跌（按横轴价格涨幅）、横线蓝色（同📌高亮色）；固定光标保持天蓝/黑色
                let bgColor = priceChange.map { $0 >= 0 ? upColor : downColor } ?? Color(red: 0.35, green: 0.75, blue: 1.0)
                // 横线若与该光标（或对方光标）竖线的顶部日期标签/底部涨幅标签重叠，则在该区间断开不画在标签上
                // 对方光标：两个光标共用一个横线层，需同时让开两个光标的竖线标签
                let otherIndex: Int? = (index == selectedIndex) ? pinnedIndex : selectedIndex
                let otherCompare: Int? = (index == selectedIndex) ? nil : pinnedIndex
                let lineGap = crosshairLineGap(index: index, compare: compare, otherIndex: otherIndex, otherCompare: otherCompare,
                                               cy: cy, candleSpacing: candleSpacing, width: width,
                                               mainTop: mainTop, mainHeight: mainHeight)
                crosshairLineOverlay(width: width, height: height, y: cy, valueText: valueText,
                                     secondLine: secondLineText.isEmpty ? nil : secondLineText,
                                     gapRanges: lineGap,
                                     bgColor: bgColor,
                                     lineColor: compare != nil ? Color.blue : Color.black.opacity(0.45))
                // 主图横线右边：光标K线收盘 → 屏幕最后那根K线收盘 的涨幅；
                // 光标停在屏幕最右边一根K线（index == endIndex）时不显示（涨幅恒为0无意义）
                if isInPanel(y, mainTop, mainBottom),
                   index >= startIndex, index < endIndex, endIndex >= 0, endIndex < sortedData.count {
                    let cursorItem = sortedData[index]
                    let screenLast = sortedData[endIndex]
                    if cursorItem.close > 0, screenLast.close > 0 {
                        let pct = (screenLast.close - cursorItem.close) / cursorItem.close * 100
                        let periodCount = max(0, endIndex - index)
                        // 第二个光标时：第二行显示 两光标间K线周期个数（第二光标比固定光标多出的内容）
                        let secondPeriod = compare.flatMap { pinnedRangeStats(index, $0) }.map { $0.periodCount }
                        // 使用整宽右对齐容器，让标签右边缘精确贴合屏幕最右侧
                        VStack(spacing: 1) {
                            Text(String(format: "%+.2f%%  %d", pct, periodCount))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.top, 1)
                            if let sp = secondPeriod {
                                Text(String(format: "%d", sp))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.bottom, 1)
                            }
                        }
                        .background(pct >= 0 ? upColor : downColor)
                        .frame(width: width, alignment: .trailing)
                        .position(x: width / 2, y: cy)
                    }
                }
            }
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
            // 可交互光标（pin 开启时即第二个光标）与固定光标的竖线/标签都绘制
            mainCursorVLine(index: selectedIndex, compare: pinnedIndex, width: width, candleSpacing: candleSpacing, height: height)
            mainCursorVLine(index: pinnedIndex, compare: nil, width: width, candleSpacing: candleSpacing, height: height)
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

    /// 主图单个光标的竖线 + 顶部日期标签 + 底部涨幅标签（可交互光标与固定光标共用；
    /// compare 非 nil 表示这是第二个光标，顶部/底部标签追加与第一个固定光标的对比统计；
    /// 标签始终跟随各自竖线居中显示，不做互相避让）
    @ViewBuilder
    private func mainCursorVLine(index: Int?, compare: Int?, width: CGFloat, candleSpacing: CGFloat, height: CGFloat) -> some View {
        if let index, index >= startIndex, index <= endIndex {
            let item = sortedData[index]
            let xPosition = (CGFloat(index - startIndex) + 0.5) * candleSpacing
            // 主图竖线：从顶部日期标签背景下沿开始画到底部（竖线完全从背景底下开始，顶部无露出）；第二个光标蓝色、固定光标黑色
            let topCut = clampedAxisY(0, in: height) + 8
            let lineHeight = max(0, height - topCut)
            Rectangle().fill(compare != nil ? Color.blue : Color.black.opacity(0.45)).frame(width: 1.0, height: lineHeight)
                .position(x: xPosition, y: topCut + lineHeight / 2)
            // 顶部日期+星期标签：位于主图顶部坐标值那一行、跟随竖线位置，样式与横轴数值一致（天蓝色背景、白字加粗）；
            // 第二个光标时第二行显示 两光标间振幅 / 最大回撤 / 最大上涨 / 涨幅；宽度按最宽一行（第二行）贴边判定
            let compareStats = compare.flatMap { pinnedRangeStats(index, $0) }
            let dateText = item.formattedDateWithWeekday
            let dateSecondLine = compareStats.map { String(format: "%.2f%%  %+.2f%%  %+.2f%%  %+.2f%%", $0.amplitude, $0.drawdown, $0.rally, $0.change) }
            let dateW = dateSecondLine.map { labelTextWidth($0, fontSize: 10) } ?? labelTextWidth(dateText, fontSize: 10)
            let (dateAlign, dateOffset) = crosshairLabelAlignment(x: xPosition, labelWidth: dateW, width: width)
            VStack(spacing: 1) {
                Text(dateText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.top, 1)
                if let c = compareStats {
                    HStack(spacing: 3) {
                        Text(String(format: "%.2f%%", c.amplitude))
                            .foregroundColor(.white)
                        Text(String(format: "%+.2f%%", c.drawdown))
                            .foregroundColor(downColor)
                        Text(String(format: "%+.2f%%", c.rally))
                            .foregroundColor(upColor)
                        Text(String(format: "%+.2f%%", c.change))
                            .foregroundColor(c.change >= 0 ? upColor : downColor)
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.bottom, 1)
                }
            }
            .background(Color(red: 0.35, green: 0.75, blue: 1.0))
            .frame(width: width, alignment: dateAlign)
            .offset(x: dateOffset)
            // 两行标签更高，中心点整体下移使其完全落在主图内，避免顶部被裁剪
            .position(x: width / 2, y: cursorTopLabelY(hasSecondLine: compareStats != nil, height: height))
            // 主图竖线下方（底部）：距今涨幅（光标K线收盘 → 整个数据集最后一根K线收盘）+ 距今周期数，白字、背景红涨绿跌；
            // 第二个光标时第二行显示 两光标间成交量之和 与 成交额之和；宽度按最宽一行（第二行）贴边判定
            if let last = sortedData.last, last.close > 0 {
                let pct = (last.close - item.close) / item.close * 100
                let periodCount = max(0, (sortedData.count - 1) - index)
                let pctSecondLine = compareStats.map { String(format: "%@  %@", formatVolume($0.volSum), formatAmount($0.amoSum)) }
                let pctW = pctSecondLine.map { labelTextWidth($0, fontSize: 10) } ?? labelTextWidth(String(format: "%+.2f%%  %d", pct, periodCount), fontSize: 10)
                let (pctAlign, pctOffset) = crosshairLabelAlignment(x: xPosition, labelWidth: pctW, width: width)
                VStack(spacing: 1) {
                    Text(String(format: "%+.2f%%  %d", pct, periodCount))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.top, 1)
                    if let line2 = pctSecondLine {
                        Text(line2)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 1)
                    }
                }
                .background(pct >= 0 ? upColor : downColor)
                .frame(width: width, alignment: pctAlign)
                .offset(x: pctOffset)
                // 两行标签更高，中心点整体上移使其完全落在主图内，避免底部被裁剪
                .position(x: width / 2, y: cursorBottomLabelY(hasSecondLine: pctSecondLine != nil, height: height))
            }
        }
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
        // 空头镜像：高/低取负
        return (first.formattedDate, last.formattedDate, change, mir(high), mir(low), vol, amo)
    }

    /// 第二个光标相对第一个固定光标的区间统计（区间为两光标之间；基准为固定光标的收盘价）
    /// change=两光标间涨幅、amplitude=振幅(区间最高-最低相对基准)、drawdown=最大回撤(相对基准,通常负)、
    /// rally=最大上涨(相对基准,通常正)、volSum=成交量之和、amoSum=成交额之和、periodCount=两光标间K线周期个数
    private func pinnedRangeStats(_ second: Int, _ pinned: Int) -> (change: Double, amplitude: Double, drawdown: Double, rally: Double, volSum: Double, amoSum: Double, periodCount: Int)? {
        let s = min(second, pinned)
        let e = max(second, pinned)
        guard s >= 0, e < sortedData.count, s <= e else { return nil }
        let baseClose = sortedData[pinned].close
        guard baseClose > 0 else { return nil }
        let slice = sortedData[s...e]
        let high = slice.map(\.high).max() ?? 0
        let low = slice.map(\.low).min() ?? 0
        let change = (sortedData[second].close - baseClose) / baseClose * 100
        let amplitude = (high - low) / baseClose * 100
        let drawdown = (low - baseClose) / baseClose * 100
        let rally = (high - baseClose) / baseClose * 100
        let volSum = slice.reduce(0.0) { $0 + $1.volume }
        let amoSum = slice.reduce(0.0) { $0 + $1.turnover }
        return (change, amplitude, drawdown, rally, volSum, amoSum, e - s)
    }

    /// 成交额格式化（万亿/亿/万）
    private func formatAmount(_ v: Double) -> String {
        if v >= 1000000000000 { return String(format: "%.2f万亿", v / 1000000000000) }
        else if v >= 100000000 { return String(format: "%.2f亿", v / 100000000) }
        else if v >= 10000 { return String(format: "%.2f万", v / 10000) }
        else { return String(format: "%.0f", v) }
    }

    /// 根据光标横线 y 反算主图横轴价格（仅主图区域有效）
    private func priceAtY(_ y: CGFloat, mainTop: CGFloat, mainBottom: CGFloat, mainHeight: CGFloat) -> Double? {
        guard y >= mainTop, y <= mainBottom else { return nil }
        let ratio = Double((y - mainTop) / mainHeight)
        return priceRange.upperBound - (priceRange.upperBound - priceRange.lowerBound) * ratio
    }

    /// 主图价格 → 横线 y（用当前价格范围反算，限制在主图区域内）：用于固定光标横轴价格不随可见窗口变化
    private func priceToY(_ price: Double, mainTop: CGFloat, mainBottom: CGFloat, mainHeight: CGFloat) -> CGFloat {
        let denom = max(1e-9, priceRange.upperBound - priceRange.lowerBound)
        let ratio = (priceRange.upperBound - price) / denom
        return min(max(mainTop + CGFloat(ratio) * mainHeight, mainTop), mainBottom)
    }

    /// 第二个光标相对第一个固定光标的横轴价格涨幅（基于第二个光标横线所在位置的价格 与 第一个固定光标横轴的固定价格；
    /// 第一个光标固定后平移/缩放会改变价格范围，必须用固定价格 pinnedPrice 作基准，否则用其像素反算会得到错误涨幅）
    private func secondCursorPriceChange(y: CGFloat, pinnedY: CGFloat?, pinnedPrice: Double?,
                                         mainTop: CGFloat, mainBottom: CGFloat, mainHeight: CGFloat) -> Double? {
        // 第一个光标的横轴价格：优先用固定价格；未固定（不在主图区域）时退化为按像素反算（通常为 nil）
        let p1: Double?
        if let pp = pinnedPrice, pp > 0 {
            p1 = pp
        } else {
            guard let pinnedY else { return nil }
            p1 = priceAtY(pinnedY, mainTop: mainTop, mainBottom: mainBottom, mainHeight: mainHeight)
        }
        guard let p1,
              let p2 = priceAtY(y, mainTop: mainTop, mainBottom: mainBottom, mainHeight: mainHeight),
              p1 > 0 else { return nil }
        return (p2 - p1) / p1 * 100
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
        MainChartCanvas(slice: mainMirrored ? mirroredSlice : slice, chartStyle: chartStyle, candleSpacing: candleSpacing, height: height,
                        priceMin: priceRange.lowerBound, priceMax: priceRange.upperBound,
                        curves: mainCurves.map { CanvasCurve(color: $0.color, values: mirroredSliceArr($0.values), style: $0.style, lineWidth: $0.lineWidth, barColor: $0.barColor, markerColors: sliceColors($0.markerColors)) },
                        upColor: upColor, downColor: downColor, gridColor: gridColor,
                        showGap: displaySettings.showGap, showLatestPriceLine: displaySettings.showLatestPriceLine,
                        gapDisappearAfterFill: displaySettings.gapDisappearAfterFill,
                        gaps: mainMirrored ? mirroredGaps : gaps, sliceStart: startIndex,
                        latest: mirroredLatest)
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
                           curves: m.curves.map { CanvasCurve(color: $0.color,
                                                              values: subMirroredSliceArr(m, $0.values),
                                                              style: $0.style, lineWidth: $0.lineWidth, barColor: $0.barColor) },
                           rangeMin: range.min, rangeMax: range.max,
                           upColor: upColor, downColor: downColor, gridColor: gridColor)
                .equatable()
                .offset(x: panOffset)
            // 顶底坐标值：VOL/AMO 最低值恒为 0，底部"0"无需显示；其他指标保留顶底两个值
            let labelRatios: [CGFloat] = (m.kind == .vol || m.kind == .amo) ? [0] : [0, 1]
            overlayPriceLabels(width: width, height: height, min: range.min, max: range.max,
                               ratios: labelRatios, formatter: subFmt)

            // 可交互光标（pin 开启时即第二个光标）与固定光标的副图竖线都绘制
            subCursorVLine(index: selectedIndex, compare: pinnedIndex, candleSpacing: candleSpacing, height: height)
            subCursorVLine(index: pinnedIndex, compare: nil, candleSpacing: candleSpacing, height: height)
        }
        .frame(width: width, height: height)
        .clipped()
        .overlay {
            swipeOverlay(slot: slot, width: width, height: height)
        }
    }

    /// 副图单个光标的竖线（可交互光标与固定光标共用；第二个光标蓝色、固定光标黑色）
    @ViewBuilder
    private func subCursorVLine(index: Int?, compare: Int?, candleSpacing: CGFloat, height: CGFloat) -> some View {
        if let index, index >= startIndex, index <= endIndex {
            let xPosition = (CGFloat(index - startIndex) + 0.5) * candleSpacing
            Rectangle().fill(compare != nil ? Color.blue : Color.black.opacity(0.45))
                .frame(width: 1.0, height: height)
                .position(x: xPosition, y: height / 2)
        }
    }

    /// 副图左右滑动切换反馈：常驻方向箭头 + 拖动时的滑轨/滑块/阈值动画
    /// 副图三不参与左右滑动切换，不显示任何切换提示
    @ViewBuilder
    private func swipeOverlay(slot: SubSlot, width: CGFloat, height: CGFloat) -> some View {
        if slot != .third {
            let fb = swipeFeedback
            let isDragging = fb?.slot == slot && (fb?.offset ?? 0).magnitude > 1
            let off = isDragging ? (fb?.offset ?? 0) : 0
            let canL = slot == .top ? canSwitchPeriod(1) : (canSwitchItem?(1) ?? false)
            let canR = slot == .top ? canSwitchPeriod(-1) : (canSwitchItem?(-1) ?? false)
            let threshold: CGFloat = 70
            ZStack {
            // 常驻方向箭头提示：可切换方向高亮，边界方向灰显
            HStack {
                swipeDirectionArrow(system: "chevron.left", can: canL,
                                    active: isDragging && off < 0)
                Spacer()
                swipeDirectionArrow(system: "chevron.right", can: canR,
                                    active: isDragging && off > 0)
            }
            .padding(.horizontal, 8)

            // 拖动中的滑轨动画
            if isDragging {
                let dir: CGFloat = off > 0 ? 1 : -1
                let reachable = off > 0 ? canR : canL
                let dist = min(abs(off), threshold)
                let cx = width / 2
                let ready = abs(off) > threshold
                let color: Color = reachable ? (ready ? Color.green : Color.white.opacity(0.9)) : Color.red
                // 轨道（从中心向拖动方向延伸）
                Capsule()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: dist, height: 6)
                    .position(x: cx + dir * dist / 2, y: height / 2)
                // 阈值刻度线
                if reachable {
                    Rectangle()
                        .fill(Color.white.opacity(0.7))
                        .frame(width: 1.5, height: 12)
                        .position(x: cx + dir * threshold, y: height / 2)
                }
                // 滑块
                Circle()
                    .fill(color)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                    .shadow(radius: 1)
                    .position(x: cx + dir * dist, y: height / 2)
                // 状态文字：超过阈值提示松手切换，未到阈值提示继续拖动，不可切换方向提示边界
                let text = reachable ? (ready ? "松开切换" : "继续拖动") : "无法切换"
                let textColor: Color = (reachable && !ready) ? Color.black : Color.white
                Text(text)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(textColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(color)
                    .cornerRadius(3)
                    .position(x: cx + dir * dist, y: height / 2 - 16)
            }
            }
            .allowsHitTesting(false)
        }
    }

    /// 副图滑动方向提示箭头
    private func swipeDirectionArrow(system: String, can: Bool, active: Bool) -> some View {
        Image(systemName: can ? system : (system + ".circle"))
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(can ? (active ? Color.white : Color.black.opacity(0.35)) : Color.gray.opacity(0.25))
            .frame(width: 22, height: 22)
            .background(can ? Color.black.opacity(active ? 0.5 : 0.08) : Color.clear)
            .clipShape(Circle())
    }

    private func subLegendRow(model m: SubChartModel, height: CGFloat) -> some View {
        ZStack {
            HStack(spacing: 8) {
                IndicatorNameButton(title: m.titleName, onTap: {
                    editingSlot = (m === subTop) ? .top : (m === subBottom ? .bottom : .third)
                    showMainSheet = false
                    withAnimation { showSubSheet.toggle() }
                })
                // VOL/AMO 的数值按转换单位显示（万/亿/万亿），其余指标按默认格式
                ForEach(Array(m.curves.enumerated()), id: \.offset) { _, line in
                    legendItem(line, mirrored: m.mirrored,
                               formatter: (m.kind == .vol || m.kind == .amo) ? { formatVolume($0) } : nil)
                }
                Spacer()
                // 多/空 镜像开关：VOL/AMO 数量无方向，不支持镜像（置灰）
                mirrorButton(isOn: m.mirrored, enabled: m.kind != .vol && m.kind != .amo) {
                    m.mirrored.toggle()
                }
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
                if isBareK { legendText("裸K") }
                ForEach(Array(mainCurves.enumerated()), id: \.offset) { _, line in
                    legendItem(line, mirrored: config.mainMirrored)
                }
                Spacer()
                // 多/空 镜像开关：开启后本图取负镜像（不重算指标，仅渲染取负）
                mirrorButton(isOn: config.mainMirrored, enabled: true) {
                    config.mainMirrored.toggle()
                    // 价格范围取负会改变固定光标的价格映射，切换时清除固定光标避免错位
                    pinnedIndex = nil; pinnedY = nil; pinnedPrice = nil
                    notifyHasCursor()
                }
                // 主图放大开关：进入后主图全屏裸K、显示全部 K 线；放大期间若双指缩放导致 K 线数变少，
                // 再次点击只重新全显（保持放大）；仅当全部 K 线都在屏幕内时才退出放大并恢复最新 100 根
                Button {
                    if mainFullscreen {
                        if count < maxVisibleCount {
                            // 放大模式下双指缩放后非全显：重新让所有 K 线进入屏幕，保持放大
                            withAnimation(.easeInOut(duration: 0.25)) {
                                visibleCount = CGFloat(maxVisibleCount)
                                endOffset = 0
                            }
                        } else {
                            // 所有 K 线都在屏幕内：退出放大，恢复最新 100 根 K 线
                            withAnimation(.easeInOut(duration: 0.25)) {
                                mainFullscreen = false
                                visibleCount = 100
                                endOffset = 0
                            }
                        }
                    } else {
                        // 进入放大：主图全屏裸K，所有 K 线进入屏幕
                        withAnimation(.easeInOut(duration: 0.25)) {
                            mainFullscreen = true
                            visibleCount = CGFloat(maxVisibleCount)
                            endOffset = 0
                        }
                    }
                    // 放大状态下双指缩放时，DragGesture 可能被 MagnificationGesture 抢占而 onEnded 未触发，
                    // 导致 drag.isDragging 残留 true 拦截后续指标重算；这里强制重置并 force 重算，
                    // 保证退出放大后主图和副图指标立即恢复计算
                    drag.isDragging = false
                    drag.needsRefreshAfterDrag = false
                    // 放大模式主图裸K、副图隐藏，无需预计算；退出放大后恢复预计算
                    if mainFullscreen {
                        prefetchToken = nil
                    } else {
                        startPrefetch()
                    }
                    refreshCurves(force: true)
                } label: {
                    // 图标语义：未放大或放大中需重新全显时显示"指向外"（点击进入放大/重新全显）；
                    // 全部 K 线已全显可关闭时显示"指向内"（点击退出放大）
                    let needShowAll = mainFullscreen && count < maxVisibleCount
                    Image(systemName: needShowAll ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(mainFullscreen ? .blue : .gray)
                        .frame(width: 22, height: 22, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mainFullscreen ? (count < maxVisibleCount ? "重新显示全部 K 线" : "退出主图放大") : "放大主图")
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(Color.white)
        }
        .frame(height: height)
    }

    /// 主图指标名称按钮：固定显示当前时间周期，如"日线: MA"、"周线: 裸K"
    private var mainLegendTitle: String {
        if isBareK { return "\(period.rawValue): 裸K" }
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
        case .macd, .vmacd, .wmacd: return { String(format: "%.3f", $0) }
        case .obv, .brar: return { String(format: "%.2f", $0) }
        default: return { String(format: "%.1f", $0) }
        }
    }

    private func legendItem(_ line: IndicatorLine, format: String = "%.2f", mirrored: Bool = false, formatter: ((Double) -> String)? = nil) -> some View {
        // NOTEXT_ 前缀的输出线：不显示名称也不显示数值（仅保留线条）
        if line.hideValue { return AnyView(EmptyView()) }
        let name = legendName(line)
        let color = line.color
        if let value = legendValueFor(line), !value.isNaN {
            let v = mirrored ? -value : value
            let valueText = formatter?(v) ?? String(format: format, v)
            return AnyView(Text("\(name):\(valueText)")
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

    /// 多/空 镜像切换按钮：默认"多"，开启后显示"空"（本图取负镜像）；disabled 时置灰
    private func mirrorButton(isOn: Bool, enabled: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            Text(isOn ? "空" : "多")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(!enabled ? Color.gray.opacity(0.35) : (isOn ? Color.blue : Color.gray))
                .frame(width: 20, height: 20)
                .background(enabled ? (isOn ? Color.blue.opacity(0.12) : Color.gray.opacity(0.1)) : Color.clear)
                .cornerRadius(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(isOn ? "关闭空头镜像" : "开启空头镜像")
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
        if v >= 1000000000000 { return String(format: "%.2f万亿", v / 1000000000000) }
        else if v >= 100000000 { return String(format: "%.2f亿", v / 100000000) }
        else if v >= 10000 { return String(format: "%.2f万", v / 10000) }
        else { return String(format: "%.0f", v) }
    }

    private func clampedAxisY(_ y: CGFloat, in height: CGFloat) -> CGFloat {
        let half: CGFloat = 8
        return min(max(y, half), max(half, height - half))
    }

    /// 主图竖轴顶部标签的垂直位置：单行时保持原轴顶对齐；两行（第二个光标）时整体下移，让标签完全落在主图内、顶部不外溢
    private func cursorTopLabelY(hasSecondLine: Bool, height: CGFloat) -> CGFloat {
        let half: CGFloat = hasSecondLine ? 15 : 8
        return min(max(half, 8), max(half, height - half))
    }

    /// 主图竖轴底部标签的垂直位置：单行时保持原底部对齐；两行（第二个光标）时整体上移，让标签完全落在主图内、底部不外溢
    private func cursorBottomLabelY(hasSecondLine: Bool, height: CGFloat) -> CGFloat {
        let half: CGFloat = hasSecondLine ? 15 : 9
        return min(max(height - half, half), max(half, height - 8))
    }

    /// 标签居中对齐后的实际中心 x（由 crosshairLabelAlignment 的对齐结果换算成中心坐标）
    private func labelCenter(_ align: Alignment, offset: CGFloat, labelWidth: CGFloat, width: CGFloat) -> CGFloat {
        switch align {
        case .leading: return labelWidth / 2
        case .trailing: return width - labelWidth / 2
        default: return width / 2 + offset
        }
    }

    /// 计算单个光标竖线标签（顶部日期/底部涨幅）与横线重叠时，横线需要让开的横向区间；
    /// 不重叠时返回 nil（横线完整绘制）。横线坐标 cy 为整图坐标，标签按 mainTop 换算。
    private func cursorLabelGap(index: Int, compare: Int?, cy: CGFloat,
                                candleSpacing: CGFloat, width: CGFloat,
                                mainTop: CGFloat, mainHeight: CGFloat) -> ClosedRange<CGFloat>? {
        guard index >= startIndex, index <= endIndex else { return nil }
        let xPos = (CGFloat(index - startIndex) + 0.5) * candleSpacing
        let stats = compare.flatMap { pinnedRangeStats(index, $0) }
        // 顶部日期标签：与该光标竖线顶部标签同尺寸同位置，重叠时在标签横向区间断开横线
        let dateText = sortedData[index].formattedDateWithWeekday
        let dateLine2 = stats.map { String(format: "%.2f%%  %+.2f%%  %+.2f%%  %+.2f%%", $0.amplitude, $0.drawdown, $0.rally, $0.change) }
        let dateW = dateLine2.map { labelTextWidth($0, fontSize: 10) } ?? labelTextWidth(dateText, fontSize: 10)
        let dateHalf: CGFloat = stats != nil ? 15 : 8
        let dateCenterY = mainTop + cursorTopLabelY(hasSecondLine: stats != nil, height: mainHeight)
        if cy >= dateCenterY - dateHalf && cy <= dateCenterY + dateHalf {
            let (a, o) = crosshairLabelAlignment(x: xPos, labelWidth: dateW, width: width)
            let c = labelCenter(a, offset: o, labelWidth: dateW, width: width)
            return (c - dateW / 2)...(c + dateW / 2)
        }
        // 底部涨幅标签：同理
        if let last = sortedData.last, last.close > 0, sortedData[index].close > 0 {
            let pct = (last.close - sortedData[index].close) / sortedData[index].close * 100
            let periodCount = max(0, (sortedData.count - 1) - index)
            let pctLine2 = stats.map { String(format: "%@  %@", formatVolume($0.volSum), formatAmount($0.amoSum)) }
            let pctW = pctLine2.map { labelTextWidth($0, fontSize: 10) } ?? labelTextWidth(String(format: "%+.2f%%  %d", pct, periodCount), fontSize: 10)
            let pctHalf: CGFloat = pctLine2 != nil ? 15 : 9
            let pctCenterY = mainTop + cursorBottomLabelY(hasSecondLine: pctLine2 != nil, height: mainHeight)
            if cy >= pctCenterY - pctHalf && cy <= pctCenterY + pctHalf {
                let (a, o) = crosshairLabelAlignment(x: xPos, labelWidth: pctW, width: width)
                let c = labelCenter(a, offset: o, labelWidth: pctW, width: width)
                return (c - pctW / 2)...(c + pctW / 2)
            }
        }
        return nil
    }

    /// 横线需要让开的横向区间数组：收集当前光标自己的竖线标签 + 对方光标的竖线标签中与横线重叠的全部区间；
    /// 两个光标的日期标签都在主图顶部、涨幅标签都在底部，横线到达时可能同时穿过多个标签，需全部断开。
    private func crosshairLineGap(index: Int?, compare: Int?, otherIndex: Int?, otherCompare: Int?,
                                  cy: CGFloat, candleSpacing: CGFloat, width: CGFloat,
                                  mainTop: CGFloat, mainHeight: CGFloat) -> [ClosedRange<CGFloat>] {
        var gaps: [ClosedRange<CGFloat>] = []
        if let index, let gap = cursorLabelGap(index: index, compare: compare, cy: cy,
                                               candleSpacing: candleSpacing, width: width,
                                               mainTop: mainTop, mainHeight: mainHeight) {
            gaps.append(gap)
        }
        if let otherIndex, let gap = cursorLabelGap(index: otherIndex, compare: otherCompare, cy: cy,
                                                    candleSpacing: candleSpacing, width: width,
                                                    mainTop: mainTop, mainHeight: mainHeight) {
            gaps.append(gap)
        }
        return gaps
    }

    private func timeAxis(width: CGFloat, candleSpacing: CGFloat, height: CGFloat) -> some View {
        let left = sortedData[startIndex].formattedDateWithWeekday
        let right = sortedData[endIndex].formattedDateWithWeekday
        return ZStack {
            // 指标覆盖进度条：直观显示已计算的历史范围（背景层，文字在上层不受影响）
            if showCoverageBar {
                coverageProgressBar(width: width, height: height)
            }
            HStack(spacing: 0) {
                Text(left).font(.system(size: 10)).foregroundColor(.gray)
                Text("   周期数\(count)个").font(.system(size: 10)).foregroundColor(.gray)
                Spacer()
            }
            Text(right).font(.system(size: 10)).foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .trailing)
            // 📌 开启且第一个固定光标存在时：固定光标的行情数据覆盖显示在时间轴上（第二个光标出现后依然持续显示）
            if let pinnedIndex, pinnedIndex >= startIndex, pinnedIndex <= endIndex {
                let item = sortedData[pinnedIndex]
                let prev = prevClose(of: pinnedIndex)
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

    /// 是否显示指标覆盖进度条：后台正确计算尚未覆盖全部历史（非放大模式），算完（bgCoverageEnd 到末尾）后消失
    private var showCoverageBar: Bool {
        !mainFullscreen && !sortedData.isEmpty && bgCoverageEnd < sortedData.count - 1
    }

    /// 时间轴栏中间的指标覆盖进度条：高亮段表示后台已正确计算的覆盖范围 [0...bgCoverageEnd]
    /// 占全部数据的比例（横向代表 旧→新），从数据开头（最左）向右逐块推进，直观显示当前标的
    /// 已"精确计算"了多少历史；与普通从左往右推动的进度条不同，它反映的是真实计算覆盖范围
    private func coverageProgressBar(width: CGFloat, height: CGFloat) -> some View {
        let total = CGFloat(max(1, sortedData.count))
        let endRatio = CGFloat(min(bgCoverageEnd, sortedData.count - 1) + 1) / total
        let barWidth = min(width * 0.72, 340)
        let barHeight: CGFloat = 4
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.gray.opacity(0.18))
            Capsule()
                .fill(Color.blue)
                .frame(width: max(0, barWidth * endRatio), height: barHeight)
        }
        .frame(width: barWidth, height: barHeight)
        .position(x: width / 2, y: height / 2)
        .animation(.easeInOut(duration: 0.15), value: bgCoverageEnd)
    }

    /// 时间轴上方新增的行情数据行：十字光标出现时显示光标所在K线 开/收/高/低/涨/额（涨为百分比），
    /// 无光标时显示当前屏幕最右边那根K线的行情数据（固定光标的行情数据改由时间轴覆盖显示）
    private func axisQuoteRow(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            // 光标出现时取光标所在K线，否则取屏幕最右边那根K线
            let quoteIndex = selectedIndex ?? endIndex
            if quoteIndex >= startIndex, quoteIndex <= endIndex, quoteIndex >= 0, quoteIndex < sortedData.count {
                let item = sortedData[quoteIndex]
                let prev = prevClose(of: quoteIndex)
                let changePct = prev > 0 ? (item.close - prev) / prev * 100 : 0
                // 空头镜像：开/收/高/低取负显示；涨跌幅取负后数值不变（分子分母同号）
                let o = mir(item.open), c = mir(item.close), h = mir(item.high), l = mir(item.low)
                let isUpMirror = mainMirrored ? !item.isUp : item.isUp
                HStack(spacing: 6) {
                    axisKV("开", String(format: "%.2f", o), .black)
                    axisKV("收", String(format: "%.2f", c), isUpMirror ? upColor : downColor)
                    axisKV("高", String(format: "%.2f", h), upColor)
                    axisKV("低", String(format: "%.2f", l), downColor)
                    axisKV("涨", String(format: "%+.2f%%", changePct), changePct >= 0 ? upColor : downColor)
                    axisKV("额", item.formattedTurnover, .black)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
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
    private func slotTitle(_ slot: SubSlot) -> String {
        switch slot {
        case .top: return "副图一"
        case .bottom: return "副图二"
        case .third: return "副图三"
        }
    }

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

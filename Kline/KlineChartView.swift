//
//  KlineChartView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/8/5.
//

import SwiftUI
import Combine
import UIKit

// MARK: - K线调试日志（可用开关控制）
/// 是否输出 [KlineDebug] 调试日志。排查副图曲线/后台预计算问题时改为 `true`，定位完成后改回 `false`。
/// 仅在 DEBUG 构建生效；发布构建（Release）完全不输出，无性能影响。
private let klineDebugLoggingEnabled = true

/// 统一调试日志入口：关闭时（或非 DEBUG 构建）不产生任何输出。
/// 用 @autoclosure 延迟字符串拼接，关闭时零开销。
private func klineDebug(_ message: @autoclosure () -> String) {
    #if DEBUG
    if klineDebugLoggingEnabled { print(message()) }
    #endif
}

/// 副图可选指标 id（对应 .tdx 文件名；VOL/AMO 为无模板的内置项）

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
    /// 双指手势进行中：平移/缩放由双指手势统一处理，单指手势应跳过，避免重复平移/误触发
    var twoFingerActive = false
}

// MARK: - 双指手势（UIKit）

/// 双指手势层：一个只覆盖「单个图表面板区域」的 UIKit 视图，挂 UIPinchGestureRecognizer。
/// SwiftUI 的 MagnificationGesture 只在「捏合（距离变化）」时激活、DragGesture 多指时不可靠，
/// 无法在双指固定距离平移时拿到整体横向位移；UIPinchGestureRecognizer 原生跟踪双指质心
/// （location(in:)）与缩放（scale），固定距离平移时质心移动也会持续触发。
/// 该视图按面板分片放置（主图/各副图各一块），不覆盖 legend 行的按钮；
/// 面板上的单指触摸沿 UIKit 响应链同时派发给祖先上的 SwiftUI 手势（chartDragGesture），
/// 因此单指平移/缩放/光标/副图切换不受影响。
struct TwoFingerGestureHook: UIViewRepresentable {
    let onBegin: (CGFloat) -> Void       // 手势起始：双指质心 x
    let onChange: (CGFloat, CGFloat) -> Void // 手势中：缩放 scale、质心横向位移增量 dx
    let onEnd: () -> Void

    func makeUIView(context: Context) -> TwoFingerHookView {
        let v = TwoFingerHookView()
        v.onBegin = onBegin
        v.onChange = onChange
        v.onEnd = onEnd
        return v
    }
    func updateUIView(_ uiView: TwoFingerHookView, context: Context) {
        uiView.onBegin = onBegin
        uiView.onChange = onChange
        uiView.onEnd = onEnd
    }
}

final class TwoFingerHookView: UIView, UIGestureRecognizerDelegate {
    var onBegin: ((CGFloat) -> Void)?
    var onChange: ((CGFloat, CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var lastCentroidX: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        let p = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        p.delegate = self
        addGestureRecognizer(p)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        let c = g.location(in: self)
        switch g.state {
        case .began:
            lastCentroidX = c.x
            onBegin?(c.x)
        case .changed:
            let dx = c.x - lastCentroidX
            lastCentroidX = c.x
            onChange?(g.scale, dx)
        case .ended, .cancelled, .failed:
            lastCentroidX = 0
            onEnd?()
        default:
            break
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
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

/// 指标柱状曲线颜色规则
enum BarColorMode: Equatable {
    case fixed       // 使用曲线自身颜色
    case sign        // 按柱值正负着色（MACD）
    case candle      // 按对应K线涨跌着色（量柱）
}

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
    @Published var showBareK = false
    // 当前行情周期（跨页面/跨标的持久，返回行情再进入时保持上次选择）
    @Published var selectedPeriod: KlinePeriod = .daily
    // K线类型与图层显示（设置面板）
    @Published var chartStyle: ChartStyle = .bare
    @Published var displaySettings = ChartDisplaySettings()
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
    /// 双联动时左视图（日线）占左右总宽的比例（不含分隔条）；持久记忆
    @Published var dualSplitRatio: Double = 0.5 {
        didSet { UserDefaults.standard.set(dualSplitRatio, forKey: Self.splitRatioKey) }
    }
    /// UserDefaults 键：双联动左右视图占比
    static let splitRatioKey = "kline.dualLink.splitRatio"

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
        subTop.kind = "CDJ"
        subBottom.kind = "COL"
        subThird.kind = "MACD"
        // 恢复双联动左右视图占比记忆（UserDefaults 里没有时用默认 0.5）
        let saved = UserDefaults.standard.double(forKey: Self.splitRatioKey)
        if saved > 0 { dualSplitRatio = saved }
    }
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

// MARK: - 主图数据驱动辅助（主图指标集合来自 .tdx，SCOPE=main）

/// 主图指标条目：启用的 .tdx 主图指标 + 主图自定义指标
struct MainIndicatorEntry {
    let id: String       // .tdx 文件名 id，或 MainIndicatorCache.customKey
    let formula: String
    let isCustom: Bool
}

/// 计算当前启用的主图指标条目（顺序：.tdx 主图 defs → 自定义）
private func mainIndicatorEntries(store: SystemIndicatorStore,
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
    guard !prefetchAllNaN(out.values) else { return nil }
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

// MARK: - 副图模型

final class SubChartModel: ObservableObject {
    @Published var kind: String = "VOL"
    @Published var activeCustomID: UUID? = nil
    @Published var titleName: String = "VOL"
    @Published var curves: [IndicatorLine] = [] {
        didSet {
            // 诊断：任何把「非空」副图曲线清成空的写操作都打印调用栈，定位变空根因
            if !oldValue.isEmpty && curves.isEmpty {
                klineDebug("[KlineDebug] ⚠️副图清空 \(kind) 旧=\(oldValue.count)->新=0 | 栈:\(Thread.callStackSymbols.prefix(10).joined(separator:" | "))")
            }
        }
    }
    @Published var color: Color = Color(hex: "0050FF")!

    var isCustom: Bool { activeCustomID != nil }
}

/// 单个副图槽位的一次选择记忆（指标类型 + 所属自定义指标 id）
struct SubChartSelection {
    var kind: String
    var customID: UUID?
}

/// 从一次副图选择构建独立实例（仅配置；titleName/color 由 recomputeSub 按指标重算补齐；双联动隔离用）
private func subModel(from s: SubChartSelection) -> SubChartModel {
    let m = SubChartModel()
    m.kind = s.kind
    m.activeCustomID = s.customID
    return m
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
    /// 是否使用独立的副图模型实例（双联动左右视图各用一套，避免共享模型被不同数据长度的曲线互相覆盖）
    private let isolatedSubs: Bool
    /// 接收联动光标并自动滚动到窗口外K线时，是否把该K线居中显示（左日线视图传 true，右周线视图保持贴右边缘的现有逻辑）
    private let linkAutoCenter: Bool
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
    /// 双视图联动同步（左日线/右周线共用；单视图时传入独立空对象，cursorDate 不变化、无副作用）。
    /// 用 @ObservedObject 观察其 cursorDate 变化，触发 .onChange 联动光标
    @ObservedObject var linkSync: DualLinkSync
    /// 联动：本视图是否正由用户直接拖动光标（用于区分「右侧用户操作」与「左侧拖动回声」）
    @State private var linkUserDragging = false
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
    /// 重置内置指标前的确认对话框
    @State private var showResetBuiltinConfirm = false
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
    @StateObject private var subTop: SubChartModel
    @StateObject private var subBottom: SubChartModel
    @StateObject private var subThird: SubChartModel

    /// 自定义指标公式编辑器是否打开（由详情页持有状态，打开时隐藏顶部栏实现真全屏）
    @Binding var showCustomEditor: Bool
    /// 系统指标公式编辑器是否打开（由详情页持有状态，打开时隐藏顶部栏实现真全屏）
    @Binding var showSystemEditor: Bool
    @State private var editorTarget: EditorTarget = .main
    /// 系统指标公式编辑目标：true=主图（可切换），false=副图（编辑 initialSubId）
    @State private var systemEditorIsMain: Bool? = nil
    @State private var systemEditorSubId: String = ""
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
         showSystemEditor: Binding<Bool> = .constant(false),
         metaId: Int? = nil,
         period: KlinePeriod = .daily,
         isolatedSubs: Bool = false,
         linkAutoCenter: Bool = false,
         onPeriodSwitch: ((KlinePeriod) -> Void)? = nil,
         onPeriodPrefetched: ((KlinePeriod) -> Void)? = nil,
         onSwitchItem: ((Int) -> Void)? = nil,
         canSwitchItem: ((Int) -> Bool)? = nil,
         pinEnabled: Binding<Bool> = .constant(false),
         onHasCursorChange: ((Bool) -> Void)? = nil,
         linkSync: DualLinkSync? = nil) {
        self.series = series
        self.metaId = metaId
        self.period = period
        self.isolatedSubs = isolatedSubs
        self.linkAutoCenter = linkAutoCenter
        self.onPeriodSwitch = onPeriodSwitch
        self.onPeriodPrefetched = onPeriodPrefetched
        self.onSwitchItem = onSwitchItem
        self.canSwitchItem = canSwitchItem
        self._pinEnabled = pinEnabled
        self.onHasCursorChange = onHasCursorChange
        self.linkSync = linkSync ?? DualLinkSync()
        self._chartStyle = chartStyle
        self._displaySettings = displaySettings
        self._showCustomEditor = showCustomEditor
        self._showSystemEditor = showSystemEditor
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
        // 副图复用共享仓库中的同一实例，保证切换周期/重新进入后指标不重置；
        // 双联动（isolatedSubs）时改用独立实例，复制共享配置，曲线各自按本视图数据计算，互不覆盖
        let store = ChartConfigStore.shared
        // 双联动隔离视图：直接按本视图周期解析三副图选择到独立实例（不落地共享模型，
        // 避免左右日线/周线先后 init 时互相覆盖选择，保证右周线副图也按周线自身记忆显示）
        if isolatedSubs {
            let sels = store.subSelections(for: period)
            // 用 @StateObject 保存隔离模型：@StateObject 只取首次创建的值并跨 re-init 稳定保留，
            // 避免双联动视图被反复 init 时 @ObservedObject 采纳新建空模型导致副图曲线清空
            self._subTop = StateObject(wrappedValue: subModel(from: sels[0]))
            self._subBottom = StateObject(wrappedValue: subModel(from: sels[1]))
            self._subThird = StateObject(wrappedValue: subModel(from: sels[2]))
        } else {
            // 非隔离：应用该周期记忆到共享模型并持有同一实例（保持跨页面/切周期指标不重置）
            store.applySubKinds(for: period)
            self._subTop = StateObject(wrappedValue: store.subTop)
            self._subBottom = StateObject(wrappedValue: store.subBottom)
            self._subThird = StateObject(wrappedValue: store.subThird)
        }
        // 同一标的内切换周期：从 (标的, 周期) 缓存恢复上次的计算结果与覆盖状态，
        // 保证切回该周期时已算过的部分不重算、不丢失（LRU 保留最近 3 个标的的所有周期）。
        // 仅当缓存所用指标配置指纹与当前一致时才恢复，否则视为无效、按新配置重新计算
        if let metaId {
            let entry = ChartCacheStore.shared.entry(for: metaId, period: period)
            let fingerprint = Self.currentConfigFingerprint(period: self.period)
            if entry.configFingerprint == fingerprint {
                _mainCurves = State(initialValue: entry.mainCurves)
                _mainCache = State(initialValue: entry.mainCache)
                _indicatorCoverageStart = State(initialValue: entry.coverageStart)
                _indicatorCoverageEnd = State(initialValue: entry.coverageEnd)
                _bgCoverageEnd = State(initialValue: entry.bgCoverageEnd)
            }
            // 注：副图曲线（subTop/subBottom/subThird）的恢复/清空不在此 init 做。
            // 这些是跨页面共享的 @ObservedObject 模型，而 KlineChartView 会因 body 重算被
            // SwiftUI 反复 init；若在 init 里按缓存清空/覆盖共享模型，会在光标变化等重算
            // 时把未切换副图的现有曲线清空（切指标后后台未完成时尤其明显）。
            // 副图曲线的正确性由 recomputeSub（其内部已含 bgCovered 时的缓存恢复路径）统一负责。
        }
    }

    /// 当前主图自定义指标（从共享仓库中按当前周期激活的 ID 派生）
    private var activeCustomIndicator: CustomIndicator? {
        customStore.indicators.first { $0.id == config.activeCustomIndicatorID(for: self.period) && availableInCurrentPeriod($0) }
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
    /// 可见 K 线数上限：非放大与放大模式都允许显示全部 K 线（不限制）
    private var capVisibleCount: Int { maxVisibleCount }
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

    /// 副图可见窗口曲线的取负版本（全局空头镜像开启时）
    private func subMirroredSliceArr(_ values: [Double]) -> [Double] {
        let s = sliceArr(values)
        guard config.mainMirrored else { return s }
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

    /// 指标栏取值：有光标时取光标值，否则取可见窗口最右侧值。
    /// 全部改为 O(1)/有界查找，避免拖拽时对整表做 O(n) 反向扫描（卡顿根源之一）。
    private func legendValue(_ arr: [Double]) -> Double? {
        if let idx = selectedIndex, idx >= 0, idx < arr.count, !arr[idx].isNaN { return arr[idx] }
        let start = min(endIndex, arr.count - 1)
        guard start >= 0 else { return nil }
        // 从最近K线（endIndex）往回取「最近」的有限值：未全量计算时曲线只覆盖可见窗口附近，
        // 覆盖区间起点的指标可能尚未收敛（值为 0/NaN）。若从 endIndex-250 递增取「最早」有限值，
        // 会命中覆盖起点的 0，导致图例误显示 0；应从 endIndex 递减取最近的有效值（图例应为当前值）。
        for i in stride(from: start, through: max(0, start - 250), by: -1) {
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
    /// 在可见窗口内已收敛、数值准确；也避免每次拖动/缩放后全量重算。
    /// 取 50 使前台近似总计算量 ≈ 可见窗口(默认100) + 预热(50) ≈ 150 根，降低打开标的时的卡顿；
    /// 长周期指标在可见窗口前段的收敛精度会略降，由后台分块预计算随后覆盖为正确值
    private let indicatorWarmup = 50
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
        // 后台正确计算已覆盖整个可见窗口且指标配置未变（如退出放大恢复显示）：
        // 直接从缓存恢复完整曲线，避免在主线程全量重算所有主图指标造成明显卡顿。
        // 配置真正变化时指纹不一致，不会命中恢复，照常走下方 force 重算
        if bgCoverageEnd >= endIndex, let metaId = metaId {
            let entry = ChartCacheStore.shared.entry(for: metaId, period: period)
            if entry.configFingerprint == Self.currentConfigFingerprint(period: self.period),
               entry.bgCoverageEnd >= endIndex, !entry.mainCurves.isEmpty {
                mainCurves = entry.mainCurves
                mainCache = entry.mainCache
                return
            }
        }
        // 后台正确计算已覆盖整个可见窗口（从数据开头起算，数值最正确）：
        // 未强制重算时直接复用后台结果；指标配置变化（force）时用正确覆盖区间重算，避免退化为近似
        let bgCovered = bgCoverageEnd >= endIndex
        if bgCovered, !force, !mainCurves.isEmpty { return }
        // 后台尚未覆盖可见窗口（如缩放到全部 / 滑到未算区域）：不在此同步计算近似指标，
        // 同步计算量随可见 K 数线性增长，显示全部时会阻塞主线程卡顿；保持当前已覆盖曲线，
        // 未覆盖部分渲染时因 NaN 自然显示裸K，由后台 prefetch 继续推进覆盖后替换
        if !force, !bgCovered, !mainCurves.isEmpty { return }
        var curves: [IndicatorLine] = []
        if !config.showBareK {
            let store = SystemIndicatorStore.shared
            let custom = activeCustomIndicator
            // 计算区间：后台已覆盖窗口时用后台正确覆盖 [0...bgCoverageEnd]，否则前台近似（窗口+预热，合并已算区间）
            let (calcStart, calcEnd) = bgCovered
                ? (0, bgCoverageEnd)
                : mergedCalcRange(needStart: indicatorCalcStart, needEnd: indicatorCalcEnd)

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
            for key in mainCache.units.keys where !activeIDs.contains(key) {
                mainCache.units[key] = nil
            }
        } else {
            // 裸K：不显示指标，清空自定义缓存（其余指标缓存保留，切回裸K时复用）
            mainCache.units[MainIndicatorCache.customKey] = nil
        }
        mainCurves = curves
        // 写回 (标的, 周期) 缓存：切走再回来时恢复主图曲线与覆盖状态，不重复计算
        if let metaId = metaId {
            let store = ChartCacheStore.shared
            let fp = Self.currentConfigFingerprint(period: self.period)
            // 配置已变：先失效旧缓存（清完成标记/覆盖/曲线），避免旧配置的“已完成”被误用
            if store.invalidateIfConfigChanged(metaId: metaId, period: period, currentFingerprint: fp) {
                // 本视图预计算进度也归零，避免写回 max 把缓存覆盖末端顶回旧值（否则恢复后 bgCovered 误判、副图空白）
                bgCoverageEnd = 0
                // 取消仍在跑的旧后台任务（其 request/增量状态属于旧配置），并立即用新配置重启，
                // 否则旧任务会以旧配置结果覆盖新配置曲线（切换指标后点击主图副图被清空/错乱）
                klineDebug("[KlineDebug] 主图配置变化 bgCoverageEnd=0 重启prefetch")
                prefetchToken = nil
                startPrefetch()
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
    private func mainRows(for id: String,
                          enabled: Bool,
                          formula: String?,
                          calcStart: Int, calcEnd: Int,
                          build: (Int, TDXOutputLine) -> IndicatorLine?) -> [IndicatorLine] {
        guard enabled, let formula else { return [] }
        var cache = mainCache.units[id] ?? MainIndicatorCache.UnitSet()
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
        mainCache.units[id] = cache
        return lines
    }

    /// 整行是否全为 NaN（周期为 0 的 MA 行等）
    private func allNaN(_ values: [Double]) -> Bool { values.allSatisfy { $0.isNaN } }

    /// 公式输出行颜色：优先公式 COLORXXX，否则用默认配色
    private func lineColor(from line: TDXOutputLine, fallback: Color) -> Color {
        if let hex = line.colorHex, let c = Color(hex: hex) { return c }
        return fallback
    }

    private func recomputeSub(_ m: SubChartModel, force: Bool = false) {
        // 诊断：每次调用都打印（含调用来源栈），定位曲线被清空的具体路径
        klineDebug("[KlineDebug] recomputeSub调用 \(m.kind) 现curves=\(m.curves.count) force=\(force) bgEnd=\(bgCoverageEnd) endIdx=\(endIndex) mainFS=\(mainFullscreen) 栈:\(Thread.callStackSymbols.prefix(3).joined(separator:" < "))")
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
            if !m.curves.isEmpty { klineDebug("[KlineDebug] 清空(mainFullscreen): \(m.kind)") }
            m.curves = []
            m.titleName = m.kind
            return
        }
        // 诊断：进入 recomputeSub 时曲线已为空（说明之前被某路径清空）
        if m.curves.isEmpty { klineDebug("[KlineDebug] recomputeSub进入时空: \(m.kind) bgEnd=\(bgCoverageEnd) endIdx=\(endIndex) force=\(force)") }
        // 后台正确计算已覆盖整个可见窗口且指标配置未变（如退出放大恢复显示）：
        // 直接从缓存恢复该槽位完整曲线，避免在主线程全量重算副图指标造成明显卡顿。
        // 配置真正变化时指纹不一致，不会命中恢复，照常走下方 force 重算
        if bgCoverageEnd >= endIndex, let metaId = metaId {
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
        let bgCovered = bgCoverageEnd >= endIndex
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
                bgCoverageEnd = 0
                prefetchToken = nil
                startPrefetch()
            }
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
        if m.kind == "VOL" || m.kind == "AMO" {
            // VOL/AMO 无公式模板，是成交量/成交额柱，最低值恒为 0
            let mx = values.max() ?? 1
            r = (0, mx * 1.08)
        } else if let mn = values.min(), let mx = values.max(), mn != mx {
            // 其余均为 .tdx 公式输出曲线，统一按实际数据 min/max 加留白，不按指标名特判
            let pad = (mx - mn) * 0.05
            r = (mn - pad, mx + pad)
        } else {
            r = (0, 100)
        }
        // 空头镜像（取负）：范围镜像为 (-max)...(-min)，曲线随之镜像
        if config.mainMirrored { return (-r.max, -r.min) }
        return r
    }

    // MARK: - 手势

    private var menuIsOpen: Bool { showMainSheet || showSubSheet || showCustomEditor || showSystemEditor }

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
                // 双指手势进行中：平移/缩放由双指手势统一处理，单指手势跳过，避免重复平移/误触发
                if drag.twoFingerActive { return }
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
                            linkUserDragging = true   // 用户直接拖动光标（用于联动来源标记）
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
                // 兜底：无论手势如何结束（含双指手势被中断），都清除双指状态，避免残留拦截后续单指拖动
                drag.twoFingerActive = false
                // 关键：无论手势如何结束（含提前 return 的分支），都必须重置拖拽状态，
                // 否则 isDragging 一直为 true，后续切换/修改指标的重算都会被跳过
                drag.isDragging = false
                // 用户拖动结束，清除联动来源标记（之后的光标变化都是回声/联动，不再触发左侧居中）
                linkUserDragging = false
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
                        // 点击创建光标也视为用户直接操作（联动来源标记），使右视图点击能同步到左视图
                        linkUserDragging = true
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

    // MARK: - 双指手势（由 TwoFingerGestureHook 回调驱动）

    /// 双指手势开始：以双指质心起始位置对应K线为缩放锚点，初始化缩放基准
    private func handleTwoFingerBegin(centroidX: CGFloat, width: CGFloat) {
        drag.twoFingerActive = true
        // 双指手势接管：复位单指光标拖动状态，避免粘滞导致联动被忽略
        linkUserDragging = false
        drag.cursorDragging = false
        selectedIndex = nil; crosshairY = nil
        zoomBase = visibleCount
        zoomAnchorIndex = nil
        let spacing = width / CGFloat(max(1, count))
        let anchor = startIndex + Int((max(0, centroidX) / spacing).rounded(.down))
        zoomAnchorIndex = clamp(anchor, 0, max(0, sortedData.count - 1))
        zoomAnchorOffset = (CGFloat(zoomAnchorIndex! - startIndex) + 0.5) * spacing
        // 手势不暂停后台预计算：进度条持续推进到消失
    }

    /// 双指手势中：质心横向位移 dx → 平移（锚点K线随双指移动）；缩放 scale → 围绕锚点缩放
    private func handleTwoFingerChange(scale: CGFloat, centroidDeltaX: CGFloat, width: CGFloat) {
        guard drag.twoFingerActive else { return }
        // 平移：锚点屏幕位置随双指质心整体横向位移移动
        zoomAnchorOffset += centroidDeltaX
        // 缩放：围绕锚点缩放（锚点K线保持在同一屏幕位置）
        let newCountF = clamp(zoomBase / scale, 20, CGFloat(capVisibleCount))
        let newCount = max(1, Int(newCountF.rounded()))
        visibleCount = newCountF
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

    /// 双指手势结束：复位缩放状态，恢复后台历史预计算
    private func handleTwoFingerEnd() {
        zoomBase = visibleCount
        zoomAnchorIndex = nil
        zoomAnchorOffset = 0
        drag.twoFingerActive = false
        startPrefetch()
    }

    /// 退出放大时按十字光标设定可见窗口：
    /// - 两个光标 A/B：显示 A前10根 + A + A与B之间 + B + B后10根
    /// - 一个光标：以光标为中心显示 100 根（前49 + 光标 + 后50）
    /// - 无光标：保持最新 100 根
    private func applyExitWindowFromCursors() {
        let maxEnd = max(0, sortedData.count - 1)
        // 两个光标（固定光标 + 活动光标）：A=左、B=右，显示 [A-10 ... B+10]
        if let aIdx = pinnedIndex, let bIdx = selectedIndex, aIdx != bIdx {
            let left = min(aIdx, bIdx)
            let right = max(aIdx, bIdx)
            let start = max(0, left - 10)
            let end = min(maxEnd, right + 10)
            visibleCount = CGFloat(max(20, end - start + 1))
            endOffset = max(0, maxEnd - end)
            return
        }
        // 一个光标：以光标所在K线为中心，前 49 + 1 + 后 50 = 100 根
        if let center = selectedIndex ?? pinnedIndex {
            let start = clamp(center - 49, 0, max(0, maxEnd - 99))
            let end = min(maxEnd, start + 99)
            visibleCount = 100
            endOffset = max(0, maxEnd - end)
            return
        }
        // 无光标：恢复最新 100 根
        visibleCount = 100
        endOffset = 0
    }

    /// 生成覆盖单个图表面板区域的双指手势层（按面板分片，不覆盖 legend 行的按钮）
    private func twoFingerLayer(width: CGFloat, rect: CGRect) -> some View {
        TwoFingerGestureHook(
            onBegin: { cx in handleTwoFingerBegin(centroidX: cx, width: width) },
            onChange: { scale, dx in handleTwoFingerChange(scale: scale, centroidDeltaX: dx, width: width) },
            onEnd: { handleTwoFingerEnd() }
        )
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
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
            let mainHeight = mainFullscreen
                // 放大模式：副图不显示，主图占满 legend 行 + 行情行 + 时间轴之外的剩余空间，
                // 保证 VStack 总高度仍等于屏幕高度，顶部 legend 栏和底部时间轴位置不因居中而偏移
                ? max(1, geometry.size.height - legendHeight - 2 * timeHeight)
                : max(1, chartHeight - sub1Height - sub2Height - sub3Height)

            let mainTop = legendHeight
            let mainBottom = mainTop + mainHeight
            let mainCenterY = mainTop + mainHeight / 2
            let s1Top = mainBottom + legendHeight
            let s1Bottom = s1Top + sub1Height
            let s2Top = s1Bottom + legendHeight
            let s2Bottom = s2Top + sub2Height
            let s3Top = s2Bottom + legendHeight
            let s3Bottom = s3Top + sub3Height

            ZStack {
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
                // 双指手势层：按面板分片覆盖（主图/各副图各一块），不覆盖 legend 行的按钮，
                // 面板上的单指触摸沿响应链派发给祖先 ZStack 上的 chartDragGesture
                twoFingerLayer(width: width, rect: CGRect(x: 0, y: mainTop, width: width, height: mainHeight))
                if !mainFullscreen {
                    twoFingerLayer(width: width, rect: CGRect(x: 0, y: s1Top, width: width, height: sub1Height))
                    twoFingerLayer(width: width, rect: CGRect(x: 0, y: s2Top, width: width, height: sub2Height))
                    twoFingerLayer(width: width, rect: CGRect(x: 0, y: s3Top, width: width, height: sub3Height))
                }
            }
            .contentShape(Rectangle())
            .gesture(chartDragGesture(width: width, candleSpacing: candleSpacing, mainTop: mainTop, mainBottom: mainBottom,
                                      s1Top: s1Top, s1Bottom: s1Bottom, s2Top: s2Top, s2Bottom: s2Bottom,
                                      s3Top: s3Top, s3Bottom: s3Bottom))
            .overlay {
                // 可交互光标（pin 开启时即第二个光标）与固定光标（pin 开启时的第一个）都绘制
                ZStack(alignment: .topLeading) {
                    cursorOverlay(index: selectedIndex, y: crosshairY ?? mainCenterY, compare: pinnedIndex, fixedPrice: nil, width: width, height: geometry.size.height,
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
                if showSystemEditor, let isMain = systemEditorIsMain {
                    SystemIndicatorEditorContainer(data: sortedData, isMain: isMain, period: self.period, initialSubId: systemEditorSubId) {
                        showSystemEditor = false
                    } onSaved: { _ in
                        if isMain {
                            recomputeMainCurves(force: true)
                        } else {
                            recomputeSub(model(for: editingSlot), force: true)
                        }
                    }
                    .zIndex(55)
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
        .onChange(of: selectedIndex) { newIdx in
            klineDebug("[KlineDebug] 光标变化(selectedIndex) -> new:\(String(describing: newIdx)) | 变化后副图:[\(subTop.kind):\(subTop.curves.count), \(subBottom.kind):\(subBottom.curves.count), \(subThird.kind):\(subThird.curves.count)] pinned:\(String(describing: pinnedIndex))")
            notifyHasCursor()
            publishLinkCursor(index: newIdx)
        }
        .onChange(of: pinnedIndex) { newIdx in
            klineDebug("[KlineDebug] 光标变化(pinnedIndex) -> new:\(String(describing: newIdx)) | 变化后副图:[\(subTop.kind):\(subTop.curves.count), \(subBottom.kind):\(subBottom.curves.count), \(subThird.kind):\(subThird.curves.count)] selected:\(String(describing: selectedIndex))")
            notifyHasCursor()
        }
        .onChange(of: linkSync.cursorDate) { date in
            applyLinkCursor(date)
        }
        .onChange(of: config.showBareK) { _ in
            // 顶部栏裸K按钮切换后立即重算（隐藏/恢复主图指标）
            recomputeMainCurves(force: true)
        }
        .onChange(of: config.mainMirrored) { _ in
            // 全局多/空镜像（顶部导航栏控制）切换：价格范围取负会改变固定光标的价格映射，
            // 切换时清除固定光标避免错位
            pinnedIndex = nil; pinnedY = nil; pinnedPrice = nil
            notifyHasCursor()
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

    /// 把本视图光标位置（日期，YYYYMMDD 整数）发布到共享联动对象（双联动时同步到另一视图）。
    /// 记录本次发布是否由「右侧视图用户直接操作」产生（左视图据此决定是否居中；自身回声不算）
    private func publishLinkCursor(index: Int?) {
        linkSync.lastCursorFromRightUser = !linkAutoCenter && linkUserDragging
        // 消费后立即复位，防止来源标记因手势中断/多次发布而粘滞
        linkUserDragging = false
        let date: Int?
        if let index, index < sortedData.count { date = sortedData[index].date } else { date = nil }
        klineDebug("[DualLink] publish \(period.rawValue) idx=\(String(describing: index)) date=\(String(describing: date)) fromRight=\(linkSync.lastCursorFromRightUser) dragging=\(linkUserDragging)")
        if linkSync.cursorDate != date { linkSync.cursorDate = date }
    }

    /// 应用另一视图发布的联动光标：把本视图光标移动到对应日期最近的 K 线
    private func applyLinkCursor(_ date: Int?) {
        klineDebug("[DualLink] applyLink \(period.rawValue) 进入 date=\(String(describing: date)) dragCursor=\(drag.cursorDragging) fromRight=\(linkSync.lastCursorFromRightUser) win=[\(startIndex)...\(endIndex)] sel=\(String(describing: selectedIndex))")
        // 本视图正在被用户直接拖动光标（手势进行中）：忽略联动。
        // 否则回声会把光标拽到别的K线，下一帧手指又拉回，产生"先出现在蜡烛图位置再闪到手指位置"的闪烁
        if drag.cursorDragging { klineDebug("[DualLink] \(period.rawValue) 守卫1拖动中忽略"); return }
        // 正在应用联动（非用户直接拖动）；复位来源标记，防止手势中断后粘滞
        linkUserDragging = false
        // 该日期正是本视图当前光标所在日期 → 自己发布的，忽略，避免回环
        if let idx = selectedIndex, idx < sortedData.count, sortedData[idx].date == date { klineDebug("[DualLink] \(period.rawValue) 守卫同日期忽略"); return }
        // 左视图只响应「右侧用户直接操作」产生的位置光标；自身回声不响应。
        // date == nil（取消）必须放行，否则右侧取消时左视图收不到、光标无法清除
        if linkAutoCenter && date != nil && !linkSync.lastCursorFromRightUser { klineDebug("[DualLink] \(period.rawValue) 守卫2非右用户忽略"); return }
        klineDebug("[DualLink] applyLink 进入 date=\(String(describing: date)) win=[\(startIndex)...\(endIndex)] n=\(sortedData.count) subs=[\(subTop.curves.count),\(subBottom.curves.count),\(subThird.curves.count)] bgEnd=\(bgCoverageEnd)")
        if let date {
            if let idx = nearestIndex(to: date) {
                // 仅当联动光标由「右侧用户直接操作」产生时才居中（避免左侧自身拖动被回声触发居中）
                if linkAutoCenter && linkSync.lastCursorFromRightUser {
                    // 始终居中：无论联动K线是否已在窗口内，都把窗口滚到使其居中显示
                    let half = count / 2
                    let targetEnd = min(sortedData.count - 1, max(count - 1, idx + half))
                    let newOffset = max(0, (sortedData.count - 1) - targetEnd)
                    if newOffset != endOffset {
                        endOffset = newOffset
                        refreshCurves()
                        startPrefetch()
                    }
                } else if idx < startIndex || idx > endIndex {
                    // 非居中（右周线，或左侧回声）：仅当联动K线在窗口外才滚动，贴右边缘
                    let targetEnd = min(sortedData.count - 1, max(idx, count - 1))
                    endOffset = max(0, (sortedData.count - 1) - targetEnd)
                    refreshCurves()
                    startPrefetch()
                }
                selectedIndex = idx
                crosshairY = nil   // 无真实触摸 y，交给 overlay 用主图中心渲染
            }
        } else {
            selectedIndex = nil
            crosshairY = nil
        }
        klineDebug("[DualLink] applyLink 结束 sel=\(String(describing: selectedIndex)) subs=[\(subTop.curves.count),\(subBottom.curves.count),\(subThird.curves.count)]")
        notifyHasCursor()
    }

    /// 找到日期与 target 最接近的 K 线索引（日/周视图跨周期联动用）
    private func nearestIndex(to target: Int) -> Int? {
        guard !sortedData.isEmpty else { return nil }
        if let exact = sortedData.firstIndex(where: { $0.date == target }) { return exact }
        var best = 0
        var bestDiff = abs(sortedData[0].date - target)
        for i in 1..<sortedData.count {
            let d = abs(sortedData[i].date - target)
            if d < bestDiff { bestDiff = d; best = i }
        }
        return best
    }

    private func refreshCurves(force: Bool = false) {
        klineDebug("[KlineDebug] refreshCurves force=\(force) bgEnd=\(bgCoverageEnd) endIdx=\(endIndex) cursor=\(selectedIndex == nil ? "无" : "有")")
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
               entry.configFingerprint == Self.currentConfigFingerprint(period: self.period) { return }
        }
        // 标记缓存条目正在预计算，避免后台「其它周期预计算」对该周期重复启动
        if let metaId = metaId {
            ChartCacheStore.shared.entry(for: metaId, period: period).isPrefetching = true
        }
        let token = UUID()
        prefetchToken = token
        // 完整基础序列只构建一次，各块共享引用（避免每块重复 map 全部基础数据）
        let series = TDXSharedSeries(data: sortedData)
        // 上一块算完后的增量状态（供下一块只算新增区间、复用前缀，避免每块从数据开头整段重算）；
        // 空数组 = 从头算。公式与上一块不一致（配置中途变化）时清空状态，防止新旧公式状态错位
        var resumingMain: [TDXIncrementalState?] = []
        var resumingSubs: [TDXIncrementalState?] = []
        var lastMainFormulas: [String] = []
        var lastSubFormulas: [String?] = []
        Task { @MainActor in
            while self.prefetchToken == token {
                // 指标/设置面板打开期间暂停预计算，避免空转与干扰面板操作
                if self.menuIsOpen {
                    await Task.yield()
                    continue
                }
                // 从数据开头（最左）向右推进：块大小随覆盖推进呈几何增长（每次约翻倍）。
                // 结合增量求值（上一块状态延续，每块只算新增区间）使总计算量 ≈ O(N)，
                // 接近一次全量，大幅缩短总耗时
                let currentEnd = max(0, self.bgCoverageEnd)
                let step = max(self.prefetchBlockSize, currentEnd)
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
                guard self.prefetchToken == token else { break }
                let shouldCommit = bgEnd >= self.endIndex && !self.drag.isDragging
                // 拖动中会跳过曲线提交；但若这一整块已覆盖到数据末尾（prefetch 即将结束），
                // 即使在拖动中也强制提交，否则覆盖末端已到末尾、曲线却因拖动中跳过提交而陈旧，
                // 退出拖动后 bgCovered 误判为已覆盖、prefetchDone 又跳过重启 → 指标永不补齐
                let isLastBlock = bgEnd >= self.sortedData.count - 1
                klineDebug("[KlineDebug] 后台块: bgEnd=\(bgEnd)/\(self.sortedData.count-1) shouldCommit=\(shouldCommit) isLast=\(isLastBlock) endIdx=\(self.endIndex) dragging=\(self.drag.isDragging)")
                self.commitPrefetch(request, result, updateCurves: shouldCommit || isLastBlock)
                self.bgCoverageEnd = bgEnd
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

    /// 主线程构造预计算每块的请求：快照裁剪数据、启用的指标公式与参数（全部 Sendable，可跨线程）。
    /// series 为完整基础序列（各块共享，避免重复 map）；resumingMain/resumingSubs 为上一块算完的
    /// 增量状态（与公式一一对应；空数组 = 从头算），后台只算新增区间、复用前缀
    private func makePrefetchRequest(calcStart: Int, calcEnd: Int, series: TDXSharedSeries,
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
    private func commitPrefetch(_ req: PrefetchCalcRequest, _ result: PrefetchCalcResult, updateCurves: Bool) {
        guard updateCurves else { return }
        // ===== 进入commit时的副图快照（任何修改前，诊断用）=====
        klineDebug("[KlineDebug] commit进入快照 | [\(subTop.kind):\(subTop.curves.count), \(subBottom.kind):\(subBottom.curves.count), \(subThird.kind):\(subThird.curves.count)] cursor=\(selectedIndex == nil ? "无" : "有") bgEnd=\(bgCoverageEnd)")
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
    private static func makeFullRequest(data: [KlineItem], period: KlinePeriod) -> PrefetchCalcRequest? {
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
    private static func commitToCache(_ req: PrefetchCalcRequest, _ result: PrefetchCalcResult,
                                      entry: ChartCacheStore.Entry, data: [KlineItem], fingerprint: String, period: KlinePeriod) {
        let config = ChartConfigStore.shared
        var curves: [IndicatorLine] = []
        let customStore = CustomIndicatorStore.shared
        let customColor = customStore.indicators.first { $0.id == config.activeCustomIndicatorID(for: period) }?.color
        for (idx, id) in req.mainIDs.enumerated() {
            guard idx < result.main.count else { continue }
            let isCustom = id == MainIndicatorCache.customKey
            for (i, out) in result.main[idx].enumerated() {
                guard !prefetchAllNaN(out.values) else { continue }
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
                    guard !prefetchAllNaN(out.values) else { continue }
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
        config.setActiveCustom(ind?.id, for: self.period)
        recomputeMainCurves(force: true)
    }

    private func activateSubCustom(_ m: SubChartModel, _ ind: CustomIndicator?) {
        m.activeCustomID = ind?.id
        ChartConfigStore.shared.recordSubKinds(for: self.period)
        recomputeSub(m, force: true)
    }

    private func syncCustomAfterStoreChange() {
        if let cur = config.activeCustomIndicatorID(for: self.period),
           !customStore.indicators.contains(where: { $0.id == cur }) {
            config.setActiveCustom(nil, for: self.period)
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
                                                              values: subMirroredSliceArr($0.values),
                                                              style: $0.style, lineWidth: $0.lineWidth, barColor: $0.barColor) },
                           rangeMin: range.min, rangeMax: range.max,
                           upColor: upColor, downColor: downColor, gridColor: gridColor)
                .equatable()
                .offset(x: panOffset)
            // 顶底坐标值：VOL/AMO 最低值恒为 0，底部"0"无需显示；其他指标保留顶底两个值
            let labelRatios: [CGFloat] = (m.kind == "VOL" || m.kind == "AMO") ? [0] : [0, 1]
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
        if klineDebugLoggingEnabled {
            for (i, line) in m.curves.enumerated() {
                let endV = endIndex < line.values.count ? line.values[endIndex] : Double.nan
                let nanCount = line.values.filter { $0.isNaN }.count
                let firstNonNaN = line.values.firstIndex { !$0.isNaN }.map { "startIdx=\($0)" } ?? "全NaN"
                let selV = (selectedIndex.flatMap { $0 < line.values.count ? line.values[$0] : nil }).map { "\($0)" } ?? "nil/越界"
                klineDebug("[KlineDebug] 副图legend \(m.kind) [\(i)]\(line.name) endIdx=\(endIndex) endV=\(endV) sel=\(String(describing: selectedIndex)) selV=\(selV) nan=\(nanCount)/\(line.values.count) \(firstNonNaN)")
            }
        }
        return ZStack {
            HStack(spacing: 8) {
                IndicatorNameButton(title: m.titleName, onTap: {
                    editingSlot = (m === subTop) ? .top : (m === subBottom ? .bottom : .third)
                    showMainSheet = false
                    withAnimation { showSubSheet.toggle() }
                })
                // VOL/AMO 的数值按转换单位显示（万/亿/万亿），其余指标按默认格式
                ForEach(Array(m.curves.enumerated()), id: \.offset) { _, line in
                    legendItem(line, mirrored: config.mainMirrored,
                               formatter: (m.kind == "VOL" || m.kind == "AMO") ? { formatVolume($0) } : nil)
                }
                Spacer()
                // 副图1：最右侧「回到最新」按钮（右指带尾单箭头）。
                // 屏幕最右 K 线不是最后一根时高亮可点；点击直接加载最新 K 线（屏幕显示 100 根）。
                if m === subTop {
                    let atLatest = endIndex >= sortedData.count - 1
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            visibleCount = 100
                            endOffset = 0
                        }
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(atLatest ? Color.gray.opacity(0.35) : Color.blue)
                            .frame(width: 22, height: 22, alignment: .center)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(atLatest)
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
                // 主图放大开关：进入后主图全屏裸K、显示全部 K 线；放大期间若双指缩放导致 K 线数变少，
                // 再次点击只重新全显（保持放大）；仅当全部 K 线都在屏幕内时才退出放大并恢复最新 100 根。
                // 存在两个十字光标时（无论放大还是非放大），点击不切换放大状态，只定位到两个光标之间的 K 线
                Button {
                    let hasTwoCursors = pinnedIndex != nil && selectedIndex != nil && pinnedIndex != selectedIndex
                    if hasTwoCursors {
                        // 存在两个十字光标：不切换放大/取消放大状态，
                        // 只让屏幕显示两个光标之间的 K 线（A前10 + A与B之间 + B + B后10）
                        withAnimation(.easeInOut(duration: 0.25)) {
                            applyExitWindowFromCursors()
                        }
                    } else if mainFullscreen {
                        if count < maxVisibleCount {
                            // 放大模式下双指缩放后非全显：重新让所有 K 线进入屏幕，保持放大
                            withAnimation(.easeInOut(duration: 0.25)) {
                                visibleCount = CGFloat(maxVisibleCount)
                                endOffset = 0
                            }
                        } else {
                            // 所有 K 线都在屏幕内：退出放大，按十字光标位置设定可见窗口
                            withAnimation(.easeInOut(duration: 0.25)) {
                                mainFullscreen = false
                                applyExitWindowFromCursors()
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
                    // 图标语义：存在两个十字光标时显示"放大镜"（点击只定位到两光标之间的 K 线，
                    // 不切换放大状态）；否则未放大或放大中需重新全显时显示"指向外"（点击进入放大/重新全显），
                    // 全部 K 线已全显可关闭时显示"指向内"（点击退出放大）
                    let hasTwoCursors = pinnedIndex != nil && selectedIndex != nil && pinnedIndex != selectedIndex
                    let needShowAll = mainFullscreen && count < maxVisibleCount
                    Image(systemName: hasTwoCursors ? "magnifyingglass"
                        : (needShowAll ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(hasTwoCursors ? .blue : (mainFullscreen ? .blue : .gray))
                        .frame(width: 22, height: 22, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel((pinnedIndex != nil && selectedIndex != nil && pinnedIndex != selectedIndex)
                    ? "显示两个光标之间的K线"
                    : (mainFullscreen ? (count < maxVisibleCount ? "重新显示全部 K 线" : "退出主图放大") : "放大主图"))
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
        let store = SystemIndicatorStore.shared
        var parts: [String] = []
        for def in store.mainIndicatorDefs(period: self.period) where config.mainIndicators(for: self.period).contains(def.id) {
            parts.append(def.name)
        }
        if let a = activeCustomIndicator { parts.append(a.name) }
        if parts.isEmpty { return "\(period.rawValue): 裸K" }
        return "\(period.rawValue): \(parts.joined(separator: "/"))"
    }

    /// 副图坐标数值格式化
    private func subFormatter(for kind: String) -> (Double) -> String {
        // VOL/AMO 按转换单位显示（万/亿/万亿）；其余均为 .tdx 公式输出，统一按量级自适应精度
        guard kind != "VOL", kind != "AMO" else { return { formatVolume($0) } }
        return { v in
            let av = abs(v)
            if av >= 1000 { return String(format: "%.0f", v) }
            if av >= 1 { return String(format: "%.2f", v) }
            return String(format: "%.3f", v)
        }
    }

    private func legendItem(_ line: IndicatorLine, format: String = "%.2f", mirrored: Bool = false, formatter: ((Double) -> String)? = nil) -> some View {
        // NOTEXT_ 前缀的输出线：不显示名称也不显示数值（仅保留线条）
        if line.hideValue { return AnyView(EmptyView()) }
        let name = legendName(line)
        let color = line.color
        if let value = legendValueFor(line), !value.isNaN {
            if value == 0 {
                klineDebug("[KlineDebug] ⚠️图例值=0 \(name) endIdx=\(endIndex) sel=\(String(describing: selectedIndex)) valuesCount=\(line.values.count) nan=\(line.values.filter{$0.isNaN}.count)")
            }
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
                    // 系统主图指标（数据驱动，集合来自 .tdx SCOPE=main）
                    groupHeader("主图指标")
                    LazyVGrid(columns: gridColumns, spacing: 8) {
                        ForEach(mainIndicatorDefsForSheet, id: \.id) { def in
                            mainTile(def.name, on: config.mainIndicators(for: self.period).contains(def.id)) { toggleMain(def.id) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 6)

                    // 系统指标公式编辑入口
                    if !mainIndicatorDefsForSheet.isEmpty {
                        paramEntryRow(title: "公式编辑") {
                            showMainSheet = false
                            systemEditorIsMain = true
                            showSystemEditor = true
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

    /// 主图选择页数据驱动指标列表（来自 .tdx SCOPE=main）
    private var mainIndicatorDefsForSheet: [SystemIndicatorDef] { SystemIndicatorStore.shared.mainIndicatorDefs(period: self.period) }
    private var mainCustoms: [CustomIndicator] { customStore.indicators.filter { $0.scope == .main && availableInCurrentPeriod($0) } }

    /// 该自定义指标是否适用于当前周期（适用范围为全周期 nil 也包含当前周期）
    private func availableInCurrentPeriod(_ ind: CustomIndicator) -> Bool {
        let applicable = CustomIndicatorStore.applicablePeriods(of: ind)
        return applicable.contains(period)
    }

    private func toggleMain(_ id: String) {
        config.toggleMainIndicator(id, period: self.period)
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
                    ForEach(subSelectionGroups, id: \.0) { g, kinds in
                        groupHeader(g)
                        LazyVGrid(columns: gridColumns, spacing: 8) {
                            ForEach(kinds, id: \.self) { k in
                                subTile(k, selected: !m.isCustom && m.kind == k) {
                                    m.activeCustomID = nil
                                    m.kind = k
                                    ChartConfigStore.shared.recordSubKinds(for: self.period)
                                    recomputeSub(m, force: true)
                                }
                            }
                        }
                        .padding(.horizontal, 16).padding(.bottom, 6)
                    }

                    // 公式式系统指标（有 .tdx 模板，如 MACD/KDJ）才提供公式编辑；VOL/AMO 无模板不提供
                    if !m.isCustom,
                       SystemIndicatorStore.shared.template(for: m.kind, period: self.period) != nil {
                        paramEntryRow(title: "\(m.kind) 公式编辑") {
                            showSubSheet = false
                            systemEditorIsMain = false
                            systemEditorSubId = m.kind
                            showSystemEditor = true
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

    /// 副图选择分组（数据驱动）：内置无模板的 VOL/AMO + 所有 SCOPE=sub 的 .tdx，按 GROUP 分组
    private var subSelectionGroups: [(String, [String])] {
        let store = SystemIndicatorStore.shared
        var map: [String: [String]] = [:]
        // 内置无模板项：VOL/AMO 走专用成交量柱绘制，不在 .tdx 中
        map["量能", default: []].append("VOL")
        map["量能", default: []].append("AMO")
        // .tdx 副图：GROUP 取自定义的 tdx 字段
        for def in store.subIndicatorDefs(period: self.period) {
            let g = def.group.isEmpty ? "其他" : def.group
            map[g, default: []].append(def.id)
        }
        var result: [(String, [String])] = []
        for g in SystemIndicatorStore.subGroupOrder where map[g] != nil {
            result.append((g, map[g]!))
        }
        for g in map.keys where !SystemIndicatorStore.subGroupOrder.contains(g) {
            result.append((g, map[g]!))
        }
        return result
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

    private var subCustoms: [CustomIndicator] { customStore.indicators.filter { $0.scope == .sub && availableInCurrentPeriod($0) } }
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
            Button("重置内置指标") { showResetBuiltinConfirm = true }
                .font(.system(size: 13)).foregroundColor(.red)
            Button("完成") { onClose() }.font(.system(size: 14)).foregroundColor(.blue)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .alert("重置内置指标", isPresented: $showResetBuiltinConfirm) {
            Button("重置", role: .destructive) { performResetBuiltin() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把所有内置指标恢复为编译时的内容，确定重置吗？")
        }
    }

    /// 重置所有内置指标为编译时内容，并立即重算主图与三个副图
    private func performResetBuiltin() {
        SystemIndicatorStore.shared.restoreAllBuiltin(period: self.period)
        recomputeMainCurves(force: true)
        for m in [subTop, subBottom, subThird] { recomputeSub(m, force: true) }
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

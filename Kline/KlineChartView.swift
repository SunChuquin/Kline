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
/// 调试日志总开关：false = 关闭所有调试控制台输出（联动/副图/光标/预计算等）。
/// private let 常量在 Release 下由编译器做死代码消除，无任何运行时开销。
private let klineDebugLoggingEnabled = false

/// 统一调试日志入口：总开关为 false 时直接空实现；@autoclosure 保证字符串拼接零开销。
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
    /// 隐藏主图指标数值栏右侧的「放大/缩放」按钮（联动多视图场景不提供主图放大）
    private let hideMainZoomButton: Bool
    /// 是否为联动多图 tile（影响时间轴周期数显示等联动专属样式）
    private let isLinkedTile: Bool
    /// 历史保留的透传参数：早期左右视图不对称联动时，仅部分视图据此决定是否居中。
    /// 当前对称联动语义下，所有视图每次收到联动都一律滚动居中，本字段已无读取方，仅沿调用链透传。
    private let linkAutoCenter: Bool
    /// 光标联动开关（详情页顶部「联」字按钮的联动态）：
    ///   true  → 本视图光标主动 publish 到 linkSync，并 apply 其它视图的联动
    ///   false → 视图光标完全独立，不参与发布与接收
    let cursorLinkEnabled: Bool
    /// 清光标广播令牌（外层切换 cursorLinkEnabled 或整体退出联动时更新 UUID，
    /// 本视图 onChange 清空自身 selectedIndex/pinnedIndex 等所有光标状态）
    let cursorClearToken: UUID
    /// 联动复盘：本视图显示标的的 metaID（tile 传入；单图为 nil）。
    /// 大周期视图合成"形成中K线"时，用它取**本标的**的来源周期数据（跨标的互不借用）。
    let linkedMetaID: Int?
    /// 联动模式下隐藏行情行里的"额"（成交额）字段：时间轴上一行 与 时间轴内 pinned 覆盖 均隐藏
    let hideQuoteTurnover: Bool
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
    /// 禁止产生十字光标（「边」调节分割线状态开启时置 true）：点击/拖动/联动都不生成光标
    let suppressCrosshair: Bool
    /// 联动态交换副图滑动角色：副图一(上)切标的、副图二(下)切周期（常规模式相反）
    let swapSubSwipeRoles: Bool
    /// 副图二指标栏最右侧是否显示 🔍 搜索按钮（点击由外层接管，用于覆盖式搜索栏）
    let showSubTwoSearchButton: Bool
    /// 副图二 🔍 按钮点击回调
    let onSubTwoSearch: (() -> Void)?
    /// 信息栏「主图指标名称按钮」桥接：非 nil 时按钮不在图表内渲染，
    /// 由外层（详情页信息栏最左侧）显示，标题/点击行为通过它同步
    let mainLegendPortal: MainLegendPortal?
    /// 双视图联动同步（左日线/右周线共用；单视图时传入独立空对象，cursorDate 不变化、无副作用）。
    /// 用 @ObservedObject 观察其 cursorDate 变化，触发 .onChange 联动光标
    @ObservedObject var linkSync: DualLinkSync
    /// 联动复盘源周期数据缓存：目标大周期视图在来源数据到达后重绘合成K线
    @ObservedObject var linkSourceCache = LinkSourceBarCache.shared
    /// 联动：本视图是否正由用户直接拖动光标（用于区分「右侧用户操作」与「左侧拖动回声」）
    @State var linkUserDragging = false
    /// 联动复盘 as-of 结果模型：主图曲线/三副图按数组下标的合成点值 + 后台任务序号。
    /// 全部为低频异步写入（合成内容/光标/配置变化时才调度），封装成 ObservableObject 以收敛视图属性区；
    /// 无 .onChange 挂钩，写入仍触发本视图 body 重绘（与原 @State 行为一致，性能中性）。
    @StateObject var asOfModel = ReplayAsOfModel()
    @Binding var chartStyle: ChartStyle
    @Binding var displaySettings: ChartDisplaySettings
    /// 联动多图模式：本视图在联动布局里的下标（用于判定「谁是当前激活公式编辑器的视图」）
    let selfIndex: Int
    /// 当前正在编辑公式的联动视图下标（detail 持有）；nil = 无编辑器打开。
    /// 所有联动 tile 共享同一 showCustomEditor，仅 owner（selfIndex == editorOwnerIndex）真正弹出全屏编辑器，
    /// 避免多个 tile 同时弹出半屏编辑器。
    @Binding var editorOwnerIndex: Int?
    /// 编辑器被激活时冒泡（联动 tile 据此把 editorOwnerIndex = 自己下标）。
    var onEditorActivate: (() -> Void)?
    /// 进入时用该值初始化可见K线数（缩放级别）。nil = 用默认 100。仅联动视图由 LinkedViewStore 传入持久化值。
    var initialVisibleCount: CGFloat? = nil
    /// 可见K线数变化回调（联动持久化缩放级别用）。nil = 不回调（单图模式无需持久化）。
    var onVisibleCountChange: (@MainActor (CGFloat) -> Void)? = nil

    // 交互状态
    @State var selectedIndex: Int? = nil
    /// 联动开启后、非来源的**小周期范围框视图**里的「第二个十字光标」：纯本地状态，
    /// 不发布到 linkSync、不影响来源视图的合成/淡化、也不会让其他视图出现第二份光标；
    /// 各视图相互独立。仅来源视图再点一下（或任何全局清场）时才清除。
    @State var secondCursorIndex: Int? = nil
    @State var secondCursorY: CGFloat? = nil
    /// 副图三「裸」按钮控制的主图裸K：仅隐藏主图指标显示，不触发重算、不清除 mainCurves 缓存
    @State private var bareFromSub = false
    /// 联动光标会话标记：收到有效联动光标/范围时置 true，来源光标消失时置 false。
    /// 当前实现下每次 applyLinkCursor 都无条件把目标K线（或范围）滚动居中，居中不再依赖本标记
    /// （旧「仅第一次出现时居中、之后拖动只移动不居中」的语义已废弃）；目前只写不读，
    /// 保留以便日后需要区分「首次出现 / 持续拖动」时复用。
    @State var linkCursorActive = false
    /// 📌 开启时固定下来的第一个光标（不可被点击清除；只随 pinEnabled 关闭而清除）
    @State private var pinnedIndex: Int? = nil
    @State private var pinnedY: CGFloat? = nil
    /// 固定光标固定时刻的横轴价格（仅主图区域有效）：平移/缩放后横轴价格不随可见窗口价格范围变化
    @State private var pinnedPrice: Double? = nil
    @State var visibleCount: CGFloat = 100
    @State var endOffset: Int = 0
    @State private var zoomBase: CGFloat = 100
    // 缩放锚点：以双指位置对应的K线为基线缩放（而非屏幕最右端）
    @State private var zoomAnchorIndex: Int? = nil
    @State private var zoomAnchorOffset: CGFloat = 0
    @State var drag = DragState()
    /// 亚像素平移偏移（px）：缓慢拖动时画面平滑跟手，累计满一根K线间距才进位移动可见窗口
    @State private var panOffset: CGFloat = 0
    /// 副图左右滑动切换的拖动反馈动画状态（nil = 未在拖动副图）
    @State var swipeFeedback: SwipeFeedback? = nil
    /// 「副图滑动回调外层 onPeriodSwitch / onSwitchItem」的一次性触发守卫。
    ///
    /// 解决联动态的致命双触发问题：用户在副图二上完成一次阈值滑动后，onEnded 回调会触发一次
    /// 外层 onPeriodSwitch(newPeriod) → 外层把 view.period 从 A 改到 B → 本 tile 的
    /// .id(chartIdentity = meta-period) 变值 → SwiftUI 立刻销毁本 KlineChartView 旧实例、
    /// 创建新实例。销毁发生在同一个 runloop 的稍晚时刻，如果老实例的 swipeFeedback @State
    /// 还没被 nil'd （或者 onEnded 又因手势状态机对已销毁 view 重入一次），老实例会再回调
    /// 一次外层 onPeriodSwitch(old_period 的方向推算) → 把 B 拉回 A → 于是日志里出现：
    /// 「loadData⤴️B ✅ rows=...」 → 0.x 秒后「loadData⤴️A ✅ rows=...」，最终屏幕显示
    /// A 数据 + 信息栏周期 = B，经典"日线显示周线数据"观感。
    ///
    /// 修复：同一次 swipeFeedback 设置 → onEnded 结算 的手势生命周期内，外层回调（切换
    /// 周期/切换标的）**最多执行一次**；执行完毕后把此锁置 true，直到下一次新的
    /// swipeFeedback 被创建（nil→非nil）才解锁。
    @State private var swipeSubSlotTriggered = false
    @State private var crosshairY: CGFloat? = nil
    /// 全数据集预计算的跳空缺口（只在数据加载时计算一次，避免每次重绘全量扫描）
    @State private var gaps: [GapInfo] = []
    @ObservedObject var customStore = CustomIndicatorStore.shared
    @ObservedObject var config = ChartConfigStore.shared

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
    @StateObject var subTop: SubChartModel
    @StateObject var subBottom: SubChartModel
    @StateObject var subThird: SubChartModel

    /// 自定义指标公式编辑器是否打开（由详情页持有状态，打开时隐藏顶部栏实现真全屏）
    @Binding var showCustomEditor: Bool
    /// 系统指标公式编辑器是否打开（由详情页持有状态，打开时隐藏顶部栏实现真全屏）
    @Binding var showSystemEditor: Bool
    /// 编辑器 / 指标面板的 UI 瞬时状态（sheet 开关、编辑器目标、挂起重算）。
    /// 全部低频离散、无 .onChange 挂钩，封装成 ObservableObject 以收敛视图属性区；写入触发本视图重绘，性能中性。
    @StateObject var editorUI = ChartEditorUIState()

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
         hideMainZoomButton: Bool = false,
         isLinkedTile: Bool = false,
         linkAutoCenter: Bool = false,
         cursorLinkEnabled: Bool = false,
         cursorClearToken: UUID = UUID(),
         linkedMetaID: Int? = nil,
         hideQuoteTurnover: Bool = false,
         onPeriodSwitch: ((KlinePeriod) -> Void)? = nil,
         onPeriodPrefetched: ((KlinePeriod) -> Void)? = nil,
         onSwitchItem: ((Int) -> Void)? = nil,
         canSwitchItem: ((Int) -> Bool)? = nil,
         pinEnabled: Binding<Bool> = .constant(false),
         onHasCursorChange: ((Bool) -> Void)? = nil,
         suppressCrosshair: Bool = false,
         swapSubSwipeRoles: Bool = false,
         showSubTwoSearchButton: Bool = false,
         onSubTwoSearch: (() -> Void)? = nil,
         mainLegendPortal: MainLegendPortal? = nil,
         linkSync: DualLinkSync? = nil,
         selfIndex: Int = 0,
         editorOwnerIndex: Binding<Int?> = .constant(nil),
         onEditorActivate: (() -> Void)? = nil,
         initialVisibleCount: CGFloat? = nil,
         onVisibleCountChange: (@MainActor (CGFloat) -> Void)? = nil) {
        self.series = series
        self.metaId = metaId
        self.period = period
        self.isolatedSubs = isolatedSubs
        self.hideMainZoomButton = hideMainZoomButton
        self.isLinkedTile = isLinkedTile
        self.linkAutoCenter = linkAutoCenter
        self.cursorLinkEnabled = cursorLinkEnabled
        self.cursorClearToken = cursorClearToken
        self.linkedMetaID = linkedMetaID
        self.hideQuoteTurnover = hideQuoteTurnover
        self.onPeriodSwitch = onPeriodSwitch
        self.onPeriodPrefetched = onPeriodPrefetched
        self.onSwitchItem = onSwitchItem
        self.canSwitchItem = canSwitchItem
        self._pinEnabled = pinEnabled
        self.onHasCursorChange = onHasCursorChange
        self.suppressCrosshair = suppressCrosshair
        self.swapSubSwipeRoles = swapSubSwipeRoles
        self.showSubTwoSearchButton = showSubTwoSearchButton
        self.onSubTwoSearch = onSubTwoSearch
        self.mainLegendPortal = mainLegendPortal
        self.linkSync = linkSync ?? DualLinkSync()
        self.selfIndex = selfIndex
        self._editorOwnerIndex = editorOwnerIndex
        self.onEditorActivate = onEditorActivate
        self.initialVisibleCount = initialVisibleCount
        self.onVisibleCountChange = onVisibleCountChange
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
        // 周期签名校验（声明周期 vs K 线尾部日期间距推断周期）放在 onAppear 执行，
        // 不在 init 阶段跑：避免 Xcode Debug 模式在 init 阶段执行 Calendar/日期相关代码
        // 或 Main Thread Checker / Swift Concurrency 检查时触发断言，出现详情页崩溃。
    }

    /// 当前主图自定义指标（从共享仓库中按当前周期激活的 ID 派生）
    var activeCustomIndicator: CustomIndicator? {
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

    var sortedData: [KlineItem] { sortedAll }
    private var closes: [Double] { baseCloses }
    private var highs: [Double] { baseHighs }
    private var lows: [Double] { baseLows }
    private var opens: [Double] { baseOpens }
    private var volumes: [Double] { baseVolumes }
    private var turnovers: [Double] { baseTurnovers }

    // MARK: - 可见窗口

    var count: Int { min(max(20, Int(visibleCount.rounded())), capVisibleCount) }
    private var maxVisibleCount: Int { sortedData.count }
    /// 可见 K 线数上限：非放大与放大模式都允许显示全部 K 线（不限制）
    var capVisibleCount: Int { maxVisibleCount }
    var endIndex: Int {
        let maxEnd = sortedData.count - 1
        let minEnd = max(0, count - 1)
        return min(maxEnd, max(minEnd, maxEnd - endOffset))
    }
    var startIndex: Int { max(0, endIndex - count + 1) }
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
    var mainMirrored: Bool { config.mainMirrored }

    /// 取负：主图开启镜像时把数值取负
    func mir(_ v: Double) -> Double { mainMirrored ? -v : v }

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
        if let idx = legendCursorIndex, idx >= 0, idx < arr.count, !arr[idx].isNaN { return arr[idx] }
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
    private var isBareK: Bool { bareFromSub || config.showBareK || mainFullscreen }

    /// 自定义公式编辑器全屏弹出控制：单图直接挂 showCustomEditor；联动仅「激活者」tile 弹出。
    private var customEditorBinding: Binding<Bool> {
        Binding(
            get: { showCustomEditor && (!isLinkedTile || editorOwnerIndex == selfIndex) },
            set: { if !$0 { showCustomEditor = false } }
        )
    }
    /// 系统指标编辑器全屏弹出控制：同上。
    private var systemEditorBinding: Binding<Bool> {
        Binding(
            get: { showSystemEditor && (!isLinkedTile || editorOwnerIndex == selfIndex) },
            set: { if !$0 { showSystemEditor = false } }
        )
    }

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
        if menuIsOpen { editorUI.pendingMainRefresh = true; return }
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
                calcEnd = bgCoverageEnd
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
            calcEnd = bgCoverageEnd
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

    private var menuIsOpen: Bool { editorUI.showMainSheet || editorUI.showSubSheet || showCustomEditor || showSystemEditor }

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
                // 手势作用域固定为起点所在区域：主图/副图1/副图2；滑出起点区域后仍以起点区域处理。
                // 副图3（最下方副图）面板触摸手势**整体禁用**（单指点击/拖动/平移都不响应）：
                // 该区域预留给后续类手游虚拟按钮使用。副图三仍正常显示指标曲线与贯穿光标竖线，
                // 其指标名称/参数按钮在面板外的 legend 行，不受影响（单图/联动多图均走同一图表，同时生效）。
                let sy = value.startLocation.y
                let startInMain = isInPanel(sy, mainTop, mainBottom)
                let startInS1 = isInPanel(sy, s1Top, s1Bottom)
                let startInS2 = isInPanel(sy, s2Top, s2Bottom)
                guard startInMain || startInS1 || startInS2 else { return }
                // 联动会话中非来源的**同周期**视图：忽略一切单指操作
                // （不接管来源、不平移缩放、不放光标；双指平移/缩放在独立手势层，不受影响）
                if isLinkedFrozenView { return }
                // 联动会话中非来源的小周期范围框 / 大周期复盘视图：
                // - 本地第二光标**已存在** → 单指拖动只移动第二光标（不接管来源、不平移缩放）；
                // - 第二光标**不存在** → 不拦截，单指照常走下方 pan/zoom 与副图滑动逻辑（双指缩放在独立手势层，始终可用）。
                if isLinkedSecondCursorView && secondCursorIndex != nil {
                    drag.isDragging = true
                    drag.lastTouchX = value.location.x
                    if abs(value.translation.width) > 6 || abs(value.translation.height) > 6 {
                        let col = Int((value.location.x / candleSpacing).rounded(.down))
                        let idx = startIndex + col
                        if idx >= startIndex && idx <= endIndex {
                            secondCursorIndex = idx
                            secondCursorY = value.location.y
                            drag.secondCursorDragging = true   // 注意：不能写 drag.cursorDragging，否则会隐藏范围框
                        }
                    }
                    return
                }
                drag.isDragging = true
                // 记录最近触摸位置，作为双指缩放时的锚点（双指质心）
                drag.lastTouchX = value.location.x

                // 副图左右滑动切换：起点在副图且无光标时实时更新拖动反馈动画（显示方向提示/滑轨/阈值）
                if (startInS1 || startInS2) && selectedIndex == nil {
                    let slot: SubSlot = startInS1 ? .top : .bottom
                    let (canL, canR) = subSwipeCanLeftRight(slot: slot)
                    let wasNil = swipeFeedback == nil
                    swipeFeedback = SwipeFeedback(slot: slot, offset: value.translation.width,
                                                  canLeft: canL, canRight: canR)
                    // 一次新手势开始（nil → 非 nil）解锁「一次切换只允许回调外层一次」的锁。
                    // 见 swipeSubSlotTriggered 注释。
                    if wasNil { swipeSubSlotTriggered = false }
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
                // 兜底：无论手势如何结束（含双指手势被中断），都清除双指状态，避免残留拦截后续单指拖动
                drag.twoFingerActive = false
                // 联动非来源的**同周期**视图：单指手势全程忽略，不产生任何光标/窗口变化
                if isLinkedFrozenView {
                    drag.isDragging = false
                    drag.cursorDragging = false
                    drag.secondCursorDragging = false
                    return
                }
                // 联动非来源的小周期范围框 / 大周期复盘视图且本地第二光标**已存在**：
                // 拖动结束复位标记；轻点则只在本地取消第二光标（不发布、不影响来源视图的
                // 合成/范围框与其他视图；整组联动的取消仍由来源视图再点一下负责）。
                // 第二光标不存在时不走这里——复盘/范围框视图的拖动是正常 pan/zoom，轻点在下方放置第二光标。
                if isLinkedSecondCursorView && secondCursorIndex != nil {
                    let wasSecondDragging = drag.secondCursorDragging
                    drag.isDragging = false
                    drag.secondCursorDragging = false
                    panOffset = 0
                    guard !menuIsOpen, !suppressCrosshair else { return }
                    if !wasSecondDragging {
                        let y = value.location.y
                        let inPanel = isInPanel(y, mainTop, mainBottom)
                            || isInPanel(y, s1Top, s1Bottom) || isInPanel(y, s2Top, s2Bottom)
                        let isTap = abs(value.translation.width) < 6 && abs(value.translation.height) < 6
                        if isTap && inPanel { clearSecondCursor() }
                    }
                    return
                }
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
                    // 非来源复盘/范围框视图在副图区的**轻点**（第二光标不存在时手势才会走到这里）：
                    // 第二光标只允许在主图区域放置，副图一/副图二区域轻点仅回弹滑动反馈，
                    // 不放置第二光标、不触发切周期/标的（副图三面板手势本就整体禁用）
                    if isLinkedSecondCursorView,
                       abs(value.translation.width) < 6, abs(value.translation.height) < 6 {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { swipeFeedback = nil }
                        return
                    }
                    let threshold: CGFloat = 70
                    let dir = fb.offset > 0 ? -1 : 1   // 右滑=更小周期/上一个标的，左滑=更大周期/下一个标的
                    // 副图一（上方副图）作用调转：往左=切换小级别/上一个标的，往右=切换大级别/下一个标的
                    let topDir = -dir
                    let triggeredSwitch: Bool
                    if abs(fb.offset) > threshold {
                        // 一次性锁：同一次 swipeFeedback 手势生命周期，外层回调只许一次
                        if !swipeSubSlotTriggered {
                            swipeSubSlotTriggered = true
                            selectedIndex = nil; crosshairY = nil
                            clearSecondCursor()
                            // 联动态：副图一切标的、副图二切周期（与常规模式交换角色的作用域）
                            if swapSubSwipeRoles {
                                if fb.slot == .top {
                                    onSwitchItem?(topDir)
                                } else {
                                    switchPeriod(direction: dir)
                                }
                            } else if fb.slot == .top {
                                switchPeriod(direction: topDir)
                            } else {
                                onSwitchItem?(dir)
                            }
                            triggeredSwitch = true
                        } else {
                            DebugLogger.shared.log("[副图滑动] 一次性锁生效，屏蔽重复回调 slot=\(fb.slot) dir=\(dir) offset=\(fb.offset) period=\(self.period.rawValue)")
                            triggeredSwitch = false
                        }
                    } else {
                        triggeredSwitch = false
                    }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { swipeFeedback = nil }
                    // 若发生了真正的周期/标的切换，外层会立刻改 view.period → chartIdentity 变化 →
                    // 本 SwiftUI KlineChartView 实例即将被销毁。此时再清锁已经没有意义。
                    // 如果没有触发切换，仍然解锁下一次"新的 swipeFeedback 创建"时再清（见 onChanged）。
                    _ = triggeredSwitch
                    return
                }
                if drag.cursorDragging { drag.cursorDragging = false; return }
                let y = value.location.y
                // 轻点放置/取消光标的作用域同样不含副图3（面板手势已禁用，预留给虚拟按钮）
                let inPanel = isInPanel(y, mainTop, mainBottom) || isInPanel(y, s1Top, s1Bottom) || isInPanel(y, s2Top, s2Bottom)
                let isTap = abs(value.translation.width) < 6 && abs(value.translation.height) < 6
                // 「边」调节分割线时禁止产生/清除十字光标
                if suppressCrosshair { return }
                if isTap && inPanel {
                    let col = Int((value.location.x / candleSpacing).rounded(.down))
                    let idx = startIndex + col
                    if isLinkedSecondCursorView {
                        // 非来源复盘/范围框视图：轻点放置纯本地第二光标（走到这里时它必然不存在），
                        // 不设联动来源标记、不写 selectedIndex，因此不会接管来源/广播给其他视图，
                        // 复盘视图里再点也只取消本地第二光标，绝无可能取消整组联动。
                        // 仅限主图区域轻点放置：副图一/副图二区域轻点不放（副图三面板手势整体禁用）。
                        if isInPanel(y, mainTop, mainBottom), idx >= startIndex && idx <= endIndex {
                            secondCursorIndex = idx
                            secondCursorY = y
                        }
                    } else {
                        // 点击（无论放置还是清除光标）都视为用户直接操作（联动来源），
                        // 让本次取消/放置都能被联动到其它视图
                        linkUserDragging = true
                        if selectedIndex != nil {
                            selectedIndex = nil; crosshairY = nil
                        } else if idx >= startIndex && idx <= endIndex {
                            // 点击创建光标也视为用户直接操作（联动来源标记），使右视图点击能同步到左视图
                            selectedIndex = idx; crosshairY = value.location.y
                        }
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

    /// 记录当前图表的周期与指标配置状态到沙盒 debug_log.txt（供外部自动化校验）
    private func logChartState() {
        let mains = config.mainIndicators(for: self.period).sorted().joined(separator: ",")
        let subs = config.subSelections(for: self.period)
            .map { sel in sel.customID.map { "\(sel.kind)#\(String($0.uuidString.prefix(8)))" } ?? sel.kind }
            .joined(separator: ",")
        let custom = config.activeCustomIndicatorID(for: self.period)
            .map { String($0.uuidString.prefix(8)) } ?? "无"
        DebugLogger.shared.log("图表出现 标的:\(metaId.map(String.init) ?? "无") 周期:\(self.period.rawValue) 主图:[\(mains)] 副图:[\(subs)] 自定义:\(custom)")
    }

    /// 某方向是否存在可切换的周期（-1 更小 / +1 更大），用于副图滑动方向提示
    func canSwitchPeriod(_ dir: Int) -> Bool {
        let cases = KlinePeriod.allCases
        guard let cur = cases.firstIndex(of: period) else { return false }
        let target = cur + dir
        return target >= 0 && target < cases.count
    }

    /// 副图滑动方向可切换提示：尊重 swapSubSwipeRoles（联动态副图一切标的、副图二切周期）
    private func subSwipeCanLeftRight(slot: SubSlot) -> (Bool, Bool) {
        if swapSubSwipeRoles {
            // 副图一(上)切标的，副图二(下)切周期
            if slot == .top {
                return (canSwitchItem?(-1) ?? false, canSwitchItem?(1) ?? false)
            } else {
                return (canSwitchPeriod(-1), canSwitchPeriod(1))
            }
        } else {
            if slot == .top {
                return (canSwitchPeriod(-1), canSwitchPeriod(1))
            } else {
                return (canSwitchItem?(-1) ?? false, canSwitchItem?(1) ?? false)
            }
        }
    }

    // MARK: - 双指手势（由 TwoFingerGestureHook 回调驱动）

    /// 双指手势开始：以双指质心起始位置对应K线为缩放锚点，初始化缩放基准
    private func handleTwoFingerBegin(centroidX: CGFloat, width: CGFloat) {
        drag.twoFingerActive = true
        // 双指手势接管：复位单指光标拖动状态，避免粘滞导致联动被忽略
        linkUserDragging = false
        drag.cursorDragging = false
        selectedIndex = nil; crosshairY = nil
        clearSecondCursor()
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
        if let aIdx = pinnedIndex, let bIdx = renderCursorIndex, aIdx != bIdx {
            let left = min(aIdx, bIdx)
            let right = max(aIdx, bIdx)
            let start = max(0, left - 10)
            let end = min(maxEnd, right + 10)
            visibleCount = CGFloat(max(20, end - start + 1))
            endOffset = max(0, maxEnd - end)
            return
        }
        // 一个光标：以光标所在K线为中心，前 49 + 1 + 后 50 = 100 根
        if let center = renderCursorIndex ?? pinnedIndex {
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
                    mainChart(width: width, candleSpacing: candleSpacing, height: mainHeight,
                              secondCursorIndex: isLinkedSecondCursorView ? secondCursorIndex : nil)
                    if !mainFullscreen {
                        subLegendRow(model: subTop, height: legendHeight).zIndex(30)
                        subChart(model: subTop, width: width, candleSpacing: candleSpacing, height: sub1Height,
                                 slot: .top, secondCursorIndex: isLinkedSecondCursorView ? secondCursorIndex : nil)
                        subLegendRow(model: subBottom, height: legendHeight).zIndex(30)
                        subChart(model: subBottom, width: width, candleSpacing: candleSpacing, height: sub2Height,
                                 slot: .bottom, secondCursorIndex: isLinkedSecondCursorView ? secondCursorIndex : nil)
                        subLegendRow(model: subThird, height: legendHeight).zIndex(30)
                        subChart(model: subThird, width: width, candleSpacing: candleSpacing, height: sub3Height,
                                 slot: .third, secondCursorIndex: isLinkedSecondCursorView ? secondCursorIndex : nil)
                    }
                    // 底部两行顺序：时间轴在上（倒数第二行）、行情数据行贴底（倒数第一行）
                    timeAxis(width: width, candleSpacing: candleSpacing, height: timeHeight)
                    // 时间轴下方新增一行：十字光标出现时显示 开/收/高/低/涨/额 行情数据
                    axisQuoteRow(width: width, height: timeHeight)
                }
                // 双指手势层：按面板分片覆盖（主图/各副图各一块），不覆盖 legend 行的按钮，
                // 面板上的单指触摸沿响应链派发给祖先 ZStack 上的 chartDragGesture
                twoFingerLayer(width: width, rect: CGRect(x: 0, y: mainTop, width: width, height: mainHeight))
                if !mainFullscreen {
                    twoFingerLayer(width: width, rect: CGRect(x: 0, y: s1Top, width: width, height: sub1Height))
                    twoFingerLayer(width: width, rect: CGRect(x: 0, y: s2Top, width: width, height: sub2Height))
                    // 副图3 不挂双指层：面板手势整体禁用（虚拟按钮预留区）
                }
            }
            .contentShape(Rectangle())
            .gesture(chartDragGesture(width: width, candleSpacing: candleSpacing, mainTop: mainTop, mainBottom: mainBottom,
                                      s1Top: s1Top, s1Bottom: s1Bottom, s2Top: s2Top, s2Bottom: s2Bottom,
                                      s3Top: s3Top, s3Bottom: s3Bottom))
            .overlay {
                // 本层全部是纯装饰覆盖（范围框蓝轴/底纹、十字光标横竖线与标签、联动第二光标），
                // 不含任何可点击控件；整体禁用命中测试，避免大面积 Rectangle（尤其范围框底纹）
                // 截走触摸导致点在范围框区域内无法触发放置/取消第二光标。
                // 所有触摸统一由下层 chartDragGesture 处理。
                ZStack(alignment: .topLeading) {
                    // 更大周期源的联动范围：两根无标签竖轴框出来源周期K线覆盖的范围（此时 renderCursorIndex 为 nil，不画十字光标）。
                    // 纵向按图表面板分段（参考十字光标竖线）：跳过主图/各副图之间的指标栏，且在时间轴顶端截停，
                    // 不贯穿三个副图指标栏、底部时间轴与行情数据栏
                    if let rg = linkRangeIndices {
                        LinkRangeAxisOverlay(startIndex: startIndex, endIndex: endIndex,
                                             left: rg.left, right: rg.right, candleSpacing: candleSpacing,
                                             panOffset: panOffset,
                                             panels: mainFullscreen
                                                ? [(mainTop, mainBottom)]
                                                : [(mainTop, mainBottom),
                                                   (s1Top, s1Bottom),
                                                   (s2Top, s2Bottom),
                                                   (s3Top, s3Bottom)])
                            .equatable()
                    }
                    // 可交互光标横线 y：
                    //   联动接收态 → 按联动K线收盘价反算（fixedPrice 同步传入，标签精确显示收盘价）；
                    //   本地手指操作/单图 → 手指位置 crosshairY，轻点等无手指位置时回退主图中线。
                    let interactiveCY = linkedCursorClose.map {
                        priceToY($0, mainTop: mainTop, mainBottom: mainBottom, mainHeight: mainHeight)
                    } ?? crosshairY ?? mainCenterY
                    cursorOverlay(index: renderCursorIndex, y: interactiveCY, compare: pinnedIndex, fixedPrice: linkedCursorClose, width: width, height: geometry.size.height,
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
                    // 非来源的小周期范围框 / 大周期复盘视图的本地「第二个十字光标」：横线 + 左侧数值标签。
                    // 竖线（分段贯穿主图/副图）与顶部日期标签由各面板内 secondary 竖线绘制；
                    // 不发布联动、不影响来源与其他视图（复盘画面下与联动复盘十字光标并存）
                    if isLinkedSecondCursorView, let sIdx = secondCursorIndex, let sY = secondCursorY {
                        let cy = min(max(sY, 0), geometry.size.height)
                        let valueText = crosshairValueText(at: cy, mainTop: mainTop, mainBottom: mainBottom, mainHeight: mainHeight,
                                                           s1Top: s1Top, s1Bottom: s1Bottom, s1Height: sub1Height,
                                                           s2Top: s2Top, s2Bottom: s2Bottom, s2Height: sub2Height,
                                                           s3Top: s3Top, s3Bottom: s3Bottom, s3Height: sub3Height)
                        let lineGap = crosshairLineGap(index: sIdx, compare: nil, otherIndex: nil, otherCompare: nil,
                                                       cy: cy, candleSpacing: candleSpacing, width: width,
                                                       mainTop: mainTop, mainHeight: mainHeight)
                        SecondCursorHorizontalOverlay(startIndex: startIndex, endIndex: endIndex, index: sIdx, y: cy,
                                                      width: width, height: geometry.size.height,
                                                      candleSpacing: candleSpacing,
                                                      mainTop: mainTop, mainBottom: mainBottom, mainHeight: mainHeight,
                                                      s1Top: s1Top, s1Bottom: s1Bottom, s1Height: sub1Height,
                                                      s2Top: s2Top, s2Bottom: s2Bottom, s2Height: sub2Height,
                                                      s3Top: s3Top, s3Bottom: s3Bottom, s3Height: sub3Height,
                                                      valueText: valueText, gapRanges: lineGap)
                            .equatable()
                    }
                }
                .allowsHitTesting(false)
                // 范围框底纹/竖轴跟随 panOffset 亚像素平移时可能暂时越出视图边界，
                // 统一裁剪在本视图内，避免画到相邻 tile
                .clipped()
            }
            // 公式编辑器：用 fullScreenCover（窗口级、不受联动 tile 半屏 frame 限制）呈现，做到真全屏。
            // 联动时多 tile 共享 showCustomEditor，只有「激活者」tile（selfIndex == editorOwnerIndex）真正弹出。
            .fullScreenCover(isPresented: customEditorBinding) {
                FormulaEditorView(data: sortedData) {
                    showCustomEditor = false
                } onSaved: { ind in
                    switch editorUI.editorTarget {
                    case .main: activateCustom(ind)
                    case .sub:
                        let m = model(for: editorUI.editingSlot)
                        activateSubCustom(m, ind)
                    }
                }
            }
            .fullScreenCover(isPresented: systemEditorBinding) {
                if let isMain = editorUI.systemEditorIsMain {
                    SystemIndicatorEditorContainer(data: sortedData, isMain: isMain, period: self.period, initialSubId: editorUI.systemEditorSubId) {
                        showSystemEditor = false
                    } onSaved: { _ in
                        if isMain {
                            recomputeMainCurves(force: true)
                        } else {
                            recomputeSub(model(for: editorUI.editingSlot), force: true)
                        }
                    }
                }
            }
            .overlay {
                if editorUI.showMainSheet {
                    bottomSheet(geometry: geometry, heightFraction: 0.8) {
                        mainSheetContent
                    } onClose: { editorUI.showMainSheet = false }
                } else if editorUI.showSubSheet {
                    bottomSheet(geometry: geometry, heightFraction: 0.8) {
                        subSheetContent
                    } onClose: { editorUI.showSubSheet = false }
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
                    clearSecondCursor()
                }
                notifyHasCursor()
            }
        }
        .background(Color.white)
        .onAppear {
            // 恢复联动持久化的缩放级别（.id 重建后 @State 已回到默认 100，这里写入保存值）
            if let saved = initialVisibleCount {
                visibleCount = clamp(saved, 20, CGFloat(capVisibleCount))
            }
            // 记录当前图表配置状态（周期/主图/副图/自定义），供外部读取 debug_log.txt 做自动化校验
            logChartState()
            // 周期一致性校验（单图模式）：联动态下真正的校验在 LinkedKlineTile.loadData 的
            // chartSeries 赋值那一瞬间做（避免 "view.period 已切换但 series 还是旧值" 的
            // 假阳性）。单图模式这里安全，因为构造参数 series/period/metaId 来自同步
            // cache，天然对齐。isolatedSubs (metaId==nil, 联动态 tile) 跳过本次校验，
            // 改由 loadData 侧调用 static 版本。
            if metaId != nil { verifyPeriodSignature() }
            // 联动复盘：切周期/标的导致 .id 重建后，若联动光标仍在（cursorDate 未变、
            // 不会再收到 onChange），立即补一次来源数据加载请求，命中缓存则当帧即可合成
            ensureLinkSourceBars()
            // as-of 同理：重建后若合成态成立，直接按缓存恢复/调度指标点重算
            scheduleAsOf(asOfTrigger)
            // 把主图指标按钮标题/点击行为同步给外层信息栏
            syncMainLegendPortal()
            // 副图配置已持久化在共享仓库，无需重置
            // 联动隔离视图（isolatedSubs=metaId=nil）：强制前台同步重算，
            // 不依赖共享缓存/后台预计算推进，保证搜索切标后新标的副图第一时间完整显示。
            // 普通单图（有缓存可用）：先走不强制路径，命中缓存恢复/短可见窗口近似后由后台补齐。
            refreshCurves(force: isolatedSubs)
            // 先显示当前可见窗口（不卡），随后分块预计算更久远历史指标
            startPrefetch()
            notifyHasCursor()
        }
        .onChange(of: visibleCount) { newValue in
            // 联动持久化缩放级别：把每次可见K线数变化上抛给外层（LinkedKlineTile 负责落盘）
            onVisibleCountChange?(newValue)
        }
        .onChange(of: mainLegendTitle) { _ in
            // 指标配置/裸K/放大模式等引起标题变化时，同步给外层信息栏按钮
            syncMainLegendPortal()
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
        .onChange(of: cursorClearToken) { _ in
            // 外层广播：清掉本视图所有十字光标（切换光标联动开/关、退出联动等场景）
            selectedIndex = nil; crosshairY = nil
            pinnedIndex = nil; pinnedY = nil; pinnedPrice = nil
            clearSecondCursor()
            notifyHasCursor()
        }
        .onChange(of: linkSync.cursorDate) { date in
            applyLinkCursor(date)
        }
        .onChange(of: asOfTrigger) { t in
            // 合成内容/光标日期/指标配置变化 → 调度（或清空）as-of 单点重算
            scheduleAsOf(t)
        }
        .onChange(of: suppressCrosshair) { on in
            // 「边」开启时清除可能残留的十字光标（含固定光标、联动第二光标），并同步联动/上报
            if on {
                selectedIndex = nil; crosshairY = nil
                pinnedIndex = nil; pinnedY = nil; pinnedPrice = nil
                clearSecondCursor()
                notifyHasCursor()
            }
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
        // 编辑器被激活（自定义/系统指标都对第一次置 true 广播一次 owner），
        // 联动多图时 detail 据此把 editorOwnerIndex 设为本 tile 下标，从而只有本 tile 真正全屏弹出编辑器
        .onChange(of: showCustomEditor) { v in if v { onEditorActivate?() } }
        .onChange(of: showSystemEditor) { v in if v { onEditorActivate?() } }
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
                if editorUI.pendingMainRefresh {
                    editorUI.pendingMainRefresh = false
                    recomputeMainCurves(force: true)
                }
                if !editorUI.pendingSubCharts.isEmpty {
                    let subs = editorUI.pendingSubCharts
                    editorUI.pendingSubCharts.removeAll()
                    for m in subs { recomputeSub(m, force: true) }
                }
            }
        }
    }

    /// 屏幕上是否有任意光标（固定光标或可交互光标），通知详情页用于控制 📌 按钮
    func notifyHasCursor() {
        onHasCursorChange?(renderCursorIndex != nil || pinnedIndex != nil)
    }

    func refreshCurves(force: Bool = false) {
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
    func startPrefetch() {
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
    func crosshairValueText(at y: CGFloat, mainTop: CGFloat, mainBottom: CGFloat, mainHeight: CGFloat,
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
                let otherIndex: Int? = (index == renderCursorIndex) ? pinnedIndex : renderCursorIndex
                let otherCompare: Int? = (index == renderCursorIndex) ? nil : pinnedIndex
                let lineGap = crosshairLineGap(index: index, compare: compare, otherIndex: otherIndex, otherCompare: otherCompare,
                                               cy: cy, candleSpacing: candleSpacing, width: width,
                                               mainTop: mainTop, mainHeight: mainHeight)
                CrosshairLineOverlay(width: width, height: height, y: cy, valueText: valueText,
                                     secondLine: secondLineText.isEmpty ? nil : secondLineText,
                                     gapRanges: lineGap,
                                     bgColor: bgColor,
                                     lineColor: compare != nil ? Color.blue : Color.black.opacity(0.45))
                    .equatable()
                // 主图横线右边：光标K线收盘 → 屏幕最后那根K线收盘 的涨幅；
                // 光标停在屏幕最右边一根K线（index == endIndex）时不显示（涨幅恒为0无意义）。
                // 联动「历史时点复盘」态（本视图周期严格大于来源周期）同样不显示：屏幕末根属于
                // 光标之后的「未来淡化区」（站在光标时点尚未发生），"从光标到窗口右侧"的涨幅在复盘语义下不成立
                if linkReplayState?.idx != index,
                   isInPanel(y, mainTop, mainBottom),
                   index >= startIndex, index < endIndex, endIndex >= 0, endIndex < sortedData.count {
                    // 联动复盘：涨幅基准为合成K线收盘；屏幕末根是真实K线（"从当时到窗口右侧"）
                    let cursorItem = cursorDisplayItem(at: index)
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

    private func mainChart(width: CGFloat, candleSpacing: CGFloat, height: CGFloat,
                           secondCursorIndex: Int? = nil) -> some View {
        ZStack(alignment: .topLeading) {
            Color.white
            mainCanvas(width: width, candleSpacing: candleSpacing, height: height)
                .offset(x: panOffset)
            // 主图价格坐标：网格线仍为5条，数值只显示顶底两个（中间三个不显示）；
            // 已启用的主图 .tdx 指标全部声明 COORD=0（且无激活自定义主图指标）时不显示
            PriceLabelsAxis(width: width, height: height, axisColor: axisTextColor,
                            labels: (mainCoordHidden ? [] : [0, 1]).map { r in
                                AxisLabel(ratio: r, text: String(format: "%.2f",
                                    priceRange.upperBound - (priceRange.upperBound - priceRange.lowerBound) * Double(r)))
                            })
                .equatable()
            // 最新价：只保留虚线（在 Canvas 中绘制），不显示数值，避免与虚线重叠
            // 可交互光标（pin 开启时即第二个光标）与固定光标的竖线/标签都绘制
            mainCursorVLine(index: renderCursorIndex, compare: pinnedIndex, width: width, candleSpacing: candleSpacing, height: height)
            mainCursorVLine(index: pinnedIndex, compare: nil, width: width, candleSpacing: candleSpacing, height: height)
            // 联动小周期范围框视图的本地「第二个十字光标」：蓝色、只保留顶部日期标签（纯装饰，不参与命中测试）
            mainCursorVLine(index: secondCursorIndex, compare: nil, width: width, candleSpacing: candleSpacing, height: height,
                            secondary: true)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .clipped()
    }

    /// 主图顶底价格坐标是否隐藏：已启用的主图 .tdx 指标全部声明 COORD=0
    /// （且无激活的自定义主图指标）时隐藏；任一指标未声明 COORD 或值非 0 则显示
    private var mainCoordHidden: Bool {
        let enabled = config.mainIndicators(for: period)
        let mains = SystemIndicatorStore.shared.mainIndicatorDefs(period: period)
            .filter { enabled.contains($0.id) }
        guard !mains.isEmpty, activeCustomIndicator == nil else { return false }
        return mains.allSatisfy { $0.hideCoord }
    }

    /// 主图单个光标的竖线 + 顶部日期标签 + 底部涨幅标签（可交互光标与固定光标共用；
    /// compare 非 nil 表示这是第二个光标，顶部/底部标签追加与第一个固定光标的对比统计；
    /// 标签始终跟随各自竖线居中显示，不做互相避让）。
    /// secondary=true：联动小周期范围框视图里的纯本地「第二个十字光标」——蓝色竖线、
    /// 只保留顶部日期标签（无底部距今标签，无对比统计）。
    @ViewBuilder
    private func mainCursorVLine(index: Int?, compare: Int?, width: CGFloat, candleSpacing: CGFloat, height: CGFloat,
                                 secondary: Bool = false) -> some View {
        if let index, index >= startIndex, index <= endIndex {
            // 联动复盘：可交互光标在合成索引时，距今涨幅等读数用合成K线（日期与真实K线一致）
            let item = cursorDisplayItem(at: index)
            let xPosition = (CGFloat(index - startIndex) + 0.5) * candleSpacing
            // 主图竖线：从顶部日期标签背景下沿开始画到底部（竖线完全从背景底下开始，顶部无露出）；第二个光标蓝色、固定光标黑色
            let topCut = clampedAxisY(0, in: height) + 8
            let lineHeight = max(0, height - topCut)
            Rectangle().fill((compare != nil || secondary) ? Color.blue : Color.black.opacity(0.45)).frame(width: 1.0, height: lineHeight)
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
            // 第二个光标时第二行显示 两光标间成交量之和 与 成交额之和；宽度按最宽一行（第二行）贴边判定。
            // 联动「历史时点复盘」态（本视图周期严格大于来源周期）不显示：数据末根属于光标之后的
            // 「未来淡化区」（站在光标时点尚未发生），"距今涨幅/周期数"在复盘语义下不成立。
            // 联动范围框视图的本地第二光标（secondary）按需求只有顶部/左侧两个标签，底部同样不绘制。
            if !secondary, linkReplayState?.idx != index, let last = sortedData.last, last.close > 0 {
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

    private func mainCanvas(width: CGFloat, candleSpacing: CGFloat, height: CGFloat) -> some View {
        // 注意：K线空实心/类型直接读取 config.chartStyle —— config 已被 @ObservedObject 观察，
        // 这样「K线设置-显示组-类型」修改（含启动时从 UserDefaults 恢复）都会立即驱动主图重绘实心/空心，
        // 不依赖外部传入的 @Binding 中间层传播。
        // 联动复盘：全局 idx → 可见切片本地索引；合成K线镜像取负与 mirroredSlice 同构。
        let replay = linkReplayState
        let localCount = max(0, endIndex - startIndex + 1)
        let syntheticBar: SyntheticBar? = {
            guard let r = replay, let s = r.synthetic,
                  r.idx >= startIndex, r.idx <= endIndex else { return nil }
            let item: KlineItem
            if mainMirrored {
                item = KlineItem(date: s.date, open: -s.open, high: -s.high, low: -s.low,
                                 close: -s.close, volume: s.volume, turnover: s.turnover)
            } else {
                item = s
            }
            return SyntheticBar(index: r.idx - startIndex, item: item)
        }()
        let dimFromLocal: Int? = replay.flatMap { r in
            let d = r.dimFrom - startIndex
            return (d >= 0 && d < localCount) ? d : nil
        }
        // 主图曲线可见切片：合成索引处用 as-of 重算值单点替换（历史段/未来段数组值不动）
        func mainCurveValues(_ line: IndicatorLine, lineIndex: Int) -> [Double] {
            var values = mirroredSliceArr(line.values)
            if let r = replay, r.synthetic != nil,
               r.idx >= startIndex, r.idx <= endIndex,
               let v = asOfModel.main[lineIndex] {
                let local = r.idx - startIndex
                if local >= 0, local < values.count { values[local] = mainMirrored ? -v : v }
            }
            return values
        }
        return MainChartCanvas(slice: mainMirrored ? mirroredSlice : slice, chartStyle: config.chartStyle, candleSpacing: candleSpacing, height: height,
                        priceMin: priceRange.lowerBound, priceMax: priceRange.upperBound,
                        curves: isBareK ? [] : mainCurves.enumerated().map { li, line in
                            CanvasCurve(color: line.color, values: mainCurveValues(line, lineIndex: li),
                                        style: line.style, lineWidth: line.lineWidth, barColor: line.barColor,
                                        markerColors: sliceColors(line.markerColors))
                        },
                        upColor: upColor, downColor: downColor, gridColor: gridColor,
                        showGap: displaySettings.showGap, showLatestPriceLine: displaySettings.showLatestPriceLine,
                        gapDisappearAfterFill: displaySettings.gapDisappearAfterFill,
                        gaps: mainMirrored ? mirroredGaps : gaps, sliceStart: startIndex,
                        latest: mirroredLatest,
                        syntheticBar: syntheticBar, dimFromIndex: dimFromLocal)
            .equatable()
    }

    // MARK: - 副图

    private func subChart(model m: SubChartModel, width: CGFloat, candleSpacing: CGFloat,
                          height: CGFloat, slot: SubSlot, secondCursorIndex: Int? = nil) -> some View {
        let range = subRange(m)
        let subFmt: (Double) -> String = subFormatter(for: m.kind)
        // 顶底坐标值：VOL/AMO 最低值恒为 0，底部"0"无需显示；
        // .tdx 声明 COORD=0 的指标不显示坐标值；其他指标保留顶底两个值
        let labelRatios: [CGFloat]
        if m.kind == "VOL" || m.kind == "AMO" {
            labelRatios = [0]
        } else if !m.isCustom,
                  SystemIndicatorStore.shared.defs(for: self.period)[m.kind]?.hideCoord == true {
            labelRatios = []
        } else {
            labelRatios = [0, 1]
        }
        // 联动复盘：未来淡化本地索引 + VOL/AMO 合成柱（镜像时与副图曲线同规则取负）
        let replay = linkReplayState
        let localCount = max(0, endIndex - startIndex + 1)
        let dimLocal: Int? = replay.flatMap { r in
            let d = r.dimFrom - startIndex
            return (d >= 0 && d < localCount) ? d : nil
        }
        // 槽位下标（0/1/2，as-of 结果索引）；注意勿与函数参数 slot: SubSlot 同名
        let subSlotIndex = m === subTop ? 0 : (m === subBottom ? 1 : 2)
        let synthStick: SyntheticStick? = {
            guard let r = replay, let s = r.synthetic,
                  r.idx >= startIndex, r.idx <= endIndex,
                  m.kind == "VOL" || m.kind == "AMO" else { return nil }
            let v = m.kind == "AMO" ? s.turnover : s.volume
            return SyntheticStick(index: r.idx - startIndex,
                                  value: config.mainMirrored ? -v : v,
                                  isUp: s.isUp)
        }()
        // 副图曲线可见切片：合成索引处用 as-of 重算值单点替换（VOL/AMO 均量线等同样适用）
        func subCurveValues(_ line: IndicatorLine, lineIndex: Int) -> [Double] {
            var values = subMirroredSliceArr(line.values)
            if let r = replay, r.synthetic != nil,
               r.idx >= startIndex, r.idx <= endIndex,
               let v = asOfModel.subs[subSlotIndex][lineIndex] {
                let local = r.idx - startIndex
                if local >= 0, local < values.count { values[local] = config.mainMirrored ? -v : v }
            }
            return values
        }
        return ZStack(alignment: .topLeading) {
            Color.white
            SubChartCanvas(slice: slice, candleSpacing: candleSpacing, height: height,
                           curves: m.curves.enumerated().map { li, line in
                               CanvasCurve(color: line.color, values: subCurveValues(line, lineIndex: li),
                                           style: line.style, lineWidth: line.lineWidth, barColor: line.barColor)
                           },
                           rangeMin: range.min, rangeMax: range.max,
                           upColor: upColor, downColor: downColor, gridColor: gridColor,
                           dimFromIndex: dimLocal, syntheticStick: synthStick)
                .equatable()
                .offset(x: panOffset)
            // 顶底坐标值（是否显示由上方 labelRatios 决定）
            PriceLabelsAxis(width: width, height: height, axisColor: axisTextColor,
                            labels: labelRatios.map { r in
                                AxisLabel(ratio: r, text: subFmt(range.max - (range.max - range.min) * Double(r)))
                            })
                .equatable()

            // 可交互光标（pin 开启时即第二个光标）与固定光标的副图竖线都绘制
            SubCursorVLine(startIndex: startIndex, endIndex: endIndex, index: renderCursorIndex, compare: pinnedIndex,
                           candleSpacing: candleSpacing, height: height)
                .equatable()
            SubCursorVLine(startIndex: startIndex, endIndex: endIndex, index: pinnedIndex, compare: nil,
                           candleSpacing: candleSpacing, height: height)
                .equatable()
            // 联动小周期范围框视图的本地「第二个十字光标」副图竖线（蓝色，纯装饰不参与命中测试）
            SubCursorVLine(startIndex: startIndex, endIndex: endIndex, index: secondCursorIndex, compare: nil,
                           candleSpacing: candleSpacing, height: height, secondary: true)
                .equatable()
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .clipped()
        .overlay {
            // 副图3 不挂滑动反馈层（面板手势整体禁用，预留给虚拟按钮）；副图1/2 保留左右滑动切换
            if slot != .third {
                // 副图一（上方副图）方向已调转：左=小级别/上一标的，右=大级别/下一标的；副图二保持原方向
                SwipeOverlay(slot: slot, fb: swipeFeedback,
                             canL: slot == .top ? canSwitchPeriod(-1) : (canSwitchItem?(1) ?? false),
                             canR: slot == .top ? canSwitchPeriod(1) : (canSwitchItem?(-1) ?? false),
                             width: width, height: height)
                    .equatable()
            }
        }
    }

    private func subLegendRow(model m: SubChartModel, height: CGFloat) -> some View {
        return ZStack {
            HStack(spacing: 8) {
                IndicatorNameButton(title: m.titleName, onTap: {
                    editorUI.editingSlot = (m === subTop) ? .top : (m === subBottom ? .bottom : .third)
                    editorUI.showMainSheet = false
                    withAnimation { editorUI.showSubSheet = !editorUI.showSubSheet }
                })
                // VOL/AMO 的数值按转换单位显示（万/亿/万亿），其余指标按默认格式；
                // 联动复盘：VOL/AMO 柱线读合成累加量/额，其余指标行读 as-of 重算值；同图 MA 均量线走 as-of
                let isVolAmo = (m.kind == "VOL" || m.kind == "AMO")
                let legendSlot = m === subTop ? 0 : (m === subBottom ? 1 : 2)
                ForEach(Array(m.curves.enumerated()), id: \.offset) { lineOffset, line in
                    // 仅 stick 柱线（VOL/AMO 本体）取合成量/额
                    let volAmoOverride: Double? = {
                        guard isVolAmo, line.style == .stick,
                              let r = linkReplayState, let s = r.synthetic,
                              r.idx == renderCursorIndex else { return nil }
                        return m.kind == "AMO" ? s.turnover : s.volume
                    }()
                    // 本地第二光标存在时数值栏跟随第二光标读真实量额/指标，关闭合成 / as-of 覆盖
                    legendItem(line, mirrored: config.mainMirrored,
                               formatter: isVolAmo ? { formatVolume($0) } : nil,
                               valueOverride: legendFollowsSecondCursor
                                   ? nil
                                   : volAmoOverride ?? asOfSubOverride(slot: legendSlot, lineIndex: lineOffset))
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
                // 副图2：最右侧 🔍 搜索按钮（联动态显示；点击由外层接管覆盖式搜索栏）
                if m === subBottom && showSubTwoSearchButton {
                    Button {
                        onSubTwoSearch?()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 22, alignment: .center)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                // 副图3：最右侧「裸」按钮 —— 主图裸K开关（单图/联动均可显示）。
                // 仅切换渲染层隐藏主图指标，不触发主图重算、不清除 mainCurves 缓存（切回立即显示）。
                // 高亮样式与顶部导航栏「多/空」一致：开启=蓝，关闭=灰。
                if m === subThird {
                    Button {
                        bareFromSub.toggle()
                    } label: {
                        Text("裸")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(bareFromSub ? Color.blue : Color.gray)
                            .frame(width: 22, height: 22, alignment: .center)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                // 若提供 portal 且 hideInChart=true（联动 tile 场景）：按钮挪到外层信息栏格子左侧，
                // 图内不重复渲染；若 portal 未提供或 hideInChart=false（单图）：按钮保持在图内指标栏
                let shouldHideButtonInChart = (mainLegendPortal?.hideInChart ?? false)
                if !shouldHideButtonInChart {
                    IndicatorNameButton(title: mainLegendTitle, onTap: {
                        editorUI.showSubSheet = false
                        withAnimation { editorUI.showMainSheet = !editorUI.showMainSheet }
                    })
                }
                if isBareK { legendText("裸K") }
                if !isBareK {
                    ForEach(Array(mainCurves.enumerated()), id: \.offset) { li, line in
                        // 联动复盘：合成点指标读数用 as-of 重算值（镜像取负仍由 legendItem 处理）；
                        // 本地第二光标存在时数值栏跟随第二光标读真实值，必须关闭 as-of 覆盖
                        legendItem(line, mirrored: config.mainMirrored,
                                   valueOverride: legendFollowsSecondCursor ? nil : asOfMainOverride(li))
                    }
                }
                Spacer()
                // 主图放大开关：进入后主图全屏裸K、显示全部 K 线；放大期间若双指缩放导致 K 线数变少，
                // 再次点击只重新全显（保持放大）；仅当全部 K 线都在屏幕内时才退出放大并恢复最新 100 根。
                // 存在两个十字光标时（无论放大还是非放大），点击不切换放大状态，只定位到两个光标之间的 K 线
                if !hideMainZoomButton {
                    Button {
                    let hasTwoCursors = pinnedIndex != nil && renderCursorIndex != nil && pinnedIndex != renderCursorIndex
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
                    let hasTwoCursors = pinnedIndex != nil && renderCursorIndex != nil && pinnedIndex != renderCursorIndex
                    let needShowAll = mainFullscreen && count < maxVisibleCount
                    Image(systemName: hasTwoCursors ? "magnifyingglass"
                        : (needShowAll ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(hasTwoCursors ? .blue : (mainFullscreen ? .blue : .gray))
                        .frame(width: 22, height: 22, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel((pinnedIndex != nil && renderCursorIndex != nil && pinnedIndex != renderCursorIndex)
                    ? "显示两个光标之间的K线"
                    : (mainFullscreen ? (count < maxVisibleCount ? "重新显示全部 K 线" : "退出主图放大") : "放大主图"))
                }
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

    /// 把主图指标按钮的标题/点击行为同步给外层信息栏（提供 portal 时）。
    /// - 单图：portal.hideInChart == false（按钮渲染在图内主图指标栏）→ 完整标题 "日线: MA/CMK"
    /// - 联动：portal.hideInChart == true（按钮渲染在信息栏格子里）→ 只显示周期 "日线"
    private func syncMainLegendPortal() {
        guard let portal = mainLegendPortal else { return }
        portal.title = portal.hideInChart ? period.rawValue : mainLegendTitle
        portal.onTap = {
            self.editorUI.showSubSheet = false
            withAnimation { self.editorUI.showMainSheet = !self.editorUI.showMainSheet }
        }
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

    private func legendItem(_ line: IndicatorLine, format: String = "%.2f", mirrored: Bool = false, formatter: ((Double) -> String)? = nil,
                            valueOverride: Double? = nil) -> some View {
        // NOTEXT_ 前缀的输出线：不显示名称也不显示数值（仅保留线条）
        if line.hideValue { return AnyView(EmptyView()) }
        let name = legendName(line)
        let color = line.color
        // 联动复盘：VOL/AMO 合成量/额由外部显式覆盖，优先于曲线数组读数
        if let value = valueOverride ?? legendValueFor(line), !value.isNaN {
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

    private func formatVolume(_ v: Double) -> String {
        if v >= 1000000000000 { return String(format: "%.2f万亿", v / 1000000000000) }
        else if v >= 100000000 { return String(format: "%.2f亿", v / 100000000) }
        else if v >= 10000 { return String(format: "%.2f万", v / 10000) }
        else { return String(format: "%.0f", v) }
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
        // 底部涨幅标签：同理（联动复盘时收盘价取合成K线）
        let displayClose = cursorDisplayItem(at: index).close
        if let last = sortedData.last, last.close > 0, displayClose > 0 {
            let pct = (last.close - displayClose) / displayClose * 100
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
    func crosshairLineGap(index: Int?, compare: Int?, otherIndex: Int?, otherCompare: Int?,
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
                Text(left).font(.system(size: 11)).foregroundColor(.gray)
                if !isLinkedTile {
                    Text("   周期数\(count)个").font(.system(size: 11)).foregroundColor(.gray)
                }
                Spacer()
            }
            .padding(.leading, 12)   // 起始文字朝中间偏移 4pt
            Text(right).font(.system(size: 11)).foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 4)   // 截止文字朝中间偏移 4pt
            // 联动多图：时间轴中间只显示周期数字，居中显示（单图保持「周期数xxx个」样式）
            if isLinkedTile {
                Text("\(count)").font(.system(size: 11)).foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
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
                    if !hideQuoteTurnover {
                        axisKV("额", item.formattedTurnover, .black)
                    }
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
            // （联动复盘/范围框视图里本地「第二个十字光标」存在时取第二光标所指K线）
            let quoteIndex = legendCursorIndex ?? endIndex
            if quoteIndex >= startIndex, quoteIndex <= endIndex, quoteIndex >= 0, quoteIndex < sortedData.count {
                // 第二光标一律读真实K线；联动复盘光标索引处才读合成K线（开收高低/量额随合成变化）
                let item = legendFollowsSecondCursor ? sortedData[quoteIndex] : cursorDisplayItem(at: quoteIndex)
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
                    if !hideQuoteTurnover {
                        axisKV("额", item.formattedTurnover, .black)
                    }
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
            Text(title).font(.system(size: 11)).foregroundColor(.gray)
            Text(value).font(.system(size: 11)).foregroundColor(color)
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
            // 只圆顶部两角：底边贴紧物理屏幕底边后，底部若保留圆角，两角会露出深色遮罩
            .clipShape(TopRoundedCornerRect(radius: 16))
            // ⚠️ 固定高度面板直接加 .ignoresSafeArea 无效：扩展容器内默认居中放置，
            // 面板只下移半个 inset、底部仍留灰缝（露出遮罩）。
            // 必须用贪婪 frame(alignment:.bottom) 把面板钉在容器底边，
            // 扩展后容器底边 = 物理屏幕底边，面板才真正贴底
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(edges: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 主图选择页（紧凑分组 + 编辑图标）

    private var mainSheetContent: some View {
        VStack(spacing: 0) {
            sheetHeader(title: "主图指标") { editorUI.showMainSheet = false }
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
                            editorUI.showMainSheet = false
                            editorUI.systemEditorIsMain = true
                            showSystemEditor = true
                        }
                    }

                    groupHeader("自定义指标（主图）")
                    HStack {
                        Button("+ 新增/管理") { editorUI.showMainSheet = false; editorUI.editorTarget = .main; showCustomEditor = true }
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
                editorUI.showMainSheet = false; editorUI.editorTarget = .main; showCustomEditor = true
            } label: {
                Image(systemName: "pencil").font(.system(size: 13)).foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    // MARK: - 副图选择页（紧凑分组 + 编辑图标）

    private var subSheetContent: some View {
        let m = model(for: editorUI.editingSlot)
        return VStack(spacing: 0) {
            sheetHeader(title: "选择副图指标 · \(slotTitle(editorUI.editingSlot))") { editorUI.showSubSheet = false }
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
                            editorUI.showSubSheet = false
                            editorUI.systemEditorIsMain = false
                            editorUI.systemEditorSubId = m.kind
                            showSystemEditor = true
                        }
                    }

                    groupHeader("自定义指标（副图）")
                    HStack {
                        Button("+ 新增/管理") { editorUI.showSubSheet = false; editorUI.editorTarget = .sub; showCustomEditor = true }
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
                editorUI.showSubSheet = false; editorUI.editorTarget = .sub; showCustomEditor = true
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
            Button("重置内置指标") { editorUI.showResetBuiltinConfirm = true }
                .font(.system(size: 13)).foregroundColor(.red)
            Button("完成") { onClose() }.font(.system(size: 14)).foregroundColor(.blue)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .alert("重置内置指标", isPresented: Binding(get: { editorUI.showResetBuiltinConfirm },
                                              set: { editorUI.showResetBuiltinConfirm = $0 })) {
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

    // MARK: - 周期签名校验（诊断用）

    /// 依据数据尾部 K 线日期间距推断实际周期签名；与声明周期不一致时记录日志
    /// （static 版本，供外部在"数据刚加载完成"这一刻调用——联动态 tile 的 loadData、
    /// 单图模式 onAppear 都能使用。static 版本的好处：调用者有完整上下文，
    /// 不必依赖调用时 KlineChartView 的 self.series / self.period 是否和当时的
    /// 数据同步，避免假阳性。）
    static func verifyPeriodSignature(series: ChartSeries, declared: KlinePeriod, metaId: Int?) {
        let all = series.sorted
        guard all.count >= 3 else { return }
        // ⚠️ 必须 Array(...) 转成新数组：all.suffix(6) 返回的是 ArraySlice，
        // 保留了原数组的原始索引（如 994...999），直接用 tail[0]/tail[1] 会因
        // SliceBuffer 越界触发 Fatal error: Index out of bounds。
        let tail = Array(all.suffix(6))
        var gaps: [Int] = []
        for i in 1..<tail.count {
            let prev = tail[i - 1].date
            let curr = tail[i].date
            let days = dateDiffDays(yymmdd1: prev, yymmdd2: curr)
            if days > 0 { gaps.append(days) }
        }
        guard !gaps.isEmpty else { return }
        let avgGap = Double(gaps.reduce(0, +)) / Double(gaps.count)
        let inferred: KlinePeriod
        switch avgGap {
        case 0..<4:     inferred = .daily
        case 4..<14:    inferred = .weekly
        case 14..<60:   inferred = .monthly
        case 60..<150:  inferred = .quarterly
        default:        inferred = .yearly
        }
        if inferred != declared {
            let mid = metaId.map(String.init) ?? "nil"
            DebugLogger.shared.log("⚠️ [周期签名不匹配] 标的:\(mid) 声明周期:\(declared.rawValue) 推断周期:\(inferred.rawValue) 尾间距(天)=\(gaps) 均值≈\(String(format:"%.1f",avgGap)) K数=\(all.count)")
        }
    }

    /// 实例方法（单图 onAppear 入口）：self.series 和 self.period 是本视图真正渲染时
    /// 的构造参数，在单图模式下它们在 init 时就已经「对齐」——单图是一次性加载所有
    /// 周期并从 (metaID,period) cache 直接取当前，没有联动态那种 view.period 先变、
    /// series 异步后才更新的时间差。所以这里直接调用 static 版本即可。
    private func verifyPeriodSignature() {
        Self.verifyPeriodSignature(series: series, declared: period, metaId: metaId)
    }

    /// 两个 YYYYMMDD 整数日期之间的天数差（d2 - d1）。用于周期签名推断。
    private static func dateDiffDays(yymmdd1 d1: Int, yymmdd2 d2: Int) -> Int {
        func toComps(_ d: Int) -> DateComponents {
            DateComponents(year: d / 10000, month: (d / 100) % 100, day: d % 100)
        }
        // Calendar(identifier:) 为非 failable init，无需解包回退
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let a = cal.date(from: toComps(d1)),
              let b = cal.date(from: toComps(d2)) else { return 0 }
        return cal.dateComponents([.day], from: a, to: b).day ?? 0
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
    /// 联动复盘：光标所在大周期K线的单点合成替换（本地索引 + 已镜像处理的合成K线）
    var syntheticBar: SyntheticBar? = nil
    /// 联动复盘：未来淡化起始本地索引（含）；nil = 不淡化
    var dimFromIndex: Int? = nil
    var dimAlpha: Double = 1.0 / 3.0

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
                // 收盘线：复盘态先把合成点收盘价替换进序列，再按"历史原色 / 未来淡化"分段绘制
                var closeValues = slice.map(\.close)
                if let sb = syntheticBar, sb.index >= 0, sb.index < closeValues.count {
                    closeValues[sb.index] = sb.item.close
                }
                strokeLine(ctx, values: closeValues, color: Color(red: 0.2, green: 0.4, blue: 0.9),
                           h: h, style: .solid, lineWidth: 1, step: lineStep,
                           dimFrom: dimFromIndex, dimAlpha: dimAlpha)
            case .ohlc:
                drawOHLC(ctx, h: h, candleWidth: candleWidth, step: lineStep)
            }

            for curve in curves { drawCurve(ctx, curve: curve, h: h, step: lineStep) }

            if showLatestPriceLine, let latest {
                let y = yPos(latest.close, h: h)
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                // 复盘态：最新价线属于"未来"，同步淡化（光标在最后一根时 dimFromIndex=nil，不淡化）
                let baseColor = latest.isUp ? upColor.opacity(0.6) : downColor.opacity(0.6)
                let lineColor = dimFromIndex == nil ? baseColor : baseColor.opacity(dimAlpha)
                ctx.stroke(p, with: .color(lineColor),
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
            // 联动复盘：缺口整体位于未来淡化区时同步降透明度；跨边界的缺口保持原色
            let gapDim: Double = (dimFromIndex.map { (gap.startIdx - sliceStart) >= $0 } ?? false) ? dimAlpha : 1.0
            let color = (gap.isUp ? upColor.opacity(0.18) : downColor.opacity(0.18)).opacity(gapDim)
            ctx.fill(Path(rect), with: .color(color))
            ctx.stroke(Path(rect), with: .color(color.opacity(0.8 * gapDim)), lineWidth: 0.5)
        }
    }

    /// 按屏幕列数对 K 线聚合绘制：列足够宽时分笔绘制，否则按块合并保留开收高低极值。
    private func drawCandles(_ ctx: GraphicsContext, h: CGFloat, candleWidth: CGFloat, hollow: Bool, cols: Int) {
        let n = slice.count
        guard n > 0 else { return }
        let blockLen = max(1, (n + cols - 1) / cols)
        if blockLen == 1 {
            for li in 0..<n {
                // 联动复盘：合成索引单点替换；未来淡化区整体降透明度
                let item = effectiveItem(li)
                let x = (CGFloat(li) + 0.5) * candleSpacing
                drawOneCandle(ctx, open: item.open, close: item.close, low: item.low, high: item.high,
                              x: x, candleWidth: candleWidth, h: h, hollow: hollow,
                              color: dimmed(item.isUp ? upColor : downColor, li))
            }
            return
        }
        var lo = 0
        while lo < n {
            let hi = min(n, lo + blockLen)
            var low = Double.greatestFiniteMagnitude
            var high = -Double.greatestFiniteMagnitude
            for k in lo..<hi {
                // 合成点在超聚合块内时也参与包络（极窄窗口场景）
                let it = effectiveItem(k)
                if it.low < low { low = it.low }
                if it.high > high { high = it.high }
            }
            let open = effectiveItem(lo).open
            let close = effectiveItem(hi - 1).close
            let span = hi - lo
            let x = (CGFloat(lo) + CGFloat(span) * 0.5) * candleSpacing
            let baseColor = effectiveItem(hi - 1).isUp ? upColor : downColor
            // 整块都在未来区才淡化（跨合成/淡化边界的块保持原色，避免半块变色）
            let color = (dimFromIndex.map { lo >= $0 } ?? false) ? baseColor.opacity(dimAlpha) : baseColor
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
            // 联动复盘：合成索引单点替换、未来淡化
            let item = effectiveItem(li)
            let x = (CGFloat(li) + 0.5) * candleSpacing
            let color = dimmed(item.isUp ? upColor : downColor, li)
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
            strokeLine(ctx, values: curve.values, color: curve.color, h: h, style: .dotline, lineWidth: curve.lineWidth, step: step,
                       dimFrom: dimFromIndex, dimAlpha: dimAlpha)
        case .pointdot:
            let colors = curve.markerColors
            for idx in decimatedIndices(count: curve.values.count, step: step) {
                let v = curve.values[idx]
                guard !v.isNaN else { continue }
                let x = (CGFloat(idx) + 0.5) * candleSpacing
                let y = yPos(v, h: h)
                let c = dimmed(colors?[idx] ?? curve.color, idx)
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
                ctx.fill(Path(rect), with: .color(dimmed(curve.color, i)))
            }
        case .solid:
            strokeLine(ctx, values: curve.values, color: curve.color, h: h, style: .solid, lineWidth: curve.lineWidth, step: step,
                       dimFrom: dimFromIndex, dimAlpha: dimAlpha)
        case .nodraw:
            break
        }
    }

    /// 折线绘制，支持联动复盘的「历史原色 / 未来淡化」两段着色：
    /// dimFrom 之前（含合成点 idx）原色，dimFrom 起（含）淡化。NaN 在各段内自然断开。
    private func strokeLine(_ ctx: GraphicsContext, values: [Double], color: Color, h: CGFloat, style: TDXLineStyle, lineWidth: Double, step: Int = 1,
                            dimFrom: Int? = nil, dimAlpha: Double = 1.0 / 3.0) {
        let s: StrokeStyle = style == .dotline ? StrokeStyle(lineWidth: lineWidth, dash: [3, 3]) : StrokeStyle(lineWidth: lineWidth)
        let indices = decimatedIndices(count: values.count, step: step)
        let boundary = dimFrom ?? values.count
        // 历史段（i < boundary）
        var hist = Path(); var histStarted = false
        // 未来段（i >= boundary）
        var fut = Path(); var futStarted = false
        for i in indices {
            let v = values[i]
            guard !v.isNaN else { continue }
            let x = (CGFloat(i) + 0.5) * candleSpacing
            let y = yPos(v, h: h)
            if i < boundary {
                if histStarted { hist.addLine(to: CGPoint(x: x, y: y)) } else { hist.move(to: CGPoint(x: x, y: y)); histStarted = true }
            } else {
                if futStarted { fut.addLine(to: CGPoint(x: x, y: y)) } else { fut.move(to: CGPoint(x: x, y: y)); futStarted = true }
            }
        }
        if histStarted { ctx.stroke(hist, with: .color(color), style: s) }
        if futStarted { ctx.stroke(fut, with: .color(color.opacity(dimAlpha)), style: s) }
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

/// 指标名称按钮：单击立即切换选择面板；参数编辑入口在面板内。
/// （信息栏也用它渲染主图指标按钮，故不对本文件私有；图标已移除，只留标题。）
struct IndicatorNameButton: View {
    let title: String
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .medium))
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
    /// 联动复盘：未来淡化起始本地索引（含），nil = 不淡化
    var dimFromIndex: Int? = nil
    var dimAlpha: Double = 1.0 / 3.0
    /// 联动复盘：VOL/AMO 在光标索引处的合成柱（值已按镜像取负）
    var syntheticStick: SyntheticStick? = nil

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
            // 联动复盘：合成索引的柱（VOL/AMO）单点替换为合成量/额
            let synthHere = syntheticStick?.index == i ? syntheticStick : nil
            let v = synthHere?.value ?? curve.values[i]
            guard !v.isNaN else { continue }
            let x = (CGFloat(i) + 0.5) * candleSpacing
            let yv = yPos(v, h: h)
            let rect = CGRect(x: x - barWidth / 2, y: min(yZero, yv), width: barWidth, height: max(0.5, abs(yZero - yv)))
            var color: Color
            switch curve.barColor {
            case .sign: color = v >= 0 ? upColor.opacity(0.85) : downColor.opacity(0.85)
            case .candle:
                // 合成柱的涨跌按合成K线；否则按原 slice
                let isUp = synthHere?.isUp ?? (i < slice.count ? slice[i].isUp : v >= 0)
                color = isUp ? upColor.opacity(0.85) : downColor.opacity(0.85)
            case .fixed: color = curve.color
            }
            // 未来淡化区柱体降透明度（合成点本身不淡化）
            if let d = dimFromIndex, i >= d { color = color.opacity(dimAlpha) }
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
                var c = colors?[idx] ?? curve.color
                if let d = dimFromIndex, idx >= d { c = c.opacity(dimAlpha) }
                var dot = Path()
                dot.addEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                ctx.fill(dot, with: .color(c))
            }
            return
        }
        // 联动复盘：历史段原色、未来段淡化（NaN 在各段内自然断开）
        let boundary = dimFromIndex ?? curve.values.count
        var hist = Path(); var histStarted = false
        var fut = Path(); var futStarted = false
        for i in decimatedIndices(count: curve.values.count, step: step) {
            let v = curve.values[i]
            guard !v.isNaN else { continue }
            let x = (CGFloat(i) + 0.5) * candleSpacing
            let y = yPos(v, h: h)
            if i < boundary {
                if histStarted { hist.addLine(to: CGPoint(x: x, y: y)) } else { hist.move(to: CGPoint(x: x, y: y)); histStarted = true }
            } else {
                if futStarted { fut.addLine(to: CGPoint(x: x, y: y)) } else { fut.move(to: CGPoint(x: x, y: y)); futStarted = true }
            }
        }
        let s: StrokeStyle = curve.style == .dotline ? StrokeStyle(lineWidth: curve.lineWidth, dash: [3, 3]) : StrokeStyle(lineWidth: curve.lineWidth)
        if histStarted { ctx.stroke(hist, with: .color(curve.color), style: s) }
        if futStarted { ctx.stroke(fut, with: .color(curve.color.opacity(dimAlpha)), style: s) }
    }

    private func yPos(_ v: Double, h: CGFloat) -> CGFloat {
        let range = rangeMax - rangeMin
        guard range > 0 else { return h }
        return h * CGFloat(1 - (v - rangeMin) / range)
    }
}

// MARK: - 顶部圆角矩形（iOS 15 兼容的 UnevenRoundedRectangle 替代）
// 底部面板贴紧物理屏幕底边时使用：只圆顶部两角，底部两角为直角，
// 避免贴底后底部圆角缝隙露出深色遮罩
struct TopRoundedCornerRect: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(radius, min(rect.width, rect.height) / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                 radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                 radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

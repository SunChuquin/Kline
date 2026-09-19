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
/// （internal：IndicatorPipeline.swift 的管线方法也使用）
func klineDebug(_ message: @autoclosure () -> String) {
    #if DEBUG
    if klineDebugLoggingEnabled { print(message()) }
    #endif
}


/// 行情 K 线图。
struct KlineChartView: View {
    private let series: ChartSeries
    /// 当前标的 ID（用于按 (标的, 周期) 读写指标计算缓存；nil 时不使用缓存）
    let metaId: Int?
    /// 当前行情周期（用于主图指标名称按钮显示 "日线: MA" 之类前缀）
    let period: KlinePeriod
    /// 是否使用独立的副图模型实例（双联动左右视图各用一套，避免共享模型被不同数据长度的曲线互相覆盖）
    let isolatedSubs: Bool
    /// 隐藏主图指标数值栏右侧的「放大/缩放」按钮（联动多视图场景不提供主图放大）
    let hideMainZoomButton: Bool
    /// 是否为联动多图 tile（影响时间轴周期数显示等联动专属样式）
    let isLinkedTile: Bool
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
    /// 信息行被拖动上报（多图重置按钮高亮用）：任一信息行内容被拖动置 true。
    var onInfoRowPanned: ((Bool) -> Void)? = nil
    /// 是否为主格（单图 / 联动多图的第一格）：只有主格消费悬浮按钮（新按钮）转圈发出的光标命令，
    /// 其余格完全不响应。默认 false，避免影响既有调用点。
    var isMainTile: Bool = false

    // 交互状态
    @State var selectedIndex: Int? = nil
    /// 联动开启后、非来源的**小周期范围框视图**里的「第二个十字光标」：纯本地状态，
    /// 不发布到 linkSync、不影响来源视图的合成/淡化、也不会让其他视图出现第二份光标；
    /// 各视图相互独立。仅来源视图再点一下（或任何全局清场）时才清除。
    @State var secondCursorIndex: Int? = nil
    @State var secondCursorY: CGFloat? = nil
    /// 副图三「裸」按钮控制的主图裸K：仅隐藏主图指标显示，不触发重算、不清除 mainCurves 缓存
    @State var bareFromSub = false
    /// 联动光标会话标记：收到有效联动光标/范围时置 true，来源光标消失时置 false。
    /// 当前实现下每次 applyLinkCursor 都无条件把目标K线（或范围）滚动居中，居中不再依赖本标记
    /// （旧「仅第一次出现时居中、之后拖动只移动不居中」的语义已废弃）；目前只写不读，
    /// 保留以便日后需要区分「首次出现 / 持续拖动」时复用。
    @State var linkCursorActive = false
    /// 📌 开启时固定下来的第一个光标（不可被点击清除；只随 pinEnabled 关闭而清除）
    @State var pinnedIndex: Int? = nil
    @State var pinnedY: CGFloat? = nil
    /// 固定光标固定时刻的横轴价格（仅主图区域有效）：平移/缩放后横轴价格不随可见窗口价格范围变化
    @State var pinnedPrice: Double? = nil
    @State var visibleCount: CGFloat = 100
    @State var endOffset: Int = 0
    @State var zoomBase: CGFloat = 100
    // 缩放锚点：以双指位置对应的K线为基线缩放（而非屏幕最右端）
    @State var zoomAnchorIndex: Int? = nil
    @State var zoomAnchorOffset: CGFloat = 0
    @State var drag = DragState()
    /// 亚像素平移偏移（px）：缓慢拖动时画面平滑跟手，累计满一根K线间距才进位移动可见窗口
    @State var panOffset: CGFloat = 0
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
    @State var swipeSubSlotTriggered = false
    @State var crosshairY: CGFloat? = nil
    /// 已消费的悬浮按钮转圈命令序号：订阅 @Published 时会立即收到当前值（重放），
    /// 靠它把重放过滤掉，保证同值命令可重复触发、旧命令不会被二次施加
    @State var lastAccessoryAdvanceSeq = 0
    /// 指标/预计算状态域（跳空缺口、主图曲线、覆盖区间、预计算 token 等）：
    /// 从 7 个散落 @State 收敛为 ObservableObject（IndicatorPipeline.swift）。
    /// 全部低频写入、无 .onChange 挂钩，写入触发本视图重绘（与原 @State 行为一致，性能中性）
    @StateObject var computation: IndicatorComputationStore
    @ObservedObject var customStore = CustomIndicatorStore.shared
    @ObservedObject var config = ChartConfigStore.shared

    /// 主图放大模式：隐藏三个副图 K 线区域（副图名称/指标栏保留并挤到最下方），主图占满剩余空间
    @State var mainFullscreen = false

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
         onVisibleCountChange: (@MainActor (CGFloat) -> Void)? = nil,
         onInfoRowPanned: ((Bool) -> Void)? = nil,
         isMainTile: Bool = false) {
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
        self.onInfoRowPanned = onInfoRowPanned
        self.isMainTile = isMainTile
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
        // 指标/预计算状态域：缺口一次性计算 + (标的, 周期) 缓存恢复在 store init 内完成
        self._computation = StateObject(wrappedValue: IndicatorComputationStore(
            all: all, metaId: metaId, period: period))
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
        // 注：指标/预计算域（主图曲线/覆盖/缺口）的缓存恢复已移入 IndicatorComputationStore.init。
        // 注：副图曲线（subTop/subBottom/subThird）的恢复/清空不在此 init 做。
        // 这些是跨页面共享的 @ObservedObject 模型，而 KlineChartView 会因 body 重算被
        // SwiftUI 反复 init；若在 init 里按缓存清空/覆盖共享模型，会在光标变化等重算
        // 时把未切换副图的现有曲线清空（切指标后后台未完成时尤其明显）。
        // 副图曲线的正确性由 recomputeSub（其内部已含 bgCovered 时的缓存恢复路径）统一负责。
        // 周期签名校验（声明周期 vs K 线尾部日期间距推断周期）放在 onAppear 执行，
        // 不在 init 阶段跑：避免 Xcode Debug 模式在 init 阶段执行 Calendar/日期相关代码
        // 或 Main Thread Checker / Swift Concurrency 检查时触发断言，出现详情页崩溃。
    }

    /// 当前主图自定义指标（从共享仓库中按当前周期激活的 ID 派生）
    var activeCustomIndicator: CustomIndicator? {
        customStore.indicators.first { $0.id == config.activeCustomIndicatorID(for: self.period) && availableInCurrentPeriod($0) }
    }

    // MARK: - 配色

    var upColor: Color { Color(red: 0.85, green: 0.16, blue: 0.16) }
    var downColor: Color { Color(red: 0.0, green: 0.55, blue: 0.35) }
    var gridColor: Color { Color.gray.opacity(0.22) }
    var axisTextColor: Color { Color(.label).opacity(0.55) }
    private var bollColor: Color { Color(red: 0.4, green: 0.4, blue: 0.9) }
    private var ma5Color: Color { Color(.label).opacity(0.75) }
    private var ma10Color: Color { Color.orange }
    private var ma20Color: Color { Color.pink }

    func maColor(_ i: Int) -> Color {
        let colors = [Color(.label).opacity(0.75), Color.orange, Color.pink, Color.blue,
                      Color(red: 0.9, green: 0.6, blue: 0), Color.teal, Color.purple, Color.brown]
        return colors[i % colors.count]
    }

    var sortedData: [KlineItem] { sortedAll }
    private var closes: [Double] { baseCloses }
    private var highs: [Double] { baseHighs }
    private var lows: [Double] { baseLows }
    private var opens: [Double] { baseOpens }
    var volumes: [Double] { baseVolumes }
    var turnovers: [Double] { baseTurnovers }

    // MARK: - 可见窗口

    var count: Int { min(max(20, Int(visibleCount.rounded())), capVisibleCount) }
    var maxVisibleCount: Int { sortedData.count }
    /// 可见 K 线数上限：非放大与放大模式都允许显示全部 K 线（不限制）
    var capVisibleCount: Int { maxVisibleCount }
    var endIndex: Int {
        let maxEnd = sortedData.count - 1
        let minEnd = max(0, count - 1)
        return min(maxEnd, max(minEnd, maxEnd - endOffset))
    }
    var startIndex: Int { max(0, endIndex - count + 1) }
    var slice: [KlineItem] {
        guard startIndex <= endIndex, startIndex >= 0, endIndex < sortedData.count else { return [] }
        return Array(sortedData[startIndex...endIndex])
    }
    private func sliceArr(_ arr: [Double]) -> [Double] {
        guard !arr.isEmpty, startIndex <= endIndex, endIndex < arr.count else { return [] }
        return Array(arr[startIndex...endIndex])
    }
    func sliceColors(_ arr: [Color]?) -> [Color]? {
        guard let arr, !arr.isEmpty, startIndex <= endIndex, endIndex < arr.count else { return arr }
        return Array(arr[startIndex...endIndex])
    }

    // MARK: - 镜像（多/空）

    /// 主图是否开启空头镜像（纯取负）
    var mainMirrored: Bool { config.mainMirrored }

    /// 取负：主图开启镜像时把数值取负
    func mir(_ v: Double) -> Double { mainMirrored ? -v : v }

    /// 可见窗口曲线的取负版本（用于画布），未镜像时原样返回
    func mirroredSliceArr(_ values: [Double]) -> [Double] {
        let s = sliceArr(values)
        guard mainMirrored else { return s }
        return s.map { -$0 }
    }

    /// 副图可见窗口曲线的取负版本（全局空头镜像开启时）
    func subMirroredSliceArr(_ values: [Double]) -> [Double] {
        let s = sliceArr(values)
        guard config.mainMirrored else { return s }
        return s.map { -$0 }
    }

    /// 镜像后的可见 K 线（OHLC 取负；日期/量额不变，仅供画布绘制）
    var mirroredSlice: [KlineItem] {
        guard mainMirrored else { return slice }
        return slice.map { it in
            KlineItem(date: it.date, open: -it.open, high: -it.high, low: -it.low,
                      close: -it.close, volume: it.volume, turnover: it.turnover)
        }
    }

    /// 镜像后的跳空缺口（top/bottom 取负）
    var mirroredGaps: [GapInfo] {
        guard mainMirrored else { return computation.gaps }
        return computation.gaps.map { g in GapInfo(startIdx: g.startIdx, top: -g.top, bottom: -g.bottom, isUp: g.isUp, filledIdx: g.filledIdx) }
    }

    /// 镜像后的最新一根 K 线（最新价线用）
    var mirroredLatest: KlineItem? {
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

    // MARK: - 指标序列计算


    /// 主图是否裸K：用户手动设置 或 主图放大模式（全屏裸K，不计算任何指标）
    var isBareK: Bool { bareFromSub || config.showBareK || mainFullscreen }

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



    // MARK: - 主图价格区间

    var priceRange: ClosedRange<Double> {
        guard !slice.isEmpty else { return 0...100 }
        var minLow = slice.map(\.low).min() ?? 0
        var maxHigh = slice.map(\.high).max() ?? 100
        // 默认打开"指标不挤压K线"：范围只按K线自身计算；关闭时才纳入指标线范围（K线被挤压）
        if !displaySettings.indicatorNotSqueezeKline {
            let offsets = Array(startIndex...endIndex).filter { $0 < closes.count }
            var all: [Double] = []
            for line in computation.mainCurves {
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

    func subRange(_ m: SubChartModel) -> (min: Double, max: Double) {
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

    var menuIsOpen: Bool { editorUI.showMainSheet || editorUI.showSubSheet || showCustomEditor || showSystemEditor }

    func clamp<V: Comparable>(_ v: V, _ lo: V, _ hi: V) -> V { min(max(v, lo), hi) }

    /// 标签文本实际渲染宽度（含左右各 4pt 内边距）：用于贴边判定，避免用估算半宽导致提前贴边


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
        .background(Color(.systemBackground))
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
            computation.prefetchToken = nil
            // 同时终止惯性滑动：CADisplayLink 持有动画器 target，不终止会随悬空闭包
            // 继续写已销毁视图的 @State（白耗帧且可能掩盖新视图的初始状态）
            cancelPanInertia()
            // 「光标贴边自动拖动」同为 CADisplayLink 驱动，同样必须终止
            stopEdgeAutoScroll()
        }
        .onChange(of: sortedData.count) { _ in
            // 数据刷新（实时K线追加/历史预取落盘等）：终止惯性——动画器闭包持有旧的
            // 数据副本，边界钳制（sortedData.count - count）会与新数据失真
            cancelPanInertia()
            stopEdgeAutoScroll()
        }
        .onChange(of: selectedIndex) { newIdx in
            klineDebug("[KlineDebug] 光标变化(selectedIndex) -> new:\(String(describing: newIdx)) | 变化后副图:[\(subTop.kind):\(subTop.curves.count), \(subBottom.kind):\(subBottom.curves.count), \(subThird.kind):\(subThird.curves.count)] pinned:\(String(describing: pinnedIndex))")
            notifyHasCursor()
            publishLinkCursor(index: newIdx)
            // 「光标贴边自动拖动」的唯一停法之一：该光标被现有任何方式清除（轻点清除、
            // 关闭光标联动、退出联动、切周期/标的销毁视图等最终都会让 selectedIndex 归 nil）
            if newIdx == nil { stopEdgeAutoScroll() }
        }
        // 悬浮按钮（新按钮）环上转圈 → 光标推进命令。仅主格消费（其余格在方法内直接 return）；
        // 无命令时本路径不写任何状态，既有手势/惯性/贴边自动滚动/联动发布全部不参与。
        // 订阅 @Published 时会立即收到当前值，靠 seq 去重，避免重放被当成新命令
        .onReceive(FloatingAccessoryCoordinator.shared.$cursorAdvance) { cmd in
            applyAccessoryCursorAdvance(cmd)
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

    /// 消费悬浮按钮（新按钮）转圈命令：
    /// - 仅主格生效，其余格与未收到命令时一律零写入；
    /// - 无光标（selectedIndex == nil）时不生成（贴边生成属第 4 阶段），直接忽略；
    /// - 有光标时按 candles 平移，并夹在可见窗口 startIndex...endIndex 内（越界停在边缘，
    ///   窗口反向滚动属第 4 阶段）。
    private func applyAccessoryCursorAdvance(_ cmd: FloatingAccessoryCursorAdvance?) {
        guard isMainTile, let cmd else { return }
        guard cmd.seq != lastAccessoryAdvanceSeq else { return }
        lastAccessoryAdvanceSeq = cmd.seq
        guard let cur = selectedIndex else { return }
        let target = min(max(cur + cmd.candles, startIndex), endIndex)
        guard target != cur else { return }
        selectedIndex = target
    }

    func refreshCurves(force: Bool = false) {
        klineDebug("[KlineDebug] refreshCurves force=\(force) bgEnd=\(computation.bgCoverageEnd) endIdx=\(endIndex) cursor=\(selectedIndex == nil ? "无" : "有")")
        recomputeMainCurves(force: force)
        recomputeSub(subTop, force: force)
        recomputeSub(subBottom, force: force)
        recomputeSub(subThird, force: force)
    }


    func model(for slot: SubSlot) -> SubChartModel {
        switch slot {
        case .top: return subTop
        case .bottom: return subBottom
        case .third: return subThird
        }
    }

    func activateCustom(_ ind: CustomIndicator?) {
        config.setActiveCustom(ind?.id, for: self.period)
        recomputeMainCurves(force: true)
    }

    func activateSubCustom(_ m: SubChartModel, _ ind: CustomIndicator?) {
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
        let bodyTop = yPos(max(open, close), h: h)
        let bodyBottom = yPos(min(open, close), h: h)
        let rect = CGRect(x: x - candleWidth / 2, y: bodyTop, width: candleWidth, height: max(1, bodyBottom - bodyTop))
        let isHollow = hollow && close >= open
        // 影线分上下两段、跳过实体矩形内部（先画影线再画实体，实体填充会盖住重叠部分）：
        // 淡化区颜色是半透明的（opacity(dimAlpha)），若整条影线先画、再被同色半透明实体覆盖，
        // 重叠处 alpha 叠加为 1-(1-a)²，明显高于实体本身（a=1/3 时 0.33→0.56），
        // 视觉上就是实心蜡烛矩形正中多出一条更深的竖线；不淡化（不透明）时本就看不出来。
        // 空心蜡烛内部用画布底色填充、影线本就不可见，仍按整条绘制
        var wick = Path()
        if isHollow {
            wick.move(to: CGPoint(x: x, y: yH)); wick.addLine(to: CGPoint(x: x, y: yL))
        } else {
            wick.move(to: CGPoint(x: x, y: yH)); wick.addLine(to: CGPoint(x: x, y: bodyTop))
            wick.move(to: CGPoint(x: x, y: bodyBottom)); wick.addLine(to: CGPoint(x: x, y: yL))
        }
        ctx.stroke(wick, with: .color(color), lineWidth: 1)
        if isHollow {
            // 悬空蜡烛：内部填充画布底色（夜间自适应），只留描边
            ctx.fill(Path(rect), with: .color(Color(.systemBackground)))
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
                .foregroundColor(.primary)
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

//
//  MarketPageModel.swift
//  Kline
//
//  行情页状态模型与批量动作（P2-7 从 MarketPageKit.swift 拆出；MarketBridge 活引用，
//  原生四档布局随 JSON 布局系统退役，模型与数据口径保留）。
//

import SwiftUI
import Combine
import UIKit

/// 行情页顶部一级菜单（参考测试页2：居中 Tab）
enum TopField: String, CaseIterable, Identifiable {
    case market = "市场"
    case picker = "选股"
    case fav = "自选"
    var id: String { rawValue }
}

/// 选股 → 二级
enum PickerField: String, CaseIterable, Identifiable {
    case trend = "趋势"
    case oscillation = "震荡"
    case reversal = "反转"
    case sentiment = "情绪"
    var id: String { rawValue }
}

/// 自选 → 二级
enum FavField: String, CaseIterable, Identifiable {
    case holdings = "持仓"
    case pool = "股池"
    var id: String { rawValue }
}

/// 行情页「市场」二级分类（对应 tdx_parser.py 生成的 meta.type 取值；
/// 「ETF指数」= 沪深京指数 + 扩展行情指数 合并展示）
enum MarketTab: String, CaseIterable, Identifiable {
    case mainBoard = "沪深主板"
    case etfIndex = "ETF指数"
    var id: String { rawValue }
}


// MARK: - 行高 / 字号参数

/// 表格行高与字号参数：A 档沿用 `.regular`（= 改造前写死的 38 表头 / 45 数据行 / 18 字号），
/// 紧凑布局（D 档 = 32 / 34 / 15）传入更小的值。
///
/// `MarketTableBody` 把这三个值**透传**给 `MarketTableRow` 的 `heightOverride` / `fontSizeOverride`：
/// `.regular` 与改动前逐值相等 → A 档渲染零变化；紧凑档由行内部真实压缩行高与字号
/// （不能靠行外层 frame 硬压——那样行内容仍按原高度渲染，会溢出重叠）。
struct MarketRowMetrics: Equatable {
    var headerHeight: CGFloat = 38
    var rowHeight: CGFloat = 45
    var fontSize: CGFloat = 18

    /// 现有实现（A 档）的取值
    static let regular = MarketRowMetrics()
}

// MARK: - 市场宽度概览（D 档概览条）

/// 当前分类快照的聚合统计：由 `MarketPageModel.scheduleRefresh()` 一次性算好写入 `model.overview`，
/// 布局视图只读取、不在 `body` 里遍历全表。
struct MarketOverview: Equatable {
    /// 有效行数（`changePct` 非 nil 的行）
    var validCount: Int = 0
    var up: Int = 0
    var down: Int = 0
    var flat: Int = 0
    /// 涨停 / 跌停：主板 10% 口径，pct >= 9.8 / <= -9.8
    var limitUp: Int = 0
    var limitDown: Int = 0
    /// 有效行的成交额合计（元）
    var totalTurnover: Double = 0
}

// MARK: - B 档侧栏条目

/// 侧栏条目（B 档）：一级分区 + 其下二级条目；`badge` 为数量角标，nil 表示无真实数据源（界面显示 "-"）。
/// 放在文件级（而非 `MarketPageModel` 内嵌）以避开 `@MainActor` 类型的内嵌类型隔离约束。
struct MarketTopMenuItem: Identifiable {
    let field: TopField
    let title: String
    /// 二级分类的 rawValue（选中判定用）
    let key: String
    let badge: String?
    var id: String { "\(field.rawValue)_\(key)" }
}

// MARK: - 页面状态模型（四档布局共用）

/// 行情页状态模型：分类状态 + 列表快照 + 浮层开关 + 横向滚动 / 列宽调整逻辑。
/// 由容器 `MarketView` 以 `@StateObject` 持有，各布局视图以 `@ObservedObject` 消费。
@MainActor
final class MarketPageModel: ObservableObject {

    // MARK: 共享数据源（全部是既有单例，不新增数据源）
    let databaseManager = DatabaseManager.shared
    let fav = FavoritesStore.shared
    let rowCache = MarketRowCache.shared
    let colCfg = MarketConfigStore.shared

    // MARK: 分类状态
    @Published var topMenu: TopField = .market
    @Published var secondLevelVisible: Bool = false
    @Published var selectedTab: MarketTab = .mainBoard
    @Published var pickerSeg: PickerField = .trend
    @Published var favSeg: FavField = .holdings

    // MARK: 列表快照与配置
    /// **渲染用的行快照**：由 `scheduleRefresh()` 写入，避免在计算属性里做预取副作用（否则会死循环触发重绘）。
    @Published var displayRows: [MarketRow] = []
    /// D 档概览统计：在 `scheduleRefresh()` 里对 filtered 快照一次性算好（布局视图禁止在 body 内遍历全表）
    @Published var overview: MarketOverview? = nil
    /// C 档「磁贴 / 表格」分段切换：true = 磁贴网格，false = 复用表格主体
    @Published var showsTileMode: Bool = true
    /// 「边」边线调节模式：开启后表头/数据行列边界显示可拖分隔线，左右拖动调整列宽并持久化
    @Published var edgeAdjust = false
    /// 整表横向滚动偏移（冻结前 N 列固定，其余列平移）
    @Published var hScrollOffset: CGFloat = 0
    /// 表格宿主实测宽度（安全区内，异形屏横屏已扣除刘海侧 inset）
    @Published var tableVisibleWidth: CGFloat = 0
    /// 布局自身常驻占据的横向宽度（B 档左侧分类侧栏 200pt；其余档 0），
    /// 由容器按当前布局写入：容器实测的是整页宽度，含侧栏时必须扣掉才是表格可视宽
    @Published var tableWidthInset: CGFloat = 0

    // MARK: 浮层
    @Published var showColumnPanel = false
    @Published var addGroupTarget: MetaItem? = nil
    /// 长按操作面板目标（nil = 未打开；面板挂在容器层 overlay，行 / 磁贴不挂任何 menu）
    @Published var rowMenuTarget: FavoritesRowMenuTarget? = nil
    /// 备注弹窗目标（全局备注，与自选页共享同一条）
    @Published var noteEditorTarget: FavoritesRowMenuTarget? = nil
    /// 预警弹窗目标（单只预警 = 1 只；批量预警 = N 只，同一弹窗与创建路径）
    @Published var alertSheetTargets: [MetaItem] = []

    // MARK: 批量编辑（长按面板「批量编辑」进入；列表换成简易多选列表 + 底部批量条）
    /// 是否处于批量编辑态：true 时表格/磁贴整体换成 `MarketBatchList`
    @Published var batchMode = false
    /// 批量编辑：多选集合（SelectionValue = metaID）
    @Published var batchSelection: Set<Int> = []
    /// 批量备注弹窗载体（打开瞬间快照选中标的）；批量预警复用上面的 alertSheetTargets
    @Published var batchNoteTarget: BatchNoteTarget? = nil
    /// 点击顶部搜索图标后弹出搜索页（复用 HomeView 搜索模式，等同双击首页的效果）
    @Published var homeSearchActive = false
    /// 公式管理中心页（全屏 overlay）开合：仅「选股」Tab 工具区入口触发
    @Published var showFormulaCenter = false

    // MARK: 内部
    var hDragStart: CGFloat = 0
    var panAxisIsH: Bool? = nil
    /// 有字段筛选生效时，合并 bars 陆续到位触发的重筛选（防抖，避免每行刷全表）
    var filterDebounce: DispatchWorkItem? = nil
    /// 概览统计的防抖重算任务（bars 陆续到位时合并触发，避免逐行 O(n) 重算）
    var overviewDebounce: DispatchWorkItem? = nil

    private var cancellables = Set<AnyCancellable>()

    init() {
        // 数据源的 objectWillChange 全部在主线程发布，直接转发（不加线程跳转，保持与改造前同一帧刷新时机）。
        // 作用：列配置 / 行缓存 / 库加载等变化时，直接观察本模型的子视图（表格主体、边线覆盖层）能重算，
        // 不依赖容器重跑 body 后的逐层传递。
        forward(colCfg.objectWillChange)
        forward(rowCache.objectWillChange)
        forward(databaseManager.objectWillChange)

        // 批量编辑：切换分类 / 一级二级菜单 / 布局 / 磁贴表格态后，行集已完全不同，
        // 「看不见的行」不应继续被批量动作命中 → 清空选择、但保持批量态
        // （与自选页「切分组清空选择、保持编辑态」口径一致，见 FavoritesPageKit.init）
        $selectedTab.dropFirst().sink { [weak self] _ in self?.setBatchSelection([]) }
            .store(in: &cancellables)
        $topMenu.dropFirst().sink { [weak self] _ in self?.setBatchSelection([]) }
            .store(in: &cancellables)
        $pickerSeg.dropFirst().sink { [weak self] _ in self?.setBatchSelection([]) }
            .store(in: &cancellables)
        $favSeg.dropFirst().sink { [weak self] _ in self?.setBatchSelection([]) }
            .store(in: &cancellables)
        $showsTileMode.dropFirst().sink { [weak self] _ in self?.setBatchSelection([]) }
            .store(in: &cancellables)
        // P2-7：布局切换订阅随 JSON 布局系统退役（切分类等既有订阅已覆盖批量态清理）

        // ⚠️ 自选页没有的坑：切到无标的分类时四档都渲染空态视图，批量列表与「完成」按钮会一起消失，
        // 用户将卡在批量态且没有出口 → 行集变空即自动退出批量编辑
        $displayRows.map(\.isEmpty).removeDuplicates().dropFirst()
            .sink { [weak self] isEmpty in
                guard isEmpty, let self, self.batchMode else { return }
                self.exitBatchMode()
            }
            .store(in: &cancellables)
    }

    /// 把数据源的 objectWillChange 转发到本模型
    private func forward<P: Publisher>(_ publisher: P) where P.Failure == Never {
        publisher
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - 派生数据

    /// 当前「市场」二级分类对应的 meta.type 取值集合
    /// （ETF指数 合并展示原「指数」+「ETF」两类内容）
    private var currentTypes: [String] {
        selectedTypes(for: selectedTab)
    }

    /// 给定「市场」二级分类 → 对应的 meta.type 取值集合（B 档侧栏数量角标也用它）
    func selectedTypes(for tab: MarketTab) -> [String] {
        switch tab {
        case .mainBoard: return ["沪深主板"]
        case .etfIndex: return ["沪深京指数", "扩展行情指数"]
        }
    }

    /// 当前二级分类名（B 档右侧工作区标题；选股/自选按各自二级状态）
    var currentCategoryTitle: String {
        switch topMenu {
        case .market: return selectedTab.rawValue
        case .picker: return pickerSeg.rawValue
        case .fav: return favSeg.rawValue
        }
    }

    /// 某个一级分区下的二级条目（B 档侧栏用）
    func topMenuItems(for field: TopField) -> [MarketTopMenuItem] {
        switch field {
        case .market:
            return MarketTab.allCases.map { tab in
                MarketTopMenuItem(field: .market, title: tab.rawValue, key: tab.rawValue,
                                  badge: "\(itemCount(tab: tab))")
            }
        case .picker:
            // 选股 / 自选暂无真实数据源：角标显示 "-"
            return PickerField.allCases.map { p in
                MarketTopMenuItem(field: .picker, title: p.rawValue, key: p.rawValue, badge: nil)
            }
        case .fav:
            return FavField.allCases.map { f in
                MarketTopMenuItem(field: .fav, title: f.rawValue, key: f.rawValue, badge: nil)
            }
        }
    }

    /// 「市场」某二级分类的标的数量（B 档侧栏角标）
    func itemCount(tab: MarketTab) -> Int {
        let types = selectedTypes(for: tab)
        return databaseManager.metaList.filter { types.contains($0.type) }.count
    }

    /// B 档侧栏点击某条目：写一级 + 对应二级状态，再刷新（分类状态与 A 档共用）
    func setSidebarSelection(_ item: MarketTopMenuItem) {
        topMenu = item.field
        switch item.field {
        case .market:
            if let tab = MarketTab(rawValue: item.key), selectedTab != tab { selectedTab = tab }
        case .picker:
            if let p = PickerField(rawValue: item.key), pickerSeg != p { pickerSeg = p }
        case .fav:
            if let f = FavField(rawValue: item.key), favSeg != f { favSeg = f }
        }
        scheduleRefresh()
    }

    /// C 档「磁贴 / 表格」切换（同值赋值加守卫）
    func toggleTileMode(_ tile: Bool) {
        if showsTileMode != tile { showsTileMode = tile }
    }

    /// 当前「市场」二级分类下的全部标的（搜索已改为独立搜索页，不在此就地过滤）
    var tabItems: [MetaItem] {
        databaseManager.metaList.filter { currentTypes.contains($0.type) }
    }

    /// 表格冻结列数（「行情表设置」面板可配置：第 1 列恒冻结，第 2/3 列可开关；范围 1~3）
    var frozenCount: Int {
        colCfg.frozenCount(for: .marketBoard)
    }

    /// 当前排序字段（无排序时为 nil）
    var currentSortField: MarketField? {
        colCfg.sortRule(for: .marketBoard)?.field
    }

    /// 当前页面是否有任一字段筛选生效（决定 bars 到位后是否防抖重刷）
    var hasActiveFilters: Bool {
        !colCfg.activeFilters(for: .marketBoard).isEmpty
    }

    /// 字段筛选配置的 Equatable 快照（供 onChange 检测「表头设置」里筛选变化）
    var filterConfigKey: [String] {
        colCfg.config(for: .marketBoard).columns
            .filter { !$0.filterLabels.isEmpty }
            .map { "\($0.field.rawValue)=\($0.filterLabels.sorted().joined(separator: "|"))" }
    }

    /// 可视列里冻结前 N 列后，其余列的最大可左移量（整表横向滚动上限）
    var maxHOffset: CGFloat {
        // 可视宽度用实测宿主宽（安全区内）再扣掉布局自带的常驻横向占位（B 档侧栏）；
        // 首帧未测量完成前退回 UIScreen 估算
        let hostW = tableVisibleWidth > 0 ? tableVisibleWidth : UIScreen.main.bounds.width
        let visW = max(0, hostW - tableWidthInset)
        return max(0, MarketTableRow.scrollContentWidth(for: .marketBoard, config: colCfg, frozenCount: frozenCount)
             - visW)
    }

    // MARK: - 刷新

    /// 一次性：分置顶/非置顶 → 置顶优先预取 → 注册壳 → 排序 → 写入 displayRows。
    /// **仅在输入变化时调用**（tab/搜索/加载完毕/收藏变化/排序规则变化），不在计算属性里调用。
    func scheduleRefresh() {
        guard databaseManager.isLoaded else {
            displayRows = []
            if overview != nil { overview = nil }
            return
        }
        let metas = tabItems
        // 1) 分固定 / 非固定
        let pinnedMetas = metas.filter { fav.isPinned($0.id) }
        let othersMetas = metas.filter { !fav.isPinned($0.id) }

        // 2) **先**触发带优先级的预取（置顶先查，非置顶随后）。
        //    这一步会在 inFlight 中为置顶标先占位，保证它们进入高优先级队列。
        if !pinnedMetas.isEmpty || !othersMetas.isEmpty {
            rowCache.prefetchPrioritized(high: pinnedMetas, low: othersMetas)
        }

        // 3) 注册所有行的壳（prefetch:false，不触发低优预取抢占 inFlight）
        for m in metas { _ = rowCache.row(for: m, prefetch: false) }

        // 4) 按排序规则取快照写入 displayRows
        let pinned = pinnedMetas.compactMap { rowCache.rows[$0.id] }
        let others = othersMetas.compactMap { rowCache.rows[$0.id] }
        let list: [MarketRow]
        if let rule = colCfg.sortRule(for: .marketBoard) {
            list = pinned.sorted(by: rule) + others.sorted(by: rule)
        } else {
            list = pinned + others
        }
        // 5) 字段筛选（表头设置面板配置，可多字段同时生效；同字段多档取 OR，跨字段取 AND）
        let filters = colCfg.activeFilters(for: .marketBoard)
        let filtered: [MarketRow]
        if filters.isEmpty {
            filtered = list
        } else {
            filtered = list.filter { row in
                for (field, options) in filters {
                    guard let v = row.number(field) else { return false }
                    // 同字段多档命中任一即可（OR）
                    if !options.contains(where: { $0.matches(v) }) { return false }
                }
                return true
            }
        }
        // 只在差异大时赋值（减少 SwiftUI 触发）
        if filtered.map(\.id) != displayRows.map(\.id) {
            displayRows = filtered
        }
        // 6) D 档概览统计：对同一份 filtered 快照一次性算好（后续行内取值走 MarketRow 缓存，无额外副作用）
        let stats = Self.makeOverview(filtered)
        if overview != stats { overview = stats }
    }

    /// 概览统计口径（D 档）：
    /// - 只统计 `row.number(.changePct)` 非 nil 的行（有效行）；
    /// - 涨 / 跌 / 平 = pct > 0 / < 0 / == 0；
    /// - 涨停 = pct >= 9.8、跌停 = pct <= -9.8（主板 10% 口径）；
    /// - 总成交额 = 有效行中 `number(.turnover)` 可用值的合计（元）。
    private static func makeOverview(_ rows: [MarketRow]) -> MarketOverview {
        var up = 0, down = 0, flat = 0, limitUp = 0, limitDown = 0
        var turnover: Double = 0
        var valid = 0
        for row in rows {
            guard let pct = row.number(.changePct) else { continue }
            valid += 1
            if pct > 0 { up += 1 } else if pct < 0 { down += 1 } else { flat += 1 }
            if pct >= 9.8 { limitUp += 1 }
            if pct <= -9.8 { limitDown += 1 }
            if let t = row.number(.turnover) { turnover += t }
        }
        return MarketOverview(validCount: valid, up: up, down: down, flat: flat,
                              limitUp: limitUp, limitDown: limitDown, totalTurnover: turnover)
    }

    /// 用当前 `displayRows`（已是筛选后的快照）重算概览：不改列表、不触发预取
    func refreshOverview() {
        let next: MarketOverview? = databaseManager.isLoaded ? Self.makeOverview(displayRows) : nil
        if overview != next { overview = next }
    }

    /// bars 陆续到位时防抖（250ms）重算概览：避免每行到达都做一次 O(n) 全表聚合
    func scheduleOverviewRefresh() {
        overviewDebounce?.cancel()
        // 显式切回 MainActor 再调用（DispatchWorkItem 的 block 不保证隔离继承）
        let m = self
        let item = DispatchWorkItem {
            Task { @MainActor in m.refreshOverview() }
        }
        overviewDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// 一级菜单点击：
    /// - 二级隐藏时：任意点击均展开对应二级菜单；
    /// - 二级显示时：点当前选中项收起；点其他项仅切换内容、保持显示。
    func tapTopMenu(_ field: TopField) {
        if secondLevelVisible {
            if topMenu == field {
                withAnimation(.easeInOut(duration: 0.18)) { secondLevelVisible = false }
                return
            }
            topMenu = field
        } else {
            topMenu = field
            withAnimation(.easeInOut(duration: 0.18)) { secondLevelVisible = true }
        }
        scheduleRefresh()
    }

    // MARK: - 横向滚动 / 列宽

    /// 横向拖拽：侦测主轴向驱动 hScrollOffset（冻结列固定、其余列平移）；
    /// 用 simultaneousGesture 挂在外层垂直 ScrollView 上，上下滑动不受影响。
    var horizontalDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                if self.panAxisIsH == nil {
                    self.panAxisIsH = abs(v.translation.width) > abs(v.translation.height)
                    if self.panAxisIsH == true { self.hDragStart = self.hScrollOffset }
                }
                if self.panAxisIsH == true {
                    let next = min(0, max(-self.maxHOffset, self.hDragStart + v.translation.width))
                    if self.hScrollOffset != next { self.hScrollOffset = next }
                }
            }
            .onEnded { _ in
                if self.panAxisIsH == true {
                    self.hDragStart = self.hScrollOffset
                }
                self.panAxisIsH = nil
            }
    }

    /// 拖动某列分隔线：把最新宽度写回该列对应字段的 widthOverride（持久化到沙盒 JSON）。
    /// 与默认宽一致时清空覆盖值，恢复可跟随默认宽联动。
    func onResizeColumn(_ col: ColumnLayout, _ width: CGFloat) {
        let f = col.overrideField
        let override = MarketTableRow.shouldClearOverride(width, col: col) ? nil : width
        colCfg.setWidthOverride(f, width: override, page: .marketBoard)
        // 收窄可能导致滚动偏移越界：夹回有效范围
        if hScrollOffset < -maxHOffset { hScrollOffset = -maxHOffset }
    }

    // MARK: - 长按操作面板（自绘，替代系统 .contextMenu；面板挂在容器层 overlay）

    /// 行情页上下文：无分组 + 行情页标记（面板不给固顶 / 移前移后）
    func menuTarget(for meta: MetaItem) -> FavoritesRowMenuTarget {
        FavoritesRowMenuTarget(meta: meta, groupID: nil, isMarketPage: true)
    }

    /// 打开长按面板（同值不写，避免 @Published 发布风暴）
    func openRowMenu(_ target: FavoritesRowMenuTarget) {
        if rowMenuTarget != target { rowMenuTarget = target }
    }

    /// 面板项：加自选 / 取消自选、固定 / 取消固定、加入指定分组、批量编辑、备注…、设置 / 取消预警
    /// （行情页无分组概念，故不出现移前移后；口径与搜索页共用 `MetaRowMenuKit`，
    /// 「加入指定分组」复用既有 AddToGroupSheet）
    /// `includeBatchEdit`：已在批量态时不显示（冗余项）
    func rowMenuItems(for target: FavoritesRowMenuTarget) -> [FavoritesRowMenuItem] {
        MetaRowMenuKit.items(for: target.meta, includeBatchEdit: !batchMode)
    }

    /// 执行面板动作（面板已在调用处关闭）：需要弹窗的动作写进本模型的浮层目标
    func performRowMenu(_ action: FavoritesRowMenuAction, for target: FavoritesRowMenuTarget) {
        guard let outcome = MetaRowMenuKit.perform(action, for: target) else { return }
        switch outcome {
        case .addToGroup(let meta):
            addGroupTarget = meta
        case .note(let noteTarget):
            noteEditorTarget = noteTarget
        case .alert(let meta):
            alertSheetTargets = [meta]
        case .batchEdit(let metaID):
            enterBatchMode(preselect: metaID)
        }
    }

    // MARK: - 批量编辑（多选 + 底部批量条）

    /// 进入批量编辑态并预选指定标的（长按面板「批量编辑」入口用：长按哪只就勾上哪只）
    func enterBatchMode(preselect: Int?) {
        if !batchMode { batchMode = true }
        setBatchSelection(preselect.map { [$0] } ?? [])
    }

    /// 退出批量编辑态：清空选择并回到表格 / 磁贴
    func exitBatchMode() {
        setBatchSelection([])
        if batchMode { batchMode = false }
    }

    /// 写多选（同值不写，避免 @Published 发布风暴）
    func setBatchSelection(_ new: Set<Int>) {
        if batchSelection != new { batchSelection = new }
    }

    /// 选中标的快照：按列表当前显示顺序（Set 无序，动作一律按显示顺序执行）
    func batchSelectedMetas() -> [MetaItem] {
        guard !batchSelection.isEmpty else { return [] }
        let selected = batchSelection
        return displayRows.map(\.meta).filter { selected.contains($0.id) }
    }

    /// 批量条项目：行情页无分组上下文，故只给「行情页适用子集」
    /// （加 / 取消自选、固顶 / 取消固顶、设置 / 清除备注、设置 / 取消预警、全选 / 取消全选）。
    /// 「加自选」与「取消自选」刻意拆成两个独立项（与自选页的 固顶/取消固顶、设置备注/清除备注 一致），
    /// 由执行侧「先判方向」保证不会反向操作
    func batchBarItems() -> [MarketBatchItem] {
        let hasSelection = !batchSelection.isEmpty
        let hasAccount = FavoritesAlertKit.accountID != nil
        return [
            MarketBatchItem(action: .addFavorite, title: "加自选",
                           icon: "star", enabled: hasSelection),
            MarketBatchItem(action: .removeFavorite, title: "取消自选",
                           icon: "star.slash", enabled: hasSelection),
            MarketBatchItem(action: .pin, title: "固顶",
                           icon: "pin", enabled: hasSelection),
            MarketBatchItem(action: .unpin, title: "取消固顶",
                           icon: "pin.slash", enabled: hasSelection),
            MarketBatchItem(action: .setNote, title: "设置备注",
                           icon: "note.text", enabled: hasSelection),
            MarketBatchItem(action: .clearNote, title: "清除备注",
                           icon: "trash", enabled: hasSelection),
            MarketBatchItem(action: .setAlert, title: "设置预警",
                           icon: "bell", enabled: hasSelection && hasAccount,
                           reason: hasAccount ? nil : "请先在模拟页创建账户"),
            MarketBatchItem(action: .cancelAlert, title: "取消预警",
                           icon: "bell.slash", enabled: hasSelection),
            // 全选是「从无到有」的入口：批量条只在有行时才渲染，故恒可用；已全选时再点为幂等 no-op
            MarketBatchItem(action: .selectAll, title: "全选",
                           icon: "checkmark.circle", enabled: true),
            MarketBatchItem(action: .deselectAll, title: "取消全选",
                           icon: "circle", enabled: hasSelection)
        ]
    }

    /// 执行批量动作（动作完成后清空选择并保持批量态；单个标的失败只记日志、继续处理其余标的）
    func performBatch(_ action: MarketBatchAction) {
        switch action {
        case .selectAll:
            setBatchSelection(Set(displayRows.map(\.metaID)))
        case .deselectAll:
            setBatchSelection([])

        case .addFavorite:
            // ⚠️ toggleFavorite 是纯 toggle：裸调会把「已自选」的反向删掉，故必须先判方向
            for meta in batchSelectedMetas() where !fav.isFavorited(meta.id) {
                fav.toggleFavorite(meta.id)
            }
            finishBatch()

        case .removeFavorite:
            for meta in batchSelectedMetas() where fav.isFavorited(meta.id) {
                fav.toggleFavorite(meta.id)
            }
            finishBatch()

        case .pin:
            setBatchPinned(true)
        case .unpin:
            setBatchPinned(false)

        case .setNote:
            batchNoteTarget = BatchNoteTarget(metas: batchSelectedMetas())

        case .clearNote:
            for meta in batchSelectedMetas() { fav.setNote(metaID: meta.id, text: "") }
            finishBatch()

        case .setAlert:
            // 批量预警复用既有预警弹窗载体（1 只与 N 只同一套创建路径）
            alertSheetTargets = batchSelectedMetas()

        case .cancelAlert:
            for meta in batchSelectedMetas() { Task { await FavoritesAlertKit.cancelAlerts(metaID: meta.id) } }
            finishBatch()
        }
    }

    /// 批量固顶 / 取消固顶：按列表当前显示顺序逐个执行（Set 无序，不能按点击顺序）；
    /// 用 `isPinned` 先判方向，保证「固顶」不会把已固顶项反向取消（反之亦然）
    private func setBatchPinned(_ pinned: Bool) {
        let selected = batchSelection
        for row in displayRows where selected.contains(row.metaID) {
            if fav.isPinned(row.metaID) != pinned {
                if pinned { fav.pin(row.metaID) } else { fav.unpin(row.metaID) }
            }
        }
        finishBatch()
    }

    /// 批量备注落库（弹窗「保存」传文本；「清空」传空串 = 删除 key）
    func applyBatchNote(_ text: String) {
        let metas = batchNoteTarget?.metas ?? []
        for meta in metas { fav.setNote(metaID: meta.id, text: text) }
        finishBatch()
    }

    /// 批量动作收尾：只清空选择、保持批量态（用户可继续下一轮选择）
    func finishBatch() {
        setBatchSelection([])
    }
}

// MARK: - 行情页批量动作

/// 行情页批量动作（与自选页的 `FavoritesBatchAction` 是两套：行情页无分组上下文，
/// 故不含「移出 / 移到分组」；固顶走行情页的全局固顶 API）
enum MarketBatchAction: String, Identifiable {
    case addFavorite
    case removeFavorite
    case pin
    case unpin
    case setNote
    case clearNote
    case setAlert
    case cancelAlert
    case selectAll
    case deselectAll

    var id: String { rawValue }
}

/// 批量条单项：动作 / 标题 / 图标 / 是否可用 / 不可用原因（不可用原因在条上统一显示一行）
struct MarketBatchItem: Identifiable {
    let action: MarketBatchAction
    let title: String
    let icon: String
    var enabled: Bool = true
    var reason: String? = nil

    var id: String { action.rawValue }
}


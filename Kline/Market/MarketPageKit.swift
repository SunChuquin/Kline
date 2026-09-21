//
//  MarketPageKit.swift
//  Kline
//
//  行情页共享骨架：按布局分发的容器（MarketView）与 A/B/C/D 四档布局共用的
//  页面状态模型 MarketPageModel、顶部一级菜单 / 二级胶囊、表格主体、行长按菜单与浮层。
//  枚举 TopField / PickerField / FavField / MarketTab 仍定义在 MarketView.swift 顶部。
//

import SwiftUI
import Combine
import UIKit

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
        // 1) 分置顶 / 非置顶
        let favedMetas = metas.filter { fav.isFavorited($0.id) }
        let othersMetas = metas.filter { !fav.isFavorited($0.id) }

        // 2) **先**触发带优先级的预取（置顶先查，非置顶随后）。
        //    这一步会在 inFlight 中为置顶标先占位，保证它们进入高优先级队列。
        if !favedMetas.isEmpty || !othersMetas.isEmpty {
            rowCache.prefetchPrioritized(high: favedMetas, low: othersMetas)
        }

        // 3) 注册所有行的壳（prefetch:false，不触发低优预取抢占 inFlight）
        for m in metas { _ = rowCache.row(for: m, prefetch: false) }

        // 4) 按排序规则取快照写入 displayRows
        let faved = favedMetas.compactMap { rowCache.rows[$0.id] }
        let others = othersMetas.compactMap { rowCache.rows[$0.id] }
        let list: [MarketRow]
        if let rule = colCfg.sortRule(for: .marketBoard) {
            list = faved.sorted(by: rule) + others.sorted(by: rule)
        } else {
            list = faved + others
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
}

// MARK: - 顶部一级菜单栏（含二级胶囊栏）

/// 一级菜单（市场 / 选股 / 自选）+ 左侧设置/边线调整按钮 + 右侧公式入口与搜索按钮，
/// 下方按需展开二级胶囊栏。A/B/C/D 四档共用。
struct MarketHeaderBar: View {
    @ObservedObject var model: MarketPageModel

    var body: some View {
        VStack(spacing: 0) {
            // 一级菜单（居中 Tab）+ 搜索/设置（靠右）
            ZStack(alignment: .center) {
                HStack(spacing: 22) {
                    ForEach(TopField.allCases) { field in
                        Button(action: { model.tapTopMenu(field) }) {
                            HStack(spacing: 3) {
                                Text(field.rawValue)
                                    .font(.system(size: 20, weight: model.topMenu == field ? .bold : .regular))
                                    .foregroundColor(model.topMenu == field ? .red : .primary)
                                // 仅选中项显示「上下箭头」图标（未选中只显示文字）
                                if model.topMenu == field {
                                    menuChevronIcon
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("market.topMenu.\(field.rawValue)")
                    }
                }
                .frame(maxWidth: .infinity)

                // 左侧：行情设置按钮（贴左，居中 Tab 两侧留白）
                HStack {
                    // 行情设置按钮：默认打开「行情表设置」面板；
                    // 从设置面板点「单元格宽度调整」后，切换为「带方框的❌」
                    // 图标，保持宽度调整模式（左右拖动列分隔线调整列宽），
                    // 再点一次退出该模式并恢复为设置按钮
                    Button {
                        if model.edgeAdjust {
                            withAnimation(.easeInOut(duration: 0.15)) { model.edgeAdjust = false }
                        } else {
                            model.showColumnPanel = true
                        }
                    } label: {
                        Image(systemName: model.edgeAdjust ? "xmark.square" : "slider.horizontal.3")
                            .foregroundColor(model.edgeAdjust ? .blue : .secondary)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .help(model.edgeAdjust ? "退出单元格宽度调整" : "行情表设置（表头/冻结/宽度调整）")
                    Spacer()
                }
                .padding(.leading, 12)

                // 右侧：公式入口（仅「选股」Tab 显示）+ 搜索按钮（保持最右不动）
                HStack(spacing: 0) {
                    Spacer()
                    // 公式入口：只在「选股」Tab 显示（市场 / 自选页工具区不出现），
                    // 点击打开公式管理中心并定位到「选股指标」段；
                    // 44×44 命中区放在 label 内层（不裁剪），外层仍收成 28×28，
                    // 保证工具栏行高与相邻的搜索 / 设置按钮完全一致、不被撑高
                    if model.topMenu == .picker {
                        Button { model.showFormulaCenter = true } label: {
                            Image(systemName: "function")
                                .foregroundColor(.secondary)
                                .font(.system(size: 16))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: 28, height: 28)
                        .help("公式管理（选股公式）")
                    }
                    Button { model.homeSearchActive = true } label: {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary).font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .help("搜索标的")
                }
                .padding(.trailing, 12)
            }
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))

            // 二级胶囊（根据一级切换）：默认隐藏，展开/收起带动画
            if model.secondLevelVisible {
                MarketSecondLevelBar(model: model)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color(.systemBackground))
        .clipped()
    }

    /// 「上下箭头」状态图标：两个无线条箭头（^ / 倒置^）垂直排列；
    /// 二级菜单展开时高亮下方箭头，折叠时高亮上方箭头。
    private var menuChevronIcon: some View {
        VStack(spacing: -3) {
            Image(systemName: "chevron.up")
                .font(.system(size: 9, weight: .heavy))
                .foregroundColor(model.secondLevelVisible ? Color.secondary.opacity(0.45) : .red)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .heavy))
                .foregroundColor(model.secondLevelVisible ? .red : Color.secondary.opacity(0.45))
        }
        .padding(.leading, 1)
        .accessibilityHidden(true)
    }
}

// MARK: - 二级胶囊栏

/// 二级胶囊栏：一级=市场→主板/ETF指数；选股→趋势/震荡/反转/情绪；自选→持仓/股池
struct MarketSecondLevelBar: View {
    @ObservedObject var model: MarketPageModel

    var body: some View {
        HStack(spacing: 0) {
            switch model.topMenu {
            case .market:
                ForEach(MarketTab.allCases) { s in
                    Button(action: {
                        model.selectedTab = s
                        model.scheduleRefresh()
                    }) {
                        capsule(text: s.rawValue, selected: model.selectedTab == s)
                    }
                    .buttonStyle(.plain)
                }
            case .picker:
                ForEach(PickerField.allCases) { s in
                    capsule(text: s.rawValue, selected: model.pickerSeg == s)
                        .onTapGesture { model.pickerSeg = s }
                }
            case .fav:
                ForEach(FavField.allCases) { s in
                    capsule(text: s.rawValue, selected: model.favSeg == s)
                        .onTapGesture { model.favSeg = s }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(Color(.systemGray6).opacity(0.4))
    }

    /// 单个胶囊：选中红色加粗 + 淡红底
    private func capsule(text: String, selected: Bool) -> some View {
        Text(text)
            .font(.system(size: 18, weight: selected ? .bold : .regular))
            .foregroundColor(selected ? .red : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(selected ? Color.red.opacity(0.08) : Color.clear)
            .cornerRadius(14)
    }
}

// MARK: - 工具条（B / D 档共用）

/// 工作区工具条按钮组：表头设置 / 边线调整 / 搜索（「选股」一级额外给公式入口）。
/// 视觉为小胶囊（28pt 高），命中区撑到 44pt 高。
struct MarketToolBar: View {
    @ObservedObject var model: MarketPageModel

    var body: some View {
        HStack(spacing: 8) {
            MarketToolButton(icon: "slider.horizontal.3", title: "表头设置") {
                model.showColumnPanel = true
            }
            MarketToolButton(icon: "arrow.left.and.right.square", title: "边线调整") {
                model.edgeAdjust.toggle()
            }
            MarketToolButton(icon: "magnifyingglass", title: "搜索") {
                model.homeSearchActive = true
            }
            if model.topMenu == .picker {
                MarketToolButton(icon: "function", title: "公式") {
                    model.showFormulaCenter = true
                }
            }
        }
    }
}

/// 工具条单个按钮：图标 + 文案（蓝色小胶囊），外层 44pt 命中区
struct MarketToolButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color(.systemGray6))
            .cornerRadius(7)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: - 表格主体（吸顶表头 + 数据行 + 横向滚动 + 边线覆盖层 + 下拉刷新）

/// 表格主体：A/B/C/D 四档共用，行高与字号由 `metrics` 参数化
/// （透传给 `MarketTableRow` 的 `heightOverride` / `fontSizeOverride`，紧凑档才真正压进行内）。
struct MarketTableBody: View {
    @ObservedObject var model: MarketPageModel
    var metrics: MarketRowMetrics = .regular

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                // 表头（吸顶，冻结前 N 列）
                MarketTableRow(page: .marketBoard, mode: .header, config: model.colCfg, rowCache: model.rowCache,
                               frozenCount: model.frozenCount, xOffset: model.hScrollOffset,
                               heightOverride: headerHeightOverride, fontSizeOverride: fontSizeOverride)
                    .background(Color(.systemBackground))
                // 列表：外层垂直 ScrollView 保留上下滚动/懒加载；
                // 横向用手势驱动 hScrollOffset（冻结前 N 列不动，其余列平移）
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.displayRows) { row in
                            rowCard(row: row)
                            Divider()
                        }
                    }
                }
                .simultaneousGesture(model.edgeAdjust ? nil : model.horizontalDragGesture)
                .refreshable {
                    // 重新拉 meta + 刷新 rows（触发重新计算字段值）
                    model.rowCache.refresh(metas: model.tabItems)
                    model.scheduleRefresh()
                }
            }

            // 边线调节覆盖层：开启时才叠加可拖分隔线
            if model.edgeAdjust {
                ColumnResizeOverlay(
                    cols: MarketTableRow.renderedColumns(for: .marketBoard, config: model.colCfg),
                    frozenCount: model.frozenCount,
                    xOffset: model.hScrollOffset,
                    onResize: { col, width in model.onResizeColumn(col, width) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    /// 行高 / 字号覆盖值：`.regular` 时统一传 nil → 行内取值与改动前逐值一致
    /// （高度 38 / 45 虽相等，但副字号 18×0.72=12.96 与既有 13 有亚像素差，故整组一起走 nil）
    private var headerHeightOverride: CGFloat? { metrics == .regular ? nil : metrics.headerHeight }
    private var rowHeightOverride: CGFloat? { metrics == .regular ? nil : metrics.rowHeight }
    private var fontSizeOverride: CGFloat? { metrics == .regular ? nil : metrics.fontSize }

    private func rowCard(row: MarketRow) -> some View {
        let meta = row.meta
        let isFaved = model.fav.isFavorited(meta.id)
        return HStack(spacing: 0) {
            // 整行单元格（冻结前 N 列 + 滚动列）；自选高亮由 MarketTableRow.isFaved 呈现
            MarketTableRow(page: .marketBoard, mode: .data(meta: meta), config: model.colCfg, rowCache: model.rowCache,
                           onOpen: { meta in
                // 预取当前 Tab 全部 rows，便于详情页左右切换时 tile 直接命中缓存
                let ctx = model.displayRows.map { $0.meta }
                DetailRouter.shared.open(meta, in: ctx)
            }, frozenCount: model.frozenCount, xOffset: model.hScrollOffset, isFaved: isFaved,
               heightOverride: rowHeightOverride, fontSizeOverride: fontSizeOverride)
        }
        .padding(.trailing, 8)
        .accessibilityIdentifier("market.rowCard")
        // 长按弹菜单：加自选 / 取消自选 / 加入指定分组
        .contextMenu {
            marketRowMenuContent(model: model, meta: meta, isFaved: isFaved)
        }
    }
}

// MARK: - 数据行长按菜单（A / C 档复用）

/// 数据行长按菜单内容（A / C 档复用）：加自选 / 取消自选 / 加入指定分组。
///
/// 以 `@ViewBuilder` 函数形式提供，调用处直接内联在 `.contextMenu { }` 里 ——
/// 与改造前的内联写法在 SwiftUI 菜单构建上完全等价（不引入自定义 View 包裹菜单项的歧义）。
@ViewBuilder
func marketRowMenuContent(model: MarketPageModel, meta: MetaItem, isFaved: Bool) -> some View {
    Button(action: { model.fav.toggleFavorite(meta.id) }) {
        Label(isFaved ? "取消自选" : "加自选", systemImage: isFaved ? "star.slash" : "star")
    }
    Button(action: { model.addGroupTarget = meta }) {
        Label("加入指定分组", systemImage: "folder.badge.plus")
    }
}

// MARK: - 浮层（设置面板 / 加分组 / 搜索页 / 公式中心）

/// 行情页四个浮层：挂在容器层，四档布局共用。
/// - 行情表设置面板 sheet（回调进入列宽调整模式）
/// - 加入分组 sheet
/// - 搜索页 overlay（复用 HomeView 搜索模式）
/// - 公式管理中心 overlay
struct MarketSheets: ViewModifier {
    @ObservedObject var model: MarketPageModel

    func body(content: Content) -> some View {
        content
            // 点击顶部搜索图标：弹出与「双击首页」完全一致的搜索页面——
            // 直接复用 HomeView 的搜索模式（返回按钮+搜索框+SearchPageView），
            // 不新建任何搜索实现；isSearching=true 时 HomeView 即呈现搜索界面，
            // 点返回按钮写回 false → 覆盖层关闭、回到行情页
            .overlay {
                if model.homeSearchActive {
                    // selectedTab 传入常量 2（行情页）：本覆盖层只是搜索界面，不改底部 Tab 选中态
                    HomeView(isSearching: $model.homeSearchActive, isProfilePresented: .constant(false),
                             selectedTab: .constant(2))
                        .transition(.opacity)
                }
                // 公式管理中心：全屏页面（铺满，无遮罩），关闭走页内「返回」；
                // 挂在页面根视图的 overlay 上，避免被表格 ScrollView 裁剪
                if model.showFormulaCenter {
                    ZStack {
                        FormulaCenterView(initialKind: .picker, onClose: { model.showFormulaCenter = false })
                    }
                    .transition(.opacity)
                    .zIndex(1000)
                }
            }
            .sheet(isPresented: $model.showColumnPanel) {
                MarketColumnConfigPanel(page: .marketBoard, configStore: model.colCfg) {
                    // 点击「单元格宽度调整」：面板关闭后进入宽度调整模式
                    withAnimation(.easeInOut(duration: 0.15)) { model.edgeAdjust = true }
                }
            }
            .sheet(item: Binding(
                get: { model.addGroupTarget.map(IdentifiableMeta.init) },
                set: { model.addGroupTarget = $0?.meta }
            )) { wrap in
                AddToGroupSheet(meta: wrap.meta, fav: model.fav)
            }
    }
}

extension View {
    /// 挂载行情页四个浮层（四档布局共用）
    func marketSheets(model: MarketPageModel) -> some View {
        modifier(MarketSheets(model: model))
    }
}

// MARK: - AddToGroupSheet 的 Binding(item:) 需要 Identifiable 包装 MetaItem

private struct IdentifiableMeta: Identifiable {
    let meta: MetaItem
    var id: Int { meta.id }
}

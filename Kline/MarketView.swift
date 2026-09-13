//
//  MarketView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/23.
//  2026/09/01 重构为通达信式表单（可配置字段 + 自定义排序 + 表头显隐 + 加自选）
//

import SwiftUI
import Combine

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
    case mainBoard = "主板"
    case etfIndex = "ETF指数"
    var id: String { rawValue }
}

struct MarketView: View {
    @ObservedObject private var databaseManager = DatabaseManager.shared
    @ObservedObject private var fav = FavoritesStore.shared
    @ObservedObject private var rowCache = MarketRowCache.shared
    @ObservedObject private var colCfg = MarketConfigStore.shared
    @ObservedObject private var detailRouter = DetailRouter.shared

    @State private var selectedTab: MarketTab = .mainBoard
    @State private var showColumnPanel = false
    @State private var addGroupTarget: MetaItem? = nil
    /// 点击顶部搜索图标后弹出搜索页（复用 HomeView 搜索模式，等同双击首页的效果）
    @State private var homeSearchActive = false
    /// 有字段筛选生效时，合并 bars 陆续到位触发的重筛选（防抖，避免每行刷全表）
    @State private var filterDebounce: DispatchWorkItem? = nil

    // 顶部一级/二级菜单（参考测试页2 居中 Tab + 分段胶囊样式）
    @State private var topMenu: TopField = .market
    // 市场 → 二级：主板/ETF指数（即 MarketTab）
    @State private var pickerSeg: PickerField = .trend
    @State private var favSeg: FavField = .holdings

    // === 整表横向滚动（冻结前 3 列）===
    @State private var hScrollOffset: CGFloat = 0
    @State private var hDragStart: CGFloat = 0
    @State private var panAxisIsH: Bool? = nil

    /// 「边」边线调节模式：开启后表头/数据行列边界显示可拖分隔线，左右拖动调整列宽并持久化
    @State private var edgeAdjust = false

    /// **渲染用的行快照**：由 `scheduleRefresh()` 写入，避免在计算属性里做预取副作用（否则会死循环触发重绘）。
    @State private var displayRows: [MarketRow] = []

    /// 当前「市场」二级分类对应的 meta.type 取值集合
    /// （ETF指数 合并展示原「指数」+「ETF」两类内容）
    private var currentTypes: [String] {
        switch selectedTab {
        case .mainBoard: return ["沪深主板"]
        case .etfIndex: return ["沪深京指数", "扩展行情指数"]
        }
    }

    /// 当前「市场」二级分类下的全部标的（搜索已改为独立搜索页，不在此就地过滤）
    private var tabItems: [MetaItem] {
        databaseManager.metaList.filter { currentTypes.contains($0.type) }
    }

    /// 表格冻结列数（「行情表设置」面板可配置：第 1 列恒冻结，第 2/3 列可开关；范围 1~3）
    private var frozenCount: Int {
        colCfg.frozenCount(for: .marketBoard)
    }

    /// 当前排序字段（无排序时为 nil）
    private var currentSortField: MarketField? {
        colCfg.sortRule(for: .marketBoard)?.field
    }

    /// 当前页面是否有任一字段筛选生效（决定 bars 到位后是否防抖重刷）
    private var hasActiveFilters: Bool {
        !colCfg.activeFilters(for: .marketBoard).isEmpty
    }

    /// 字段筛选配置的 Equatable 快照（供 onChange 检测「表头设置」里筛选变化）
    private var filterConfigKey: [String] {
        colCfg.config(for: .marketBoard).columns
            .filter { !$0.filterLabels.isEmpty }
            .map { "\($0.field.rawValue)=\($0.filterLabels.sorted().joined(separator: "|"))" }
    }

    /// 一次性：分置顶/非置顶 → 置顶优先预取 → 注册壳 → 排序 → 写入 displayRows。
    /// **仅在输入变化时调用**（tab/搜索/加载完毕/收藏变化/排序规则变化），不在计算属性里调用。
    private func scheduleRefresh() {
        guard databaseManager.isLoaded else {
            displayRows = []
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
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            if databaseManager.isLoaded {
                if tabItems.isEmpty {
                    MarketEmptyStateView(icon: "magnifyingglass", message: "暂无标的")
                } else {
                    // 表头（吸顶，冻结前 3 列）+ 列表（横向手势滚动 / 边线调节覆盖层）
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            MarketTableRow(page: .marketBoard, mode: .header, config: colCfg, rowCache: rowCache,
                                           frozenCount: frozenCount, xOffset: hScrollOffset)
                            .background(Color(.systemBackground))
                            // 列表：外层垂直 ScrollView 保留上下滚动/懒加载；
                            // 横向用手势驱动 hScrollOffset（冻结前3列不动，其余列平移）
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(displayRows) { row in
                                        rowCard(row: row)
                                        Divider()
                                    }
                                }
                            }
                            .simultaneousGesture(edgeAdjust ? nil : horizontalDragGesture)
                            .refreshable {
                                // 重新拉 meta + 刷新 rows（触发重新计算字段值）
                                rowCache.refresh(metas: tabItems)
                                scheduleRefresh()
                            }
                        }

                        // 边线调节覆盖层：开启时才叠加可拖分隔线
                        if edgeAdjust {
                            ColumnResizeOverlay(
                                cols: MarketTableRow.renderedColumns(for: .marketBoard, config: colCfg),
                                frozenCount: frozenCount,
                                xOffset: hScrollOffset,
                                onResize: onResizeColumn
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                }
            } else {
                loadingView
            }
        }
        // 点击顶部搜索图标：弹出与「双击首页」完全一致的搜索页面——
        // 直接复用 HomeView 的搜索模式（返回按钮+搜索框+SearchPageView），
        // 不新建任何搜索实现；isSearching=true 时 HomeView 即呈现搜索界面，
        // 点返回按钮写回 false → 覆盖层关闭、回到行情页
        .overlay {
            if homeSearchActive {
                HomeView(isSearching: $homeSearchActive, isProfilePresented: .constant(false))
                    .transition(.opacity)
            }
        }
        // 异形屏横屏贴边已由 ContentView 根布局统一处理，此处仅实测宿主宽度
        // （贴边后的真实可视宽），供 maxHOffset 计算横向滚动上限
        .marketTableHostWidth(to: $tableVisibleWidth)
        // 键盘避让已由 ContentView 根部全局禁用，此处无需重复处理
        .onAppear { scheduleRefresh() }
        // 切 Tab / 数据库加载完毕
        .onChange(of: selectedTab) { _ in scheduleRefresh() }
        .onChange(of: databaseManager.isLoaded) { _ in scheduleRefresh() }
        // 收藏变化（加 / 删自选会触发置顶分组）
        .onReceive(fav.objectWillChange) { _ in scheduleRefresh() }
        // 排序规则变化
        .onChange(of: colCfg.visibleColumns(for: .marketBoard)) { _ in scheduleRefresh() }
        .onChange(of: colCfg.sortRule(for: .marketBoard)) { _ in
            scheduleRefresh()
        }
        // 字段筛选变化（「表头设置」面板里调整筛选后）
        .onChange(of: filterConfigKey) { _ in scheduleRefresh() }
        // **关键**：每只标的的 bars 从后台到达后，rowCache 会 objectWillChange。
        // 由于 displayRows 里存的是 MarketRow（class，引用不变），如果不主动做一次 copy，
        // SwiftUI 会认为 displayRows 没变，ForEach 不会重算行内部的 Text → 一直显示 "-"。
        // 这里做一次轻量 copy，保证行内 Text 重算。
        .onReceive(rowCache.objectWillChange) { _ in
            // 已展示行的数值先做轻量 copy 立即刷新
            displayRows = displayRows
            // 有字段筛选时，把「值刚到、此前被排除」的行加回：防抖 250ms 合并，避免每行刷全表
            if hasActiveFilters {
                filterDebounce?.cancel()
                let item = DispatchWorkItem { scheduleRefresh() }
                filterDebounce = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
            }
        }
        .sheet(isPresented: $showColumnPanel) {
            MarketColumnConfigPanel(page: .marketBoard, configStore: colCfg) {
                // 点击「单元格宽度调整」：面板关闭后进入宽度调整模式
                withAnimation(.easeInOut(duration: 0.15)) { edgeAdjust = true }
            }
        }
        .sheet(item: Binding(
            get: { addGroupTarget.map(IdentifiableMeta.init) },
            set: { addGroupTarget = $0?.meta }
        )) { wrap in
            AddToGroupSheet(meta: wrap.meta, fav: fav)
        }
    }

    // MARK: - 顶部栏（一级菜单 + 二级胶囊 + 搜索/设置，参考测试页2）

    private var headerView: some View {
        VStack(spacing: 0) {
            // 一级菜单（居中 Tab）+ 搜索/设置（靠右）—— 参考测试页2 topBrandBar
            ZStack(alignment: .center) {
                HStack(spacing: 22) {
                    ForEach(TopField.allCases) { field in
                        Button(action: {
                            topMenu = field
                            scheduleRefresh()
                        }) {
                            Text(field.rawValue)
                                .font(.system(size: 20, weight: topMenu == field ? .bold : .regular))
                                .foregroundColor(topMenu == field ? .red : .primary)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
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
                        if edgeAdjust {
                            withAnimation(.easeInOut(duration: 0.15)) { edgeAdjust = false }
                        } else {
                            showColumnPanel = true
                        }
                    } label: {
                        Image(systemName: edgeAdjust ? "xmark.square" : "slider.horizontal.3")
                            .foregroundColor(edgeAdjust ? .blue : .secondary)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .help(edgeAdjust ? "退出单元格宽度调整" : "行情表设置（表头/冻结/宽度调整）")
                    Spacer()
                }
                .padding(.leading, 12)

                // 右侧：搜索按钮（保持最右不动）
                HStack {
                    Spacer()
                    Button { homeSearchActive = true } label: {
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

            // 二级胶囊（根据一级切换）
            secondLevelBar
        }
        .background(Color(.systemBackground))
    }

    /// 二级胶囊栏：一级=市场→主板/ETF指数；选股→趋势/震荡/反转/情绪；自选→持仓/股池
    private var secondLevelBar: some View {
        HStack(spacing: 0) {
            switch topMenu {
            case .market:
                ForEach(MarketTab.allCases) { s in
                    Button(action: { selectedTab = s; scheduleRefresh() }) {
                        Text(s.rawValue)
                            .font(.system(size: 18, weight: selectedTab == s ? .bold : .regular))
                            .foregroundColor(selectedTab == s ? .red : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(selectedTab == s ? Color.red.opacity(0.08) : Color.clear)
                            .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                }
            case .picker:
                ForEach(PickerField.allCases) { s in
                    Text(s.rawValue)
                        .font(.system(size: 18, weight: pickerSeg == s ? .bold : .regular))
                        .foregroundColor(pickerSeg == s ? .red : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(pickerSeg == s ? Color.red.opacity(0.08) : Color.clear)
                        .cornerRadius(14)
                        .onTapGesture { pickerSeg = s }
                }
            case .fav:
                ForEach(FavField.allCases) { s in
                    Text(s.rawValue)
                        .font(.system(size: 18, weight: favSeg == s ? .bold : .regular))
                        .foregroundColor(favSeg == s ? .red : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(favSeg == s ? Color.red.opacity(0.08) : Color.clear)
                        .cornerRadius(14)
                        .onTapGesture { favSeg = s }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(Color(.systemGray6).opacity(0.4))
    }

    /// 三级快捷筛选栏已移除：字段筛选改由「表头设置」面板按字段配置（可多字段同时筛选）。
    // MARK: - 行卡片（主组件）

    /// 表格宿主实测宽度（安全区内，异形屏横屏已扣除刘海侧 inset）
    @State private var tableVisibleWidth: CGFloat = 0

    /// 可视列里冻结前 3 列后，其余列的最大可左移量（整表横向滚动上限）
    private var maxHOffset: CGFloat {
        // 可视宽度用实测宿主宽（安全区内）；首帧未测量完成前退回 UIScreen 估算
        let visW = tableVisibleWidth > 0 ? tableVisibleWidth : UIScreen.main.bounds.width
        return max(0, MarketTableRow.scrollContentWidth(for: .marketBoard, config: colCfg, frozenCount: frozenCount)
             - visW)
    }

    /// 横向拖拽：侦测主轴向驱动 hScrollOffset（冻结列固定、其余列平移）；
    /// 用 simultaneousGesture 挂在外层垂直 ScrollView 上，上下滑动不受影响。
    private var horizontalDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                if panAxisIsH == nil {
                    panAxisIsH = abs(v.translation.width) > abs(v.translation.height)
                    if panAxisIsH == true { hDragStart = hScrollOffset }
                }
                if panAxisIsH == true {
                    hScrollOffset = min(0, max(-maxHOffset, hDragStart + v.translation.width))
                }
            }
            .onEnded { _ in
                if panAxisIsH == true {
                    hDragStart = hScrollOffset
                }
                panAxisIsH = nil
            }
    }

    private func rowCard(row: MarketRow) -> some View {
        let meta = row.meta
        let isFaved = fav.isFavorited(meta.id)
        return HStack(spacing: 0) {
            // 整行单元格（冻结前3列 + 滚动列）；自选高亮由 MarketTableRow.isFaved 呈现
            MarketTableRow(page: .marketBoard, mode: .data(meta: meta), config: colCfg, rowCache: rowCache,
                           onOpen: { meta in
                // 预取当前 Tab 全部 rows，便于详情页左右切换时 tile 直接命中缓存
                let ctx = displayRows.map { $0.meta }
                DetailRouter.shared.open(meta, in: ctx)
            }, frozenCount: frozenCount, xOffset: hScrollOffset, isFaved: isFaved)
        }
        .padding(.trailing, 8)
        .accessibilityIdentifier("market.rowCard")
        // 长按弹菜单：加自选 / 取消自选 / 加入指定分组
        .contextMenu {
            Button(action: { fav.toggleFavorite(meta.id) }) {
                Label(isFaved ? "取消自选" : "加自选", systemImage: isFaved ? "star.slash" : "star")
            }
            Button(action: { addGroupTarget = meta }) {
                Label("加入指定分组", systemImage: "folder.badge.plus")
            }
        }
    }

    // MARK: - 列宽（边线拖改）

    /// 拖动某列分隔线：把最新宽度写回该列对应字段的 widthOverride（持久化到沙盒 JSON）。
    /// 与默认宽一致时清空覆盖值，恢复可跟随默认宽联动。
    private func onResizeColumn(_ col: ColumnLayout, _ width: CGFloat) {
        let f = col.overrideField
        let override = MarketTableRow.shouldClearOverride(width, col: col) ? nil : width
        colCfg.setWidthOverride(f, width: override, page: .marketBoard)
        // 收窄可能导致滚动偏移越界：夹回有效范围
        if hScrollOffset < -maxHOffset { hScrollOffset = -maxHOffset }
    }

    // MARK: - 占位

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("加载中...")
                .foregroundColor(.gray)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - 列宽「边线」拖改覆盖层：开启时在每列右边界画一条可拖分隔线

private struct ColumnResizeOverlay: View {
    let cols: [ColumnLayout]
    let frozenCount: Int
    let xOffset: CGFloat
    /// 拖动某列右边界 → 以 (该列, 新宽度) 回调
    let onResize: (ColumnLayout, CGFloat) -> Void

    private static let lineW: CGFloat = 0.5

    /// 每个分隔线的锚点 x（屏幕坐标）
    private var dividerXs: [(x: CGFloat, col: ColumnLayout)] {
        let frozen = Array(cols.prefix(frozenCount))
        let scroll = Array(cols.dropFirst(frozenCount))
        var out: [(x: CGFloat, col: ColumnLayout)] = []
        var cum: CGFloat = Self.lineW
        for col in frozen {
            cum += col.width
            out.append((cum, col))
            cum += Self.lineW
        }
        let frozenW = cum
        var scum: CGFloat = 0
        for col in scroll {
            scum += col.width
            out.append((frozenW + scum + xOffset, col))
            scum += Self.lineW
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            ForEach(dividerXs, id: \.col.id) { d in
                ColumnResizeHandle(col: d.col, onResize: onResize)
                    .position(x: d.x, y: geo.size.height / 2)
            }
        }
        .clipped()
    }
}

private struct ColumnResizeHandle: View {
    let col: ColumnLayout
    let onResize: (ColumnLayout, CGFloat) -> Void
    /// 拖动起点时的列宽（避免拖动中宽度已更新导致的重复累加）
    @State private var startW: CGFloat? = nil

    private static let hitW: CGFloat = 16
    private static let minW: CGFloat = 48
    private static let maxW: CGFloat = 600

    var body: some View {
        Rectangle()
            .fill(Color.blue.opacity(0.85))
            .frame(width: 1.5)
            .frame(width: Self.hitW)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let s = startW ?? col.width
                        startW = s
                        onResize(col, min(Self.maxW, max(Self.minW, s + v.translation.width)))
                    }
                    .onEnded { _ in startW = nil }
            )
    }
}

// MARK: - AddToGroupSheet 的 Binding(item:) 需要 Identifiable 包装 MetaItem

private struct IdentifiableMeta: Identifiable {
    let meta: MetaItem
    var id: Int { meta.id }
}

#Preview {
    MarketView()
}

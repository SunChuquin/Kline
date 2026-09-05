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

/// 行情页「市场」二级分类（对应 tdx_parser.py 生成的 meta.type 三个取值）
enum MarketTab: String, CaseIterable, Identifiable {
    case mainBoard = "主板"
    case index = "指数"
    case etf = "ETF"
    var id: String { rawValue }
}

struct MarketView: View {
    @ObservedObject private var databaseManager = DatabaseManager.shared
    @ObservedObject private var fav = FavoritesStore.shared
    @ObservedObject private var rowCache = MarketRowCache.shared
    @ObservedObject private var colCfg = MarketConfigStore.shared
    @ObservedObject private var detailRouter = DetailRouter.shared

    @State private var searchText = ""
    @State private var searchResults: [MetaItem] = []
    @State private var showSearchField = false
    @FocusState private var isSearchFocused: Bool
    @State private var selectedTab: MarketTab = .mainBoard
    @State private var showColumnPanel = false
    @State private var addGroupTarget: MetaItem? = nil

    // 顶部一级/二级菜单（参考测试页2 居中 Tab + 分段胶囊样式）
    @State private var topMenu: TopField = .market
    // 市场 → 二级：主板/指数/ETF（即 MarketTab）
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

    /// 当前「市场」二级分类对应的 meta.type 值（主板/指数/ETF）
    private var currentType: String {
        switch selectedTab {
        case .mainBoard: return "沪深主板"
        case .index: return "沪深京指数"
        case .etf: return "扩展行情指数"
        }
    }

    /// 当前「市场」二级分类下的全部标的（搜索为空时展示此列表 + 排序）
    private var tabItems: [MetaItem] {
        databaseManager.metaList.filter { $0.type == currentType }
    }

    private var filteredItems: [MetaItem] {
        if searchText.isEmpty {
            return tabItems
        } else {
            // 搜索结果为全库匹配，再按当前 Tab 类型过滤
            return searchResults.filter { $0.type == currentType }
        }
    }

    /// 一次性：分置顶/非置顶 → 置顶优先预取 → 注册壳 → 排序 → 写入 displayRows。
    /// **仅在输入变化时调用**（tab/搜索/加载完毕/收藏变化/排序规则变化），不在计算属性里调用。
    private func scheduleRefresh() {
        guard databaseManager.isLoaded else {
            displayRows = []
            return
        }
        let metas = filteredItems
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
        // 只在差异大时赋值（减少 SwiftUI 触发）
        if list.map(\.id) != displayRows.map(\.id) {
            displayRows = list
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            if databaseManager.isLoaded {
                if filteredItems.isEmpty {
                    MarketEmptyStateView(icon: "magnifyingglass",
                                         message: searchText.isEmpty ? "暂无标的" : "没有找到相关股票")
                } else {
                    // 表头（吸顶，冻结前 3 列）+ 列表（横向手势滚动 / 边线调节覆盖层）
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            MarketTableRow(page: .marketBoard, mode: .header, config: colCfg, rowCache: rowCache,
                                           frozenCount: 3, xOffset: hScrollOffset)
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
                                frozenCount: 3,
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
        // 搜索展开时：覆盖其余区域拦截点击，点击外部即收起搜索框
        .overlay {
            if showSearchField {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        searchText = ""
                        showSearchField = false
                        isSearchFocused = false
                    }
            }
        }
        .onAppear { scheduleRefresh() }
        // 搜索
        .onChange(of: searchText) { newValue in
            if !newValue.isEmpty {
                databaseManager.searchMetaAsync(keyword: newValue) { results in
                    searchResults = results
                }
            } else {
                searchResults = []
            }
            scheduleRefresh()
        }
        // 搜索结果到位后重排
        .onChange(of: searchResults) { _ in scheduleRefresh() }
        // 切 Tab / 数据库加载完毕
        .onChange(of: selectedTab) { _ in scheduleRefresh() }
        .onChange(of: databaseManager.isLoaded) { _ in scheduleRefresh() }
        // 收藏变化（加 / 删自选会触发置顶分组）
        .onReceive(fav.objectWillChange) { _ in scheduleRefresh() }
        // 排序规则变化
        .onChange(of: colCfg.visibleColumns(for: .marketBoard)) { _ in scheduleRefresh() }
        // **关键**：每只标的的 bars 从后台到达后，rowCache 会 objectWillChange。
        // 由于 displayRows 里存的是 MarketRow（class，引用不变），如果不主动做一次 copy，
        // SwiftUI 会认为 displayRows 没变，ForEach 不会重算行内部的 Text → 一直显示 "-"。
        // 这里做一次轻量 copy，保证行内 Text 重算。
        .onReceive(rowCache.objectWillChange) { _ in
            displayRows = displayRows
        }
        .sheet(isPresented: $showColumnPanel) {
            MarketColumnConfigPanel(page: .marketBoard, configStore: colCfg)
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

                // 搜索 + 边线调节 + 表头设置 —— 贴右
                HStack(spacing: 6) {
                    // 边线调节按钮：开启后左右拖动列边界调整并持久化列宽
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { edgeAdjust.toggle() }
                    } label: {
                        Text("边")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(edgeAdjust ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 30, height: 30)
                    .help("开启后可左右拖动各列分隔线调整列宽")

                    // 表头设置按钮
                    Button { showColumnPanel = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(.secondary).font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .help("表头设置（字段显隐/排序/宽度）")

                    // 搜索栏（默认展开，始终显示，不折叠为图标）
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray).font(.system(size: 13))
                        TextField("搜索代码/名称", text: $searchText)
                            .textFieldStyle(.plain)
                            .focused($isSearchFocused)
                            .submitLabel(.search)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { isSearchFocused = false }
                    }
                    .padding(EdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 9))
                    .background(Color(.systemGray5))
                    .cornerRadius(10)
                    .frame(width: 150)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
            }
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))

            // 二级胶囊（根据一级切换）
            secondLevelBar
        }
        .background(Color(.systemBackground))
    }

    /// 二级胶囊栏：一级=市场→主板/指数/ETF；选股→趋势/震荡/反转/情绪；自选→持仓/股池
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

    // MARK: - 行卡片（主组件）

    /// 可视列里冻结前 3 列后，其余列的最大可左移量（整表横向滚动上限）
    private var maxHOffset: CGFloat {
        max(0, MarketTableRow.scrollContentWidth(for: .marketBoard, config: colCfg, frozenCount: 3)
             - UIScreen.main.bounds.width)
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
                isSearchFocused = false
                // 预取当前 Tab 全部 rows，便于详情页左右切换时 tile 直接命中缓存
                let ctx = displayRows.map { $0.meta }
                DetailRouter.shared.open(meta, in: ctx)
            }, frozenCount: 3, xOffset: hScrollOffset, isFaved: isFaved)
        }
        .padding(.trailing, 8)
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

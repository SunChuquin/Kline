//
//  MarketView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/23.
//  2026/09/01 重构为通达信式表单（可配置字段 + 自定义排序 + 表头显隐 + 加自选）
//

import SwiftUI
import Combine

/// 行情页顶部 Tab 分类（对应 tdx_parser.py 生成的 meta.type 三个取值）
enum MarketTab: String, CaseIterable, Identifiable {
    case mainBoard = "沪深主板"
    case index = "沪深京指数"
    case extIndex = "扩展指数"
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
    @FocusState private var isSearchFocused: Bool
    @State private var selectedTab: MarketTab = .mainBoard
    @State private var showColumnPanel = false
    @State private var addGroupTarget: MetaItem? = nil

    /// **渲染用的行快照**：由 `scheduleRefresh()` 写入，避免在计算属性里做预取副作用（否则会死循环触发重绘）。
    @State private var displayRows: [MarketRow] = []

    /// 当前 Tab 对应的 meta.type 值
    private var currentType: String {
        switch selectedTab {
        case .mainBoard: return "沪深主板"
        case .index: return "沪深京指数"
        case .extIndex: return "扩展行情指数"
        }
    }

    /// 当前 Tab 下的全部标的（搜索为空时展示此列表 + 排序）
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
                    // 表头（吸顶）
                    MarketTableRow(page: .marketBoard, mode: .header, config: colCfg, rowCache: rowCache)
                    // 列表：List 有分隔线和删除/移动支持；这里用 ScrollView+LazyVStack 更贴合通达信卡片观感
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(displayRows) { row in
                                rowCard(row: row)
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                    .refreshable {
                        // 重新拉 meta + 刷新 rows（触发重新计算字段值）
                        rowCache.refresh(metas: tabItems)
                        scheduleRefresh()
                    }
                }
            } else {
                loadingView
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

    // MARK: - 顶部栏（Tab + 搜索 + 快捷按钮）

    private var headerView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // 左侧 Tab 子标签
                HStack(spacing: 4) {
                    ForEach(MarketTab.allCases) { tab in
                        Button(action: {
                            selectedTab = tab
                            // 切 Tab：交给 onChange(selectedTab) 统一调度（置顶优先预取 + 行快照）
                            scheduleRefresh()
                        }) {
                            Text(tab.rawValue)
                                .font(.system(size: 14,
                                              weight: selectedTab == tab ? .bold : .regular))
                                .foregroundColor(selectedTab == tab ? .blue : .secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .overlay(alignment: .bottom) {
                                    if selectedTab == tab {
                                        Rectangle()
                                            .fill(Color.blue)
                                            .frame(height: 2)
                                            .padding(.horizontal, 9)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                // Tab 不抢占剩余空间，让给搜索栏
                .layoutPriority(1)

                Spacer(minLength: 4)

                // 表头设置按钮（靠右，在搜索栏左侧）
                Button { showColumnPanel = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.secondary).font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .help("表头设置（字段显隐/排序/宽度）")

                // 搜索栏：固定宽度（贴合提示文字长度），与按钮一起靠右对齐
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray).font(.system(size: 13))
                    TextField("搜索代码/名称", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(EdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 9))
                .background(Color(.systemGray5))
                .cornerRadius(10)
                .frame(width: 150)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // 行情概览小条（当前 Tab 的小指标：上涨/下跌/平盘/停牌个数）
            if databaseManager.isLoaded, !searchText.isEmpty {
                // 搜索态不显示概览
            } else if databaseManager.isLoaded {
                tabOverviewBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .background(Color(.systemBackground))
    }

    /// Tab 概览：统计当前 Tab 上涨/下跌/平盘数。
    /// **不触发预取**（否则会抢占置顶优先的 inFlight 占位，把所有标的塞到低优队尾）。
    private var tabOverviewBar: some View {
        let rows = rowCache.rows(for: tabItems, prefetch: false)
        var up = 0, down = 0, flat = 0, pending = 0
        for r in rows {
            guard let pct = r.number(.changePct) else {
                pending += 1; continue
            }
            if pct > 0 { up += 1 }
            else if pct < 0 { down += 1 }
            else { flat += 1 }
        }
        let total = up + down + flat
        func pill(_ label: String, _ count: Int, color: Color) -> some View {
            HStack(spacing: 3) {
                Text(label).font(.system(size: 11)).foregroundColor(.secondary)
                Text("\(count)").font(.system(size: 12, weight: .semibold)).foregroundColor(color)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color(.systemGray6))
            .cornerRadius(6)
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                pill("股票", total, color: .primary)
                pill("上涨", up, color: .red)
                pill("下跌", down, color: .green)
                pill("平盘", flat, color: .gray)
                if pending > 0 { pill("计算中", pending, color: .orange) }
            }
        }
    }

    // MARK: - 行卡片（主组件）

    private func rowCard(row: MarketRow) -> some View {
        // 左侧固定：加自选星标 + 表单列（后者内部 ScrollView 横向滚动）
        let meta = row.meta
        return HStack(spacing: 0) {
            // 星标按钮（加自选/取消）
            Button {
                fav.toggleFavorite(meta.id)
            } label: {
                Image(systemName: fav.isFavorited(meta.id) ? "star.fill" : "star")
                    .foregroundColor(fav.isFavorited(meta.id) ? .yellow : .gray)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 36)
            .contextMenu {
                Button(action: { addGroupTarget = meta }) {
                    Label("加入指定分组", systemImage: "folder.badge.plus")
                }
                if fav.isFavorited(meta.id) {
                    Button(role: .destructive, action: { fav.toggleFavorite(meta.id) }) {
                        Label("取消自选", systemImage: "star.slash")
                    }
                }
            }

            MarketTableRow(page: .marketBoard, mode: .data(meta: meta), config: colCfg, rowCache: rowCache) { meta in
                isSearchFocused = false
                // 预取当前 Tab 全部 rows，便于详情页左右切换时 tile 直接命中缓存
                let ctx = displayRows.map { $0.meta }
                DetailRouter.shared.open(meta, in: ctx)
            }
        }
        .padding(.trailing, 8)
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

// MARK: - AddToGroupSheet 的 Binding(item:) 需要 Identifiable 包装 MetaItem

private struct IdentifiableMeta: Identifiable {
    let meta: MetaItem
    var id: Int { meta.id }
}

#Preview {
    MarketView()
}

//
//  FavoritesPageKit.swift
//  Kline
//
//  自选页共享骨架：跨布局共享的页面状态模型 FavoritesPageModel 与子视图
//  （工具条 / 分组 Tab 条 / 表格主体 / 行长按菜单 / 手动组编辑列表 / 浮层）。
//  A 档（FavoritesLayoutAView）由它们组合而成；后续 B/C/D 三档复用同一套骨架。
//  写法与行情页 MarketPageKit.swift 同惯例：模型由容器 @StateObject 持有，
//  各布局视图与子视图以 @ObservedObject 消费。
//

import SwiftUI
import Combine
import UIKit

// MARK: - 页面状态模型（四档布局共用）

/// 自选页状态模型：分组 Tab / 当前分组标的 / 排序快照 / 浮层开关 / 横向滚动 / 公式刷新进度。
/// 由容器 `FavoritesView` 以 `@StateObject` 持有，各布局视图以 `@ObservedObject` 消费。
/// 数据源变化（自选分组 / 数据库加载 / 行缓存 / 列配置）由容器层的 @ObservedObject 触发重算，
/// 模型内只保留 UI 状态与派生数据（不在 body 里做全表重计算以外的副作用）。
@MainActor
final class FavoritesPageModel: ObservableObject {

    // MARK: 共享数据源（全部是既有单例，不新增数据源）
    let fav = FavoritesStore.shared
    let dbm = DatabaseManager.shared
    let rowCache = MarketRowCache.shared
    let colCfg = MarketConfigStore.shared
    let detailRouter = DetailRouter.shared

    // MARK: UI 状态（跨布局共享）
    @Published var showEditingMode: Bool = false
    @Published var hScrollOffset: CGFloat = 0
    @Published var tableVisibleWidth: CGFloat = 0
    @Published var refreshProgress: (groupID: UUID, done: Int, total: Int)? = nil
    @Published var showColumnPanel: Bool = false
    @Published var showManageSheet: Bool = false
    @Published var showAddSheet: Bool = false
    @Published var formulaEditorTarget: FavoritesGroup? = nil
    @Published var addGroupTarget: MetaItem? = nil

    // MARK: 内部（横向拖拽，不参与渲染，无需 Published）
    var hDragStart: CGFloat = 0
    var panAxisIsH: Bool? = nil

    // MARK: - 派生数据（与改造前 FavoritesView 的计算属性等价）

    /// Tab 列表（0 = "全部"虚拟分组，其后 = 各非隐藏真实分组）
    var tabs: [FavoritesGroup] {
        var out: [FavoritesGroup] = [fav.allGroup]
        out.append(contentsOf: fav.visibleGroups)
        return out
    }

    /// 表格冻结列数（「行情表设置」面板可配置：第 1 列恒冻结，第 2/3 列可开关；范围 1~3）
    var frozenCount: Int {
        colCfg.frozenCount(for: .favorites)
    }

    /// 当前选中分组（选中态失配时回退到首个 Tab）
    var currentGroup: FavoritesGroup {
        let gid = fav.selectedGroupID
        if let g = tabs.first(where: { $0.id == gid }) { return g }
        return tabs.first ?? fav.allGroup
    }

    /// 当前分组内的标的
    var currentItems: [MetaItem] {
        items(groupID: currentGroup.id)
    }

    /// 当前分组内的行（已按列配置排序规则排序）
    var sortedRows: [MarketRow] {
        sortedRows(groupID: currentGroup.id)
    }

    /// 可视列里冻结前 N 列后，其余列的最大可左移量（整表横向滚动上限）
    var maxHOffset: CGFloat {
        // 可视宽度用实测宿主宽（安全区内）；首帧未测量完成前退回 UIScreen 估算
        let visW = tableVisibleWidth > 0 ? tableVisibleWidth : UIScreen.main.bounds.width
        return max(0, MarketTableRow.scrollContentWidth(for: .favorites, config: colCfg, frozenCount: frozenCount)
             - visW)
    }

    /// 指定分组内的标的
    func items(groupID: UUID) -> [MetaItem] {
        fav.resolveMetaItems(groupID: groupID, allMeta: dbm.metaList)
    }

    /// 指定分组内的行（已按列配置排序规则排序）
    func sortedRows(groupID: UUID) -> [MarketRow] {
        let all = rowCache.rows(for: items(groupID: groupID))
        if let rule = colCfg.sortRule(for: .favorites) {
            return all.sorted(by: rule)
        }
        return all
    }

    func countOfGroup(_ g: FavoritesGroup) -> Int {
        items(groupID: g.id).count
    }

    // MARK: - 动作

    /// 预取所有分组内标的的行数据
    func prefetchAllGroups() {
        var all: Set<Int> = []
        for g in tabs {
            for m in items(groupID: g.id) {
                all.insert(m.id)
            }
        }
        let metas = dbm.metaList.filter { all.contains($0.id) }
        _ = rowCache.rows(for: metas)
    }

    /// 下拉刷新当前分组：公式分组走公式重算；手动分组走行缓存刷新
    func refreshCurrentGroup() {
        if currentGroup.kind == .formula {
            refreshFormulaGroup(id: currentGroup.id)
        } else {
            rowCache.refresh(metas: currentItems)
        }
    }

    /// 刷新公式分组（全市场跑公式，进度回写 refreshProgress）
    func refreshFormulaGroup(id: UUID) {
        guard let g = fav.groups.first(where: { $0.id == id }), g.kind == .formula else { return }
        setRefreshProgress(id, done: 0, total: 0)
        // 范围：全市场（用户量不大，这个 Demo 可以接受；后续按行业限制就是在此传入子集）
        let pool = dbm.metaList
        let total = pool.count
        setRefreshProgress(id, done: 0, total: total)
        fav.refreshFormulaGroup(id: id, candidates: pool, cache: rowCache,
                                progress: { [weak self] d, t in
                                    self?.setRefreshProgress(id, done: d, total: t)
                                },
                                completion: { [weak self] cnt in
                                    DebugLogger.shared.log("[Favorites] formulaGroup \(g.name) matches=\(cnt)/\(total)")
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        self?.clearRefreshProgress(groupID: id)
                                    }
                                })
    }

    /// 手动分组拖动排序后落盘。
    /// 与改造前 forceSaveOrder 等价：借助公开 API（rename 回同名）触发 saveToDisk。
    func saveManualOrder(groupID: UUID, orderedMetaIDs: [Int]) {
        guard let idx = fav.groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard fav.groups[idx].kind == .manual else { return }
        fav.groups[idx].manualMetaIDs = orderedMetaIDs
        fav.renameGroup(id: groupID, name: fav.groups[idx].name)
    }

    /// 横向拖拽：按主轴向驱动 hScrollOffset（冻结列固定、其余列平移）；
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
                    // 同值不写：避免拖动中每帧无谓地触发重绘
                    if self.hScrollOffset != next { self.hScrollOffset = next }
                }
            }
            .onEnded { _ in
                if self.panAxisIsH == true { self.hDragStart = self.hScrollOffset }
                self.panAxisIsH = nil
            }
    }

    // MARK: - 刷新进度回写（同值不写）

    func setRefreshProgress(_ groupID: UUID, done: Int, total: Int) {
        if let p = refreshProgress, p.groupID == groupID, p.done == done, p.total == total { return }
        refreshProgress = (groupID, done, total)
    }

    func clearRefreshProgress(groupID: UUID) {
        guard let p = refreshProgress, p.groupID == groupID else { return }
        refreshProgress = nil
    }
}

// MARK: - 顶部工具条（标题 + 右侧图标按钮组）

/// 标题「自选」+ 右侧图标按钮组（编辑模式 / 表头设置 / 分组管理 / 新建分组），
/// 选中公式分组时额外显示「刷新选股」与「选择公式 / 编辑公式」。A/B/C/D 四档共用。
struct FavoritesToolbar: View {
    @ObservedObject var model: FavoritesPageModel

    var body: some View {
        HStack(spacing: 4) {
            Text("自选")
                .font(.system(size: 18, weight: .bold))
                .accessibilityIdentifier("favorites.title")
                .padding(.leading, 16)
            Spacer()
            // 刷新公式分组（仅当选中 formula 分组）
            if model.currentGroup.kind == .formula {
                Button {
                    model.refreshFormulaGroup(id: model.currentGroup.id)
                } label: {
                    if let p = model.refreshProgress, p.groupID == model.currentGroup.id {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.8)
                            Text("\(p.done)/\(p.total)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    } else {
                        Label("刷新选股", systemImage: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.blue.opacity(0.08))
                            .foregroundColor(.blue)
                            .cornerRadius(8)
                    }
                }
                .buttonStyle(.plain)
                // 胶囊外观不变，只把命中区撑到 44 高
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            if model.currentGroup.kind == .formula {
                Button {
                    model.formulaEditorTarget = model.currentGroup
                } label: {
                    // 已引用公式显示「编辑公式」，未选择显示「选择公式」
                    Label(model.fav.formulaName(groupID: model.currentGroup.id) == nil ? "选择公式" : "编辑公式",
                          systemImage: "function")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            topIconButton(model.showEditingMode ? "line.3.horizontal.circle.fill" : "line.3.horizontal",
                          color: model.showEditingMode ? .blue : .secondary) {
                model.showEditingMode.toggle()
            }
            topIconButton("slider.horizontal.3") {
                model.showColumnPanel = true
            }
            topIconButton("folder") {
                model.showManageSheet = true
            }
            topIconButton("plus", size: 18, color: .blue) {
                model.showAddSheet = true
            }
            .padding(.trailing, 4)
        }
        .frame(height: 48)
        .background(Color(.systemBackground))
    }

    /// 顶部工具条图标按钮：统一 44x44 命中区。
    /// 纯图标按钮若不加 frame，可点范围只有字形大小（约 16x19），真机上很难点中。
    private func topIconButton(_ systemName: String, size: CGFloat = 16,
                               color: Color = .secondary,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .foregroundColor(color)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 分组 Tab 条（横向滚动，顶部分组切换）

/// 横向分组 Tab 条：图标 + 名称 + 数量，选中蓝字 + 底部蓝色 2pt 横线。A/B/C/D 四档共用。
struct FavoritesGroupTabs: View {
    @ObservedObject var model: FavoritesPageModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.tabs) { g in
                    let active = g.id == model.currentGroup.id
                    Button {
                        model.fav.selectedGroupID = g.id
                    } label: {
                        HStack(spacing: 4) {
                            if g.id == model.fav.allGroup.id {
                                Image(systemName: "tray.full.fill")
                                    .font(.system(size: 12))
                            } else {
                                Image(systemName: g.kind == .manual ? "folder.fill" : "function")
                                    .font(.system(size: 12))
                            }
                            Text(g.name)
                                .font(.system(size: 14, weight: active ? .bold : .regular))
                                .lineLimit(1)
                            Text(" \(model.countOfGroup(g))")
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .foregroundColor(active ? .blue : .secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        // 参考行情页 Tab：选中用底部蓝色横线高亮，不带胶囊背景
                        .overlay(alignment: .bottom) {
                            if active {
                                Rectangle()
                                    .fill(Color.blue)
                                    .frame(height: 2)
                                    .padding(.horizontal, 9)
                            }
                        }
                        // 命中区补充：Tab 本身只有约 31pt 高（真机很难点中），纵向补到约 44pt。
                        // 补的空间全部放在上方：让按钮底边与下划线齐平，下方不再是"看不见的 Tab 热区"，
                        // 否则点下方表头排序时会误触到 Tab
                        .padding(.top, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        // 与下方表头之间留出明确间隙（含表头排序热区），避免点表头时误触 Tab
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
    }
}

// MARK: - 表格主体（吸顶表头 + 数据行 + 冻结列横向滚动 + 下拉刷新 + 空态/加载态）

/// 表格主体：A/B/C/D 四档共用，行高与字号参数化。
///
/// ⚠️ `MarketTableRow` 内部行高与字号目前写死（表头 38 / 数据行 45 / 字号 18），本次不越界修改它，
/// 因此：
/// - `rowHeight` 作用在「数据行外层容器 frame」上：默认 45 与内部值相等 → 恒等变换，A 档渲染零变化；
/// - `fontSize` 通过环境字体（`\.font`）下发，只影响容器自己渲染的文字（表格内文字均为显式字号，
///   会被内层显式 `.font` 覆盖）→ A 档渲染零变化；后续紧凑档可据此统一收口。
/// D 档若要真正压缩行内行高 / 字号，需要给 `MarketTableRow` 增加可选 `rowHeight` / `fontSize` 参数。
struct FavoritesTableBody: View {
    @ObservedObject var model: FavoritesPageModel
    /// 数据行外层容器行高（A 档 45；D 档紧凑表 34）
    var rowHeight: CGFloat = 45
    /// 数据行外层字号（A 档 18；D 档紧凑表 15）
    var fontSize: CGFloat = 18

    var body: some View {
        if !model.dbm.isLoaded {
            loadingView
        } else if model.currentItems.isEmpty {
            if model.currentGroup.kind == .formula {
                formulaGroupEmptyState
            } else {
                MarketEmptyStateView(icon: "star.slash",
                                     message: model.currentGroup.name == "全部"
                                            ? "还没有自选股"
                                            : "此分组暂无股票",
                                     subtitle: "在行情页面长按股票行即可加自选，或点击右上角 + 新建分组")
            }
        } else {
            // 表头（吸顶，冻结前3列，横向跟随整表滚动）
            MarketTableRow(page: .favorites, mode: .header, config: model.colCfg, rowCache: model.rowCache,
                           frozenCount: model.frozenCount, xOffset: model.hScrollOffset)
            .background(Color(.systemBackground))
            listBody
        }
    }

    @ViewBuilder
    private var listBody: some View {
        if model.showEditingMode, model.currentGroup.kind == .manual {
            FavoritesManualEditingList(model: model)
        } else {
            standardList
        }
    }

    /// 标准只读/点击模式列表（共享表单渲染）
    private var standardList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.sortedRows) { row in
                    rowCard(row: row)
                    Divider().padding(.leading, 30)
                }
            }
            // 字号参数下发（行内文字均为显式字号，A 档渲染不变；供后续紧凑布局的容器文字使用）
            .environment(\.font, Font.system(size: fontSize))
        }
        .simultaneousGesture(model.horizontalDragGesture)
        .refreshable {
            model.refreshCurrentGroup()
        }
    }

    /// 行卡片（标准模式）
    private func rowCard(row: MarketRow) -> some View {
        let meta = row.meta
        // 与改造前一致：点击上下文取当前分组标的快照
        let items = model.currentItems
        return HStack(spacing: 0) {
            // 整行单元格（冻结前3列 + 滚动列）；自选页无需自选高亮，样式与行情页非自选行一致
            MarketTableRow(page: .favorites, mode: .data(meta: meta), config: model.colCfg, rowCache: model.rowCache,
                           onOpen: { m in
                model.detailRouter.open(m, in: items)
            }, frozenCount: model.frozenCount, xOffset: model.hScrollOffset, isFaved: false)
        }
        .padding(.trailing, 8)
        .frame(height: rowHeight)
        // 长按弹菜单：取消自选 / 加入其它分组 / 移动分组
        .contextMenu {
            favoritesRowMenuContent(model: model, meta: meta)
        }
    }

    private var formulaGroupEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "function")
                .font(.system(size: 46)).foregroundColor(.blue)
            Text(model.currentGroup.cachedMatches == nil
                 ? "尚未选股" : "暂无符合条件的股票")
                .font(.system(size: 15)).foregroundColor(.primary)
            Text(model.currentGroup.cachedMatches == nil
                 ? "点击右上角「刷新选股」即可按公式计算所有股票的最新一期信号"
                 : "可以修改公式阈值或再次刷新查看最新结果")
                .font(.system(size: 13)).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Button {
                model.refreshFormulaGroup(id: model.currentGroup.id)
            } label: {
                Label("立即刷新选股", systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.blue).foregroundColor(.white)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("自选页面准备中...").foregroundColor(.gray)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - 数据行长按菜单（A 档与后续 C 档复用）

/// 数据行长按菜单内容（A 档与后续 C 档复用）：取消自选 / 加入其它分组 / 移动到分组。
///
/// 以 `@ViewBuilder` 函数形式提供，调用处直接内联在 `.contextMenu { }` 里 ——
/// 与改造前的内联写法在 SwiftUI 菜单构建上完全等价（不引入自定义 View 包裹菜单项的歧义）。
@ViewBuilder
func favoritesRowMenuContent(model: FavoritesPageModel, meta: MetaItem) -> some View {
    Button(role: .destructive, action: { model.fav.toggleFavorite(meta.id) }) {
        Label("取消自选", systemImage: "star.slash")
    }
    Button(action: { model.addGroupTarget = meta }) {
        Label("加入其它分组", systemImage: "folder.badge.plus")
    }
    Menu(content: {
        let manualGroups = model.fav.groups.filter { $0.kind == .manual }
        ForEach(manualGroups) { g in
            Button(action: {
                if g.manualMetaIDs.contains(meta.id) {
                    model.fav.removeFromGroup(id: g.id, metaID: meta.id)
                } else {
                    model.fav.addToGroup(id: g.id, metaID: meta.id)
                }
            }) {
                let inIt = g.manualMetaIDs.contains(meta.id)
                Label(g.name, systemImage: inIt ? "checkmark" : "")
            }
        }
    }) { Label("移动到分组", systemImage: "arrow.up.arrow.down.circle") }
}

// MARK: - 手动分组编辑模式列表（List + onMove + editMode，后续 C 档复用）

/// 手动分组在编辑模式下的可拖动排序列表：拖动后顺序立即落盘。
struct FavoritesManualEditingList: View {
    @ObservedObject var model: FavoritesPageModel

    var body: some View {
        let gid = model.currentGroup.id
        let currentBinding = Binding<[MetaItem]>(
            get: { model.items(groupID: gid) },
            set: { newMetas in
                // 将手动组的 manualMetaIDs 替换为新的顺序并落盘
                model.saveManualOrder(groupID: gid, orderedMetaIDs: newMetas.map { $0.id })
            }
        )
        return List {
            ForEach(currentBinding) { $m in
                HStack(spacing: 0) {
                    let mm = $m.wrappedValue
                    // 自选页内容本身即自选结果，无需再用灰底/红字标记，样式与行情页非自选行一致
                    MarketTableRow(page: .favorites, mode: .data(meta: mm), config: model.colCfg, rowCache: model.rowCache,
                                   onOpen: { m in
                        model.detailRouter.open(m, in: model.items(groupID: gid))
                    }, frozenCount: model.frozenCount, xOffset: model.hScrollOffset, isFaved: false)
                    .contextMenu {
                        Button(role: .destructive) {
                            model.fav.removeFromGroup(id: gid, metaID: mm.id)
                        } label: {
                            Label("从该分组移除", systemImage: "trash")
                        }
                    }
                }
            }
            .onMove { from, to in
                var items = model.items(groupID: gid)
                items.move(fromOffsets: from, toOffset: to)
                model.saveManualOrder(groupID: gid, orderedMetaIDs: items.map { $0.id })
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))
    }
}

// MARK: - 浮层（列配置 / 管理分组 / 新建分组 / 公式编辑 / 加入分组）

/// 自选页 5 个呈现层：挂在容器层，四档布局共用。
/// - 行情表设置面板 sheet
/// - 管理分组 sheet
/// - 新建分组 sheet
/// - 公式分组编辑 sheet
/// - 加入分组 sheet
struct FavoritesSheets: ViewModifier {
    @ObservedObject var model: FavoritesPageModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.showColumnPanel) {
                MarketColumnConfigPanel(page: .favorites, configStore: model.colCfg)
            }
            .sheet(isPresented: $model.showManageSheet) {
                FavManageSheet(fav: model.fav)
            }
            .sheet(isPresented: $model.showAddSheet) {
                FavAddGroupSheet(fav: model.fav)
            }
            .sheet(item: Binding(
                get: { model.formulaEditorTarget.map(IdentifiableGroup.init) },
                set: { model.formulaEditorTarget = $0?.group }
            )) { wrap in
                FavFormulaEditorSheet(group: wrap.group, fav: model.fav)
            }
            .sheet(item: Binding(
                get: { model.addGroupTarget.map(FavIdentifiableMeta.init) },
                set: { model.addGroupTarget = $0?.meta }
            )) { wrap in
                AddToGroupSheet(meta: wrap.meta, fav: model.fav)
            }
    }
}

extension View {
    /// 挂载自选页 5 个浮层（四档布局共用）
    func favoritesSheets(model: FavoritesPageModel) -> some View {
        modifier(FavoritesSheets(model: model))
    }
}

//
//  FavoritesView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/23.
//  2026/09/01 重写为：持久自选 + 自定义分组 + 指标公式自动分组
//

import SwiftUI

// MARK: - 主页面

struct FavoritesView: View {
    @ObservedObject private var fav = FavoritesStore.shared
    @ObservedObject private var dbm = DatabaseManager.shared
    @ObservedObject private var rowCache = MarketRowCache.shared
    @ObservedObject private var colCfg = MarketConfigStore.shared
    @ObservedObject private var detailRouter = DetailRouter.shared

    @State private var showColumnPanel = false
    @State private var showManageSheet = false
    @State private var showAddSheet = false
    @State private var formulaEditorTarget: FavoritesGroup? = nil
    @State private var addGroupTarget: MetaItem? = nil
    @State private var refreshProgress: (groupID: UUID, done: Int, total: Int)? = nil
    @State private var showEditingMode = false   // 编辑模式：组内可拖排/删除

    // === 整表横向滚动（冻结前 3 列）===
    @State private var hScrollOffset: CGFloat = 0
    @State private var hDragStart: CGFloat = 0
    @State private var panAxisIsH: Bool? = nil

    /// Tab 列表（0 = "全部"虚拟分组，其后 = 各非隐藏真实分组）
    private var tabs: [FavoritesGroup] {
        var out: [FavoritesGroup] = [fav.allGroup]
        out.append(contentsOf: fav.visibleGroups)
        return out
    }

    /// 表格冻结列数（「行情表设置」面板可配置：第 1 列恒冻结，第 2/3 列可开关；范围 1~3）
    private var frozenCount: Int {
        colCfg.frozenCount(for: .favorites)
    }

    private var currentGroup: FavoritesGroup {
        let gid = fav.selectedGroupID
        if let g = tabs.first(where: { $0.id == gid }) { return g }
        return tabs.first ?? fav.allGroup
    }

    private var currentItems: [MetaItem] {
        fav.resolveMetaItems(groupID: currentGroup.id, allMeta: dbm.metaList)
    }

    private var sortedRows: [MarketRow] {
        let all = rowCache.rows(for: currentItems)
        if let rule = colCfg.sortRule(for: .favorites) {
            return all.sorted(by: rule)
        }
        return all
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具 + 分组 Tab
            topBar
            groupTabBar
            Divider()

            if !dbm.isLoaded {
                loadingView
            } else if currentItems.isEmpty {
                if currentGroup.kind == .formula {
                    formulaGroupEmptyState
                } else {
                    MarketEmptyStateView(icon: "star.slash",
                                         message: currentGroup.name == "全部"
                                                ? "还没有自选股"
                                                : "此分组暂无股票",
                                         subtitle: "在行情页面长按股票行即可加自选，或点击右上角 + 新建分组")
                }
            } else {
                // 表头（吸顶，冻结前3列，横向跟随整表滚动）
                MarketTableRow(page: .favorites, mode: .header, config: colCfg, rowCache: rowCache,
                               frozenCount: frozenCount, xOffset: hScrollOffset)
                .background(Color(.systemBackground))
                listBody
            }
        }
        // 异形屏横屏贴边已由 ContentView 根布局统一处理，此处仅实测宿主宽度
        // （贴边后的真实可视宽），供 maxHOffset 计算横向滚动上限
        .marketTableHostWidth(to: $tableVisibleWidth)
        .onChange(of: dbm.isLoaded) { loaded in
            if loaded { prefetchAllGroups() }
        }
        .onAppear { if dbm.isLoaded { prefetchAllGroups() } }
        .sheet(isPresented: $showColumnPanel) {
            MarketColumnConfigPanel(page: .favorites, configStore: colCfg)
        }
        .sheet(isPresented: $showManageSheet) {
            FavManageSheet(fav: fav)
        }
        .sheet(isPresented: $showAddSheet) {
            FavAddGroupSheet(fav: fav)
        }
        .sheet(item: Binding(
            get: { formulaEditorTarget.map(IdentifiableGroup.init) },
            set: { formulaEditorTarget = $0?.group }
        )) { wrap in
            FavFormulaEditorSheet(group: wrap.group, fav: fav)
        }
        .sheet(item: Binding(
            get: { addGroupTarget.map(FavIdentifiableMeta.init) },
            set: { addGroupTarget = $0?.meta }
        )) { wrap in
            AddToGroupSheet(meta: wrap.meta, fav: fav)
        }
    }

    private func prefetchAllGroups() {
        var all: Set<Int> = []
        for g in tabs {
            for m in fav.resolveMetaItems(groupID: g.id, allMeta: dbm.metaList) {
                all.insert(m.id)
            }
        }
        let metas = dbm.metaList.filter { all.contains($0.id) }
        _ = rowCache.rows(for: metas)
    }

    // MARK: - 顶部工具条

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

    private var topBar: some View {
        HStack(spacing: 4) {
            Text("自选")
                .font(.system(size: 18, weight: .bold))
                .accessibilityIdentifier("favorites.title")
                .padding(.leading, 16)
            Spacer()
            // 刷新公式分组（仅当选中 formula 分组）
            if currentGroup.kind == .formula {
                Button {
                    refreshFormulaGroup(id: currentGroup.id)
                } label: {
                    if let p = refreshProgress, p.groupID == currentGroup.id {
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
            if currentGroup.kind == .formula {
                Button {
                    formulaEditorTarget = currentGroup
                } label: {
                    // 已引用公式显示「编辑公式」，未选择显示「选择公式」
                    Label(fav.formulaName(groupID: currentGroup.id) == nil ? "选择公式" : "编辑公式",
                          systemImage: "function")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            topIconButton(showEditingMode ? "line.3.horizontal.circle.fill" : "line.3.horizontal",
                          color: showEditingMode ? .blue : .secondary) {
                showEditingMode.toggle()
            }
            topIconButton("slider.horizontal.3") {
                showColumnPanel = true
            }
            topIconButton("folder") {
                showManageSheet = true
            }
            topIconButton("plus", size: 18, color: .blue) {
                showAddSheet = true
            }
            .padding(.trailing, 4)
        }
        .frame(height: 48)
        .background(Color(.systemBackground))
    }

    // MARK: - 分组 Tab 条（横向滚动，顶部分组切换）

    private var groupTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs) { g in
                    let active = g.id == currentGroup.id
                    Button {
                        fav.selectedGroupID = g.id
                    } label: {
                        HStack(spacing: 4) {
                            if g.id == fav.allGroup.id {
                                Image(systemName: "tray.full.fill")
                                    .font(.system(size: 12))
                            } else {
                                Image(systemName: g.kind == .manual ? "folder.fill" : "function")
                                    .font(.system(size: 12))
                            }
                            Text(g.name)
                                .font(.system(size: 14, weight: active ? .bold : .regular))
                                .lineLimit(1)
                            Text(" \(countOfGroup(g))")
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

    private func countOfGroup(_ g: FavoritesGroup) -> Int {
        fav.resolveMetaItems(groupID: g.id, allMeta: dbm.metaList).count
    }

    // MARK: - 列表主体

    @ViewBuilder
    private var listBody: some View {
        if showEditingMode, currentGroup.kind == .manual {
            manualEditingList
        } else {
            standardList
        }
    }

    /// 标准只读/点击模式列表（共享表单渲染）
    private var standardList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sortedRows) { row in
                    rowCard(row: row)
                    Divider().padding(.leading, 30)
                }
            }
        }
        .simultaneousGesture(horizontalDragGesture)
        .refreshable {
            if currentGroup.kind == .formula {
                refreshFormulaGroup(id: currentGroup.id)
            } else {
                rowCache.refresh(metas: currentItems)
            }
        }
    }

    private var manualEditingList: some View {
        let gid = currentGroup.id
        let currentBinding = Binding<[MetaItem]>(
            get: { fav.resolveMetaItems(groupID: gid, allMeta: dbm.metaList) },
            set: { newMetas in
                // 将手动组的 manualMetaIDs 替换为新的顺序
                let order = newMetas.map { $0.id }
                guard let idx = fav.groups.firstIndex(where: { $0.id == gid }) else { return }
                guard fav.groups[idx].kind == .manual else { return }
                fav.groups[idx].manualMetaIDs = order
                // 直接写 JSON 存档
                // (利用保存 API)
                forceSaveOrder()
            }
        )
        return List {
            ForEach(currentBinding) { $m in
                HStack(spacing: 0) {
                    let mm = $m.wrappedValue
                    // 自选页内容本身即自选结果，无需再用灰底/红字标记，样式与行情页非自选行一致
                    MarketTableRow(page: .favorites, mode: .data(meta: mm), config: colCfg, rowCache: rowCache,
                                   onOpen: { meta in
                        DetailRouter.shared.open(meta, in: currentItems)
                    }, frozenCount: frozenCount, xOffset: hScrollOffset, isFaved: false)
                    .contextMenu {
                        Button(role: .destructive) {
                            fav.removeFromGroup(id: gid, metaID: mm.id)
                        } label: {
                            Label("从该分组移除", systemImage: "trash")
                        }
                    }
                }
            }
            .onMove { from, to in
                var items = fav.resolveMetaItems(groupID: gid, allMeta: dbm.metaList)
                items.move(fromOffsets: from, toOffset: to)
                let ids = items.map { $0.id }
                if let idx = fav.groups.firstIndex(where: { $0.id == gid }) {
                    fav.groups[idx].manualMetaIDs = ids
                    forceSaveOrder()
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))
    }

    private func forceSaveOrder() {
        // 借助公开 API 触发保存：模拟 toggle 一次不存在的 metaID 不会有副作用
        // 简单起见，直接用 addGroup(removeGroup 之外的操作)；
        // 最直接的是 rename 回同名
        if let g = fav.groups.first(where: { $0.id == currentGroup.id }) {
            fav.renameGroup(id: g.id, name: g.name)
        }
    }

    /// 表格宿主实测宽度（安全区内，异形屏横屏已扣除刘海侧 inset）
    @State private var tableVisibleWidth: CGFloat = 0

    /// 可视列里冻结前 3 列后，其余列的最大可左移量（整表横向滚动上限）
    private var maxHOffset: CGFloat {
        // 可视宽度用实测宿主宽（安全区内）；首帧未测量完成前退回 UIScreen 估算
        let visW = tableVisibleWidth > 0 ? tableVisibleWidth : UIScreen.main.bounds.width
        return max(0, MarketTableRow.scrollContentWidth(for: .favorites, config: colCfg, frozenCount: frozenCount)
             - visW)
    }

    /// 横向拖拽：按主轴向驱动 hScrollOffset（冻结列固定、其余列平移）；
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
                if panAxisIsH == true { hDragStart = hScrollOffset }
                panAxisIsH = nil
            }
    }

    /// 行卡片（标准模式）
    private func rowCard(row: MarketRow) -> some View {
        let meta = row.meta
        return HStack(spacing: 0) {
            // 整行单元格（冻结前3列 + 滚动列）；自选页无需自选高亮，样式与行情页非自选行一致
            MarketTableRow(page: .favorites, mode: .data(meta: meta), config: colCfg, rowCache: rowCache,
                           onOpen: { meta in
                DetailRouter.shared.open(meta, in: currentItems)
            }, frozenCount: frozenCount, xOffset: hScrollOffset, isFaved: false)
        }
        .padding(.trailing, 8)
        // 长按弹菜单：取消自选 / 加入其它分组 / 移动分组
        .contextMenu {
            Button(role: .destructive, action: { fav.toggleFavorite(meta.id) }) {
                Label("取消自选", systemImage: "star.slash")
            }
            Button(action: { addGroupTarget = meta }) {
                Label("加入其它分组", systemImage: "folder.badge.plus")
            }
            Menu(content: {
                let manualGroups = fav.groups.filter { $0.kind == .manual }
                ForEach(manualGroups) { g in
                    Button(action: {
                        if g.manualMetaIDs.contains(meta.id) {
                            fav.removeFromGroup(id: g.id, metaID: meta.id)
                        } else {
                            fav.addToGroup(id: g.id, metaID: meta.id)
                        }
                    }) {
                        let inIt = g.manualMetaIDs.contains(meta.id)
                        Label(g.name, systemImage: inIt ? "checkmark" : "")
                    }
                }
            }) { Label("移动到分组", systemImage: "arrow.up.arrow.down.circle") }
        }
    }

    // MARK: - 公式分组刷新

    private func refreshFormulaGroup(id: UUID) {
        guard let g = fav.groups.first(where: { $0.id == id }), g.kind == .formula else { return }
        refreshProgress = (id, 0, 0)
        // 范围：全市场（用户量不大，这个 Demo 可以接受；后续按行业限制就是在此传入子集）
        let pool = dbm.metaList
        let total = pool.count
        refreshProgress = (id, 0, total)
        fav.refreshFormulaGroup(id: id, candidates: pool, cache: rowCache,
                                progress: { d, t in
                                    refreshProgress = (id, d, t)
                                },
                                completion: { cnt in
                                    DebugLogger.shared.log("[Favorites] formulaGroup \(g.name) matches=\(cnt)/\(total)")
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        refreshProgress = nil
                                    }
                                })
    }

    private var formulaGroupEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "function")
                .font(.system(size: 46)).foregroundColor(.blue)
            Text(currentGroup.cachedMatches == nil
                 ? "尚未选股" : "暂无符合条件的股票")
                .font(.system(size: 15)).foregroundColor(.primary)
            Text(currentGroup.cachedMatches == nil
                 ? "点击右上角「刷新选股」即可按公式计算所有股票的最新一期信号"
                 : "可以修改公式阈值或再次刷新查看最新结果")
                .font(.system(size: 13)).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Button {
                refreshFormulaGroup(id: currentGroup.id)
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

// MARK: - 辅助 Identifiable 包装

private struct FavIdentifiableMeta: Identifiable {
    let meta: MetaItem
    var id: Int { meta.id }
}
private struct IdentifiableGroup: Identifiable {
    let group: FavoritesGroup
    var id: UUID { group.id }
}

// MARK: - 管理分组 sheet（删除/重命名/排序/隐藏）

struct FavManageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var fav: FavoritesStore
    /// 点「重新选择」时打开的公式分组编辑浮层
    @State private var formulaEditorTarget: FavoritesGroup? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("取消") { dismiss() }.foregroundColor(.secondary)
                Spacer()
                Text("管理分组").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Text("完成").foregroundColor(.blue).fontWeight(.bold)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            List {
                Section("分组顺序与显隐（长按拖动排序）") {
                    ForEach(Array(fav.groups.enumerated()), id: \.element.id) { i, _ in
                        let g = fav.groups[i]
                        let issue = fav.formulaIssue(groupID: g.id)
                        HStack(spacing: 10) {
                            Image(systemName: g.kind == .manual ? "folder.fill" : "function")
                                .foregroundColor(g.kind == .manual ? .orange : .purple)
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("分组名",
                                          text: Binding(
                                            get: { fav.groups[i].name },
                                            set: { nv in fav.groups[i].name = nv }
                                          ))
                                    .onSubmit { fav.saveToDisk() }
                                HStack(spacing: 8) {
                                    Text(g.kind == .manual ? "自定义" : "公式选股")
                                        .font(.system(size: 11))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(g.kind == .manual ? Color.orange.opacity(0.15) : Color.purple.opacity(0.15))
                                        .foregroundColor(g.kind == .manual ? .orange : .purple)
                                        .cornerRadius(4)
                                    // 公式分组显示引用到的选股公式名；引用失效时用橙字提示
                                    if g.kind == .formula {
                                        Text(fav.formulaName(groupID: g.id) ?? "未选择公式")
                                            .font(.system(size: 11))
                                            .foregroundColor(issue == nil ? .secondary : .orange)
                                            .lineLimit(1)
                                    }
                                    Text("\(g.manualMetaIDs.count) 只")
                                        .font(.system(size: 11)).foregroundColor(.secondary)
                                }
                                // 引用失效：橙字提示 + 「重新选择」入口（打开公式分组编辑浮层）
                                if let issue = issue {
                                    HStack(spacing: 6) {
                                        Text(issue)
                                            .font(.system(size: 11))
                                            .foregroundColor(.orange)
                                        Button("重新选择") { formulaEditorTarget = g }
                                            .font(.system(size: 11))
                                            .foregroundColor(.blue)
                                            .contentShape(Rectangle())
                                    }
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { !fav.groups[i].isHidden },
                                set: { nv in
                                    fav.groups[i].isHidden = !nv
                                    fav.saveToDisk()
                                }
                            )).labelsHidden()
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { from, to in
                        fav.moveGroup(fromOffsets: from, toOffset: to)
                    }
                    .onDelete { idx in
                        idx.forEach { i in
                            fav.removeGroup(id: fav.groups[i].id)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
        }
        .background(Color(.systemGroupedBackground))
        // sheet 是独立呈现图层，需单独禁用键盘避让，保证弹出键盘时面板布局不被挤压
        .ignoresSafeArea(.keyboard)
        // 「重新选择」：打开公式分组编辑浮层（改引用 / 换公式）
        .sheet(item: $formulaEditorTarget) { g in
            FavFormulaEditorSheet(group: g, fav: fav)
        }
    }
}

// MARK: - 新建分组 sheet（自定义/公式）

struct FavAddGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var fav: FavoritesStore
    @State private var name: String = ""
    @State private var kind: FavoritesGroupKind = .manual
    /// 选中的选股公式库条目 id（nil = 未选择，公式分组此时不可创建）
    @State private var selectedPickerID: String?
    /// 全屏打开公式管理页（新建选股公式）
    @State private var showFormulaCenter = false

    /// 名称非空；公式分组还要求已选中一条选股公式
    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if kind == .formula { return selectedPickerID != nil }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("取消") { dismiss() }.foregroundColor(.secondary)
                Spacer()
                Text("新建分组").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: {
                    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanName.isEmpty else { return }
                    switch kind {
                    case .manual:
                        fav.addGroup(.manual(name: cleanName))
                    case .formula:
                        guard let pickerID = selectedPickerID else { return }
                        fav.addGroup(.formula(name: cleanName, formulaID: pickerID))
                    }
                    dismiss()
                }) {
                    Text("创建").foregroundColor(.blue).fontWeight(.bold)
                }
                .disabled(!canCreate)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            Form {
                Section {
                    TextField("分组名称（如：科技龙头）", text: $name)
                        .font(.system(size: 16))
                    Picker("分组类型", selection: $kind) {
                        Text("自定义分组").tag(FavoritesGroupKind.manual)
                        Text("指标公式自动分组").tag(FavoritesGroupKind.formula)
                    }
                    .pickerStyle(.segmented)
                } header: { Text("基本信息") }

                if kind == .formula {
                    Section(header: Text("选择选股公式")) {
                        FavPickerFormulaChooser(selectedID: $selectedPickerID) {
                            showFormulaCenter = true
                        }
                    }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        // sheet 是独立呈现图层，需单独禁用键盘避让，保证弹出键盘时面板布局不被挤压
        .ignoresSafeArea(.keyboard)
        // 去公式管理新建选股公式（关闭后列表因 @Published 自动刷新）
        .fullScreenCover(isPresented: $showFormulaCenter) {
            FormulaCenterView(initialKind: .picker, onClose: { showFormulaCenter = false })
        }
    }
}

// MARK: - 选股公式选择器（新建 / 编辑公式分组共用）

/// 从公式库的选股公式中选择一条引用：单选列表 + 「去公式管理新建」入口。
/// 公式文本只在公式管理里维护，这里只做选择。
private struct FavPickerFormulaChooser: View {
    @Binding var selectedID: String?
    var onOpenLibrary: () -> Void

    @ObservedObject private var library = FormulaLibraryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if library.pickers.isEmpty {
                Text("公式库还没有选股公式")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(library.pickers) { doc in
                        pickerRow(doc)
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
            }

            Button(action: onOpenLibrary) {
                HStack(spacing: 6) {
                    Image(systemName: "function").font(.system(size: 13, weight: .semibold))
                    Text("去公式管理新建").font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(.blue)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .background(Color.blue.opacity(0.08))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)

            Text("选股公式统一在公式管理里维护；这里只选择引用。分组刷新时最后一根输出值 > 0 视为命中")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pickerRow(_ doc: FormulaDoc) -> some View {
        let selected = selectedID == doc.id
        return Button {
            selectedID = doc.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(selected ? .blue : .gray)
                VStack(alignment: .leading, spacing: 3) {
                    Text(doc.name)
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                    Text(summary(doc.pickBody))
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 单行摘要：去掉换行并裁剪空白
    private func summary(_ body: String) -> String {
        let one = body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.isEmpty ? "（空公式）" : one
    }
}

// MARK: - 公式分组编辑器（已有公式分组的修改）

struct FavFormulaEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let group: FavoritesGroup
    @ObservedObject var fav: FavoritesStore

    @State private var name: String
    /// 选中的选股公式库条目 id（初始 = 分组当前引用）
    @State private var selectedPickerID: String?
    /// 全屏打开公式管理页（新建选股公式）
    @State private var showFormulaCenter = false

    init(group: FavoritesGroup, fav: FavoritesStore) {
        self.group = group
        self.fav = fav
        _name = State(initialValue: group.name)
        _selectedPickerID = State(initialValue: group.formulaID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("取消") { dismiss() }.foregroundColor(.secondary)
                Spacer()
                Text("公式分组：\(group.name)")
                    .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Spacer()
                Button(action: {
                    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !n.isEmpty else { return }
                    // 改名 + 重绑公式引用（内部会落盘并清空旧结果）
                    fav.renameGroup(id: group.id, name: n)
                    fav.bindFormula(groupID: group.id, formulaID: selectedPickerID)
                    dismiss()
                }) {
                    Text("保存").foregroundColor(.blue).fontWeight(.bold)
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            // 引用失效提示（引用的选股公式已被删除）
            if let issue = fav.formulaIssue(groupID: group.id) {
                Text(issue)
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 10)
            }

            Form {
                Section(header: Text("分组名称")) {
                    TextField("名称", text: $name)
                }
                Section(header: Text("选择选股公式"),
                        footer: Text("点击保存后会清空旧结果；回到自选页点「刷新选股」后台跑全市场，输出线最后一根值 > 0 即入选")) {
                    FavPickerFormulaChooser(selectedID: $selectedPickerID) {
                        showFormulaCenter = true
                    }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        // sheet 是独立呈现图层，需单独禁用键盘避让，保证弹出键盘时面板布局不被挤压
        .ignoresSafeArea(.keyboard)
        // 去公式管理新建选股公式（关闭后列表因 @Published 自动刷新）
        .fullScreenCover(isPresented: $showFormulaCenter) {
            FormulaCenterView(initialKind: .picker, onClose: { showFormulaCenter = false })
        }
    }
}

// MARK: - 扩展：让 FavManageSheet 能触发保存（因为它直接对 $fav.groups 绑定写）

extension FavoritesStore {
    // saveToDisk 已在 FavoritesStore 暴露，无需再扩展
}

extension FavoritesStore {
    /// 对外暴露的 groups 下标修改（FavManageSheet 绑定写元素属性时调用）
    func updateGroupProperty(id: UUID, mutate: (inout FavoritesGroup) -> Void) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        mutate(&groups[idx])
        saveToDisk()
    }
}

#Preview {
    FavoritesView()
}

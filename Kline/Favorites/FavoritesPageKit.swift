//
//  FavoritesPageKit.swift
//  Kline
//
//  自选页共享骨架：跨布局共享的页面状态模型 FavoritesPageModel 与子视图
//  （工具条 / 编辑态开关 / 分组 Tab 条 / 表格主体 / 编辑态多选列表 / 长按面板与弹窗浮层）。
//  编辑态：手动 / 公式 /「全部」三类分组都可进（`List(selection:)` 多选 + 手动组保留拖拽排序），
//  底部批量条见 FavoritesRowMenu.swift（FavoritesBatchBar：按分组类型裁剪可用项）。
//  长按面板与备注 / 预警弹窗见 FavoritesRowMenu.swift：全部挂在容器层 overlay，
//  行与卡片自身不挂 menu（系统 .contextMenu 会把行换宿主重排 → 列错位 / 被裁）。
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
    /// 长按操作面板目标（nil = 未打开；挂在容器层 overlay，行内不挂任何 menu）
    @Published var rowMenuTarget: FavoritesRowMenuTarget? = nil
    /// 备注弹窗目标（全局备注，所有分组 / 行情页共享同一条）
    @Published var noteEditorTarget: FavoritesRowMenuTarget? = nil
    /// 预警弹窗载体（面板单只「设置预警」= 1 只；批量预警 = N 只，同一弹窗与创建路径）
    @Published var batchAlertTarget: BatchAlertTarget? = nil
    /// 批量编辑：多选集合（`List(selection:)` 的 SelectionValue = metaID）
    @Published var batchSelection: Set<Int> = []
    /// 批量备注弹窗载体（打开瞬间快照选中标的）
    @Published var batchNoteTarget: BatchNoteTarget? = nil
    /// 批量「移到分组」选择器开关（confirmationDialog 承载，沿用项目既有选择器规范）
    @Published var batchGroupPickerActive: Bool = false
    /// C 档列表形态：true = 卡片流（默认），false = 表格
    @Published var showsCardMode: Bool = true
    /// 布局自身常驻占据的横向宽度（B 档左侧分组侧栏 216pt；其余档 0），
    /// 由容器按当前布局写入：容器实测的是整页宽度，含侧栏时必须扣掉才是表格可视宽
    @Published var tableWidthInset: CGFloat = 0

    // MARK: 内部（横向拖拽，不参与渲染，无需 Published）
    var hDragStart: CGFloat = 0
    var panAxisIsH: Bool? = nil
    /// 订阅令牌（切分组 / 切布局时清空多选）
    private var cancellables = Set<AnyCancellable>()

    init() {
        // 跨分组 / 跨档位的多选语义不清（"看不见的行"不应被批量动作命中）→ 一旦切换就清空。
        // 放在模型里订阅，避免在 GroupTabs / B 侧栏 / D 看板 / 容器等每个写入点各加一段守卫。
        fav.$selectedGroupID
            .dropFirst()
            .sink { [weak self] _ in self?.setBatchSelection([]) }
            .store(in: &cancellables)
        PageLayoutStore.shared.$favoritesLayout
            .dropFirst()
            .sink { [weak self] _ in self?.setBatchSelection([]) }
            .store(in: &cancellables)
    }

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
        // 可视宽度用实测宿主宽（安全区内）再扣掉布局自带的常驻横向占位（B 档侧栏）；
        // 首帧未测量完成前退回 UIScreen 估算
        let hostW = tableVisibleWidth > 0 ? tableVisibleWidth : UIScreen.main.bounds.width
        let visW = max(0, hostW - tableWidthInset)
        return max(0, MarketTableRow.scrollContentWidth(for: .favorites, config: colCfg, frozenCount: frozenCount)
             - visW)
    }

    /// 指定分组内的标的
    func items(groupID: UUID) -> [MetaItem] {
        fav.resolveMetaItems(groupID: groupID, allMeta: dbm.metaList)
    }

    /// 指定分组内的行（已按列配置排序规则排序，并做「固顶优先」稳定分区）
    /// - Parameter prefetch: true → 未就绪的行触发后台预取（列表渲染用）；
    ///   false → 只读缓存快照（D 档统计快照用：避免统计重算 → 预取 → objectWillChange → 再重算的回环）
    func sortedRows(groupID: UUID, prefetch: Bool = true) -> [MarketRow] {
        let all = rowCache.rows(for: items(groupID: groupID), prefetch: prefetch)
        let base = colCfg.sortRule(for: .favorites).map { all.sorted(by: $0) } ?? all
        // 固顶优先：在页面级排序规则**之后**做稳定分区 —— 固顶项按固顶顺序恒排最前，
        // 其余保持排序后的原顺序（不用 sorted，避免不稳定排序打乱其余行）
        let pinned = fav.pinnedIDs(groupID: groupID)
        guard !pinned.isEmpty else { return base }

        var byID: [Int: MarketRow] = [:]
        for row in base { byID[row.metaID] = row }
        var head: [MarketRow] = []
        var taken: Set<Int> = []
        for id in pinned {
            guard let row = byID[id], taken.insert(id).inserted else { continue }
            head.append(row)
        }
        guard !head.isEmpty else { return base }
        let rest = base.filter { !taken.contains($0.metaID) }
        return head + rest
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

    // MARK: - 长按操作面板（自绘，替代系统 .contextMenu；面板挂在容器层 overlay）

    /// 当前是否处于「手动分组编辑态列表」语境（该语境的面板额外给「从该分组移除」）
    var isManualEditingList: Bool {
        showEditingMode && currentGroup.kind == .manual && currentGroup.id != fav.allGroup.id
    }

    /// 自选页上下文：当前分组 + 非行情页
    func menuTarget(for meta: MetaItem) -> FavoritesRowMenuTarget {
        FavoritesRowMenuTarget(meta: meta, groupID: currentGroup.id, isMarketPage: false)
    }

    /// 打开长按面板（同值不写，避免 @Published 发布风暴）
    func openRowMenu(_ target: FavoritesRowMenuTarget) {
        if rowMenuTarget != target { rowMenuTarget = target }
    }

    /// 面板项（按「可用性矩阵」算好后交给面板；不可用的项给 reason 供面板在其下方说明）
    ///
    /// - 手动分组：固顶 / 移前移后 / 加入其它分组 / 备注 / 设置·取消预警 / 取消自选
    /// - 公式分组：固顶 / 加入其它分组 / 备注 / 设置·取消预警（移前移后置灰给原因；取消自选不出现）
    /// - 「全部」虚拟组：加入其它分组 / 备注 / 设置·取消预警 / 取消自选（无固顶与移前移后）
    func rowMenuItems(for target: FavoritesRowMenuTarget,
                      includeRemoveFromGroup: Bool = false) -> [FavoritesRowMenuItem] {
        let meta = target.meta
        guard let gid = target.groupID else { return [] }
        let group = fav.groups.first(where: { $0.id == gid })
        let isAllGroup = gid == fav.allGroup.id
        var items: [FavoritesRowMenuItem] = []

        // 固顶：手动分组与公式分组都可固顶（纯显示层，与公式刷新结果无关）；「全部」虚拟组无实体 → 不出现
        if !isAllGroup, group != nil {
            let pinned = fav.isPinned(groupID: gid, metaID: meta.id)
            items.append(FavoritesRowMenuItem(action: .togglePin,
                                              title: pinned ? "取消固顶" : "固顶",
                                              icon: pinned ? "pin.slash" : "pin"))
        }

        // 移到最前 / 最后：仅手动实体分组且当前无页面级排序规则才可用
        if !isAllGroup, let group = group {
            let sortRule = colCfg.sortRule(for: .favorites)
            var blockReason: String?
            if group.kind == .formula {
                blockReason = "顺序由公式计算得到"
            } else if let rule = sortRule {
                let orderText = rule.order == .descending ? "降序" : "升序"
                blockReason = "当前按 \(rule.field.title)\(orderText) 排序，暂不可手动定位"
            }
            let index = group.manualMetaIDs.firstIndex(of: meta.id)
            let notInGroup = "不在该分组内"

            let firstEnabled = blockReason == nil && index != nil && index != 0
            var firstReason = blockReason
            if firstReason == nil, firstEnabled == false {
                firstReason = index == nil ? notInGroup : "已在最前"
            }
            items.append(FavoritesRowMenuItem(action: .moveToFirst, title: "移到最前",
                                              icon: "arrow.up.to.line",
                                              enabled: firstEnabled, reason: firstReason))

            let lastEnabled = blockReason == nil && index != nil && index != group.manualMetaIDs.count - 1
            var lastReason = blockReason
            if lastReason == nil, lastEnabled == false {
                lastReason = index == nil ? notInGroup : "已在最后"
            }
            items.append(FavoritesRowMenuItem(action: .moveToLast, title: "移到最后",
                                              icon: "arrow.down.to.line",
                                              enabled: lastEnabled, reason: lastReason))
        }

        // 加入其它分组（复用既有 AddToGroupSheet）
        items.append(FavoritesRowMenuItem(action: .addToGroup, title: "加入其它分组",
                                          icon: "folder.badge.plus"))

        // 备注…（有备注时右侧给首行摘要）
        let note = fav.note(for: meta.id)
        items.append(FavoritesRowMenuItem(action: .note, title: "备注…", icon: "note.text",
                                          trailing: note.map { FavoritesRowMenuItem.noteSummary($0) }))

        // 设置 / 取消预警（无可用模拟账户且尚未设置预警时置灰并说明）
        let hasAlert = FavoritesAlertKit.hasAlert(metaID: meta.id)
        let canAlert = hasAlert || FavoritesAlertKit.accountID != nil
        items.append(FavoritesRowMenuItem(action: .toggleAlert,
                                          title: hasAlert ? "取消预警" : "设置预警",
                                          icon: hasAlert ? "bell.slash" : "bell",
                                          enabled: canAlert,
                                          reason: canAlert ? nil : "请先在模拟页创建账户"))

        // 编辑态：仅从该分组移除（保留其它分组里的自选）
        if includeRemoveFromGroup, !isAllGroup, group?.kind == .manual {
            items.append(FavoritesRowMenuItem(action: .removeFromGroup, title: "从该分组移除",
                                              icon: "trash", destructive: true))
        }

        // 取消自选：公式分组成员由公式决定，故不出现；手动分组与「全部」组都有
        if isAllGroup || group?.kind == .manual {
            items.append(FavoritesRowMenuItem(action: .toggleFavorite, title: "取消自选",
                                              icon: "star.slash", destructive: true))
        }
        return items
    }

    /// 执行面板动作（面板已在调用处关闭）
    func performRowMenu(_ action: FavoritesRowMenuAction, for target: FavoritesRowMenuTarget) {
        let meta = target.meta
        switch action {
        case .togglePin:
            if let gid = target.groupID { fav.togglePin(groupID: gid, metaID: meta.id) }
        case .moveToFirst:
            if let gid = target.groupID { fav.moveToFirst(groupID: gid, metaID: meta.id) }
        case .moveToLast:
            if let gid = target.groupID { fav.moveToLast(groupID: gid, metaID: meta.id) }
        case .addToGroup:
            addGroupTarget = meta
        case .note:
            noteEditorTarget = target
        case .toggleAlert:
            if FavoritesAlertKit.hasAlert(metaID: meta.id) {
                FavoritesAlertKit.cancelAlerts(metaID: meta.id)
            } else {
                // 单只预警也走批量预警弹窗（count = 1），同一套创建路径
                batchAlertTarget = BatchAlertTarget(metas: [meta])
            }
        case .toggleFavorite:
            fav.toggleFavorite(meta.id)
        case .removeFromGroup:
            if let gid = target.groupID { fav.removeFromGroup(id: gid, metaID: meta.id) }
        }
    }

    // MARK: - 批量编辑（多选 + 底部批量条）

    /// 当前分组是否「全部」虚拟组（无实体：固顶 / 移到分组不适用，移出即「取消自选」）
    private var isAllGroupSelected: Bool { currentGroup.id == fav.allGroup.id }

    /// 进入 / 退出编辑态：退出时清空多选（避免残留选择在下次进入时命中"看不见的行"）
    func toggleEditingMode() {
        if showEditingMode {
            setBatchSelection([])
            showEditingMode = false
        } else {
            showEditingMode = true
        }
    }

    /// 写多选（同值不写，避免 @Published 发布风暴）
    func setBatchSelection(_ new: Set<Int>) {
        if batchSelection != new { batchSelection = new }
    }

    /// 选中标的快照：按当前分组原始顺序（Set 无序，动作一律按显示顺序执行）
    func batchSelectedMetas() -> [MetaItem] {
        guard !batchSelection.isEmpty else { return [] }
        let selected = batchSelection
        return currentItems.filter { selected.contains($0.id) }
    }

    /// 批量条项目（按当前分组类型的可用性矩阵裁剪 / 置灰；不可用项给原因供批量条显示一行说明）
    ///
    /// - 手动分组：10 项全可用
    /// - 公式分组：移出 / 移到分组 置灰（原因「顺序由公式计算得到」，拖拽排序同样不提供）
    /// - 「全部」虚拟组：只保留 取消自选 / 备注 / 预警 / 全选 / 取消全选（固顶与移到分组不出现）
    func batchBarItems() -> [FavoritesBatchItem] {
        let isAll = isAllGroupSelected
        let isFormula = currentGroup.kind == .formula
        let hasSelection = !batchSelection.isEmpty
        let formulaReason = isFormula ? "顺序由公式计算得到" : nil
        let hasAccount = FavoritesAlertKit.accountID != nil
        var items: [FavoritesBatchItem] = []

        items.append(FavoritesBatchItem(action: .removeFromGroup,
                                        title: isAll ? "取消自选" : "移出",
                                        icon: "folder.badge.minus",
                                        enabled: hasSelection && !isFormula,
                                        reason: formulaReason))
        if !isAll {
            items.append(FavoritesBatchItem(action: .moveToGroup, title: "移到分组",
                                            icon: "folder.badge.plus",
                                            enabled: hasSelection && !isFormula,
                                            reason: formulaReason))
            items.append(FavoritesBatchItem(action: .pin, title: "固顶",
                                            icon: "pin", enabled: hasSelection))
            items.append(FavoritesBatchItem(action: .unpin, title: "取消固顶",
                                            icon: "pin.slash", enabled: hasSelection))
        }
        items.append(FavoritesBatchItem(action: .setNote, title: "设置备注",
                                        icon: "note.text", enabled: hasSelection))
        items.append(FavoritesBatchItem(action: .clearNote, title: "清除备注",
                                        icon: "trash", enabled: hasSelection))
        items.append(FavoritesBatchItem(action: .setAlert, title: "设置预警",
                                        icon: "bell", enabled: hasSelection && hasAccount,
                                        reason: hasAccount ? nil : "请先在模拟页创建账户"))
        items.append(FavoritesBatchItem(action: .cancelAlert, title: "取消预警",
                                        icon: "bell.slash", enabled: hasSelection))
        // 全选是「从无到有」的入口：批量条只在当前分组有行时才渲染（空态走列表空态），故恒可用；
        // 已全选时再点为幂等 no-op；取消全选要有选择才有意义。
        // 注意：本方法在批量条 body 内调用，故只用 O(1) 状态（不在此处遍历分组标的 / 行缓存）
        items.append(FavoritesBatchItem(action: .selectAll, title: "全选",
                                        icon: "checkmark.circle", enabled: true))
        items.append(FavoritesBatchItem(action: .deselectAll, title: "取消全选",
                                        icon: "circle", enabled: hasSelection))
        return items
    }

    /// 执行批量动作（动作完成后清空选择并保持编辑态；单个标的失败只记日志、继续处理其余标的）
    func performBatch(_ action: FavoritesBatchAction) {
        switch action {
        case .selectAll:
            // 全选 = 当前列表已显示的行（sortedRows 的 metaID 集合）
            setBatchSelection(Set(sortedRows.map(\.metaID)))
        case .deselectAll:
            setBatchSelection([])

        case .removeFromGroup:
            let gid = currentGroup.id
            for meta in batchSelectedMetas() {
                if gid == fav.allGroup.id {
                    // 「全部」虚拟组：取消自选 = 从所有手动分组移除
                    fav.toggleFavorite(meta.id)
                } else {
                    fav.removeFromGroup(id: gid, metaID: meta.id)
                }
            }
            finishBatch()

        case .moveToGroup:
            // 目标分组由 confirmationDialog 选择，选完调 performBatchMoveToGroup(_:)
            batchGroupPickerActive = true

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
            batchAlertTarget = BatchAlertTarget(metas: batchSelectedMetas())

        case .cancelAlert:
            for meta in batchSelectedMetas() { FavoritesAlertKit.cancelAlerts(metaID: meta.id) }
            finishBatch()
        }
    }

    /// 批量移到分组（用户在选择器里点了目标分组）：加入目标分组 + 从当前分组移除
    func performBatchMoveToGroup(_ target: FavoritesGroup) {
        let gid = currentGroup.id
        for meta in batchSelectedMetas() {
            fav.addToGroup(id: target.id, metaID: meta.id)
            // 当前组为「全部」虚拟组时没有实体可移除，只做加入
            if gid != fav.allGroup.id { fav.removeFromGroup(id: gid, metaID: meta.id) }
        }
        finishBatch()
    }

    /// 批量备注落库（弹窗「保存」传文本；「清空」传空串 = 删除 key）
    func applyBatchNote(_ text: String) {
        let metas = batchNoteTarget?.metas ?? []
        for meta in metas { fav.setNote(metaID: meta.id, text: text) }
        finishBatch()
    }

    /// 批量预警创建（弹窗「应用到 N 只」）：对快照标的各建一条同规则 alertOnly 条件单；
    /// 失败原因由 FavoritesAlertKit 记 DebugLogger，不中断其余标的
    func applyBatchAlert(compareUp: Bool, triggerPrice: Double) {
        let metas = batchAlertTarget?.metas ?? []
        FavoritesAlertKit.setAlerts(metas: metas, compareUp: compareUp, triggerPrice: triggerPrice)
        finishBatch()
    }

    /// 批量固顶 / 取消固顶：按列表当前显示顺序逐个执行（Set 无序，不能按点击顺序）；
    /// 用 `isPinned` 先判方向，保证「固顶」不会把已固顶项反向取消（反之亦然）
    private func setBatchPinned(_ pinned: Bool) {
        let gid = currentGroup.id
        guard gid != fav.allGroup.id else { return }
        let selected = batchSelection
        for row in sortedRows where selected.contains(row.metaID) {
            if fav.isPinned(groupID: gid, metaID: row.metaID) != pinned {
                fav.togglePin(groupID: gid, metaID: row.metaID)
            }
        }
        finishBatch()
    }

    /// 批量动作收尾：只清空选择、保持编辑态（用户常连续做多组批量动作）
    private func finishBatch() {
        setBatchSelection([])
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

// MARK: - 编辑态开关按钮（四档共用：文案「编辑」→「完成」）

/// 编辑态开关：灰底胶囊蓝字「编辑」→ 编辑态蓝底白字「完成」，命中区 44pt。
/// A 工具条 / B 工作区标题 / C 顶栏 / D 顶栏共用同一个按钮，保证四档文案与选中态一致；
/// 退出编辑态时由 `FavoritesPageModel.toggleEditingMode()` 一并清空多选。
struct FavoritesEditToggleButton: View {
    @ObservedObject var model: FavoritesPageModel

    var body: some View {
        Button {
            model.toggleEditingMode()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.showEditingMode ? "line.3.horizontal.circle.fill" : "line.3.horizontal")
                    .font(.system(size: 12, weight: .medium))
                Text(model.showEditingMode ? "完成" : "编辑")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    // 固定最小宽：文案切换时按钮宽度不跳动
                    .frame(minWidth: 24)
            }
            .foregroundColor(model.showEditingMode ? .white : .blue)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(model.showEditingMode ? Color.blue : Color(.systemGray6))
            .cornerRadius(7)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            // 编辑态开关（A/B/C/D 四档同一按钮：文案「编辑」→「完成」）
            FavoritesEditToggleButton(model: model)
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
/// `rowHeight` / `fontSize` 直接透传给 `MarketTableRow` 的 `heightOverride` / `fontSizeOverride`
/// （表头与数据行统一按该行高渲染、主字号按该字号渲染，副行按 0.72 比例）：
/// - 默认 45 / 18 时不传覆盖值（nil），`MarketTableRow` 沿用既有写死值（表头 38 / 数据行 45 / 主字号 18）
///   → A 档渲染零变化；
/// - D 档紧凑表传 34 / 15，行高与字号真正落到行内部（不再靠外层 frame 硬压，避免溢出重叠）。
struct FavoritesTableBody: View {
    @ObservedObject var model: FavoritesPageModel
    /// 数据行高（A 档 45；D 档紧凑表 34）
    var rowHeight: CGFloat = 45
    /// 数据行主字号（A 档 18；D 档紧凑表 15）
    var fontSize: CGFloat = 18

    /// 行高覆盖值：默认 45 与既有写死值一致 → 传 nil 保持 A 档零变化
    private var rowHeightOverride: CGFloat? { rowHeight == 45 ? nil : rowHeight }
    /// 字号覆盖值：默认 18 与既有写死值一致 → 传 nil 保持 A 档零变化
    private var fontSizeOverride: CGFloat? { fontSize == 18 ? nil : fontSize }

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
                           frozenCount: model.frozenCount, xOffset: model.hScrollOffset,
                           heightOverride: rowHeightOverride, fontSizeOverride: fontSizeOverride)
            .background(Color(.systemBackground))
            listBody
        }
    }

    @ViewBuilder
    private var listBody: some View {
        // 三类分组（手动 / 公式 /「全部」虚拟组）都可进入编辑态：批量动作按分组类型裁剪可用项
        // （旧行为「公式组切编辑回退只读列表」已修掉）
        if model.showEditingMode {
            FavoritesManualEditingList(model: model,
                                       heightOverride: rowHeightOverride,
                                       fontSizeOverride: fontSizeOverride)
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
        }
        .simultaneousGesture(model.rowMenuTarget == nil ? model.horizontalDragGesture : nil)
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
            }, frozenCount: model.frozenCount, xOffset: model.hScrollOffset, isFaved: false,
                           heightOverride: rowHeightOverride, fontSizeOverride: fontSizeOverride)
        }
        .padding(.trailing, 8)
        .frame(height: rowHeight)
        // 长按出操作面板：面板挂在容器层 overlay，**行自身无任何样式改动** ——
        // 不用 .contextMenu（它走 UIContextMenuInteraction 抬升快照管线，会把行换宿主重排，
        // 行内 GeometryReader 实测宽 + 常量列宽 + offset + clipped 会因此列错位 / 被裁）
        .onLongPressGesture(minimumDuration: 0.5) {
            withAnimation(.easeOut(duration: 0.15)) {
                model.openRowMenu(model.menuTarget(for: meta))
            }
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

// MARK: - 编辑态列表（多选 + 拖拽排序 + 底部批量条）

/// 编辑态列表：手动 / 公式 /「全部」三类分组都可进入。
/// - 多选：`List(selection:)`，SelectionValue = `metaID`（Int），行用 `.tag(metaID)`；
///   写入统一走 `model.setBatchSelection`（同值不写）
/// - 拖拽排序：仅手动实体分组提供 `.onMove`（公式组顺序由公式算、「全部」组是虚拟并集）——
///   不提供拖拽手柄，而不是"提供但 no-op"，避免出现拖了没反应的手柄
/// - 行数据取分组**原始顺序**（手动组 = manualMetaIDs 顺序；不走 sortedRows，避免固顶分区 /
///   排序规则打乱拖动语义）
/// - 底部常驻批量条（A/B/C/D 与 C 档卡片形态共用这一处）；编辑态不挂横向手势（本就与横滑互斥）
struct FavoritesManualEditingList: View {
    @ObservedObject var model: FavoritesPageModel
    /// 行高覆盖（nil = 既有 45）；D 档紧凑表传 34，编辑态与只读态行高一致
    var heightOverride: CGFloat? = nil
    /// 主字号覆盖（nil = 既有 18）；D 档紧凑表传 15
    var fontSizeOverride: CGFloat? = nil

    private var gid: UUID { model.currentGroup.id }

    /// 拖拽排序可用性：仅手动实体分组
    private var canReorder: Bool {
        model.currentGroup.kind == .manual && gid != model.fav.allGroup.id
    }

    /// 编辑态行数据：分组原始顺序
    private var editingItems: [MetaItem] { model.items(groupID: gid) }

    /// 多选绑定：统一经 `setBatchSelection` 写入（同值不写）
    private var selection: Binding<Set<Int>> {
        Binding(get: { model.batchSelection },
                set: { model.setBatchSelection($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                if canReorder {
                    ForEach(editingItems) { meta in
                        editingRow(meta).tag(meta.id)
                    }
                    .onMove { from, to in
                        var items = editingItems
                        items.move(fromOffsets: from, toOffset: to)
                        model.saveManualOrder(groupID: gid, orderedMetaIDs: items.map { $0.id })
                    }
                } else {
                    ForEach(editingItems) { meta in
                        editingRow(meta).tag(meta.id)
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))

            // 底部批量条（高度固定；无选择时动作置灰）
            FavoritesBatchBar(model: model)
        }
    }

    /// 编辑态行：与只读态同一套 MarketTableRow（行高 / 字号沿用覆盖值）+ 长按操作面板
    private func editingRow(_ meta: MetaItem) -> some View {
        HStack(spacing: 0) {
            // 自选页内容本身即自选结果，无需再用灰底/红字标记，样式与行情页非自选行一致
            MarketTableRow(page: .favorites, mode: .data(meta: meta), config: model.colCfg, rowCache: model.rowCache,
                           onOpen: { m in
                model.detailRouter.open(m, in: model.items(groupID: gid))
            }, frozenCount: model.frozenCount, xOffset: model.hScrollOffset, isFaved: false,
                           heightOverride: heightOverride, fontSizeOverride: fontSizeOverride)
            // 长按出同一套操作面板（该列表的「从该分组移除」并入面板项）
            .onLongPressGesture(minimumDuration: 0.5) {
                withAnimation(.easeOut(duration: 0.15)) {
                    model.openRowMenu(model.menuTarget(for: meta))
                }
            }
        }
    }
}

// MARK: - 浮层（列配置 / 管理分组 / 新建分组 / 公式编辑 / 加入分组 / 长按面板 / 备注 / 预警）

/// 自选页呈现层：挂在容器层，四档布局共用。
/// - 长按操作面板 / 备注弹窗 / 预警弹窗 / 批量备注弹窗（容器层 overlay，四档共用同一套）
/// - 批量「移到分组」选择器（confirmationDialog，沿用项目既有选择器规范）
/// - 行情表设置面板 sheet
/// - 管理分组 sheet
/// - 新建分组 sheet
/// - 公式分组编辑 sheet
/// - 加入分组 sheet
struct FavoritesSheets: ViewModifier {
    @ObservedObject var model: FavoritesPageModel

    func body(content: Content) -> some View {
        content
            // 长按面板 / 备注 / 预警：容器层 overlay（行内零改动，长按前后行几何逐值不变）
            .overlay { rowMenuLayers }
            // 批量「移到分组」：目标分组用 confirmationDialog 选（选择器统一规范，不用 Menu）
            .confirmationDialog("移到分组", isPresented: $model.batchGroupPickerActive,
                                titleVisibility: .visible) {
                ForEach(model.fav.groups.filter { $0.kind == .manual }) { g in
                    Button(g.name) { model.performBatchMoveToGroup(g) }
                }
                Button("取消", role: .cancel) { }
            }
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

    @ViewBuilder
    private var rowMenuLayers: some View {
        if let target = model.rowMenuTarget {
            FavoritesOverlayCard(onDismiss: { closeRowMenu() }) {
                FavoritesRowMenuPanel(title: target.meta.name,
                                      subtitle: target.meta.displayCode,
                                      items: model.rowMenuItems(for: target,
                                                                includeRemoveFromGroup: model.isManualEditingList),
                                      onSelect: { action in
                                          closeRowMenu()
                                          model.performRowMenu(action, for: target)
                                      },
                                      onCancel: { closeRowMenu() })
            }
        }
        if let target = model.noteEditorTarget {
            FavoritesOverlayCard(onDismiss: { closeNoteEditor() }) {
                FavoritesNoteSheet(meta: target.meta,
                                   initialText: model.fav.note(for: target.meta.id) ?? "",
                                   onSave: { text in
                                       model.fav.setNote(metaID: target.meta.id, text: text)
                                       closeNoteEditor()
                                   },
                                   onClear: {
                                       model.fav.setNote(metaID: target.meta.id, text: "")
                                       closeNoteEditor()
                                   },
                                   onCancel: { closeNoteEditor() })
            }
        }
        if let target = model.batchNoteTarget, let first = target.metas.first {
            FavoritesOverlayCard(onDismiss: { closeBatchNote() }) {
                FavoritesNoteSheet(meta: first,
                                   initialText: "",
                                   titleOverride: "批量备注 · \(target.count) 只",
                                   onSave: { text in
                                       model.applyBatchNote(text)
                                       closeBatchNote()
                                   },
                                   onClear: {
                                       // 批量「清空」= 删除这批标的的备注 key
                                       model.applyBatchNote("")
                                       closeBatchNote()
                                   },
                                   onCancel: { closeBatchNote() })
            }
        }
        if let target = model.batchAlertTarget {
            FavoritesOverlayCard(onDismiss: { closeBatchAlert() }) {
                FavoritesBatchAlertSheet(metas: target.metas,
                                         onApply: { compareUp, price in
                                             closeBatchAlert()
                                             model.applyBatchAlert(compareUp: compareUp,
                                                                   triggerPrice: price)
                                         },
                                         onCancel: { closeBatchAlert() })
            }
        }
    }

    private func closeRowMenu() {
        guard model.rowMenuTarget != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { model.rowMenuTarget = nil }
    }

    private func closeNoteEditor() {
        guard model.noteEditorTarget != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { model.noteEditorTarget = nil }
    }

    private func closeBatchNote() {
        guard model.batchNoteTarget != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { model.batchNoteTarget = nil }
    }

    private func closeBatchAlert() {
        guard model.batchAlertTarget != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { model.batchAlertTarget = nil }
    }
}

extension View {
    /// 挂载自选页全部呈现层（四档布局共用）
    func favoritesSheets(model: FavoritesPageModel) -> some View {
        modifier(FavoritesSheets(model: model))
    }
}

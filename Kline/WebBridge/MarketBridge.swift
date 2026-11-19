//
//  MarketBridge.swift
//  Kline
//
//  Market 域的桥接动作实现（协议 v2 market.*）：行情页 Web 化的 Swift 侧。
//  数据全部来自原生 Store（DatabaseManager / MarketRowCache / MarketConfigStore / FavoritesStore），
//  Web 侧零状态。页面状态模型 = 常驻 MarketPageModel（原生 MarketView 退役后由本桥持有，
//  分类状态跨动作保持；原生 MarketView 类保留不删，回退 = 改回 ContentView 一行分支）。
//
//  数据流（写回模式 v2）：
//   - Web 只发动作；原生写状态后**不回推快照**——由 market.changed 事件（节流 ~0.8s 合并）
//     触发 Web 回读 snapshot（事件通知 + 页面拉取模式，P2 计划 §3.4）。
//   - 行数值变化源 = MarketRowCache.objectWillChange（预取/引擎值逐批到达）→ 节流推送；
//     快照拉取时直接读 row.number() 缓存，天然最新。
//   - 筛选生效时行集依赖数值 → rowCache 变化需防抖重刷 displayRows（对齐原生 MarketView）。
//
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Combine
import SwiftUI

@MainActor
final class MarketBridge: ObservableObject {

    static let shared = MarketBridge()

    /// Web 模式专用的页面状态模型（分类状态跨动作保持）
    let model = MarketPageModel()

    // MARK: 原生全屏浮层桥（MarketWebShellView overlay 挂载呈现）
    // 搜索页复用 HomeView 搜索模式、公式中心复用 FormulaCenterView——P2-2 不引入 Web 弹层容器。

    @Published var homeSearchActive = false
    @Published var showFormulaCenter = false

    // MARK: 变化信号 → market.changed 节流推送

    private var cancellables = Set<AnyCancellable>()
    private var changedItem: DispatchWorkItem? = nil
    private var pendingReason = "data"
    /// 筛选生效时 bars 陆续到位的重刷防抖（对齐原生 MarketView.filterDebounce）
    private var filterDebounce: DispatchWorkItem? = nil
    /// 节流窗口（行情秒级快照节奏；实测后调参）
    private let changedThrottle: TimeInterval = 0.8

    private init() {
        let rowCache = MarketRowCache.shared
        let colCfg = MarketConfigStore.shared
        let fav = FavoritesStore.shared
        let dbm = DatabaseManager.shared

        // 行数值变化：高频（预取逐批到达）。有筛选时防抖重刷（数值影响行集），随后节流推送
        rowCache.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                if self.model.hasActiveFilters {
                    self.filterDebounce?.cancel()
                    let m = self.model
                    let item = DispatchWorkItem {
                        Task { @MainActor in m.scheduleRefresh() }
                    }
                    self.filterDebounce = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
                }
                self.scheduleChanged(reason: "data")
            }
            .store(in: &cancellables)

        // 列配置变化（排序/显隐/筛选/冻结）：行集与列布局都变 → 立即重刷 + 节流推送
        colCfg.objectWillChange
            .sink { [weak self] _ in
                self?.model.scheduleRefresh()
                self?.scheduleChanged(reason: "config")
            }
            .store(in: &cancellables)

        // 收藏变化（加/删自选触发置顶分组 → 行序变）
        fav.objectWillChange
            .sink { [weak self] _ in
                self?.model.scheduleRefresh()
                self?.scheduleChanged(reason: "edit")
            }
            .store(in: &cancellables)

        // 页面状态变化（分类切换等；Web 端回读快照携带 topMenu/seconds）
        model.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged(reason: "data") }
            .store(in: &cancellables)

        // 库加载完成 → 刷新行集。
        // ⚠️⚠️ 两个连环坑（2026-11-19 实测排障）：
        // ① @Published 订阅时同步回放当前值，init 执行期间 [weak self] 解析失败会静默吞掉
        //    首发 → dropFirst 只听后续变化，init 时已加载的场景在末尾显式补刷；
        // ② $isLoaded 是 **willSet 语义**：sink 收到 true 时属性实际值尚未写入，
        //    scheduleRefresh 内部 guard databaseManager.isLoaded 会看到 false 而清空返回
        //    （MarketRowCache.prewarm 显式传 isLoaded:true 参数绕开了同款坑）→
        //    跳到下一 runloop 再刷，届时写入已完成。
        dbm.$isLoaded
            .dropFirst()
            .sink { [weak self] loaded in
                guard loaded else { return }
                DispatchQueue.main.async {
                    guard let self, DatabaseManager.shared.isLoaded else { return }
                    self.model.scheduleRefresh()
                    self.scheduleChanged(reason: "data")
                }
            }
            .store(in: &cancellables)

        // init 时库已就绪（本桥是行情页 Web 化后的唯一宿主，冷启动预热通常已完成）：显式刷一次
        if dbm.isLoaded {
            DebugLogger.shared.log("[MarketBridge] init 补刷开始 isLoaded=\(dbm.isLoaded) metas=\(model.tabItems.count)")
            model.scheduleRefresh()
            DebugLogger.shared.log("[MarketBridge] init 补刷完成 displayRows=\(model.displayRows.count)")
            scheduleChanged(reason: "data")
        } else {
            DebugLogger.shared.log("[MarketBridge] init 时库未就绪，等待 isLoaded 变化触发")
        }
    }

    /// 节流合并推送：窗口内首个信号安排推送，后续信号仅更新 reason
    private func scheduleChanged(reason: String) {
        pendingReason = reason
        guard changedItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.changedItem = nil
            WebMessageRouter.shared.pushEvent("market.changed",
                                              payload: ["reason": self.pendingReason])
        }
        changedItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + changedThrottle, execute: item)
    }

    /// 写回完成立即推送（不经节流）：Web 端动作成功即回读，事件主要兜底 native 推送链路
    private func notifyChangedNow(reason: String) {
        changedItem?.cancel()
        changedItem = nil
        WebMessageRouter.shared.pushEvent("market.changed", payload: ["reason": reason])
    }

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "snapshot":
            return WebBridgeResponse.ok(request.id, data: snapshotData())
        case "select":
            return select(request)
        case "refresh":
            return refresh(request)
        case "openDetail":
            return openDetail(file: (request.payload["file"] as? String) ?? "", id: request.id)
        case "openSearch":
            shared.homeSearchActive = true
            return WebBridgeResponse.ok(request.id)
        case "openFormulaCenter":
            shared.showFormulaCenter = true
            return WebBridgeResponse.ok(request.id)
        case "groupInfo":
            return groupInfo(request)
        case "setFavorite":
            return setFavorite(request)
        case "setInGroup":
            return setInGroup(request)
        case "createGroup":
            return createGroup(request)
        case "sortToggle":
            return sortToggle(request)
        case "configSnapshot":
            return WebBridgeResponse.ok(request.id, data: configSnapshotData())
        case "configSet":
            return configSet(request)
        case "configReset":
            MarketConfigStore.shared.reset(page: .marketBoard)
            shared.notifyChangedNow(reason: "config")
            return WebBridgeResponse.ok(request.id)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "market.\(request.action) 未实现")
        }
    }

    // MARK: - 快照组装

    /// market.snapshot：分类状态 + 渲染列 + 排序筛选后的行情行（数值按可见列裁剪）。
    /// 数值未就绪发 null（Web 端显示 "-"）；pct 恒发（着色基准，可见列不含 changePct 时也要）。
    static func snapshotData() -> [String: Any] {
        let bridge = MarketBridge.shared
        let model = bridge.model
        let fav = FavoritesStore.shared
        let colCfg = MarketConfigStore.shared

        // 自愈兜底：行集空但库已就绪 → 现场刷一次（init 时序 / 信号丢失的任何场景都收敛，
        // scheduleRefresh 幂等轻量；行集非空时不重复刷，保持拉取 <10ms）
        if model.displayRows.isEmpty, DatabaseManager.shared.isLoaded {
            model.scheduleRefresh()
            DebugLogger.shared.log("[MarketBridge] snapshot 自愈刷新 displayRows=\(model.displayRows.count)")
        }

        // 渲染列布局（相邻代码/名称合并为双行单元格，与原生表格完全一致）
        let rendered = MarketTableRow.renderedColumns(for: .marketBoard, config: colCfg)
        let colsAny: [[String: Any]] = rendered.map { col in
            ["field": col.field.rawValue,
             "isNameCode": col.isNameCode,
             "title": col.isNameCode ? "名称/代码" : col.field.title,
             "width": Int(col.width)]
        }
        // 数值字段集：渲染列里的非合并列（去重）
        var valueFields: [MarketField] = []
        for col in rendered where !col.isNameCode && !valueFields.contains(col.field) {
            valueFields.append(col.field)
        }

        let rowsAny: [[String: Any]] = model.displayRows.map { row in
            var values: [String: Any] = [:]
            for f in valueFields {
                values[f.rawValue] = row.number(f) ?? NSNull()
            }
            return [
                "file": row.meta.file,
                "code": row.meta.displayCode,
                "name": row.meta.name,
                "fav": fav.isFavorited(row.metaID),
                "pinned": fav.isPinned(row.metaID),
                "pct": row.number(.changePct) ?? NSNull(),
                "values": values,
            ]
        }

        // 当前一级下的二级分类（count 仅市场类有真实数据源，badge 为数字字符串或 nil）
        let secondsAny: [[String: Any]] = model.topMenuItems(for: model.topMenu).map { item in
            ["key": item.key, "title": item.title, "active": item.key == model.currentCategoryTitle,
             "count": item.badge.flatMap(Int.init) ?? NSNull()]
        }

        var sortFieldAny: Any = NSNull()
        var sortAsc = false
        if let rule = colCfg.sortRule(for: .marketBoard) {
            sortFieldAny = rule.field.rawValue
            sortAsc = rule.order == .ascending
        }

        return [
            "loaded": DatabaseManager.shared.isLoaded,
            "topMenu": model.topMenu.rawValue,
            "seconds": secondsAny,
            "columns": colsAny,
            "sortField": sortFieldAny,
            "sortAsc": sortAsc,
            "rows": rowsAny,
        ]
    }

    /// market.select {menu?, second?}：切一级/二级分类（rawValue 中文匹配）。
    /// 写状态后 scheduleRefresh；Web 端动作成功即回读，行值随后经 changed 推送补齐。
    private static func select(_ request: WebBridgeRequest) -> [String: Any] {
        let model = MarketBridge.shared.model
        var touched = false
        if let menuRaw = request.payload["menu"] as? String,
           let field = TopField(rawValue: menuRaw), model.topMenu != field {
            model.topMenu = field
            touched = true
        }
        if let second = request.payload["second"] as? String, !second.isEmpty {
            switch model.topMenu {
            case .market:
                if let tab = MarketTab(rawValue: second), model.selectedTab != tab {
                    model.selectedTab = tab; touched = true
                }
            case .picker:
                if let p = PickerField(rawValue: second), model.pickerSeg != p {
                    model.pickerSeg = p; touched = true
                }
            case .fav:
                if let f = FavField(rawValue: second), model.favSeg != f {
                    model.favSeg = f; touched = true
                }
            }
        }
        if touched { model.scheduleRefresh() }
        return WebBridgeResponse.ok(request.id)
    }

    /// market.refresh：触发 scheduleRefresh（预取置顶优先）；异步完成后经 changed 推送补齐
    private static func refresh(_ request: WebBridgeRequest) -> [String: Any] {
        let model = MarketBridge.shared.model
        let count = model.displayRows.count
        model.scheduleRefresh()
        DebugLogger.shared.log("[MarketBridge] refresh rows=\(count)")
        return WebBridgeResponse.ok(request.id, data: ["queued": true, "count": count])
    }

    /// market.openDetail {file}：按 file 反查 MetaItem → DetailRouter 全屏 K 线图
    private static func openDetail(file: String, id: String) -> [String: Any] {
        guard let meta = DatabaseManager.shared.metaList.first(where: { $0.file == file }) else {
            return WebBridgeResponse.fail(id, code: "invalid_payload",
                                          message: "未找到标的 \(file)")
        }
        DetailRouter.shared.item = meta
        DebugLogger.shared.log("[MarketBridge] openDetail \(file)")
        return WebBridgeResponse.ok(id)
    }

    // MARK: - 加自选（AddToGroupSheet 的 Vant 化等价交互）

    /// market.groupInfo {file}：一键自选标记 + 手动分组列表（含成员态，浮层打开时拉取）
    private static func groupInfo(_ request: WebBridgeRequest) -> [String: Any] {
        guard let file = request.payload["file"] as? String,
              let metaID = DatabaseManager.shared.metaList.first(where: { $0.file == file })?.id else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要有效 file")
        }
        let fav = FavoritesStore.shared
        let groupsAny: [[String: Any]] = fav.groups
            .filter { $0.kind == .manual }
            .map { g in
                ["id": g.id.uuidString,
                 "name": g.name,
                 "count": g.manualMetaIDs.count,
                 "member": g.manualMetaIDs.contains(metaID)]
            }
        return WebBridgeResponse.ok(request.id, data: ["isFav": fav.isFavorited(metaID),
                                                       "groups": groupsAny])
    }

    /// market.setFavorite {file, fav}：一键加/取消自选（目标态语义，幂等）
    private static func setFavorite(_ request: WebBridgeRequest) -> [String: Any] {
        guard let file = request.payload["file"] as? String,
              let metaID = DatabaseManager.shared.metaList.first(where: { $0.file == file })?.id,
              let target = request.payload["fav"] as? Bool else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "需要 file 与 fav")
        }
        let fav = FavoritesStore.shared
        if fav.isFavorited(metaID) != target {
            fav.toggleFavorite(metaID)
        }
        shared.notifyChangedNow(reason: "edit")
        return WebBridgeResponse.ok(request.id, data: ["fav": target])
    }

    /// market.setInGroup {file, groupID, member}：加/移出手动分组（目标态语义，幂等）
    private static func setInGroup(_ request: WebBridgeRequest) -> [String: Any] {
        guard let file = request.payload["file"] as? String,
              let metaID = DatabaseManager.shared.metaList.first(where: { $0.file == file })?.id,
              let groupIDString = request.payload["groupID"] as? String,
              let groupID = UUID(uuidString: groupIDString),
              let member = request.payload["member"] as? Bool else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "需要 file、groupID 与 member")
        }
        let fav = FavoritesStore.shared
        guard fav.groups.first(where: { $0.id == groupID })?.kind == .manual else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "分组不存在或非手动分组")
        }
        let isMember = fav.groups.first(where: { $0.id == groupID })?.manualMetaIDs.contains(metaID) ?? false
        if member != isMember {
            if member { fav.addToGroup(id: groupID, metaID: metaID) }
            else { fav.removeFromGroup(id: groupID, metaID: metaID) }
        }
        shared.notifyChangedNow(reason: "edit")
        return WebBridgeResponse.ok(request.id, data: ["member": member])
    }

    /// market.createGroup {name}：新建自定义分组，返回新组 id
    private static func createGroup(_ request: WebBridgeRequest) -> [String: Any] {
        let name = (request.payload["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "name 不能为空")
        }
        let group = FavoritesStore.shared.addGroup(.manual(name: name))
        shared.notifyChangedNow(reason: "edit")
        return WebBridgeResponse.ok(request.id, data: ["id": group.id.uuidString])
    }

    // MARK: - 排序与列配置

    /// market.sortToggle {field}：点击表头三击循环（降→升→取消），语义在原生 toggleSort
    private static func sortToggle(_ request: WebBridgeRequest) -> [String: Any] {
        guard let fieldRaw = request.payload["field"] as? String,
              let field = MarketField(rawValue: fieldRaw) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要有效 field")
        }
        MarketConfigStore.shared.toggleSort(field: field, page: .marketBoard)
        var data: [String: Any] = ["sortField": NSNull(), "sortAsc": false]
        if let rule = MarketConfigStore.shared.sortRule(for: .marketBoard) {
            data = ["sortField": rule.field.rawValue, "sortAsc": rule.order == .ascending]
        }
        shared.notifyChangedNow(reason: "config")
        return WebBridgeResponse.ok(request.id, data: data)
    }

    /// market.configSnapshot：全部可配置列（含隐藏/固定列）+ 排序 + 冻结数 + 各字段筛选档
    static func configSnapshotData() -> [String: Any] {
        let colCfg = MarketConfigStore.shared
        let config = colCfg.config(for: .marketBoard)
        let colsAny: [[String: Any]] = config.columns.map { col in
            let options = col.field.rangeFilterOptions?.map(\.label)
            return [
                "field": col.field.rawValue,
                "title": col.field.title,
                "fixed": col.field.isFixedColumn,
                "visible": col.visible,
                "widthOverride": col.widthOverride.map { Int($0) } ?? NSNull(),
                "filterLabels": col.filterLabels,
                "filterOptions": options ?? NSNull(),
            ]
        }
        var sortRuleAny: Any = NSNull()
        if let rule = config.sortRule {
            sortRuleAny = ["field": rule.field.rawValue, "order": rule.order.rawValue]
        }
        return ["columns": colsAny, "sortRule": sortRuleAny,
                "frozenCount": colCfg.frozenCount(for: .marketBoard)]
    }

    /// market.configSet {columns, sortRule?, frozenCount}：草稿整页写回（幂等目标态）。
    /// columns = 可配置列全集（fixed 列原生侧收敛恒置顶；widthOverride 不在 payload——
    /// 面板不动列宽，保留现有覆盖值）。非固定列顺序按 payload 出现顺序重排。
    private static func configSet(_ request: WebBridgeRequest) -> [String: Any] {
        guard let payloadCols = request.payload["columns"] as? [[String: Any]] else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要 columns")
        }
        let colCfg = MarketConfigStore.shared
        let config = colCfg.config(for: .marketBoard)

        // 解析 payload 列（可配置非固定列）；widthOverride 不在 payload → 保留现有覆盖值
        var ordered: [MarketColumnPref] = []
        for item in payloadCols {
            guard let fieldRaw = item["field"] as? String,
                  let field = MarketField(rawValue: fieldRaw),
                  field.isConfigurable, !field.isFixedColumn else { continue }
            let visible = (item["visible"] as? Bool) ?? false
            let labels = (item["filterLabels"] as? [String]) ?? []
            let currentOverride = config.columns.first(where: { $0.field == field })?.widthOverride
            ordered.append(MarketColumnPref(field: field, visible: visible,
                                            widthOverride: currentOverride, filterLabels: labels))
        }
        // 未出现在 payload 的既有可配置列：保持原 pref 追加在后（防丢）
        let payloadFields = Set(ordered.map(\.field))
        for col in config.columns where col.field.isConfigurable && !col.field.isFixedColumn {
            if !payloadFields.contains(col.field) { ordered.append(col) }
        }
        // fixed 列取自原配置（normalized 保证存在、恒置顶）
        var finalCols: [MarketColumnPref] = []
        for f in MarketField.fixedColumns {
            if let col = config.columns.first(where: { $0.field == f }) { finalCols.append(col) }
        }
        finalCols.append(contentsOf: ordered)

        var next = MarketPageConfig(columns: finalCols, sortRule: config.sortRule,
                                    frozenCount: config.frozenCount)

        // 排序（可选；payload 带 sortRule 键但形状无效 = 取消排序）
        if let ruleDict = request.payload["sortRule"] as? [String: Any],
           let fieldRaw = ruleDict["field"] as? String,
           let field = MarketField(rawValue: fieldRaw),
           let orderRaw = ruleDict["order"] as? String,
           let order = SortOrder(rawValue: orderRaw) {
            next.sortRule = MarketSortRule(field: field, order: order)
        } else if request.payload.keys.contains("sortRule") {
            next.sortRule = nil
        }

        // 冻结列数（1~3 钳制）
        if let frozen = request.payload["frozenCount"] as? Int {
            next.frozenCount = min(3, max(1, frozen))
        }

        colCfg.update(.marketBoard, config: next)
        shared.notifyChangedNow(reason: "config")
        return WebBridgeResponse.ok(request.id)
    }
}

// MARK: - 行情 Tab 的 Web 宿主（WebTabHostView + 原生浮层挂载）

/// 行情页 Tab 内容的混合宿主：Web 表格主体 + 原生全屏浮层（搜索页 / 公式中心）。
/// 浮层状态由 MarketBridge 持有（market.openSearch / openFormulaCenter 写入），
/// 关闭走浮层内返回按钮写回 false。P2-2 不引入 Web 弹层容器（那是 P2-5 的机制）。
struct MarketWebShellView: View {
    @ObservedObject private var bridge = MarketBridge.shared

    var body: some View {
        WebTabHostView(route: "market")
            .overlay {
                if bridge.homeSearchActive {
                    // 复用 HomeView 搜索模式（与原生行情页同款）：selectedTab 传常量 2 不改底栏选中态
                    HomeView(isSearching: $bridge.homeSearchActive, isProfilePresented: .constant(false),
                             selectedTab: .constant(2))
                        .transition(.opacity)
                }
                if bridge.showFormulaCenter {
                    ZStack {
                        FormulaCenterView(initialKind: .picker,
                                          onClose: { bridge.showFormulaCenter = false })
                    }
                    .transition(.opacity)
                    .zIndex(1000)
                }
            }
    }
}

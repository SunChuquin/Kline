//
//  CondBridge.swift
//  Kline
//
//  条件单桥（协议 v2 cond.*）：P2-9a 条件单管理页 / 编辑器 Web 化的 Swift 侧。
//
//  呈现链（两个 activePage 名共用 route:"page" 同一 WebView，Web 端按 page.open 切面板）：
//   - sim.openCondManage → requestList → "condManage"（三分段列表）
//   - sim.openCondEditor {positionID} → 异步组装可卖数量 → requestEditor(position) → "condEditor"
//   - 管理页「编辑」→ cond.edit / 「新建」→ cond.new（同一 WebView 内 activeName 切换，无缝）
//   - 保存成功 → WebPageBridge.open("condManage") 切回列表（无需销毁重建）
//
//  draft 传输：Web 端与原生走 SimCondOrder 的 JSON 口径（iso8601 日期，与 sim.json 落库
//  同构）——snapshot 下发 editing 单据原样 JSON，Web 端改字段原样回传，原生 ISO8601
//  JSONDecoder 解码（逐项兜底，旧字段缺失不炸）。
//
//  校验/文案：validateCondCreate 走引擎（async fail-closed）；条件摘要/指令/有效期文案
//  走 SimRulesProjection 缓存（request 异步投递）→ 订阅 objectWillChange 在缓存更新后
//  重推最新 evaluate 结果（占位 → 就绪的两段式呈现，对齐原生观察模式）。
//
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Combine
import Foundation

@MainActor
final class CondBridge: ObservableObject {

    static let shared = CondBridge()

    // MARK: - 模式状态

    /// 列表页账户上下文（sim.openCondManage 时锁定）
    private(set) var listAccountID: UUID? = nil

    /// 编辑器上下文（"condEditor" 页的数据源）
    struct EditorContext {
        let accountID: UUID
        let metaID: Int
        let code: String
        let name: String
        let initialKind: SimCondKind
        let initialDirection: SimOrderDirection
        let initialQty: Int
        let initialPrice: Double?
        let editing: SimCondOrder?
        /// 校验用持仓（新建/编辑同账户同标的；无持仓 nil）
        let position: SimPosition?
    }

    private(set) var editor: EditorContext? = nil

    /// 最近一次 evaluate 的 draft（投影缓存更新后重算推送用）
    private var lastDraft: SimCondOrder? = nil

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // 投影文案缓存更新 → 重推最近一次 evaluate（占位 → 就绪两段式）
        SimRulesProjection.shared.objectWillChange
            .sink { [weak self] _ in self?.republishIfPending() }
            .store(in: &cancellables)
    }

    // MARK: - 打开入口

    /// sim.openCondManage：条件单管理页（Web）
    func requestList() {
        listAccountID = SimulationBridge.shared.model.orderAccountID
        WebPageBridge.shared.open("condManage")
    }

    /// sim.openCondEditor {positionID}：持仓行入口（可卖数量异步组装后呈现，对齐原生）
    func requestEditor(position: SimPosition) {
        let projection = SimTradeRulesProjection.shared
        Task { @MainActor in
            let qty = await projection.sellableQtyAsync(position: position) ?? projection.lotSize
            openEditor(EditorContext(
                accountID: position.accountID,
                metaID: position.metaID,
                code: position.code,
                name: position.name,
                initialKind: .stopLoss,
                initialDirection: .sell,
                initialQty: qty > 0 ? qty : projection.lotSize,
                initialPrice: position.costPrice,
                editing: nil,
                position: position))
        }
    }

    /// 管理页「编辑」既有单据
    func requestEditor(existing: SimCondOrder) {
        let position = SimStore.shared.position(accountID: existing.accountID, metaID: existing.metaID)
        openEditor(EditorContext(
            accountID: existing.accountID,
            metaID: existing.metaID,
            code: existing.code,
            name: existing.name,
            initialKind: existing.kind,
            initialDirection: existing.directive.direction,
            initialQty: existing.directive.qty,
            initialPrice: nil,
            editing: existing,
            position: position))
    }

    /// 管理页「新建」（默认标的同下单口径）
    func requestNew() {
        let model = SimulationBridge.shared.model
        guard let accountID = model.orderAccountID else {
            WebMessageRouter.shared.pushEvent("cond.changed",
                                              payload: ["reason": "newFailed", "message": "请先新建一个模拟账户"],
                                              route: "page")
            return
        }
        guard let target = model.defaultTarget(accountID: accountID) else {
            WebMessageRouter.shared.pushEvent("cond.changed",
                                              payload: ["reason": "newFailed", "message": "暂无可用标的"],
                                              route: "page")
            return
        }
        openEditor(EditorContext(
            accountID: accountID,
            metaID: target.metaID,
            code: target.code,
            name: target.name,
            initialKind: .price,
            initialDirection: .buy,
            initialQty: SimTradeRuleConstants.lotSize,
            initialPrice: nil,
            editing: nil,
            position: SimStore.shared.positions(accountID: accountID)
                .first(where: { $0.metaID == target.metaID })))
    }

    private func openEditor(_ context: EditorContext) {
        editor = context
        lastDraft = nil
        WebPageBridge.shared.open("condEditor")
        // 编辑单据的文案预热（投影缓存，首次 evaluate 前就绪）
        if let existing = context.editing {
            SimRulesProjection.shared.request(existing)
        }
    }

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "list":
            return list(request)
        case "editorContext":
            return editorContext(request)
        case "evaluate":
            return evaluate(request)
        case "save":
            return save(request)
        case "cancel":
            return cancel(request)
        case "edit":
            return edit(request)
        case "new":
            shared.requestNew()
            return WebBridgeResponse.ok(request.id)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "cond.\(request.action) 未实现")
        }
    }

    // MARK: 列表快照（管理页）

    /// cond.list：当前账户条件单按三分段分组 + 行文案（投影缓存直读；未就绪为占位，
    /// 缓存更新后经 cond.changed(texts) 重推）。
    private static func list(_ request: WebBridgeRequest) -> [String: Any] {
        let accountID = shared.listAccountID
        let orders = SimStore.shared.condOrders(accountID: accountID)
        let engineReady = KlinePythonBridge.shared.isReady

        let rowsAny: [[String: Any]] = orders.map { order in
            let projection = SimRulesProjection.shared
            let directiveLine: String
            let validity = projection.validitySummary(order)
            if order.directive.isAlertOnly {
                directiveLine = "触发后只记录预警（不下单） · \(validity)"
            } else {
                directiveLine = "\(projection.directiveSummary(order)) · \(validity)"
            }
            return [
                "id": order.id.uuidString,
                "name": order.name,
                "code": order.code,
                "kind": order.kind.rawValue,
                "kindTitle": order.kind.title,
                "status": order.status.rawValue,
                "statusTitle": order.status.title,
                "isAlertOnly": order.directive.isAlertOnly,
                "repeatable": order.kind.repeatable,
                "conditionSummary": projection.conditionSummary(order),
                "directiveLine": directiveLine,
                "progressDone": order.kind == .grid ? (order.runtime.gridLevel ?? 0) : order.runtime.batchDone,
                "progressTotal": order.kind == .grid
                    ? (projection.gridLevelCountIfReady(order) ?? -1)
                    : (order.params.batchCount ?? 0),
                "hasProgressTotal": order.kind == .grid
                    ? projection.gridLevelCountIfReady(order) != nil
                    : (order.params.batchCount != nil),
                "lastMessage": order.runtime.lastMessage,
            ]
        }

        // 投影预热：全部单据入队（文案缓存就绪后 cond.changed(texts) 重推）
        for order in orders { SimRulesProjection.shared.request(order) }

        return WebBridgeResponse.ok(request.id, data: [
            "accountID": accountID?.uuidString ?? "",
            "engineReady": engineReady,
            "orders": rowsAny,
        ])
    }

    // MARK: 编辑器上下文

    /// cond.editorContext：编辑器初始化（账户/标的/最新价/持仓/编辑单据 JSON/费率常量集）。
    /// editing 的 JSON 与 sim.json 落库同口径（iso8601），Web 端改字段原样回传。
    private static func editorContext(_ request: WebBridgeRequest) -> [String: Any] {
        guard let ctx = shared.editor else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "编辑器上下文不存在，请重新进入")
        }
        let row = MarketRowCache.shared.rows[ctx.metaID]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let editingJSON = ctx.editing.flatMap { try? encoder.encode($0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }

        return WebBridgeResponse.ok(request.id, data: [
            "account": ["id": ctx.accountID.uuidString,
                        "cash": SimStore.shared.account(id: ctx.accountID)?.cash ?? 0],
            "meta": ["metaID": ctx.metaID, "code": ctx.code, "name": ctx.name],
            "lastPrice": row?.number(.latestPrice) ?? NSNull(),
            "initial": [
                "kind": ctx.initialKind.rawValue,
                "direction": ctx.initialDirection.rawValue,
                "qty": ctx.initialQty,
                "price": ctx.initialPrice ?? NSNull(),
            ],
            "editing": editingJSON ?? NSNull(),
            "rules": [
                "lotSize": SimTradeRuleConstants.lotSize,
                "priceTick": SimTradeRuleConstants.priceTick,
            ],
        ])
    }

    // MARK: draft 解码

    /// Web 端 draft JSON（SimCondOrder 同构）→ SimCondOrder（iso8601 解码，逐项兜底）。
    /// accountID/metaID/code/name 等上下文字段以编辑器上下文为准（防 Web 伪造）。
    private static func decodeDraft(_ raw: Any?) -> SimCondOrder? {
        guard let obj = raw else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var order = try? decoder.decode(SimCondOrder.self, from: data) else { return nil }
        guard let ctx = shared.editor else { return nil }
        order.accountID = ctx.accountID
        order.metaID = ctx.metaID
        order.code = ctx.code
        order.name = ctx.name
        if order.id == UUID(uuidString: "00000000-0000-0000-0000-000000000000") {
            order.id = UUID()
        }
        return order
    }

    // MARK: 校验 + 文案（异步）

    /// cond.evaluate {draft}：引擎建单校验（fail-closed）+ 投影文案。异步完成后推
    /// cond.changed(evaluate)：{ready, rejection, previewSentence, conditionSummary,
    /// directiveSummary, validitySummary}。投影缓存后续更新会自动重推（占位 → 就绪）。
    private static func evaluate(_ request: WebBridgeRequest) -> [String: Any] {
        guard let draft = decodeDraft(request.payload["draft"]) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "draft 解析失败")
        }
        shared.lastDraft = draft
        SimRulesProjection.shared.request(draft)   // 文案预热（异步防抖）
        Task { @MainActor in
            await shared.evaluateAndPush(draft)
        }
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    private nonisolated func evaluateAndPush(_ draft: SimCondOrder) async {
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.evaluateAndPushMain(draft)
        }
    }

    private func evaluateAndPushMain(_ draft: SimCondOrder) {
        let store = SimStore.shared
        guard let account = store.account(id: draft.accountID) else {
            pushEvaluate(draft: draft, rejection: "账户不可用")
            return
        }
        let snapshot = SimCondSnapshotCenter.snapshot(for: draft)
        Task { @MainActor in
            do {
                let rejection = try await SimRulesBridge.validateCondCreate(
                    order: draft, account: account, position: self.editor?.position,
                    snapshot: snapshot, now: Date())
                self.pushEvaluate(draft: draft, rejection: rejection?.message)
            } catch {
                DebugLogger.shared.log("[CondBridge] evaluate 引擎不可用 \(error)")
                self.pushEvaluate(draft: draft,
                                  rejection: SimCondRejection.engineUnavailable.message)
            }
        }
    }

    /// 组装 evaluate 推送（rejection + 投影文案缓存）
    private func pushEvaluate(draft: SimCondOrder, rejection: String?) {
        let projection = SimRulesProjection.shared
        WebMessageRouter.shared.pushEvent("cond.changed", payload: [
            "reason": "evaluate",
            "draftID": draft.id.uuidString,
            "ready": true,
            "rejection": rejection ?? "",
            "previewSentence": draft.directive.isAlertOnly
                ? "当 \(draft.name) \(projection.conditionSummary(draft)) 时，只记录预警（不下单），\(projection.validitySummary(draft))"
                : projection.previewSentence(draft),
            "conditionSummary": projection.conditionSummary(draft),
            "directiveSummary": projection.directiveSummary(draft),
            "validitySummary": projection.validitySummary(draft),
        ], route: "page")
    }

    /// 投影文案缓存更新 → 若有待呈现的 evaluate 则重推（文案从占位到就绪）
    private func republishIfPending() {
        guard let draft = lastDraft else { return }
        pushEvaluate(draft: draft, rejection: nil)
    }

    // MARK: 保存

    /// cond.save {draft}：引擎终校（fail-closed）→ upsertCondOrder → 成功切回管理页；
    /// 失败推 changed(saveResult, error)。
    private static func save(_ request: WebBridgeRequest) -> [String: Any] {
        guard let draft = decodeDraft(request.payload["draft"]) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "draft 解析失败")
        }
        Task { @MainActor in
            var payload: [String: Any] = ["reason": "saveResult", "ok": false, "error": ""]
            do {
                guard let account = SimStore.shared.account(id: draft.accountID) else {
                    payload["error"] = "账户不可用"
                    WebMessageRouter.shared.pushEvent("cond.changed", payload: payload, route: "page")
                    return
                }
                let snapshot = SimCondSnapshotCenter.snapshot(for: draft)
                let rejection = try await SimRulesBridge.validateCondCreate(
                    order: draft, account: account,
                    position: shared.editor?.position, snapshot: snapshot, now: Date())
                if let rejection {
                    payload["error"] = rejection.message
                    WebMessageRouter.shared.pushEvent("cond.changed", payload: payload, route: "page")
                    return
                }
            } catch {
                payload["error"] = "Python 引擎不可用，暂不能保存，请稍后重试"
                WebMessageRouter.shared.pushEvent("cond.changed", payload: payload, route: "page")
                return
            }
            await SimStore.shared.upsertCondOrder(draft)
            DebugLogger.shared.log("[CondBridge] saved cond \(draft.name) id=\(draft.id)")
            WebPageBridge.shared.open("condManage")   // 切回管理页（同一 WebView 无缝）
            WebMessageRouter.shared.pushEvent("cond.changed",
                                              payload: ["reason": "saveResult", "ok": true, "error": ""],
                                              route: "page")
        }
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    // MARK: 撤销 / 编辑 / 新建（管理页动作）

    /// cond.cancel {id}：监控中单据撤销（status → cancelled）
    private static func cancel(_ request: WebBridgeRequest) -> [String: Any] {
        guard let raw = request.payload["id"] as? String, let id = UUID(uuidString: raw),
              var order = SimStore.shared.condOrders(accountID: shared.listAccountID)
                  .first(where: { $0.id == id }) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要有效 id")
        }
        order.status = .cancelled
        order.updatedAt = Date()
        Task { @MainActor in
            await SimStore.shared.upsertCondOrder(order)
            WebMessageRouter.shared.pushEvent("cond.changed", payload: ["reason": "list"], route: "page")
        }
        return WebBridgeResponse.ok(request.id)
    }

    /// cond.edit {id}：管理页点编辑 → 切编辑器页（同一 WebView）
    private static func edit(_ request: WebBridgeRequest) -> [String: Any] {
        guard let raw = request.payload["id"] as? String, let id = UUID(uuidString: raw),
              let order = SimStore.shared.condOrders(accountID: shared.listAccountID)
                  .first(where: { $0.id == id }) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要有效 id")
        }
        shared.requestEditor(existing: order)
        return WebBridgeResponse.ok(request.id)
    }
}

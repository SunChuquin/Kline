//
//  StrategyDetailBridge.swift
//  Kline
//
//  策略详情页桥（协议 v2 strategyDetail.*）：P2-9c 策略详情 / 跑选股 / 生成确认 Web 化的 Swift 侧。
//
//  呈现链：原生 FormulaCenterView 策略段「详情」→ requestOpen(doc) →
//  WebPageBridge.open("strategyDetail") 全屏 Web 页（route:"page"，shell 层呈现——
//  入口只在 Home/Sim shell 的公式中心）。原生详情页（StrategyDetailView）保留可回退。
//
//  取值分两段（对齐原生 StrategyDetailView 的 E 组口径）：
//  - 基础信息（绑定账户 / 交易指令可用性）纯 Swift 同步，snapshot 直接返回；
//  - 引擎取值（选股摘要 / 交易摘要 / 规则解析与触发文案）后台异步取
//    （SimRulesBridge.strategyPreview + strategyParse），经 strategyDetail.changed(values)
//    推送——占位→就绪两段式；引擎不可用推 unavailable:true（§9.10 显式降级，不静默兜底）。
//
//  执行侧（P2-9c-3 pickRun，对齐原生 StrategyDetailView → StrategyPickListView / StrategyGenConfirmView）：
//  - 跑选股：runPick {pool} 启动 StrategyPickRunner（全局单例，两段式进度），phase/hits
//    订阅转发 changed(pickPhase/pickHits)；cancelPick 幂等取消。
//  - 生成确认：generate {metaIDs, includeEntry} 经 StrategyCondGenerator 组装草稿（引擎校验），
//    changed(genConfirm) 推送（草稿文案走 SimRulesProjection 缓存，投影就绪后重推——
//    CondBridge 同款两段式）；toggleEntry 重新组装；confirmGenerate 一次性落盘
//    （SimStore.upsertCondOrders），成功暂存 toast 并切回 strategyDetail。
//
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Combine
import Foundation

@MainActor
final class StrategyDetailBridge: ObservableObject {

    static let shared = StrategyDetailBridge()

    /// 展示中的策略文档（打开前暂存）
    private(set) var doc: FormulaDoc = FormulaDoc(id: "", kind: .strategy, name: "")

    /// 生成确认页 toast（写库成功后的「已生成 N 条」，经 snapshot 带给 strategyDetail 面板，取走即清）
    private(set) var pendingToast: String? = nil

    /// 最近一次组装的生成草稿（confirmGenerate 的输入；generate/toggleEntry 覆盖）
    private var genOutcome: StrategyGenOutcome? = nil
    /// 最近一次参与组装的标的（toggleEntry 重新组装的输入）
    private var genMetas: [MetaItem]? = nil
    /// 当前确认页的入场单开关（toggleEntry 后重推 genConfirm 带回）
    private var genIncludeEntry = false
    /// genConfirm 是否已推送过（投影缓存更新后据此重推）
    private var genConfirmPublished = false

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // 跑选股执行器：phase / hits 变化 → changed(pickPhase / pickHits)（route:"page"）
        StrategyPickRunner.shared.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                guard self != nil else { return }
                let runner = StrategyPickRunner.shared
                WebMessageRouter.shared.pushEvent(
                    "strategyDetail.changed",
                    payload: ["reason": "pickPhase",
                              "phase": Self.phaseAny(phase),
                              "prepareTimedOut": runner.prepareTimedOut],
                    route: "page")
            }
            .store(in: &cancellables)

        StrategyPickRunner.shared.$hits
            .removeDuplicates()
            .sink { [weak self] hits in
                _ = self
                WebMessageRouter.shared.pushEvent(
                    "strategyDetail.changed",
                    payload: ["reason": "pickHits",
                              "hits": hits.map(Self.hitAny),
                              "count": hits.count],
                    route: "page")
            }
            .store(in: &cancellables)

        // 草稿文案投影缓存更新 → 重推 genConfirm（占位 → 就绪两段式，CondBridge 同款）
        SimRulesProjection.shared.objectWillChange
            .sink { [weak self] _ in self?.republishGenConfirmIfPending() }
            .store(in: &cancellables)
    }

    // MARK: - 打开

    /// 原生公式中心策略段「详情」入口：暂存文档 → 打开全屏 Web 详情页
    func requestOpen(initialDoc: FormulaDoc) {
        doc = initialDoc
        WebPageBridge.shared.open("strategyDetail")
    }

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "snapshot":
            return snapshot(request)
        case "edit":
            return edit(request)
        case "backtest":
            return backtest(request)
        case "runPick":
            return runPick(request)
        case "cancelPick":
            StrategyPickRunner.shared.cancel()
            return WebBridgeResponse.ok(request.id)
        case "generate":
            return generate(request)
        case "toggleEntry":
            return toggleEntry(request)
        case "confirmGenerate":
            return confirmGenerate(request)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "strategyDetail.\(request.action) 未实现")
        }
    }

    // MARK: 快照

    /// strategyDetail.snapshot：基础信息同步返回（纯 Swift，零延迟）；引擎取值排队异步推。
    /// 绑定账户 / 失效数口径与原生 StrategyDetailView 一致（按 accountIDs 顺序解析）。
    /// toast：写库成功后的提示条（一次性带出，取走即清）。
    private static func snapshot(_ request: WebBridgeRequest) -> [String: Any] {
        let d = shared.doc
        let sim = SimStore.shared
        let boundNames = d.trade.accountIDs.compactMap { id in sim.accounts.first { $0.id == id }?.name }
        let missing = d.trade.accountIDs.filter { id in !sim.accounts.contains { $0.id == id } }.count
        let toast = shared.pendingToast
        shared.pendingToast = nil
        shared.pushEngineValues()
        return WebBridgeResponse.ok(request.id, data: [
            "id": d.id,
            "name": d.name,
            "tradeConfigured": !d.trade.isEmpty || !d.trade.accountIDs.isEmpty,
            "canGenerate": !d.trade.isEmpty && !d.trade.accountIDs.isEmpty,
            "boundAccounts": boundNames,
            "missingCount": missing,
            "valuesQueued": true,
            "toast": toast ?? "",
        ])
    }

    /// 引擎取值（选股摘要 / 交易摘要 / 规则解析与触发文案），推 strategyDetail.changed(values)。
    /// 引擎不可用 / 出参形状非法 → unavailable:true（原生同款显式降级）。
    private func pushEngineValues() {
        let d = doc
        let pickerName = FormulaLibraryStore.shared.pickerName(id: d.pickRef)
        Task { @MainActor in
            var payload: [String: Any] = ["reason": "values"]
            do {
                let preview = try await SimRulesBridge.strategyPreview(doc: d, pickerName: pickerName)
                let parse = try await SimRulesBridge.strategyParse(lines: d.rules)
                // 规则行触发文案：取 strategy_preview.triggers（与解析结果同序，一次请求全取）
                let rulesAny: [[String: Any]] = parse.rules.enumerated().map { index, call in
                    ["kindTitle": call.kind.title,
                     "trigger": index < preview.triggers.count ? preview.triggers[index] : "…"]
                }
                payload["pickSummary"] = preview.pick
                payload["tradeSummary"] = preview.trade
                payload["rules"] = rulesAny
                payload["parseErrors"] = parse.errors
                payload["unavailable"] = false
            } catch {
                payload["unavailable"] = true
            }
            WebMessageRouter.shared.pushEvent("strategyDetail.changed", payload: payload, route: "page")
        }
    }

    // MARK: 跳转

    /// strategyDetail.edit：Web 页内切策略编辑器（activePage 切 strategyEditor，同 WebView 无缝）
    private static func edit(_ request: WebBridgeRequest) -> [String: Any] {
        StrategyEditorBridge.shared.requestOpen(initialDoc: shared.doc)
        return WebBridgeResponse.ok(request.id)
    }

    /// strategyDetail.backtest：Web 页内切回测页（BacktestBridge.open → activePage 切 backtest）
    private static func backtest(_ request: WebBridgeRequest) -> [String: Any] {
        BacktestBridge.shared.open(doc: shared.doc)
        return WebBridgeResponse.ok(request.id)
    }

    // MARK: 跑选股（StrategyPickRunner 订阅转发）

    /// strategyDetail.runPick {pool}：启动跑选股（pool: market|favorites）。
    /// 进度 / 命中由 init 里的订阅转发（pickPhase / pickHits）。
    private static func runPick(_ request: WebBridgeRequest) -> [String: Any] {
        let poolRaw = request.payload["pool"] as? String ?? "market"
        guard let pool = StrategyPickPool(rawValue: poolRaw) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "pool 必须为 market / favorites")
        }
        StrategyPickRunner.shared.start(doc: shared.doc, pool: pool)
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    private static func phaseAny(_ phase: StrategyPickRunner.Phase) -> [String: Any] {
        switch phase {
        case .idle:                     return ["state": "idle"]
        case .preparing(let d, let t):  return ["state": "preparing", "done": d, "total": t]
        case .running(let d, let t):    return ["state": "running", "done": d, "total": t]
        case .finished:                 return ["state": "finished"]
        case .cancelled:                return ["state": "cancelled"]
        }
    }

    private static func hitAny(_ hit: StrategyPickHit) -> [String: Any] {
        var any: [String: Any] = ["metaID": hit.metaID, "code": hit.code, "name": hit.name]
        if let p = hit.lastPrice { any["lastPrice"] = p }
        if let c = hit.changePct { any["changePct"] = c }
        return any
    }

    // MARK: 生成确认（StrategyCondGenerator 组装 → SimStore 落盘）

    /// strategyDetail.generate {metaIDs, includeEntry?}：metaID 还原标的 → 组装草稿（引擎校验）
    /// → changed(genConfirm)（文案占位 → 投影就绪重推）。
    private static func generate(_ request: WebBridgeRequest) -> [String: Any] {
        let ids = (request.payload["metaIDs"] as? [Int]) ?? []
        let metas = ids.compactMap { id in DatabaseManager.shared.metaList.first { $0.id == id } }
        guard !metas.isEmpty else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "勾选标的无效")
        }
        let includeEntry = request.payload["includeEntry"] as? Bool ?? false
        shared.buildGenConfirm(metas: metas, includeEntry: includeEntry)
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    /// strategyDetail.toggleEntry {includeEntry}：切换入场单开关，重新组装（原生 recompute 同款）
    private static func toggleEntry(_ request: WebBridgeRequest) -> [String: Any] {
        guard let metas = shared.genMetas else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "尚未组装生成草稿")
        }
        let includeEntry = request.payload["includeEntry"] as? Bool ?? false
        shared.buildGenConfirm(metas: metas, includeEntry: includeEntry)
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    /// strategyDetail.confirmGenerate {}：一次性落盘（写 0 条视为失败）。
    /// 成功：暂存 toast + 切回 strategyDetail（面板经 snapshot 取 toast 显示）；
    /// 失败：changed(genResult) 推回 pickRun 页显示错误文案。
    private static func confirmGenerate(_ request: WebBridgeRequest) -> [String: Any] {
        shared.writeGenDrafts()
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    /// 组装生成草稿（异步引擎校验；结果推 genConfirm）
    private func buildGenConfirm(metas: [MetaItem], includeEntry: Bool) {
        genMetas = metas
        genIncludeEntry = includeEntry
        let d = doc
        let accountIDs = d.trade.accountIDs
        Task { @MainActor in
            let outcome = await StrategyCondGenerator.generate(
                doc: d, metas: metas, includeEntry: includeEntry, accountIDs: accountIDs)
            genOutcome = outcome
            genConfirmPublished = true
            // 文案预热（异步防抖；缓存就绪后 objectWillChange → 重推 genConfirm）
            SimRulesProjection.shared.request(outcome.drafts.map { $0.order() })
            republishGenConfirm()
        }
    }

    /// 组包 genConfirm（分组 / 跳过 / 概览口径对齐原生 StrategyGenConfirmView）
    private func republishGenConfirm() {
        guard let outcome = genOutcome, let metas = genMetas else { return }
        let sim = SimStore.shared
        let projection = SimRulesProjection.shared

        // 按账户分组（保持出现顺序；原生 draftGroups 同款）
        var order: [UUID] = []
        var map: [UUID: [StrategyCondDraft]] = [:]
        for draft in outcome.drafts {
            if map[draft.accountID] == nil { order.append(draft.accountID) }
            map[draft.accountID, default: []].append(draft)
        }
        let groupsAny: [[String: Any]] = order.map { id in
            ["id": id.uuidString,
             "name": sim.account(id: id)?.name ?? "已失效账户",
             "items": (map[id] ?? []).map { draft in
                 ["draftID": draft.id.uuidString,
                  "name": draft.name, "code": draft.code,
                  "kindTitle": draft.kind.title,
                  "sentence": projection.previewSentence(draft.order())]
             }]
        }

        WebMessageRouter.shared.pushEvent(
            "strategyDetail.changed",
            payload: ["reason": "genConfirm",
                      "groups": groupsAny,
                      "skips": outcome.skips.map { ["title": $0.title, "reason": $0.reason] },
                      "draftCount": outcome.drafts.count,
                      "skipCount": outcome.skips.count,
                      "truncatedByLimit": outcome.truncatedByLimit,
                      "canToggleEntry": doc.trade.direction != nil,
                      "includeEntry": genIncludeEntry,
                      "metaCount": metas.count],
            route: "page")
    }

    /// 投影缓存更新后的重推入口（genConfirm 已推送过才重推）
    private func republishGenConfirmIfPending() {
        guard genConfirmPublished else { return }
        republishGenConfirm()
    }

    /// 确认写入（异步；写 0 条视为失败）
    private func writeGenDrafts() {
        Task { @MainActor in
            guard let outcome = genOutcome, !outcome.drafts.isEmpty else {
                WebMessageRouter.shared.pushEvent("strategyDetail.changed",
                                                  payload: ["reason": "genResult", "written": 0],
                                                  route: "page")
                return
            }
            let written = await SimStore.shared.upsertCondOrders(outcome.drafts.map { $0.order() })
            if written > 0 {
                pendingToast = "已生成 \(written) 条条件单"
                genOutcome = nil
                genMetas = nil
                genConfirmPublished = false
                WebPageBridge.shared.open("strategyDetail")
            } else {
                WebMessageRouter.shared.pushEvent("strategyDetail.changed",
                                                  payload: ["reason": "genResult", "written": 0],
                                                  route: "page")
            }
        }
    }
}

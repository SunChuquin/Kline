//
//  StrategyDetailBridge.swift
//  Kline
//
//  策略详情页桥（协议 v2 strategyDetail.*）：P2-9c 策略详情 Web 化的 Swift 侧。
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
//  执行侧：编辑 → Web 页内切 strategyEditor（StrategyEditorBridge）；回测 → Web 页内切
//  backtest（BacktestBridge）；跑选股 / 生成条件单 → pickRun（StrategyPickRunner，P2-9c-3）。
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
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "strategyDetail.\(request.action) 未实现")
        }
    }

    // MARK: 快照

    /// strategyDetail.snapshot：基础信息同步返回（纯 Swift，零延迟）；引擎取值排队异步推。
    /// 绑定账户 / 失效数口径与原生 StrategyDetailView 一致（按 accountIDs 顺序解析）。
    private static func snapshot(_ request: WebBridgeRequest) -> [String: Any] {
        let d = shared.doc
        let sim = SimStore.shared
        let boundNames = d.trade.accountIDs.compactMap { id in sim.accounts.first { $0.id == id }?.name }
        let missing = d.trade.accountIDs.filter { id in !sim.accounts.contains { $0.id == id } }.count
        shared.pushEngineValues()
        return WebBridgeResponse.ok(request.id, data: [
            "id": d.id,
            "name": d.name,
            "tradeConfigured": !d.trade.isEmpty || !d.trade.accountIDs.isEmpty,
            "canGenerate": !d.trade.isEmpty && !d.trade.accountIDs.isEmpty,
            "boundAccounts": boundNames,
            "missingCount": missing,
            "valuesQueued": true,
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
}

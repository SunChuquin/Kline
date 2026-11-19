//
//  BacktestBridge.swift
//  Kline
//
//  历史回测桥（协议 v2 backtest.*）：P2-6c-2 BacktestParamView / BacktestResultView /
//  NetValueChartView Web 化的 Swift 侧。
//
//  呈现链（对齐原生）：策略详情页「回测」按钮 → 本桥 open(doc)（持有被测文档）→
//  WebPageBridge.open("backtest") 全屏 Web 页；Web 页内三态（参数表单 → 进度 → 结果），
//  phase/result 由 StrategyBacktestRunner（单任务执行器）发布，Web 经快照消费。
//
//  与原生行为对齐：
//   - run：组装 BacktestParams（period 固定日线）→ runner.start(doc:params:)（单任务，
//     重跑先失效旧轮）；Web 收 queued 后切进度页，进度经 backtest.changed 推送（节流 0.25s）
//   - cancel：runner.cancel()；cancelled 后 Web 自动 page.close 回策略详情（原生
//     handleBacktestPhase .cancelled 同语义）
//   - 关闭（closeHook）：运行中先取消再关（对齐原生 closeBacktestRun）
//   - 净值序列 / 成交明细全量下发（Web 端折叠展示，对齐原生「展开全部」交互）
//
//  线程约定：动作入口均在主线程（runner 的 phase 推送本身经主线程 @Published）。
//

import Combine
import SwiftUI

@MainActor
final class BacktestBridge: ObservableObject {

    static let shared = BacktestBridge()

    private let runner = StrategyBacktestRunner.shared

    /// 当前被回测的策略文档（「回测」入口写入；关闭时清空）
    private var currentDoc: FormulaDoc?

    private var cancellables = Set<AnyCancellable>()
    private var changedItem: DispatchWorkItem? = nil
    /// preparing 进度逐只推送，0.25s 节流合并
    private let changedThrottle: TimeInterval = 0.25

    private init() {
        runner.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged("phase") }
            .store(in: &cancellables)
        // 关闭仲裁：运行中先取消再关（对齐原生 closeBacktestRun；回测可安全取消）
        WebPageBridge.shared.closeHooks["backtest"] = { [weak self] in
            guard let self else { return true }
            if self.runner.isRunning { self.runner.cancel() }
            self.currentDoc = nil
            return true
        }
    }

    // MARK: - 呈现入口（策略详情页「回测」按钮）

    /// 打开回测 Web 页（原生 showBacktestParams 分支保留可回退）
    func open(doc: FormulaDoc) {
        currentDoc = doc
        WebPageBridge.shared.open("backtest")
    }

    func onOpen() {
        // 快照即全量状态，无需额外初始化
    }

    // MARK: - 变化信号 → backtest.changed 推送

    private func scheduleChanged(_ reason: String) {
        pendingReason = reason
        guard changedItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.changedItem = nil
            WebMessageRouter.shared.pushEvent("backtest.changed",
                                              payload: ["reason": self.pendingReason])
        }
        changedItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + changedThrottle, execute: item)
    }

    private var pendingReason = "phase"

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "snapshot":
            return WebBridgeResponse.ok(request.id, data: snapshotData())
        case "run":
            return run(request)
        case "cancel":
            shared.runner.cancel()
            DebugLogger.shared.log("[BacktestBridge] cancel")
            return WebBridgeResponse.ok(request.id)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "backtest.\(request.action) 未实现")
        }
    }

    /// backtest.run：组装参数并启动执行器（Web 收 queued 后切进度页，结论经 changed 推送）
    private static func run(_ request: WebBridgeRequest) -> [String: Any] {
        let p = request.payload
        guard let doc = shared.currentDoc else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "回测页未关联策略（请从策略详情页进入）")
        }
        guard let days = (p["days"] as? NSNumber)?.intValue,
              let capital = (p["initialCapital"] as? NSNumber)?.doubleValue,
              let poolRaw = p["pool"] as? String,
              let pool = StrategyPickPool(rawValue: poolRaw),
              let executeNextOpen = p["executeNextOpen"] as? Bool,
              let includeEntry = p["includeEntry"] as? Bool else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "回测参数不完整（days/initialCapital/pool/executeNextOpen/includeEntry）")
        }
        var params = BacktestParams()
        params.days = days
        params.initialCapital = capital > 0 ? capital : 100000
        params.pool = pool
        params.executeNextOpen = executeNextOpen
        params.includeEntry = includeEntry
        DebugLogger.shared.log("[BacktestBridge] run \(doc.name) days=\(days) pool=\(poolRaw)")
        shared.runner.start(doc: doc, params: params)
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    // MARK: - 快照组装（数值原样下发，Web 端按 SimFormat 语义格式化）

    static func snapshotData() -> [String: Any] {
        let bridge = shared

        var docAny: Any = NSNull()
        if let doc = bridge.currentDoc {
            // 参数页默认初始资金：绑定账户的初始资金，取不到用 10 万（对齐原生 BacktestParamView.init）
            let fallback = doc.trade.accountIDs
                .compactMap { id in SimStore.shared.accounts.first { $0.id == id } }
                .first?.initialCapital ?? 100000
            docAny = [
                "id": doc.id,
                "name": doc.name,
                "tradeEmpty": doc.trade.isEmpty,
                "defaultCapital": fallback,
            ]
        }

        let phase = bridge.runner.phase
        var progressAny: Any = NSNull()
        var failMessage: Any = NSNull()
        switch phase {
        case .preparing(let done, let total):
            progressAny = ["done": done, "total": total]
        case .failed(let message):
            failMessage = message
        default:
            break
        }

        var resultAny: Any = NSNull()
        if let result = bridge.runner.result {
            let stats = result.stats
            let statsAny: [String: Any] = [
                "initialCapital": stats.initialCapital,
                "finalEquity": stats.finalEquity,
                "totalReturn": stats.totalReturn,
                "annualized": stats.annualized,
                "winRate": stats.winRate,
                "profitFactor": stats.profitFactor,
                "maxDrawdown": stats.maxDrawdown,
                "tradeCount": stats.tradeCount,
                "roundTrips": stats.roundTrips,
                "avgHoldDays": stats.avgHoldDays,
            ]
            let equityAny: [[String: Any]] = result.equity.map {
                ["date": $0.date, "equity": $0.equity]
            }
            var rangeAny: Any = NSNull()
            if let range = result.maxDrawdownRange {
                rangeAny = [range.lowerBound, range.upperBound]
            }
            let tradesAny: [[String: Any]] = result.trades.map { trade in
                [
                    "date": trade.date,
                    "name": trade.name,
                    "code": trade.code,
                    "direction": trade.direction.rawValue,
                    "rule": trade.ruleKind?.title ?? NSNull(),
                    "qty": trade.qty,
                    "price": trade.price,
                    "amount": trade.amount,
                    "fee": trade.fee,
                    "realizedPnL": trade.realizedPnL ?? NSNull(),
                    "holdDays": trade.holdDays ?? NSNull(),
                ]
            }
            resultAny = [
                "stats": statsAny,
                "equity": equityAny,
                "maxDrawdownRange": rangeAny,
                "trades": tradesAny,
                "scannedCount": result.scannedCount,
                "hitCount": result.hitCount,
                "warnings": result.warnings,
                "skipped": result.skipped,
            ]
        }

        return [
            "doc": docAny,
            "phase": phaseKey(phase),
            "progress": progressAny,
            "failMessage": failMessage,
            "result": resultAny,
        ]
    }

    private static func phaseKey(_ phase: StrategyBacktestRunner.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .simulating: return "simulating"
        case .finished: return "finished"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }
}

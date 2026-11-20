//
//  TicketBridge.swift
//  Kline
//
//  全屏下单页桥（协议 v2 ticket.*）：P2-9a 模拟下单全屏页 Web 化的 Swift 侧。
//
//  呈现链：sim.openTicket {direction, positionID?} → 解析账户/标的（持仓行入口按 positionID、
//  默认入口走 defaultTarget）→ requestOpen 暂存上下文 → WebPageBridge.open("ticket")
//  全屏 Web 页（route:"page"，shell 层呈现；复用池 key "ticket"）。
//
//  票面数据经 ticket.snapshot 下发（账户资金/标的/最新价/持仓可卖/费率规则集）；
//  提交复用既有 trade.submit 动作（快捷面板 Web 票面同款链路，校验/费用/写入全在原生），
//  成功后 Web 端自行关页（全屏页语义 = 提交成功即关闭）。
//
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Combine
import Foundation

@MainActor
final class TicketBridge: ObservableObject {

    static let shared = TicketBridge()

    /// 下单上下文（openTicket 解析后暂存；snapshot 按此组装）
    struct Context {
        let accountID: UUID
        let metaID: Int
        let code: String
        let name: String
        let file: String
        let direction: SimOrderDirection
        /// 持仓行入口时带持仓（预填卖出 + 可卖数量）；默认入口 nil
        let position: SimPosition?
    }

    private(set) var context: Context? = nil

    // MARK: - 打开

    /// sim.openTicket 解析成功后调用：暂存上下文 → 打开全屏 Web 票面页
    func requestOpen(accountID: UUID, metaID: Int, code: String, name: String,
                     direction: SimOrderDirection, position: SimPosition?) {
        let meta = DatabaseManager.shared.metaList.first(where: { $0.id == metaID })
        context = Context(accountID: accountID, metaID: metaID, code: code, name: name,
                          file: meta?.file ?? "", direction: direction, position: position)
        WebPageBridge.shared.open("ticket")
    }

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "snapshot":
            return snapshot(request)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "ticket.\(request.action) 未实现")
        }
    }

    // MARK: 快照

    /// ticket.snapshot：票面初始化数据（账户/标的/最新价/持仓/费率规则集）。
    /// 仓位快捷、费用合计、可买可卖提示均由 Web 端按 rules 参数计算（纯算术）。
    private static func snapshot(_ request: WebBridgeRequest) -> [String: Any] {
        guard let ctx = shared.context else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "下单上下文不存在，请重新进入下单页")
        }
        let store = SimStore.shared
        guard let account = store.accounts.first(where: { $0.id == ctx.accountID }) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "账户不存在")
        }
        let row = MarketRowCache.shared.rows[ctx.metaID]
        let lastPrice = row?.number(.latestPrice)

        let positionAny: [String: Any]? = ctx.position.map {
            ["qty": $0.qty, "availableQty": $0.availableQty, "costPrice": $0.costPrice]
        }

        return WebBridgeResponse.ok(request.id, data: [
            "account": ["id": ctx.accountID.uuidString, "name": account.name, "cash": account.cash],
            "meta": ["metaID": ctx.metaID, "code": ctx.code, "name": ctx.name, "file": ctx.file],
            "lastPrice": lastPrice ?? NSNull(),
            "initialDirection": ctx.direction.rawValue,
            "position": positionAny ?? NSNull(),
            // 费率常量集（真源 sim_rules.py 经 SimTradeRuleConstants 镜像）：仓位快捷/费用合计/
            // 可买可卖由 Web 端按纯算术计算（公式与 SimTradingRules.swift 一致）
            "rules": [
                "lotSize": SimTradeRuleConstants.lotSize,
                "commissionRate": SimTradeRuleConstants.commissionRate,
                "commissionMin": SimTradeRuleConstants.commissionMin,
                "stampTaxRate": SimTradeRuleConstants.stampTaxRate,
                "priceTick": SimTradeRuleConstants.priceTick,
                "limitPct": SimTradeRuleConstants.limitPct,
            ],
        ])
    }
}

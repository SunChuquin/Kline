//
//  QuickBridge.swift
//  Kline
//
//  快捷面板桥（协议 v2 quick.* + trade.*）：P2-6a 悬浮球面板 Web 化的 Swift 侧。
//
//  呈现链路：悬浮球点击（ContentView.isAccessoryPanelPresented）→ 非训练态
//  sheet.open("quick")（Web 面板，SheetWebOverlayHost 常驻浮层）；训练态保留原生面板
//  （QuickTrainingPanelView，训练闭环属 P2-6c Training 批次）。关闭走 sheet.close →
//  closeHandler 回写 isAccessoryPanelPresented。
//
//  三视图状态：view = detail（详情页有标的）/ picked（列表态点自选行买/卖带入票面）/
//  list（列表态）。pickedMeta 由本桥持有（原生 @State pickedMeta 语义迁移）。
//  票面表单（方向/价格/数量）Web 端本地编辑，提交时一次写回 trade.submit——
//  SimStore.submit 精确校验（整手/T+1/资金/涨跌停），拒绝 fail 返回原生中文文案。
//
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Combine
import SwiftUI

@MainActor
final class QuickBridge: ObservableObject {

    static let shared = QuickBridge()

    /// 列表态点自选行「买 / 卖」带入的标的（面板内原地切票面；面板关闭时清空）
    @Published var pickedMeta: MetaItem? = nil
    /// 票面方向（pickTicket 带入，submit 使用；Web 端方向切换为本地 UI 态）
    @Published var pickedDirection: SimOrderDirection = .buy

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "snapshot":
            return WebBridgeResponse.ok(request.id, data: snapshotData())
        case "selectAccount":
            let raw = request.payload["accountID"] as? String
            let uuid = raw.flatMap(UUID.init(uuidString:))
            SimStore.shared.selectedAccountID = uuid
            return WebBridgeResponse.ok(request.id)
        case "pickTicket":
            guard let file = request.payload["file"] as? String,
                  let meta = DatabaseManager.shared.metaList.first(where: { $0.file == file }) else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要有效 file")
            }
            shared.pickedMeta = meta
            shared.pickedDirection = (request.payload["direction"] as? String) == "sell" ? .sell : .buy
            return WebBridgeResponse.ok(request.id)
        case "backToList":
            shared.pickedMeta = nil
            return WebBridgeResponse.ok(request.id)
        case "cancelAll":
            let accountID = SimStore.shared.queryAccountID
            Task {
                let count = await SimStore.shared.cancelAll(accountID: accountID)
                DebugLogger.shared.log("[QuickBridge] cancelAll count=\(count)")
            }
            return WebBridgeResponse.ok(request.id)
        case "closeAll":
            guard let meta = currentMeta() else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "详情标的未就绪")
            }
            guard let accountID = SimStore.shared.selectedAccountID,
                  SimStore.shared.account(id: accountID) != nil else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "请先选择有效的模拟账户")
            }
            let metaID = meta.id
            Task {
                let count = await SimStore.shared.closeAll(accountID: accountID, metaID: metaID)
                DebugLogger.shared.log("[QuickBridge] closeAll count=\(count)")
            }
            return WebBridgeResponse.ok(request.id)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "quick.\(request.action) 未实现")
        }
    }

    // MARK: - trade 模块（下单提交）

    static func handleTrade(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "submit":
            return submit(request)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "trade.\(request.action) 未实现")
        }
    }

    /// trade.submit：SimStore.submit 精确校验（整手/T+1/资金/涨跌停），拒绝 fail 返回中文文案。
    /// 标的定位：metaID（数值）优先；缺省按 file 反查（Web 端快照只持有 file）。
    static func submit(_ request: WebBridgeRequest) -> [String: Any] {
        let p = request.payload
        guard let accountRaw = p["accountID"] as? String, let accountID = UUID(uuidString: accountRaw),
              let directionRaw = p["direction"] as? String, let direction = SimOrderDirection(rawValue: directionRaw),
              let priceTypeRaw = p["priceType"] as? String, let priceType = SimPriceType(rawValue: priceTypeRaw),
              let qty = (p["qty"] as? NSNumber)?.intValue, qty > 0 else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "下单参数不完整")
        }
        // 标的解析：metaID 优先，否则 file 反查
        let meta: MetaItem?
        if let metaRaw = p["metaID"] as? String, let metaID = Int(metaRaw) {
            meta = SimQuoteCenter.meta(metaID: metaID)
        } else if let file = p["file"] as? String {
            meta = DatabaseManager.shared.metaList.first(where: { $0.file == file })
        } else {
            meta = nil
        }
        guard let meta else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "标的不存在")
        }
        let price = (p["price"] as? NSNumber)?.doubleValue
        let draft = SimOrderDraft(accountID: accountID, metaID: meta.id,
                                  code: meta.code, name: meta.name,
                                  direction: direction, priceType: priceType,
                                  price: priceType == .limit ? price : nil, qty: qty)
        let store = SimStore.shared
        // submit 是 async（引擎校验）；结果经 Task 落日志，页面以回读快照与原生侧变化为准
        Task {
            let result = await store.submit(draft)
            if case .failure(let rejection) = result {
                DebugLogger.shared.log("[QuickBridge] submit 被拒: \(rejection.message)")
                WebMessageRouter.shared.pushEvent("sim.changed", payload: ["reason": "submit-rejected"])
            } else {
                DebugLogger.shared.log("[QuickBridge] submit 成功 \(meta.name) \(direction.title) \(qty)")
            }
        }
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    // MARK: - 快照组装

    /// 当前票面标的：详情页标的（DetailRouter）优先，其次 pickedMeta
    static func currentMeta() -> MetaItem? {
        DetailRouter.shared.item ?? shared.pickedMeta
    }

    /// 交易时段文案（简化口径：竞价时段内「连续竞价」，其余「非交易时段」——盘后委托由规则层转待报）
    static func tradingPhase() -> String {
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let morningStart = 9 * 60 + 30, morningEnd = 11 * 60 + 30
        let afternoonStart = 13 * 60, afternoonEnd = 15 * 60
        let inSession = (minutes >= morningStart && minutes <= morningEnd)
            || (minutes >= afternoonStart && minutes <= afternoonEnd)
        return inSession ? "连续竞价" : "非交易时段"
    }

    /// 行行情行（lastPrice/pct；未就绪 null）
    static func quoteOf(_ metaID: Int) -> (price: Any, pct: Any) {
        let price = SimQuoteCenter.lastPrice(metaID: metaID)
        let pct = SimQuoteCenter.meta(metaID: metaID).flatMap {
            MarketRowCache.shared.numberFor($0.id, .changePct)
        }
        return (price ?? NSNull(), pct ?? NSNull())
    }

    /// quick.snapshot：三视图结构化快照（账户/票面上下文/列表态摘要与自选/在途委托）
    static func snapshotData() -> [String: Any] {
        let store = SimStore.shared
        let shared = QuickBridge.shared
        let accountID = store.queryAccountID

        let accountsAny: [[String: Any]] = store.activeAccounts.map { a in
            ["id": a.id.uuidString, "name": a.name, "badge": a.badge, "colorHex": a.colorHex]
        }
        let summary = store.summary(accountID: accountID)

        var view = "list"
        if let meta = currentMeta() {
            view = shared.pickedMeta?.file == meta.file && DetailRouter.shared.item == nil ? "picked" : "detail"
        }

        var detailAny: Any = NSNull()
        if let meta = currentMeta(), view != "list" {
            let quote = quoteOf(meta.id)
            var ticketAny: Any = NSNull()
            if let accountID, store.account(id: accountID) != nil {
                let pos = store.position(accountID: accountID, metaID: meta.id)
                var positionAny: Any = NSNull()
                if let pos {
                    let snap = store.snapshot(for: pos)
                    positionAny = ["qty": pos.qty, "availableQty": pos.availableQty,
                                   "costPrice": pos.costPrice, "lastPrice": snap.lastPrice,
                                   "profit": snap.profit, "profitPct": snap.profitPct,
                                   "sellableQty": pos.availableQty]
                }
                ticketAny = ["cash": summary.cash,
                             "lastPrice": quote.price,
                             "position": positionAny]
            }
            detailAny = ["meta": ["file": meta.file, "code": meta.displayCode, "name": meta.name,
                                  "price": quote.price, "pct": quote.pct],
                         "accountName": store.accountName(id: store.selectedAccountID),
                         "cash": summary.cash,
                         "tradingPhase": tradingPhase(),
                         "hasAccount": accountID != nil,
                         "ticket": ticketAny]
        }

        var listAny: Any = NSNull()
        if view == "list" {
            // 自选迷你列表前 6（自选标的池与原生 watchlistMetas 同口径）
            let favIDs = Set(FavoritesStore.shared.allGroup.manualMetaIDs)
            let metas = DatabaseManager.shared.metaList.filter { favIDs.contains($0.id) }.prefix(6)
            let watchlistAny: [[String: Any]] = metas.map { m in
                let q = quoteOf(m.id)
                return ["file": m.file, "code": m.displayCode, "name": m.name,
                        "price": q.price, "pct": q.pct]
            }
            let ordersAny: [[String: Any]] = store.activeOrders(accountID: accountID).prefix(5).map { o in
                ["id": o.id.uuidString, "name": o.name,
                 "direction": o.direction.rawValue, "status": o.status.title, "qty": o.qty]
            }
            listAny = ["summary": ["totalAssets": summary.totalAssets,
                                   "dayProfit": summary.dayProfit,
                                   "totalProfit": summary.totalProfit],
                       "activeOrderCount": store.activeOrders(accountID: accountID).count,
                       "watchlist": watchlistAny,
                       "activeOrders": ordersAny]
        }

        return ["trainingActive": TrainingSessionController.shared.isActive,
                "view": view,
                "accounts": accountsAny,
                "selectedName": store.accountName(id: store.selectedAccountID),
                "detail": detailAny,
                "list": listAny]
    }
}

// MARK: - Web 弹层浮层宿主（ContentView 根层常驻）

/// 常驻浮层宿主迁移说明：原挂 KlineDetailView 顶层（P2-5），P2-6a 快捷面板需要
/// 全 App 可见（悬浮球在任意页面可点）→ 迁至 ContentView 根层 overlay 链尾
/// （盖过 K 线详情全屏 overlay 与悬浮球区域）。

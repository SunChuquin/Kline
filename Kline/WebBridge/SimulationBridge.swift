//
//  SimulationBridge.swift
//  Kline
//
//  Sim 域的桥接动作实现（协议 v2 sim.*）：模拟页 Web 化的 Swift 侧。
//  数据全部来自 SimStore（账户/持仓/委托/成交/流水/日志/净值）+ SimulationPageModel（页面状态），
//  Web 侧零状态。数据流对齐 MarketBridge/HomeBridge：sim.changed（节流 ~0.8s）→ Web 回读快照。
//
//  浮层桥接：全屏下单页（SimFullScreenTicket）/ 条件单管理页与编辑器 / 策略公式 / 训练记录
//  由 SimWebShellView overlay 挂载呈现；新建账户与改价弹窗 Vant 化（Web 端 Dialog），
//  动作完成后以响应携带 toast 文案（对齐原生 SimulationPageModel.showToast 文案）。
//
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Combine
import SwiftUI

@MainActor
final class SimulationBridge: ObservableObject {

    static let shared = SimulationBridge()

    /// Web 模式专用的页面状态模型（模块切换 / 浮层请求状态跨动作保持）
    let model = SimulationPageModel()

    // MARK: 变化信号 → sim.changed 节流推送

    private var cancellables = Set<AnyCancellable>()
    private var changedItem: DispatchWorkItem? = nil
    private var pendingReason = "data"
    /// 节流窗口（下单/成交/行情快照变化共用；实测后调参）
    private let changedThrottle: TimeInterval = 0.8

    private init() {
        // SimStore 全域变化（账户/持仓/委托/成交/流水/日志/净值/选中账户）
        SimStore.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged(reason: "trade") }
            .store(in: &cancellables)

        // 页面状态变化（模块切换等 → Web 回读快照携带 module）
        model.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged(reason: "data") }
            .store(in: &cancellables)

        // 行缓存变化（持仓现价/盈亏/摘要随引擎快照刷新）
        MarketRowCache.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged(reason: "data") }
            .store(in: &cancellables)
    }

    /// 节流合并推送（对齐 MarketBridge.scheduleChanged）
    private func scheduleChanged(reason: String) {
        pendingReason = reason
        guard changedItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.changedItem = nil
            WebMessageRouter.shared.pushEvent("sim.changed",
                                              payload: ["reason": self.pendingReason])
        }
        changedItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + changedThrottle, execute: item)
    }

    /// 关键动作后立即推送（不经节流）
    private func notifyChangedNow(reason: String) {
        changedItem?.cancel()
        changedItem = nil
        WebMessageRouter.shared.pushEvent("sim.changed", payload: ["reason": reason])
    }

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
        case "selectModule":
            guard let raw = request.payload["module"] as? String,
                  let module = SimModuleTab(rawValue: raw) else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要有效 module")
            }
            shared.model.module = module
            return WebBridgeResponse.ok(request.id)
        case "createAccount":
            return createAccount(request)
        case "cancelOrder":
            guard let raw = request.payload["orderID"] as? String,
                  let id = UUID(uuidString: raw) else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要有效 orderID")
            }
            Task { await SimStore.shared.cancelOrder(id: id) }
            return WebBridgeResponse.ok(request.id)
        case "amendPrice":
            return amendPrice(request)
        case "refreshQuotes":
            Task {
                await SimStore.shared.prepareQuotes()
                shared.notifyChangedNow(reason: "data")
            }
            return WebBridgeResponse.ok(request.id, data: ["toast": "已请求最新行情"])
        case "openTicket":
            return openTicket(request)
        case "openCondEditor":
            return openCondEditor(request)
        case "openCondManage":
            shared.model.condPresentation = .list(UUID())
            return WebBridgeResponse.ok(request.id)
        case "openStrategyFormulas":
            shared.model.showStrategyFormulas = true
            return WebBridgeResponse.ok(request.id)
        case "openTrainingRecords":
            shared.model.showTrainingRecords = true
            return WebBridgeResponse.ok(request.id)
        case "exportLogs":
            return exportLogs(request)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "sim.\(request.action) 未实现")
        }
    }

    // MARK: - 快照组装

    /// sim.snapshot：账户 + 摘要/净值 + 五模块业务表（时间字符串原生格式化，对齐显示零差异）
    static func snapshotData() -> [String: Any] {
        let bridge = SimulationBridge.shared
        let store = SimStore.shared
        let accountID = store.queryAccountID

        let accountsAny: [[String: Any]] = store.activeAccounts.map { a in
            ["id": a.id.uuidString, "name": a.name, "badge": a.badge, "colorHex": a.colorHex]
        }

        let s = store.summary(accountID: accountID)
        let summaryAny: [String: Any] = [
            "totalAssets": s.totalAssets, "cash": s.cash, "marketValue": s.marketValue,
            "positionPct": s.positionPct, "dayProfit": s.dayProfit, "dayProfitPct": s.dayProfitPct,
            "totalProfit": s.totalProfit, "totalProfitPct": s.totalProfitPct,
        ]

        let positionsAny: [[String: Any]] = store.positions(accountID: accountID).map { p in
            let snap = store.snapshot(for: p)
            return ["id": p.id.uuidString, "code": p.code, "name": p.name,
                    "qty": p.qty, "availableQty": p.availableQty, "costPrice": p.costPrice,
                    "lastPrice": snap.lastPrice,
                    "marketValue": snap.marketValue,
                    "profit": snap.profit, "profitPct": snap.profitPct]
        }

        let ordersAny: [[String: Any]] = store.orders(accountID: accountID).map { o in
            ["id": o.id.uuidString,
             "time": SimFormat.time(o.createdAt),
             "code": o.code, "name": o.name,
             "direction": o.direction.rawValue, "priceType": o.priceType.rawValue,
             "price": o.price ?? NSNull(),
             "qty": o.qty, "filledQty": o.filledQty,
             "status": o.status.rawValue, "active": o.status.isActive]
        }

        let fillsAny: [[String: Any]] = store.fills(accountID: accountID).map { f in
            ["id": f.id.uuidString, "time": SimFormat.time(f.tradedAt),
             "code": f.code, "name": f.name,
             "direction": f.direction.rawValue,
             "price": f.price, "qty": f.qty, "amount": f.amount, "fee": f.fee,
             "contract": f.contractNo]
        }

        let ledgerAny: [[String: Any]] = store.ledgerEntries(accountID: accountID).map { e in
            ["id": e.id.uuidString, "time": SimFormat.dateTime(e.occurredAt),
             "kind": e.kind.title, "note": e.note,
             "amount": e.amount, "balance": e.balanceAfter,
             "accountName": store.accountName(id: e.accountID)]
        }

        let logsAny: [[String: Any]] = store.actionLogs(accountID: accountID).map { log in
            ["id": log.id.uuidString, "time": SimFormat.dateTime(log.occurredAt),
             "accountName": store.accountName(id: log.accountID),
             "module": log.module.title, "content": log.content, "result": log.result]
        }

        return [
            "selectedID": accountID?.uuidString ?? NSNull(),
            "accountName": store.accountName(id: accountID),
            "accounts": accountsAny,
            "summary": summaryAny,
            "netValue": store.netValueSeries(accountID: accountID, days: 30),
            "module": bridge.model.module.rawValue,
            "positions": positionsAny,
            "orders": ordersAny,
            "fills": fillsAny,
            "ledger": ledgerAny,
            "logs": logsAny,
        ]
    }

    // MARK: - 账户管理

    /// sim.createAccount {name, capital}：引擎侧开户，成功自动选中（响应带 toast 文案）
    private static func createAccount(_ request: WebBridgeRequest) -> [String: Any] {
        let name = (request.payload["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let capital = (request.payload["capital"] as? Double) ?? 100_000
        guard capital > 0 else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "初始资金需大于 0")
        }
        Task {
            if let account = await SimStore.shared.createAccount(name: name.isEmpty ? "新账户" : name,
                                                                 initialCapital: capital) {
                SimStore.shared.selectedAccountID = account.id
            }
        }
        return WebBridgeResponse.ok(request.id,
                                    data: ["toast": "已创建账户「\(name.isEmpty ? "新账户" : name)」"])
    }

    /// sim.amendPrice {orderID, price}：修改限价委托价（响应带 toast 文案）
    private static func amendPrice(_ request: WebBridgeRequest) -> [String: Any] {
        guard let raw = request.payload["orderID"] as? String,
              let id = UUID(uuidString: raw),
              let price = (request.payload["price"] as? NSNumber)?.doubleValue, price > 0,
              let order = SimStore.shared.order(id: id) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "需要有效 orderID 与 price")
        }
        Task {
            await SimStore.shared.amendOrderPrice(id: id, newPrice: price)
        }
        return WebBridgeResponse.ok(request.id,
                                    data: ["toast": "已改价：\(order.name) → \(SimFormat.price(price))"])
    }

    // MARK: - 下单与条件单浮层桥接

    /// sim.openTicket {direction, positionID?}：桥接原生全屏下单页。
    /// positionID 有值 = 持仓行入口（预填该持仓标的）；缺省 = 快捷下单（默认标的）。
    /// 账户/标的不可用时 fail（Web 端 toast 提示，对齐原生轻提示文案）。
    private static func openTicket(_ request: WebBridgeRequest) -> [String: Any] {
        guard let directionRaw = request.payload["direction"] as? String,
              let direction = SimOrderDirection(rawValue: directionRaw) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要有效 direction")
        }
        let model = shared.model
        let store = SimStore.shared

        // 持仓行入口：按 positionID 解析标的与账户
        if let posRaw = request.payload["positionID"] as? String,
           let posID = UUID(uuidString: posRaw),
           let position = store.positions(accountID: store.queryAccountID).first(where: { $0.id == posID }) {
            guard let accountID = model.orderAccountID else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "请先新建一个模拟账户")
            }
            model.openTicket(accountID: accountID, metaID: position.metaID,
                             code: position.code, name: position.name, direction: direction)
            return WebBridgeResponse.ok(request.id)
        }

        // 快捷下单（底部买卖条同口径）
        guard let accountID = model.orderAccountID else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "请先新建一个模拟账户")
        }
        guard let target = model.defaultTarget(accountID: accountID) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "暂无可用标的，无法下单")
        }
        model.openTicket(accountID: accountID, metaID: target.metaID,
                         code: target.code, name: target.name, direction: direction)
        return WebBridgeResponse.ok(request.id)
    }

    /// sim.openCondEditor {positionID}：持仓行条件单入口。
    /// 可卖数量走引擎异步组装（对齐 SimulationPageModel.openCondEditor），组装完成即呈现浮层。
    private static func openCondEditor(_ request: WebBridgeRequest) -> [String: Any] {
        guard let posRaw = request.payload["positionID"] as? String,
              let posID = UUID(uuidString: posRaw),
              let position = SimStore.shared.positions(accountID: SimStore.shared.queryAccountID)
                  .first(where: { $0.id == posID }) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要有效 positionID")
        }
        shared.model.openCondEditor(for: position)
        return WebBridgeResponse.ok(request.id)
    }

    // MARK: - 日志导出

    /// sim.exportLogs {keyword, logModule?}：按 Web 端筛选口径导出 CSV（对齐 exportableLogs 逻辑）。
    /// 导出落 Documents/Simulation/，响应带 toast 文案（含文件名）。
    private static func exportLogs(_ request: WebBridgeRequest) -> [String: Any] {
        let store = SimStore.shared
        var logs = store.actionLogs(accountID: store.queryAccountID)
        if let moduleRaw = request.payload["logModule"] as? String,
           let filter = ActionModule(rawValue: moduleRaw) {
            logs = logs.filter { $0.module == filter }
        }
        let key = ((request.payload["keyword"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            logs = logs.filter { $0.content.localizedCaseInsensitiveContains(key) }
        }
        guard !logs.isEmpty else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "当前没有可导出的操作日志")
        }

        let header = "时间,账户,模块,操作内容,结果"
        let lines = logs.map { log -> String in
            let cells = [SimFormat.dateTime(log.occurredAt),
                         store.accountName(id: log.accountID),
                         log.module.title,
                         log.content,
                         log.result]
            return cells.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                .joined(separator: ",")
        }
        let content = ([header] + lines).joined(separator: "\n")

        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return WebBridgeResponse.fail(request.id, code: "internal_error",
                                          message: "导出失败：无法访问 Documents 目录")
        }
        let dir = docs.appendingPathComponent("Simulation", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "sim_logs_\(formatter.string(from: Date())).csv"
        do {
            try content.write(to: dir.appendingPathComponent(fileName),
                              atomically: true, encoding: .utf8)
            return WebBridgeResponse.ok(request.id,
                                        data: ["toast": "已导出 \(logs.count) 条日志 → Documents/Simulation/\(fileName)",
                                               "file": fileName])
        } catch {
            return WebBridgeResponse.fail(request.id, code: "internal_error",
                                          message: "导出失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 模拟 Tab 的 Web 宿主（WebTabHostView + 原生浮层挂载）

/// 模拟页 Tab 内容的混合宿主：Web 页主体 + 原生全屏浮层（下单页 / 条件单 / 策略公式 / 训练记录）。
/// 浮层状态由 SimulationPageModel 持有（sim.* 动作写入），复用既有呈现修饰器。
/// ⚠️ bridge.model 是 let 属性（KeyPath 只读），不能经 $bridge.model 生成 Binding——
/// 单独用 @ObservedObject 订阅页面模型本体。
struct SimWebShellView: View {
    @ObservedObject private var bridge = SimulationBridge.shared
    @ObservedObject private var simModel = SimulationBridge.shared.model

    var body: some View {
        WebTabHostView(route: "simulation")
            // 全屏下单页（复用原生呈现修饰器；SimStore 写回后 sim.changed 推送刷新 Web）
            .simFullScreenTicket($simModel.ticketRequest)
            .overlay {
                if simModel.showStrategyFormulas {
                    ZStack {
                        FormulaCenterView(initialKind: .strategy,
                                          onClose: { simModel.showStrategyFormulas = false })
                    }
                    .transition(.opacity)
                    .zIndex(1000)
                }
            }
            // 条件单呈现（管理页 / 编辑器单一收敛；iOS 15 多 fullScreenCover 相互压制）
            .simCondEntryPresentation($simModel.condPresentation,
                                      accountID: SimStore.shared.queryAccountID)
            // 训练记录管理页
            .simTrainingRecordPresentation($simModel.showTrainingRecords)
    }
}

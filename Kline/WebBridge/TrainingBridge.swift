//
//  TrainingBridge.swift
//  Kline
//
//  训练桥（协议 v2 training.*）：P2-6c-3 训练 Web 化的 Swift 侧，两个 Web 面：
//   1. 训练设置浮层（sheet.open("training")，SheetPage 居中卡片面板）——表单态在 Web 本地，
//      数据动作（搜索/随机抽取/日期区间/开始训练）走本桥；开始成功后 Web 关面板，
//      训练态（K 线训练图表 + 快捷面板 + 回放推进）由原生 TrainingSessionController 接管。
//   2. 训练记录管理页（WebFullscreenPageHost "trainingRecords"，从模拟页入口打开）——
//      会话列表 / 单会话明细（成交表 / 条件单 / 预警）/ 删除与清空。
//
//  训练态闭环保留原生（P2 计划边界条款）：回放推进 advanceOneBar 逐根驱动图表，
//  桥接事件延迟不可接受；训练态浮层全部挂在 K 线详情之上，Web 页宿主在其下不可见。
//
//  与原生行为对齐：
//   - 偏好持久化（账户类型/本金/交易模式）走同一组 UserDefaults key（对齐 @AppStorage）
//   - 随机抽取：可训练池内随机；金额账户只在「起始日 2 手买得起」的标的里挑（引擎预检，
//     不可用显式报错 §9.10）；逻辑从 TrainingSetupSheet 迁入
//   - begin：金额账户原生预检（anchorClose + TrainAccountRule.minCapital）→ 不足推
//     beginReselect 弹窗文案；成功推 begun（Web 关面板进训练态）
//   - 明细条件单文案经 SimRulesProjection 引擎投影（未就绪显式「…」占位，就绪后推
//     changed(projection) 让 Web 重拉）
//
//  线程约定：动作入口均在主线程；引擎预检在 Task 内，结果经主线程推送。
//

import Combine
import SwiftUI

@MainActor
final class TrainingBridge: ObservableObject {

    static let shared = TrainingBridge()

    private let store = TrainingStore.shared
    private let projection = SimRulesProjection.shared

    /// 明细页当前会话（projection 就绪推送后 Web 重拉用）
    private var detailSessionID: String?

    private var cancellables = Set<AnyCancellable>()
    private var changedItem: DispatchWorkItem? = nil
    private var pendingReason = "records"
    private let changedThrottle: TimeInterval = 0.3

    private init() {
        // 条件单文案投影就绪 → 推送（Web 明细页重拉）
        projection.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged("projection") }
            .store(in: &cancellables)
    }

    // MARK: - 呈现入口

    /// 打开训练记录管理页（模拟页 sim.openTrainingRecords 入口改桥；原生浮层保留可回退）
    func openRecords() {
        WebPageBridge.shared.open("trainingRecords")
    }

    func onOpen() {
        // 记录页快照在动作里即时组装（含 refresh）
    }

    // MARK: - 变化信号 → training.changed 推送

    private func scheduleChanged(_ reason: String) {
        pendingReason = reason
        guard changedItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.changedItem = nil
            WebMessageRouter.shared.pushEvent("training.changed",
                                              payload: ["reason": self.pendingReason])
        }
        changedItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + changedThrottle, execute: item)
    }

    /// 带消息/数据的即时推送（begin 结论 / 随机抽取结果）
    private func pushPayload(_ reason: String, _ extra: [String: Any] = [:]) {
        var payload: [String: Any] = ["reason": reason]
        for (k, v) in extra { payload[k] = v }
        WebMessageRouter.shared.pushEvent("training.changed", payload: payload)
    }

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "setup.snapshot":
            return WebBridgeResponse.ok(request.id, data: setupSnapshotData())
        case "setPrefs":
            return setPrefs(request)
        case "search":
            return search(request)
        case "pickRandom":
            return pickRandom(request)
        case "anchor":
            return anchor(request)
        case "begin":
            return begin(request)
        case "records.snapshot":
            return WebBridgeResponse.ok(request.id, data: recordsSnapshotData())
        case "recordDetail":
            return recordDetail(request)
        case "deleteRecord":
            return deleteRecord(request)
        case "clearRecords":
            TrainingStore.shared.deleteAll()
            TrainingStore.shared.refresh()
            shared.scheduleChanged("records")
            DebugLogger.shared.log("[TrainingBridge] clearRecords")
            return WebBridgeResponse.ok(request.id)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "training.\(request.action) 未实现")
        }
    }

    // MARK: - 设置浮层：偏好 / 搜索 / 随机抽取 / 日期区间 / 开始训练

    private static let prefsAccountTypeKey = "training.accountType"
    private static let prefsCapitalKey = "training.capitalText"
    private static let prefsTradeModeKey = "training.tradeMode"

    /// training.setup.snapshot：上次偏好 + 自选分组（分类 chips 固定在 Web 端）
    static func setupSnapshotData() -> [String: Any] {
        let d = UserDefaults.standard
        return [
            "prefs": [
                "accountType": d.string(forKey: prefsAccountTypeKey) ?? "percent",
                "capitalText": d.string(forKey: prefsCapitalKey) ?? "100000",
                "tradeMode": d.string(forKey: prefsTradeModeKey) ?? "sameDayClose",
            ],
            "groups": FavoritesStore.shared.visibleGroups.map { ["id": $0.id.uuidString, "name": $0.name] },
        ]
    }

    /// training.setPrefs：偏好写回（幂等；缺省字段不动）
    private static func setPrefs(_ request: WebBridgeRequest) -> [String: Any] {
        let p = request.payload
        let d = UserDefaults.standard
        if let v = p["accountType"] as? String, TrainAccountType(rawValue: v) != nil {
            d.set(v, forKey: prefsAccountTypeKey)
        }
        if let v = p["capitalText"] as? String {
            d.set(v, forKey: prefsCapitalKey)
        }
        if let v = p["tradeMode"] as? String, TrainTradeMode(rawValue: v) != nil {
            d.set(v, forKey: prefsTradeModeKey)
        }
        return WebBridgeResponse.ok(request.id)
    }

    /// training.search {keyword}：searchMeta 同口径，最多 20 条，带可训练标记
    private static func search(_ request: WebBridgeRequest) -> [String: Any] {
        let kw = (request.payload["keyword"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else {
            return WebBridgeResponse.ok(request.id, data: ["results": [] as [[String: Any]]])
        }
        let results: [[String: Any]] = DatabaseManager.shared.searchMeta(keyword: kw).prefix(20).map {
            ["file": $0.file, "name": $0.name, "code": $0.displayCode,
             "trainable": TrainingDateMath.isTrainable($0)]
        }
        return WebBridgeResponse.ok(request.id, data: ["results": results])
    }

    /// 分类 → 候选池（rawValue 与原生 TrainingCategory 一致；从 View 迁入）
    private static func candidatePool(category: String, groupID: UUID?) -> [MetaItem] {
        let all = DatabaseManager.shared.metaList
        switch category {
        case "沪深主板": return all.filter { $0.type == "沪深主板" }
        case "ETF 指数": return all.filter { $0.type == "沪深京指数" || $0.type == "扩展行情指数" }
        case "自选": return FavoritesStore.shared.resolveMetaItems(groupID: FavoritesStore.allGroupID, allMeta: all)
        case "我的分组": return FavoritesStore.shared.resolveMetaItems(groupID: groupID ?? FavoritesStore.allGroupID, allMeta: all)
        default: return all   // "全部"
        }
    }

    /// [lower, upper] 内随机一个自然日（实际交易日由 begin 吸附；从 View 迁入）
    private static func randomDate(lower: Date, upper: Date) -> Date? {
        guard lower <= upper else { return nil }
        let days = Calendar.current.dateComponents([.day], from: lower, to: upper).day ?? 0
        let offset = days > 0 ? Int.random(in: 0...days) : 0
        return Calendar.current.date(byAdding: .day, value: offset, to: lower)
    }

    /// training.pickRandom：可训练池内随机；金额账户只在「2 手买得起」的标的里挑（引擎预检）。
    /// 百分比路径同步返回；金额路径异步（引擎），结果经 changed(picked/pickFailed) 推送。
    private static func pickRandom(_ request: WebBridgeRequest) -> [String: Any] {
        let p = request.payload
        let category = p["category"] as? String ?? "全部"
        let groupID = (p["groupID"] as? String).flatMap(UUID.init(uuidString:))
        let accountType = TrainAccountType(rawValue: p["accountType"] as? String ?? "percent") ?? .percent
        let capital = (p["capital"] as? NSNumber)?.doubleValue ?? 0

        let pool = candidatePool(category: category, groupID: groupID).filter { TrainingDateMath.isTrainable($0) }
        guard !pool.isEmpty else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "该分类下暂无可训练的标的（需至少 65 天历史）")
        }

        func resultData(_ meta: MetaItem, _ startDate: Int) -> [String: Any] {
            ["file": meta.file, "name": meta.name, "code": meta.displayCode, "startDate": startDate]
        }

        // 百分比账户不校验资金，直接随机（对齐原生 pickRandom）
        if accountType == .percent {
            guard let meta = pool.randomElement(),
                  let lower = TrainingDateMath.minDate(of: meta),
                  let upper = TrainingDateMath.maxDate(of: meta),
                  let day = randomDate(lower: lower, upper: upper) else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "随机抽取失败，请重试")
            }
            return WebBridgeResponse.ok(request.id, data: resultData(meta, TrainingDateMath.int(from: day)))
        }

        // 仓位金额账户：随机抽取只在「起始日收盘价买得起 2 手」的标的里挑（异步引擎预检）
        guard capital > 0 else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "请先输入有效的本金金额")
        }
        Task {
            var picked: (meta: MetaItem, startDate: Int)?
            do {
                let lot = SimTradeRuleConstants.lotSize
                outer: for meta in pool.shuffled().prefix(60) {
                    guard let lower = TrainingDateMath.minDate(of: meta),
                          let upper = TrainingDateMath.maxDate(of: meta), lower <= upper else { continue }
                    for _ in 0..<2 {
                        guard let day = randomDate(lower: lower, upper: upper) else { continue }
                        let startInt = TrainingDateMath.int(from: day)
                        guard let close = TrainingSessionController.shared.anchorClose(meta: meta, startDate: startInt) else { continue }
                        let need = try await TrainAccountRule.minCapital(price: close, lotSize: lot)
                        guard capital >= need else { continue }
                        picked = (meta, startInt)
                        break outer
                    }
                }
            } catch {
                DebugLogger.shared.log("[TrainingBridge] pickRandom：引擎不可用 \(error)")
                shared.pushPayload("pickFailed", ["message": TrainingSessionController.engineUnavailableText])
                return
            }
            if let picked {
                shared.pushPayload("picked", resultData(picked.meta, picked.startDate))
            } else {
                shared.pushPayload("pickFailed",
                                   ["message": "该分类下没有满足条件的标的（当前本金买不起 2 手，请提高本金或换个分类）"])
            }
        }
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    /// training.anchor {file}：选中标的的日期区间与可训练性（自然日随机在 Web 端做）
    private static func anchor(_ request: WebBridgeRequest) -> [String: Any] {
        guard let file = request.payload["file"] as? String,
              let meta = DatabaseManager.shared.metaList.first(where: { $0.file == file }) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要有效 file")
        }
        return WebBridgeResponse.ok(request.id, data: [
            "minDate": TrainingDateMath.minDate(of: meta).map { TrainingDateMath.int(from: $0) } ?? NSNull(),
            "maxDate": TrainingDateMath.maxDate(of: meta).map { TrainingDateMath.int(from: $0) } ?? NSNull(),
            "trainable": TrainingDateMath.isTrainable(meta),
        ])
    }

    /// training.begin：开始训练（金额账户原生预检 2 手可买；结论经 changed 推送）。
    /// begun = 已开训（Web 关面板进训练态）；beginFailed = 文案；beginReselect = 重新选择标的弹窗文案。
    private static func begin(_ request: WebBridgeRequest) -> [String: Any] {
        let p = request.payload
        guard let file = p["file"] as? String,
              let meta = DatabaseManager.shared.metaList.first(where: { $0.file == file }),
              let startDate = (p["startDate"] as? NSNumber)?.intValue,
              let accountRaw = p["accountType"] as? String,
              let accountType = TrainAccountType(rawValue: accountRaw),
              let tradeRaw = p["tradeMode"] as? String,
              let tradeMode = TrainTradeMode(rawValue: tradeRaw) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "训练参数不完整（file/startDate/accountType/tradeMode）")
        }
        let capital = (p["capital"] as? NSNumber)?.doubleValue ?? 0
        Task {
            // 金额账户预检：起始日收盘价至少买得起 2 手（引擎费用，不可用显式报错 §9.10）
            if accountType == .fixedAmount {
                guard capital > 0 else {
                    shared.pushPayload("beginFailed", ["message": "请输入有效的本金金额"])
                    return
                }
                guard let close = TrainingSessionController.shared.anchorClose(meta: meta, startDate: startDate),
                      close > 0 else {
                    shared.pushPayload("beginFailed", ["message": "该标的暂无行情数据，无法开始训练"])
                    return
                }
                let need: Double
                do {
                    need = try await TrainAccountRule.minCapital(price: close, lotSize: SimTradeRuleConstants.lotSize)
                } catch {
                    DebugLogger.shared.log("[TrainingBridge] begin：引擎不可用 \(error)")
                    shared.pushPayload("beginFailed", ["message": TrainingSessionController.engineUnavailableText])
                    return
                }
                guard capital >= need else {
                    shared.pushPayload("beginReselect", ["message": "「\(meta.name)」在起始日（\(TrainSessionRecord.dateText(startDate))）收盘价 \(SimFormat.price(close))，买入 2 手需 \(SimFormat.amount(need))，当前本金 \(SimFormat.amount(capital)) 不足，请重新选择标的或提高本金。"])
                    return
                }
                startAndNotify(meta: meta, startDate: startDate, accountType: accountType,
                               capital: capital, tradeMode: tradeMode)
                return
            }
            // 百分比账户：不校验资金
            startAndNotify(meta: meta, startDate: startDate, accountType: accountType,
                           capital: TrainAccountRule.defaultCapital, tradeMode: tradeMode)
        }
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    /// begin 收尾：成功推 begun（Web 关面板，训练态原生接管）；无行情推 beginFailed
    private static func startAndNotify(meta: MetaItem, startDate: Int,
                                       accountType: TrainAccountType, capital: Double,
                                       tradeMode: TrainTradeMode) {
        if TrainingSessionController.shared.begin(meta: meta, startDate: startDate,
                                                  accountType: accountType, capital: capital,
                                                  tradeMode: tradeMode) {
            DebugLogger.shared.log("[TrainingBridge] begun \(meta.name) @\(startDate)")
            shared.pushPayload("begun")
        } else {
            shared.pushPayload("beginFailed", ["message": "该标的暂无行情数据，无法开始训练"])
        }
    }

    // MARK: - 记录管理页：列表 / 明细 / 删除

    /// 会话行公共组装（列表与明细共用；createdAt 原生格式化）
    private static func sessionData(_ s: TrainSessionRecord) -> [String: Any] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return [
            "id": s.id,
            "name": s.name,
            "code": s.code,
            "startDate": s.startDate,
            "endDate": s.endDate ?? NSNull(),
            "tradeCount": s.tradeCount,
            "status": s.status.rawValue,
            "createdAtText": f.string(from: s.createdAt),
        ]
    }

    /// training.records.snapshot：会话列表（store 倒序，先 refresh 对齐原生 onAppear）
    static func recordsSnapshotData() -> [String: Any] {
        TrainingStore.shared.refresh()
        return ["sessions": TrainingStore.shared.sessions.map { sessionData($0) }]
    }

    /// training.recordDetail {id}：单会话成交 / 条件单 / 预警；条件单文案经引擎投影
    private static func recordDetail(_ request: WebBridgeRequest) -> [String: Any] {
        let store = TrainingStore.shared
        let projection = SimRulesProjection.shared
        guard let id = request.payload["id"] as? String,
              let session = store.sessions.first(where: { $0.id == id }) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "会话不存在")
        }
        shared.detailSessionID = id

        let trades = store.trades(sessionID: id)
        let conds = store.conditions(sessionID: id)
        let alerts = store.alerts(sessionID: id)

        // 条件单文案投影：请求引擎；未就绪时 conditionSummary 返回「…」占位，
        // 就绪后 objectWillChange 订阅推 changed(projection) 让 Web 重拉
        projection.request(conds.map { $0.order })

        let tradesAny: [[String: Any]] = trades.map { t in
            let triggerText: String
            if t.trigger == TrainTradeTrigger.cond, let kind = t.condKind, !kind.isEmpty {
                triggerText = "\(t.trigger.title)·\(kind)"
            } else {
                triggerText = t.trigger.title
            }
            return [
                "seq": t.seq,
                "direction": t.direction.rawValue,
                "mark": t.mark.rawValue,
                "tradeDate": t.tradeDate,
                "price": t.price,
                "qty": t.qty,
                "amount": t.amount,
                "fee": t.fee,
                "pnl": t.pnl ?? NSNull(),
                "triggerText": triggerText,
                "note": t.note,
            ]
        }
        let condsAny: [[String: Any]] = conds.map { record in
            let order = record.order
            return [
                "kindTitle": order.kind.title,
                "statusTitle": order.status.title,
                "alertOnly": order.directive.isAlertOnly,
                "createdDate": record.createdDate,
                "summary": projection.conditionSummary(order),
                "validity": projection.validitySummary(order),
                "lastMessage": order.runtime.lastMessage,
            ]
        }
        let alertsAny: [[String: Any]] = alerts.map { a in
            ["tradeDate": a.tradeDate, "price": a.price, "message": a.message]
        }

        return WebBridgeResponse.ok(request.id, data: [
            "session": sessionData(session),
            "trades": tradesAny,
            "conds": condsAny,
            "alerts": alertsAny,
        ])
    }

    /// training.deleteRecord {id}
    private static func deleteRecord(_ request: WebBridgeRequest) -> [String: Any] {
        guard let id = request.payload["id"] as? String else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要 id")
        }
        TrainingStore.shared.deleteSession(id: id)
        TrainingStore.shared.refresh()
        shared.scheduleChanged("records")
        return WebBridgeResponse.ok(request.id)
    }
}

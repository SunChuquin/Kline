//
//  TrainingSessionController.swift
//  Kline
//
//  「K 线单人训练」运行时控制器（单例；同一时刻只允许一个训练会话）。
//  只持有当前训练标的的全量日线缓存（升序），训练期间仅在缓存上推进 `trainingDate`，
//  不再查库；成交经 TrainingStore 即时落库。训练态**不触碰** SimStore（模拟账户）。
//
//  条件单 / 预警：全部存训练库（train_cond / train_alert），评估口径与实盘一致——
//  走 SimCondRule 纯函数，但快照来自「训练日 K 线收盘价」而非实时行情。
//  结算时机：① 推进一根 K 线后 ② 新建 / 修改条件单后。命中后：
//    - 普通条件单 → 以训练日收盘价写入一笔训练成交（trigger = 条件单）
//    - 「仅提醒」 → 只追加一条训练预警记录，不产生成交
//

import Foundation
import Combine

final class TrainingSessionController: ObservableObject {
    static let shared = TrainingSessionController()

    /// 训练态条件单使用的占位账户 id（训练不落任何真实模拟账户）
    static let trainingAccountID = SimStore.allAccountID

    /// 训练态条件单编辑器使用的占位账户（训练不追踪资金，资金给足即可通过校验）
    static let trainingAccount = SimAccount(id: trainingAccountID, name: "训练账户", badge: "训",
                                            colorHex: "#1E5FA8", initialCapital: 1_000_000,
                                            cash: 1_000_000, createdAt: Date(timeIntervalSince1970: 0),
                                            isArchived: false)

    /// 训练标的；非 nil 即处于训练态
    @Published private(set) var meta: MetaItem?
    /// 训练起始日期 YYYYMMDD（已吸附到实际交易日）
    @Published private(set) var startDate: Int = 0
    /// 当前训练日 YYYYMMDD（图表右缘上界）
    @Published private(set) var trainingDate: Int = 0
    /// 该标最新库日期（日线最后一根）
    @Published private(set) var latestDate: Int = 0
    /// 本会话成交，按 seq 升序
    @Published private(set) var trades: [TrainTradeRecord] = []
    /// 本会话条件单（含创建时的训练日）
    @Published private(set) var conditions: [TrainCondRecord] = []
    /// 本会话预警记录（触发时间倒序）
    @Published private(set) var alerts: [TrainAlertRecord] = []
    /// 是否已结束（推进到最新日期自动置 true）
    @Published private(set) var isFinished: Bool = false

    /// 当前会话 id（TrainingStore 主键）；无训练时为空串
    private(set) var sessionID: String = ""

    /// 全量日线缓存（升序）
    private var bars: [KlineItem] = []
    /// 训练持仓数量 / 均价：随 begin / placeTrade / close 就地维护，避免每次 body 求值遍历 trades
    private var positionQtyValue = 0
    private var avgCostValue: Double = 0

    private init() {}

    // MARK: - 派生状态

    var isActive: Bool { meta != nil }

    /// 日线中 date <= trainingDate 的最后一根 close（bars 升序）
    var currentClose: Double? {
        bars.last(where: { $0.date <= trainingDate })?.close
    }

    /// 训练持仓数量
    var positionQty: Int { positionQtyValue }

    /// 训练持仓均价（无持仓 0）
    var avgCost: Double { avgCostValue }

    /// 浮动盈亏：(currentClose - avgCost) * positionQty；无持仓 nil
    var floatingPnl: Double? {
        guard positionQtyValue > 0, let close = currentClose else { return nil }
        return (close - avgCostValue) * Double(positionQtyValue)
    }

    /// 监控中的条件单
    var monitoringConditions: [SimCondOrder] {
        conditions.map(\.order).filter { $0.status == .monitoring }
    }

    /// 训练持仓的「可卖」快照（训练无 T+1，持仓即可卖）；无持仓返回 nil
    var trainingPositionSnapshot: SimPosition? {
        guard positionQtyValue > 0, let meta = meta else { return nil }
        return SimPosition(id: Self.trainingAccountID, accountID: Self.trainingAccountID,
                           metaID: meta.id, code: meta.code, name: meta.name,
                           qty: positionQtyValue, availableQty: positionQtyValue,
                           costPrice: avgCostValue, openedAt: Date())
    }

    /// 主图信号标记：按训练日聚合，一日一个（同日有买有卖 → T）
    var signalMarks: [Int: TrainSignalMark] {
        guard !trades.isEmpty else { return [:] }
        var grouped: [Int: [TrainTradeRecord]] = [:]
        for trade in trades { grouped[trade.tradeDate, default: []].append(trade) }
        var result: [Int: TrainSignalMark] = [:]
        for (date, list) in grouped {
            let hasBuy = list.contains { $0.direction == .buy }
            let hasSell = list.contains { $0.direction == .sell }
            let mark: TrainTradeMark = (hasBuy && hasSell) ? .dayTrade : (hasBuy ? .buy : .sell)
            result[date] = TrainSignalMark(mark: mark, isConditional: list.contains { $0.trigger == .cond })
        }
        return result
    }

    // MARK: - 生命周期

    /// 开始训练：取全量日线（升序缓存）→ 吸附起始日 → 建会话 → 起始日即最新日则直接结束
    @discardableResult
    func begin(meta: MetaItem, startDate: Int) -> Bool {
        // 查询量很小（单只标的），允许同步调用
        let raw = DatabaseManager.shared.fetchDailyData(metaId: meta.id)   // date 降序
        let sorted = raw.sorted { $0.date < $1.date }                      // 升序
        guard let last = sorted.last else { return false }                 // 无行情 → 不改变状态

        // 起始日吸附到「date <= startDate 的最后一根」；不存在则取第一根
        let anchor = sorted.last(where: { $0.date <= startDate })?.date ?? sorted[0].date

        bars = sorted
        self.meta = meta
        self.startDate = anchor
        self.trainingDate = anchor
        self.latestDate = last.date
        self.trades = []
        self.conditions = []
        self.alerts = []
        positionQtyValue = 0
        avgCostValue = 0
        sessionID = TrainingStore.shared.createSession(metaID: meta.id, code: meta.code,
                                                       name: meta.name, startDate: anchor)
        // 起始日即最新日：一开始就到位，直接判定结束并落库
        if anchor == last.date {
            TrainingStore.shared.finishSession(id: sessionID, endDate: last.date)
            isFinished = true
        } else {
            isFinished = false
        }
        return true
    }

    /// 推进一根 K 线；推进后先结算条件单 / 预警（吃新训练日的收盘价），再判是否到最新日
    func advanceOneBar() {
        guard isActive, !isFinished else { return }
        guard let i = bars.firstIndex(where: { $0.date == trainingDate }) else { return }
        let next = i + 1
        guard next < bars.count else { return }
        trainingDate = bars[next].date

        sweepConditions(reason: "ADVANCE")

        if trainingDate == latestDate {
            TrainingStore.shared.finishSession(id: sessionID, endDate: latestDate)
            isFinished = true
        }
    }

    /// 关闭训练：未结束则先落 end_date，然后清空运行时状态（页面随之关闭）
    func close() {
        if isActive, !isFinished {
            TrainingStore.shared.finishSession(id: sessionID, endDate: trainingDate)
        }
        meta = nil
        trades = []
        conditions = []
        alerts = []
        sessionID = ""
        isFinished = false
        bars = []
        startDate = 0
        trainingDate = 0
        latestDate = 0
        positionQtyValue = 0
        avgCostValue = 0
    }

    // MARK: - 下单

    /// 以 currentClose 成交一笔；返回 nil = 成功，否则返回中文拒绝原因
    /// - Parameters:
    ///   - trigger: 触发来源（手动 / 条件单），落训练库供追溯
    ///   - condKind: 触发它的条件单类型中文名（手动为 nil）
    func placeTrade(direction: SimOrderDirection, qty: Int, note: String,
                    trigger: TrainTradeTrigger = .manual, condKind: String? = nil) -> String? {
        guard isActive else { return "当前无进行中的训练" }
        guard let price = currentClose, price > 0 else { return "当前训练日无可用行情" }

        let lot = SimTradingRules.default.lotSize
        if qty <= 0 || qty % lot != 0 {
            return "委托数量需为 \(lot) 股的整数倍且大于 0"
        }
        // 训练不支持做空
        if direction == .sell, qty > positionQtyValue {
            return "训练持仓不足：当前可卖 \(positionQtyValue) 股"
        }

        let amount = price * Double(qty)
        let fee = SimTradingRules.default.fee(amount: amount, direction: direction)
        let pnl: Double? = direction == .sell ? (price - avgCostValue) * Double(qty) - fee : nil
        let seq = trades.count + 1

        let ok = TrainingStore.shared.appendTrade(sessionID: sessionID, seq: seq, direction: direction,
                                                  tradeDate: trainingDate, price: price, qty: qty,
                                                  amount: amount, fee: fee, pnl: pnl, note: note,
                                                  trigger: trigger, condKind: condKind)
        guard ok else { return "训练交易落库失败" }

        // 持仓 / 均价：买入加权平均；卖出均价不变，清仓归零
        if direction == .buy {
            let q0 = positionQtyValue
            let q = q0 + qty
            avgCostValue = q > 0 ? (avgCostValue * Double(q0) + price * Double(qty)) / Double(q) : 0
            positionQtyValue = q
        } else {
            positionQtyValue -= qty
            if positionQtyValue <= 0 {
                positionQtyValue = 0
                avgCostValue = 0
            }
        }

        // 直接回读库内记录（id / seq / mark 与落库一致，做 T 提升也能立刻反映）
        trades = TrainingStore.shared.trades(sessionID: sessionID)
        return nil
    }

    // MARK: - 条件单 / 预警管理

    /// 条件单编辑器的训练后端（取数走训练日快照，保存写训练库并立即结算）
    var condEditorBackend: TrainingCondBackend {
        TrainingCondBackend(
            account: Self.trainingAccount,
            position: { [weak self] in self?.trainingPositionSnapshot },
            snapshot: { [weak self] order in self?.condSnapshot(for: order) ?? SimCondSnapshot() },
            save: { [weak self] order in self?.upsertCondition(order) })
    }

    /// 重新从训练库加载条件单与预警记录
    func reloadConditions() {
        guard !sessionID.isEmpty else { conditions = []; return }
        conditions = TrainingStore.shared.conditions(sessionID: sessionID)
    }

    func reloadAlerts() {
        guard !sessionID.isEmpty else { alerts = []; return }
        alerts = TrainingStore.shared.alerts(sessionID: sessionID)
    }

    /// 新建 / 修改一条训练条件单（创建训练日 = 当前训练日），随后立即结算一次
    func upsertCondition(_ order: SimCondOrder) {
        guard isActive, !sessionID.isEmpty else { return }
        _ = TrainingStore.shared.upsertCondition(sessionID: sessionID, order: order,
                                                 createdDate: trainingDate)
        reloadConditions()
        sweepConditions(reason: "CREATE")
    }

    /// 删除一条训练条件单
    func deleteCondition(id: String) {
        TrainingStore.shared.deleteCondition(id: id)
        reloadConditions()
    }

    /// 训练态建单校验用的行情快照（以当前训练日收盘价为准）
    func condSnapshot(for order: SimCondOrder) -> SimCondSnapshot {
        guard let i = bars.firstIndex(where: { $0.date == trainingDate }) else { return SimCondSnapshot() }
        let bar = bars[i]
        let prevClose = i > 0 ? bars[i - 1].close : bar.open
        let changePct = prevClose > 0 ? (bar.close - prevClose) / prevClose * 100 : nil
        return SimCondSnapshot(last: bar.close, prevClose: prevClose, high: bar.high, low: bar.low,
                               changePct: changePct, ma: maValue(at: i, period: order.params.maPeriod))
    }

    // MARK: - 结算引擎

    /// 结算全部监控中的训练条件单：
    /// 有效期（按训练日）→ 取训练日快照 → SimCondRule 判定 → 命中写训练库
    func sweepConditions(reason: String) {
        guard isActive, !sessionID.isEmpty, !conditions.isEmpty else { return }

        var list = conditions
        var dirty = false
        var fired = false
        let now = Date()

        for index in list.indices {
            var record = list[index]
            guard record.order.status == .monitoring else { continue }

            // 1) 有效期（训练态按训练日判定，而非自然日）
            if let expired = trainingExpiredReason(record) {
                record.order.status = .expired
                record.order.updatedAt = now
                record.order.runtime.lastEvaluatedAt = now
                record.order.runtime.lastMessage = expired
                list[index] = record
                dirty = true
                DebugLogger.shared.log("[Training] 条件单失效(\(reason)) \(record.order.name)：\(expired)")
                continue
            }

            // 2) 判定：时间条件按训练日比较，其余复用 SimCondRule 纯函数
            let snapshot = condSnapshot(for: record.order)
            let decision: SimCondDecision
            if record.order.kind == .time {
                decision = trainingTimeDecision(order: record.order, snapshot: snapshot)
            } else {
                decision = SimCondRule.evaluate(order: record.order, snapshot: snapshot)
            }

            // 3) 结果落库
            switch decision {
            case .hold(let runtime):
                if record.order.runtime != runtime {
                    record.order.runtime = runtime
                    record.order.updatedAt = now
                    list[index] = record
                    dirty = true
                }

            case .abort(let why):
                record.order.status = .expired
                record.order.updatedAt = now
                record.order.runtime.lastEvaluatedAt = now
                record.order.runtime.lastMessage = why
                list[index] = record
                dirty = true

            case .complete(let why):
                record.order.status = .completed
                record.order.updatedAt = now
                record.order.runtime.lastEvaluatedAt = now
                record.order.runtime.lastMessage = why
                list[index] = record
                dirty = true

            case .fire(let qty, let at):
                list[index] = fireCondition(record, qty: qty, at: at, snapshot: snapshot, now: now)
                dirty = true
                fired = true
            }
        }

        guard dirty else { return }
        for record in list {
            _ = TrainingStore.shared.upsertCondition(sessionID: sessionID, order: record.order,
                                                     createdDate: record.createdDate)
        }
        conditions = list
        if fired {
            reloadAlerts()
            trades = TrainingStore.shared.trades(sessionID: sessionID)
        }
        DebugLogger.shared.log("[Training] 条件单结算(\(reason))：\(list.count) 条，\(fired ? "有" : "无")触发")
    }

    // MARK: - 结算辅助

    /// 「仅提醒」不下单；普通条件单以训练日收盘价写入一笔训练成交
    private func fireCondition(_ record: TrainCondRecord, qty: Int, at triggerPrice: Double,
                               snapshot: SimCondSnapshot, now: Date) -> TrainCondRecord {
        var target = record
        let order = target.order
        target.order.runtime.lastEvaluatedAt = now
        target.order.runtime.lastPrice = snapshot.last ?? order.runtime.lastPrice
        target.order.runtime.lastTriggerPrice = triggerPrice
        target.order.updatedAt = now

        if order.directive.isAlertOnly {
            let message = SimStore.shared.alertMessage(order: order, triggerPrice: triggerPrice)
            _ = TrainingStore.shared.appendAlert(TrainAlertRecord(
                id: UUID().uuidString, sessionID: sessionID, condID: order.id.uuidString,
                tradeDate: trainingDate, price: triggerPrice, message: message, occurredAt: now))
            target.order.triggeredCount += 1
            applyRepeatableProgress(&target.order, alertMessage: message)
            return target
        }

        let direction = SimStore.shared.fireDirection(order: order, triggerPrice: triggerPrice)
        let rejection = placeTrade(direction: direction, qty: qty,
                                   note: "条件单：\(order.kind.title)",
                                   trigger: .cond, condKind: order.kind.title)
        if rejection == nil {
            target.order.triggeredCount += 1
            if order.kind.repeatable {
                target.order.runtime = SimStore.shared.advanceRepeatable(order: target.order,
                                                                        triggerPrice: triggerPrice)
                if SimStore.shared.repeatableFinished(order: target.order) {
                    target.order.status = .completed
                    target.order.runtime.lastMessage = order.kind == .grid ? "已完成全部档位" : "已完成全部批次"
                } else if order.kind == .grid {
                    target.order.runtime.lastMessage = "已成交第 \(target.order.runtime.gridLevel ?? 0) 档"
                } else {
                    target.order.runtime.lastMessage = "已成交第 \(target.order.runtime.batchDone) 批"
                }
            } else {
                target.order.status = .triggered
                target.order.triggeredAt = now
                target.order.runtime.lastMessage = "已触发并写入训练成交"
            }
            DebugLogger.shared.log("[Training] 条件单触发 \(order.name) · \(order.kind.title)"
                                   + " 数量=\(qty) 训练日=\(trainingDate)")
        } else {
            // 单次类型触发后被拒 → 不重试；多触发类型保持监控继续下一档
            target.order.runtime.lastMessage = rejection ?? ""
            if !order.kind.repeatable { target.order.status = .rejected }
            DebugLogger.shared.log("[Training] 条件单触发被拒 \(order.name)：\(rejection ?? "")")
        }
        return target
    }

    /// 「仅提醒」的多触发进度推进 / 单次类型置已触发
    private func applyRepeatableProgress(_ order: inout SimCondOrder, alertMessage: String) {
        if order.kind.repeatable {
            order.runtime = SimStore.shared.advanceRepeatable(order: order,
                                                             triggerPrice: order.runtime.lastTriggerPrice ?? 0)
            if SimStore.shared.repeatableFinished(order: order) {
                order.status = .completed
                order.runtime.lastMessage = order.kind == .grid ? "已完成全部档位" : "已完成全部批次"
            } else {
                order.runtime.lastMessage = alertMessage
            }
        } else {
            order.status = .triggered
            order.triggeredAt = Date()
            order.runtime.lastMessage = alertMessage
        }
    }

    /// 训练态有效期：`.day` = 仅创建时所在的训练日有效；`.untilDate` 按训练日比较
    private func trainingExpiredReason(_ record: TrainCondRecord) -> String? {
        switch record.order.validity {
        case .longTerm:
            return nil
        case .day:
            return trainingDate > record.createdDate ? "当日有效条件单已跨训练日失效" : nil
        case .untilDate:
            guard let expiresAt = record.order.expiresAt else { return nil }
            return trainingDate > Self.dateInt(expiresAt) ? "已超过指定有效期" : nil
        }
    }

    /// 时间条件在训练态下按训练日比较（`SimCondRule.evaluate` 用的是真实 `Date()`，训练不适用）
    private func trainingTimeDecision(order: SimCondOrder, snapshot: SimCondSnapshot) -> SimCondDecision {
        guard let fireDate = order.params.fireDate else { return .abort("触发时间缺失") }
        guard trainingDate >= Self.dateInt(fireDate) else { return .hold(order.runtime) }
        guard let at = snapshot.last, at > 0 else { return .hold(order.runtime) }
        return .fire(qty: order.directive.qty, at: at)
    }

    /// 训练日所在下标起的 period 日简单均线（不足周期返回 nil）
    private func maValue(at index: Int, period: Int?) -> Double? {
        guard let period = period, period > 0,
              index >= period - 1, index < bars.count else { return nil }
        var sum = 0.0
        for k in (index - period + 1)...index { sum += bars[k].close }
        return sum / Double(period)
    }

    /// Date → Int(YYYYMMDD)（公历 + 当前时区，与回测 / 策略生成同口径）
    private static func dateInt(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return (components.year ?? 0) * 10000 + (components.month ?? 0) * 100 + (components.day ?? 0)
    }
}

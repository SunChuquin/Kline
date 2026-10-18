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

/// 训练区间统计（顶栏徽标用）：区间 = [起始训练日, 当前训练日]，基准 = 起始日收盘价
struct TrainRangeStats: Equatable {
    /// K：成交笔数
    var trades: Int = 0
    /// M/高：区间最大涨幅 %（区间最高相对基准）
    var rally: Double = 0
    /// N/低：区间最大回撤 %（区间最低相对基准，通常为负）
    var drawdown: Double = 0
    /// 振：训练振幅 %（区间最高 − 区间最低，恒为非负）
    var amplitude: Double = 0
    /// C/收：起始至今涨幅 %
    var change: Double = 0
    /// 盈：持仓收益率 % =（浮动盈亏 + 已实现盈亏）/ 累计买入成本（无成交时为 0）
    var pnl: Double = 0
}

final class TrainingSessionController: ObservableObject {
    static let shared = TrainingSessionController()

    /// 训练态条件单使用的占位账户 id（训练不落任何真实模拟账户）
    static let trainingAccountID = SimStore.allAccountID

    /// 引擎不可用的显式拒绝文案（§9.10 fail-closed：不下单 / 不结算，绝不静默用 Swift 兜底）
    static let engineUnavailableText = "Python 引擎不可用，暂不能交易，请稍后重试"

    /// 训练标的；非 nil 即处于训练态
    @Published private(set) var meta: MetaItem?
    /// 训练账户类型（百分比 / 仓位金额）
    @Published private(set) var accountType: TrainAccountType = .percent
    /// 仓位金额账户的初始本金（百分比账户 = 名义本金）
    @Published private(set) var initialCapital: Double = 0
    /// 仓位金额账户的可用资金（百分比账户不使用）
    @Published private(set) var cash: Double = 0
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
    /// 交易模式（当日收盘价成交 / 隔日委托）
    @Published private(set) var tradeMode: TrainTradeMode = .sameDayClose
    /// 隔日委托队列（按挂单先后）；非空即表示有未成交的手动下单
    @Published private(set) var pendingOrders: [TrainPendingOrder] = []
    /// 隔日委托结算失败提示（推进后一次性展示，下次挂单 / 推进时覆盖）
    @Published private(set) var pendingRejectText: String?

    /// 当前会话 id（TrainingStore 主键）；无训练时为空串
    private(set) var sessionID: String = ""

    /// 全量日线缓存（升序）
    private var bars: [KlineItem] = []
    /// 训练持仓数量 / 均价：随 begin / placeTrade / close 就地维护，避免每次 body 求值遍历 trades
    private var positionQtyValue = 0
    private var avgCostValue: Double = 0
    /// 当日买入锁定量（T+1 标的当日不可卖部分）；推进训练日 / 重开 / 关闭时清零
    private var lockedQtyValue = 0
    /// 已实现盈亏累计（买入记 -费用、卖出记 (价-均价)*量-费用），供顶栏「盈」统计
    private var realizedPnlValue: Double = 0
    /// 累计买入成本（买入成交额之和，不含费用）：作为顶栏「盈」收益率的分母
    private var investedCostValue: Double = 0

    private init() {}

    // MARK: - 派生状态

    var isActive: Bool { meta != nil }

    /// 条件单结算重入守卫（§11.18.2 约束 5）：`.engine` 下上一轮 `await` 未回时不得再扫，
    /// 否则同一条件单可能被两轮并发结算重复触发（双份成交）。
    private var condSweepInFlight = false

    /// 日线中 date <= trainingDate 的最后一根 close（bars 升序）
    var currentClose: Double? {
        bars.last(where: { $0.date <= trainingDate })?.close
    }

    /// 训练持仓数量
    var positionQty: Int { positionQtyValue }

    /// 本标的的交收规则（沪深主板 / 沪深京指数 = T+1；扩展行情指数 = T+0）
    var settlementRule: TrainSettlementRule { TrainSettlementRule.resolve(for: meta) }

    /// 买入可用资金：百分比账户用名义本金（不做不足校验），仓位金额账户用实际可用资金
    var buyingPower: Double {
        accountType == .percent ? TrainAccountRule.notionalCapital : cash
    }

    /// 可卖数量：T+1 标的要扣掉「当日买入尚不可卖」的锁定量；T+0 标的全部可卖
    var sellableQty: Int {
        settlementRule.allowsSameDaySell ? positionQtyValue : max(0, positionQtyValue - lockedQtyValue)
    }

    /// 当日买入锁定量（T+1 标的；T+0 恒为 0，仅用于展示）
    var lockedQty: Int { settlementRule.allowsSameDaySell ? 0 : lockedQtyValue }

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

    /// 训练持仓的「可卖」快照（T+1 标的已扣除当日买入锁定部分）；无持仓返回 nil
    var trainingPositionSnapshot: SimPosition? {
        guard positionQtyValue > 0, let meta = meta else { return nil }
        return SimPosition(id: Self.trainingAccountID, accountID: Self.trainingAccountID,
                           metaID: meta.id, code: meta.code, name: meta.name,
                           qty: positionQtyValue, availableQty: sellableQty,
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

    /// 训练区间统计（顶栏徽标用）：口径与光标的区间统计一致（基准 = 起始训练日收盘价），
    /// 但区间固定为 [起始训练日, 当前训练日]，不依赖光标与可见窗口。
    /// M/高 = 区间最大涨幅（区间最高相对基准）、N/低 = 区间最大回撤（区间最低相对基准）、
    /// 振 = 训练振幅（区间最高 − 区间最低）、C/收 = 起始至今涨幅、
    /// 盈 = 持仓收益率（浮动 + 已实现，相对累计买入成本）、笔 = 成交笔数
    var rangeStats: TrainRangeStats {
        guard isActive else { return TrainRangeStats() }
        guard initialCapital > 0,
              let si = bars.firstIndex(where: { $0.date == startDate }),
              let ci = bars.firstIndex(where: { $0.date == trainingDate }), si <= ci else {
            return TrainRangeStats(trades: trades.count)
        }
        let base = bars[si].close
        guard base > 0 else { return TrainRangeStats(trades: trades.count) }
        let slice = bars[si...ci]
        let high = slice.map(\.high).max() ?? base
        let low = slice.map(\.low).min() ?? base
        // 浮动盈亏必须就地取当前训练日收盘价重算（avgCost × 持仓量），与「浮盈」面板同源；
        // 收益率分母用累计买入成本，这样 1/4 仓位、全仓都能读出「这笔仓位赚了多少」
        let floating = Double(positionQtyValue) * (bars[ci].close - avgCostValue)
        let pnlRatio = investedCostValue > 0 ? (realizedPnlValue + floating) / investedCostValue * 100 : 0
        return TrainRangeStats(trades: trades.count,
                               rally: (high - base) / base * 100,
                               drawdown: (low - base) / base * 100,
                               amplitude: (high - low) / base * 100,
                               change: (bars[ci].close - base) / base * 100,
                               pnl: pnlRatio)
    }

    // MARK: - 生命周期

    /// 开始训练：取全量日线（升序缓存）→ 吸附起始日 → 建会话 → 起始日即最新日则直接结束
    /// - Parameters:
    ///   - accountType: 百分比账户（不校验资金）/ 仓位金额账户（固定本金，买入校验）
    ///   - capital: 仓位金额账户的初始本金；百分比账户忽略（内部取名义本金）
    ///   - tradeMode: 交易模式：当日收盘价成交（下单即刻成交）/ 隔日委托（挂到下一训练日成交）
    @discardableResult
    func begin(meta: MetaItem, startDate: Int,
               accountType: TrainAccountType = .percent,
               capital: Double = TrainAccountRule.defaultCapital,
               tradeMode: TrainTradeMode = .sameDayClose) -> Bool {
        // 查询量很小（单只标的），允许同步调用
        let raw = DatabaseManager.shared.fetchDailyData(metaId: meta.id)   // date 降序
        let sorted = raw.sorted { $0.date < $1.date }                      // 升序
        guard let last = sorted.last else { return false }                 // 无行情 → 不改变状态

        // 起始日吸附到「date <= startDate 的最后一根」；不存在则取第一根
        let anchor = sorted.last(where: { $0.date <= startDate })?.date ?? sorted[0].date

        bars = sorted
        self.meta = meta
        self.accountType = accountType
        // 百分比账户用名义本金做「仓位比例 → 股数」的换算基，不参与资金校验
        self.initialCapital = accountType == .fixedAmount ? max(0, capital) : TrainAccountRule.notionalCapital
        self.cash = self.initialCapital
        self.startDate = anchor
        self.trainingDate = anchor
        self.latestDate = last.date
        self.trades = []
        self.conditions = []
        self.alerts = []
        self.tradeMode = tradeMode
        self.pendingOrders = []
        self.pendingRejectText = nil
        positionQtyValue = 0
        avgCostValue = 0
        lockedQtyValue = 0
        realizedPnlValue = 0
        investedCostValue = 0
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

    /// 推进一根 K 线；推进后先结算隔日委托（仅对新训练日有效），再结算条件单 / 预警，最后判是否到最新日。
    /// 隔日委托的成交日 = 推进后的新训练日（永远等于「当前训练日」，不会出现未来日期的成交）
    func advanceOneBar() async {
        guard isActive, !isFinished else { return }
        guard let i = bars.firstIndex(where: { $0.date == trainingDate }) else { return }
        let next = i + 1
        guard next < bars.count else { return }
        trainingDate = bars[next].date
        // 进入新训练日：T+1 标的昨日买入的份额当日解锁
        lockedQtyValue = 0

        await settlePendingOrders()

        await sweepConditions(reason: "ADVANCE")

        if trainingDate == latestDate {
            TrainingStore.shared.finishSession(id: sessionID, endDate: latestDate)
            isFinished = true
        }
    }

    /// 结算隔日委托队列（仅对刚推进到的新训练日有效）：
    /// 逐笔判断该日行情是否触及委托价（买入：最低价 ≤ 委托价；卖出：最高价 ≥ 委托价），
    /// 触及则按委托价成交（成交日 = 新训练日），未触及 / 校验失败即作废并提示；队列一律清空。
    private func settlePendingOrders() async {
        guard !pendingOrders.isEmpty else { return }
        let queued = pendingOrders
        pendingOrders = []
        guard let bar = bars.first(where: { $0.date == trainingDate }), bar.close > 0, bar.low > 0 else {
            pendingRejectText = "训练日 \(TrainSessionRecord.dateText(trainingDate)) 无可用行情，隔日委托已作废"
            return
        }
        let dateText = TrainSessionRecord.dateText(trainingDate)
        var notices: [String] = []
        for order in queued {
            // 买入：当日最低价跌到委托价及以下即视为成交；卖出：当日最高价涨到委托价及以上即视为成交
            let touched = order.direction == .buy ? bar.low <= order.price : bar.high >= order.price
            guard touched else {
                notices.append("\(order.direction.title) \(SimFormat.price(order.price)) 未触及"
                               + "（\(dateText) 区间 \(SimFormat.price(bar.low))~\(SimFormat.price(bar.high))），隔日委托已作废")
                continue
            }
            if let rejection = await settleTrade(direction: order.direction, qty: order.qty, note: order.note,
                                                 trigger: .manual, condKind: nil,
                                                 price: order.price, date: trainingDate) {
                notices.append("隔日委托未成交（\(dateText)）：\(rejection)")
            }
        }
        pendingRejectText = notices.isEmpty ? nil : notices.joined(separator: "\n")
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
        pendingOrders = []
        pendingRejectText = nil
        sessionID = ""
        isFinished = false
        bars = []
        startDate = 0
        trainingDate = 0
        latestDate = 0
        positionQtyValue = 0
        avgCostValue = 0
        lockedQtyValue = 0
        realizedPnlValue = 0
        investedCostValue = 0
        cash = 0
        initialCapital = 0
    }

    // MARK: - 下单

    /// 下单入口；返回 nil = 成功（成交或挂单），否则返回中文拒绝原因。
    /// 交易模式：
    ///   - 当日收盘价成交 → 立刻以当前训练日收盘价成交（成交日 = 当前训练日，不看委托价）
    ///   - 隔日委托     → 手动下单按 limitPrice 挂限价单，仅下一训练日有效：
    ///                    该日行情触及委托价（买入：最低价 ≤ 委托价；卖出：最高价 ≥ 委托价）
    ///                    才按委托价成交（成交日 = 该训练日），未触及即作废
    /// 条件单始终按「触发日收盘价」成交（判定口径即训练日收盘价），不受本开关影响。
    /// - Parameters:
    ///   - limitPrice: 委托价（隔日委托用；nil 取当前训练日收盘价）
    ///   - trigger: 触发来源（手动 / 条件单），落训练库供追溯
    ///   - condKind: 触发它的条件单类型中文名（手动为 nil）
    func placeTrade(direction: SimOrderDirection, qty: Int, note: String,
                    limitPrice: Double? = nil,
                    trigger: TrainTradeTrigger = .manual, condKind: String? = nil) async -> String? {
        guard isActive else { return "当前无进行中的训练" }
        guard let close = currentClose, close > 0 else { return "当前训练日无可用行情" }

        let lot = SimTradeRuleConstants.lotSize
        if qty <= 0 || qty % lot != 0 {
            return "委托数量需为 \(lot) 股的整数倍且大于 0"
        }

        // 隔日委托：只挂限价单，绝不在当前训练日、更不会在未来训练日成交
        if tradeMode == .nextDayClose, trigger == .manual {
            guard !isFinished else { return "训练已到最新交易日，无法再挂隔日委托" }
            let price = limitPrice ?? close
            guard price > 0 else { return "请输入有效的委托价" }
            // 挂单只对下一训练日有效，届时 T+1 锁定量已清零：可卖上限按「持仓 − 已挂卖单」算
            let queuedSell = pendingOrders.filter { $0.direction == .sell }.reduce(0) { $0 + $1.qty }
            if direction == .sell, qty > max(0, positionQtyValue - queuedSell) {
                return "训练持仓不足：当前持仓 \(SimFormat.shares(positionQtyValue)) 股"
                    + (queuedSell > 0 ? "（已挂卖单 \(SimFormat.shares(queuedSell)) 股）" : "")
            }
            if direction == .buy, accountType == .fixedAmount {
                // 挂单校验：费用 / 可买复核走引擎；引擎不可用 → 显式拒绝不挂单（§9.10）
                let amount = price * Double(qty)
                let fee: Double
                do {
                    fee = try await SimRulesBridge.tradeFee(amount: amount, direction: .buy)
                } catch {
                    DebugLogger.shared.log("[Training] placeTrade：引擎不可用（挂单校验）\(error)")
                    return Self.engineUnavailableText
                }
                if amount + fee > cash {
                    let affordable: Int
                    do {
                        affordable = try await SimRulesBridge.tradeAffordableQty(cash: cash, price: price)
                    } catch {
                        DebugLogger.shared.log("[Training] placeTrade：引擎不可用（可买复核）\(error)")
                        return Self.engineUnavailableText
                    }
                    return "可用资金不足，可买 \(affordable) 股（可用 \(SimFormat.amount(cash))）"
                }
            }
            pendingOrders.append(TrainPendingOrder(direction: direction, qty: qty, price: price,
                                                   note: note, placedDate: trainingDate))
            pendingRejectText = nil
            DebugLogger.shared.log("[Training] 隔日委托挂单 \(direction.title) \(qty) 股"
                                   + " 委托价=\(price) 挂单训练日=\(trainingDate) 队列=\(pendingOrders.count)")
            return nil
        }

        return await settleTrade(direction: direction, qty: qty, note: note,
                                 trigger: trigger, condKind: condKind, price: close, date: trainingDate)
    }

    /// 可卖上限拒绝文案（T+1 标的区分「当日买入锁定」与「持仓不足」）
    private func sellRejectionText(qty: Int) -> String {
        if settlementRule == .tPlus1, lockedQtyValue > 0 {
            return "\(settlementRule.title) 标的当日买入不可卖：当前可卖 \(sellableQty) 股（今日买入 \(lockedQtyValue) 股锁定中）"
        }
        return "训练持仓不足：当前可卖 \(sellableQty) 股"
    }

    /// 真正成交一笔：以 price 在训练日 date 落库并维护持仓 / 资金 / 盈亏统计。
    ///
    /// 阶段 C：成交业务逻辑全部下沉到 Python 引擎（`training_execute_trade` op）。
    /// Swift 仅负责入参装配 + 出参应用 + 落库。
    /// 引擎不可用 → 返回显式拒绝文案，**不落库**（§9.10 fail-closed）。
    private func settleTrade(direction: SimOrderDirection, qty: Int, note: String,
                             trigger: TrainTradeTrigger, condKind: String?,
                             price: Double, date: Int) async -> String? {
        // 构造会话状态快照（交给 Python 引擎计算）
        let sessionState: [String: Any] = [
            "cash": cash,
            "positionQty": positionQtyValue,
            "avgCost": avgCostValue,
            "lockedQty": lockedQtyValue,
            "realizedPnl": realizedPnlValue,
            "investedCost": investedCostValue
        ]

        let accountTypeStr = accountType == .fixedAmount ? "fixedAmount" : "percent"

        do {
            let result = try await SimRulesBridge.trainingExecuteTrade(
                sessionState: sessionState,
                tradeDirection: direction,
                tradeQty: qty,
                tradePrice: price,
                tradeDate: date,
                tradeNote: note,
                accountType: accountTypeStr
            )

            // 拒绝 → 不落库
            if let rejection = result.rejection {
                if let code = rejection["code"] as? String,
                   let message = rejection["message"] as? String {
                    return message
                }
                return Self.engineUnavailableText
            }

            // 应用更新后的状态
            if let state = result.state as? [String: Any] {
                if let newCash = state["cash"] as? Double {
                    cash = newCash
                }
                if let newPositionQty = state["positionQty"] as? Int {
                    positionQtyValue = newPositionQty
                }
                if let newAvgCost = state["avgCost"] as? Double {
                    avgCostValue = newAvgCost
                }
                if let newLockedQty = state["lockedQty"] as? Int {
                    lockedQtyValue = newLockedQty
                }
                if let newRealizedPnl = state["realizedPnl"] as? Double {
                    realizedPnlValue = newRealizedPnl
                }
                if let newInvestedCost = state["investedCost"] as? Double {
                    investedCostValue = newInvestedCost
                }
            }

            // 落库交易记录
            let tradeDict = result.trade ?? [:]
            let seq = trades.count + 1
            let tradePrice = tradeDict["price"] as? Double ?? price
            let tradeQty = tradeDict["qty"] as? Int ?? qty
            let tradeAmount = tradeDict["amount"] as? Double ?? (tradePrice * Double(tradeQty))
            let tradeFee = tradeDict["fee"] as? Double ?? 0
            let tradePnl = tradeDict["pnl"] as? Double

            let ok = TrainingStore.shared.appendTrade(sessionID: sessionID, seq: seq,
                                                      direction: direction,
                                                      tradeDate: date,
                                                      price: tradePrice,
                                                      qty: tradeQty,
                                                      amount: tradeAmount,
                                                      fee: tradeFee,
                                                      pnl: tradePnl,
                                                      note: note,
                                                      trigger: trigger,
                                                      condKind: condKind)
            guard ok else { return "训练交易落库失败" }

            trades = TrainingStore.shared.trades(sessionID: sessionID)
            DebugLogger.shared.log("[Training] 成交 \(direction == .buy ? "买" : "卖") \(qty) 股"
                                   + " 训练日=\(trainingDate) 成交日=\(date) 价=\(price)")
            return nil
        } catch {
            DebugLogger.shared.log("[Training] settleTrade：Python 引擎异常 \(error)")
            return Self.engineUnavailableText
        }
    }

    /// 预检用：某标的在 startDate（吸附到「date ≤ startDate 的最后一根」）的收盘价。
    /// 只读查询，不改动任何会话状态；供设置窗「金额账户至少能买两手」校验与随机抽取筛选使用。
    func anchorClose(meta: MetaItem, startDate: Int) -> Double? {
        let sorted = DatabaseManager.shared.fetchDailyData(metaId: meta.id).sorted { $0.date < $1.date }
        return sorted.last(where: { $0.date <= startDate })?.close
    }

    // MARK: - 条件单 / 预警管理

    /// 条件单编辑器的训练后端（取数走训练日快照，保存写训练库并立即结算）
    ///
    /// ⚠️ `save` 是同步闭包（`SimCondEditorView` 的编辑器协议，模拟态同形）：结算已在
    /// `.engine` 下只能 async，故内部起 Task 跑（`.swift` 模式同步 resume，时序不变）。
    var condEditorBackend: TrainingCondBackend {
        TrainingCondBackend(
            account: condEditorAccount,
            position: { [weak self] in self?.trainingPositionSnapshot },
            snapshot: { [weak self] order in self?.condSnapshot(for: order) ?? SimCondSnapshot() },
            save: { [weak self] order in Task { await self?.upsertCondition(order) } })
    }

    /// 条件单编辑器用的训练账户快照：资金按当前账户类型给（百分比账户 = 名义本金，金额账户 = 可用资金）
    private var condEditorAccount: SimAccount {
        let power = isActive ? buyingPower : TrainAccountRule.notionalCapital
        return SimAccount(id: Self.trainingAccountID, name: "训练账户", badge: "训",
                          colorHex: "#1E5FA8", initialCapital: power, cash: power,
                          createdAt: Date(timeIntervalSince1970: 0), isArchived: false)
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
    func upsertCondition(_ order: SimCondOrder) async {
        guard isActive, !sessionID.isEmpty else { return }
        _ = TrainingStore.shared.upsertCondition(sessionID: sessionID, order: order,
                                                 createdDate: trainingDate)
        reloadConditions()
        await sweepConditions(reason: "CREATE")
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
    /// 有效期（按训练日）→ 取训练日快照 → 引擎判定 → 命中写训练库
    ///
    /// A5-4（Training 路径）：非时间条件的判定走引擎（`.swift` 模式同步直通现状）；
    /// 引擎未就绪 / 异常 → 本轮不结算（条件单保持 monitoring，§9.10 fail-closed，
    /// 对齐 `SimCondEngine.sweepConditions`）。时间条件仍按训练日本地判定（引擎不适用）。
    func sweepConditions(reason: String) async {
        guard isActive, !sessionID.isEmpty, !conditions.isEmpty else { return }
        guard SimRulesBridge.judgmentAvailable else {
            DebugLogger.shared.log("[Training] 条件单结算(\(reason))：引擎未就绪，本轮不结算")
            return
        }
        // 重入守卫：结算已在进行中直接返回（对齐 `SimCondEngine.sweepConditions`）
        guard !condSweepInFlight else {
            DebugLogger.shared.log("[Training] 条件单结算(\(reason))：上一轮结算未完成，跳过本轮")
            return
        }
        condSweepInFlight = true
        defer { condSweepInFlight = false }

        // 构造输入参数
        var snapshots: [UUID: SimCondSnapshot] = [:]
        for record in conditions {
            snapshots[record.order.id] = condSnapshot(for: record.order)
        }

        do {
            let sweepResult = try await SimRulesBridge.trainingSweep(
                orders: conditions.map { $0.order },
                snapshots: snapshots,
                trainingDate: trainingDate,
                tzOffsetSeconds: TimeZone.current.secondsFromGMT()
            )

            // 应用更新后的条件单（保留原始 createdDate）
            var updatedConditions: [TrainCondRecord] = []
            for order in sweepResult.orders {
                if let existing = conditions.first(where: { $0.order.id == order.id }) {
                    updatedConditions.append(TrainCondRecord(order: order, createdDate: existing.createdDate))
                } else {
                    updatedConditions.append(TrainCondRecord(order: order, createdDate: TrainingSessionController.dateInt(Date())))
                }
            }
            conditions = updatedConditions

            // 处理交易意图
            var fired = false
            for intent in sweepResult.tradeIntents {
                guard let direction = SimOrderDirection(rawValue: intent["direction"] as? String ?? "") else { continue }
                let qty = intent["qty"] as? Int ?? 0
                let price = intent["price"] as? Double
                let date = intent["date"] as? Int ?? trainingDate
                let note = intent["note"] as? String ?? ""
                let kind = SimCondKind(rawValue: intent["kind"] as? String ?? "") ?? .price

                let rejection = await settleTrade(direction: direction, qty: qty, note: note,
                                                  trigger: .cond, condKind: kind.rawValue,
                                                  price: price ?? 0, date: date)
                if rejection == nil {
                    fired = true
                }
            }

                // 应用预警记录
            for alertDict in sweepResult.alertRecords {
                if let id = alertDict["id"] as? String,
                   let condID = alertDict["condID"] as? String,
                   let price = alertDict["price"] as? Double,
                   let message = alertDict["message"] as? String,
                   let occurredAt = alertDict["occurredAt"] as? Date {
                    let record = TrainAlertRecord(id: id, sessionID: sessionID, condID: condID,
                                                  tradeDate: trainingDate, price: price,
                                                  message: message, occurredAt: occurredAt)
                    alerts.append(record)
                }
            }
            if !sweepResult.alertRecords.isEmpty {
                reloadAlerts()
            }

            trades = TrainingStore.shared.trades(sessionID: sessionID)
            DebugLogger.shared.log("[Training] 条件单结算(\(reason))：\(conditions.count) 条，\(fired ? "有" : "无")触发")
        } catch {
            DebugLogger.shared.log("[Training] 条件单结算(\(reason))：Python 引擎异常 \(error)")
        }
    }

    // MARK: - 结算辅助

    /// 「仅提醒」不下单；普通条件单以训练日收盘价写入一笔训练成交
    ///
    /// A5-5：触发分支全走引擎（B 组 `cond_alert_message` / `cond_fire_direction` / `cond_advance` /
    /// `cond_repeatable_finished`）；**引擎异常 → 跳过本单**（不改状态、不下单），与
    /// `SimCondEngine.fireAlertOnly` / `fire` 同口径。
    private func fireCondition(_ record: TrainCondRecord, qty: Int, at triggerPrice: Double,
                               snapshot: SimCondSnapshot, now: Date) async -> TrainCondRecord {
        var target = record
        let order = target.order

        if order.directive.isAlertOnly {
            // 预警文案（B 组）；引擎异常 → 跳过本单（不记预警、不改状态）
            let message: String
            do {
                message = try await SimRulesBridge.condAlertMessage(order: order,
                                                                   triggerPrice: triggerPrice)
            } catch {
                DebugLogger.shared.log("[Training] 条件单预警：引擎异常，跳过 \(order.name) \(error)")
                return record
            }
            target.order.runtime.lastEvaluatedAt = now
            target.order.runtime.lastPrice = snapshot.last ?? order.runtime.lastPrice
            target.order.runtime.lastTriggerPrice = triggerPrice
            target.order.triggeredCount += 1
            target.order.updatedAt = now
            _ = TrainingStore.shared.appendAlert(TrainAlertRecord(
                id: UUID().uuidString, sessionID: sessionID, condID: order.id.uuidString,
                tradeDate: trainingDate, price: triggerPrice, message: message, occurredAt: now))
            await advanceRepeatable(&target.order, pendingMessage: message)
            if !order.kind.repeatable {
                target.order.status = .triggered
                target.order.triggeredAt = now
                target.order.runtime.lastMessage = message
            }
            return target
        }

        // 触发方向（B 组）：引擎裁决；异常 / 出参非法 → 跳过本单（不改状态、不下单）
        let direction: SimOrderDirection
        do {
            guard let dir = try await SimRulesBridge.condFireDirection(order: order,
                                                                      triggerPrice: triggerPrice) else {
                DebugLogger.shared.log("[Training] 条件单触发：方向输出非法，跳过 \(order.name)")
                return record
            }
            direction = dir
        } catch {
            DebugLogger.shared.log("[Training] 条件单触发：引擎异常，跳过 \(order.name) \(error)")
            return record
        }

        target.order.runtime.lastEvaluatedAt = now
        target.order.runtime.lastPrice = snapshot.last ?? order.runtime.lastPrice
        target.order.runtime.lastTriggerPrice = triggerPrice
        target.order.updatedAt = now

        let rejection = await placeTrade(direction: direction, qty: qty,
                                         note: "条件单：\(order.kind.title)",
                                         trigger: .cond, condKind: order.kind.title)
        if rejection == nil {
            target.order.triggeredCount += 1
            if order.kind.repeatable {
                await advanceRepeatable(&target.order)
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

    /// 多触发类型（网格 / 分批）的档位 / 批次推进（B 组：推进与完成判定都走引擎）。
    /// 引擎异常 → 保持 monitoring 不推进（不抛出、不中断本轮结算，对齐 `SimCondEngine.fire`）。
    /// - Parameter pendingMessage: 未走完时写入 `lastMessage` 的文案（nil = 「已成交第 N 档 / 批」默认文案）
    private func advanceRepeatable(_ order: inout SimCondOrder, pendingMessage: String? = nil) async {
        guard order.kind.repeatable else { return }
        do {
            order.runtime = try await SimRulesBridge.condAdvance(order: order,
                                                                triggerPrice: order.runtime.lastTriggerPrice ?? 0)
            if try await SimRulesBridge.condRepeatableFinished(order: order) {
                order.status = .completed
                order.runtime.lastMessage = order.kind == .grid ? "已完成全部档位" : "已完成全部批次"
            } else if let pendingMessage {
                order.runtime.lastMessage = pendingMessage
            } else {
                order.runtime.lastMessage = order.kind == .grid
                    ? "已成交第 \(order.runtime.gridLevel ?? 0) 档"
                    : "已成交第 \(order.runtime.batchDone) 批"
            }
        } catch {
            DebugLogger.shared.log("[Training] 条件单档位推进：引擎异常 \(error)")
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

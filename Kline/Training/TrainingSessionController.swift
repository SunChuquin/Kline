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
    func advanceOneBar() {
        guard isActive, !isFinished else { return }
        guard let i = bars.firstIndex(where: { $0.date == trainingDate }) else { return }
        let next = i + 1
        guard next < bars.count else { return }
        trainingDate = bars[next].date
        // 进入新训练日：T+1 标的昨日买入的份额当日解锁
        lockedQtyValue = 0

        settlePendingOrders()

        sweepConditions(reason: "ADVANCE")

        if trainingDate == latestDate {
            TrainingStore.shared.finishSession(id: sessionID, endDate: latestDate)
            isFinished = true
        }
    }

    /// 结算隔日委托队列（仅对刚推进到的新训练日有效）：
    /// 逐笔判断该日行情是否触及委托价（买入：最低价 ≤ 委托价；卖出：最高价 ≥ 委托价），
    /// 触及则按委托价成交（成交日 = 新训练日），未触及 / 校验失败即作废并提示；队列一律清空。
    private func settlePendingOrders() {
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
            if let rejection = settleTrade(direction: order.direction, qty: order.qty, note: order.note,
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
                    trigger: TrainTradeTrigger = .manual, condKind: String? = nil) -> String? {
        guard isActive else { return "当前无进行中的训练" }
        guard let close = currentClose, close > 0 else { return "当前训练日无可用行情" }

        let lot = SimTradingRules.default.lotSize
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
                let amount = price * Double(qty)
                let fee = SimTradingRules.default.fee(amount: amount, direction: .buy)
                if amount + fee > cash {
                    return "可用资金不足，可买 \(SimTradingRules.default.affordableQty(cash: cash, price: price)) 股（可用 \(SimFormat.amount(cash))）"
                }
            }
            pendingOrders.append(TrainPendingOrder(direction: direction, qty: qty, price: price,
                                                   note: note, placedDate: trainingDate))
            pendingRejectText = nil
            DebugLogger.shared.log("[Training] 隔日委托挂单 \(direction.title) \(qty) 股"
                                   + " 委托价=\(price) 挂单训练日=\(trainingDate) 队列=\(pendingOrders.count)")
            return nil
        }

        return settleTrade(direction: direction, qty: qty, note: note,
                           trigger: trigger, condKind: condKind, price: close, date: trainingDate)
    }

    /// 可卖上限拒绝文案（T+1 标的区分「当日买入锁定」与「持仓不足」）
    private func sellRejectionText(qty: Int) -> String {
        if settlementRule == .tPlus1, lockedQtyValue > 0 {
            return "\(settlementRule.title) 标的当日买入不可卖：当前可卖 \(sellableQty) 股（今日买入 \(lockedQtyValue) 股锁定中）"
        }
        return "训练持仓不足：当前可卖 \(sellableQty) 股"
    }

    /// 真正成交一笔：以 price 在训练日 date 落库并维护持仓 / 资金 / 盈亏统计
    private func settleTrade(direction: SimOrderDirection, qty: Int, note: String,
                             trigger: TrainTradeTrigger, condKind: String?,
                             price: Double, date: Int) -> String? {
        // 训练不支持做空；可卖上限按标的交收规则（T+1 扣当日买入锁定、T+0 全可卖）
        if direction == .sell, qty > sellableQty { return sellRejectionText(qty: qty) }

        let amount = price * Double(qty)
        let fee = SimTradingRules.default.fee(amount: amount, direction: direction)
        // 仓位金额账户：买入前校验资金（百分比账户不校验，永远买得起）
        if direction == .buy, accountType == .fixedAmount, amount + fee > cash {
            let affordable = SimTradingRules.default.affordableQty(cash: cash, price: price)
            return "可用资金不足，可买 \(affordable) 股（可用 \(SimFormat.amount(cash))）"
        }
        let pnl: Double? = direction == .sell ? (price - avgCostValue) * Double(qty) - fee : nil
        let seq = trades.count + 1

        let ok = TrainingStore.shared.appendTrade(sessionID: sessionID, seq: seq, direction: direction,
                                                  tradeDate: date, price: price, qty: qty,
                                                  amount: amount, fee: fee, pnl: pnl, note: note,
                                                  trigger: trigger, condKind: condKind)
        guard ok else { return "训练交易落库失败" }

        // 持仓 / 均价：买入加权平均；卖出均价不变，清仓归零
        if direction == .buy {
            let q0 = positionQtyValue
            let q = q0 + qty
            avgCostValue = q > 0 ? (avgCostValue * Double(q0) + price * Double(qty)) / Double(q) : 0
            positionQtyValue = q
            // 当日买入份额在 T+1 标的当日不可卖 → 计入锁定量（T+0 标的该量不参与可卖计算）
            lockedQtyValue += qty
        } else {
            positionQtyValue -= qty
            if positionQtyValue <= 0 {
                positionQtyValue = 0
                avgCostValue = 0
                lockedQtyValue = 0
            } else {
                // 卖出只消耗可卖（未锁定）部分，锁定量不得超过剩余持仓
                lockedQtyValue = min(lockedQtyValue, positionQtyValue)
            }
        }

        // 仓位金额账户按成交额与费用记账（百分比账户不追踪资金）
        if accountType == .fixedAmount {
            cash += direction == .buy ? -(amount + fee) : (amount - fee)
            if cash < 0 { cash = 0 }
        }

        // 已实现盈亏累计（买入记 -费用、卖出记 (价-均价)*量-费用）：供顶栏「盈」，
        // 百分比账户不记资金流，只能靠此口径统计收益；同时累计买入成本作收益率分母
        if direction == .buy {
            realizedPnlValue -= fee
            investedCostValue += amount
        } else {
            realizedPnlValue += pnl ?? 0
        }

        // 直接回读库内记录（id / seq / mark 与落库一致，做 T 提升也能立刻反映）
        trades = TrainingStore.shared.trades(sessionID: sessionID)
        DebugLogger.shared.log("[Training] 成交 \(direction == .buy ? "买" : "卖") \(qty) 股"
                               + " 训练日=\(trainingDate) 成交日=\(date) 价=\(price)")
        return nil
    }

    /// 预检用：某标的在 startDate（吸附到「date ≤ startDate 的最后一根」）的收盘价。
    /// 只读查询，不改动任何会话状态；供设置窗「金额账户至少能买两手」校验与随机抽取筛选使用。
    func anchorClose(meta: MetaItem, startDate: Int) -> Double? {
        let sorted = DatabaseManager.shared.fetchDailyData(metaId: meta.id).sorted { $0.date < $1.date }
        return sorted.last(where: { $0.date <= startDate })?.close
    }

    // MARK: - 条件单 / 预警管理

    /// 条件单编辑器的训练后端（取数走训练日快照，保存写训练库并立即结算）
    var condEditorBackend: TrainingCondBackend {
        TrainingCondBackend(
            account: condEditorAccount,
            position: { [weak self] in self?.trainingPositionSnapshot },
            snapshot: { [weak self] order in self?.condSnapshot(for: order) ?? SimCondSnapshot() },
            save: { [weak self] order in self?.upsertCondition(order) })
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

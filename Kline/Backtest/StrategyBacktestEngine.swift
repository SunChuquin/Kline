//
//  StrategyBacktestEngine.swift
//  Kline
//
//  策略完整历史回测：纯逻辑引擎（逐日推进，复用费率 / T+1 / 涨跌停口径）+ 取数与 as-of 命中运行器。
//
//  Created by 孙楚昆 on 2026/9/20.
//

import Foundation
import Combine

// MARK: - 回测内部值类型（回测独立账本，与 SimStore 无关）

/// 回测持仓
///
/// 成本价按「成交额 + 买入费用」加权：这样「净值 = 初始资金 + 已实现盈亏 + 期末浮动盈亏」
/// 精确成立（若不计买入费用，净值与两者之和会差一个 Σ买入费用）。
private struct BacktestPosition {
    var metaID: Int
    var qty: Int
    var availableQty: Int
    var costPrice: Double
    var openedDate: Int                // 开仓日（YYYYMMDD），T+1 用
    var gridLevel: Int = 0             // 网格已触发档位数
    var gridBasePrice: Double = 0      // 网格基准价（首次评估时取 gridBase）
    var gridLastPrice: Double = 0      // 网格上次触发价
    var gridStopped: Bool = false      // 价格越出区间 → 该规则停止
    var extreme: Double = 0            // 开仓后最高价（TRAILING 用）
    var batchDone: Int = 0             // 分批已完成笔数
    var planRules: [BacktestPlanRule] = []   // 本 bar 现场重算的计划规则
}

/// 规则 → 条件单参数的映射结果
///
/// 由阶段二的 `StrategyCondGenerator.drafts` 产出（沿用同一张映射表，不重复实现），
/// 回测自己再做逐 bar 的触发判定。
private struct BacktestPlanRule {
    var kind: StrategyRuleKind
    var params: SimCondParams
    var direction: SimOrderDirection
    var qty: Int
}

/// 待成交动作（默认信号次日开盘成交）
private struct BacktestPendingAction {
    var metaID: Int
    var signalDate: Int
    var direction: SimOrderDirection
    var desiredQty: Int          // 0 = 卖出全部可卖；买入传具体股数
    var priceType: SimPriceType
    var offsetTicks: Int
    var triggerPrice: Double     // 信号日收盘价（限价基准）
    var ruleKind: StrategyRuleKind?
}

/// 取消标志盒（后台队列与主线程共用，锁保护；不挂 actor 以便后台直接读）
private final class BacktestCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock(); value = true; lock.unlock()
    }

    func reset() {
        lock.lock(); value = false; lock.unlock()
    }
}

// MARK: - 纯逻辑引擎

/// 历史回测引擎：输入全部就绪的数据，输出净值曲线与明细（纯函数，同参数重复调用结果一致）
///
/// 硬边界：
/// - 整体 `nonisolated`，不访问 `DatabaseManager` / `MarketRowCache` / `SimStore`（所有 IO 只在运行器里）；
/// - 输入输出全值类型；内部所有集合遍历显式排序（`sorted()`），无随机、无字典序依赖；
/// - 费用与可买量复用 `SimTradingRules.default`，涨跌停复用 `limitRange(prevClose:)`，不复制口径；
/// - 规则 → `SimCondKind` + `SimCondParams` + `SimCondDirective` 复用 `StrategyCondGenerator.drafts`。
enum StrategyBacktestEngine {

    /// 回测主入口
    /// - Parameters:
    ///   - bars: 标的 → **升序** bars
    ///   - pickHits: 标的 → 命中日期集合（as-of 已算好，元素为 YYYYMMDD）
    ///   - metas: 标的 → MetaItem（缺失时用占位元数据）
    nonisolated static func run(doc: FormulaDoc,
                                bars: [Int: [KlineItem]],
                                pickHits: [Int: Set<Int>],
                                metas: [Int: MetaItem],
                                params: BacktestParams) -> BacktestResult {
        var warnings: [String] = []
        var skipped: [String] = []
        let rules = SimTradingRules.default

        // MARK: 1. 窗口与交易日历
        // 每只标的取最后 params.days 根；窗口起点 = 各标的窗口首日的最小值；交易日历 = 参与标的在窗口内 date 的并集升序
        var series: [Int: [KlineItem]] = [:]            // 标的 → 全序列（升序，用于取昨收）
        var windows: [Int: [KlineItem]] = [:]           // 标的 → 窗口内升序 bars
        var indexByDate: [Int: [Int: Int]] = [:]        // 标的 → date → 全序列下标
        var windowIndexByDate: [Int: [Int: Int]] = [:]  // 标的 → date → 窗口内下标
        var windowCloses: [Int: [Double]] = [:]         // 标的 → 窗口内 close 序列（MA 自算用）

        for id in bars.keys.sorted() {
            let full = bars[id] ?? []
            if full.isEmpty {
                skipped.append("\(metaTitle(metas[id], id))：无历史行情数据，已跳过")
                continue
            }
            if full.count < 30 {
                skipped.append("\(metaTitle(metas[id], id))：行情不足 30 根（\(full.count)），已跳过")
                continue
            }
            let win = Array(full.suffix(max(params.days, 1)))
            var map: [Int: Int] = [:]
            map.reserveCapacity(full.count)
            for (i, bar) in full.enumerated() { map[bar.date] = i }
            var winMap: [Int: Int] = [:]
            winMap.reserveCapacity(win.count)
            for (i, bar) in win.enumerated() { winMap[bar.date] = i }

            series[id] = full
            windows[id] = win
            indexByDate[id] = map
            windowIndexByDate[id] = winMap
            windowCloses[id] = win.map { $0.close }
        }

        let included = windows.keys.sorted()
        guard !included.isEmpty else {
            return emptyResult(params: params, scanned: bars.count, skipped: skipped)
        }

        var calendarSet = Set<Int>()
        for id in included {
            for bar in windows[id] ?? [] { calendarSet.insert(bar.date) }
        }
        let calendar = calendarSet.sorted()

        // MARK: 1b. 未来函数静态扫描（纯文本级，只提示不阻断）
        warnings.append(contentsOf: futureFunctionWarnings(text: doc.pickBody))

        // MARK: 1c. 单日跳空 > 11% 的标的数（疑似除权 → 假暴跌误触发卖点，去重合并成 1 条）
        var gapMetaCount = 0
        for id in included {
            let win = windows[id] ?? []
            guard win.count > 1 else { continue }
            for i in 1..<win.count where win[i - 1].close > 0 {
                let change = abs((win[i].close - win[i - 1].close) / win[i - 1].close)
                if change > 0.11 { gapMetaCount += 1; break }
            }
        }
        if gapMetaCount > 0 {
            warnings.append("\(gapMetaCount) 只标的出现单日跳空 > 11%，疑似除权，结果可能失真")
        }

        // MARK: 2. 账本状态
        var cash = params.initialCapital
        var positions: [Int: BacktestPosition] = [:]
        var pending: [BacktestPendingAction] = []
        var equityPoints: [BacktestEquityPoint] = []
        var trades: [BacktestTrade] = []
        var lastClose: [Int: Double] = [:]
        // 未成交原因计数（逐笔记 warning 会刷屏，改为汇总）
        var limitUpBlocks = 0, limitDownBlocks = 0, t1Blocks = 0

        // MARK: 3. 局部工具（捕获上面的账本状态）

        /// 取某标的某日的 bar（无该日行情返回 nil）
        func barOn(_ id: Int, _ date: Int) -> KlineItem? {
            guard let i = indexByDate[id]?[date], let s = series[id], i >= 0, i < s.count else { return nil }
            return s[i]
        }

        /// 昨收（全序列前一根 close；无前一根时退化用当日开盘价）
        func prevCloseOf(_ id: Int, bar: KlineItem) -> Double {
            guard let i = indexByDate[id]?[bar.date], let s = series[id], i > 0 else { return bar.open }
            return s[i - 1].close
        }

        /// 窗口内自算 PERIOD 简单均线（不足周期返回 nil，即不出信号）
        func maValue(_ id: Int, period: Int, index: Int) -> Double? {
            guard period > 0, index >= period - 1, let closes = windowCloses[id], index < closes.count else { return nil }
            var sum = 0.0
            for k in (index - period + 1)...index { sum += closes[k] }
            return sum / Double(period)
        }

        /// 成交价口径：触发价落在 bar 内 → 用触发价；整根 bar 都在触发价之外（跳空）→ 用开盘价
        func fillPrice(trigger: Double, bar: KlineItem) -> Double {
            if trigger > bar.high { return bar.open }
            return max(trigger, bar.low)
        }

        /// 买入成交：涨停拦截 → 资金不足缩量 → 建 / 加持仓（T+1：当日买入不加可卖）
        func performBuy(metaID: Int, signalDate: Int, date: Int, ruleKind: StrategyRuleKind?,
                        bar: KlineItem, price: Double, desiredQty: Int) -> Bool {
            guard price > 0 else { return false }
            let lot = max(rules.lotSize, 1)
            // 成交价触涨停（涨跌停上界）→ 不成交
            if let range = rules.limitRange(prevClose: prevCloseOf(metaID, bar: bar)), price >= range.upperBound {
                limitUpBlocks += 1
                return false
            }
            let affordable = rules.affordableQty(cash: cash, price: price)
            var qty = desiredQty > 0 ? desiredQty : affordable
            qty = qty / lot * lot
            if qty > affordable { qty = affordable }        // 资金不足 → 按可买量缩量
            guard qty > 0 else {
                if skipped.count < 200 {
                    skipped.append("\(date) \(metaTitle(metas[metaID], metaID))：可用资金不足，买入跳过")
                }
                return false
            }
            let amount = price * Double(qty)
            let fee = rules.fee(amount: amount, direction: .buy)
            cash -= amount + fee
            if var pos = positions[metaID], pos.qty > 0 {
                let newQty = pos.qty + qty
                pos.costPrice = (Double(pos.qty) * pos.costPrice + amount + fee) / Double(newQty)
                pos.qty = newQty
                positions[metaID] = pos                     // availableQty 不变（当日买入不可卖）
            } else {
                positions[metaID] = BacktestPosition(metaID: metaID, qty: qty, availableQty: 0,
                                                     costPrice: (amount + fee) / Double(qty),
                                                     openedDate: date, extreme: bar.high)
            }
            trades.append(BacktestTrade(signalDate: signalDate, date: date, metaID: metaID,
                                        code: metas[metaID]?.code ?? "", name: metas[metaID]?.name ?? "",
                                        ruleKind: ruleKind, direction: .buy, qty: qty, price: price,
                                        amount: amount, fee: fee, realizedPnL: nil, holdDays: nil))
            return true
        }

        /// 卖出成交：跌停拦截 → T+1 可卖限制 → 按加权成本价结算已实现盈亏；返回实际成交股数
        func performSell(metaID: Int, signalDate: Int, date: Int, ruleKind: StrategyRuleKind?,
                         bar: KlineItem, price: Double, desiredQty: Int) -> Int {
            guard price > 0, let pos = positions[metaID], pos.qty > 0 else { return 0 }
            let lot = max(rules.lotSize, 1)
            // 成交价触跌停（涨跌停下界）→ 不成交
            if let range = rules.limitRange(prevClose: prevCloseOf(metaID, bar: bar)), price <= range.lowerBound {
                limitDownBlocks += 1
                return 0
            }
            let sellable = rules.tPlus1Enabled ? pos.availableQty : pos.qty
            var qty = desiredQty > 0 ? desiredQty : sellable
            if qty > sellable { qty = sellable }
            qty = qty / lot * lot
            guard qty > 0 else {
                t1Blocks += 1
                if skipped.count < 200 {
                    skipped.append("\(date) \(metaTitle(metas[metaID], metaID))：可卖数量不足（T+1 或已清仓），卖出跳过")
                }
                return 0
            }
            let amount = price * Double(qty)
            let fee = rules.fee(amount: amount, direction: .sell)
            let pnl = (price - pos.costPrice) * Double(qty) - fee
            cash += amount - fee
            var updated = pos
            updated.qty -= qty
            updated.availableQty = max(0, updated.availableQty - qty)
            if updated.qty <= 0 {
                positions.removeValue(forKey: metaID)
            } else {
                positions[metaID] = updated
            }
            trades.append(BacktestTrade(signalDate: signalDate, date: date, metaID: metaID,
                                        code: metas[metaID]?.code ?? "", name: metas[metaID]?.name ?? "",
                                        ruleKind: ruleKind, direction: .sell, qty: qty, price: price,
                                        amount: amount, fee: fee, realizedPnL: pnl,
                                        holdDays: daysBetween(pos.openedDate, date)))
            return qty
        }

        /// 入场数量：TRADE.QTY → TRADE.AMOUNT 按信号日收盘价折算整手 → 缺省「可用资金的 20%」折算整手（至少 1 手）
        func entryQty(id: Int, price: Double) -> Int {
            let lot = max(rules.lotSize, 1)
            let trade = doc.trade
            if let qty = trade.qty, qty > 0 { return qty / lot * lot }
            guard price > 0 else { return 0 }
            if let amount = trade.amount, amount > 0 {
                return max(Int(amount / price / Double(lot)) * lot, lot)
            }
            guard cash > 0 else { return 0 }
            return max(Int(cash * 0.2 / price / Double(lot)) * lot, lot)
        }

        /// 规则 → 条件单参数：复用阶段二的 `StrategyCondGenerator.drafts`（nonisolated 纯函数，不重复映射表）
        /// meta / accountID 只用于装配草稿的展示字段，回测不使用
        func planRules(metaID: Int, costPrice: Double, lastPrice: Double) -> [BacktestPlanRule] {
            let meta = metas[metaID] ?? MetaItem(id: metaID, file: "", code: "", name: "", type: "",
                                                 firstDate: nil, lastDate: nil)
            let accountID = UUID(uuidString: "00000000-0000-0000-0000-00000000BACC") ?? UUID()
            let mapped = StrategyCondGenerator.drafts(doc: doc, meta: meta, accountID: accountID,
                                                     lastPrice: lastPrice, costPrice: costPrice)
            return mapped.drafts.map { draft in
                BacktestPlanRule(kind: strategyKind(draft.kind), params: draft.params,
                                 direction: draft.directive.direction, qty: draft.directive.qty)
            }
        }

        /// 信号类离场（涨跌幅 / 均线）：默认次日开盘成交（与入场同口径）
        func scheduleExit(metaID: Int, kind: StrategyRuleKind, date: Int, bar: KlineItem) {
            if params.executeNextOpen {
                pending.append(BacktestPendingAction(metaID: metaID, signalDate: date, direction: .sell,
                                                     desiredQty: 0, priceType: .market, offsetTicks: 0,
                                                     triggerPrice: bar.close, ruleKind: kind))
            } else {
                _ = performSell(metaID: metaID, signalDate: date, date: date, ruleKind: kind,
                                bar: bar, price: bar.close, desiredQty: 0)
            }
        }

        /// 整仓离场判定：按计划规则逐条判定，命中即卖出全部可卖；同一 bar 内止损腿优先于止盈腿
        func evaluateFullExit(metaID: Int, date: Int, bar: KlineItem) -> Bool {
            guard let pos = positions[metaID], pos.qty > 0 else { return false }
            for rule in pos.planRules {
                switch rule.kind {
                case .grid, .batch:
                    continue                                     // 多触发类型在 evaluateGrid / evaluateBatch 处理

                case .price:
                    guard rule.direction == .sell, let trigger = rule.params.triggerPrice,
                          trigger > 0, bar.low <= trigger else { continue }
                    _ = performSell(metaID: metaID, signalDate: date, date: date, ruleKind: .price,
                                    bar: bar, price: fillPrice(trigger: trigger, bar: bar), desiredQty: 0)
                    return true

                case .stopLoss:
                    // 止损腿优先（与 SimCondRule.evaluate 同序）；MODE=PCT 时触发价已由成本价换算好
                    if let stop = rule.params.stopLossPrice, stop > 0, bar.low <= stop {
                        _ = performSell(metaID: metaID, signalDate: date, date: date, ruleKind: .stopLoss,
                                        bar: bar, price: fillPrice(trigger: stop, bar: bar), desiredQty: 0)
                        return true
                    }
                    if let take = rule.params.takeProfitPrice, take > 0, bar.high >= take {
                        _ = performSell(metaID: metaID, signalDate: date, date: date, ruleKind: .stopLoss,
                                        bar: bar, price: fillPrice(trigger: take, bar: bar), desiredQty: 0)
                        return true
                    }

                case .trailing:
                    // 先用 high 推进极值（已在主循环里做过），再判回撤；保底价优先
                    if rule.params.floorEnabled, let floor = rule.params.floorPrice, floor > 0, bar.low <= floor {
                        _ = performSell(metaID: metaID, signalDate: date, date: date, ruleKind: .trailing,
                                        bar: bar, price: fillPrice(trigger: floor, bar: bar), desiredQty: 0)
                        return true
                    }
                    if let pct = rule.params.trailPct, pct > 0, pos.extreme > 0 {
                        let trigger = pos.extreme * (1 - pct / 100)
                        if bar.low <= trigger {
                            _ = performSell(metaID: metaID, signalDate: date, date: date, ruleKind: .trailing,
                                            bar: bar, price: fillPrice(trigger: trigger, bar: bar), desiredQty: 0)
                            return true
                        }
                    }

                case .time:
                    guard let fire = rule.params.fireDate, date >= dateInt(fire) else { continue }
                    let price = params.executeNextOpen ? bar.open : bar.close
                    _ = performSell(metaID: metaID, signalDate: date, date: date, ruleKind: .time,
                                    bar: bar, price: price, desiredQty: 0)
                    return true

                case .changePct:
                    guard let threshold = rule.params.changeThreshold, threshold != 0 else { continue }
                    let prev = prevCloseOf(metaID, bar: bar)
                    guard prev > 0 else { continue }
                    let changePct = (bar.close - prev) / prev * 100
                    let hit = threshold > 0 ? (changePct >= threshold) : (changePct <= threshold)
                    guard hit else { continue }
                    scheduleExit(metaID: metaID, kind: .changePct, date: date, bar: bar)
                    return true

                case .maCross:
                    guard let period = rule.params.maPeriod, let above = rule.params.maAbove,
                          let index = windowIndexByDate[metaID]?[date],
                          let ma = maValue(metaID, period: period, index: index),
                          let prevMa = maValue(metaID, period: period, index: index - 1) else { continue }
                    let prev = prevCloseOf(metaID, bar: bar)
                    let hit = above ? (prev <= prevMa && bar.close >= ma) : (prev > prevMa && bar.close <= ma)
                    guard hit else { continue }
                    scheduleExit(metaID: metaID, kind: .maCross, date: date, bar: bar)
                    return true
                }
            }
            return false
        }

        /// 网格（多触发）：bar 内可多档；low 判下移一档买入、high 判上移一档卖出；价格越出区间则该规则停止
        func evaluateGrid(metaID: Int, date: Int, bar: KlineItem) {
            guard let rule = positions[metaID]?.planRules.first(where: { $0.kind == .grid }) else { return }
            guard var pos = positions[metaID], pos.qty > 0, !pos.gridStopped else { return }
            let p = rule.params
            guard let base = p.gridBase, let lower = p.gridLower, let upper = p.gridUpper,
                  let stepPct = p.gridStepPct, stepPct > 0,
                  let perLevel = p.gridQtyPerLevel, perLevel > 0 else { return }
            if pos.gridBasePrice <= 0 {
                pos.gridBasePrice = base
                pos.gridLastPrice = base
                pos.gridLevel = 0
            }
            // 价格越出 [gridLower, gridUpper] → 该规则停止（记一次 warning）
            if bar.high > upper || bar.low < lower {
                pos.gridStopped = true
                positions[metaID] = pos
                warnings.append("\(date) \(metaTitle(metas[metaID], metaID)) 价格越出网格区间 "
                                + "[\(priceText(lower)), \(priceText(upper))]，网格规则停止")
                return
            }
            let step = stepPct / 100 * pos.gridBasePrice     // 每档步长按基准价换算（与参数目录的百分数口径一致）
            guard step > 0 else { positions[metaID] = pos; return }
            let maxLevels = max(gridLevelCount(params: p), 1)
            positions[metaID] = pos

            // 下移：买入（每档目标价 = 上次触发价 - step）
            for _ in 0..<maxLevels {
                guard let cur = positions[metaID], cur.gridLevel < maxLevels else { break }
                let target = cur.gridLastPrice - step
                guard bar.low <= target else { break }
                let qty = gridQty(params: p, level: cur.gridLevel, perLevel: perLevel)
                guard qty > 0 else { break }
                guard performBuy(metaID: metaID, signalDate: date, date: date, ruleKind: .grid,
                                 bar: bar, price: target, desiredQty: qty) else { break }
                positions[metaID]?.gridLevel = cur.gridLevel + 1
                positions[metaID]?.gridLastPrice = target
            }
            // 上移：卖出（卖出同档数量，受可卖限制）
            for _ in 0..<maxLevels {
                guard let cur = positions[metaID], cur.gridLevel > 0 else { break }
                let target = cur.gridLastPrice + step
                guard bar.high >= target else { break }
                let qty = gridQty(params: p, level: cur.gridLevel - 1, perLevel: perLevel)
                guard qty > 0 else { break }
                let filled = performSell(metaID: metaID, signalDate: date, date: date, ruleKind: .grid,
                                         bar: bar, price: target, desiredQty: qty)
                guard filled > 0 else { break }
                positions[metaID]?.gridLevel = max(cur.gridLevel - 1, 0)
                positions[metaID]?.gridLastPrice = target
            }
        }

        /// 分批（多触发）：逐 bar 推进一批；买入越跌越买（目标价递减）、卖出越涨越卖（目标价递增）
        ///
        /// `batchStepPct` 的真实语义是**百分数**（相对首批价的每批价差），不是差价：
        /// 策略层 `GAP` 以元填写，由 `StrategyCondGenerator` 换算为 `gap / 首批价 × 100`。
        func evaluateBatch(metaID: Int, date: Int, bar: KlineItem) {
            guard let rule = positions[metaID]?.planRules.first(where: { $0.kind == .batch }),
                  let pos = positions[metaID], pos.qty > 0 else { return }
            let p = rule.params
            guard let totalQty = p.batchTotalQty, totalQty > 0,
                  let count = p.batchCount, count >= 2,
                  let first = p.batchFirstPrice, first > 0,
                  let stepPct = p.batchStepPct, stepPct > 0 else { return }
            let index = pos.batchDone + 1
            guard index <= count else { return }
            let isBuy = rule.direction == .buy
            let offset = stepPct / 100 * Double(index - 1)
            let target = isBuy ? first * (1 - offset) : first * (1 + offset)
            guard target > 0 else { return }
            let reached = isBuy ? (bar.low <= target) : (bar.high >= target)
            guard reached else { return }
            let qty = batchQty(totalQty: totalQty, count: count, index: index)
            guard qty > 0 else { return }
            if isBuy {
                guard performBuy(metaID: metaID, signalDate: date, date: date, ruleKind: .batch,
                                 bar: bar, price: target, desiredQty: qty) else { return }
            } else {
                let filled = performSell(metaID: metaID, signalDate: date, date: date, ruleKind: .batch,
                                         bar: bar, price: target, desiredQty: qty)
                guard filled > 0 else { return }
            }
            positions[metaID]?.batchDone = index        // 成交后才推进批次（未成交不推进）
        }

        /// 价格条件（买方向，如 ORDDIR=BUY）：high ≥ 触发价 → 加仓
        func evaluatePriceBuy(metaID: Int, date: Int, bar: KlineItem) {
            guard let rule = positions[metaID]?.planRules.first(where: { $0.kind == .price && $0.direction == .buy }),
                  let trigger = rule.params.triggerPrice, trigger > 0,
                  bar.high >= trigger, rule.qty > 0 else { return }
            _ = performBuy(metaID: metaID, signalDate: date, date: date, ruleKind: .price,
                           bar: bar, price: fillPrice(trigger: trigger, bar: bar), desiredQty: rule.qty)
        }

        // MARK: 4. 逐交易日推进
        for date in calendar {
            // a. 开盘执行待成交动作（限价用触发价 ± 档位，市价用当日 open）
            //    信号日当日不成交；顺延到该标的下一根 bar 的开盘（停牌自动跳过）
            if !pending.isEmpty {
                var rest: [BacktestPendingAction] = []
                rest.reserveCapacity(pending.count)
                for action in pending {
                    guard date > action.signalDate, let bar = barOn(action.metaID, date) else {
                        rest.append(action)
                        continue
                    }
                    let price: Double
                    if action.priceType == .limit {
                        let trigger = action.triggerPrice + Double(action.offsetTicks) * rules.priceTick
                        price = fillPrice(trigger: trigger, bar: bar)
                    } else {
                        price = bar.open
                    }
                    switch action.direction {
                    case .buy:
                        _ = performBuy(metaID: action.metaID, signalDate: action.signalDate, date: date,
                                       ruleKind: action.ruleKind, bar: bar,
                                       price: price, desiredQty: action.desiredQty)
                    case .sell:
                        _ = performSell(metaID: action.metaID, signalDate: action.signalDate, date: date,
                                        ruleKind: action.ruleKind, bar: bar,
                                        price: price, desiredQty: action.desiredQty)
                    }
                }
                pending = rest
            }

            // b. T+1 释放：非当日买入的持仓，可卖数量回到全部
            // （先取局部副本再写回：同一表达式里同时读写 positions[id] 会触发独占访问冲突）
            for id in positions.keys.sorted() where positions[id]?.openedDate != date {
                guard var pos = positions[id] else { continue }
                pos.availableQty = pos.qty
                positions[id] = pos
            }

            // c. 持仓的规则判定（同一 bar 内止损腿优先于止盈腿；整仓离场后本标的当日不再动作）
            for id in positions.keys.sorted() {
                guard let bar = barOn(id, date) else { continue }        // 当日无 bar → 不成交
                guard var pos = positions[id], pos.qty > 0 else { continue }
                // 计划规则现场重算：STOP_LOSS(MODE=PCT) 的触发价跟随当前成本价
                pos.planRules = planRules(metaID: id, costPrice: pos.costPrice, lastPrice: bar.close)
                // TRAILING 先用 high 推进极值
                if pos.planRules.contains(where: { $0.kind == .trailing }) {
                    pos.extreme = max(pos.extreme, bar.high)
                }
                positions[id] = pos

                if evaluateFullExit(metaID: id, date: date, bar: bar) { continue }
                evaluateGrid(metaID: id, date: date, bar: bar)
                evaluateBatch(metaID: id, date: date, bar: bar)
                evaluatePriceBuy(metaID: id, date: date, bar: bar)
            }

            // d. 入场信号：选股命中且当前无持仓（includeEntry 关闭则只回测已有持仓上的规则）
            if params.includeEntry {
                for id in included {
                    guard pickHits[id]?.contains(date) == true,
                          (positions[id]?.qty ?? 0) == 0,
                          let bar = barOn(id, date) else { continue }
                    let qty = entryQty(id: id, price: bar.close)
                    guard qty > 0 else { continue }
                    let trade = doc.trade
                    if params.executeNextOpen {
                        pending.append(BacktestPendingAction(metaID: id, signalDate: date, direction: .buy,
                                                             desiredQty: qty,
                                                             priceType: trade.priceType ?? .market,
                                                             offsetTicks: trade.offsetTicks ?? 0,
                                                             triggerPrice: bar.close, ruleKind: nil))
                    } else {
                        _ = performBuy(metaID: id, signalDate: date, date: date, ruleKind: nil,
                                       bar: bar, price: bar.close, desiredQty: qty)
                    }
                }
            }

            // e. 收盘估值：净值 = 可用资金 + Σ(持仓股数 × 当日 close)；当日无 bar 的持仓沿用上一根 close
            var equity = cash
            for id in positions.keys.sorted() {
                guard let pos = positions[id] else { continue }
                if let bar = barOn(id, date) { lastClose[id] = bar.close }
                equity += Double(pos.qty) * (lastClose[id] ?? pos.costPrice)
            }
            equityPoints.append(BacktestEquityPoint(date: date, equity: equity))
        }

        // MARK: 5. 收尾：不做强制平仓，未平仓按最后一个交易日收盘价计入净值
        let finalEquity = equityPoints.last?.equity ?? params.initialCapital
        if !positions.isEmpty {
            warnings.append("期末仍有 \(positions.count) 只标的未平仓，已按最后一个交易日收盘价计入净值")
        }

        // MARK: 6. 指标
        let roundTrades = trades.filter { $0.realizedPnL != nil }
        let winCount = roundTrades.filter { ($0.realizedPnL ?? 0) > 0 }.count
        let gains = roundTrades.reduce(0.0) { $0 + max($1.realizedPnL ?? 0, 0) }
        let losses = roundTrades.reduce(0.0) { $0 + min($1.realizedPnL ?? 0, 0) }
        let totalReturn = params.initialCapital > 0 ? finalEquity / params.initialCapital - 1 : 0
        let base = 1 + totalReturn
        let periods = Double(max(calendar.count, 1))
        let annualized = base > 0 ? pow(base, 252 / periods) - 1 : -1
        let winRate = roundTrades.isEmpty ? 0 : Double(winCount) / Double(roundTrades.count)
        let profitFactor = losses < 0 ? gains / abs(losses) : 0
        let holdDays = roundTrades.compactMap { $0.holdDays }
        let avgHoldDays = holdDays.isEmpty ? 0 : Double(holdDays.reduce(0, +)) / Double(holdDays.count)

        // 最大回撤 + 区间（equity 数组下标区间，供折线图高亮）
        var maxDrawdown = 0.0
        var drawdownRange: ClosedRange<Int>?
        var peak = equityPoints.first?.equity ?? params.initialCapital
        var peakIndex = 0
        for (i, point) in equityPoints.enumerated() {
            if point.equity > peak {
                peak = point.equity
                peakIndex = i
            }
            guard peak > 0 else { continue }
            let drawdown = 1 - point.equity / peak
            if drawdown > maxDrawdown {
                maxDrawdown = drawdown
                drawdownRange = peakIndex...i
            }
        }

        // 固定口径说明（与条件单生成确认页同口径）
        warnings.append("TRAILING 与 bar 内「先 high 后 low」判定属乐观假设，实际触发价可能更差")
        warnings.append("实盘条件单只吃行情快照，触发必然晚于回测的逐 bar 判定")
        if limitUpBlocks > 0 { warnings.append("\(limitUpBlocks) 笔买入因成交价触涨停未成交") }
        if limitDownBlocks > 0 { warnings.append("\(limitDownBlocks) 笔卖出因成交价触跌停未成交") }
        if t1Blocks > 0 { warnings.append("\(t1Blocks) 笔卖出因 T+1（当日买入不可卖）未成交") }

        let stats = BacktestStats(initialCapital: params.initialCapital, finalEquity: finalEquity,
                                  totalReturn: totalReturn, annualized: annualized,
                                  winRate: winRate, profitFactor: profitFactor,
                                  maxDrawdown: maxDrawdown, tradeCount: trades.count,
                                  roundTrips: roundTrades.count, avgHoldDays: avgHoldDays)
        let hitCount = included.reduce(0) { $0 + ((pickHits[$1]?.isEmpty == false) ? 1 : 0) }

        return BacktestResult(params: params, stats: stats, equity: equityPoints,
                              maxDrawdownRange: drawdownRange, trades: trades,
                              scannedCount: bars.count, hitCount: hitCount,
                              warnings: warnings, skipped: skipped)
    }

    // MARK: - 静态辅助

    /// 未来函数静态扫描（纯文本级，只提示不阻断）：`BACKSET` / `ZIG` / `REF(X, -n)` 会让 as-of 值用到未来数据
    nonisolated static func futureFunctionWarnings(text: String) -> [String] {
        var result: [String] = []
        let upper = text.uppercased()
        if upper.contains("BACKSET") {
            result.append("选股公式包含未来函数（BACKSET），回测结果偏乐观")
        }
        if upper.contains("ZIG") {
            result.append("选股公式包含未来函数（ZIG），回测结果偏乐观")
        }
        if containsNegativeRef(text) {
            result.append("选股公式包含未来函数（REF 负偏移），回测结果偏乐观")
        }
        return result
    }

    /// 是否存在 `REF(X, -n)` 形式的负偏移
    private nonisolated static func containsNegativeRef(_ text: String) -> Bool {
        let pattern = "REF\\s*\\([^,()]*,\\s*-"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 无可用标的时的空结果（净值空数组、指标归零，仍带固定口径说明与跳过清单）
    private nonisolated static func emptyResult(params: BacktestParams, scanned: Int,
                                                skipped: [String]) -> BacktestResult {
        let stats = BacktestStats(initialCapital: params.initialCapital, finalEquity: params.initialCapital,
                                  totalReturn: 0, annualized: 0, winRate: 0, profitFactor: 0,
                                  maxDrawdown: 0, tradeCount: 0, roundTrips: 0, avgHoldDays: 0)
        let warnings = ["没有可参与回测的标的（行情缺失或不足 30 根），未产生净值曲线",
                        "TRAILING 与 bar 内「先 high 后 low」判定属乐观假设，实际触发价可能更差",
                        "实盘条件单只吃行情快照，触发必然晚于回测的逐 bar 判定"]
        return BacktestResult(params: params, stats: stats, equity: [], maxDrawdownRange: nil,
                              trades: [], scannedCount: scanned, hitCount: 0,
                              warnings: warnings, skipped: skipped)
    }

    /// 标的展示名
    private nonisolated static func metaTitle(_ meta: MetaItem?, _ id: Int) -> String {
        guard let meta else { return "标 #\(id)" }
        return "\(meta.name) \(meta.code)"
    }

    /// 条件单种类 → 策略规则种类
    private nonisolated static func strategyKind(_ kind: SimCondKind) -> StrategyRuleKind {
        switch kind {
        case .price:     return .price
        case .stopLoss:  return .stopLoss
        case .trailing:  return .trailing
        case .time:      return .time
        case .changePct: return .changePct
        case .maCross:   return .maCross
        case .grid:      return .grid
        case .batch:     return .batch
        }
    }

    /// Date → Int(YYYYMMDD)（与 StrategyCondGenerator.fireDate 同口径：公历 + 当前时区）
    private nonisolated static func dateInt(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return (components.year ?? 0) * 10000 + (components.month ?? 0) * 100 + (components.day ?? 0)
    }

    /// 两个 YYYYMMDD 之间的自然日差
    private nonisolated static func daysBetween(_ from: Int, _ to: Int) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        var startComponents = DateComponents()
        startComponents.year = from / 10000
        startComponents.month = (from / 100) % 100
        startComponents.day = from % 100
        var endComponents = DateComponents()
        endComponents.year = to / 10000
        endComponents.month = (to / 100) % 100
        endComponents.day = to % 100
        guard let start = calendar.date(from: startComponents),
              let end = calendar.date(from: endComponents) else { return 0 }
        return max(calendar.dateComponents([.day], from: start, to: end).day ?? 0, 0)
    }

    /// 网格预估档位数（复用 SimCondRule.gridLevelCount 的对数口径，不重复实现）
    private nonisolated static func gridLevelCount(params: SimCondParams) -> Int {
        let placeholderID = UUID(uuidString: "00000000-0000-0000-0000-00000000BACC") ?? UUID()
        let order = SimCondOrder(id: placeholderID, accountID: placeholderID, metaID: 0,
                                 code: "", name: "", kind: .grid, params: params,
                                 directive: SimCondDirective(), validity: .longTerm,
                                 createdAt: Date(timeIntervalSince1970: 0),
                                 updatedAt: Date(timeIntervalSince1970: 0))
        return SimCondRule.gridLevelCount(order: order)
    }

    /// 网格单档数量：每格股数 × 倍数^档位（倍数额度封顶 4 档，与 SimCondRule 一致）
    private nonisolated static func gridQty(params: SimCondParams, level: Int, perLevel: Int) -> Int {
        let multiplier = min(max(params.gridMultiplier ?? 1, 1), 5)
        let factor = pow(multiplier, Double(min(max(level, 0), 4)))
        return perLevel * Int(round(factor))
    }

    /// 分批单批数量：总数量按批数均分并向下取整到手，最后一批吃掉余数（与 SimCondRule.batchQty 同口径）
    private nonisolated static func batchQty(totalQty: Int, count: Int, index: Int) -> Int {
        let lot = max(SimTradingRules.default.lotSize, 1)
        let perBatch = totalQty / count / lot * lot
        if index >= count { return max(totalQty - perBatch * (count - 1), 0) }
        return max(perBatch, 0)
    }

    /// 价格文案（两位小数）
    private nonisolated static func priceText(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

// MARK: - 运行器（取数 + as-of 命中）

/// 回测执行器（全局单例，同一时刻只跑一个任务）
///
/// 三段式：① 后台逐只 `fetchPeriodLimited` 取数 → ② 逐只一次全量求值得到 as-of 命中日期集合 →
/// ③ 全部就绪后调纯引擎模拟。重活全在 `MarketRowCache.computeQueue`，UI 只读 `phase` / `result`。
@MainActor
final class StrategyBacktestRunner: ObservableObject {
    static let shared = StrategyBacktestRunner()

    /// 阶段：准备行情数据 → 模拟 → 结束 / 取消 / 失败
    enum Phase: Equatable {
        case idle
        case preparing(done: Int, total: Int)
        case simulating
        case finished
        case cancelled
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: BacktestResult?

    var isRunning: Bool {
        switch phase {
        case .preparing, .simulating: return true
        case .idle, .finished, .cancelled, .failed: return false
        }
    }

    private let db = DatabaseManager.shared
    private let queue = MarketRowCache.shared.computeQueue
    /// 取消标志盒（后台队列与主线程共用，锁保护；不挂在 actor 上以便后台直接读）
    private let cancelBox = BacktestCancelBox()
    /// 任务序号：start / cancel 都会递增，旧一轮的回调据此整体失效
    private var runToken = 0

    private init() {}

    // MARK: - 入口

    /// 开始回测：同一时刻只允许一个任务，再次 start 会先让旧任务失效
    func start(doc: FormulaDoc, params: BacktestParams) {
        cancelBox.cancel()      // 让旧一轮的回调立刻停手
        runToken += 1
        cancelBox.reset()       // 新的一轮重新开始（旧轮回调已按 token 失效）
        let token = runToken

        // 公式文本：优先 PICKREF 引用的选股公式，取不到再回退内嵌 PICK 文本
        let refText = FormulaLibraryStore.shared.formulaText(id: doc.pickRef) ?? ""
        let formula = refText.isEmpty ? doc.pickBody : refText

        // 结果只在 .finished 时非 nil：新任务开始先清掉上一轮
        if result != nil { result = nil }

        guard !formula.isEmpty else {
            setPhase(.failed("策略没有选股条件"))
            return
        }

        // 候选池：全市场 / 自选（「全部」虚拟分组的去重并集）
        let all = db.metaList
        let candidates: [MetaItem]
        switch params.pool {
        case .market:
            candidates = all
        case .favorites:
            candidates = FavoritesStore.shared.resolveMetaItems(groupID: FavoritesStore.allGroupID, allMeta: all)
        }
        guard !candidates.isEmpty else {
            setPhase(.failed("候选池为空，无法回测"))
            return
        }

        setPhase(.preparing(done: 0, total: candidates.count))

        let db = self.db
        let cancelBox = self.cancelBox
        queue.async { [weak self] in
            var preparedBars: [Int: [KlineItem]] = [:]
            var preparedMetas: [Int: MetaItem] = [:]
            var preparedHits: [Int: Set<Int>] = [:]
            var runnerSkips: [String] = []
            let limit = params.days + 60        // 多取 60 根，保证窗口首日也有昨收 / 均线起点
            var done = 0

            /// 进度推送（主线程更新 @Published；取消后由 token 与标志双重拦截）
            let pushProgress: (Int) -> Void = { current in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, token == self.runToken, !self.cancelBox.isCancelled else { return }
                    let next = Phase.preparing(done: current, total: candidates.count)
                    if self.phase != next { self.phase = next }
                }
            }

            for meta in candidates {
                if cancelBox.isCancelled { return }     // 每只标的边界检查取消
                let raw = db.fetchPeriodLimited(metaId: meta.id, table: params.period.folderName, limit: limit)
                let series = Array(raw.reversed())      // date DESC → 升序
                done += 1
                defer { pushProgress(done) }

                if series.count < 30 {
                    runnerSkips.append("\(meta.name) \(meta.code)：行情不足 30 根（\(series.count)），已跳过")
                    continue
                }

                // as-of 命中：一次全量求值，第 i 根输出值即「截至第 i 根」的 as-of 值。
                // 因果公式下这等价于逐 bar 截断重算，却省掉「逐日 × 全市场」的重算；
                // 未来函数会破坏该等价性（已在引擎 warnings 里静态提示）。
                var hits = Set<Int>()
                do {
                    let lines = try TDXFormulaEngine.evaluate(formula: formula, data: series)
                    if let last = lines.last {
                        for (i, value) in last.values.enumerated() where !value.isNaN && value > 0 {
                            if i < series.count { hits.insert(series[i].date) }
                        }
                    }
                } catch {
                    runnerSkips.append("\(meta.name) \(meta.code)：选股公式求值失败"
                                       + "（\(error.localizedDescription)），已跳过")
                    continue
                }

                preparedBars[meta.id] = series
                preparedMetas[meta.id] = meta
                preparedHits[meta.id] = hits
            }

            // 全部就绪 → 进入模拟阶段
            DispatchQueue.main.async { [weak self] in
                guard let self = self, token == self.runToken, !self.cancelBox.isCancelled else { return }
                self.setPhase(.simulating)
            }

            var outcome = StrategyBacktestEngine.run(doc: doc, bars: preparedBars,
                                                     pickHits: preparedHits, metas: preparedMetas,
                                                     params: params)
            if !runnerSkips.isEmpty { outcome.skipped.append(contentsOf: runnerSkips) }
            // 引用型选股（PICKREF）的正文在引擎侧不可见，这里用同一扫描器补一次未来函数提示
            if !refText.isEmpty, refText != doc.pickBody {
                for warning in StrategyBacktestEngine.futureFunctionWarnings(text: refText)
                where !outcome.warnings.contains(warning) {
                    outcome.warnings.append(warning)
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self, token == self.runToken, !self.cancelBox.isCancelled else { return }
                if self.result != outcome { self.result = outcome }
                self.setPhase(.finished)
            }
        }
    }

    /// 取消当前回测（未在跑时无副作用）
    func cancel() {
        guard isRunning else { return }
        cancelBox.cancel()
        runToken += 1
        setPhase(.cancelled)
    }

    // MARK: - 内部

    /// 同值不赋值：@Published 同值赋值也会发布，避免发布风暴
    private func setPhase(_ next: Phase) {
        if phase != next { phase = next }
    }
}
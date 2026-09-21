//
//  SimCondRule.swift
//  Kline
//
//  条件单评估纯函数层：行情快照入参、判定三态（fire / hold / abort）、
//  8 种类型的触发判定、建单校验（可直接展示的中文拒绝文案）与列表/预览文案构造，
//  以及快照取数助手 SimCondSnapshotCenter（走既有 SimQuoteCenter / MarketRowCache）。
//  约定：本层纯计算、无副作用——不写 SimStore、不落盘、不取数（取数在 SnapshotCenter）。
//  本项目的「最新价」是本地日线库最后一根 K 线的 close，没有盘中 tick 推送。
//  「仅提醒」（SimCondDirective.isAlertOnly）只在本层放行数量 / 持仓校验与网格 / 分批的数量缺省，
//  普通条件单的判定与校验一律零变化。
//

import Foundation

// MARK: - 行情快照

/// 行情快照：评估所需的全部输入（纯数据，无副作用）
struct SimCondSnapshot {
    var last: Double? = nil        // 最新价（行情未就绪为 nil）
    var prevClose: Double? = nil   // 昨收
    var high: Double? = nil        // 最高
    var low: Double? = nil         // 最低
    var changePct: Double? = nil   // 当日涨跌幅（%）
    var ma: Double? = nil          // 按 order.params.maPeriod 取的对应均线值
}

// MARK: - 判定结果

/// 条件单判定结果
enum SimCondDecision {
    case fire(qty: Int, at: Double)     // 触发：本次下单数量与触发价
    case hold(SimCondRuntime)           // 继续监控：可携带更新后的运行时
    case abort(String)                  // 异常失效：中文原因（配置坏了 / 参数缺失）
    case complete(String)               // 正常走完（多触发类型档位 / 批次走完，或价格越出区间）：中文说明
}

// MARK: - 建单拒绝原因

/// 建单 / 改单被拒原因（中文文案，风格对齐 SimOrderRejection）
enum SimCondRejection: Error, Equatable {
    case accountUnavailable
    case noQuote                                                // 无行情
    case invalidQty(lot: Int)                                   // 数量非整手 / ≤ 0
    case noPosition                                             // 卖出方向无持仓
    case missingParam(String)                                   // 参数缺失
    case invalidOCORange                                        // 止盈 ≤ 基准 / 止损 ≥ 基准
    case invalidGridRange                                       // 网格区间倒挂
    case invalidGridStep                                        // 网格间距 ≤ 0
    case invalidBatchCount                                      // 分批笔数不在 2...5
    case batchTooSmall(lot: Int)                                // 分批每批不足 1 手
    case invalidFireDate                                        // 时间条件为空或已过期

    var message: String {
        switch self {
        case .accountUnavailable:
            return "请先选择有效的模拟账户"
        case .noQuote:
            return "暂无该标的行情，无法创建条件单"
        case .invalidQty(let lot):
            return "委托数量需为 \(lot) 股的整数倍且大于 0"
        case .noPosition:
            return "当前账户无可卖持仓，无法创建卖出条件单"
        case .missingParam(let name):
            return "\(name)不能为空"
        case .invalidOCORange:
            return "止盈价应高于基准价，止损价应低于基准价"
        case .invalidGridRange:
            return "网格价格区间下界需低于上界"
        case .invalidGridStep:
            return "网格间距需大于 0"
        case .invalidBatchCount:
            return "分批笔数需为 2 ~ 5 笔"
        case .batchTooSmall(let lot):
            return "分批总数量不足：每批至少 1 手（\(lot) 股）"
        case .invalidFireDate:
            return "时间条件需选择未来的触发时间"
        }
    }
}

// MARK: - 规则（纯函数）

/// nonisolated：纯计算层，历史回测引擎在后台线程直接复用（取数在 @MainActor 的 SimCondSnapshotCenter）
nonisolated enum SimCondRule {

    // MARK: 评估

    /// 纯函数：不写任何数据。
    /// 快照缺失（last 为 nil 或 ≤ 0）一律 hold，不误触发。
    static func evaluate(order: SimCondOrder, snapshot: SimCondSnapshot) -> SimCondDecision {
        let p = order.params
        guard let price = snapshot.last, price > 0 else { return .hold(order.runtime) }

        switch order.kind {
        case .price:
            guard let trigger = p.triggerPrice, trigger > 0 else { return .abort("触发价缺失") }
            let compareUp = p.compareUp ?? true
            let hit = compareUp ? (price >= trigger) : (price <= trigger)
            return hit ? .fire(qty: order.directive.qty, at: trigger) : .hold(order.runtime)

        case .stopLoss:
            guard p.takeProfitPrice != nil || p.stopLossPrice != nil else {
                return .abort("止盈止损参数缺失")
            }
            // 双边 OCO：同一次评估两条都满足时取止损腿（风控优先）；只设一腿时另一腿忽略
            if let stop = p.stopLossPrice, price <= stop {
                return .fire(qty: order.directive.qty, at: stop)
            }
            if let take = p.takeProfitPrice, price >= take {
                return .fire(qty: order.directive.qty, at: take)
            }
            return .hold(order.runtime)

        case .trailing:
            guard let breakout = p.breakoutPrice, breakout > 0 else { return .abort("突破价缺失") }
            // 保底价触发：跌破保底价直接触发
            if p.floorEnabled, let floor = p.floorPrice, floor > 0, price <= floor {
                return .fire(qty: order.directive.qty, at: price)
            }
            var runtime = order.runtime
            // 未突破且从未突破过 → 不追踪，直接 hold
            guard runtime.extreme != nil || price >= breakout else { return .hold(runtime) }
            // 极值只能在评估点采样（两次评估之间的价格路径不可见）
            let extreme = max(runtime.extreme ?? price, price)
            runtime.extreme = extreme
            guard let trailPct = p.trailPct, trailPct > 0 else { return .hold(runtime) }
            let drawdown = extreme > 0 ? (extreme - price) / extreme * 100 : 0
            if drawdown >= trailPct { return .fire(qty: order.directive.qty, at: price) }
            return .hold(runtime)

        case .time:
            guard let fireDate = p.fireDate else { return .abort("触发时间缺失") }
            guard Date() >= fireDate else { return .hold(order.runtime) }
            // 触发价取最新价，无最新价时退化用昨收（两者同源，行情未就绪则整体 hold）
            guard let at = snapshot.last ?? snapshot.prevClose, at > 0 else {
                return .hold(order.runtime)
            }
            return .fire(qty: order.directive.qty, at: at)

        case .changePct:
            guard let threshold = p.changeThreshold, threshold != 0 else {
                return .abort("涨跌幅阈值缺失")
            }
            guard let pct = snapshot.changePct else { return .hold(order.runtime) }
            let hit = threshold > 0 ? (pct >= threshold) : (pct <= threshold)
            return hit ? .fire(qty: order.directive.qty, at: price) : .hold(order.runtime)

        case .maCross:
            guard p.maPeriod != nil, p.maAbove != nil else { return .abort("均线参数缺失") }
            guard let ma = snapshot.ma, let prev = snapshot.prevClose else {
                return .hold(order.runtime)
            }
            // bar 对 bar 判定（昨收与最新价分列均线两侧），天然避免持续满足即反复触发
            let above = p.maAbove ?? true
            let hit = above ? (prev < ma && price >= ma) : (prev > ma && price <= ma)
            return hit ? .fire(qty: order.directive.qty, at: price) : .hold(order.runtime)

        case .grid:
            guard let lower = p.gridLower, let upper = p.gridUpper,
                  let step = p.gridStepPct, step > 0 else {
                return .abort("网格参数不完整")
            }
            // 「仅提醒」不产生委托：每格数量允许缺省 / 为 0，预警照样可触发
            if !order.directive.isAlertOnly {
                guard let perLevel = p.gridQtyPerLevel, perLevel > 0 else {
                    return .abort("网格参数不完整")
                }
            }
            guard price >= lower, price <= upper else { return .complete("价格已越出网格区间") }
            var runtime = order.runtime
            if runtime.gridLevel == nil { runtime.gridLevel = 0 }
            if runtime.gridLastPrice == nil { runtime.gridLastPrice = p.gridBase ?? price }
            guard let base = runtime.gridLastPrice, base > 0 else { return .hold(runtime) }
            // 相对「上一次触发价」的百分比步长判定：下移一档买入 / 上移一档卖出
            let dropPct = (base - price) / base * 100
            let risePct = (price - base) / base * 100
            guard dropPct >= step || risePct >= step else { return .hold(runtime) }
            let level = max(runtime.gridLevel ?? 0, 0)
            let multiplier = min(max(p.gridMultiplier ?? 1, 1), 5)
            let factor = pow(multiplier, Double(min(level, 4)))
            let qty = (p.gridQtyPerLevel ?? 0) * Int(round(factor))
            return .fire(qty: max(qty, 0), at: price)

        case .batch:
            guard let count = p.batchCount, count >= 2,
                  let firstPrice = p.batchFirstPrice, firstPrice > 0,
                  let stepPct = p.batchStepPct, stepPct > 0 else {
                return .abort("分批参数不完整")
            }
            // 「仅提醒」不产生委托：总数量允许缺省 / 为 0
            if !order.directive.isAlertOnly {
                guard let totalQty = p.batchTotalQty, totalQty > 0 else {
                    return .abort("分批参数不完整")
                }
            }
            let done = max(order.runtime.batchDone, 0)
            let index = done + 1
            guard index <= count else { return .complete("分批已全部完成") }
            // 买入越跌越买（目标价递减），卖出越涨越卖（目标价递增）
            let isBuy = order.directive.direction == .buy
            let offset = stepPct / 100 * Double(index - 1)
            let target = isBuy ? firstPrice * (1 - offset) : firstPrice * (1 + offset)
            let reached = isBuy ? (price <= target) : (price >= target)
            guard reached else { return .hold(order.runtime) }
            return .fire(qty: batchQty(totalQty: p.batchTotalQty ?? 0, count: count, index: index),
                         at: price)
        }
    }

    /// 分批单批数量：总数量按批数均分并向下取整到手，最后一批吃掉余数
    private static func batchQty(totalQty: Int, count: Int, index: Int) -> Int {
        let lot = max(SimTradingRules.default.lotSize, 1)
        let perBatch = totalQty / count / lot * lot
        if index >= count { return max(totalQty - perBatch * (count - 1), 0) }
        return max(perBatch, 0)
    }

    /// 网格区间内预估总档位数（上区间档位 + 下区间档位，至少 1 档）
    static func gridLevelCount(order: SimCondOrder) -> Int {
        let p = order.params
        guard let base = p.gridBase, base > 0,
              let upper = p.gridUpper, let lower = p.gridLower,
              let step = p.gridStepPct, step > 0 else { return 1 }
        let unit = log(1 + step / 100)
        guard unit > 0 else { return 1 }
        let up = upper > base ? log(upper / base) / unit : 0
        let down = lower < base ? log(base / lower) / unit : 0
        return max(Int(floor(up)) + Int(floor(down)), 1)
    }

    // MARK: 校验

    /// 建单 / 改单校验：返回 nil 表示通过。
    /// 注意：不复用 SimTradingRules.validate（那是为「立即成交」设计的），
    /// 仅复用其 lotSize 与 sellableQty(position:)。
    static func validateCreate(order: SimCondOrder, account: SimAccount,
                               position: SimPosition?, snapshot: SimCondSnapshot) -> SimCondRejection? {
        if account.isArchived || account.id != order.accountID { return .accountUnavailable }

        let rules = SimTradingRules.default
        let lot = max(rules.lotSize, 1)
        let p = order.params

        // 「仅提醒」（isAlertOnly）不产生委托：数量校验整段放行（允许数量为 0）。
        // 普通条件单保持原判序与原文案，不放宽任何一项。
        if !order.directive.isAlertOnly {
            // 数量：网格用每格数量、分批用总数量，其余类型用委托指令数量
            switch order.kind {
            case .grid:
                guard let perLevel = p.gridQtyPerLevel, perLevel > 0, perLevel % lot == 0 else {
                    return .invalidQty(lot: lot)
                }
            case .batch:
                guard let totalQty = p.batchTotalQty, totalQty > 0, totalQty % lot == 0 else {
                    return .invalidQty(lot: lot)
                }
            default:
                if order.directive.qty <= 0 || order.directive.qty % lot != 0 {
                    return .invalidQty(lot: lot)
                }
            }
        }

        // 行情：触发判定必须有最新价
        guard let last = snapshot.last, last > 0 else { return .noQuote }

        // 卖出方向必须有可卖持仓（「仅提醒」不下单，允许无持仓）
        if !order.directive.isAlertOnly, order.directive.direction == .sell {
            if rules.sellableQty(position: position) <= 0 { return .noPosition }
        }

        switch order.kind {
        case .price:
            guard let trigger = p.triggerPrice, trigger > 0 else { return .missingParam("触发价") }

        case .stopLoss:
            guard p.takeProfitPrice != nil || p.stopLossPrice != nil else {
                return .missingParam("止盈价或止损价")
            }
            if p.baseMode == .price, let base = p.basePrice, base > 0 {
                if let take = p.takeProfitPrice, take <= base { return .invalidOCORange }
                if let stop = p.stopLossPrice, stop >= base { return .invalidOCORange }
            }

        case .trailing:
            guard let breakout = p.breakoutPrice, breakout > 0 else { return .missingParam("突破价") }
            guard let trailPct = p.trailPct, trailPct > 0 else { return .missingParam("回落幅度") }
            if p.floorEnabled {
                guard let floor = p.floorPrice, floor > 0 else { return .missingParam("保底价") }
            }

        case .time:
            guard let fireDate = p.fireDate else { return .missingParam("触发时间") }
            if fireDate <= Date() { return .invalidFireDate }

        case .changePct:
            guard let threshold = p.changeThreshold, threshold != 0 else {
                return .missingParam("涨跌幅阈值")
            }

        case .maCross:
            guard let period = p.maPeriod, [5, 10, 20, 60].contains(period) else {
                return .missingParam("均线周期")
            }
            guard p.maAbove != nil else { return .missingParam("穿越方向") }

        case .grid:
            guard let base = p.gridBase, base > 0 else { return .missingParam("基准价") }
            guard let lower = p.gridLower, let upper = p.gridUpper else {
                return .missingParam("网格价格区间")
            }
            if upper <= lower { return .invalidGridRange }
            guard let step = p.gridStepPct, step > 0 else { return .invalidGridStep }

        case .batch:
            guard let count = p.batchCount, count >= 2, count <= 5 else { return .invalidBatchCount }
            guard let firstPrice = p.batchFirstPrice, firstPrice > 0 else {
                return .missingParam("首批价格")
            }
            guard let stepPct = p.batchStepPct, stepPct > 0 else { return .missingParam("每批价差") }
            // 每批手数校验同属数量校验：「仅提醒」放行（不产生委托，总量可为 0）
            if !order.directive.isAlertOnly {
                let totalQty = p.batchTotalQty ?? 0
                if totalQty < count * lot { return .batchTooSmall(lot: lot) }
            }
        }

        // 有效期：指定日期必须给出到期日，否则该单永不失效
        if order.validity == .untilDate, order.expiresAt == nil {
            return .missingParam("有效期到期日")
        }

        return nil
    }

    // MARK: 文案（列表行与预览共用）

    /// 条件摘要（不含标的与指令）
    static func conditionSummary(_ order: SimCondOrder) -> String {
        let p = order.params
        switch order.kind {
        case .price:
            guard let trigger = p.triggerPrice else { return "价格条件待完善" }
            let symbol = (p.compareUp ?? true) ? "≥" : "≤"
            return "现价 \(symbol) \(SimFormat.price(trigger))"

        case .stopLoss:
            var parts: [String] = []
            if let take = p.takeProfitPrice {
                parts.append("止盈 \(SimFormat.price(take))\(pctSuffix(take, base: p.basePrice))")
            }
            if let stop = p.stopLossPrice {
                parts.append("止损 \(SimFormat.price(stop))\(pctSuffix(stop, base: p.basePrice))")
            }
            guard !parts.isEmpty else { return "止盈止损待完善" }
            return parts.joined(separator: "或 ")

        case .trailing:
            let verb = order.directive.direction == .sell ? "回落卖出" : "反弹买入"
            guard let breakout = p.breakoutPrice else { return verb }
            let moveWord = order.directive.direction == .sell ? "回落" : "反弹"
            var text = "\(verb) · 突破 \(SimFormat.price(breakout)) 后\(moveWord) \(percentText(p.trailPct ?? 0))%"
            if p.floorEnabled, let floor = p.floorPrice {
                text += " · 保底 \(SimFormat.price(floor))"
            }
            return text

        case .time:
            guard let fireDate = p.fireDate else { return "时间条件待完善" }
            return "\(SimFormat.dateTime(fireDate)) 触发"

        case .changePct:
            guard let threshold = p.changeThreshold else { return "涨跌幅待完善" }
            if threshold > 0 { return "日涨幅 ≥ \(percentText(threshold))%" }
            return "日跌幅 ≥ \(percentText(abs(threshold)))%"

        case .maCross:
            let period = p.maPeriod ?? 20
            return (p.maAbove ?? true) ? "上穿 MA\(period)" : "下破 MA\(period)"

        case .grid:
            guard let lower = p.gridLower, let upper = p.gridUpper else { return "网格交易待完善" }
            return "网格交易 · 区间 \(SimFormat.price(lower)) ~ \(SimFormat.price(upper))"
                + " · 间距 \(percentText(p.gridStepPct ?? 0))%"

        case .batch:
            let verb = order.directive.direction == .buy ? "分批买入" : "分批卖出"
            let count = p.batchCount ?? 0
            let first = p.batchFirstPrice.map { SimFormat.price($0) } ?? "—"
            return "\(verb) \(count) 批 · 首批 \(first) · 每批 \(percentText(p.batchStepPct ?? 0))%"
        }
    }

    /// 委托指令摘要（带「触发后」前缀）
    static func directiveSummary(_ order: SimCondOrder) -> String {
        "触发后 " + directiveCore(order)
    }

    /// 委托指令核心（不含「触发后」前缀，供预览句复用）
    static func directiveCore(_ order: SimCondOrder) -> String {
        let d = order.directive
        if order.kind == .grid {
            let perLevel = order.params.gridQtyPerLevel.map { SimFormat.shares($0) } ?? "0"
            let multiplier = numberText(order.params.gridMultiplier ?? 1)
            return "\(d.priceType.title) · 每格 \(perLevel) 股 · 倍数 \(multiplier)"
        }
        var text = "\(d.priceType.title)\(d.direction.title)"
        if d.priceType == .limit, d.offsetTicks != 0 {
            let sign = d.offsetTicks > 0 ? "+" : "-"
            text += "（触发价 \(sign)\(abs(d.offsetTicks)) 档）"
        }
        text += " \(SimFormat.shares(d.qty)) 股"
        return text
    }

    /// 有效期摘要
    static func validitySummary(_ order: SimCondOrder) -> String {
        switch order.validity {
        case .day:
            return "当日有效"
        case .longTerm:
            return "长期有效"
        case .untilDate:
            guard let expiresAt = order.expiresAt else { return "指定日期有效" }
            return "\(SimFormat.shortDate(expiresAt)) 前有效"
        }
    }

    /// 一句话预览（标的 + 条件 + 指令 + 有效期）
    static func previewSentence(_ order: SimCondOrder) -> String {
        "当 \(order.name) \(conditionSummary(order)) 时，以 \(directiveCore(order))，\(validitySummary(order))"
    }

    // MARK: 文案辅助

    /// 相对基准价的幅度文案（基准价缺失时返回空串）
    private static func pctSuffix(_ value: Double, base: Double?) -> String {
        guard let base = base, base > 0 else { return "" }
        return "（\(SimFormat.pct((value - base) / base * 100))）"
    }

    /// 百分数（保留 1 位小数，不带 % 号）
    private static func percentText(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// 紧凑数值（倍数委托：1 → "1"，1.5 → "1.5"）
    private static func numberText(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

// MARK: - 快照取数

/// 行情快照取数（@MainActor，走既有 SimQuoteCenter / MarketRowCache，不新增取数路径）
@MainActor
enum SimCondSnapshotCenter {
    static func snapshot(for order: SimCondOrder) -> SimCondSnapshot {
        let cache = MarketRowCache.shared
        return SimCondSnapshot(last: SimQuoteCenter.lastPrice(metaID: order.metaID),
                               prevClose: SimQuoteCenter.prevClose(metaID: order.metaID),
                               high: cache.numberFor(order.metaID, .high),
                               low: cache.numberFor(order.metaID, .low),
                               changePct: cache.numberFor(order.metaID, .changePct),
                               ma: maValue(metaID: order.metaID, period: order.params.maPeriod))
    }

    /// 按均线周期取对应字段（period 非 5/10/20/60 时返回 nil）
    private static func maValue(metaID: Int, period: Int?) -> Double? {
        guard let period = period else { return nil }
        let field: MarketField
        switch period {
        case 5:  field = .ma5
        case 10: field = .ma10
        case 20: field = .ma20
        case 60: field = .ma60
        default: return nil
        }
        return MarketRowCache.shared.numberFor(metaID, field)
    }
}
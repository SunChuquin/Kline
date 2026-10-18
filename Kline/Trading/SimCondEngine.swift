//
//  SimCondEngine.swift
//  Kline
//
//  条件单触发引擎：SimStore 的扩展。统一结算入口 sweepConditions(trigger:) 在
//  「行情刷新 / 手动检查 / 数据重载」时机结算全部监控中的条件单：
//  重入保护 → 有效期判定 → 取行情快照 → 纯函数判定 → 组装 SimOrderDraft 走既有 submit
//  （不新增旁路下单逻辑，生成的委托带 originCondID 回链）。
//  约定：整轮结算只在结尾写盘一次；写回一律先比较再赋值（沿用 @Published 写入守卫）；
//  单次类型触发成功置 triggered、失败置 rejected（不重试）；多触发类型（网格 / 分批）
//  失败保持 monitoring 并记因，走完全部档位 / 批次后置 completed。
//  另：指令为 isAlertOnly 的「仅提醒」条件单触发时**不下单**（不产生任何委托 / 成交），
//  只写运行时状态并追加一条 SimAlertRecord（多触发类型每次触发都追加，不覆盖历史）。
//

import Foundation

// MARK: - 触发源与结果

/// 结算触发源
enum SimCondTrigger {
    case quoteRefresh
    case manual
    case dataReload
}

/// 单轮结算结果（供「立即检查」就地提示）
struct SimCondSweepResult {
    var evaluated = 0
    var fired = 0
    var rejected = 0
    var expired = 0
    var completed = 0

    var message: String {
        var parts: [String] = []
        if fired > 0 { parts.append("触发 \(fired) 笔") }
        if rejected > 0 { parts.append("被拒 \(rejected) 笔") }
        if expired > 0 { parts.append("失效 \(expired) 笔") }
        if completed > 0 { parts.append("完成 \(completed) 笔") }
        guard !parts.isEmpty else { return "本次检查无触发" }
        return "本次检查" + parts.joined(separator: " · ")
    }
}

// MARK: - 引擎

extension SimStore {

    /// 统一结算入口：先判有效期 → 取快照 → 判定 → 下发委托。
    /// 已在结算中直接返回空结果（不重入）。
    @discardableResult
    func sweepConditions(trigger: SimCondTrigger) async -> SimCondSweepResult {
        var result = SimCondSweepResult()
        guard !condSweepInFlight else { return result }
        // A5-4：`.engine` 模式下有效期 / 判定 / 档位推进 / 授权全走引擎；引擎未就绪 → 本轮不结算
        // （条件单保持 monitoring，等引擎就绪后的下一次触发结算），**不用 Swift 兜底**（§9.10）。
        guard SimRulesBridge.judgmentAvailable else {
            DebugLogger.shared.log("[SimCondEngine] sweep：引擎未就绪，本轮不结算")
            return result
        }
        condSweepInFlight = true
        defer { condSweepInFlight = false }

        let monitoring = conditionalOrders.filter { $0.status == .monitoring }
        guard !monitoring.isEmpty else { return result }

        // 阶段 C：整轮结算**一次进引擎**（`cond_sweep` op），Swift 只装配入参 + 应用增量。
        // 口径由 `scripts/verify_cond_sweep_parity.py`（整环 op vs 细粒度 op 序列，12 例：hold /
        // fire / expired / abort / 网格 / 分批 / 仅提醒 / 被拒）逐字段锁死，改 op 前必跑该对拍。
        var snapshots: [UUID: SimCondSnapshot] = [:]
        var lastPrices: [Int: Double] = [:]
        var prevCloses: [Int: Double] = [:]
        for order in monitoring {
            snapshots[order.id] = SimCondSnapshotCenter.snapshot(for: order)
            if let lp = SimQuoteCenter.lastPrice(metaID: order.metaID) { lastPrices[order.metaID] = lp }
            if let pc = SimQuoteCenter.prevClose(metaID: order.metaID) { prevCloses[order.metaID] = pc }
        }

        let sweep: SimRulesBridge.CondSweepResult
        do {
            sweep = try await SimRulesBridge.condSweep(orders: conditionalOrders,
                                                      snapshots: snapshots,
                                                      accounts: accounts,
                                                      positions: positions,
                                                      lastPrices: lastPrices,
                                                      prevCloses: prevCloses,
                                                      now: Date(),
                                                      tzOffsetSeconds: TimeZone.current.secondsFromGMT(),
                                                      fills: fills,
                                                      existingOrders: orders)
        } catch {
            DebugLogger.shared.log("[SimCondEngine] sweep：引擎异常，本轮不结算 \(error)")
            return result
        }

        // 增量应用（全部复用既有 applier；Swift 侧不含任何结算逻辑）
        if !sweep.newFills.isEmpty { assignFills(fills + sweep.newFills) }
        for cashChange in sweep.cashChanges {
            if let accountID = cashChange["accountID"] as? UUID,
               let cash = cashChange["cash"] as? Double {
                applyCashChangePython(accountID: accountID, newCash: cash)
            }
        }
        for positionChange in sweep.positionChanges { applyPositionChangePython(positionChange) }
        for ledgerEntry in sweep.ledgerEntries { appendLedgerFromDict(ledgerEntry) }
        for logEntry in sweep.logs { appendLogFromDict(logEntry) }
        if !sweep.alertRecords.isEmpty { await appendAlertRecordsFromSweep(sweep.alertRecords) }
        if !sweep.newOrders.isEmpty { assignOrders(orders + sweep.newOrders) }

        // 条件单全量回写：仅当解码条数与现状一致时整体替换（避免部分解码失败造成丢失）
        var ordersChanged = false
        if sweep.orders.count == conditionalOrders.count {
            ordersChanged = zip(sweep.orders, conditionalOrders)
                .contains { $0.updatedAt != $1.updatedAt || $0.status != $1.status }
            if ordersChanged { assignConditionalOrders(sweep.orders) }
        } else {
            DebugLogger.shared.log("[SimCondEngine] sweep：条件单回写条数不一致"
                                   + "（\(sweep.orders.count) vs \(conditionalOrders.count)），跳过回写")
        }

        result.evaluated = sweep.evaluated
        result.fired = sweep.fired
        result.rejected = sweep.rejected
        result.expired = sweep.expired
        result.completed = sweep.completed

        // 整轮结算只在确实有写入时写盘一次
        if ordersChanged || sweep.fired > 0 || sweep.rejected > 0 || sweep.expired > 0
            || sweep.completed > 0 || !sweep.newFills.isEmpty || !sweep.cashChanges.isEmpty
            || !sweep.ledgerEntries.isEmpty || !sweep.positionChanges.isEmpty
            || !sweep.alertRecords.isEmpty {
            saveToDisk()
        }
        return result
    }

    // MARK: - 预警文案

    /// 预警文案：形如「预警：现价 1512.30 上穿 1500.00」（仅入记录 / 运行时，不做 App 内弹窗）
    /// （训练态复用：放宽为 internal，纯计算无副作用）
    func alertMessage(order: SimCondOrder, triggerPrice: Double) -> String {
        let priceText = SimFormat.price(triggerPrice)
        let p = order.params
        switch order.kind {
        case .price:
            guard let target = p.triggerPrice else { return "预警：现价 \(priceText) 触发价格条件" }
            let verb = (p.compareUp ?? true) ? "上穿" : "下破"
            return "预警：现价 \(priceText) \(verb) \(SimFormat.price(target))"

        case .stopLoss:
            if let stop = p.stopLossPrice, triggerPrice <= stop {
                return "预警：现价 \(priceText) 下破止损价 \(SimFormat.price(stop))"
            }
            if let take = p.takeProfitPrice {
                return "预警：现价 \(priceText) 上穿止盈价 \(SimFormat.price(take))"
            }
            return "预警：现价 \(priceText) 触发止盈止损条件"

        case .trailing:
            if p.floorEnabled, let floor = p.floorPrice, triggerPrice <= floor {
                return "预警：现价 \(priceText) 跌破保底价 \(SimFormat.price(floor))"
            }
            let word = order.directive.direction == .sell ? "回落" : "反弹"
            return "预警：现价 \(priceText) \(word)达到 \(String(format: "%.1f", p.trailPct ?? 0))%"

        case .time:
            return "预警：现价 \(priceText) 到达触发时间"

        case .changePct:
            let threshold = p.changeThreshold ?? 0
            let word = threshold > 0 ? "涨幅" : "跌幅"
            return "预警：现价 \(priceText) 日\(word)达到 \(String(format: "%.1f", abs(threshold)))%"

        case .maCross:
            let period = p.maPeriod ?? 20
            let word = (p.maAbove ?? true) ? "上穿" : "下破"
            return "预警：现价 \(priceText) \(word) MA\(period)"

        case .grid:
            return "预警：现价 \(priceText) 触发网格档位"

        case .batch:
            return "预警：现价 \(priceText) 触发分批第 \(order.runtime.batchDone + 1) 批"
        }
    }

    // MARK: - 有效期

    /// 有效期判定：返回非 nil 即为失效原因（长期有效不因时间失效）
    /// （训练态复用：放宽为 internal，纯计算无副作用）
    func expiredReason(of order: SimCondOrder, today: Date, calendar: Calendar) -> String? {
        switch order.validity {
        case .longTerm:
            return nil
        case .day:
            return calendar.startOfDay(for: order.createdAt) < today ? "当日有效条件单已跨日失效" : nil
        case .untilDate:
            guard let expiresAt = order.expiresAt else { return nil }
            return calendar.startOfDay(for: expiresAt) < today ? "已超过指定有效期" : nil
        }
    }

    // MARK: - 触发辅助

    /// 触发方向：网格按「相对上一次触发价下移买入 / 上移卖出」双向推进，其余类型用用户设定方向
    /// （训练态复用：放宽为 internal，纯计算无副作用）
    func fireDirection(order: SimCondOrder, triggerPrice: Double) -> SimOrderDirection {
        guard order.kind == .grid else { return order.directive.direction }
        let base = order.runtime.gridLastPrice ?? order.params.gridBase ?? triggerPrice
        return triggerPrice < base ? .buy : .sell
    }

    /// 触发价 → 委托价：市价单不带价；限价单 = 触发价 + N 档（下限 0.01）
    /// （训练态复用：放宽为 internal，纯计算无副作用）
    func executionPrice(directive: SimCondDirective, triggerPrice: Double) -> Double? {
        guard directive.priceType == .limit else { return nil }
        let tick = SimTradeRuleConstants.priceTick
        return max(triggerPrice + Double(directive.offsetTicks) * tick, 0.01)
    }

    /// 多触发类型的档位 / 批次推进（网格记档位与本次触发价，分批记笔数）
    /// （训练态复用：放宽为 internal，纯计算无副作用）
    func advanceRepeatable(order: SimCondOrder, triggerPrice: Double) -> SimCondRuntime {
        var runtime = order.runtime
        switch order.kind {
        case .grid:
            runtime.gridLevel = (runtime.gridLevel ?? 0) + 1
            runtime.gridLastPrice = triggerPrice
        case .batch:
            runtime.batchDone += 1
        default:
            break
        }
        return runtime
    }

    /// 多触发类型是否已走完全部档位 / 批次
    /// （训练态复用：放宽为 internal，纯计算无副作用）
    func repeatableFinished(order: SimCondOrder) -> Bool {
        switch order.kind {
        case .grid:
            return (order.runtime.gridLevel ?? 0) >= SimCondRule.gridLevelCount(order: order)
        case .batch:
            return order.runtime.batchDone >= (order.params.batchCount ?? 0)
        default:
            return false
        }
    }
}
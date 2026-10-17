//
//  SimRulesAsync.swift
//  Kline
//
//  阶段 A5-4：交易判定 / 结算推进 / 交易规则的 **async 门面**。
//
//  为什么要 async：`.engine` 模式下引擎调用只能异步（`KlinePythonBridge.call` 的完成回调回主线程，
//  `blockingCall` 显式禁止主线程阻塞），而 `SimStore.submit` / `sweepConditions` 位于主线程同步路径。
//  故先在本文件把「一次 op」包装成 `async throws`（域类型进、域类型出），调用方（sweep / submit /
//  编辑器校验）再逐步改为 `await`。
//
//  与 `SimRulesBridge.payload` 的关系：本文件只做「入参装配 + 出参反解」，**不重复实现**任何判定；
//  两条后端（`.swift` 现状 / `.engine` 引擎）由 `payload` 按 `mode` 分发，故所有包装函数天然双跑一致。
//
//  降级（§9.10 / §11.7）：引擎未就绪时 `payload` 给 `.engineNotReady` → 本层 `throws`，调用方显式降级
//  （不下单 / 不结算），**不静默用 Swift 兜底**。
//

import Foundation

extension SimRulesBridge {

    // MARK: - 通用 async 原语

    /// 异步取一次 op 结果。
    /// - `.swift`：立即返回（`payload` 在 `.swift` 分支同步回调）。
    /// - `.engine`：调 `sim_rules.py`；引擎未就绪 → 抛 `.engineNotReady`。
    @MainActor
    static func payloadAsync(op: String, input: [String: Any],
                             timeout: TimeInterval = 30) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            payload(op: op, input: input, timeout: timeout) { r in
                switch r {
                case .success(let o): cont.resume(returning: o)
                case .failure(let f): cont.resume(throwing: f)
                }
            }
        }
    }

    // MARK: - A 组：条件单判定

    /// 条件单判定（`cond_evaluate`）→ `SimCondDecision`（形状非法 → nil）。
    ///
    /// `now` 两侧口径：引擎用它判 `.time` 条件（`CondRule` 的 `.swift` 现状内部取 `Date()`，
    /// 故 `now` 只对引擎生效——生产调用点传同一 `now`，两者差为一次求值耗时）。
    @MainActor
    static func evaluateCond(order: SimCondOrder, snapshot: SimCondSnapshot,
                             now: Date = Date()) async throws -> SimCondDecision? {
        let input: [String: Any] = ["order": SimRulesCodec.condOrderJSON(order) ?? [:],
                                    "snapshot": SimRulesCodec.snapshotJSON(snapshot),
                                    "now": SimRulesCodec.isoString(now)]
        let out = try await payloadAsync(op: "cond_evaluate", input: input)
        return SimRulesCodec.condDecisionFromJSON(out["result"])
    }

    /// 建单 / 改单校验（`cond_validate_create`）→ 拒绝原因（nil = 通过）。
    @MainActor
    static func validateCondCreate(order: SimCondOrder, account: SimAccount, position: SimPosition?,
                                   snapshot: SimCondSnapshot,
                                   now: Date = Date()) async throws -> SimCondRejection? {
        let input: [String: Any] = ["order": SimRulesCodec.condOrderJSON(order) ?? [:],
                                    "account": SimRulesCodec.accountJSON(account),
                                    "position": position.map(SimRulesCodec.positionJSON) ?? NSNull(),
                                    "snapshot": SimRulesCodec.snapshotJSON(snapshot),
                                    "now": SimRulesCodec.isoString(now)]
        let out = try await payloadAsync(op: "cond_validate_create", input: input)
        return SimRulesCodec.condRejectionFromJSON(out["result"])
    }

    // MARK: - B 组：结算纯推进

    /// 有效期失效原因（`cond_expired_reason`）→ 非 nil 即失效。
    /// `tzOffsetSeconds` 取 `calendar` 在 `now` 时刻的偏移（DST 时区与 Swift `Calendar.current`
    /// 可能差一小时，见 §11.5 已知限制）。
    @MainActor
    static func condExpiredReason(order: SimCondOrder, now: Date,
                                  calendar: Calendar) async throws -> String? {
        let input: [String: Any] = ["order": SimRulesCodec.condOrderJSON(order) ?? [:],
                                    "now": SimRulesCodec.isoString(now),
                                    "tzOffsetSeconds": calendar.timeZone.secondsFromGMT(for: now)]
        let out = try await payloadAsync(op: "cond_expired_reason", input: input)
        return SimRulesCodec.str(out["reason"])
    }

    /// 触发方向（`cond_fire_direction`）。
    @MainActor
    static func condFireDirection(order: SimCondOrder,
                                  triggerPrice: Double) async throws -> SimOrderDirection? {
        let out = try await payloadAsync(op: "cond_fire_direction",
                                         input: ["order": SimRulesCodec.condOrderJSON(order) ?? [:],
                                                 "triggerPrice": triggerPrice])
        return SimRulesCodec.str(out["direction"]).flatMap(SimOrderDirection.init(rawValue:))
    }

    /// 执行价（`cond_execution_price`）→ nil 表示「无价可用（市价/无行情）」。
    @MainActor
    static func condExecutionPrice(directive: SimCondDirective,
                                   triggerPrice: Double) async throws -> Double? {
        let out = try await payloadAsync(op: "cond_execution_price",
                                         input: ["directive": SimRulesCodec.directiveJSON(directive),
                                                 "triggerPrice": triggerPrice])
        return SimRulesCodec.num(out["price"])
    }

    /// 档位 / 批次推进（`cond_advance`）→ 新的运行时。
    @MainActor
    static func condAdvance(order: SimCondOrder, triggerPrice: Double) async throws -> SimCondRuntime {
        let out = try await payloadAsync(op: "cond_advance",
                                         input: ["order": SimRulesCodec.condOrderJSON(order) ?? [:],
                                                 "triggerPrice": triggerPrice])
        return SimRulesCodec.runtimeFromJSON(out["runtime"])
    }

    /// 多触发类型是否走完全部档位 / 批次（`cond_repeatable_finished`）。
    @MainActor
    static func condRepeatableFinished(order: SimCondOrder) async throws -> Bool {
        let out = try await payloadAsync(op: "cond_repeatable_finished",
                                         input: ["order": SimRulesCodec.condOrderJSON(order) ?? [:]])
        return SimRulesCodec.bool(out["finished"]) ?? false
    }

    /// 预警文案（`cond_alert_message`）。
    @MainActor
    static func condAlertMessage(order: SimCondOrder, triggerPrice: Double) async throws -> String {
        let out = try await payloadAsync(op: "cond_alert_message",
                                         input: ["order": SimRulesCodec.condOrderJSON(order) ?? [:],
                                                 "triggerPrice": triggerPrice])
        return SimRulesCodec.str(out["message"]) ?? ""
    }

    // MARK: - C 组：交易规则

    /// 下单授权校验（`trade_validate`）→ 拒绝原因（nil = 通过）。
    /// ⚠️ 这条是**红线 4**（「不变量守卫」）的引擎侧落点：`.engine` 模式下整手 / 涨跌停 / T+1
    /// 复核由引擎裁决，Swift 侧不再复算（D2）。
    @MainActor
    static func tradeValidate(draft: SimOrderDraft, account: SimAccount, position: SimPosition?,
                              lastPrice: Double?, prevClose: Double?) async throws -> SimOrderRejection? {
        var input: [String: Any] = ["draft": SimRulesCodec.orderDraftJSON(draft),
                                    "account": SimRulesCodec.accountJSON(account),
                                    "position": position.map(SimRulesCodec.positionJSON) ?? NSNull()]
        if let v = lastPrice { input["lastPrice"] = v }
        if let v = prevClose { input["prevClose"] = v }
        let out = try await payloadAsync(op: "trade_validate", input: input)
        return SimRulesCodec.orderRejectionFromJSON(out["result"])
    }

    /// 费用（`trade_calc.fee` = 佣金 + 印花税）。
    @MainActor
    static func tradeFee(amount: Double, direction: SimOrderDirection) async throws -> Double {
        let out = try await payloadAsync(op: "trade_calc",
                                         input: ["calc": "fee", "amount": amount,
                                                 "direction": direction.rawValue])
        return SimRulesCodec.num(out["value"]) ?? 0
    }

    /// 佣金（`trade_calc.commission`）。
    @MainActor
    static func tradeCommission(amount: Double) async throws -> Double {
        let out = try await payloadAsync(op: "trade_calc",
                                         input: ["calc": "commission", "amount": amount])
        return SimRulesCodec.num(out["value"]) ?? 0
    }

    /// 印花税（`trade_calc.stampTax`）。
    @MainActor
    static func tradeStampTax(amount: Double, direction: SimOrderDirection) async throws -> Double {
        let out = try await payloadAsync(op: "trade_calc",
                                         input: ["calc": "stampTax", "amount": amount,
                                                 "direction": direction.rawValue])
        return SimRulesCodec.num(out["value"]) ?? 0
    }

    /// 可买整手数量（`trade_calc.affordableQty`）。
    @MainActor
    static func tradeAffordableQty(cash: Double, price: Double) async throws -> Int {
        let out = try await payloadAsync(op: "trade_calc",
                                         input: ["calc": "affordableQty", "cash": cash, "price": price])
        return SimRulesCodec.int(out["value"]) ?? 0
    }

    /// 可卖数量（`trade_calc.sellableQty`，含 T+1）。
    @MainActor
    static func tradeSellableQty(position: SimPosition) async throws -> Int {
        let out = try await payloadAsync(op: "trade_calc",
                                         input: ["calc": "sellableQty",
                                                 "position": SimRulesCodec.positionJSON(position)])
        return SimRulesCodec.int(out["value"]) ?? 0
    }

    /// 是否交易时段（`trade_calc.isTradingSession`）。
    /// `tzOffsetSeconds` 取**本机时区在该时刻的偏移**（与 `.swift` 现状 `Calendar.current` 同口径；
    /// DST 时区与引擎的固定偏移可能差一小时，见 §11.5 已知限制）。
    @MainActor
    static func tradeIsTradingSession(at date: Date) async throws -> Bool {
        let out = try await payloadAsync(op: "trade_calc",
                                         input: ["calc": "isTradingSession",
                                                 "at": SimRulesCodec.isoString(date),
                                                 "tzOffsetSeconds": TimeZone.current
                                                     .secondsFromGMT(for: date)])
        return SimRulesCodec.bool(out["value"]) ?? false
    }

    /// 涨跌停区间（`trade_calc.limitRange`）→ nil 表示无昨收（不设限）。
    @MainActor
    static func tradeLimitRange(prevClose: Double?) async throws
        -> (lower: Double, upper: Double)? {
        var input: [String: Any] = ["calc": "limitRange"]
        if let v = prevClose { input["prevClose"] = v }
        let out = try await payloadAsync(op: "trade_calc", input: input)
        guard let r = out["range"] as? [String: Any] else { return nil }
        return (lower: SimRulesCodec.num(r["lower"]) ?? 0, upper: SimRulesCodec.num(r["upper"]) ?? 0)
    }

    // MARK: - D 组：策略 → 条件单草稿（纯映射）

    /// 规则 → 草稿（`strategy_drafts`）：账户 × 标的 × 规则 的**纯映射**部分。
    /// ⚠️ 时间相关规则（`TIME`）由引擎按 `tzOffsetSeconds` 判日期，故显式注入本机偏移。
    @MainActor
    static func strategyDrafts(doc: FormulaDoc, meta: MetaItem, accountID: UUID,
                               lastPrice: Double, costPrice: Double?) async throws
        -> (drafts: [StrategyCondDraft], skips: [StrategyGenSkip]) {
        var input: [String: Any] = ["rules": doc.rules,
                                    "trade": SimRulesCodec.tradeSpecJSON(doc.trade),
                                    "meta": SimRulesCodec.metaItemJSON(meta),
                                    "accountID": accountID.uuidString,
                                    "lastPrice": lastPrice,
                                    "tzOffsetSeconds": TimeZone.current.secondsFromGMT()]
        if let v = costPrice { input["costPrice"] = v }
        let out = try await payloadAsync(op: "strategy_drafts", input: input)
        let drafts = try ((out["drafts"] as? [Any]) ?? []).map {
            try SimRulesCodec.strategyDraftFromJSON($0)
        }
        let skips = ((out["skips"] as? [[String: Any]]) ?? []).map {
            StrategyGenSkip(title: SimRulesCodec.str($0["title"]) ?? "",
                            reason: SimRulesCodec.str($0["reason"]) ?? "")
        }
        return (drafts, skips)
    }

    /// 可选入场单（`strategy_entry_draft`）→ nil 表示不生成（无方向 / 无有效最新价）。
    @MainActor
    static func strategyEntryDraft(doc: FormulaDoc, meta: MetaItem, accountID: UUID,
                                   lastPrice: Double) async throws -> StrategyCondDraft? {
        let out = try await payloadAsync(op: "strategy_entry_draft",
                                         input: ["trade": SimRulesCodec.tradeSpecJSON(doc.trade),
                                                 "meta": SimRulesCodec.metaItemJSON(meta),
                                                 "accountID": accountID.uuidString,
                                                 "lastPrice": lastPrice])
        guard let d = out["draft"], !(d is NSNull) else { return nil }
        return try SimRulesCodec.strategyDraftFromJSON(d)
    }
}

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

    // MARK: - E 组：策略 DSL 纯解析 / 校验 / 预览

    /// 解析 RULES 文本（`strategy_parse`）→ 规则数组 + 中文错误清单。
    @MainActor
    static func strategyParse(lines: String) async throws
        -> (rules: [StrategyRuleCall], errors: [String]) {
        let out = try await payloadAsync(op: "strategy_parse", input: ["lines": lines])
        let rules = try ((out["rules"] as? [Any]) ?? []).map { try SimRulesCodec.ruleCallFromJSON($0) }
        return (rules, (out["errors"] as? [String]) ?? [])
    }

    /// 一条规则 → RULES 文本（`strategy_rule_line`）。
    @MainActor
    static func strategyRuleLine(_ call: StrategyRuleCall) async throws -> String {
        let out = try await payloadAsync(op: "strategy_rule_line",
                                         input: ["call": SimRulesCodec.ruleCallJSON(call)])
        guard let line = SimRulesCodec.str(out["line"]) else {
            throw SimRulesCodec.CodecError.badShape("strategyRuleLine.line")
        }
        return line
    }

    /// 规则目录（`strategy_catalog`）：`kind` 传 nil 取全部 8 类。
    @MainActor
    static func strategyCatalog(kind: StrategyRuleKind? = nil) async throws
        -> [StrategyRuleKind: SimRulesCodec.StrategyCatalogEntry] {
        var input: [String: Any] = [:]
        if let kind { input["kind"] = kind.rawValue }
        let out = try await payloadAsync(op: "strategy_catalog", input: input)
        return SimRulesCodec.catalogFromJSON(out["catalog"])
    }

    /// 静态校验（`strategy_validate`）→ 中文错误清单（空 = 通过）。
    /// `pickSyntaxError` 由调用方的 TDX 试算得到，原样透传给引擎。
    @MainActor
    static func strategyValidate(doc: FormulaDoc, pickerExists: Bool,
                                 pickSyntaxError: String?) async throws -> [String] {
        var input: [String: Any] = ["doc": SimRulesCodec.formulaDocJSON(doc),
                                    "pickerExists": pickerExists]
        if let pickSyntaxError { input["pickSyntaxError"] = pickSyntaxError }
        let out = try await payloadAsync(op: "strategy_validate", input: input)
        return (out["issues"] as? [String]) ?? []
    }

    /// 语义预览（`strategy_preview`）：全为展示文案。
    /// ⚠️ `tzOffsetSeconds` 必需（`trade` 摘要里的「有效期至 MM-dd」按本地壁钟）。
    @MainActor
    static func strategyPreview(doc: FormulaDoc, pickerName: String?) async throws
        -> SimRulesCodec.StrategyPreviewResult {
        var input: [String: Any] = ["doc": SimRulesCodec.formulaDocJSON(doc),
                                    "tzOffsetSeconds": TimeZone.current.secondsFromGMT()]
        if let pickerName { input["pickerName"] = pickerName }
        let out = try await payloadAsync(op: "strategy_preview", input: input)
        guard let r = SimRulesCodec.previewFromJSON(out) else {
            throw SimRulesCodec.CodecError.badShape("strategyPreview")
        }
        return r
    }

    /// TRADE 段解析（`trade_parse`）→ 规格 + 中文错误清单。
    /// ⚠️ `tzOffsetSeconds` 必需（`EXPIRES=YYYY-MM-DD` 要按本地日历拼日界）。
    @MainActor
    static func tradeParse(lines: [String]) async throws
        -> (spec: StrategyTradeSpec, errors: [String]) {
        let out = try await payloadAsync(op: "trade_parse",
                                         input: ["lines": lines,
                                                 "tzOffsetSeconds": TimeZone.current.secondsFromGMT()])
        return (SimRulesCodec.tradeSpecFromJSON(out["spec"]), (out["errors"] as? [String]) ?? [])
    }

    /// TRADE 段序列化（`trade_serialize`）→ 文本。
    @MainActor
    static func tradeSerialize(_ spec: StrategyTradeSpec) async throws -> String {
        let out = try await payloadAsync(op: "trade_serialize",
                                         input: ["spec": SimRulesCodec.tradeSpecJSON(spec),
                                                 "tzOffsetSeconds": TimeZone.current.secondsFromGMT()])
        guard let text = SimRulesCodec.str(out["text"]) else {
            throw SimRulesCodec.CodecError.badShape("tradeSerialize.text")
        }
        return text
    }

    /// 规则行内 ORD* 覆盖（`trade_override`）→ 覆盖值 + 是否为空 + 中文摘要。
    /// `isEmpty` / `summary` 取引擎出参（摘要属展示口径，不从 Swift 复算）。
    @MainActor
    static func tradeOverride(_ call: StrategyRuleCall) async throws
        -> (override: StrategyDirectiveOverride, isEmpty: Bool, summary: String?) {
        let out = try await payloadAsync(op: "trade_override",
                                         input: ["call": SimRulesCodec.ruleCallJSON(call)])
        return (SimRulesCodec.directiveOverrideFromJSON(out["override"]),
                SimRulesCodec.bool(out["isEmpty"]) ?? true,
                out["summary"] as? String)
    }

    // MARK: - C 组：下单执行主循环（`submit_order`，阶段 C 完全下沉）

    /// 下单执行（`submit_order`）：校验 → 交易时段判断 → 订单创建 → 成交/持仓/资金/流水推进。
    /// Swift 仅负责入参装配 + 出参反解 + 应用；**所有业务逻辑在 Python 引擎中执行**。
    @MainActor
    static func submitOrder(draft: SimOrderDraft, account: SimAccount, position: SimPosition?,
                            lastPrice: Double?, prevClose: Double?, now: Date,
                            tzOffsetSeconds: Int, fills: [SimFill],
                            orders: [SimOrder]) async throws -> SubmitOrderResult {
        var input: [String: Any] = [
            "draft": SimRulesCodec.orderDraftJSON(draft),
            "account": SimRulesCodec.accountJSON(account),
            "position": position.map(SimRulesCodec.positionJSON) ?? NSNull(),
            "now": SimRulesCodec.isoString(now),
            "tzOffsetSeconds": tzOffsetSeconds,
            "fills": fills.map(SimRulesCodec.fillJSON),
            "orders": orders.map(SimRulesCodec.orderJSON)
        ]
        if let v = lastPrice { input["lastPrice"] = v }
        if let v = prevClose { input["prevClose"] = v }
        let out = try await payloadAsync(op: "submit_order", input: input)
        guard let result = out["result"] as? [String: Any] else {
            throw SimRulesCodec.CodecError.badShape("submit_order.result")
        }
        return SubmitOrderResult(from: result)
    }

    /// `submit_order` 出参（引擎权威；Swift 侧只做反解与应用）。
    ///
    /// ⚠️ `positionChange` / `ledgerEntry` / `logEntry` 里的 `UUID` / `Date` 必须还原成
    /// **原生类型**：调用方 `SimStore.applyPositionChangePython` / `appendLedgerFromDict` /
    /// `appendLogFromDict` 是按 `as? UUID` / `as? Date` 读取的（不是字符串）。
    struct SubmitOrderResult {
        var order: SimOrder?
        var fills: [SimFill] = []
        var rejection: SimOrderRejection?
        var cashChange: [String: Any]?
        var positionChange: [String: Any]?
        var ledgerEntry: [String: Any]?
        var logEntry: [String: Any]?

        init(from result: [String: Any]) {
            order = (result["order"] as? [String: Any]).map(SimRulesCodec.orderFromJSON)
            fills = (result["fills"] as? [[String: Any]] ?? []).map(SimRulesCodec.fillFromJSON)
            rejection = SimRulesCodec.orderRejectionFromJSON(result["rejection"])
            cashChange = Self.cashChangeFromJSON(result["cashChange"])
            positionChange = Self.positionChangeFromJSON(result["positionChange"])
            ledgerEntry = Self.ledgerEntryFromJSON(result["ledgerEntry"])
            logEntry = Self.logEntryFromJSON(result["logEntry"])
        }

        private static func cashChangeFromJSON(_ any: Any?) -> [String: Any]? {
            guard let d = any as? [String: Any], let cash = SimRulesCodec.num(d["cash"]) else { return nil }
            var o: [String: Any] = ["cash": cash]
            if let id = SimRulesCodec.uuid(d["accountID"]) { o["accountID"] = id }
            return o
        }

        private static func positionChangeFromJSON(_ any: Any?) -> [String: Any]? {
            guard let d = any as? [String: Any] else { return nil }
            var o: [String: Any] = [:]
            if let v = SimRulesCodec.uuid(d["accountID"]) { o["accountID"] = v }
            if let v = SimRulesCodec.int(d["metaID"]) { o["metaID"] = v }
            if let v = SimRulesCodec.str(d["code"]) { o["code"] = v }
            if let v = SimRulesCodec.str(d["name"]) { o["name"] = v }
            if let v = SimRulesCodec.int(d["qty"]) { o["qty"] = v }
            if let v = SimRulesCodec.int(d["availableQty"]) { o["availableQty"] = v }
            if let v = SimRulesCodec.num(d["costPrice"]) { o["costPrice"] = v }
            if let v = SimRulesCodec.isoDate(d["openedAt"]) { o["openedAt"] = v }
            o["removed"] = SimRulesCodec.bool(d["removed"]) ?? false
            return o
        }

        private static func ledgerEntryFromJSON(_ any: Any?) -> [String: Any]? {
            guard let d = any as? [String: Any] else { return nil }
            var o: [String: Any] = [:]
            if let v = SimRulesCodec.uuid(d["id"]) { o["id"] = v }
            if let v = SimRulesCodec.uuid(d["accountID"]) { o["accountID"] = v }
            if let v = SimRulesCodec.str(d["kind"]) { o["kind"] = v }
            if let v = SimRulesCodec.str(d["note"]) { o["note"] = v }
            if let v = SimRulesCodec.num(d["amount"]) { o["amount"] = v }
            if let v = SimRulesCodec.num(d["balanceAfter"]) { o["balanceAfter"] = v }
            if let v = SimRulesCodec.isoDate(d["occurredAt"]) { o["occurredAt"] = v }
            return o
        }

        private static func logEntryFromJSON(_ any: Any?) -> [String: Any]? {
            guard let d = any as? [String: Any] else { return nil }
            var o: [String: Any] = [:]
            if let v = SimRulesCodec.uuid(d["id"]) { o["id"] = v }
            if let v = SimRulesCodec.uuid(d["accountID"]) { o["accountID"] = v }
            if let v = SimRulesCodec.str(d["module"]) { o["module"] = v }
            if let v = SimRulesCodec.str(d["content"]) { o["content"] = v }
            if let v = SimRulesCodec.str(d["result"]) { o["result"] = v }
            if let v = SimRulesCodec.isoDate(d["occurredAt"]) { o["occurredAt"] = v }
            return o
        }
    }

    // MARK: - 训练态：成交执行 / 条件单结算（完全下沉到引擎）

    /// 训练态成交执行（`training_execute_trade`）：校验 → 费用 → 资金 → 持仓/盈亏推进。
    /// Swift 仅负责入参装配 + 出参应用 + 落库。
    @MainActor
    static func trainingExecuteTrade(sessionState: [String: Any],
                                     tradeDirection: SimOrderDirection,
                                     tradeQty: Int,
                                     tradePrice: Double,
                                     tradeDate: Int,
                                     tradeNote: String,
                                     accountType: String) async throws -> TrainingExecuteTradeResult {
        let input: [String: Any] = [
            "sessionState": sessionState,
            "trade": ["direction": tradeDirection.rawValue,
                      "qty": tradeQty,
                      "price": tradePrice,
                      "date": tradeDate,
                      "note": tradeNote],
            "accountType": accountType
        ]
        let out = try await payloadAsync(op: "training_execute_trade", input: input)
        guard let result = out["result"] as? [String: Any] else {
            throw SimRulesCodec.CodecError.badShape("training_execute_trade.result")
        }
        return TrainingExecuteTradeResult(from: result)
    }

    /// `training_execute_trade` 出参。
    struct TrainingExecuteTradeResult {
        var trade: [String: Any]?
        var state: [String: Any]
        var rejection: [String: Any]?

        init(from result: [String: Any]) {
            trade = result["trade"] as? [String: Any]
            state = result["state"] as? [String: Any] ?? [:]
            rejection = result["rejection"] as? [String: Any]
        }
    }

    /// 训练态条件单结算（`training_sweep`）：有效期 → 快照 → 判定 → 触发意图 → 档位推进/完成 → 预警。
    /// ⚠️ 触发后**不直接下单**：返回 `tradeIntents`，由 Swift 层调用 `settleTrade` 处理成交。
    @MainActor
    static func trainingSweep(orders: [SimCondOrder],
                              snapshots: [UUID: SimCondSnapshot],
                              trainingDate: Int,
                              tzOffsetSeconds: Int) async throws -> TrainingSweepResult {
        let ordersJSON = orders.compactMap { SimRulesCodec.condOrderJSON($0) }
        var snapshotsJSON: [String: Any] = [:]
        for (id, snap) in snapshots {
            snapshotsJSON[id.uuidString] = SimRulesCodec.snapshotJSON(snap)
        }
        let input: [String: Any] = [
            "orders": ordersJSON,
            "snapshots": snapshotsJSON,
            "now": SimRulesCodec.isoString(Date()),
            "trainingDate": trainingDate,
            "tzOffsetSeconds": tzOffsetSeconds
        ]
        let out = try await payloadAsync(op: "training_sweep", input: input)
        guard let result = out["result"] as? [String: Any] else {
            throw SimRulesCodec.CodecError.badShape("training_sweep.result")
        }
        return TrainingSweepResult(from: result)
    }

    /// `training_sweep` 出参。
    struct TrainingSweepResult {
        var evaluated = 0
        var fired = 0
        var rejected = 0
        var expired = 0
        var completed = 0
        var orders: [SimCondOrder] = []
        var tradeIntents: [[String: Any]] = []
        var alertRecords: [[String: Any]] = []
        var logs: [[String: Any]] = []

        init(from result: [String: Any]) {
            evaluated = SimRulesCodec.int(result["evaluated"]) ?? 0
            fired = SimRulesCodec.int(result["fired"]) ?? 0
            rejected = SimRulesCodec.int(result["rejected"]) ?? 0
            expired = SimRulesCodec.int(result["expired"]) ?? 0
            completed = SimRulesCodec.int(result["completed"]) ?? 0
            orders = (result["orders"] as? [[String: Any]] ?? [])
                .compactMap { try? SimRulesCodec.condOrderFromJSON($0) }
            tradeIntents = result["tradeIntents"] as? [[String: Any]] ?? []
            // 预警记录的 `occurredAt` 需还原为原生 `Date`（调用方按 `as? Date` 读取）。
            alertRecords = (result["alertRecords"] as? [[String: Any]] ?? []).compactMap { d in
                guard let id = SimRulesCodec.str(d["id"]), !id.isEmpty,
                      SimRulesCodec.str(d["condID"]) != nil,
                      let price = SimRulesCodec.num(d["price"]),
                      SimRulesCodec.str(d["message"]) != nil,
                      let occurredAt = SimRulesCodec.isoDate(d["occurredAt"]) else { return nil }
                var o = d
                o["price"] = price
                o["occurredAt"] = occurredAt
                return o
            }
            logs = result["logs"] as? [[String: Any]] ?? []
        }
    }
}

//
//  SimRulesAsyncTests.swift
//  KlineTests
//
//  阶段 A5-4：`SimRulesBridge` 的 **async 门面**（SimRulesAsync.swift）领域级对拍。
//
//  与 `SimRulesDiffTests` 的分工：
//    · `SimRulesDiffTests` 比的是 **op 级 JSON**（两侧后端逐字段）；
//    · 本套件比的是 **领域类型**——`evaluateCond` / `tradeValidate` / … 的返回值与 Swift 现状
//      （`SimCondRule.evaluate` / `SimTradingRules.validate` / …）逐条相等。
//  两者合起来才能证明「引擎输出 → 领域模型」的**反解**（A5-4 新写的写回变换）无损失：
//  只比 JSON 会漏掉「JSON 对了但反解错了」的 bug。
//
//  用例来源：三份 fixture 的既有入参（**不新增 golden、不改 fixture**），
//  同一批用例在 `.swift` 与 `.engine` 两种 `mode` 下各跑一遍（引擎未就绪 → XCTSkip）。
//

import XCTest
@testable import Kline

@MainActor
final class SimRulesAsyncTests: XCTestCase {

    // MARK: - fixture 读取

    private func loadFixture(_ name: String) throws -> [String: Any] {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "SimRulesAsyncTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bad fixture \(name).json"])
        }
        return root
    }

    private func cases(_ fixture: [String: Any], _ segment: String,
                       op: String? = nil) -> [[String: Any]] {
        let all = (fixture[segment] as? [[String: Any]]) ?? []
        guard let op else { return all }
        return all.filter { ($0["op"] as? String) == op }
    }

    private func input(_ c: [String: Any]) -> [String: Any] { (c["input"] as? [String: Any]) ?? [:] }
    private func name(_ c: [String: Any]) -> String { (c["caseName"] as? String) ?? "?" }

    // MARK: - 领域对象装配（从 fixture 入参形状）

    private func order(_ any: Any?) throws -> SimCondOrder {
        try SimRulesCodec.condOrderFromJSON(any)
    }

    private func snapshot(_ any: Any?) -> SimCondSnapshot {
        SimRulesCodec.snapshotFromJSON(any)
    }

    private func account(_ any: Any?) -> SimAccount { SimRulesCodec.accountFromJSON(any) }
    private func position(_ any: Any?) -> SimPosition? { SimRulesCodec.positionFromJSON(any) }

    /// `trade_validate` 的 draft：与 `SimRulesBridge.runTradeValidate` 同法装配。
    private func draft(_ any: Any?) -> SimOrderDraft {
        let d = (any as? [String: Any]) ?? [:]
        return SimOrderDraft(accountID: SimRulesCodec.uuid(d["accountID"]) ?? UUID(),
                             metaID: SimRulesCodec.int(d["metaID"]) ?? 0,
                             code: SimRulesCodec.str(d["code"]) ?? "",
                             name: SimRulesCodec.str(d["name"]) ?? "",
                             direction: SimRulesCodec.str(d["direction"])
                                 .flatMap(SimOrderDirection.init(rawValue:)) ?? .buy,
                             priceType: SimRulesCodec.str(d["priceType"])
                                 .flatMap(SimPriceType.init(rawValue:)) ?? .market,
                             price: SimRulesCodec.num(d["price"]),
                             qty: SimRulesCodec.int(d["qty"]) ?? 0)
    }

    private func tzCalendar(_ any: Any?) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: SimRulesCodec.int(any) ?? 0) ?? .current
        return cal
    }

    private func date(_ any: Any?) -> Date { SimRulesCodec.isoDate(any) ?? Date() }

    /// `SimCondDecision` 非 Equatable，故投影成可比较文本（含全部关联值）。
    private func desc(_ d: SimCondDecision?) -> String {
        guard let d else { return "<nil>" }
        switch d {
        case .fire(let qty, let at): return "fire(qty:\(qty),at:\(at))"
        case .hold(let r): return "hold(\(desc(r)))"
        case .abort(let s): return "abort(\(s))"
        case .complete(let s): return "complete(\(s))"
        }
    }

    private func desc(_ r: SimCondRuntime) -> String {
        [r.extreme.map { "\($0)" } ?? "-", r.lastPrice.map { "\($0)" } ?? "-",
         r.gridLevel.map { "\($0)" } ?? "-", r.gridLastPrice.map { "\($0)" } ?? "-",
         "\(r.batchDone)", r.lastEvaluatedAt.map { SimRulesCodec.isoString($0) } ?? "-",
         r.lastMessage, r.lastTriggerPrice.map { "\($0)" } ?? "-"].joined(separator: "|")
    }

    private func desc(_ r: SimCondRejection?) -> String { r.map { "\($0)" } ?? "<nil>" }
    private func desc(_ r: SimOrderRejection?) -> String { r.map { "\($0)" } ?? "<nil>" }

    // MARK: - 引擎就绪

    private func ensureEngineReady() async throws {
        if KlinePythonBridge.shared.isReady { return }
        var failureMsg: String?
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            KlinePythonBridge.shared.ensureReady { r in
                if case .failure(let m) = r { failureMsg = m }
                cont.resume()
            }
        }
        if let m = failureMsg {
            throw XCTSkip("Python 引擎未就绪：\(m)——无引擎构建验证降级路径而非失败")
        }
    }

    // MARK: - 全部对拍（两种 mode 共用）

    private func runAllParity(_ mode: SimRulesBridge.Mode) async throws {
        let saved = SimRulesBridge.mode
        defer { SimRulesBridge.mode = saved }
        SimRulesBridge.mode = mode

        let sim = try loadFixture("sim_rules")

        // ---- A 组：cond_evaluate
        for c in cases(sim, "evaluate") {
            let i = input(c)
            let o = try order(i["order"]), s = snapshot(i["snapshot"])
            let got = try await SimRulesBridge.evaluateCond(order: o, snapshot: s,
                                                            now: date(i["now"]))
            let want = SimCondRule.evaluate(order: o, snapshot: s)
            XCTAssertEqual(desc(got), desc(want), "\(mode) cond_evaluate \(name(c))")
        }

        // ---- A 组：cond_validate_create
        for c in cases(sim, "validateCreate") {
            let i = input(c)
            let o = try order(i["order"]), s = snapshot(i["snapshot"])
            let acct = account(i["account"]), pos = position(i["position"])
            let now = date(i["now"])
            let got = try await SimRulesBridge.validateCondCreate(order: o, account: acct,
                                                                  position: pos, snapshot: s, now: now)
            let want = SimCondRule.validateCreate(order: o, account: acct, position: pos,
                                                  snapshot: s, now: now)
            XCTAssertEqual(desc(got), desc(want), "\(mode) cond_validate_create \(name(c))")
        }

        // ---- B 组：结算纯推进
        for c in cases(sim, "sweep") {
            let i = input(c)
            let o = try order(i["order"])
            let tp = SimRulesCodec.num(i["triggerPrice"]) ?? 0
            switch name(c).split(separator: ".")[0] {
            case "exp":
                let now = date(i["now"]), cal = tzCalendar(i["tzOffsetSeconds"])
                let got = try await SimRulesBridge.condExpiredReason(order: o, now: now, calendar: cal)
                let want = SimStore.shared.expiredReason(of: o, today: cal.startOfDay(for: now),
                                                         calendar: cal)
                XCTAssertEqual(got ?? "<nil>", want ?? "<nil>", "\(mode) cond_expired_reason \(name(c))")
            case "fire_dir":
                let got = try await SimRulesBridge.condFireDirection(order: o, triggerPrice: tp)
                XCTAssertEqual(got, SimStore.shared.fireDirection(order: o, triggerPrice: tp),
                               "\(mode) cond_fire_direction \(name(c))")
            case "exec":
                let dir = directive(i["directive"])
                let got = try await SimRulesBridge.condExecutionPrice(directive: dir, triggerPrice: tp)
                XCTAssertEqual(got, SimStore.shared.executionPrice(directive: dir, triggerPrice: tp),
                               "\(mode) cond_execution_price \(name(c))")
            case "adv":
                let got = try await SimRulesBridge.condAdvance(order: o, triggerPrice: tp)
                XCTAssertEqual(desc(got),
                               desc(SimStore.shared.advanceRepeatable(order: o, triggerPrice: tp)),
                               "\(mode) cond_advance \(name(c))")
            case "rep":
                let got = try await SimRulesBridge.condRepeatableFinished(order: o)
                XCTAssertEqual(got, SimStore.shared.repeatableFinished(order: o),
                               "\(mode) cond_repeatable_finished \(name(c))")
            case "alert":
                let got = try await SimRulesBridge.condAlertMessage(order: o, triggerPrice: tp)
                XCTAssertEqual(got, SimStore.shared.alertMessage(order: o, triggerPrice: tp),
                               "\(mode) cond_alert_message \(name(c))")
            default:
                XCTFail("sweep 段出现未覆盖的 op：\(name(c))")
            }
        }

        // ---- C 组：trade_validate
        for c in cases(sim, "tradingRules", op: "trade_validate") {
            let i = input(c)
            let d = draft(i["draft"]), acct = account(i["account"]), pos = position(i["position"])
            let last = SimRulesCodec.num(i["lastPrice"]), prev = SimRulesCodec.num(i["prevClose"])
            let got = try await SimRulesBridge.tradeValidate(draft: d, account: acct, position: pos,
                                                             lastPrice: last, prevClose: prev)
            let want = SimTradingRules.default.validate(draft: d, account: acct, position: pos,
                                                        lastPrice: last, prevClose: prev)
            XCTAssertEqual(desc(got), desc(want), "\(mode) trade_validate \(name(c))")
        }

        // ---- C 组：trade_calc（feature 子集：fee / affordableQty / sellableQty / isTradingSession / limitRange）
        for c in cases(sim, "tradingRules", op: "trade_calc") {
            let i = input(c)
            let calc = SimRulesCodec.str(i["calc"]) ?? ""
            let rules = SimTradingRules.default
            switch calc {
            case "commission":
                let amount = SimRulesCodec.num(i["amount"]) ?? 0
                let got = try await SimRulesBridge.tradeCommission(amount: amount)
                XCTAssertEqual(got, rules.commission(amount: amount), accuracy: 1e-9,
                               "\(mode) trade_calc.commission \(name(c))")
            case "stampTax":
                let dir = SimRulesCodec.str(i["direction"])
                    .flatMap(SimOrderDirection.init(rawValue:)) ?? .buy
                let amount = SimRulesCodec.num(i["amount"]) ?? 0
                let got = try await SimRulesBridge.tradeStampTax(amount: amount, direction: dir)
                XCTAssertEqual(got, rules.stampTax(amount: amount, direction: dir), accuracy: 1e-9,
                               "\(mode) trade_calc.stampTax \(name(c))")
            case "fee":
                let dir = SimRulesCodec.str(i["direction"])
                    .flatMap(SimOrderDirection.init(rawValue:)) ?? .buy
                let amount = SimRulesCodec.num(i["amount"]) ?? 0
                let got = try await SimRulesBridge.tradeFee(amount: amount, direction: dir)
                XCTAssertEqual(got, rules.fee(amount: amount, direction: dir), accuracy: 1e-9,
                               "\(mode) trade_calc.fee \(name(c))")
            case "affordableQty":
                let cash = SimRulesCodec.num(i["cash"]) ?? 0
                let price = SimRulesCodec.num(i["price"]) ?? 0
                let got = try await SimRulesBridge.tradeAffordableQty(cash: cash, price: price)
                XCTAssertEqual(got, rules.affordableQty(cash: cash, price: price),
                               "\(mode) trade_calc.affordableQty \(name(c))")
            case "sellableQty":
                guard let pos = position(i["position"]) else { break }
                let got = try await SimRulesBridge.tradeSellableQty(position: pos)
                XCTAssertEqual(got, rules.sellableQty(position: pos),
                               "\(mode) trade_calc.sellableQty \(name(c))")
            case "isTradingSession":
                let at = date(i["at"])
                let got = try await SimRulesBridge.tradeIsTradingSession(at: at)
                XCTAssertEqual(got, rules.isTradingSession(at: at),
                               "\(mode) trade_calc.isTradingSession \(name(c))")
            case "limitRange":
                let prev = SimRulesCodec.num(i["prevClose"])
                let got = try await SimRulesBridge.tradeLimitRange(prevClose: prev)
                let want = rules.limitRange(prevClose: prev)
                XCTAssertEqual(got?.lower ?? -1, want?.lowerBound ?? -1, accuracy: 1e-9,
                               "\(mode) trade_calc.limitRange.lower \(name(c))")
                XCTAssertEqual(got?.upper ?? -1, want?.upperBound ?? -1, accuracy: 1e-9,
                               "\(mode) trade_calc.limitRange.upper \(name(c))")
            default:
                XCTFail("trade_calc 出现未覆盖的 calc：\(calc)（\(name(c))）")
            }
        }

        // ---- D 组：strategy_drafts（纯映射；本组专验 `strategyDraftFromJSON` 反解无损失）
        for c in cases(sim, "mapping", op: "strategy_drafts") {
            let i = input(c)
            let doc = strategyDoc(i["rules"], i["trade"])
            let meta = SimRulesCodec.metaItemFromJSON(i["meta"])
            let accountID = SimRulesCodec.uuid(i["accountID"]) ?? UUID()
            let last = SimRulesCodec.num(i["lastPrice"]) ?? 0
            let cost = SimRulesCodec.num(i["costPrice"])
            let got = try await SimRulesBridge.strategyDrafts(doc: doc, meta: meta,
                                                              accountID: accountID,
                                                              lastPrice: last, costPrice: cost)
            let want = StrategyCondGenerator.drafts(doc: doc, meta: meta, accountID: accountID,
                                                    lastPrice: last, costPrice: cost)
            XCTAssertEqual(got.drafts.map(desc), want.drafts.map(desc),
                           "\(mode) strategy_drafts \(name(c))")
            XCTAssertEqual(got.skips.map(skipDesc), want.skips.map(skipDesc),
                           "\(mode) strategy_drafts.skips \(name(c))")
        }

        // ---- D 组：strategy_entry_draft（可选入场单，nil = 不生成）
        for c in cases(sim, "mapping", op: "strategy_entry_draft") {
            let i = input(c)
            let doc = strategyDoc(nil, i["trade"])
            let meta = SimRulesCodec.metaItemFromJSON(i["meta"])
            let accountID = SimRulesCodec.uuid(i["accountID"]) ?? UUID()
            let last = SimRulesCodec.num(i["lastPrice"]) ?? 0
            let got = try await SimRulesBridge.strategyEntryDraft(doc: doc, meta: meta,
                                                                  accountID: accountID,
                                                                  lastPrice: last)
            let want = StrategyCondGenerator.entryDraft(doc: doc, meta: meta, accountID: accountID,
                                                        lastPrice: last)
            XCTAssertEqual(got.map(desc) ?? "<nil>", want.map(desc) ?? "<nil>",
                           "\(mode) strategy_entry_draft \(name(c))")
        }

        // ---- E 组：策略 DSL 纯解析 / 校验 / 预览（本组覆盖 E 组全部新反解）
        let dsl = try loadFixture("strategy_dsl")

        for c in cases(dsl, "strategyParse") {
            let lines = SimRulesCodec.str(input(c)["lines"]) ?? ""
            let got = try await SimRulesBridge.strategyParse(lines: lines)
            let want = StrategyRuleParser.parse(lines: lines)
            XCTAssertEqual(got.rules.map(ruleDesc), want.rules.map(ruleDesc),
                           "\(mode) strategy_parse.rules \(name(c))")
            XCTAssertEqual(got.errors, want.errors, "\(mode) strategy_parse.errors \(name(c))")
        }

        for c in cases(dsl, "strategyRuleLine") {
            guard let call = try? ruleCall(input(c)["call"]) else { continue }
            let got = try await SimRulesBridge.strategyRuleLine(call)
            XCTAssertEqual(got, StrategyRuleParser.line(for: call),
                           "\(mode) strategy_rule_line \(name(c))")
        }

        for c in cases(dsl, "strategyCatalog") {
            let kinds = SimRulesCodec.str(input(c)["kind"])
                .flatMap(StrategyRuleKind.init(rawValue:)).map { [$0] } ?? StrategyRuleKind.allCases
            let got = try await SimRulesBridge.strategyCatalog(kind: kinds.count == 1 ? kinds[0] : nil)
            for kind in kinds {
                guard let e = got[kind] else {
                    XCTFail("\(mode) strategy_catalog 缺 \(kind.rawValue)（\(name(c))）"); continue
                }
                XCTAssertEqual(e.title, kind.title, "\(mode) catalog.title \(kind.rawValue)")
                XCTAssertEqual(e.conditionOrderTitle, kind.conditionOrderTitle,
                               "\(mode) catalog.conditionOrderTitle \(kind.rawValue)")
                XCTAssertEqual(e.knownKeys, StrategyRuleCatalog.knownKeys(for: kind).sorted(),
                               "\(mode) catalog.knownKeys \(kind.rawValue)")
                XCTAssertEqual(e.specs.map(specDesc),
                               StrategyRuleCatalog.specs(for: kind).map(specDesc),
                               "\(mode) catalog.specs \(kind.rawValue)")
                XCTAssertFalse(e.simCondKind.isEmpty, "\(mode) catalog.simCondKind 为空 \(kind.rawValue)")
            }
        }

        for c in cases(dsl, "strategyValidate") {
            let i = input(c)
            let doc = SimRulesCodec.formulaDocFromJSON(i["doc"])
            let exists = SimRulesCodec.bool(i["pickerExists"]) ?? false
            let syntax = SimRulesCodec.str(i["pickSyntaxError"])
            let got = try await SimRulesBridge.strategyValidate(doc: doc, pickerExists: exists,
                                                               pickSyntaxError: syntax)
            let want = StrategyValidator.validate(doc: doc, pickerExists: exists,
                                                  pickSyntaxError: syntax)
            XCTAssertEqual(got, want, "\(mode) strategy_validate \(name(c))")
        }

        for c in cases(dsl, "strategyPreview") {
            let i = input(c)
            let doc = SimRulesCodec.formulaDocFromJSON(i["doc"])
            let pickerName = SimRulesCodec.str(i["pickerName"])
            let got = try await SimRulesBridge.strategyPreview(doc: doc, pickerName: pickerName)
            XCTAssertEqual(got.summary, StrategyPreview.summary(doc: doc, pickerName: pickerName),
                           "\(mode) strategy_preview.summary \(name(c))")
            XCTAssertEqual(got.pick, StrategyPreview.pickSummary(doc: doc, pickerName: pickerName),
                           "\(mode) strategy_preview.pick \(name(c))")
            XCTAssertEqual(got.trade, StrategyPreview.tradeSummary(doc: doc),
                           "\(mode) strategy_preview.trade \(name(c))")
            XCTAssertEqual(got.executionNotice, StrategyPreview.executionNotice,
                           "\(mode) strategy_preview.executionNotice \(name(c))")
            let (calls, _) = StrategyRuleParser.parse(lines: doc.rules)
            XCTAssertEqual(got.triggers, calls.map { StrategyPreview.triggerText($0) },
                           "\(mode) strategy_preview.triggers \(name(c))")
        }

        for c in cases(dsl, "tradeParse") {
            let lines = tradeLines(input(c)["lines"])
            let got = try await SimRulesBridge.tradeParse(lines: lines)
            let want = StrategyTradeParser.parse(lines: lines)
            XCTAssertEqual(jsonDesc(SimRulesCodec.tradeSpecJSON(got.spec)),
                           jsonDesc(SimRulesCodec.tradeSpecJSON(want.spec)),
                           "\(mode) trade_parse.spec \(name(c))")
            XCTAssertEqual(got.errors, want.errors, "\(mode) trade_parse.errors \(name(c))")
        }

        for c in cases(dsl, "tradeSerialize") {
            let spec = SimRulesCodec.tradeSpecFromJSON(input(c)["spec"])
            let got = try await SimRulesBridge.tradeSerialize(spec)
            XCTAssertEqual(got, StrategyTradeParser.serialize(spec),
                           "\(mode) trade_serialize \(name(c))")
        }

        for c in cases(dsl, "tradeOverride") {
            guard let call = try? ruleCall(input(c)["call"]) else { continue }
            let got = try await SimRulesBridge.tradeOverride(call)
            let want = StrategyTradeParser.override(in: call)
            XCTAssertEqual(jsonDesc(SimRulesCodec.directiveOverrideJSON(got.override)),
                           jsonDesc(SimRulesCodec.directiveOverrideJSON(want)),
                           "\(mode) trade_override \(name(c))")
            XCTAssertEqual(got.isEmpty, want.isEmpty, "\(mode) trade_override.isEmpty \(name(c))")
            XCTAssertEqual(got.summary ?? "<nil>", want.summary ?? "<nil>",
                           "\(mode) trade_override.summary \(name(c))")
        }
    }

    // MARK: - E 组装配 / 比较

    private func ruleCall(_ any: Any?) throws -> StrategyRuleCall {
        try SimRulesCodec.ruleCallFromJSON(any)
    }

    /// `StrategyRuleCall` 的键排序文本（`params` / 行号 / 原文全参与）。
    private func ruleDesc(_ c: StrategyRuleCall) -> String {
        jsonDesc(SimRulesCodec.ruleCallJSON(c))
    }

    private func specDesc(_ s: StrategyParamSpec) -> String {
        jsonDesc(SimRulesCodec.paramSpecJSON(s))
    }

    /// 任意 JSON 对象 → 键排序文本（字典顺序无关的比较）。
    private func jsonDesc(_ o: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "<encode-failed>" }
        return s
    }

    /// TRADE 段行：fixture 里既可能是字符串也可能是数组（与 `SimRulesBridge.tradeLines` 同义）。
    private func tradeLines(_ any: Any?) -> [String] {
        if let s = any as? String {
            return s.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
        }
        return (any as? [Any])?.map { ($0 as? String) ?? "" } ?? []
    }

    // MARK: - D 组装配 / 比较

    /// 与 `SimRulesBridge.runStrategyDrafts` 同法装配（RULES 段字符串 + TRADE 段 spec）。
    private func strategyDoc(_ rules: Any?, _ trade: Any?) -> FormulaDoc {
        FormulaDoc(id: "strategy", kind: .strategy, name: "策略",
                   pickBody: "", pickRef: nil,
                   rules: SimRulesCodec.str(rules) ?? "",
                   trade: SimRulesCodec.tradeSpecFromJSON(trade))
    }

    /// `StrategyCondDraft` 非 Equatable（含 `id` / `Date`），投影成「键排序的 JSON 文本」比较——
    /// 这样比较走的是**同一个编解码层**（`strategyDraftJSON`），能量出反解（`strategyDraftFromJSON`）
    /// 是否丢字段或错类型。
    private func desc(_ d: StrategyCondDraft) -> String {
        guard let o = try? SimRulesCodec.strategyDraftJSON(d),
              let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "<encode-failed>" }
        return s
    }

    private func skipDesc(_ s: StrategyGenSkip) -> String { "\(s.title)|\(s.reason)" }

    private func directive(_ any: Any?) -> SimCondDirective {
        let d = (any as? [String: Any]) ?? [:]
        return SimCondDirective(
            direction: SimRulesCodec.str(d["direction"])
                .flatMap(SimOrderDirection.init(rawValue:)) ?? .sell,
            priceType: SimRulesCodec.str(d["priceType"])
                .flatMap(SimPriceType.init(rawValue:)) ?? .market,
            offsetTicks: SimRulesCodec.int(d["offsetTicks"]) ?? 0,
            qty: SimRulesCodec.int(d["qty"]) ?? 0,
            alertOnly: SimRulesCodec.bool(d["alertOnly"]))
    }

    // MARK: - 用例（两种 mode）

    func testParitySwiftMode() async throws {
        try await runAllParity(.swift)
    }

    func testParityEngineMode() async throws {
        try await ensureEngineReady()
        try await runAllParity(.engine)
    }
}

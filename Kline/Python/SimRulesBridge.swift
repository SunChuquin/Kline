//
//  SimRulesBridge.swift
//  Kline
//
//  阶段 A4：交易判定「Swift ↔ 引擎」双跑门面（**过渡期**，见
//  .trae/documents/python-engine/Python引擎下沉可行性分析.md §11.7）。
//
//  角色：把一次「交易判定 op」的结果产出与后端选择收敛到一处——
//    · `.swift`  → 调本仓 Swift 现状（SimCondRule / SimTradingRules /
//                  StrategyCondGenerator / StrategyRuleParser / StrategyTradeParser /
//                  StrategyValidator / StrategyPreview / StrategyBacktestEngine），
//                  投影成与 sim_rules.py **同形状的 JSON**（含 `ok:true`）；
//    · `.engine` → 经 KlinePythonBridge 调 `sim_rules.py`，原样返回其 `kline_result`。
//  两种后端的输出形状一致，故可在同进程内逐字段对拍（A4 差分双跑）。
//
//  与 sim_rules.py 的对应（op 清单见 §11.3）：
//    sim_format / cond_evaluate / cond_validate_create / cond_grid_level_count / cond_text /
//    cond_expired_reason / cond_fire_direction / cond_execution_price / cond_advance /
//    cond_repeatable_finished / cond_alert_message / trade_calc / trade_validate /
//    strategy_drafts / strategy_entry_draft / strategy_parse / strategy_rule_line /
//    strategy_catalog / strategy_validate / strategy_preview / trade_parse /
//    trade_serialize / trade_override / backtest_run。
//
//  ⚠️ 本文件内的 JSON 投影逻辑**只服务于「双跑对拍」与「Swift 现状 dump」**：
//     它原本在 KlineTests/SimRulesContractTests.swift 内，A4 迁到此处成为门面的
//     `.swift` 后端（单一来源：dump 生产端与差分测试共用，避免两份漂移）。
//     A6 删 Swift 实现时，本文件的 `.swift` 分支随实现一并删除。
//
//  降级（§11.7）：`.engine` 模式下引擎未就绪 → `.failure(.engineNotReady)`，
//  调用方按 §9.10 走**显式降级**（不静默用 Swift 兜底，避免双语义）。
//

import Foundation

enum SimRulesBridge {

    // MARK: - 后端选择

    enum Mode {
        case swift
        case engine
    }

    /// 运行开关：默认 `.swift`（= 现状）；单测与 Debug 页可切 `.engine`。
    static var mode: Mode = .swift

    /// 调用失败分类。`.engineNotReady` 即 §11.7 的「返回 nil」语义（显式降级）。
    enum Failure: Error, CustomStringConvertible {
        case engineNotReady
        case unknownOp(String)
        case badOutput
        case callError(String)

        var description: String {
            switch self {
            case .engineNotReady: return "引擎未就绪"
            case .unknownOp(let op): return "未知 op：\(op)"
            case .badOutput: return "引擎输出非 JSON 对象"
            case .callError(let msg): return msg
            }
        }
    }

    // MARK: - 统一入口（按 mode 分发）

    /// 按 `mode` 跑一次 op：
    /// - `.swift`  → 同步跑 Swift 参考实现并回调（本就主线程，立即回调）；
    /// - `.engine` → 异步调 `sim_rules.py`（引擎未就绪 → `.engineNotReady`）。
    @MainActor
    static func payload(op: String, input: [String: Any], timeout: TimeInterval = 30,
                        completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        switch mode {
        case .swift:
            do {
                completion(.success(try swiftPayload(op: op, input: input)))
            } catch let f as Failure {
                completion(.failure(f))
            } catch {
                completion(.failure(.callError("Swift 参考实现异常：\(error)")))
            }
        case .engine:
            enginePayload(op: op, input: input, timeout: timeout, completion: completion)
        }
    }

    /// 引擎后端：调 `sim_rules.py`，原样返回 `kline_result`（含 `ok:true`）。
    /// 引擎未就绪 → `.engineNotReady`（**不触发** ensureReady / 不加载）。
    static func enginePayload(op: String, input: [String: Any], timeout: TimeInterval = 30,
                              completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        guard KlinePythonBridge.shared.isReady else {
            completion(.failure(.engineNotReady))
            return
        }
        var payload = input
        payload["op"] = op
        KlinePythonBridge.shared.call(script: "sim_rules", input: payload, timeout: timeout) { r in
            switch r {
            case .success(let data):
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(.badOutput))
                    return
                }
                completion(.success(obj))
            case .failure(let e):
                completion(.failure(.callError(String(describing: e))))
            }
        }
    }

    // MARK: - Swift 参考后端（投影为与引擎同形状的 JSON）

    /// 跑 Swift 现状并投影成 fixture/golden 形状（含 `ok:true`）。
    /// `@MainActor`：B 组若干 op 经 `SimStore.shared`（`@MainActor`）取值。
    @MainActor
    static func swiftPayload(op: String, input: [String: Any]) throws -> [String: Any] {
        var payload = try swiftBody(op: op, input: input)
        payload["ok"] = true
        return payload
    }

    @MainActor
    private static func swiftBody(op: String, input: [String: Any]) throws -> [String: Any] {
        switch op {
        // ---- A 组：条件单判定 ----
        case "sim_format":
            return try runSimFormat(input)
        case "cond_evaluate":
            let order = try decodeOrder(input["order"])
            return ["result": decisionJSON(SimCondRule.evaluate(order: order,
                                                                snapshot: snapshot(input["snapshot"])))]
        case "cond_validate_create":
            let order = try decodeOrder(input["order"])
            let rej = SimCondRule.validateCreate(order: order, account: account(input["account"]),
                                                 position: position(input["position"]),
                                                 snapshot: snapshot(input["snapshot"]),
                                                 now: isoDate(input["now"]) ?? Date())
            return ["result": rej.map { condRejectionJSON($0) } ?? NSNull()]
        case "cond_grid_level_count":
            return ["count": SimCondRule.gridLevelCount(order: try decodeOrder(input["order"]))]
        case "cond_text":
            let order = try decodeOrder(input["order"])
            let text: String
            switch str(input["field"]) ?? "condition" {
            case "directiveCore": text = SimCondRule.directiveCore(order)
            case "directive": text = SimCondRule.directiveSummary(order)
            case "validity": text = SimCondRule.validitySummary(order)
            case "preview": text = SimCondRule.previewSentence(order)
            default: text = SimCondRule.conditionSummary(order)
            }
            return ["text": text]
        // ---- B 组：结算纯推进 ----
        case "cond_expired_reason":
            let order = try decodeOrder(input["order"])
            let tz = int(input["tzOffsetSeconds"]) ?? 0
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: tz) ?? .current
            let now = isoDate(input["now"]) ?? Date()
            let reason = SimStore.shared.expiredReason(of: order, today: cal.startOfDay(for: now),
                                                       calendar: cal)
            return ["reason": reason ?? NSNull()]
        case "cond_fire_direction":
            let order = try decodeOrder(input["order"])
            let d = SimStore.shared.fireDirection(order: order,
                                                  triggerPrice: num(input["triggerPrice"]) ?? 0)
            return ["direction": d.rawValue]
        case "cond_execution_price":
            let d = try decodeDirective(input["directive"])
            let p = SimStore.shared.executionPrice(directive: d,
                                                   triggerPrice: num(input["triggerPrice"]) ?? 0)
            return ["price": p ?? NSNull()]
        case "cond_advance":
            let order = try decodeOrder(input["order"])
            let rt = SimStore.shared.advanceRepeatable(order: order,
                                                       triggerPrice: num(input["triggerPrice"]) ?? 0)
            return ["runtime": runtimeJSON(rt)]
        case "cond_repeatable_finished":
            return ["finished": SimStore.shared.repeatableFinished(order: try decodeOrder(input["order"]))]
        case "cond_alert_message":
            let order = try decodeOrder(input["order"])
            return ["message": SimStore.shared.alertMessage(order: order,
                                                            triggerPrice: num(input["triggerPrice"]) ?? 0)]
        // ---- C 组：交易规则 ----
        case "trade_calc":
            return try runTradeCalc(input)
        case "trade_validate":
            return try runTradeValidate(input)
        // ---- D 组：策略 → 条件单草稿 ----
        case "strategy_drafts":
            return try runStrategyDrafts(input)
        case "strategy_entry_draft":
            return try runStrategyEntryDraft(input)
        // ---- E 组：策略 DSL 纯解析 / 校验 / 预览 ----
        case "strategy_parse":
            let out = StrategyRuleParser.parse(lines: str(input["lines"]) ?? "")
            return ["rules": out.rules.map { ruleCallJSON($0) }, "errors": out.errors]
        case "strategy_rule_line":
            let c = (input["call"] as? [String: Any]) ?? [:]
            let kind = StrategyRuleKind(rawValue: str(c["kind"]) ?? "")!
            let params = (c["params"] as? [String: String]) ?? [:]
            return ["line": StrategyRuleParser.line(for: StrategyRuleCall(kind: kind, params: params,
                                                                         raw: "", line: 0))]
        case "strategy_catalog":
            var kinds = StrategyRuleKind.allCases
            if let want = str(input["kind"]), !want.isEmpty,
               let k = StrategyRuleKind(rawValue: want) { kinds = [k] }
            var catalog: [String: Any] = [:]
            for k in kinds {
                catalog[k.rawValue] = [
                    "title": k.title,
                    "conditionOrderTitle": k.conditionOrderTitle,
                    "simCondKind": Self.simKind(k).rawValue,
                    "specs": StrategyRuleCatalog.specs(for: k).map { specJSON($0) },
                    "knownKeys": StrategyRuleCatalog.knownKeys(for: k).sorted(),
                ]
            }
            return ["catalog": catalog]
        case "strategy_validate":
            let issues = StrategyValidator.validate(doc: formulaDoc(input["doc"]),
                                                    pickerExists: bool(input["pickerExists"]) ?? false,
                                                    pickSyntaxError: str(input["pickSyntaxError"]))
            return ["issues": issues]
        case "strategy_preview":
            let doc = formulaDoc(input["doc"])
            let pickerName = str(input["pickerName"])
            let (calls, _) = StrategyRuleParser.parse(lines: doc.rules)
            return ["summary": StrategyPreview.summary(doc: doc, pickerName: pickerName),
                    "pick": StrategyPreview.pickSummary(doc: doc, pickerName: pickerName),
                    "trade": StrategyPreview.tradeSummary(doc: doc),
                    "executionNotice": StrategyPreview.executionNotice,
                    "triggers": calls.map { StrategyPreview.triggerText($0) }]
        case "trade_parse":
            let out = StrategyTradeParser.parse(lines: tradeLines(input["lines"]))
            return ["spec": specToJSON(out.spec), "errors": out.errors]
        case "trade_serialize":
            return ["text": StrategyTradeParser.serialize(specFromJSON(input["spec"]))]
        case "trade_override":
            let c = (input["call"] as? [String: Any]) ?? [:]
            let kind = StrategyRuleKind(rawValue: str(c["kind"]) ?? "PRICE") ?? .price
            let params = (c["params"] as? [String: String]) ?? [:]
            let o = StrategyTradeParser.override(in: StrategyRuleCall(kind: kind, params: params,
                                                                      raw: "", line: 0))
            let overrideJSON: [String: Any] = ["dir": o.dir?.rawValue ?? NSNull(),
                                               "qty": o.qty ?? NSNull(),
                                               "amount": o.amount ?? NSNull(),
                                               "priceType": o.priceType?.rawValue ?? NSNull(),
                                               "offsetTicks": o.offsetTicks ?? NSNull()]
            return ["override": overrideJSON,
                    "isEmpty": o.isEmpty,
                    "summary": o.summary ?? NSNull()]
        // ---- F 组：历史回测 ----
        case "backtest_run":
            return try runBacktest(input)
        default:
            throw Failure.unknownOp(op)
        }
    }

    // MARK: - 基础转换（fixture JSON → Swift 模型）

    private static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
    private static func num(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber else { return nil }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        return n.doubleValue
    }
    private static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }
    private static func str(_ v: Any?) -> String? { v as? String }

    private static func uuid(_ v: Any?) -> UUID? { (v as? String).flatMap { UUID(uuidString: $0) } }

    private static func isoDate(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    private static func isoString(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from any: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: any)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(type, from: data)
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(value)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badOutput
        }
        return obj
    }

    private static func decodeOrder(_ any: Any?) throws -> SimCondOrder {
        // 逐项兜底解码（缺失键取默认），空对象也可
        try decode(SimCondOrder.self, from: any ?? [:] as [String: Any])
    }

    private static func decodeDirective(_ any: Any?) throws -> SimCondDirective {
        guard let any else { return SimCondDirective() }
        return try decode(SimCondDirective.self, from: any)
    }

    private static func snapshot(_ any: Any?) -> SimCondSnapshot {
        let d = (any as? [String: Any]) ?? [:]
        return SimCondSnapshot(last: num(d["last"]), prevClose: num(d["prevClose"]),
                               high: num(d["high"]), low: num(d["low"]),
                               changePct: num(d["changePct"]), ma: num(d["ma"]))
    }

    private static func account(_ any: Any?) -> SimAccount {
        let d = (any as? [String: Any]) ?? [:]
        return SimAccount(id: uuid(d["id"]) ?? UUID(),
                          name: str(d["name"]) ?? "账户", badge: "主", colorHex: "#1E5FA8",
                          initialCapital: num(d["initialCapital"]) ?? 1_000_000,
                          cash: num(d["cash"]) ?? 0,
                          createdAt: Date(timeIntervalSince1970: 0),
                          isArchived: bool(d["isArchived"]) ?? false)
    }

    private static func position(_ any: Any?) -> SimPosition? {
        guard let any, let d = any as? [String: Any] else { return nil }
        return SimPosition(id: UUID(), accountID: uuid(d["accountID"]) ?? UUID(),
                           metaID: int(d["metaID"]) ?? 0, code: str(d["code"]) ?? "",
                           name: str(d["name"]) ?? "",
                           qty: int(d["qty"]) ?? 0, availableQty: int(d["availableQty"]) ?? 0,
                           costPrice: num(d["costPrice"]) ?? 0,
                           openedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - 出参编码（严格对齐 sim_rules.py，见 §11.6）

    private static func runtimeJSON(_ r: SimCondRuntime) -> [String: Any] {
        var o: [String: Any] = ["batchDone": r.batchDone]
        if let v = r.extreme { o["extreme"] = v }
        if let v = r.lastPrice { o["lastPrice"] = v }
        if let v = r.gridLevel { o["gridLevel"] = v }
        if let v = r.gridLastPrice { o["gridLastPrice"] = v }
        if let v = r.lastEvaluatedAt { o["lastEvaluatedAt"] = isoString(v) }
        if let v = r.lastTriggerPrice { o["lastTriggerPrice"] = v }
        if !r.lastMessage.isEmpty { o["lastMessage"] = r.lastMessage }
        return o
    }

    private static func decisionJSON(_ d: SimCondDecision) -> [String: Any] {
        switch d {
        case .fire(let qty, let at): return ["decision": "fire", "qty": qty, "at": at]
        case .hold(let rt): return ["decision": "hold", "runtime": runtimeJSON(rt)]
        case .abort(let reason): return ["decision": "abort", "reason": reason]
        case .complete(let reason): return ["decision": "complete", "reason": reason]
        }
    }

    private static func condRejectionJSON(_ r: SimCondRejection) -> Any {
        switch r {
        case .accountUnavailable, .noQuote, .noPosition,
             .invalidOCORange, .invalidGridRange, .invalidGridStep,
             .invalidBatchCount, .invalidFireDate:
            return ["code": condRejectCode(r), "message": r.message]
        case .invalidQty(let lot):
            return ["code": "invalidQty", "lot": lot, "message": r.message]
        case .batchTooSmall(let lot):
            return ["code": "batchTooSmall", "lot": lot, "message": r.message]
        case .missingParam(let name):
            return ["code": "missingParam", "name": name, "message": r.message]
        }
    }

    private static func condRejectCode(_ r: SimCondRejection) -> String {
        switch r {
        case .accountUnavailable: return "accountUnavailable"
        case .noQuote: return "noQuote"
        case .invalidQty: return "invalidQty"
        case .noPosition: return "noPosition"
        case .missingParam: return "missingParam"
        case .invalidOCORange: return "invalidOCORange"
        case .invalidGridRange: return "invalidGridRange"
        case .invalidGridStep: return "invalidGridStep"
        case .invalidBatchCount: return "invalidBatchCount"
        case .batchTooSmall: return "batchTooSmall"
        case .invalidFireDate: return "invalidFireDate"
        }
    }

    private static func orderRejectionJSON(_ r: SimOrderRejection) -> Any {
        switch r {
        case .emptyAccount, .noQuote:
            return ["code": orderRejectCode(r), "message": r.message]
        case .notLotMultiple(let lot):
            return ["code": "notLotMultiple", "lot": lot, "message": r.message]
        case .insufficientCash(let available, let affordableQty):
            return ["code": "insufficientCash", "available": available,
                    "affordableQty": affordableQty, "message": r.message]
        case .insufficientShares(let available):
            return ["code": "insufficientShares", "available": available, "message": r.message]
        case .priceOutOfLimit(let lower, let upper):
            return ["code": "priceOutOfLimit", "lower": lower, "upper": upper, "message": r.message]
        }
    }

    private static func orderRejectCode(_ r: SimOrderRejection) -> String {
        switch r {
        case .emptyAccount: return "emptyAccount"
        case .notLotMultiple: return "notLotMultiple"
        case .insufficientCash: return "insufficientCash"
        case .insufficientShares: return "insufficientShares"
        case .priceOutOfLimit: return "priceOutOfLimit"
        case .noQuote: return "noQuote"
        }
    }

    // MARK: - sim_format / trade_calc / trade_validate

    private static func runSimFormat(_ input: [String: Any]) throws -> [String: Any] {
        let fn = str(input["fn"]) ?? ""
        if ["time", "dateTime", "shortDate"].contains(fn) {
            let d = isoDate(input["date"]) ?? Date()
            switch fn {
            case "time": return ["value": SimFormat.time(d)]
            case "dateTime": return ["value": SimFormat.dateTime(d)]
            default: return ["value": SimFormat.shortDate(d)]
            }
        }
        let v = num(input["value"]) ?? 0
        switch fn {
        case "amount": return ["value": SimFormat.amount(v)]
        case "amount0": return ["value": SimFormat.amount0(v)]
        case "signed": return ["value": SimFormat.signed(v)]
        case "signed0": return ["value": SimFormat.signed0(v)]
        case "pct": return ["value": SimFormat.pct(v)]
        case "shares": return ["value": SimFormat.shares(Int(v))]
        case "price": return ["value": SimFormat.price(v)]
        default:
            throw Failure.unknownOp("sim_format/\(fn)")
        }
    }

    private static func runTradeCalc(_ input: [String: Any]) throws -> [String: Any] {
        var rules = SimTradingRules.default
        if let t = bool(input["tPlus1Enabled"]) { rules.tPlus1Enabled = t }
        let calc = str(input["calc"]) ?? ""
        switch calc {
        case "commission": return ["value": rules.commission(amount: num(input["amount"]) ?? 0)]
        case "stampTax":
            return ["value": rules.stampTax(amount: num(input["amount"]) ?? 0,
                                            direction: SimOrderDirection(rawValue: str(input["direction"]) ?? "buy") ?? .buy)]
        case "fee":
            return ["value": rules.fee(amount: num(input["amount"]) ?? 0,
                                       direction: SimOrderDirection(rawValue: str(input["direction"]) ?? "buy") ?? .buy)]
        case "limitRange":
            if let r = rules.limitRange(prevClose: num(input["prevClose"])) {
                return ["range": ["lower": r.lowerBound, "upper": r.upperBound]]
            }
            return ["range": NSNull()]
        case "affordableQty":
            return ["value": rules.affordableQty(cash: num(input["cash"]) ?? 0, price: num(input["price"]) ?? 0)]
        case "sellableQty":
            return ["value": rules.sellableQty(position: position(input["position"]))]
        case "isTradingSession":
            return ["value": rules.isTradingSession(at: isoDate(input["at"]) ?? Date())]
        default:
            throw Failure.unknownOp("trade_calc/\(calc)")
        }
    }

    private static func runTradeValidate(_ input: [String: Any]) throws -> [String: Any] {
        let d = (input["draft"] as? [String: Any]) ?? [:]
        let draft = SimOrderDraft(accountID: uuid(d["accountID"]) ?? UUID(), metaID: 0, code: "", name: "",
                                  direction: SimOrderDirection(rawValue: str(d["direction"]) ?? "buy") ?? .buy,
                                  priceType: SimPriceType(rawValue: str(d["priceType"]) ?? "market") ?? .market,
                                  price: num(d["price"]), qty: int(d["qty"]) ?? 0)
        let rej = SimTradingRules.default.validate(draft: draft, account: account(input["account"]),
                                                   position: position(input["position"]),
                                                   lastPrice: num(input["lastPrice"]),
                                                   prevClose: num(input["prevClose"]))
        return ["result": rej.map { orderRejectionJSON($0) } ?? NSNull()]
    }

    // MARK: - 策略映射（D 组）

    private static func specFromJSON(_ any: Any?) -> StrategyTradeSpec {
        SimRulesCodec.tradeSpecFromJSON(any)
    }

    private static func formulaDoc(_ any: Any?) -> FormulaDoc {
        SimRulesCodec.formulaDocFromJSON(any)
    }

    private static func metaItem(_ any: Any?) -> MetaItem {
        SimRulesCodec.metaItemFromJSON(any)
    }

    private static func draftJSON(_ d: StrategyCondDraft) throws -> [String: Any] {
        var o: [String: Any] = [
            "accountID": d.accountID.uuidString,
            "metaID": d.metaID,
            "code": d.code,
            "name": d.name,
            "kind": d.kind.rawValue,
            "params": try jsonObject(d.params),
            "directive": ["direction": d.directive.direction.rawValue,
                          "priceType": d.directive.priceType.rawValue,
                          "offsetTicks": d.directive.offsetTicks,
                          "qty": d.directive.qty],
            "validity": d.validity.rawValue,
        ]
        if d.validity == .untilDate, let e = d.expiresAt { o["expiresAt"] = isoString(e) }
        return o
    }

    private static func runStrategyDrafts(_ input: [String: Any]) throws -> [String: Any] {
        let doc = FormulaDoc(id: "strategy", kind: .strategy, name: "策略",
                             pickBody: "", pickRef: nil,
                             rules: str(input["rules"]) ?? "",
                             trade: specFromJSON(input["trade"]))
        let meta = metaItem(input["meta"])
        let out = StrategyCondGenerator.drafts(doc: doc, meta: meta,
                                               accountID: uuid(input["accountID"]) ?? UUID(),
                                               lastPrice: num(input["lastPrice"]) ?? 0,
                                               costPrice: num(input["costPrice"]))
        return ["drafts": try out.drafts.map { try draftJSON($0) },
                "skips": out.skips.map { ["title": $0.title, "reason": $0.reason] }]
    }

    private static func runStrategyEntryDraft(_ input: [String: Any]) throws -> [String: Any] {
        let doc = FormulaDoc(id: "strategy", kind: .strategy, name: "策略",
                             pickBody: "", pickRef: nil, rules: "",
                             trade: specFromJSON(input["trade"]))
        let d = StrategyCondGenerator.entryDraft(doc: doc, meta: metaItem(input["meta"]),
                                                 accountID: uuid(input["accountID"]) ?? UUID(),
                                                 lastPrice: num(input["lastPrice"]) ?? 0)
        return ["draft": try d.map { try draftJSON($0) } ?? NSNull()]
    }

    // MARK: - E 组编码辅助

    private static func ruleCallJSON(_ c: StrategyRuleCall) -> [String: Any] {
        ["kind": c.kind.rawValue, "params": c.params, "raw": c.raw, "line": c.line]
    }

    private static func simKind(_ k: StrategyRuleKind) -> SimCondKind {
        switch k {
        case .price: return .price
        case .stopLoss: return .stopLoss
        case .trailing: return .trailing
        case .time: return .time
        case .changePct: return .changePct
        case .maCross: return .maCross
        case .grid: return .grid
        case .batch: return .batch
        }
    }

    private static func specJSON(_ s: StrategyParamSpec) -> [String: Any] {
        ["key": s.key, "title": s.title, "type": paramTypeName(s.type),
         "isOptional": s.isOptional, "placeholder": s.placeholder,
         "options": s.options, "unit": s.unit]
    }

    private static func paramTypeName(_ t: StrategyParamType) -> String {
        switch t {
        case .number: return "number"
        case .percent: return "percent"
        case .integer: return "integer"
        case .text: return "text"
        case .option: return "option"
        }
    }

    private static func specToJSON(_ s: StrategyTradeSpec) -> [String: Any] {
        SimRulesCodec.tradeSpecJSON(s)
    }

    private static func tradeLines(_ any: Any?) -> [String] {
        if let s = any as? String {
            return s.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
        }
        if let a = any as? [Any] { return a.map { ($0 as? String) ?? "" } }
        return []
    }

    // MARK: - F 组：回测

    private static func runBacktest(_ input: [String: Any]) throws -> [String: Any] {
        let m = SimRulesCodec.backtestInputDecode(input)
        let r = StrategyBacktestEngine.run(doc: m.doc, bars: m.bars, pickHits: m.pickHits,
                                           metas: m.metas, params: m.params, shouldCancel: nil)
        return SimRulesCodec.backtestJSON(r)
    }

    // MARK: - 生产入口（A5-4 回测子系统）

    /// 生产回测入口（**后台线程**）：按 `mode` 分派。
    /// - `.swift` → 现状 `StrategyBacktestEngine.run`；
    /// - `.engine` → `SimRulesCodec` 编码 + `blockingCall(sim_rules, "backtest_run")` + 反解；
    ///   引擎未就绪 → `.failure(.engineNotReady)`（调用方按 §9.10 显式降级，不静默用 Swift）。
    ///
    /// 取消语义：`.swift` 逐日检查 `shouldCancel`；`.engine` 是一次性阻塞调用，
    /// 取消只在返回后生效（调用方在回调里再查取消标志，与现状的「取出结果前再查一次」一致）。
    static func backtestRun(doc: FormulaDoc, bars: [Int: [KlineItem]], pickHits: [Int: Set<Int>],
                            metas: [Int: MetaItem], params: BacktestParams,
                            shouldCancel: (() -> Bool)?,
                            timeout: TimeInterval = 120) -> Result<BacktestResult, Failure> {
        switch mode {
        case .swift:
            return .success(StrategyBacktestEngine.run(doc: doc, bars: bars, pickHits: pickHits,
                                                       metas: metas, params: params,
                                                       shouldCancel: shouldCancel))
        case .engine:
            guard KlinePythonBridge.shared.isReady else { return .failure(.engineNotReady) }
            var input = SimRulesCodec.backtestInput(doc: doc, bars: bars, pickHits: pickHits,
                                                    metas: metas, params: params,
                                                    tzOffsetSeconds: TimeZone.current.secondsFromGMT())
            input["op"] = "backtest_run"
            switch KlinePythonBridge.shared.blockingCall(script: "sim_rules", input: input,
                                                         timeout: timeout) {
            case .success(let data):
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .failure(.badOutput)
                }
                do { return .success(try SimRulesCodec.backtestResult(from: obj, params: params)) }
                catch { return .failure(.badOutput) }
            case .failure(let e):
                return .failure(.callError(String(describing: e)))
            }
        }
    }

    private static func backtestJSON(_ r: BacktestResult) -> [String: Any] {
        SimRulesCodec.backtestJSON(r)
    }
}

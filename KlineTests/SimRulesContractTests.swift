//
//  SimRulesContractTests.swift
//  KlineTests
//
//  契约测试③（阶段 A1）：交易判定成对下沉的 Swift↔fixture 对拍。
//
//  最高权威说明（《Python引擎下沉可行性分析.md》§12）：
//    · fixture 的 input 手写 / 评审（由 scripts/gen_sim_rules_inputs.py 从 A0 用例抽出）；
//    · fixture 的 expected **只能由 Swift 现状 dump 写**，禁止手工编辑；
//    · 本文件是 expected 的唯一生产端：
//        KLINE_DUMP_SIM_RULES=1  → 跑 Swift 现状并把 expected 覆盖式打进 stdout（base64 分片），
//                                  由 scripts/extract_sim_rules_golden.py 落盘；
//        否则                    → 读 fixture 的 expected 逐字段断言（逐位精确）。
//
//  三个 fixture：
//    · sim_rules.json      —— simFormat / evaluate / validateCreate / gridLevelCount / text /
//                             sweep / tradingRules / mapping 八段（expected 由 dump 写）
//    · strategy_dsl.json   —— E 组解析类（expected 为手写规格，本文件只断言）
//    · backtest_golden.json —— F 组回测（expected 由 dump 写）
//
//  生成命令（见 §12.3；iOS 模拟器沙盒写不到仓库路径，故走 stdout）：
//    KLINE_DUMP_SIM_RULES=1 xcodebuild test -scheme Kline \
//      -destination 'platform=iOS Simulator,name=iPhone 11,OS=27.0' \
//      -only-testing:KlineTests/SimRulesContractTests 2>&1 \
//      | python3 scripts/extract_sim_rules_golden.py
//
//  ⚠️ 环境依赖：SimFormat 日期文案 / isTradingSession / 策略 fireDate 都走「本机时区」，
//     fixture 按 +08:00 生成（testEnvironmentTimeZoneIsPlus8 会显式校验）。
//

import XCTest
@testable import Kline

@MainActor
final class SimRulesContractTests: XCTestCase {

    private let dumpMode = ProcessInfo.processInfo.environment["KLINE_DUMP_SIM_RULES"] == "1"

    private static let acc1 = "11111111-1111-1111-1111-111111111111"
    private static let acc2 = "22222222-2222-2222-2222-222222222222"

    // MARK: - fixture 读取

    private func loadFixture(_ name: String) throws -> [String: Any] {
        let bundle = Bundle(for: Self.self)
        var url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        if url == nil { url = bundle.url(forResource: name, withExtension: "json") }
        guard let resolved = url else {
            XCTFail("fixture \(name).json 不在测试 bundle（已尝试 Fixtures/ 子目录与根目录）")
            throw NSError(domain: "KlineContractTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name).json"])
        }
        let data = try Data(contentsOf: resolved)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("fixture \(name).json 顶层不是 JSON object")
            throw NSError(domain: "KlineContractTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "bad fixture \(name).json"])
        }
        return root
    }

    // MARK: - 基础转换

    private func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
    private func num(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber else { return nil }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        return n.doubleValue
    }
    private func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }
    private func str(_ v: Any?) -> String? { v as? String }

    private func uuid(_ v: Any?) -> UUID? { (v as? String).flatMap { UUID(uuidString: $0) } }

    private func isoDate(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    private func isoString(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
    }

    private func decode<T: Decodable>(_ type: T.Type, from any: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: any)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(type, from: data)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(value)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "KlineContractTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "编码结果不是对象"])
        }
        return obj
    }

    private func decodeOrder(_ any: Any?) throws -> SimCondOrder {
        // 逐项兜底解码（缺失键取默认），空对象也可
        try decode(SimCondOrder.self, from: any ?? [:] as [String: Any])
    }

    private func decodeDirective(_ any: Any?) throws -> SimCondDirective {
        guard let any else { return SimCondDirective() }
        return try decode(SimCondDirective.self, from: any)
    }

    private func snapshot(_ any: Any?) -> SimCondSnapshot {
        let d = (any as? [String: Any]) ?? [:]
        return SimCondSnapshot(last: num(d["last"]), prevClose: num(d["prevClose"]),
                               high: num(d["high"]), low: num(d["low"]),
                               changePct: num(d["changePct"]), ma: num(d["ma"]))
    }

    private func account(_ any: Any?) -> SimAccount {
        let d = (any as? [String: Any]) ?? [:]
        return SimAccount(id: uuid(d["id"]) ?? UUID(),
                          name: str(d["name"]) ?? "账户", badge: "主", colorHex: "#1E5FA8",
                          initialCapital: num(d["initialCapital"]) ?? 1_000_000,
                          cash: num(d["cash"]) ?? 0,
                          createdAt: Date(timeIntervalSince1970: 0),
                          isArchived: bool(d["isArchived"]) ?? false)
    }

    private func position(_ any: Any?) -> SimPosition? {
        guard let any, let d = any as? [String: Any] else { return nil }
        return SimPosition(id: UUID(), accountID: uuid(d["accountID"]) ?? UUID(),
                           metaID: int(d["metaID"]) ?? 0, code: str(d["code"]) ?? "",
                           name: str(d["name"]) ?? "",
                           qty: int(d["qty"]) ?? 0, availableQty: int(d["availableQty"]) ?? 0,
                           costPrice: num(d["costPrice"]) ?? 0,
                           openedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - 出参编码（严格对齐 sim_rules.py，见 §11.6）

    private func runtimeJSON(_ r: SimCondRuntime) -> [String: Any] {
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

    private func decisionJSON(_ d: SimCondDecision) -> [String: Any] {
        switch d {
        case .fire(let qty, let at): return ["decision": "fire", "qty": qty, "at": at]
        case .hold(let rt): return ["decision": "hold", "runtime": runtimeJSON(rt)]
        case .abort(let reason): return ["decision": "abort", "reason": reason]
        case .complete(let reason): return ["decision": "complete", "reason": reason]
        }
    }

    private func condRejectionJSON(_ r: SimCondRejection) -> Any {
        switch r {
        case .accountUnavailable, .noQuote, .noPosition,
             .invalidOCORange, .invalidGridRange, .invalidGridStep,
             .invalidBatchCount, .invalidFireDate:
            return ["code": Self.condRejectCode(r), "message": r.message]
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

    private func orderRejectionJSON(_ r: SimOrderRejection) -> Any {
        switch r {
        case .emptyAccount, .noQuote:
            return ["code": Self.orderRejectCode(r), "message": r.message]
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

    // MARK: - 单 case 执行（sim_rules.json 八段）

    private func runSimRuleCase(_ op: String, _ input: [String: Any]) throws -> [String: Any] {
        switch op {
        case "sim_format":
            return try runSimFormat(input)
        case "cond_evaluate":
            let order = try decodeOrder(input["order"])
            let payload = decisionJSON(SimCondRule.evaluate(order: order, snapshot: snapshot(input["snapshot"])))
            return ["result": payload]
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
            let field = str(input["field"]) ?? "condition"
            let text: String
            switch field {
            case "directiveCore": text = SimCondRule.directiveCore(order)
            case "directive": text = SimCondRule.directiveSummary(order)
            case "validity": text = SimCondRule.validitySummary(order)
            case "preview": text = SimCondRule.previewSentence(order)
            default: text = SimCondRule.conditionSummary(order)
            }
            return ["text": text]
        case "cond_expired_reason":
            let order = try decodeOrder(input["order"])
            let tz = int(input["tzOffsetSeconds"]) ?? 0
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: tz) ?? .current
            let now = isoDate(input["now"]) ?? Date()
            let reason = SimStore.shared.expiredReason(of: order, today: cal.startOfDay(for: now), calendar: cal)
            return ["reason": reason ?? NSNull()]
        case "cond_fire_direction":
            let order = try decodeOrder(input["order"])
            let d = SimStore.shared.fireDirection(order: order, triggerPrice: num(input["triggerPrice"]) ?? 0)
            return ["direction": d.rawValue]
        case "cond_execution_price":
            let d = try decodeDirective(input["directive"])
            let p = SimStore.shared.executionPrice(directive: d, triggerPrice: num(input["triggerPrice"]) ?? 0)
            return ["price": p ?? NSNull()]
        case "cond_advance":
            let order = try decodeOrder(input["order"])
            let rt = SimStore.shared.advanceRepeatable(order: order, triggerPrice: num(input["triggerPrice"]) ?? 0)
            return ["runtime": runtimeJSON(rt)]
        case "cond_repeatable_finished":
            return ["finished": SimStore.shared.repeatableFinished(order: try decodeOrder(input["order"]))]
        case "cond_alert_message":
            let order = try decodeOrder(input["order"])
            return ["message": SimStore.shared.alertMessage(order: order,
                                                            triggerPrice: num(input["triggerPrice"]) ?? 0)]
        case "trade_calc":
            return try runTradeCalc(input)
        case "trade_validate":
            return try runTradeValidate(input)
        case "strategy_drafts":
            return try runStrategyDrafts(input)
        case "strategy_entry_draft":
            return try runStrategyEntryDraft(input)
        default:
            XCTFail("sim_rules.json 未知 op：\(op)")
            return ["error": "unknown op \(op)"]
        }
    }

    private func runSimFormat(_ input: [String: Any]) throws -> [String: Any] {
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
            XCTFail("sim_format 未知 fn：\(fn)")
            return ["value": ""]
        }
    }

    private func runTradeCalc(_ input: [String: Any]) throws -> [String: Any] {
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
            XCTFail("trade_calc 未知 calc：\(calc)")
            return ["value": 0]
        }
    }

    private func runTradeValidate(_ input: [String: Any]) throws -> [String: Any] {
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

    private func specFromJSON(_ any: Any?) -> StrategyTradeSpec {
        let d = (any as? [String: Any]) ?? [:]
        var s = StrategyTradeSpec()
        s.direction = (d["direction"] as? String).flatMap(SimOrderDirection.init(rawValue:))
        s.qty = int(d["qty"])
        s.amount = num(d["amount"])
        s.priceType = (d["priceType"] as? String).flatMap(SimPriceType.init(rawValue:))
        s.offsetTicks = int(d["offsetTicks"])
        s.validity = (d["validity"] as? String).flatMap(SimCondValidity.init(rawValue:))
        s.expiresAt = isoDate(d["expiresAt"])
        s.accountIDs = (d["accountIDs"] as? [String])?.compactMap { UUID(uuidString: $0) } ?? []
        return s
    }

    private func formulaDoc(_ any: Any?) -> FormulaDoc {
        let d = (any as? [String: Any]) ?? [:]
        let kind = (d["kind"] as? String).flatMap(FormulaKind.init(rawValue:)) ?? .strategy
        return FormulaDoc(id: "strategy", kind: kind,
                          name: str(d["name"]) ?? "策略",
                          pickBody: str(d["pickBody"]) ?? "",
                          pickRef: str(d["pickRef"]),
                          rules: str(d["rules"]) ?? "",
                          trade: specFromJSON(d["trade"]))
    }

    private func metaItem(_ any: Any?) -> MetaItem {
        let d = (any as? [String: Any]) ?? [:]
        return MetaItem(id: int(d["id"]) ?? 0, file: str(d["file"]) ?? "",
                        code: str(d["code"]) ?? "", name: str(d["name"]) ?? "标的",
                        type: str(d["type"]) ?? "股票", firstDate: nil, lastDate: nil)
    }

    private func draftJSON(_ d: StrategyCondDraft) throws -> [String: Any] {
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

    private func runStrategyDrafts(_ input: [String: Any]) throws -> [String: Any] {
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

    private func runStrategyEntryDraft(_ input: [String: Any]) throws -> [String: Any] {
        let doc = FormulaDoc(id: "strategy", kind: .strategy, name: "策略",
                             pickBody: "", pickRef: nil, rules: "",
                             trade: specFromJSON(input["trade"]))
        let d = StrategyCondGenerator.entryDraft(doc: doc, meta: metaItem(input["meta"]),
                                                 accountID: uuid(input["accountID"]) ?? UUID(),
                                                 lastPrice: num(input["lastPrice"]) ?? 0)
        return ["draft": try d.map { try draftJSON($0) } ?? NSNull()]
    }

    // MARK: - dump / 断言

    private func assertEqualJSON(_ expected: Any, _ actual: Any, _ path: String) -> [String] {
        if let e = expected as? [String: Any] {
            guard let a = actual as? [String: Any] else {
                return ["\(path)：期望对象，实得 \(actual)"]
            }
            var errs: [String] = []
            for k in e.keys {
                if let av = a[k] { errs += assertEqualJSON(e[k]!, av, "\(path).\(k)") }
                else { errs.append("\(path).\(k)：缺失") }
            }
            for k in a.keys where e[k] == nil { errs.append("\(path).\(k)：多余字段") }
            return errs
        }
        if let e = expected as? [Any] {
            guard let a = actual as? [Any] else { return ["\(path)：期望数组，实得 \(actual)"] }
            if e.count != a.count { return ["\(path)：长度 期望 \(e.count)，实得 \(a.count)"] }
            var errs: [String] = []
            for (i, pair) in zip(e, a).enumerated() { errs += assertEqualJSON(pair.0, pair.1, "\(path)[\(i)]") }
            return errs
        }
        if expected is NSNull || actual is NSNull {
            if !(expected is NSNull && actual is NSNull) { return ["\(path)：期望 \(expected)，实得 \(actual)"] }
            return []
        }
        if let e = expected as? NSNumber, let a = actual as? NSNumber,
           CFGetTypeID(e) != CFBooleanGetTypeID(), CFGetTypeID(a) != CFBooleanGetTypeID() {
            if abs(e.doubleValue - a.doubleValue) > 1e-9 * max(1.0, abs(e.doubleValue)) {
                return ["\(path)：期望 \(e)，实得 \(a)"]
            }
            return []
        }
        if let e = expected as? Bool, let a = actual as? Bool, e == a { return [] }
        if let e = expected as? String, let a = actual as? String, e == a { return [] }
        if String(describing: expected) == String(describing: actual) { return [] }
        return ["\(path)：期望 \(expected)，实得 \(actual)"]
    }

    private func processSection(fixtureName: String, section: String, cases: [[String: Any]],
                                assertMode: Bool) throws -> (cases: [[String: Any]], failed: Int) {
        var outCases: [[String: Any]] = []
        var failed = 0
        for c in cases {
            let name = str(c["caseName"]) ?? "?"
            let op = str(c["op"]) ?? "?"
            let input = (c["input"] as? [String: Any]) ?? [:]
            var payload = try runSimRuleCase(op, input)
            payload["ok"] = true
            if assertMode {
                let expected = c["expected"]!   // 调用方保证齐备
                let errs = assertEqualJSON(expected, payload, "\(fixtureName).\(section).\(name)")
                if !errs.isEmpty {
                    failed += 1
                    for e in errs { XCTFail("❌ \(e)") }
                }
            }
            outCases.append(["caseName": name, "op": op, "input": input, "expected": payload])
        }
        return (outCases, failed)
    }

    private func allCasesHaveExpected(_ fixture: [String: Any], sections: [String]) -> Bool {
        for s in sections {
            guard let cases = fixture[s] as? [[String: Any]] else { return false }
            for c in cases where c["expected"] == nil { return false }
        }
        return true
    }

    // MARK: - 主测试：sim_rules.json

    func testSimRulesContract() throws {
        let fixture = try loadFixture("sim_rules")
        let sections = ["simFormat", "evaluate", "validateCreate", "gridLevelCount",
                        "text", "sweep", "tradingRules", "mapping"]
        let complete = allCasesHaveExpected(fixture, sections: sections)
        // dump 模式：显式环境变量（TEST_RUNNER_KLINE_DUMP_SIM_RULES=1 传入）或首次引导（fixture 尚无 expected）
        let shouldEmit = dumpMode || !complete
        var golden: [String: Any] = ["_header": fixture["_header"] ?? [:] as [String: Any]]
        for s in sections {
            guard let cases = fixture[s] as? [[String: Any]] else { XCTFail("sim_rules.json 缺段 \(s)"); continue }
            let r = try processSection(fixtureName: "sim_rules.json", section: s, cases: cases,
                                       assertMode: complete && !dumpMode)
            golden[s] = r.cases
        }
        if shouldEmit { try emit(sentinel: "KLINE_SIM_RULES_GOLDEN_B64", object: golden) }
    }

    // MARK: - 主测试：strategy_dsl.json（手写规格，只断言）

    func testStrategyDSLContract() throws {
        let fixture = try loadFixture("strategy_dsl")
        let sections = ["strategyParse", "strategyRuleLine", "strategyCatalog", "strategyValidate",
                        "strategyPreview", "tradeParse", "tradeSerialize", "tradeOverride"]
        for s in sections {
            guard let cases = fixture[s] as? [[String: Any]] else { continue }
            for c in cases {
                let name = str(c["caseName"]) ?? "?"
                let op = str(c["op"]) ?? "?"
                let input = (c["input"] as? [String: Any]) ?? [:]
                var payload = try runDSLCase(op, input)
                payload["ok"] = true
                if let expected = c["expected"] {
                    for e in assertEqualJSON(expected, payload, "strategy_dsl.json.\(s).\(name)") {
                        XCTFail("❌ \(e)")
                    }
                } else {
                    XCTFail("strategy_dsl.json.\(s).\(name)：缺 expected（手写规格）")
                }
            }
        }
    }

    // MARK: - 主测试：backtest_golden.json

    func testBacktestGolden() throws {
        let fixture = try loadFixture("backtest_golden")
        guard let cases = fixture["cases"] as? [[String: Any]] else {
            XCTFail("backtest_golden.json 缺 cases"); return
        }
        let complete = cases.allSatisfy { $0["expected"] != nil }
        let shouldEmit = dumpMode || !complete
        var outCases: [[String: Any]] = []
        for c in cases {
            let name = str(c["caseName"]) ?? "?"
            let input = (c["input"] as? [String: Any]) ?? [:]
            var payload = try runBacktest(input)
            payload["ok"] = true
            if complete, !dumpMode, let expected = c["expected"] {
                for e in assertEqualJSON(expected, payload, "backtest_golden.json.\(name)") {
                    XCTFail("❌ \(e)")
                }
            }
            outCases.append(["caseName": name, "op": "backtest_run", "input": input, "expected": payload])
        }
        if shouldEmit {
            try emit(sentinel: "KLINE_BACKTEST_GOLDEN_B64",
                     object: ["_header": fixture["_header"] ?? [:] as [String: Any], "cases": outCases])
        }
    }

    // MARK: - E 组执行

    private func runDSLCase(_ op: String, _ input: [String: Any]) throws -> [String: Any] {
        switch op {
        case "strategy_parse":
            let out = StrategyRuleParser.parse(lines: str(input["lines"]) ?? "")
            return ["rules": out.rules.map { ruleCallJSON($0) }, "errors": out.errors]
        case "strategy_rule_line":
            let c = (input["call"] as? [String: Any]) ?? [:]
            let kind = StrategyRuleKind(rawValue: str(c["kind"]) ?? "")!
            let params = (c["params"] as? [String: String]) ?? [:]
            return ["line": StrategyRuleParser.line(for: StrategyRuleCall(kind: kind, params: params, raw: "", line: 0))]
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
            let o = StrategyTradeParser.override(in: StrategyRuleCall(kind: kind, params: params, raw: "", line: 0))
            let overrideJSON: [String: Any] = ["dir": o.dir?.rawValue ?? NSNull(),
                                               "qty": o.qty ?? NSNull(),
                                               "amount": o.amount ?? NSNull(),
                                               "priceType": o.priceType?.rawValue ?? NSNull(),
                                               "offsetTicks": o.offsetTicks ?? NSNull()]
            return ["override": overrideJSON,
                    "isEmpty": o.isEmpty,
                    "summary": o.summary ?? NSNull()]
        default:
            XCTFail("strategy_dsl.json 未知 op：\(op)")
            return ["error": "unknown op \(op)"]
        }
    }

    private func ruleCallJSON(_ c: StrategyRuleCall) -> [String: Any] {
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

    private func specJSON(_ s: StrategyParamSpec) -> [String: Any] {
        ["key": s.key, "title": s.title, "type": Self.paramTypeName(s.type),
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

    private func specToJSON(_ s: StrategyTradeSpec) -> [String: Any] {
        ["direction": s.direction?.rawValue ?? NSNull(),
         "qty": s.qty ?? NSNull(),
         "amount": s.amount ?? NSNull(),
         "priceType": s.priceType?.rawValue ?? NSNull(),
         "offsetTicks": s.offsetTicks ?? NSNull(),
         "validity": s.validity?.rawValue ?? NSNull(),
         "expiresAt": s.expiresAt.map { isoString($0) } ?? NSNull(),
         "accountIDs": s.accountIDs.map { $0.uuidString }]
    }

    private func tradeLines(_ any: Any?) -> [String] {
        if let s = any as? String {
            return s.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
        }
        if let a = any as? [Any] { return a.map { ($0 as? String) ?? "" } }
        return []
    }

    // MARK: - F 组：回测

    private func runBacktest(_ input: [String: Any]) throws -> [String: Any] {
        let doc = formulaDoc(input["doc"])
        var bars: [Int: [KlineItem]] = [:]
        for (k, v) in (input["bars"] as? [String: Any]) ?? [:] {
            guard let mid = Int(k), let arr = v as? [[String: Any]] else { continue }
            bars[mid] = arr.map { b in
                KlineItem(date: int(b["date"]) ?? 0, open: num(b["open"]) ?? 0, high: num(b["high"]) ?? 0,
                          low: num(b["low"]) ?? 0, close: num(b["close"]) ?? 0, volume: 0, turnover: 0)
            }
        }
        var hits: [Int: Set<Int>] = [:]
        for (k, v) in (input["pickHits"] as? [String: Any]) ?? [:] {
            guard let mid = Int(k), let arr = v as? [Any] else { continue }
            hits[mid] = Set(arr.compactMap { int($0) })
        }
        var metas: [Int: MetaItem] = [:]
        for (k, v) in (input["metas"] as? [String: Any]) ?? [:] {
            guard let mid = Int(k), let d = v as? [String: Any] else { continue }
            metas[mid] = MetaItem(id: mid, file: "", code: str(d["code"]) ?? "",
                                  name: str(d["name"]) ?? "", type: "股票",
                                  firstDate: nil, lastDate: nil)
        }
        let pin = (input["params"] as? [String: Any]) ?? [:]
        var params = BacktestParams()
        params.days = int(pin["days"]) ?? 250
        params.initialCapital = num(pin["initialCapital"]) ?? 100_000
        params.executeNextOpen = bool(pin["executeNextOpen"]) ?? true
        params.includeEntry = bool(pin["includeEntry"]) ?? true

        let r = StrategyBacktestEngine.run(doc: doc, bars: bars, pickHits: hits,
                                           metas: metas, params: params, shouldCancel: nil)
        return backtestJSON(r)
    }

    private func backtestJSON(_ r: BacktestResult) -> [String: Any] {
        var o: [String: Any] = [:]
        o["stats"] = ["initialCapital": r.stats.initialCapital, "finalEquity": r.stats.finalEquity,
                      "totalReturn": r.stats.totalReturn, "annualized": r.stats.annualized,
                      "winRate": r.stats.winRate, "profitFactor": r.stats.profitFactor,
                      "maxDrawdown": r.stats.maxDrawdown, "tradeCount": r.stats.tradeCount,
                      "roundTrips": r.stats.roundTrips, "avgHoldDays": r.stats.avgHoldDays]
        o["equity"] = r.equity.map { ["date": $0.date, "equity": $0.equity] }
        if let rg = r.maxDrawdownRange { o["maxDrawdownRange"] = [rg.lowerBound, rg.upperBound] }
        else { o["maxDrawdownRange"] = NSNull() }
        o["trades"] = r.trades.map { t -> [String: Any] in
            ["signalDate": t.signalDate, "date": t.date, "metaID": t.metaID, "code": t.code,
             "name": t.name, "ruleKind": t.ruleKind?.rawValue ?? NSNull(),
             "direction": t.direction.rawValue, "qty": t.qty, "price": t.price,
             "amount": t.amount, "fee": t.fee,
             "realizedPnL": t.realizedPnL ?? NSNull(), "holdDays": t.holdDays ?? NSNull()]
        }
        o["scannedCount"] = r.scannedCount
        o["hitCount"] = r.hitCount
        o["warnings"] = r.warnings
        o["skipped"] = r.skipped
        o["params"] = ["days": r.params.days, "initialCapital": r.params.initialCapital,
                       "executeNextOpen": r.params.executeNextOpen, "includeEntry": r.params.includeEntry]
        return o
    }

    // MARK: - dump 输出（base64 分片）

    private func emit(sentinel: String, object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        let b64 = data.base64EncodedString()
        let bytes = Array(b64.utf8)
        print("\(sentinel)_BEGIN")
        var i = 0
        var idx = 0
        while i < bytes.count {
            let end = min(i + 1000, bytes.count)
            let piece = String(decoding: bytes[i..<end], as: UTF8.self)
            print("\(sentinel):\(idx):\(piece)")
            i = end; idx += 1
        }
        print("\(sentinel)_END")
    }

    // MARK: - 环境校验

    func testEnvironmentTimeZoneIsPlus8() {
        let off = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(off, 28800,
            "sim_rules / backtest fixture 依赖 +08:00 本机时区"
            + "（SimFormat 日期文案、isTradingSession、策略 fireDate 都走本机时区）；"
            + "请把模拟器/主机时区设为 Asia/Shanghai 再跑本套件。当前偏移 \(off) 秒")
    }
}

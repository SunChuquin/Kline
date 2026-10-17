//
//  StrategyProjectionTests.swift
//  KlineTests
//
//  阶段 E-4：策略编辑器「引擎投影层」`StrategyProjection` 契约测试。
//
//  覆盖：
//    ① `.swift` 模式 = 完全直通 Swift 现状（零行为变化，且**不产生**任何缓存 / 请求）；
//    ② `.engine` 模式冷缓存 → 先给显式空态（nil / 空），`request*` + 防抖冲一次后 = 引擎值；
//    ③ 两种 mode 下与 Swift 现状逐条相等（`strategy_dsl.json` 的 catalog / ruleLine / validate /
//       preview 段既有入参全量跑一遍）；
//    ④ 同内容重复请求被去重（不重复打引擎）。
//
//  用例来源：`KlineTests/Fixtures/strategy_dsl.json` 既有入参（**不新增 golden、不改 fixture**）。
//

import XCTest
@testable import Kline

@MainActor
final class StrategyProjectionTests: XCTestCase {

    private var proj: StrategyProjection { StrategyProjection.shared }

    // MARK: - fixture 读取

    private func loadFixture(_ name: String) throws -> [String: Any] {
        let bundle = Bundle(for: type(of: self))
        var url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        if url == nil { url = bundle.url(forResource: name, withExtension: "json") }
        guard let resolved = url,
              let data = try? Data(contentsOf: resolved),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "StrategyProjectionTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bad fixture \(name).json"])
        }
        return root
    }

    private func cases(_ fixture: [String: Any], _ segment: String) -> [[String: Any]] {
        (fixture[segment] as? [[String: Any]]) ?? []
    }

    private func input(_ c: [String: Any]) -> [String: Any] { (c["input"] as? [String: Any]) ?? [:] }
    private func name(_ c: [String: Any]) -> String { (c["caseName"] as? String) ?? "?" }

    // MARK: - 比较辅助

    private func jsonDesc(_ o: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "<encode-failed>" }
        return s
    }

    private func specDesc(_ s: StrategyParamSpec) -> String { jsonDesc(SimRulesCodec.paramSpecJSON(s)) }

    private func doc(rules: String, pickBody: String = "C>1", pickRef: String? = nil,
                     trade: StrategyTradeSpec = StrategyTradeSpec()) -> FormulaDoc {
        FormulaDoc(id: "strategy", kind: .strategy, name: "策略", pickBody: pickBody,
                   pickRef: pickRef, rules: rules, trade: trade)
    }

    // MARK: - 引擎就绪（无内嵌引擎的构建 → skip，验证降级路径而非失败）

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

    // MARK: - ① `.swift` 模式零开销直通

    func testSwiftModeDirectPassThroughLeavesCacheEmpty() async throws {
        let saved = SimRulesBridge.mode
        defer { SimRulesBridge.mode = saved }
        // 先排干上一批在途请求，再清空
        await proj.flushAndWait()
        proj.reset()
        SimRulesBridge.mode = .swift

        let kind = StrategyRuleKind.grid
        let params = ["BASE": "14.60", "LOW": "13.50", "HIGH": "15.80", "STEP": "1.5", "QTY": "300"]
        let call = StrategyRuleCall(kind: kind, params: params, raw: "")
        let d = doc(rules: "PRICE(OP=>=, VALUE=1)")

        // `.swift` 模式：request* 应直接 return（零入队）
        proj.requestCatalog()
        proj.requestRules([call])
        proj.requestParse(rules: d.rules)
        proj.requestValidate(doc: d, pickerExists: false, pickSyntaxError: nil)
        proj.requestPreview(doc: d, pickerName: nil)

        XCTAssertEqual(proj.specs(for: kind).map(specDesc),
                       StrategyRuleCatalog.specs(for: kind).map(specDesc))
        XCTAssertEqual(proj.ruleLine(kind: kind, params: params),
                       StrategyRuleParser.line(for: call))
        XCTAssertEqual(proj.overrideSummary(kind: kind, params: params)?.isEmpty,
                       StrategyTradeParser.override(in: call).isEmpty)
        XCTAssertEqual(proj.parse(rules: d.rules)?.errors,
                       StrategyRuleParser.parse(lines: d.rules).errors)
        XCTAssertEqual(proj.issues(doc: d, pickerExists: false, pickSyntaxError: nil),
                       StrategyValidator.validate(doc: d, pickerExists: false, pickSyntaxError: nil))
        let pv = proj.preview(doc: d, pickerName: nil)
        XCTAssertEqual(pv?.summary, StrategyPreview.summary(doc: d, pickerName: nil))
        XCTAssertEqual(pv?.pick, StrategyPreview.pickSummary(doc: d, pickerName: nil))
        XCTAssertEqual(pv?.trade, StrategyPreview.tradeSummary(doc: d))
        XCTAssertEqual(pv?.executionNotice, StrategyPreview.executionNotice)
        XCTAssertEqual(pv?.triggers ?? [],
                       StrategyRuleParser.parse(lines: d.rules).rules.map { StrategyPreview.triggerText($0) })

        XCTAssertTrue(proj.availability.isEmpty, "`.swift` 模式不得产生引擎请求")
        XCTAssertTrue(proj.catalog.isEmpty)
        XCTAssertTrue(proj.ruleLines.isEmpty)
        XCTAssertTrue(proj.overrideSummaries.isEmpty)
        XCTAssertTrue(proj.parses.isEmpty)
        XCTAssertTrue(proj.validations.isEmpty)
        XCTAssertTrue(proj.previews.isEmpty)
    }

    // MARK: - ② `.engine` 冷缓存：先显式空态，再给引擎值

    func testEngineModeColdCacheGivesNilThenEngineValue() async throws {
        try await ensureEngineReady()
        let saved = SimRulesBridge.mode
        defer { SimRulesBridge.mode = saved }
        await proj.flushAndWait()
        proj.reset()
        SimRulesBridge.mode = .engine

        let kind = StrategyRuleKind.price
        let params = ["OP": ">=", "VALUE": "1480"]
        let call = StrategyRuleCall(kind: kind, params: params, raw: "")
        let d = doc(rules: "PRICE(OP=>=, VALUE=1480)")

        XCTAssertTrue(proj.specs(for: kind).isEmpty, "冷缓存目录 → 空（视图占位）")
        XCTAssertNil(proj.ruleLine(kind: kind, params: params),
                     "冷缓存必须给 nil，不得用 Swift 现状值兜底（§9.10）")
        XCTAssertNil(proj.overrideSummary(kind: kind, params: params))
        XCTAssertNil(proj.issues(doc: d, pickerExists: false, pickSyntaxError: nil))
        XCTAssertNil(proj.preview(doc: d, pickerName: nil))

        proj.requestCatalog()
        proj.requestRules([call])
        proj.requestValidate(doc: d, pickerExists: false, pickSyntaxError: nil)
        proj.requestPreview(doc: d, pickerName: nil)
        await proj.flushAndWait()

        XCTAssertEqual(proj.specs(for: kind).map(specDesc),
                       StrategyRuleCatalog.specs(for: kind).map(specDesc),
                       "防抖冲一次后应拿到引擎目录")
        XCTAssertEqual(proj.ruleLine(kind: kind, params: params),
                       StrategyRuleParser.line(for: call))
        XCTAssertEqual(proj.overrideSummary(kind: kind, params: params)?.isEmpty,
                       StrategyTradeParser.override(in: call).isEmpty)
        XCTAssertEqual(proj.issues(doc: d, pickerExists: false, pickSyntaxError: nil),
                       StrategyValidator.validate(doc: d, pickerExists: false, pickSyntaxError: nil))
        XCTAssertEqual(proj.preview(doc: d, pickerName: nil)?.trade, StrategyPreview.tradeSummary(doc: d))
    }

    // MARK: - ③ `.engine` 与 Swift 现状逐条相等（fixture 全量）

    func testEngineModeMatchesSwiftOnFixture() async throws {
        try await ensureEngineReady()
        let saved = SimRulesBridge.mode
        defer { SimRulesBridge.mode = saved }
        await proj.flushAndWait()
        proj.reset()
        SimRulesBridge.mode = .engine

        let dsl = try loadFixture("strategy_dsl")

        // 目录：一次取全 8 类，逐类比对 specs / knownKeys
        proj.requestCatalog()
        await proj.flushAndWait()
        for kind in StrategyRuleKind.allCases {
            XCTAssertEqual(proj.specs(for: kind).map(specDesc),
                           StrategyRuleCatalog.specs(for: kind).map(specDesc),
                           "engine catalog.specs \(kind.rawValue)")
            XCTAssertEqual(proj.catalog[kind]?.knownKeys.sorted(),
                           StrategyRuleCatalog.knownKeys(for: kind).sorted(),
                           "engine catalog.knownKeys \(kind.rawValue)")
        }

        // 规则行（含 ORD* 保留键）
        for c in cases(dsl, "strategyRuleLine") {
            guard let call = try? SimRulesCodec.ruleCallFromJSON(input(c)["call"]) else { continue }
            proj.requestRules([call])
            await proj.flushAndWait()
            XCTAssertEqual(proj.ruleLine(kind: call.kind, params: call.params),
                           StrategyRuleParser.line(for: call), "engine ruleLine \(name(c))")
            XCTAssertEqual(proj.overrideSummary(kind: call.kind, params: call.params)?.isEmpty,
                           StrategyTradeParser.override(in: call).isEmpty,
                           "engine override.isEmpty \(name(c))")
        }

        // 静态校验
        for c in cases(dsl, "strategyValidate") {
            let i = input(c)
            let d = SimRulesCodec.formulaDocFromJSON(i["doc"])
            let exists = SimRulesCodec.bool(i["pickerExists"]) ?? false
            let syntax = SimRulesCodec.str(i["pickSyntaxError"])
            proj.requestValidate(doc: d, pickerExists: exists, pickSyntaxError: syntax)
            await proj.flushAndWait()
            XCTAssertEqual(proj.issues(doc: d, pickerExists: exists, pickSyntaxError: syntax),
                           StrategyValidator.validate(doc: d, pickerExists: exists,
                                                      pickSyntaxError: syntax),
                           "engine validate \(name(c))")
        }

        // 语义预览（全 5 字段）
        for c in cases(dsl, "strategyPreview") {
            let i = input(c)
            let d = SimRulesCodec.formulaDocFromJSON(i["doc"])
            let pickerName = SimRulesCodec.str(i["pickerName"])
            proj.requestPreview(doc: d, pickerName: pickerName)
            await proj.flushAndWait()
            let got = proj.preview(doc: d, pickerName: pickerName)
            XCTAssertEqual(got?.summary, StrategyPreview.summary(doc: d, pickerName: pickerName),
                           "engine preview.summary \(name(c))")
            XCTAssertEqual(got?.pick, StrategyPreview.pickSummary(doc: d, pickerName: pickerName),
                           "engine preview.pick \(name(c))")
            XCTAssertEqual(got?.trade, StrategyPreview.tradeSummary(doc: d),
                           "engine preview.trade \(name(c))")
            XCTAssertEqual(got?.executionNotice, StrategyPreview.executionNotice,
                           "engine preview.executionNotice \(name(c))")
            XCTAssertEqual(got?.triggers ?? [],
                           StrategyRuleParser.parse(lines: d.rules).rules
                               .map { StrategyPreview.triggerText($0) },
                           "engine preview.triggers \(name(c))")
        }
    }

    // MARK: - ④ 同内容重复请求去重

    func testRepeatRequestIsDeduped() async throws {
        try await ensureEngineReady()
        let saved = SimRulesBridge.mode
        defer { SimRulesBridge.mode = saved }
        await proj.flushAndWait()
        proj.reset()
        SimRulesBridge.mode = .engine

        let call = StrategyRuleCall(kind: .price, params: ["OP": ">=", "VALUE": "1480"], raw: "")
        proj.requestRules([call])
        await proj.flushAndWait()
        let afterFirst = proj.availability
        XCTAssertFalse(afterFirst.isEmpty, "首轮请求应有投影键")
        XCTAssertTrue(afterFirst.values.allSatisfy { $0 == .ready }, "首轮请求应全部就绪")

        // 同一内容再请求：应被 requestedSig 去重（键集与可用性都不变）
        proj.requestRules([call])
        await proj.flushAndWait()
        XCTAssertEqual(proj.availability, afterFirst, "同内容重复请求应被去重")
        XCTAssertEqual(proj.ruleLine(kind: call.kind, params: call.params),
                       StrategyRuleParser.line(for: call))
    }

    // MARK: - 占位文案

    func testPlaceholderText() {
        XCTAssertEqual(StrategyProjection.placeholderText, "…")
    }
}

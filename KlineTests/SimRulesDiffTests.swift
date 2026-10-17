//
//  SimRulesDiffTests.swift
//  KlineTests
//
//  契约测试③（阶段 A4）：交易判定「Swift ↔ 引擎」**同用例同进程差分双跑**。
//
//  与 A1（`SimRulesContractTests`：Swift↔golden）和 A3（`PyBridgeSimRulesTests`：
//  Python↔golden）不同，本套件**不读 fixture 的 expected**——它直接让两侧各自
//  产出同一 case 的结果，再逐字段对拍。这样即使 fixture 被两边同时改错（理论
//  上的「同源漂移」）也拦得住，且是 A5 切换后端前的活体守卫。
//
//  两侧入口：
//    · Swift 现状 → `SimRulesBridge.swiftPayload(op:input:)`（门面的 `.swift` 后端）
//    · 引擎      → `SimRulesBridge.enginePayload(op:input:)`（门面的 `.engine` 后端）
//  两者输出形状一致（含 `ok:true`），故可直接 `SimRulesJSONCompare` 比较。
//
//  skip 语义：引擎未就绪 → `ensureEngineReady` 抛 XCTSkip（降级路径）；引擎就绪后
//  任一侧失败/不一致 = 真实缺陷 → 真 fail。
//
//  另含 `testModeDispatch`：校验 `SimRulesBridge.mode` 的 `.swift` / `.engine` 分发
//  与两侧后端各自等价（`.engineNotReady` 的「返回 nil → 显式降级」语义只能在无引擎
//  构建里触发，见 §11.7 / §9.10，此处不构造）。
//

import XCTest
@testable import Kline

@MainActor
final class SimRulesDiffTests: XCTestCase {

    /// 与 SimRulesContractTests / PyBridgeSimRulesTests 同分段（不含 expected 依赖）。
    private let fixtures: [(name: String, sections: [String])] = [
        ("sim_rules", ["simFormat", "evaluate", "validateCreate", "gridLevelCount",
                       "text", "sweep", "tradingRules", "mapping"]),
        ("strategy_dsl", ["strategyParse", "strategyRuleLine", "strategyCatalog", "strategyValidate",
                          "strategyPreview", "tradeParse", "tradeSerialize", "tradeOverride"]),
        ("backtest_golden", ["cases"]),
    ]

    // MARK: - fixture 读取

    private func loadFixture(_ name: String) throws -> [String: Any] {
        let bundle = Bundle(for: Self.self)
        var url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        if url == nil { url = bundle.url(forResource: name, withExtension: "json") }
        guard let resolved = url else {
            XCTFail("fixture \(name).json 不在测试 bundle（已尝试 Fixtures/ 子目录与根目录）")
            throw NSError(domain: "KlinePyBridgeTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name).json"])
        }
        let data = try Data(contentsOf: resolved)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("fixture \(name).json 顶层不是 JSON object")
            throw NSError(domain: "KlinePyBridgeTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "bad fixture \(name).json"])
        }
        return root
    }

    private func str(_ v: Any?) -> String? { v as? String }

    // MARK: - 引擎就绪（异步 + expectation；引擎不可用 → XCTSkip）

    private func ensureEngineReady() throws {
        if KlinePythonBridge.shared.isReady { return }
        let exp = expectation(description: "KlinePythonBridge.ensureReady")
        var failureMsg: String?
        KlinePythonBridge.shared.ensureReady { result in
            switch result {
            case .success: break
            case .failure(let msg): failureMsg = msg
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 60)
        if let msg = failureMsg {
            throw XCTSkip("Python 引擎未就绪：\(msg)"
                + "——无引擎构建（KLINE_SKIP_ENGINE_EMBED=1 或无 EngineCache）验证降级路径而非失败")
        }
    }

    // MARK: - 引擎侧（异步 → 同步等待）

    private func enginePayload(op: String, input: [String: Any]) throws -> [String: Any] {
        let exp = expectation(description: "SimRulesBridge.enginePayload op=\(op)")
        var boxed: Result<[String: Any], SimRulesBridge.Failure>?
        SimRulesBridge.enginePayload(op: op, input: input, timeout: 30) { r in
            boxed = r
            exp.fulfill()
        }
        wait(for: [exp], timeout: 35)
        guard let result = boxed else {
            throw NSError(domain: "KlinePyBridgeTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "enginePayload op=\(op) 未在超时前回调"])
        }
        switch result {
        case .success(let obj): return obj
        case .failure(let f):
            XCTFail("enginePayload op=\(op) 失败：\(f)")
            throw NSError(domain: "KlinePyBridgeTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "enginePayload failed: \(f)"])
        }
    }

    // MARK: - ① 同用例集双跑：Swift 现状 vs 引擎

    func testSwiftVsEngineSameCaseSet() throws {
        try ensureEngineReady()
        var total = 0
        for (name, sections) in fixtures {
            let fixture = try loadFixture(name)
            for s in sections {
                guard let cases = fixture[s] as? [[String: Any]] else {
                    XCTFail("\(name).json 缺段 \(s)")
                    continue
                }
                for c in cases {
                    total += 1
                    let caseName = str(c["caseName"]) ?? "?"
                    let op = str(c["op"]) ?? "?"
                    let input = (c["input"] as? [String: Any]) ?? [:]
                    let swift = try SimRulesBridge.swiftPayload(op: op, input: input)
                    let engine = try enginePayload(op: op, input: input)
                    let errs = SimRulesJSONCompare.report(expected: swift, actual: engine,
                                                          path: "diff.\(name).\(s).\(caseName)")
                    if !errs.isEmpty {
                        XCTFail("❌ Swift↔引擎 差异 \(name).\(s).\(caseName)（op=\(op)）：\n  "
                                + errs.joined(separator: "\n  "))
                    }
                }
            }
        }
        XCTAssertGreaterThan(total, 0, "没有任何用例参与双跑（fixture 结构变化？）")
    }

    // MARK: - ② mode 分发：.swift / .engine 与各自后端等价

    func testModeDispatch() throws {
        try ensureEngineReady()
        defer { SimRulesBridge.mode = .swift }   // 恢复到默认（避免污染其它套件）

        // 取一个 sim_rules 首例作代表（双跑覆盖全量已由 ① 完成，此处只验分发）
        let fixture = try loadFixture("sim_rules")
        guard let c = (fixture["simFormat"] as? [[String: Any]])?.first else {
            XCTFail("sim_rules.json 缺 simFormat 用例"); return
        }
        let op = str(c["op"]) ?? "?"
        let input = (c["input"] as? [String: Any]) ?? [:]
        let reference = try SimRulesBridge.swiftPayload(op: op, input: input)

        // .swift：同步回调，结果 == swiftPayload
        SimRulesBridge.mode = .swift
        var swiftOut: Result<[String: Any], SimRulesBridge.Failure>?
        SimRulesBridge.payload(op: op, input: input) { swiftOut = $0 }
        guard case .success(let swiftViaMode)? = swiftOut else {
            XCTFail("mode=.swift 未同步成功回调：\(String(describing: swiftOut))"); return
        }
        XCTAssertTrue(SimRulesJSONCompare.report(expected: reference, actual: swiftViaMode,
                                                 path: "dispatch.swift").isEmpty,
                      "mode=.swift 结果应等于 swiftPayload")

        // .engine：异步回调，结果 == enginePayload
        SimRulesBridge.mode = .engine
        let exp = expectation(description: "SimRulesBridge.payload mode=.engine")
        var engineOut: Result<[String: Any], SimRulesBridge.Failure>?
        SimRulesBridge.payload(op: op, input: input, timeout: 30) { r in engineOut = r; exp.fulfill() }
        wait(for: [exp], timeout: 35)
        guard case .success(let engineViaMode)? = engineOut else {
            XCTFail("mode=.engine 未成功回调：\(String(describing: engineOut))"); return
        }
        let direct = try enginePayload(op: op, input: input)
        XCTAssertTrue(SimRulesJSONCompare.report(expected: direct, actual: engineViaMode,
                                                 path: "dispatch.engine").isEmpty,
                      "mode=.engine 结果应等于 enginePayload")
    }

    // MARK: - ③ cond_texts（A5-3 批量文案）一致性

    /// `cond_texts` 是 A5-3 投影层用的批量 op（一次取全 6 字段）。本用例验证：
    /// ① 两侧后端（Swift 投影 / 引擎）逐字一致；② 批量各字段 == 对应单字段 op（`cond_text` /
    /// `cond_grid_level_count`）——即批量只是「合并往返」，不引入新语义。
    func testCondTextsBatchedConsistency() throws {
        try ensureEngineReady()
        let fixture = try loadFixture("sim_rules")
        guard let cases = fixture["text"] as? [[String: Any]] else {
            XCTFail("sim_rules.json 缺段 text"); return
        }
        var checked = 0
        for c in cases {
            let input = (c["input"] as? [String: Any]) ?? [:]
            guard let order = input["order"] as? [String: Any] else { continue }
            let tz = input["tzOffsetSeconds"] ?? 0
            let caseName = str(c["caseName"]) ?? "?"
            let batchedIn: [String: Any] = ["order": order, "tzOffsetSeconds": tz]

            let swift = try SimRulesBridge.swiftPayload(op: "cond_texts", input: batchedIn)
            let engine = try enginePayload(op: "cond_texts", input: batchedIn)
            let errs = SimRulesJSONCompare.report(expected: swift, actual: engine,
                                                  path: "cond_texts.\(caseName)")
            XCTAssertTrue(errs.isEmpty, "cond_texts 双跑差异 \(caseName)：\(errs)")

            guard let t = engine["text"] as? [String: Any] else {
                XCTFail("\(caseName)：cond_texts 无 text"); continue
            }
            for field in ["condition", "directiveCore", "directive", "validity", "preview"] {
                let single = try enginePayload(op: "cond_text",
                                               input: ["field": field, "order": order,
                                                       "tzOffsetSeconds": tz])
                XCTAssertEqual(str(t[field]), str(single["text"]),
                               "\(caseName)：cond_texts.\(field) != cond_text(\(field))")
            }
            let gc = try enginePayload(op: "cond_grid_level_count", input: ["order": order])
            XCTAssertEqual(t["gridLevelCount"] as? Int, gc["count"] as? Int,
                           "\(caseName)：cond_texts.gridLevelCount != cond_grid_level_count")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "没有 text 用例参与 cond_texts 一致性检查")
    }
}

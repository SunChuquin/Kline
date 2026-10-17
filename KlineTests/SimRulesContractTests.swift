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
//  ⚠️ A4 起：Swift 现状的「投影成 golden 形状 JSON」逻辑已迁至生产门面
//     `SimRulesBridge.swiftPayload(op:input:)`（供 A4 差分双跑与 dump 共用，单一来源）；
//     本文件只保留 fixture 读写、dump/断言与档位组织。
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

    private func str(_ v: Any?) -> String? { v as? String }

    // MARK: - dump / 断言

    private func processSection(fixtureName: String, section: String, cases: [[String: Any]],
                                assertMode: Bool) throws -> (cases: [[String: Any]], failed: Int) {
        var outCases: [[String: Any]] = []
        var failed = 0
        for c in cases {
            let name = str(c["caseName"]) ?? "?"
            let op = str(c["op"]) ?? "?"
            let input = (c["input"] as? [String: Any]) ?? [:]
            let payload = try SimRulesBridge.swiftPayload(op: op, input: input)
            if assertMode {
                let expected = c["expected"]!   // 调用方保证齐备
                let errs = SimRulesJSONCompare.report(expected: expected, actual: payload,
                                                      path: "\(fixtureName).\(section).\(name)")
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
                let payload = try SimRulesBridge.swiftPayload(op: op, input: input)
                if let expected = c["expected"] {
                    for e in SimRulesJSONCompare.report(expected: expected, actual: payload,
                                                        path: "strategy_dsl.json.\(s).\(name)") {
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
            let payload = try SimRulesBridge.swiftPayload(op: "backtest_run", input: input)
            if complete, !dumpMode, let expected = c["expected"] {
                for e in SimRulesJSONCompare.report(expected: expected, actual: payload,
                                                    path: "backtest_golden.json.\(name)") {
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

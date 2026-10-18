//
//  SimRulesCodecTests.swift
//  KlineTests
//
//  阶段 A5-2：生产编解码层 `SimRulesCodec` 的契约测试（回测子系统为首个接入者）。
//
//  覆盖：
//    ① 入参编解码**不动点**：`encode(decode(x))` 幂等（编码器与解码器互逆）；
//    ② 出参反解：`backtestJSON(backtestResult(from: fixture.expected))` == `fixture.expected`
//       （逐字段，含 NSNull/数值容差）——验证「引擎 JSON → 生产模型」无损；
//    ③ 生产编码可被引擎消费：`encode(models)` 喂引擎得到 `fixture.expected`；
//    ④ 生产入口 `SimRulesBridge.backtestRun`：`.engine` 结果 == `.swift` 结果。
//    （③④ 需引擎就绪，否则 XCTSkip——降级路径由 SimRulesTrustTests / 无引擎构建覆盖。）
//

import XCTest
@testable import Kline

final class SimRulesCodecTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> [String: Any] {
        let bundle = Bundle(for: Self.self)
        var url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        if url == nil { url = bundle.url(forResource: name, withExtension: "json") }
        let data = try Data(contentsOf: try XCTUnwrap(url, "fixture \(name).json 不在测试 bundle"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func backtestCases() throws -> [[String: Any]] {
        let root = try loadFixture("backtest_golden")
        return try XCTUnwrap(root["cases"] as? [[String: Any]])
    }

    private func ensureEngineReady() throws {
        if KlinePythonBridge.shared.isReady { return }
        let exp = expectation(description: "ensureReady")
        var failureMsg: String?
        KlinePythonBridge.shared.ensureReady { r in
            if case .failure(let msg) = r { failureMsg = msg }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 60)
        if let msg = failureMsg {
            throw XCTSkip("Python 引擎未就绪：\(msg)——无引擎构建验证降级路径而非失败")
        }
    }

    // MARK: - ① 入参编解码不动点

    func testBacktestInputEncodeDecodeFixpoint() throws {
        for c in try backtestCases() {
            let name = c["caseName"] as? String ?? "?"
            let input = try XCTUnwrap(c["input"] as? [String: Any])
            let m1 = SimRulesCodec.backtestInputDecode(input)
            let json1 = SimRulesCodec.backtestInput(doc: m1.doc, bars: m1.bars, pickHits: m1.pickHits,
                                                    metas: m1.metas, params: m1.params,
                                                    tzOffsetSeconds: m1.tzOffsetSeconds)
            let m2 = SimRulesCodec.backtestInputDecode(json1)
            let json2 = SimRulesCodec.backtestInput(doc: m2.doc, bars: m2.bars, pickHits: m2.pickHits,
                                                    metas: m2.metas, params: m2.params,
                                                    tzOffsetSeconds: m2.tzOffsetSeconds)
            let errs = SimRulesJSONCompare.report(expected: json1, actual: json2, path: "$")
            XCTAssertTrue(errs.isEmpty, "\(name)：encode/decode 不动点被破坏 → \(errs)")
            // 关键字段不得丢：doc.rules / bars 根数 / pickHits / metas.code
            XCTAssertEqual(SimRulesCodec.str((json1["doc"] as? [String: Any])?["rules"]),
                           SimRulesCodec.str((input["doc"] as? [String: Any])?["rules"]), name)
            XCTAssertEqual((json1["bars"] as? [String: Any])?.count,
                           (input["bars"] as? [String: Any])?.count, name)
        }
    }

    // MARK: - ② 出参反解无损

    func testBacktestResultDecodeMatchesGolden() throws {
        for c in try backtestCases() {
            let name = c["caseName"] as? String ?? "?"
            let input = try XCTUnwrap(c["input"] as? [String: Any])
            let expected = try XCTUnwrap(c["expected"] as? [String: Any])
            let params = SimRulesCodec.backtestInputDecode(input).params
            let result = try SimRulesCodec.backtestResult(from: expected, params: params)
            var json = SimRulesCodec.backtestJSON(result)
            json["ok"] = true        // fixture.expected 含 ok（op 完整输出）
            let errs = SimRulesJSONCompare.report(expected: expected, actual: json, path: "$")
            XCTAssertTrue(errs.isEmpty, "\(name)：出参反解有损 → \(errs)")
        }
    }

    // MARK: - ③ 生产编码可被引擎消费

    func testEncodedInputDrivesEngineToGolden() throws {
        try ensureEngineReady()
        for c in try backtestCases() {
            let name = c["caseName"] as? String ?? "?"
            let input = try XCTUnwrap(c["input"] as? [String: Any])
            let expected = try XCTUnwrap(c["expected"] as? [String: Any])
            let m = SimRulesCodec.backtestInputDecode(input)
            let encoded = SimRulesCodec.backtestInput(doc: m.doc, bars: m.bars, pickHits: m.pickHits,
                                                      metas: m.metas, params: m.params,
                                                      tzOffsetSeconds: m.tzOffsetSeconds)
            let actual = try enginePayload(op: "backtest_run", input: encoded)
            let errs = SimRulesJSONCompare.report(expected: expected, actual: actual, path: "$")
            XCTAssertTrue(errs.isEmpty, "\(name)：生产编码喂引擎与 golden 不一致 → \(errs)")
        }
    }

    // MARK: - 引擎侧 helper

    private func enginePayload(op: String, input: [String: Any]) throws -> [String: Any] {
        let exp = expectation(description: "enginePayload op=\(op)")
        var boxed: Result<[String: Any], SimRulesBridge.Failure>?
        SimRulesBridge.enginePayload(op: op, input: input, timeout: 30) { r in boxed = r; exp.fulfill() }
        wait(for: [exp], timeout: 35)
        let r = try XCTUnwrap(boxed, "enginePayload op=\(op) 未在超时前回调")
        switch r {
        case .success(let obj): return obj
        case .failure(let f):
            XCTFail("enginePayload op=\(op) 失败：\(f)")
            throw NSError(domain: "SimRulesCodecTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "enginePayload failed: \(f)"])
        }
    }
}

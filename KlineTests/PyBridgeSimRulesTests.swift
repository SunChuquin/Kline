//
//  PyBridgeSimRulesTests.swift
//  KlineTests
//
//  契约测试③（阶段 A3）：交易判定成对下沉的 **Python↔fixture** 对拍。
//
//  与 SimRulesContractTests（Swift 现状 ↔ fixture）对同一份 golden 断言：
//    · sim_rules.json      —— 八段（simFormat / evaluate / validateCreate / gridLevelCount /
//                             text / sweep / tradingRules / mapping），expected 由 Swift dump 写；
//    · strategy_dsl.json   —— E 组解析类八段，expected 为手写规格；
//    · backtest_golden.json —— F 组回测，expected 由 Swift dump 写。
//
//  通道：KlinePythonBridge.call(script: "sim_rules")（JSON 通道；backtest_run 亦走此通道，
//  其 bars 为 JSON 内联、非 bin 段）。业务脚本 `kline_result = {"ok": true, …op 输出…}`
//  即 fixture 的 expected（桥接 readResult 校验 ok==true 后原样返回 _kres，不额外包一层）。
//
//  skip 语义（对齐 PyBridgeQuoteParsingTests）：引擎未就绪（无引擎构建 /
//  KLINE_SKIP_ENGINE_EMBED=1）→ ensureReady 失败 → XCTSkip（这是降级路径，不是失败）；
//  引擎就绪后 call 失败属真实缺陷 → 真 fail（sim_rules.py 仅标准库，不存在环境性 skip）。
//
//  时区：sim_rules.py 所有时间相关 op 一律吃入参 tzOffsetSeconds（fixture 已逐条注入），
//  不经本机时区；唯一取「真实 now」的是 cond_evaluate 的 .time 分支，用例用 2000/2099
//  远日期（对 now 不敏感）。故本套件**不依赖宿主时区**，无需 SimRulesContractTests 的
//  +08:00 守卫（那条守卫是给「Swift 侧 dump」用的，不是给引擎用的）。
//
//  数值口径：与 SimRulesContractTests / SimRulesDiffTests 共用测试目标内的
//  `SimRulesJSONCompare`（递归比较、数值相对容差 1e-9·max(1,|e|)、对象键集必须
//  完全一致——缺键/多键皆报错）。
//

import XCTest
@testable import Kline

final class PyBridgeSimRulesTests: XCTestCase {

    // MARK: - fixture 读取（Fixtures/ 子目录优先，取不到退回 bundle 根）

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

    /// 后台 ensureReady（引擎加载含 dlopen + Py_Initialize，60s 上限）；
    /// 失败 → XCTSkip（无引擎构建验证降级路径而非失败）。
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

    // MARK: - 桥接调用（异步；返回 kline_result 顶层 dict）

    /// 异步 call sim_rules（timeout 30s）；引擎已就绪后 call 失败属真实缺陷 → XCTFail。
    /// 返回业务脚本的 `kline_result`（= {"ok": true, …op 输出…}，即 fixture 的 expected）。
    private func callSimRules(op: String, input: [String: Any]) throws -> [String: Any] {
        var payload = input
        payload["op"] = op
        let exp = expectation(description: "KlinePythonBridge.call sim_rules op=\(op)")
        var boxed: Result<Data, PyBridgeError>?
        KlinePythonBridge.shared.call(script: "sim_rules", input: payload, timeout: 30) { r in
            boxed = r
            exp.fulfill()
        }
        wait(for: [exp], timeout: 35)
        guard let result = boxed else {
            throw NSError(domain: "KlinePyBridgeTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "sim_rules op=\(op) bridge call 未在超时前回调"])
        }
        switch result {
        case .success(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("sim_rules op=\(op) 输出非 JSON 对象（\(data.count) bytes）")
                throw NSError(domain: "KlinePyBridgeTests", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "sim_rules bad output"])
            }
            return obj
        case .failure(let e):
            XCTFail("sim_rules op=\(op) bridge call 失败：\(e)")
            throw NSError(domain: "KlinePyBridgeTests", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "sim_rules bridge call failed"])
        }
    }

    // MARK: - 通用分段落 runner（比较器 = 测试共享 SimRulesJSONCompare）

    private func runFixture(_ name: String, sections: [String]) throws {
        try ensureEngineReady()
        let fixture = try loadFixture(name)
        var caseCount = 0
        for s in sections {
            guard let cases = fixture[s] as? [[String: Any]] else {
                XCTFail("\(name).json 缺段 \(s)")
                continue
            }
            XCTAssertFalse(cases.isEmpty, "\(name).json 段 \(s) 不应为空")
            for c in cases {
                caseCount += 1
                let caseName = str(c["caseName"]) ?? "?"
                let op = str(c["op"]) ?? "?"
                let input = (c["input"] as? [String: Any]) ?? [:]
                guard let expected = c["expected"] else {
                    XCTFail("\(name).json.\(s).\(caseName)：缺 expected（golden 未 dump / 手写规格漏填）")
                    continue
                }
                let actual = try callSimRules(op: op, input: input)
                let errs = SimRulesJSONCompare.report(expected: expected, actual: actual,
                                                      path: "\(name).json.\(s).\(caseName)")
                if !errs.isEmpty {
                    // 单 case 聚合为一条失败：逐字段并列，便于定位，又不至于刷屏
                    XCTFail("❌ \(name).json.\(s).\(caseName)（op=\(op)）：\n  " + errs.joined(separator: "\n  "))
                }
            }
        }
        XCTAssertGreaterThan(caseCount, 0, "\(name).json 无任何用例（fixture 结构变化？）")
    }

    // MARK: - 主测试：sim_rules.json（八段）

    func testPyBridgeSimRulesMatchesGolden() throws {
        try runFixture("sim_rules", sections: [
            "simFormat", "evaluate", "validateCreate", "gridLevelCount",
            "text", "sweep", "tradingRules", "mapping",
        ])
    }

    // MARK: - 主测试：strategy_dsl.json（E 组解析类八段）

    func testPyBridgeStrategyDSLMatchesGolden() throws {
        try runFixture("strategy_dsl", sections: [
            "strategyParse", "strategyRuleLine", "strategyCatalog", "strategyValidate",
            "strategyPreview", "tradeParse", "tradeSerialize", "tradeOverride",
        ])
    }

    // MARK: - 主测试：backtest_golden.json（F 组回测）

    func testPyBridgeBacktestMatchesGolden() throws {
        try runFixture("backtest_golden", sections: ["cases"])
    }
}

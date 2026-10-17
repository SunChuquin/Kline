//
//  SimRulesProjectionTests.swift
//  KlineTests
//
//  阶段 A5-3：引擎投影层 `SimRulesProjection`（防抖 + 缓存 + `.swift` 直通）。
//
//  覆盖：
//    ① 过渡期直通：`mode == .swift` 时取值 == `SimCondRule` 现状（零行为变化）；
//    ② `.engine` 模式：`request` → 引擎 `cond_texts` → 缓存文案与 Swift 现状逐字一致；
//    ③ 内容去重：同内容重复 request 不再打引擎（可用性保持 ready）。
//    （②③ 需引擎就绪，否则 XCTSkip。）
//
//  范围说明：日期相关 kind（`.time`）的文案受时区口径影响（Swift `Calendar.current` 含 DST，
//  引擎用固定 `tzOffsetSeconds`；见 §11.5 已知限制），本套件不纳入逐字比较，改由
//  `SimRulesDiffTests` 的 `cond_texts` 一致性用例（同入参两侧对拍）兜住。
//

import XCTest
@testable import Kline

@MainActor
final class SimRulesProjectionTests: XCTestCase {

    // MARK: - 构造条件单（走引擎契约形状 = Codable）

    private func makeOrder(kind: String, params: [String: Any],
                           directive: [String: Any] = ["direction": "sell", "priceType": "market",
                                                       "offsetTicks": 0, "qty": 300, "alertOnly": false],
                           validity: String = "longTerm", name: String = "条件单甲") throws -> SimCondOrder {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "accountID": "11111111-1111-1111-1111-111111111111",
            "metaID": 7, "code": "600519.SH", "name": name,
            "kind": kind, "params": params, "directive": directive,
            "validity": validity, "runtime": [:],
            "createdAt": "2026-10-17T01:00:00Z", "updatedAt": "2026-10-17T01:00:00Z",
        ]
        return try SimRulesCodec.condOrderFromJSON(json)
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

    /// 轮询等待若干单据的投影就绪（避免固定 sleep 的脆弱性）
    private func waitReady(_ ids: [UUID], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ids.allSatisfy({ SimRulesProjection.shared.availability[$0] == .ready }) { return true }
            let exp = expectation(description: "yield")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
            wait(for: [exp], timeout: 2)
        }
        return ids.allSatisfy({ SimRulesProjection.shared.availability[$0] == .ready })
    }

    private func withMode(_ mode: SimRulesBridge.Mode, _ body: () throws -> Void) rethrows {
        let saved = SimRulesBridge.mode
        defer { SimRulesBridge.mode = saved }
        SimRulesBridge.mode = mode
        try body()
    }

    // MARK: - ① 过渡期直通

    func testSwiftModePassthrough() throws {
        try withMode(.swift) {
            let o = try makeOrder(kind: "price",
                                  params: ["triggerPrice": 1500.0, "compareUp": true])
            XCTAssertEqual(SimRulesProjection.shared.conditionSummary(o), SimCondRule.conditionSummary(o))
            XCTAssertEqual(SimRulesProjection.shared.validitySummary(o), SimCondRule.validitySummary(o))
            XCTAssertEqual(SimRulesProjection.shared.directiveSummary(o), SimCondRule.directiveSummary(o))
            XCTAssertEqual(SimRulesProjection.shared.directiveCore(o), SimCondRule.directiveCore(o))
            XCTAssertEqual(SimRulesProjection.shared.previewSentence(o), SimCondRule.previewSentence(o))
            XCTAssertEqual(SimRulesProjection.shared.gridLevelCount(o), SimCondRule.gridLevelCount(order: o))
        }
    }

    // MARK: - ② .engine 投影 == Swift 现状

    func testEngineProjectionMatchesSwift() throws {
        try ensureEngineReady()

        let specs: [(String, [String: Any])] = [
            ("price", ["triggerPrice": 1500.0, "compareUp": true]),
            ("price", ["triggerPrice": 1480.0, "compareUp": false]),
            ("stopLoss", ["takeProfitPrice": 1600.0, "stopLossPrice": 1450.0, "basePrice": 1500.0]),
            ("trailing", ["breakoutPrice": 1450.0, "trailPct": 3.0]),
            ("maCross", ["maPeriod": 20, "fastPeriod": 5, "slowPeriod": 20, "compareUp": true]),
            ("changePct", ["changePct": 5.0, "compareUp": true]),
            ("grid", ["gridBase": 1500.0, "gridStep": 10.0, "gridCount": 5]),
            ("batch", ["batchCount": 3]),
        ]
        let orders = try specs.map { try makeOrder(kind: $0.0, params: $0.1) }

        // 期望值：Swift 现状（.swift 模式取）
        var expected: [UUID: (String, String, String, String, Int)] = [:]
        try withMode(.swift) {
            for o in orders {
                expected[o.id] = (SimCondRule.conditionSummary(o), SimCondRule.validitySummary(o),
                                  SimCondRule.directiveSummary(o), SimCondRule.previewSentence(o),
                                  SimCondRule.gridLevelCount(order: o))
            }
        }

        // 引擎投影
        try withMode(.engine) {
            SimRulesProjection.shared.request(orders)
            let ready = waitReady(orders.map { $0.id }, timeout: 30)
            XCTAssertTrue(ready, "投影未在超时内就绪（引擎可能出错）")
            for o in orders {
                let e = try XCTUnwrap(expected[o.id])
                XCTAssertEqual(SimRulesProjection.shared.conditionSummary(o), e.0, "condition \(o.kind)")
                XCTAssertEqual(SimRulesProjection.shared.validitySummary(o), e.1, "validity \(o.kind)")
                XCTAssertEqual(SimRulesProjection.shared.directiveSummary(o), e.2, "directive \(o.kind)")
                XCTAssertEqual(SimRulesProjection.shared.previewSentence(o), e.3, "preview \(o.kind)")
                XCTAssertEqual(SimRulesProjection.shared.gridLevelCount(o), e.4, "grid \(o.kind)")
            }
        }
    }

    // MARK: - ③ 内容去重（同内容重复 request 不打引擎）

    func testIdenticalRepeatRequestIsDeduped() throws {
        try ensureEngineReady()
        try withMode(.engine) {
            let o = try makeOrder(kind: "price", params: ["triggerPrice": 1500.0, "compareUp": true])
            SimRulesProjection.shared.request([o])
            XCTAssertTrue(waitReady([o.id], timeout: 30), "首轮未就绪")

            // 同一内容再请求：应被 requestedJSON 去重（不重置为 computing）
            SimRulesProjection.shared.request([o])
            XCTAssertEqual(SimRulesProjection.shared.availability[o.id], .ready,
                           "同内容重复请求不应把可用性重置为 computing")
            XCTAssertEqual(SimRulesProjection.shared.conditionSummary(o),
                           SimCondRule.conditionSummary(o))
        }
    }
}

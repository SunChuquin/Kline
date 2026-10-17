//
//  SimTradeRulesProjectionTests.swift
//  KlineTests
//
//  阶段 A5-5 前置（C 组展示面 ·《Python引擎下沉可行性分析.md》§11.23）：`SimTradeRulesProjection`
//  （交易规则派生值的引擎投影层）契约测试。
//
//  覆盖：
//    ① `.swift` 模式 = 完全直通 `SimTradingRules`（零行为变化，且**不产生**任何缓存/请求）；
//    ② `.engine` 模式冷缓存 → 先给显式空态（nil），防抖冲一次后 = Swift 现状值（逐条对拍）；
//    ③ 两种 mode 下与 `SimTradingRules.default` 逐字段相等（fixture 入参全量跑一遍）；
//    ④ 配置常量与占位文案（§11.22 信任链镜像 + §9.10 显式空态）。
//
//  用例来源：`KlineTests/Fixtures/sim_rules.json` 的 `tradingRules` 段既有入参
//  （**不新增 golden、不改 fixture**）。
//

import XCTest
@testable import Kline

@MainActor
final class SimTradeRulesProjectionTests: XCTestCase {

    private var proj: SimTradeRulesProjection { SimTradeRulesProjection.shared }

    // MARK: - fixture 读取

    private func loadFixture(_ name: String) throws -> [String: Any] {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "SimTradeRulesProjectionTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bad fixture \(name).json"])
        }
        return root
    }

    private func cases(_ fixture: [String: Any], op: String) -> [[String: Any]] {
        ((fixture["tradingRules"] as? [[String: Any]]) ?? []).filter { ($0["op"] as? String) == op }
    }

    private func input(_ c: [String: Any]) -> [String: Any] { (c["input"] as? [String: Any]) ?? [:] }
    private func name(_ c: [String: Any]) -> String { (c["caseName"] as? String) ?? "?" }

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

    // MARK: - 对拍（两种 mode 共用）

    /// 先取一次（`.engine` 模式为未命中 → 入队），冲一次防抖队列，再取并与 Swift 现状比对。
    private func expectAfterFlush<T: Equatable>(_ label: String, _ read: () -> T?, _ want: T,
                                                file: StaticString = #filePath, line: UInt = #line)
    async {
        _ = read()
        await proj.flushAndWait()
        XCTAssertEqual(read(), want, label, file: file, line: line)
    }

    private func runProjectionParity(_ mode: SimRulesBridge.Mode) async throws {
        let saved = SimRulesBridge.mode
        defer { SimRulesBridge.mode = saved }
        SimRulesBridge.mode = mode
        proj.reset()

        let sim = try loadFixture("sim_rules")
        let rules = SimTradingRules.default

        for c in cases(sim, op: "trade_calc") {
            let i = input(c)
            let label = "\(mode) 投影 trade_calc.\(SimRulesCodec.str(i["calc"]) ?? "?") \(name(c))"
            let dir = SimRulesCodec.str(i["direction"])
                .flatMap(SimOrderDirection.init(rawValue:)) ?? .buy
            switch SimRulesCodec.str(i["calc"]) ?? "" {
            case "commission":
                let amount = SimRulesCodec.num(i["amount"]) ?? 0
                await expectAfterFlush(label, { proj.commission(amount: amount) },
                                       rules.commission(amount: amount))
            case "stampTax":
                let amount = SimRulesCodec.num(i["amount"]) ?? 0
                await expectAfterFlush(label, { proj.stampTax(amount: amount, direction: dir) },
                                       rules.stampTax(amount: amount, direction: dir))
            case "fee":
                let amount = SimRulesCodec.num(i["amount"]) ?? 0
                await expectAfterFlush(label, { proj.fee(amount: amount, direction: dir) },
                                       rules.fee(amount: amount, direction: dir))
            case "affordableQty":
                let cash = SimRulesCodec.num(i["cash"]) ?? 0
                let price = SimRulesCodec.num(i["price"]) ?? 0
                await expectAfterFlush(label, { proj.affordableQty(cash: cash, price: price) },
                                       rules.affordableQty(cash: cash, price: price))
            case "sellableQty":
                let pos = SimRulesCodec.positionFromJSON(i["position"])
                await expectAfterFlush(label, { proj.sellableQty(position: pos) },
                                       rules.sellableQty(position: pos))
            case "isTradingSession":
                let at = SimRulesCodec.isoDate(i["at"]) ?? Date()
                await expectAfterFlush(label, { proj.isTradingSession(at: at) },
                                       rules.isTradingSession(at: at))
            case "limitRange":
                let prev = SimRulesCodec.num(i["prevClose"])
                let want = rules.limitRange(prevClose: prev)
                _ = proj.limitRange(prevClose: prev)
                await proj.flushAndWait()
                let got = proj.limitRange(prevClose: prev)
                XCTAssertEqual(got?.lowerBound ?? -1, want?.lowerBound ?? -1, accuracy: 1e-9, label)
                XCTAssertEqual(got?.upperBound ?? -1, want?.upperBound ?? -1, accuracy: 1e-9, label)
            default:
                break
            }
        }

        // 动作路径（直接 await 引擎）也要与现状一致
        for c in cases(sim, op: "trade_calc") where SimRulesCodec.str(input(c)["calc"]) == "sellableQty" {
            let pos = SimRulesCodec.positionFromJSON(input(c)["position"])
            if let pos {
                let got = await proj.sellableQtyAsync(position: pos)
                XCTAssertEqual(got, rules.sellableQty(position: pos),
                               "\(mode) sellableQtyAsync \(name(c))")
            }
        }
    }

    // MARK: - 用例（两种 mode）

    func testParitySwiftMode() async throws {
        try await runProjectionParity(.swift)
    }

    func testParityEngineMode() async throws {
        try await ensureEngineReady()
        try await runProjectionParity(.engine)
    }

    // MARK: - ① `.swift` 模式零开销直通

    func testSwiftModeDirectPassLeavesCacheEmpty() async throws {
        let saved = SimRulesBridge.mode
        defer { SimRulesBridge.mode = saved }
        // 先把上一批在途请求排干，再清空——否则断言可能被迟到的写入打破
        await proj.flushAndWait()
        proj.reset()
        SimRulesBridge.mode = .swift

        let pos = SimPosition(id: UUID(), accountID: UUID(), metaID: 1, code: "600000",
                              name: "浦发银行", qty: 500, availableQty: 300,
                              costPrice: 10.5, openedAt: Date())
        XCTAssertEqual(proj.fee(amount: 10000, direction: .sell),
                       SimTradingRules.default.fee(amount: 10000, direction: .sell))
        XCTAssertEqual(proj.commission(amount: 10000),
                       SimTradingRules.default.commission(amount: 10000))
        XCTAssertEqual(proj.stampTax(amount: 10000, direction: .sell),
                       SimTradingRules.default.stampTax(amount: 10000, direction: .sell))
        XCTAssertEqual(proj.affordableQty(cash: 100000, price: 10),
                       SimTradingRules.default.affordableQty(cash: 100000, price: 10))
        XCTAssertEqual(proj.sellableQty(position: pos),
                       SimTradingRules.default.sellableQty(position: pos))
        XCTAssertEqual(proj.limitRange(prevClose: 10)?.upperBound,
                       SimTradingRules.default.limitRange(prevClose: 10)?.upperBound)
        XCTAssertEqual(proj.isTradingSession(at: Date()),
                       SimTradingRules.default.isTradingSession(at: Date()))

        XCTAssertTrue(proj.values.isEmpty, "`.swift` 模式不得写投影缓存（零行为变化）")
        XCTAssertTrue(proj.availability.isEmpty, "`.swift` 模式不得产生引擎请求")
    }

    // MARK: - ② `.engine` 冷缓存：先显式空态，再给引擎值

    func testEngineModeColdCacheGivesNilThenEngineValue() async throws {
        try await ensureEngineReady()
        let saved = SimRulesBridge.mode
        defer { SimRulesBridge.mode = saved }
        await proj.flushAndWait()
        proj.reset()
        SimRulesBridge.mode = .engine

        let amount = 12345.67
        XCTAssertNil(proj.fee(amount: amount, direction: .sell),
                     "冷缓存必须先给显式空态（nil），不得用 Swift 现状值兜底（§9.10）")
        await proj.flushAndWait()
        XCTAssertEqual(proj.fee(amount: amount, direction: .sell),
                       SimTradingRules.default.fee(amount: amount, direction: .sell),
                       "防抖冲一次后应拿到引擎值")
    }

    // MARK: - ③ 时段按分钟归并（每秒时钟不刷引擎）

    func testSessionKeyBucketsByMinute() async throws {
        try await ensureEngineReady()
        let saved = SimRulesBridge.mode
        defer { SimRulesBridge.mode = saved }
        await proj.flushAndWait()
        proj.reset()
        SimRulesBridge.mode = .engine

        let base = Date(timeIntervalSince1970: 1_700_000_000)      // 落在某分钟内第 20 秒
        let later = base.addingTimeInterval(10)                    // 同一分钟内第 30 秒
        _ = proj.isTradingSession(at: base)
        await proj.flushAndWait()
        let first = proj.isTradingSession(at: base)
        XCTAssertNotNil(first)
        // 同一分钟内：直接命中缓存，不应再入队（`pending` 为空 → 冲一次也读得到）
        XCTAssertEqual(proj.isTradingSession(at: later), first,
                       "同一分钟内应复用同一投影值（时钟每秒刷新不打引擎）")
        XCTAssertEqual(proj.availability.count, 1, "同一分钟只应有一个时段缓存键")
    }

    // MARK: - ④ 配置常量与占位文案

    func testConstantsAndPlaceholderText() {
        XCTAssertEqual(proj.lotSize, 100)
        XCTAssertEqual(proj.priceTick, 0.01)
        XCTAssertEqual(proj.lotSize, SimTradingRules.default.lotSize)
        XCTAssertEqual(proj.priceTick, SimTradingRules.default.priceTick)

        XCTAssertEqual(SimTradeRulesProjection.placeholderText, "—")
        XCTAssertEqual(SimTradeRulesProjection.moneyText(nil), "—")
        XCTAssertEqual(SimTradeRulesProjection.moneyText(1234.5), SimFormat.amount(1234.5))
        XCTAssertEqual(SimTradeRulesProjection.sharesText(nil), "—")
        XCTAssertEqual(SimTradeRulesProjection.sharesText(300), SimFormat.shares(300))
    }
}

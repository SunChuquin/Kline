//
//  PyBridgePeriodAggregationTests.swift
//  KlineTests
//
//  桥接契约测试①：周期聚合（周/月/季/年）—— Python 引擎 period_aggregate.py
//  经 KlinePythonBridge 调用，结果 vs PC 侧 golden。
//
//  契约来源：.trae/specs/add-python-offload-pilot/spec.md 桥接链路
//  （Swift 测试 → KlinePythonBridge.shared.call → PythonEngineHost.PyRun →
//  Bundle.main/PyScripts/period_aggregate.py op="aggregate"）；
//  golden 为 src/contract_golden.py 产出的 KlineTests/Fixtures/period_aggregation.json
//  （与 PeriodAggregationContractTests.swift 同一 fixture、同一数值口径）。
//
//  调用方式：每个 case 的 daily 全量作为一个 series（file=caseName），periods 全四周期，
//  每个独立 case 一次 bridge 异步 call（timeout 30s）取 result[caseName][period] 行数组；
//  测试一律用异步 call + XCTestExpectation（blockingCall 禁止主线程同步等待，不在此使用）。
//
//  数值口径：date 精确相等（YYYYMMDD 整数，双方行均按 date 升序，按下标直接对齐）；
//  open/high/low/close 容差 1e-6；vol 为整数累加 → 1e-9 容差（整数量级下等效精确相等，
//  仅防御浮点表示噪声）；amo 容差 1e-6（golden 经 num6 规整、Python 侧 round(v, 6)）。
//
//  skip 语义：引擎未就绪（KLINE_SKIP_ENGINE_EMBED=1 / 无 EngineCache 等无引擎构建）
//  时 ensureReady 失败 → XCTSkip 而非 fail——无引擎构建验证的是纯 Swift 降级路径，
//  本测试只负责「引擎可用时全绿」。
//

import XCTest
@testable import Kline

final class PyBridgePeriodAggregationTests: XCTestCase {

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

    private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    private func intVal(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

    // MARK: - 引擎就绪与桥接调用（异步 + expectation；引擎不可用 → XCTSkip）

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
                + "——无引擎构建（KLINE_SKIP_ENGINE_EMBED=1 或无 EngineCache）验证纯 Swift 降级路径而非失败")
        }
    }

    /// 异步 call 业务脚本（timeout 30s；bridge 完成回调派发主线程，XCTest wait 可接住）；
    /// 返回输出顶层 dict 的 result 对象。引擎已就绪后 call 失败属真实缺陷 → XCTFail。
    private func callScript(_ script: String, input: [String: Any]) throws -> [String: Any] {
        let exp = expectation(description: "KlinePythonBridge.call \(script)")
        var boxed: Result<Data, PyBridgeError>?
        KlinePythonBridge.shared.call(script: script, input: input, timeout: 30) { r in
            boxed = r
            exp.fulfill()
        }
        wait(for: [exp], timeout: 35)
        guard let result = boxed else {
            throw NSError(domain: "KlinePyBridgeTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "\(script) bridge call 未在超时前回调"])
        }
        switch result {
        case .success(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["result"] as? [String: Any] else {
                XCTFail("\(script) 输出缺 result 对象（\(data.count) bytes；bridge 契约：顶层 dict 且 ok=true，payload 在 result 字段）")
                throw NSError(domain: "KlinePyBridgeTests", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "\(script) bad result payload"])
            }
            return payload
        case .failure(let e):
            XCTFail("\(script) bridge call 失败：\(e)")
            throw NSError(domain: "KlinePyBridgeTests", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "\(script) bridge call failed"])
        }
    }

    // MARK: - 用例：单方法遍历全部 cases（每 case 一次 bridge call，互不依赖执行顺序）

    /// 全部 7 个 case：每 case 的 daily 作为一个 series 经桥送入 period_aggregate.py，
    /// 四周期输出逐行逐字段对齐 golden（date 精确 / 价格 1e-6 / vol 1e-9 / amo 1e-6）。
    func testPyBridgeAggregateMatchesGolden() throws {
        try ensureEngineReady()
        let root = try loadFixture("period_aggregation")
        guard let cases = root["cases"] as? [[String: Any]] else {
            XCTFail("fixture 缺 cases（fixture: period_aggregation.json）")
            return
        }
        XCTAssertFalse(cases.isEmpty,
            "fixture cases 不应为空（fixture: period_aggregation.json → cases）")
        let periods = ["weekly", "monthly", "quarterly", "yearly"]
        for (ci, caseDict) in cases.enumerated() {
            guard let caseName = caseDict["caseName"] as? String,
                  let daily = caseDict["daily"] as? [[Any]],
                  let golden = caseDict["golden"] as? [String: Any] else {
                XCTFail("cases[\(ci)] 缺 caseName/daily/golden：keys=\(caseDict.keys.sorted())"
                    + "（fixture: period_aggregation.json → cases[\(ci)]）")
                continue
            }
            let payload = try callScript("period_aggregate", input: [
                "op": "aggregate",
                "periods": periods,
                "series": [["file": caseName, "daily": daily]],
            ])
            guard let fileResult = payload[caseName] as? [String: Any] else {
                XCTFail("[\(caseName)] 输出 result 缺 file 键 \(caseName)：keys=\(payload.keys.sorted())"
                    + "（bridge: period_aggregate.py op=aggregate → result.\(caseName)）")
                continue
            }
            for periodName in periods {
                guard let goldenRows = golden[periodName] as? [[Any]] else {
                    XCTFail("[\(caseName)] golden 缺周期键 \(periodName)"
                        + "（fixture: period_aggregation.json → cases[\(caseName)].golden）")
                    continue
                }
                guard let pyRows = fileResult[periodName] as? [[Any]] else {
                    XCTFail("[\(caseName)] 输出缺周期键 \(periodName)：keys=\(fileResult.keys.sorted())"
                        + "（bridge: period_aggregate.py op=aggregate → result.\(caseName).\(periodName)）")
                    continue
                }
                XCTAssertEqual(pyRows.count, goldenRows.count,
                    "[\(caseName)][\(periodName)] 行数：golden=\(goldenRows.count) python=\(pyRows.count)"
                    + "（fixture: period_aggregation.json → cases[\(caseName)].golden.\(periodName)；停牌周期双方均无行）")
                for (i, g) in goldenRows.enumerated() where i < pyRows.count {
                    let p = pyRows[i]
                    guard g.count >= 7, p.count >= 7 else {
                        XCTFail("[\(caseName)][\(periodName)]#\(i) 行不足 7 字段：golden=\(g.count) python=\(p.count)"
                            + "（fixture: period_aggregation.json → cases[\(caseName)].golden.\(periodName)[\(i)]）")
                        continue
                    }
                    let key = "period_aggregation.json → cases[\(caseName)].golden.\(periodName)[\(i)]"
                    XCTAssertEqual(intVal(p[0]), intVal(g[0]),
                        "[\(caseName)][\(periodName)]#\(i).date：golden=\(g[0]) python=\(p[0])"
                        + "（fixture: \(key)[0]；口径=周期内首个交易日，双方均按 date 升序按下标对齐）")
                    let priceFields: [(String, Int)] = [("open", 1), ("high", 2), ("low", 3), ("close", 4)]
                    for (field, idx) in priceFields {
                        XCTAssertEqual(num(p[idx]) ?? .nan, num(g[idx]) ?? .nan, accuracy: 1e-6,
                            "[\(caseName)][\(periodName)]#\(i).\(field)：golden=\(g[idx]) python=\(p[idx])"
                            + "（fixture: \(key)[\(idx)]；容差 1e-6）")
                    }
                    XCTAssertEqual(num(p[5]) ?? .nan, num(g[5]) ?? .nan, accuracy: 1e-9,
                        "[\(caseName)][\(periodName)]#\(i).vol：golden=\(g[5]) python=\(p[5])"
                        + "（fixture: \(key)[5]；口径=Σvol，整数累加 → 1e-9 容差等效精确相等）")
                    XCTAssertEqual(num(p[6]) ?? .nan, num(g[6]) ?? .nan, accuracy: 1e-6,
                        "[\(caseName)][\(periodName)]#\(i).amo：golden=\(g[6]) python=\(p[6])"
                        + "（fixture: \(key)[6]；口径=Σamo，双方均 6 位小数规整 → 容差 1e-6）")
                }
            }
        }
    }
}

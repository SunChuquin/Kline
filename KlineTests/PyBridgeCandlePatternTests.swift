//
//  PyBridgeCandlePatternTests.swift
//  KlineTests
//
//  桥接契约测试④：K 线形态识别 —— Python 引擎 candle_patterns.py 经
//  KlinePythonBridge 调用（op="detect"），结果 vs C 版 talib 产出的 golden。
//
//  契约来源：.trae/documents/python-engine/Python引擎下沉可行性分析.md §3.6.3
//  （阶段 2 形态识别首批 10 个 CDL 形态，numpy 向量化移植）。
//  golden 为 scripts/verify_candle_patterns.py --fixture 产出的
//  KlineTests/Fixtures/candle_patterns.json（期望值取自 Mac pip C 版 talib 0.8.1，
//  移植版与 C 版已全量差分零差异——见脚本头部验证契约）。
//
//  数值口径：输出为 int 数组（命中 ±100 / ENGULFING/HARAMI 端点重合 ±80 / 未命中 0，
//  前 lookback 根恒 0），与 golden 逐值精确相等（无浮点容差）。
//
//  skip 语义（对齐 PyBridgePeriodAggregationTests）：
//  - 引擎未就绪（无引擎构建 / KLINE_SKIP_ENGINE_EMBED=1）→ ensureReady 失败 → XCTSkip；
//  - 引擎就绪但 numpy 未安装（旧引擎缓存）→ script error 文本含 "numpy" → XCTSkip
//    （candle_patterns.py 依赖 numpy；numpy 随引擎包版本化，缺失属环境旧版而非缺陷）；
//  - 其余（输出不符等）→ 真 fail。
//

import XCTest
@testable import Kline

final class PyBridgeCandlePatternTests: XCTestCase {

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

    /// 异步 call 业务脚本（timeout 30s）；引擎已就绪后 call 失败属真实缺陷 → XCTFail，
    /// 唯一例外：错误文本含 "numpy"（旧引擎缓存未内嵌 numpy）→ XCTSkip。
    private func callDetect(_ input: [String: Any]) throws -> [String: Any] {
        let exp = expectation(description: "KlinePythonBridge.call candle_patterns")
        var boxed: Result<Data, PyBridgeError>?
        KlinePythonBridge.shared.call(script: "candle_patterns", input: input, timeout: 30) { r in
            boxed = r
            exp.fulfill()
        }
        wait(for: [exp], timeout: 35)
        guard let result = boxed else {
            throw NSError(domain: "KlinePyBridgeTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "candle_patterns bridge call 未在超时前回调"])
        }
        switch result {
        case .success(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["result"] as? [String: Any] else {
                XCTFail("candle_patterns 输出缺 result 对象（\(data.count) bytes）")
                throw NSError(domain: "KlinePyBridgeTests", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "candle_patterns bad result payload"])
            }
            return payload
        case .failure(let e):
            let text = String(describing: e)
            if text.contains("numpy") {
                throw XCTSkip("引擎内 numpy 未安装（旧引擎缓存 / 旧 Engine.app；candle_patterns.py 依赖 numpy）"
                    + "——script error: \(text)")
            }
            XCTFail("candle_patterns bridge call 失败：\(e)")
            throw NSError(domain: "KlinePyBridgeTests", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "candle_patterns bridge call failed"])
        }
    }

    /// golden 期望 int 数组 → [Int]（JSON 数字经 NSNumber 取 intValue，防御浮点表示）
    private func expectedInts(_ v: Any?) -> [Int]? {
        (v as? [Any])?.map { ($0 as? NSNumber)?.intValue ?? Int.min }
    }

    // MARK: - 用例

    /// 全形态全量对齐 golden：fixture 三个序列（随机游走 / 独立 OHLC / 手工样例）一次
    /// bridge call，10 个形态 × 每序列逐 bar 精确相等；并断言命中数 > 0（fixture 有效性）。
    func testPyBridgeDetectAllPatternsMatchesGolden() throws {
        try ensureEngineReady()
        let root = try loadFixture("candle_patterns")
        guard let series = root["series"] as? [[String: Any]],
              let expected = root["expected"] as? [String: [String: Any]] else {
            XCTFail("fixture 缺 series / expected（fixture: candle_patterns.json）")
            return
        }
        XCTAssertFalse(series.isEmpty, "fixture series 不应为空")
        let input: [String: Any] = [
            "op": "detect",
            "series": series,
            "patterns": root["patterns"] as? [String] ?? [],
            "penetration": root["penetration"] ?? 0.3,
        ]
        let result = try callDetect(input)

        var totalHits = 0
        for s in series {
            let file = s["file"] as? String ?? ""
            let bars = s["bars"] as? [[Any]] ?? []
            guard let got = result[file] as? [String: Any] else {
                XCTFail("输出缺序列 \(file)")
                continue
            }
            let expFile = expected[file] ?? [:]
            for (pattern, expArr) in expFile {
                let expectedArr = expectedInts(expArr) ?? []
                let gotArr = expectedInts(got[pattern]) ?? []
                XCTAssertEqual(gotArr.count, bars.count,
                    "\(file)/\(pattern) 输出长度 \(gotArr.count) 应等于 bar 数 \(bars.count)")
                XCTAssertEqual(gotArr, expectedArr,
                    "\(file)/\(pattern) 与 golden 不一致（首个差异下标 "
                        + "\(zip(gotArr, expectedArr).first(where: { $0 != $1 }).map { gotArr.firstIndex(of: $0.0) ?? -1 } ?? -1)）")
                totalHits += expectedArr.filter { $0 != 0 }.count
            }
        }
        XCTAssertGreaterThan(totalHits, 0, "fixture 命中数为 0——golden 有效性存疑，请重新生成")
    }

    /// 缺省参数与子集调用：不传 patterns/penetration（缺省=全 10 形态 + 0.3）应与显式全量
    /// 一致；子集 ["engulfing","doji"] 只返回请求的两个形态且同样对齐 golden。
    func testPyBridgeDetectDefaultsAndSubset() throws {
        try ensureEngineReady()
        let root = try loadFixture("candle_patterns")
        guard let series = root["series"] as? [[String: Any]],
              let expected = root["expected"] as? [String: [String: Any]],
              let file = series.first?["file"] as? String else {
            XCTFail("fixture 缺 series / expected / file")
            return
        }

        // ① 缺省调用（仅 op + series）
        let defaults = try callDetect(["op": "detect", "series": series])
        guard let gotDefault = defaults[file] as? [String: Any] else {
            XCTFail("缺省调用输出缺序列 \(file)")
            return
        }
        XCTAssertEqual(Set(gotDefault.keys), Set((expected[file] ?? [:]).keys),
            "缺省调用应返回全部形态")
        for (pattern, expArr) in expected[file] ?? [:] {
            XCTAssertEqual(expectedInts(gotDefault[pattern]) ?? [], expectedInts(expArr) ?? [],
                "\(file)/\(pattern) 缺省调用与 golden 不一致")
        }

        // ② 子集调用（engulfing / doji）
        let subset = try callDetect(["op": "detect", "series": series,
                                     "patterns": ["engulfing", "doji"]])
        guard let gotSubset = subset[file] as? [String: Any] else {
            XCTFail("子集调用输出缺序列 \(file)")
            return
        }
        XCTAssertEqual(Set(gotSubset.keys), Set(["engulfing", "doji"]), "子集调用应只返回请求的形态")
        for pattern in ["engulfing", "doji"] {
            XCTAssertEqual(expectedInts(gotSubset[pattern]) ?? [],
                           expectedInts(expected[file]?[pattern]) ?? [],
                           "\(file)/\(pattern) 子集调用与 golden 不一致")
        }
    }
}

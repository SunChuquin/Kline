//
//  PyBridgeMyTTFunctionTests.swift
//  KlineTests
//
//  桥接契约测试⑥：MyTT 函数库 —— Python 引擎 mytt.py（numpy 垫片版）
//  经 KlinePythonBridge 调用（op="functions"），结果 vs pandas 2.2.3 原版
//  MyTT 产出的 golden。
//
//  契约来源：.trae/documents/python-engine/Python引擎下沉可行性分析.md §3.2
//  候选 2（公式引擎解析层+函数库下沉，阶段 A：MyTT + pandas API numpy 垫片）。
//  golden 为 scripts/verify_mytt_shim.py --fixture 产出的
//  KlineTests/Fixtures/mytt_functions.json（expected 取自 scripts/vendor/
//  MyTT_pandas.py 在 pandas 2.2.3 下的输出；垫片与原版 PC 差分 38701 点
//  零差异——NaN 位置与数值逐位一致，含 RD 四舍五入边界与 α=0.5 分歧哨兵）。
//
//  数值口径：垫片 rolling/ewm 为 pandas Cython 直译的纯标量运算
//  （IEEE 确定性，期望逐位一致）；唯一非确定路径是 SLOPE/FORCAST 的
//  np.polyfit（LAPACK，跨平台 ulp 级差异），故统一取绝对容差 1e-9。
//  bool 输出经 doubleValue 数值化对比（true=1/false=0，错配必超容差）；
//  NaN 位（null）双侧精确一致。
//
//  skip 语义（对齐 PyBridgeCandlePatternTests）：
//  - 引擎未就绪（无引擎构建 / KLINE_SKIP_ENGINE_EMBED=1）→ ensureReady 失败 → XCTSkip；
//  - 引擎就绪但 numpy 未安装（旧引擎缓存）→ script error 文本含 "numpy" → XCTSkip；
//  - 其余（输出不符等）→ 真 fail。
//

import XCTest
@testable import Kline

final class PyBridgeMyTTFunctionTests: XCTestCase {

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

    /// 异步 call mytt（timeout 30s）；引擎已就绪后 call 失败属真实缺陷 → XCTFail，
    /// 唯一例外：错误文本含 "numpy"（旧引擎缓存未内嵌 numpy）→ XCTSkip。
    private func callMytt(_ input: [String: Any]) throws -> [String: Any] {
        let exp = expectation(description: "KlinePythonBridge.call mytt")
        var boxed: Result<Data, PyBridgeError>?
        KlinePythonBridge.shared.call(script: "mytt", input: input, timeout: 30) { r in
            boxed = r
            exp.fulfill()
        }
        wait(for: [exp], timeout: 35)
        guard let result = boxed else {
            throw NSError(domain: "KlinePyBridgeTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "mytt bridge call 未在超时前回调"])
        }
        switch result {
        case .success(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["result"] as? [String: Any] else {
                XCTFail("mytt 输出缺 result 对象（\(data.count) bytes）")
                throw NSError(domain: "KlinePyBridgeTests", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "mytt bad result payload"])
            }
            return payload
        case .failure(let e):
            let text = String(describing: e)
            if text.contains("numpy") {
                throw XCTSkip("引擎内 numpy 未安装（旧引擎缓存 / 旧 Engine.app；mytt.py 依赖 numpy）"
                    + "——script error: \(text)")
            }
            XCTFail("mytt bridge call 失败：\(e)")
            throw NSError(domain: "KlinePyBridgeTests", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "mytt bridge call failed"])
        }
    }

    // MARK: - 函数库批量求值 vs golden（pandas 2.2.3 原版 MyTT）

    func testPyBridgeMyTTFunctionsMatchGolden() throws {
        try ensureEngineReady()
        let root = try loadFixture("mytt_functions")
        guard let series = root["series"] as? [String: Any],
              let calls = root["calls"] as? [[String: Any]],
              let expected = root["expected"] as? [[String: Any]] else {
            XCTFail("fixture 缺 series/calls/expected（fixture: mytt_functions.json）")
            return
        }
        let result = try callMytt(["op": "functions", "series": series, "calls": calls])
        guard let results = result["results"] as? [[String: Any]] else {
            XCTFail("输出缺 results 数组（mytt op=functions）")
            return
        }
        XCTAssertEqual(results.count, expected.count,
            "call 数：golden=\(expected.count) python=\(results.count)（fixture: mytt_functions.json）")

        for (k, exp) in expected.enumerated() where k < results.count {
            let got = results[k]
            let fn = exp["fn"] as? String ?? "?"
            XCTAssertEqual(got["fn"] as? String, fn,
                "calls[\(k)] 函数名不一致（fixture: mytt_functions.json → expected[\(k)].fn）")
            guard let gOuts = got["outputs"] as? [Any],
                  let eOuts = exp["outputs"] as? [Any] else {
                XCTFail("[\(fn)] outputs 缺失（fixture: mytt_functions.json → expected[\(k)]）")
                continue
            }
            if gOuts.count != eOuts.count {
                XCTFail("[\(fn)] 输出列数：golden=\(eOuts.count) python=\(gOuts.count)（fixture: mytt_functions.json → expected[\(k)]）")
                continue
            }
            for (ci, eo) in eOuts.enumerated() {
                // RET 等函数输出为标量（非数组）——统一包成单元素数组对齐（PC 差分同口径）
                let eWrapped = (eo as? [Any]) ?? [eo]
                let gRaw = gOuts[ci]
                let gWrapped = (gRaw as? [Any]) ?? [gRaw]
                let ea = eWrapped, ga = gWrapped
                if ga.count != ea.count {
                    XCTFail("[\(fn)#\(ci)] 长度：golden=\(ea.count) python=\(ga.count)（fixture: mytt_functions.json → expected[\(k)].outputs[\(ci)]）")
                    continue
                }
                var mismatch: String?
                for (i, ev) in ea.enumerated() {
                    let gv = ga[i]
                    // NaN 位（null）双侧精确一致
                    if ev is NSNull || gv is NSNull {
                        if (ev is NSNull) != (gv is NSNull) {
                            mismatch = "[\(i)] NaN 位不一致: golden=\(ev is NSNull ? "NaN" : "\(ev)") python=\(gv is NSNull ? "NaN" : "\(gv)")"
                            break
                        }
                        continue
                    }
                    guard let en = ev as? NSNumber, let gn = gv as? NSNumber else {
                        mismatch = "[\(i)] 非数值: golden=\(ev) python=\(gv)"
                        break
                    }
                    // bool 经 doubleValue 数值化（true=1/false=0，错配必超容差）
                    let gd = gn.doubleValue, ed = en.doubleValue
                    if gd.isNaN != ed.isNaN || abs(gd - ed) > 1e-9 {
                        mismatch = "[\(i)] golden=\(ed) python=\(gd)（容差 1e-9；SLOPE/FORCAST 的 polyfit 为 LAPACK 路径允许 ulp 级差异）"
                        break
                    }
                }
                if let m = mismatch {
                    XCTFail("[\(fn)#\(ci)]\(m)（fixture: mytt_functions.json → expected[\(k)].outputs[\(ci)]）")
                }
            }
        }
    }
}

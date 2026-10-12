//
//  PyBridgeChanTests.swift
//  KlineTests
//
//  桥接契约测试⑦：缠论 K 线聚合 —— Python 引擎 chan.py（chan.py 语义移植版）
//  经 KlinePythonBridge 调用（op="chan"），结果 vs chan.py 原版产出的 golden。
//
//  契约来源：.trae/documents/python-engine/Python引擎下沉可行性分析.md
//  候选 15（缠论 K 线聚合扩展：合并 → 分型 → 笔，参考开源 chan.py）。
//  golden 为 scripts/verify_chan.py --fixture 产出的
//  KlineTests/Fixtures/chan_bi.json（expected 取自 chan.py 原版
//  CChanConfig({}) + trigger_step=False 默认配置的输出；移植版与原版
//  PC 差分 6 语料全字段精确一致——注意 CChanConfig 层默认
//  bi_fx_check="strict"、gap_as_kl=False，与 CBiConfig 类自身默认不同）。
//
//  数值口径：chan 聚合的输出数值均为 bar 原值传递（无浮点运算，仅比较
//  与传递），JSON 往返无损 → 逐字段精确对比（doubleValue 相等）。
//
//  skip 语义（对齐 PyBridgeMyTTFunctionTests）：
//  - 引擎未就绪（无引擎构建 / KLINE_SKIP_ENGINE_EMBED=1）→ ensureReady 失败 → XCTSkip；
//  - 引擎就绪后 call 失败 / 输出不符 → 真 fail（chan.py 纯标准库，无 numpy 降级例外）。
//

import XCTest
@testable import Kline

final class PyBridgeChanTests: XCTestCase {

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

    /// 异步 call chan（timeout 30s）；引擎已就绪后 call 失败属真实缺陷 → XCTFail
    /// （chan.py 纯标准库零依赖，无 numpy 旧缓存例外）。
    private func callChan(_ input: [String: Any]) throws -> [String: Any] {
        let exp = expectation(description: "KlinePythonBridge.call chan")
        var boxed: Result<Data, PyBridgeError>?
        KlinePythonBridge.shared.call(script: "chan", input: input, timeout: 30) { r in
            boxed = r
            exp.fulfill()
        }
        wait(for: [exp], timeout: 35)
        guard let result = boxed else {
            throw NSError(domain: "KlinePyBridgeTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "chan bridge call 未在超时前回调"])
        }
        switch result {
        case .success(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["result"] as? [String: Any] else {
                XCTFail("chan 输出缺 result 对象（\(data.count) bytes）")
                throw NSError(domain: "KlinePyBridgeTests", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "chan bad result payload"])
            }
            return payload
        case .failure(let e):
            XCTFail("chan bridge call 失败：\(e)")
            throw NSError(domain: "KlinePyBridgeTests", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "chan bridge call failed"])
        }
    }

    // MARK: - 字段精确对比（数值为 bar 原值传递，doubleValue 相等）

    /// 逐字段对比 golden 与引擎输出；不一致返回首个差异描述（nil=一致）。
    private func firstMismatch(got: [[String: Any]], expected: [[String: Any]],
                               corpus: String, key: String) -> String? {
        if got.count != expected.count {
            return "\(corpus).\(key) 数量不一致: golden=\(expected.count) python=\(got.count)"
        }
        let fields = expected.first?.keys.sorted() ?? []
        for i in 0..<expected.count {
            for f in fields {
                let ev = expected[i][f]
                let gv = got[i][f]
                if let en = ev as? NSNumber, let gn = gv as? NSNumber {
                    if en.doubleValue != gn.doubleValue {
                        return "\(corpus).\(key)[\(i)].\(f): golden=\(ev) python=\(gv)"
                    }
                } else if !(ev is NSNull) || !(gv is NSNull) {
                    let eIsNull = ev is NSNull, gIsNull = gv is NSNull
                    if eIsNull != gIsNull {
                        return "\(corpus).\(key)[\(i)].\(f): null 位不一致 golden=\(ev) python=\(gv)"
                    }
                    if String(describing: ev) != String(describing: gv) {
                        return "\(corpus).\(key)[\(i)].\(f): golden=\(ev) python=\(gv)"
                    }
                }
            }
        }
        return nil
    }

    // MARK: - 缠论聚合 vs golden（chan.py 原版，CChanConfig 默认配置）

    func testPyBridgeChanMatchGolden() throws {
        try ensureEngineReady()
        let root = try loadFixture("chan_bi")
        for (corpus, item) in root.sorted(by: { $0.key < $1.key }) {
            guard let bars = (item as? [String: Any])?["bars"] as? [[Any]],
                  let expected = (item as? [String: Any])?["expected"] as? [String: Any],
                  let eKlc = expected["klc"] as? [[String: Any]],
                  let eBi = expected["bi"] as? [[String: Any]] else {
                XCTFail("fixture[\(corpus)] 缺 bars/expected/klc/bi（fixture: chan_bi.json）")
                continue
            }
            let result = try callChan(["op": "chan", "bars": bars])
            guard let gKlc = result["klc"] as? [[String: Any]],
                  let gBi = result["bi"] as? [[String: Any]] else {
                XCTFail("[\(corpus)] 输出缺 klc/bi 数组（op=chan）")
                continue
            }
            if let m = firstMismatch(got: gKlc, expected: eKlc, corpus: corpus, key: "klc") {
                XCTFail("合并K线不一致：\(m)（fixture: chan_bi.json → \(corpus).expected.klc）")
            }
            if let m = firstMismatch(got: gBi, expected: eBi, corpus: corpus, key: "bi") {
                XCTFail("笔不一致：\(m)（fixture: chan_bi.json → \(corpus).expected.bi）")
            }
        }
    }

    // MARK: - 输入校验（非法 bars 报错而非崩溃）

    func testPyBridgeChanInputValidation() throws {
        try ensureEngineReady()
        let badCases: [(String, [String: Any])] = [
            ("bars 非数组", ["op": "chan", "bars": "x"]),
            ("bars 空数组", ["op": "chan", "bars": [[Any]]()]),
            ("元素不足5列", ["op": "chan", "bars": [[20240101, 10.0, 11.0, 9.5]]]),
            ("low 越过 open", ["op": "chan", "bars": [[20240101, 10.0, 11.0, 10.5, 10.2]]]),
        ]
        for (label, input) in badCases {
            let exp = expectation(description: "KlinePythonBridge.call chan bad input")
            var boxed: Result<Data, PyBridgeError>?
            KlinePythonBridge.shared.call(script: "chan", input: input, timeout: 30) { r in
                boxed = r
                exp.fulfill()
            }
            wait(for: [exp], timeout: 35)
            guard let result = boxed else {
                XCTFail("[\(label)] call 未在超时前回调")
                continue
            }
            switch result {
            case .success(let data):
                // 成功仅当 ok=false 的业务错误（脚本契约），ok=true 则为漏检
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if obj?["ok"] as? Bool == true {
                    XCTFail("[\(label)] 应被拒收却返回 ok=true")
                }
            case .failure:
                break  // 桥接层错误（脚本抛错）同样视为正确拒收
            }
        }
    }
}

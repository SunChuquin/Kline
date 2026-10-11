//
//  PyBridgeQuoteParsingTests.swift
//  KlineTests
//
//  桥接契约测试⑤：多源取数口径解析 —— Python 引擎 quote_parse.py 经
//  KlinePythonBridge 调用，四个 op（em_snapshot / tencent_kline / calibrate /
//  secid）结果 vs 既有 golden（与 QuoteParsingContractTests 同一 fixture，
//  纯标准库脚本，无 numpy 依赖）。
//
//  契约来源：.trae/documents/python-engine/Python引擎下沉可行性分析.md 候选 4
//  （多源取数口径下沉，阶段 A：口径层下沉、网络层留 Swift）。
//  golden 为 src/contract_golden.py 产出的 KlineTests/Fixtures/quote_parsing.json
//  与 secid_mapping.json（样本为 2026-10-04 真实抓包常量内置，离线确定）；
//  PC 侧 quote_parse.py 四 op 已对该 fixture 差分零差异（内联驱动验证）。
//
//  数值口径（对齐 QuoteParsingContractTests）：价格容差 1e-6；vol/amo 单值直传
//  精确相等；date / tradeDate / outcome 精确相等；calibrate 的 expectedReject
//  ↔ anomaly 分支总映射。
//
//  skip 语义（对齐 PyBridgePeriodAggregationTests）：
//  - 引擎未就绪（无引擎构建 / KLINE_SKIP_ENGINE_EMBED=1）→ ensureReady 失败 → XCTSkip；
//  - 引擎就绪后 call 失败属真实缺陷 → 真 fail（quote_parse.py 仅标准库，
//    不存在「旧引擎缓存缺 numpy」类环境性 skip）。
//

import XCTest
@testable import Kline

final class PyBridgeQuoteParsingTests: XCTestCase {

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
    private func boolVal(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
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

    /// 异步 call quote_parse（timeout 30s）；引擎已就绪后 call 失败属真实缺陷 → XCTFail。
    private func callQuoteParse(_ input: [String: Any]) throws -> [String: Any] {
        let exp = expectation(description: "KlinePythonBridge.call quote_parse")
        var boxed: Result<Data, PyBridgeError>?
        KlinePythonBridge.shared.call(script: "quote_parse", input: input, timeout: 30) { r in
            boxed = r
            exp.fulfill()
        }
        wait(for: [exp], timeout: 35)
        guard let result = boxed else {
            throw NSError(domain: "KlinePyBridgeTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "quote_parse bridge call 未在超时前回调"])
        }
        switch result {
        case .success(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["result"] as? [String: Any] else {
                XCTFail("quote_parse 输出缺 result 对象（\(data.count) bytes）")
                throw NSError(domain: "KlinePyBridgeTests", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "quote_parse bad result payload"])
            }
            return payload
        case .failure(let e):
            XCTFail("quote_parse bridge call 失败：\(e)")
            throw NSError(domain: "KlinePyBridgeTests", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "quote_parse bridge call failed"])
        }
    }

    // MARK: - ① 东财批量快照（f17开/f15高/f16低/f2收/f5量/f6额/f124→tradeDate）

    func testPyBridgeEmSnapshotMatchesGolden() throws {
        try ensureEngineReady()
        let root = try loadFixture("quote_parsing")
        guard let em = root["eastmoneySnapshot"] as? [String: Any],
              let raw = em["raw"] as? String,
              let golden = em["golden"] as? [[String: Any]] else {
            XCTFail("fixture 缺 eastmoneySnapshot.raw/golden（fixture: quote_parsing.json）")
            return
        }
        let result = try callQuoteParse(["op": "em_snapshot", "raw": raw])
        XCTAssertEqual(result.count, golden.count,
            "标的数：golden=\(golden.count) python=\(result.count)"
            + "（fixture: quote_parsing.json → eastmoneySnapshot.golden）")
        for g in golden {
            guard let secid = g["secid"] as? String else {
                XCTFail("golden 缺 secid（fixture: quote_parsing.json → eastmoneySnapshot.golden）")
                continue
            }
            let key = "quote_parsing.json → eastmoneySnapshot.golden(secid=\(secid))"
            guard let snap = result[secid] as? [String: Any] else {
                XCTFail("输出缺 secid=\(secid)（fixture: \(key)）")
                continue
            }
            let fields: [(String, Double?, Double?)] = [
                ("open", num(g["open"]), num(snap["open"])),
                ("high", num(g["high"]), num(snap["high"])),
                ("low", num(g["low"]), num(snap["low"])),
                ("close", num(g["close"]), num(snap["close"])),
                ("vol", num(g["vol"]), num(snap["vol"])),
                ("amo", num(g["amo"]), num(snap["amo"])),
            ]
            for (field, gv, pv) in fields {
                guard let gvv = gv, let pvv = pv else {
                    XCTFail("[em:\(secid)] \(field)：golden=\(String(describing: gv)) python=\(String(describing: pv))（fixture: \(key).\(field)）")
                    continue
                }
                XCTAssertEqual(pvv, gvv, accuracy: 1e-6,
                    "[em:\(secid)] \(field)：golden=\(gvv) python=\(pvv)（fixture: \(key).\(field)；容差 1e-6）")
            }
            XCTAssertEqual(intVal(snap["tradeDate"]) ?? -1, intVal(g["tradeDate"]) ?? -1,
                "[em:\(secid)] tradeDate：golden=\(String(describing: g["tradeDate"])) python=\(String(describing: snap["tradeDate"]))（f124 按 UTC+8 换算；fixture: \(key).tradeDate）")
        }
    }

    // MARK: - ② 腾讯 newfqkline（⚠️ 价格顺序 开-收-高-低）

    func testPyBridgeTencentKlineMatchesGolden() throws {
        try ensureEngineReady()
        let root = try loadFixture("quote_parsing")
        guard let list = root["tencentKline"] as? [[String: Any]] else {
            XCTFail("fixture 缺 tencentKline（fixture: quote_parsing.json）")
            return
        }
        for item in list {
            guard let market = item["marketCode"] as? String,
                  let raw = item["raw"] as? String,
                  let golden = item["golden"] as? [[String: Any]] else {
                XCTFail("fixture 缺 tencentKline[].marketCode/raw/golden（fixture: quote_parsing.json）")
                continue
            }
            let result = try callQuoteParse(["op": "tencent_kline",
                                             "raw": raw, "marketCode": market])
            guard let rows = result["rows"] as? [[String: Any]] else {
                XCTFail("[\(market)] 输出缺 rows（quote_parse op=tencent_kline）")
                continue
            }
            XCTAssertEqual(rows.count, golden.count,
                "[\(market)] 行数：golden=\(golden.count) python=\(rows.count)（fixture: quote_parsing.json → tencentKline[\(market)]）")
            for (i, g) in golden.enumerated() where i < rows.count {
                let b = rows[i]
                let key = "quote_parsing.json → tencentKline[\(market)].golden[\(i)]"
                XCTAssertEqual(intVal(b["date"]) ?? -1, intVal(g["date"]) ?? -1,
                    "[\(market)]#\(i).date：golden=\(String(describing: g["date"])) python=\(String(describing: b["date"]))（fixture: \(key).date）")
                // ⚠️ 腾讯 wire 价格顺序 开-收-高-低（与东财快照不同），脚本已换算到字段名
                let priceFields: [(String, String, Int)] = [
                    ("open", "open", 1), ("close", "close", 2),
                    ("high", "high", 3), ("low", "low", 4),
                ]
                for (field, pyKey, wireIdx) in priceFields {
                    XCTAssertEqual(num(b[pyKey]) ?? .nan, num(g[field]) ?? .nan, accuracy: 1e-6,
                        "[\(market)]#\(i).\(field)：golden=\(String(describing: g[field])) python=\(String(describing: b[pyKey]))（wire r[\(wireIdx)]；fixture: \(key).\(field)；容差 1e-6）")
                }
                XCTAssertEqual(num(b["vol"]) ?? -1, num(g["vol"]) ?? -1,
                    "[\(market)]#\(i).vol(手)：golden=\(String(describing: g["vol"])) python=\(String(describing: b["vol"]))（r[5]=量(手)；fixture: \(key).vol；精确相等）")
                XCTAssertEqual(num(b["amo"]) ?? -1, num(g["amo"]) ?? -1,
                    "[\(market)]#\(i).amo(万元)：golden=\(String(describing: g["amo"])) python=\(String(describing: b["amo"]))（r[8]=额(万元)；fixture: \(key).amo；精确相等）")
            }
        }
    }

    // MARK: - ③ 自校准 calibrate（价格 → 量比吸附 → 额比哨兵 → 缺口行折算）

    func testPyBridgeCalibrateMatchesGolden() throws {
        try ensureEngineReady()
        let root = try loadFixture("quote_parsing")
        guard let cases = root["calibration"] as? [[String: Any]] else {
            XCTFail("fixture 缺 calibration（fixture: quote_parsing.json → calibration）")
            return
        }
        XCTAssertFalse(cases.isEmpty, "fixture calibration 不应为空")
        for c in cases {
            guard let name = c["caseName"] as? String,
                  let mainLatest = intVal(c["mainLatest"]),
                  let wireRows = c["sourceRows"] as? [[Any]],
                  let golden = c["golden"] as? [String: Any],
                  let goldenOutcome = golden["outcome"] as? String else {
                XCTFail("calibration 用例字段缺失（需 caseName/mainLatest/sourceRows/golden.outcome）")
                continue
            }
            let key = "quote_parsing.json → calibration[\(name)]"
            let result = try callQuoteParse([
                "op": "calibrate",
                "base": c["base"] ?? [:],
                "sourceRows": wireRows,
                "mainLatest": mainLatest,
            ])
            let outcome = result["outcome"] as? String ?? "(缺 outcome)"
            XCTAssertEqual(outcome, goldenOutcome,
                "[\(name)] outcome：golden=\(goldenOutcome) python=\(outcome)（fixture: \(key).golden.outcome）")
            let expectedReject = boolVal(golden["expectedReject"]) ?? false
            var isAnomaly = false
            if outcome == "anomaly" { isAnomaly = true }
            XCTAssertEqual(isAnomaly, expectedReject,
                "[\(name)] expectedReject：golden=\(expectedReject) python outcome=\(outcome)（fixture: \(key).golden.expectedReject）")
            if goldenOutcome == "gap" {
                XCTAssertEqual(boolVal(result["priceOnly"]) ?? false, boolVal(golden["priceOnly"]) ?? false,
                    "[\(name)] priceOnly（fixture: \(key).golden.priceOnly）")
                XCTAssertEqual(num(result["volRatio"]) ?? -1, num(golden["volRatio"]) ?? -1, accuracy: 1e-12,
                    "[\(name)] volRatio 吸附值：golden=\(String(describing: golden["volRatio"])) python=\(String(describing: result["volRatio"]))（fixture: \(key).golden.volRatio）")
                let goldenBars = (golden["bars"] as? [[String: Any]]) ?? []
                let gotBars = (result["bars"] as? [[String: Any]]) ?? []
                XCTAssertEqual(gotBars.count, goldenBars.count,
                    "[\(name)] 缺口行数：golden=\(goldenBars.count) python=\(gotBars.count)（fixture: \(key).golden.bars）")
                for (i, gb) in goldenBars.enumerated() where i < gotBars.count {
                    let b = gotBars[i]
                    let bkey = "\(key).golden.bars[\(i)]"
                    XCTAssertEqual(intVal(b["date"]) ?? -1, intVal(gb["date"]) ?? -1,
                        "[\(name)] bars[\(i)].date（fixture: \(bkey).date）")
                    for f in ["open", "high", "low", "close"] {
                        XCTAssertEqual(num(b[f]) ?? .nan, num(gb[f]) ?? .nan, accuracy: 1e-6,
                            "[\(name)] bars[\(i)].\(f)：golden=\(String(describing: gb[f])) python=\(String(describing: b[f]))（fixture: \(bkey).\(f)；容差 1e-6）")
                    }
                    XCTAssertEqual(num(b["vol"]) ?? -1, num(gb["vol"]) ?? -1,
                        "[\(name)] bars[\(i)].vol：golden=\(String(describing: gb["vol"])) python=\(String(describing: b["vol"]))（vol=源(手)×volRatio 折算；fixture: \(bkey).vol；精确相等）")
                    XCTAssertEqual(num(b["amo"]) ?? -1, num(gb["amo"]) ?? -1,
                        "[\(name)] bars[\(i)].amo：golden=\(String(describing: gb["amo"])) python=\(String(describing: b["amo"]))（amo=源(万元)×amoScale 折算；fixture: \(bkey).amo；精确相等）")
                }
            }
            if goldenOutcome == "anomaly", let reason = golden["reason"] as? String {
                let gotReason = result["reason"] as? String ?? "(缺 reason)"
                XCTAssertTrue(gotReason.hasPrefix(String(reason.prefix(4))),
                    "[\(name)] anomaly 原因前缀：golden=\(reason) python=\(gotReason)（fixture: \(key).golden.reason）")
            }
        }
    }

    // MARK: - ④ file → secid 映射（PC 权威口径：特例表 → 前缀规则；扩展前缀 → null）

    func testPyBridgeSecidMatchesGolden() throws {
        try ensureEngineReady()
        let root = try loadFixture("secid_mapping")
        guard let entries = root["entries"] as? [[String: Any]] else {
            XCTFail("fixture 缺 entries（fixture: secid_mapping.json）")
            return
        }
        var files: [String] = []
        for e in entries {
            if let f = e["file"] as? String { files.append(f) }
        }
        XCTAssertFalse(files.isEmpty, "fixture entries 不应为空")
        let result = try callQuoteParse(["op": "secid", "files": files])
        for (i, e) in entries.enumerated() {
            guard let file = e["file"] as? String else { continue }
            let rule = (e["rule"] as? String) ?? "-"
            let expected = e["secid"] as? String   // JSON null → nil（rule=override 的有意分工）
            let got = result[file] as? String
            XCTAssertEqual(got ?? "", expected ?? "",
                "[secid] rule=\(rule) file=\(file)：golden=\(String(describing: expected)) python=\(String(describing: got))（fixture: secid_mapping.json → entries[\(i)]；null 属 PC/设备有意分工）")
        }
    }
}

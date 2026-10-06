//
//  PyBridgeTemplateParseTests.swift
//  KlineTests
//
//  桥接契约测试②：指标模板（.tdx）解析 —— Python 引擎 template_parse.py
//  经 KlinePythonBridge 调用，结果 vs PC 侧 golden。
//
//  契约来源：.trae/specs/add-python-offload-pilot/spec.md 桥接链路
//  （Swift 测试 → KlinePythonBridge.shared.call → PythonEngineHost.PyRun →
//  Bundle.main/PyScripts/template_parse.py）；golden 为 src/contract_golden.py
//  产出的 KlineTests/Fixtures/indicator_templates.json（与
//  IndicatorTemplateContractTests.swift 同一 fixture、同一解析口径）。
//
//  调用方式：corpus 每份 .tdx 按 loadTemplateContent 从测试 bundle / 主 App bundle
//  （Indicators/ 子目录 → 根目录）读取原文（与生产 loadAllPeriods 同源），
//  items = [{id: 去扩展名文件名, content: 原文}]，整批一次 bridge 异步 call（timeout 30s）；
//  输出 result 与输入 items 顺序/条数一致（脚本契约：拒载条目也在 result 里，
//  accepted=false，其余字段 null/默认）。测试一律用异步 call + XCTestExpectation。
//
//  断言口径：accepted 与 golden swiftExpected 一致；accepted=true 时
//  name/scope/group/formulaTemplate 逐字段一致（golden 无 coord 字段，不比对；
//  scope golden 取值为 "main"/"sub"）。
//
//  内嵌负控（非 fixture 数据，口径见 fixture notes）：出现 KIND= 且取值非 TECH
//  （PICKER/STRATEGY）→ accepted=false；KIND=TECH → accepted=true；
//  无 FORMULA 区（template 为空）→ accepted=false。
//
//  skip 语义：引擎未就绪（KLINE_SKIP_ENGINE_EMBED=1 / 无 EngineCache 等无引擎构建）
//  时 ensureReady 失败 → XCTSkip 而非 fail——无引擎构建验证的是纯 Swift 降级路径，
//  本测试只负责「引擎可用时全绿」。
//

import XCTest
@testable import Kline

final class PyBridgeTemplateParseTests: XCTestCase {

    // MARK: - 资源读取（fixtures：Fixtures/ 子目录优先；.tdx：测试 bundle → 主 App bundle）

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

    /// .tdx 原文：测试 bundle 优先，退回主 App bundle（Indicators/ 子目录 → 根目录），
    /// 与生产 copyBuiltin/builtinContent 的两种打包布局兼容（同 IndicatorTemplateContractTests）。
    private func loadTemplateContent(_ fileName: String) -> String? {
        let stem = (fileName as NSString).deletingPathExtension
        let testBundle = Bundle(for: Self.self)
        var url = testBundle.url(forResource: stem, withExtension: "tdx", subdirectory: "Indicators")
        if url == nil { url = testBundle.url(forResource: stem, withExtension: "tdx") }
        if url == nil { url = Bundle.main.url(forResource: stem, withExtension: "tdx", subdirectory: "Indicators") }
        if url == nil { url = Bundle.main.url(forResource: stem, withExtension: "tdx") }
        guard let resolved = url else { return nil }
        return try? String(contentsOf: resolved, encoding: .utf8)
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

    /// 异步 call template_parse.py（timeout 30s），items 整批送入；
    /// 返回 result 数组（顺序与输入 items 一致）。引擎已就绪后 call 失败属真实缺陷 → XCTFail。
    private func callItems(_ items: [[String: Any]]) throws -> [[String: Any]] {
        let exp = expectation(description: "KlinePythonBridge.call template_parse")
        var boxed: Result<Data, PyBridgeError>?
        KlinePythonBridge.shared.call(script: "template_parse", input: ["items": items],
                                      timeout: 30) { r in
            boxed = r
            exp.fulfill()
        }
        wait(for: [exp], timeout: 35)
        guard let result = boxed else {
            throw NSError(domain: "KlinePyBridgeTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "template_parse bridge call 未在超时前回调"])
        }
        switch result {
        case .success(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["result"] as? [[String: Any]] else {
                XCTFail("template_parse 输出缺 result 数组（\(data.count) bytes；bridge 契约：顶层 dict 且 ok=true，payload 在 result 字段）")
                throw NSError(domain: "KlinePyBridgeTests", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "template_parse bad result payload"])
            }
            return payload
        case .failure(let e):
            XCTFail("template_parse bridge call 失败：\(e)")
            throw NSError(domain: "KlinePyBridgeTests", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "template_parse bridge call failed"])
        }
    }

    // MARK: - corpus：31 份 .tdx 整批一次 call，逐条对齐 golden

    func testCorpusTemplatesMatchGolden() throws {
        try ensureEngineReady()
        let root = try loadFixture("indicator_templates")
        guard let templates = root["templates"] as? [[String: Any]] else {
            XCTFail("fixture 缺 templates（fixture: indicator_templates.json）")
            return
        }
        XCTAssertFalse(templates.isEmpty,
            "fixture templates 不应为空（fixture: indicator_templates.json → templates）")
        var items: [[String: Any]] = []
        var meta: [(id: String, fileName: String, golden: [String: Any])] = []
        for (i, t) in templates.enumerated() {
            guard let fileName = t["fileName"] as? String else {
                XCTFail("templates[\(i)] 缺 fileName（fixture: indicator_templates.json → templates[\(i)]）")
                continue
            }
            let id = (fileName as NSString).deletingPathExtension
            guard let content = loadTemplateContent(fileName) else {
                XCTFail("[\(fileName)] .tdx 原文读取失败（测试 bundle 与主 App bundle 的 Indicators/ 子目录、根目录均未找到）"
                    + "（fixture: indicator_templates.json → templates[\(i)]）")
                continue
            }
            items.append(["id": id, "content": content])
            meta.append((id, fileName, t))
        }
        XCTAssertGreaterThan(items.count, 0,
            "没有收集到任何 .tdx 条目（fixture: indicator_templates.json → templates[].fileName）")
        let rows = try callItems(items)
        XCTAssertEqual(rows.count, items.count,
            "输出条数须与输入 items 一致：items=\(items.count) result=\(rows.count)"
            + "（bridge: template_parse.py 契约——result 与 items 同序同条数，拒载条目也在 result 里）")
        for (i, m) in meta.enumerated() where i < rows.count {
            let row = rows[i]
            let key = "indicator_templates.json → templates（\(m.fileName)）"
            XCTAssertEqual(row["id"] as? String, m.id,
                "[\(m.fileName)] result[\(i)].id：golden=\(m.id) python=\(String(describing: row["id"]))"
                + "（\(key)；输出顺序须与输入 items 一致）")
            let expectedAccepted = (m.golden["swiftExpected"] as? String) == "accepted"
            XCTAssertEqual(row["accepted"] as? Bool, expectedAccepted,
                "[\(m.fileName)] accepted：golden=\(expectedAccepted) python=\(String(describing: row["accepted"]))"
                + "（\(key).swiftExpected）")
            guard expectedAccepted else { continue }
            // accepted=true：name/scope/group/formulaTemplate 逐字段一致（golden 无 coord 字段，不比对）
            XCTAssertEqual(row["name"] as? String, m.golden["name"] as? String ?? "",
                "[\(m.fileName)] name：golden=\(String(describing: m.golden["name"])) python=\(String(describing: row["name"]))"
                + "（\(key).name）")
            XCTAssertEqual(row["scope"] as? String, m.golden["scope"] as? String ?? "",
                "[\(m.fileName)] scope：golden=\(String(describing: m.golden["scope"])) python=\(String(describing: row["scope"]))"
                + "（\(key).scope；golden 取值 main/sub）")
            XCTAssertEqual(row["group"] as? String, m.golden["group"] as? String ?? "",
                "[\(m.fileName)] group：golden=\(String(describing: m.golden["group"])) python=\(String(describing: row["group"]))"
                + "（\(key).group）")
            XCTAssertEqual(row["formulaTemplate"] as? String, m.golden["formulaTemplate"] as? String ?? "",
                "[\(m.fileName)] formulaTemplate：golden=\(String(describing: m.golden["formulaTemplate"])) python=\(String(describing: row["formulaTemplate"]))"
                + "（\(key).formulaTemplate；FORMULA: 后各行 '\\n' join）")
        }
    }

    // MARK: - 内嵌负控（非 fixture 数据，守住 rejected / 通过分支）

    /// KIND= 非 TECH（PICKER/STRATEGY）→ 拒载；KIND=TECH → 通过；无 FORMULA 区 → 拒载。
    func testNegativeControls() throws {
        try ensureEngineReady()
        let negControls: [(id: String, content: String, accepted: Bool)] = [
            ("NEG_KIND_PICKER", "KIND=PICKER\nNAME=负控\nFORMULA:\nMA(CLOSE,5);", false),
            ("NEG_KIND_STRATEGY", "KIND=STRATEGY\nNAME=负控\nFORMULA:\nMA(CLOSE,5);", false),
            ("NEG_KIND_TECH_OK", "KIND=TECH\nNAME=负控通过\nFORMULA:\nMA(CLOSE,5);", true),
            ("NEG_NO_FORMULA", "KIND=TECH\nNAME=负控无公式", false),
        ]
        let items = negControls.map { ["id": $0.id, "content": $0.content] }
        let rows = try callItems(items)
        XCTAssertEqual(rows.count, negControls.count,
            "负控输出条数须与输入一致：items=\(negControls.count) result=\(rows.count)"
            + "（bridge: template_parse.py 契约——result 与 items 同序同条数）")
        for (i, nc) in negControls.enumerated() where i < rows.count {
            let row = rows[i]
            XCTAssertEqual(row["id"] as? String, nc.id,
                "负控 result[\(i)].id：expected=\(nc.id) python=\(String(describing: row["id"]))"
                + "（输出顺序须与输入 items 一致）")
            XCTAssertEqual(row["accepted"] as? Bool, nc.accepted,
                "内嵌负控[\(nc.id)] accepted：expected=\(nc.accepted) python=\(String(describing: row["accepted"]))"
                + "（口径：indicator_templates.json → notes——KIND= 非 TECH 拒载 / KIND=TECH 通过 / 无 FORMULA 区拒载）")
        }
    }
}

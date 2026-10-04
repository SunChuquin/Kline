//
//  IndicatorTemplateContractTests.swift
//  KlineTests
//
//  契约测试③：指标模板（.tdx）解析 —— Swift SystemIndicatorStore.parse vs PC 侧 golden。
//
//  契约来源：src/contract_golden.py 产出的 KlineTests/Fixtures/indicator_templates.json
//  （fixtures 无独立版本字段，以文件内 notes 为口径说明；golden 由 check_indicators.parse_tdx
//  计算 —— 与 SystemIndicatorStore.parse 同规则：SCOPE=MAIN/主图 → main 否则 sub；
//  formulaTemplate 为 FORMULA: 后各行以 '\n' join；KIND 缺失或 TECH → accepted，
//  出现 KIND= 且非 TECH（含未知取值）→ rejected）。
//
//  被测函数：SystemIndicatorStore.shared.parse(content:id:)（private init 单例，
//  经 shared 调用；init 只做 Documents 目录初始化与内置模板同步，无网络、无 DB）。
//  .tdx 内容从测试 bundle / 主 App bundle（Indicators/ 子目录或根目录）读取，
//  读取方式与生产 SystemIndicatorStore.loadAllPeriods 一致（String(contentsOf:, .utf8)）。
//
//  覆盖说明：当前 corpus 31 份 .tdx 全部 accepted（KIND= 行缺失）、无 rejected 条目；
//  为不让 rejected 分支失守，本文件附加两条**内嵌负控**（合成内容 KIND=SELECT / 未知取值，
//  非 fixture 数据，口径见 fixture notes）断言 parse 返回 nil。
//
//  重新生成 fixtures：cd 仓库根目录 && python src/contract_golden.py
//

import XCTest
@testable import Kline

final class IndicatorTemplateContractTests: XCTestCase {

    // MARK: - 资源读取（fixtures：Fixtures/ 子目录优先；.tdx：Indicators/ 子目录优先）

    private func loadFixture(_ name: String) throws -> [String: Any] {
        let bundle = Bundle(for: Self.self)
        var url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        if url == nil { url = bundle.url(forResource: name, withExtension: "json") }
        guard let resolved = url else {
            XCTFail("fixture \(name).json 不在测试 bundle（已尝试 Fixtures/ 子目录与根目录）")
            throw NSError(domain: "KlineContractTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name).json"])
        }
        let data = try Data(contentsOf: resolved)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("fixture \(name).json 顶层不是 JSON object")
            throw NSError(domain: "KlineContractTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "bad fixture \(name).json"])
        }
        return root
    }

    /// .tdx 原文：测试 bundle 优先，退回主 App bundle（Indicators/ 子目录 → 根目录），
    /// 与生产 copyBuiltin/builtinContent 的两种打包布局兼容。
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

    // MARK: - accepted：name/scope/group/formulaTemplate 逐字段与 golden 相同

    func testAcceptedTemplatesMatchGolden() throws {
        let root = try loadFixture("indicator_templates")
        guard let templates = root["templates"] as? [[String: Any]] else {
            XCTFail("fixture 缺 templates（fixture: indicator_templates.json）")
            return
        }
        XCTAssertFalse(templates.isEmpty,
            "fixture templates 不应为空（fixture: indicator_templates.json → templates）")
        var acceptedCount = 0
        for (i, t) in templates.enumerated() {
            guard let fileName = t["fileName"] as? String,
                  let expected = t["swiftExpected"] as? String else {
                XCTFail("templates[\(i)] 缺 fileName/swiftExpected（fixture: indicator_templates.json → templates[\(i)]）")
                continue
            }
            guard expected == "accepted" else { continue }
            acceptedCount += 1
            let id = (fileName as NSString).deletingPathExtension
            let key = "indicator_templates.json → templates[\(i)](\(fileName))"
            guard let content = loadTemplateContent(fileName) else {
                XCTFail("[\(fileName)] .tdx 原文读取失败（测试 bundle 与主 App bundle 的 Indicators/ 子目录、根目录均未找到）"
                    + "（fixture: \(key)）")
                continue
            }
            guard let def = SystemIndicatorStore.shared.parse(content: content, id: id) else {
                XCTFail("[\(fileName)] golden=accepted 但 Swift parse 返回 nil（fixture: \(key).swiftExpected）")
                continue
            }
            XCTAssertEqual(def.name, t["name"] as? String ?? "",
                "[\(fileName)] name：golden=\(String(describing: t["name"])) swift=\(def.name)"
                + "（fixture: \(key).name）")
            let swiftScope = (def.scope == .main) ? "main" : "sub"
            XCTAssertEqual(swiftScope, t["scope"] as? String ?? "",
                "[\(fileName)] scope：golden=\(String(describing: t["scope"])) swift=\(swiftScope)"
                + "（fixture: \(key).scope）")
            XCTAssertEqual(def.group, t["group"] as? String ?? "",
                "[\(fileName)] group：golden=\(String(describing: t["group"])) swift=\(def.group)"
                + "（fixture: \(key).group）")
            XCTAssertEqual(def.formulaTemplate, t["formulaTemplate"] as? String ?? "",
                "[\(fileName)] formulaTemplate：golden=\(String(describing: t["formulaTemplate"])) swift=\(def.formulaTemplate)"
                + "（fixture: \(key).formulaTemplate；FORMULA: 后各行 '\\n' join）")
        }
        XCTAssertGreaterThan(acceptedCount, 0,
            "fixture 中没有任何 accepted 模板（fixture: indicator_templates.json → templates[].swiftExpected）")
    }

    // MARK: - rejected：parse 必须返回 nil（corpus 当前无 rejected 条目 → 另附内嵌负控）

    func testRejectedTemplatesReturnNil() throws {
        let root = try loadFixture("indicator_templates")
        guard let templates = root["templates"] as? [[String: Any]] else {
            XCTFail("fixture 缺 templates（fixture: indicator_templates.json）")
            return
        }
        for (i, t) in templates.enumerated() {
            guard let fileName = t["fileName"] as? String,
                  let expected = t["swiftExpected"] as? String else { continue }
            guard expected == "rejected" else { continue }
            let id = (fileName as NSString).deletingPathExtension
            guard let content = loadTemplateContent(fileName) else {
                XCTFail("[\(fileName)] .tdx 原文读取失败（fixture: indicator_templates.json → templates[\(i)]）")
                continue
            }
            XCTAssertNil(SystemIndicatorStore.shared.parse(content: content, id: id),
                "[\(fileName)] golden=rejected 但 Swift parse 通过（fixture: indicator_templates.json → templates[\(i)].swiftExpected）")
        }
        // 内嵌负控（非 fixture 数据）：corpus 当前全部 accepted，用合成内容守住 rejected 分支
        // 口径（fixture notes）：出现 KIND= 且取值非 TECH（含未知取值）→ 拒载
        let rejectSamples: [(String, String)] = [
            ("KIND=SELECT", "KIND=SELECT\nNAME=负控\nFORMULA:\nMA(CLOSE,5);"),
            ("KIND=未知值", "KIND=FOO\nNAME=负控\nFORMULA:\nMA(CLOSE,5);"),
        ]
        for (label, content) in rejectSamples {
            XCTAssertNil(SystemIndicatorStore.shared.parse(content: content, id: "NEGATIVE_CONTROL"),
                "内嵌负控[\(label)]：KIND= 非 TECH 应拒载（parse 返回 nil），实际通过了（口径: indicator_templates.json → notes）")
        }
        XCTAssertNotNil(
            SystemIndicatorStore.shared.parse(content: "KIND=TECH\nNAME=负控通过\nFORMULA:\nMA(CLOSE,5);",
                                              id: "NEGATIVE_CONTROL_OK"),
            "内嵌负控[KIND=TECH]：KIND=TECH 应通过（parse 非 nil），负控本身失效")
    }
}

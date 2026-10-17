//
//  SimRulesTrustTests.swift
//  KlineTests
//
//  阶段 A5-1：交易域信任链（《Python引擎下沉可行性分析.md》§10.9 套件 8 /
//  §9.10 降级矩阵）。
//
//  覆盖：
//    ① 三方一致：脚本 sha256 / 版本声明 ↔ Swift 编译期常量 ↔ Fixtures/sim_rules_trust.json
//    ② 真源判定：Bundle 脚本 + 内嵌引擎 manifest.apiVersion → trusted
//    ③ 篡改检测：脚本被替换 → 哈希不匹配 → untrusted（不静默降级）
//    ④ 版本锁：引擎 apiVersion 不配对 / manifest 不可读 → untrusted
//    ⑤ 降级矩阵：`.engine` 模式下 untrusted 或引擎未就绪 → 交易整体不可用
//    ⑥ 声明解析：缺声明 → nil（防止「脚本没写版本」被当成合法）
//

import XCTest
import CryptoKit
@testable import Kline

final class SimRulesTrustTests: XCTestCase {

    // MARK: - fixture

    private func loadFixture() throws -> [String: Any] {
        let bundle = Bundle(for: Self.self)
        var url = bundle.url(forResource: "sim_rules_trust", withExtension: "json",
                             subdirectory: "Fixtures")
        if url == nil { url = bundle.url(forResource: "sim_rules_trust", withExtension: "json") }
        let data = try Data(contentsOf: try XCTUnwrap(url, "Fixtures/sim_rules_trust.json 不在测试 bundle"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - ① 三方一致

    /// fixture 是测试侧真源；与 Swift 编译期常量必须逐字段相等（漂移即 fail）。
    func testTrustFixtureMatchesSwiftConstants() throws {
        let fix = try loadFixture()
        XCTAssertEqual(fix["script"] as? String, SimRulesTrust.scriptName)
        XCTAssertEqual(fix["sha256"] as? String, SimRulesTrust.expectedScriptSHA256)
        XCTAssertEqual(fix["scriptVersion"] as? Int, SimRulesTrust.scriptVersion)
        XCTAssertEqual(fix["requiredApiVersion"] as? Int, SimRulesTrust.requiredAPIVersion)
    }

    /// Bundle 内业务脚本的实际 sha256 与编译期常量（及 fixture）一致。
    func testBundledScriptHashMatchesConstant() throws {
        let data = try XCTUnwrap(SimRulesTrust.bundledScriptData(), "Bundle 内缺 PyScripts/sim_rules.py")
        let actual = sha256(data)
        XCTAssertEqual(actual, SimRulesTrust.expectedScriptSHA256)
        XCTAssertEqual(actual, try loadFixture()["sha256"] as? String)
    }

    /// 脚本声明的两处版本与 Swift 常量一致（防「改了脚本忘了同步常量」）。
    func testDeclaredVersionsMatchConstants() throws {
        let data = try XCTUnwrap(SimRulesTrust.bundledScriptData())
        let declared = try XCTUnwrap(SimRulesTrust.declaredVersions(from: data))
        XCTAssertEqual(declared.scriptVersion, SimRulesTrust.scriptVersion)
        XCTAssertEqual(declared.requiredAPIVersion, SimRulesTrust.requiredAPIVersion)
    }

    // MARK: - ② 真源判定

    /// 真实 Bundle 脚本 + 真实内嵌引擎 manifest.apiVersion → trusted。
    /// （无内嵌引擎的构建里该用例 skip——降级矩阵下交易本就禁用。）
    func testRealBundleIsTrusted() throws {
        let data = try XCTUnwrap(SimRulesTrust.bundledScriptData())
        guard let api = PythonEngineHost.shared.engineManifest()?.apiVersion else {
            throw XCTSkip("本构建无内嵌引擎 manifest——按 §9.10 交易整体禁用，跳过 trusted 断言")
        }
        XCTAssertEqual(api, SimRulesTrust.requiredAPIVersion,
                       "内嵌引擎 manifest.apiVersion 未与脚本要求的 apiVersion 配对")
        XCTAssertEqual(SimRulesTrust.evaluate(scriptData: data, engineAPIVersion: api), .trusted)
    }

    // MARK: - ③ 篡改检测

    func testTamperedScriptIsUntrusted() throws {
        var data = try XCTUnwrap(SimRulesTrust.bundledScriptData())
        data[data.count - 1] = data[data.count - 1] ^ 0x01        // 翻一位，哈希必变
        let st = SimRulesTrust.evaluate(scriptData: data,
                                        engineAPIVersion: SimRulesTrust.requiredAPIVersion)
        guard case .untrusted(let why) = st else {
            return XCTFail("篡改未被检出（应 untrusted，实得 \(st)）")
        }
        XCTAssertTrue(why.contains("哈希"), why)
    }

    func testMissingScriptIsUntrusted() {
        let st = SimRulesTrust.evaluate(scriptData: nil, engineAPIVersion: 1)
        guard case .untrusted(let why) = st else {
            return XCTFail("脚本缺失应 untrusted，实得 \(st)")
        }
        XCTAssertTrue(why.contains("缺失"), why)
    }

    // MARK: - ④ 版本锁

    func testEngineApiVersionMismatchIsUntrusted() throws {
        let data = try XCTUnwrap(SimRulesTrust.bundledScriptData())
        let st = SimRulesTrust.evaluate(scriptData: data, engineAPIVersion: 999)
        guard case .untrusted(let why) = st else {
            return XCTFail("引擎 apiVersion 不配对应 untrusted，实得 \(st)")
        }
        XCTAssertTrue(why.contains("apiVersion"), why)
    }

    func testMissingEngineManifestIsUntrusted() throws {
        let data = try XCTUnwrap(SimRulesTrust.bundledScriptData())
        let st = SimRulesTrust.evaluate(scriptData: data, engineAPIVersion: nil)
        guard case .untrusted(let why) = st else {
            return XCTFail("引擎 manifest 不可读应 untrusted，实得 \(st)")
        }
        XCTAssertTrue(why.contains("manifest"), why)
    }

    // MARK: - ⑤ 降级矩阵（§9.10）

    func testTradingGateUnderEngineMode() {
        // 过渡期：Swift 后端在，交易可用。
        XCTAssertTrue(SimRulesTrust.isTradingAvailable(mode: .swift, state: .untrusted("x"),
                                                       engineReady: false))
        // 引擎模式 + 未信任 → 整体禁用。
        XCTAssertFalse(SimRulesTrust.isTradingAvailable(mode: .engine, state: .untrusted("x"),
                                                        engineReady: true))
        // 引擎模式 + 未校验 → 整体禁用（不静默放行）。
        XCTAssertFalse(SimRulesTrust.isTradingAvailable(mode: .engine, state: .unknown,
                                                        engineReady: true))
        // 引擎模式 + 已信任但引擎未就绪 → 禁用。
        XCTAssertFalse(SimRulesTrust.isTradingAvailable(mode: .engine, state: .trusted,
                                                        engineReady: false))
        // 引擎模式 + 已信任 + 就绪 → 可用。
        XCTAssertTrue(SimRulesTrust.isTradingAvailable(mode: .engine, state: .trusted,
                                                       engineReady: true))
    }

    // MARK: - ⑥ 声明解析

    func testDeclaredVersionsParsing() {
        XCTAssertNil(SimRulesTrust.declaredVersions(from: Data("no version here".utf8)))
        // 只有脚本版本、缺 API 版本 → nil
        XCTAssertNil(SimRulesTrust.declaredVersions(
            from: Data("SIM_RULES_SCRIPT_VERSION = 1\n".utf8)))
        let ok = SimRulesTrust.declaredVersions(from: Data(
            "SIM_RULES_SCRIPT_VERSION = 2\nSIM_RULES_REQUIRED_API_VERSION = 3\n".utf8))
        XCTAssertEqual(ok?.scriptVersion, 2)
        XCTAssertEqual(ok?.requiredAPIVersion, 3)
    }
}

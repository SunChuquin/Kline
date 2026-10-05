//
//  PythonEngineHostSourceTests.swift
//  KlineTests
//
//  引擎双来源单测：内嵌（Bundle.main/KlineEngine，macOS 构建路径）优先，
//  Engine.app（TrollStore 安装）回退。覆盖：
//  - embeddedEngineDir(bundlePath:) 命中/未命中
//  - resolve(_:_:) 直拼命中与「Engine.app/」前缀剥离
//  - EngineManifest 两种 layout 风格（无前缀 / 带 Engine.app/ 前缀）解码
//  - 内嵌引擎进程内加载冒烟（仅 TEST_HOST=Kline.app 且含内嵌引擎时执行，
//    CI/未跑准备脚本时 XCTSkip；loadEngine 进程内只能成功一次，全程只跑一次）
//

import XCTest
@testable import Kline

final class PythonEngineHostSourceTests: XCTestCase {

    /// 每用例独立的临时根目录（tearDown 统一清理）
    private var tmpRoot: String = ""

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PyEngineHostTests-" + UUID().uuidString)
        tmpRoot = dir.path
        try FileManager.default.createDirectory(atPath: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmpRoot)
        tmpRoot = ""
    }

    // MARK: - embeddedEngineDir(bundlePath:)

    /// 临时目录下无 KlineEngine/manifest.json → nil
    func testEmbeddedEngineDirMissing() {
        XCTAssertNil(PythonEngineHost.embeddedEngineDir(bundlePath: tmpRoot),
                     "无 KlineEngine 时不应命中内嵌引擎")
    }

    /// 有 KlineEngine/manifest.json → 命中并返回 KlineEngine 目录
    func testEmbeddedEngineDirHit() throws {
        let dir = tmpRoot + "/KlineEngine"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: dir + "/manifest.json"))
        XCTAssertEqual(PythonEngineHost.embeddedEngineDir(bundlePath: tmpRoot), dir,
                       "存在 KlineEngine/manifest.json 时应返回该目录")
    }

    // MARK: - resolve(_:_:)

    /// layout 无前缀（内嵌风格）：base/rel 直拼命中
    func testResolveDirectHit() throws {
        try FileManager.default.createDirectory(atPath: tmpRoot + "/sub", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: tmpRoot + "/sub/file"))
        XCTAssertEqual(PythonEngineHost.resolve(tmpRoot, "sub/file"), tmpRoot + "/sub/file")
    }

    /// rel 带「Engine.app/」前缀且 base 下无 Engine.app 子目录 → 剥前缀命中
    func testResolveStripsEngineAppPrefix() throws {
        let fw = tmpRoot + "/Frameworks/Python.framework"
        try FileManager.default.createDirectory(atPath: fw, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: fw + "/Python"))
        XCTAssertEqual(
            PythonEngineHost.resolve(tmpRoot, "Engine.app/Frameworks/Python.framework/Python"),
            tmpRoot + "/Frameworks/Python.framework/Python",
            "base 下无 Engine.app 子目录时应剥前缀直拼命中")
    }

    // MARK: - EngineManifest 解码（两种 layout 风格）

    /// 内嵌风格：layout 无「Engine.app/」前缀
    func testManifestDecodeEmbeddedLayout() throws {
        let json = """
        {"schema":1,"engineId":"com.sunck.KlineEngine","engineVersion":"3.14.7",
         "build":"macos-embedded","apiVersion":1,
         "layout":{"dylib":"Frameworks/Python.framework/Python",
                   "home":"Frameworks/Python.framework"}}
        """
        let m = try JSONDecoder().decode(EngineManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.apiVersion, 1)
        XCTAssertEqual(m.engineVersion, "3.14.7")
        XCTAssertEqual(m.layout.dylib, "Frameworks/Python.framework/Python")
    }

    /// Engine.app 风格：layout 带「Engine.app/」前缀（相对仓库根的旧前缀）
    func testManifestDecodeEngineAppLayout() throws {
        let json = """
        {"schema":1,"engineId":"com.sunck.KlineEngine","engineVersion":"3.14.7",
         "build":"ci-tipa","apiVersion":1,
         "layout":{"dylib":"Engine.app/Frameworks/Python.framework/Python",
                   "home":"Engine.app/Frameworks/Python.framework"}}
        """
        let m = try JSONDecoder().decode(EngineManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.apiVersion, 1)
        XCTAssertEqual(m.engineVersion, "3.14.7")
        XCTAssertEqual(m.layout.dylib, "Engine.app/Frameworks/Python.framework/Python")
    }

    // MARK: - 内嵌引擎加载冒烟（关键：模拟器自动验证入口）

    /// 仅当 KlineTests 配置 TEST_HOST（Bundle.main 是 Kline.app）且已内嵌引擎时执行：
    /// loadEngine 一次成功（engineVersion == "3.14.7"），再 runScript("pass") 成功。
    /// CI / 未跑准备脚本（无内嵌引擎）时 XCTSkip。
    func testEmbeddedEngineLoadSmoke() throws {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            throw XCTSkip("KlineTests 未配置 TEST_HOST（Bundle.main 不是 Kline.app），跳过")
        }
        guard PythonEngineHost.embeddedEngineDir(bundlePath: Bundle.main.bundlePath) != nil else {
            throw XCTSkip("无内嵌引擎（CI/未跑准备脚本），跳过")
        }
        let host = PythonEngineHost.shared

        // ① 加载（进程内只能成功一次，本用例只跑一次）
        var loadResult: Result<EngineLoadResult, String>?
        let loaded = XCTestExpectation(description: "内嵌引擎 loadEngine 成功")
        host.loadEngine { r in
            loadResult = r
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 60)
        let load = try XCTUnwrap(loadResult, "loadEngine 未回调")
        guard case .success(let res) = load else {
            XCTFail("内嵌引擎加载失败：\(load)")
            return
        }
        XCTAssertEqual(res.engineVersion, "3.14.7")

        // ② 进程内跑一句 pass（不碰 __kline_out__，仅验证解释器可用）
        var runResult: Result<Double, String>?
        let ran = XCTestExpectation(description: "runScript(pass) 成功")
        host.runScript("pass\n") { r in
            runResult = r
            ran.fulfill()
        }
        wait(for: [ran], timeout: 60)
        let run = try XCTUnwrap(runResult, "runScript 未回调")
        guard case .success = run else {
            XCTFail("runScript(pass) 失败：\(run)")
            return
        }
    }
}

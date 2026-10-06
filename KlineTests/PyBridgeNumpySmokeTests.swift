//
//  PyBridgeNumpySmokeTests.swift
//  KlineTests
//
//  numpy 基建冒烟：引擎进程内 numpy 可导入 + C 扩展运算正确。
//  背景：引擎包（engine.yml）自 2026-10 起内嵌 numpy iOS wheel（cibuildwheel 自建，
//  site-packages 逐文件进 files.sha256）；本用例验证「引擎加载 → site-packages 可见 →
//  numpy C 扩展（_multiarray_umath 等 .so）在引擎进程内 dlopen 成功 → 数值运算正确」全链路。
//
//  执行通道：PythonEngineHost.runScriptCapturingOutput（inline 脚本经 __kline_out__ 写 JSON，
//  Swift 读回断言）——与 PythonEngineHostSourceTests.testEmbeddedEngineLoadSmoke 的 ② 同链路，
//  不经 PyBridge 命名脚本（生产 PyScripts 零改动，numpy 基建不添业务脚本）。
//
//  skip 语义（对齐 PyBridge 契约测试）：
//  - 引擎未就绪（无引擎构建 / KLINE_SKIP_ENGINE_EMBED=1）→ XCTSkip（验证纯 Swift 降级路径）；
//  - 引擎就绪但 numpy 未安装（旧引擎缓存 / 旧 Engine.app）→ XCTSkip（numpy 随引擎包版本化，
//    缺失属环境旧版而非缺陷；skip reason 打明「numpy 未安装」便于 CI 日志甄别）；
//  - 其余（运算结果不符等）→ 真 fail。
//

import XCTest
@testable import Kline

final class PyBridgeNumpySmokeTests: XCTestCase {

    /// 后台 ensureReady（引擎加载含 dlopen + Py_Initialize，60s 上限；语义同 PyBridge 契约测试）；
    /// 失败 → XCTSkip（无引擎构建验证降级路径而非失败）。会触发加载——用例顺序无关。
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

    /// 引擎就绪但 numpy 未安装 → XCTSkip（脚本内 ImportError 内联捕获，经 JSON 回传区分）
    private func throwSkipIfNumpyMissing(_ obj: [String: Any]) throws {
        if (obj["numpyMissing"] as? Bool) == true {
            throw XCTSkip("引擎内 numpy 未安装（旧引擎缓存 / 旧 Engine.app；numpy 随引擎包版本化）"
                + "——script error: \(obj["error"] ?? "(无)")")
        }
    }

    /// numpy import + 数组运算冒烟：mean / dot / max / dtype / shape 全量断言
    func testNumpyImportAndCompute() throws {
        try ensureEngineReady()
        let host = PythonEngineHost.shared

        // inline 脚本：ImportError 内联捕获（区分「numpy 未安装」→ skip；其余异常 → ok=false → fail）
        let script = """
        import json as _knj
        _knres = {}
        try:
            import numpy as _knp
            _karr = _knp.array([1.0, 2.0, 3.0])
            _knres = {
                "ok": True,
                "version": _knp.__version__,
                "mean": float(_karr.mean()),
                "dot": float(_knp.dot(_karr, [4.0, 5.0, 6.0])),
                "maxDoubled": float(_knp.max(_karr * 2.0)),
                "shape": list(_karr.shape),
                "dtype": str(_karr.dtype),
            }
        except ImportError as _kne:
            _knres = {"ok": True, "numpyMissing": True, "error": repr(_kne)}
        except Exception as _kge:
            _knres = {"ok": False, "error": repr(_kge)}
        open(__kline_out__, 'w').write(_knj.dumps(_knres))
        """

        var boxed: Result<(data: Data, totalMs: Double), String>?
        let ran = XCTestExpectation(description: "runScriptCapturingOutput(numpy smoke) 成功")
        host.runScriptCapturingOutput(script) { r in
            boxed = r
            ran.fulfill()
        }
        wait(for: [ran], timeout: 60)
        let capture = try XCTUnwrap(boxed, "runScriptCapturingOutput 未回调")
        guard case .success(let payload) = capture else {
            XCTFail("numpy 冒烟脚本执行失败：\(capture)")
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: payload.data) as? [String: Any] else {
            XCTFail("numpy 冒烟输出 JSON 非法（\(payload.data.count) bytes）")
            return
        }
        try throwSkipIfNumpyMissing(obj)
        XCTAssertEqual(obj["ok"] as? Bool, true, "numpy 冒烟脚本报错：\(obj["error"] ?? "(缺 error)")")

        // 版本：wheel 固定 2.5.3（build-numpy-wheel.yml 固定 URL + sha256；升版需同步本断言）
        XCTAssertEqual(obj["version"] as? String, "2.5.3",
            "numpy 版本应为固定 wheel 版本 2.5.3（engine.yml numpy_version 输入）")
        // 数值断言（C 扩展 ufunc 实算：mean/dot/max 全错不了——import 成功但 .so 损坏时会 fail）
        let mean = try XCTUnwrap(obj["mean"] as? Double, "输出缺 mean（\(obj)）")
        let dot = try XCTUnwrap(obj["dot"] as? Double, "输出缺 dot（\(obj)）")
        let maxDoubled = try XCTUnwrap(obj["maxDoubled"] as? Double, "输出缺 maxDoubled（\(obj)）")
        XCTAssertEqual(mean, 2.0, accuracy: 1e-12,
            "mean([1,2,3]) 应为 2.0（C 扩展 reduce 实算）")
        XCTAssertEqual(dot, 32.0, accuracy: 1e-12,
            "dot([1,2,3],[4,5,6]) 应为 32.0（BLAS-free 点积实算）")
        XCTAssertEqual(maxDoubled, 6.0, accuracy: 1e-12,
            "max([1,2,3]*2) 应为 6.0（ufunc 乘法 + reduce 实算）")
        XCTAssertEqual(obj["shape"] as? [Int], [3], "shape 应为 [3]")
        XCTAssertEqual(obj["dtype"] as? String, "float64", "dtype 应为 float64")
    }
}

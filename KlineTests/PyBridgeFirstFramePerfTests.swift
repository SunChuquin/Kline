//
//  PyBridgeFirstFramePerfTests.swift
//  KlineTests
//
//  候选 2 阶段 B「首帧红线」重估实验（阈值化条件实测；可行性分析 §8 修订第 6 条
//  的用户决策：仅当实测「150 根 + 桥接往返」落在阈值内方可重估）。
//
//  实验 A（启动预热时长）：ensureReady（dlopen + Py_Initialize）+ 首调 mytt
//    （numpy import + 模块加载，一次性）。重估后两者均在启动后台异步执行，
//    不出现在任何用户等待链路；本实验量化其总时长与内存增量。
//  实验 B（首帧端到端，关键判据）：预热完成后，模拟首帧指标计算——150 根
//    OHLCV 全序列 → MA5/MA10/EMA12/MACD(12,26,9)（典型首屏负载），测
//    blockingCall 全程（Swift JSON 序列化 → 临时文件 → PyRun → 输出文件 →
//    解码）耗时的分布：20 次取 min/median/p95/max。
//  实验 C（未就绪兜底）：无需新实验——首帧指标生产路径现状即 Swift 原生
//    （未切换），降级矩阵已由降级轮全量验证；重估后架构 = 现状 + isReady 门
//    （未就绪瞬间走 Swift，与 WatchlistSyncManager 同范式）。
//
//  判定口径：稳态 median < 16ms（60fps 一帧预算）= 理想；< 33ms（30fps 一帧）
//  = 可用上限；≥ 33ms = 红线维持。
//
//  ⚠️ 数据有效性前提：本测试须**单独跑**（-only-testing:.../PyBridgeFirstFramePerfTests），
//  进程全新才能测到真实 ensureReady/首调开销（引擎与 numpy 已驻留时该两项
//  失真为 0；稳态分布不受影响）。
//
//  skip 语义：引擎未就绪（无引擎构建 / KLINE_SKIP_ENGINE_EMBED=1）→ XCTSkip
//  （降级轮验证的是 Swift 兜底路径，与本实验目的正交）。
//

import XCTest
@testable import Kline

final class PyBridgeFirstFramePerfTests: XCTestCase {

    // MARK: - 工具

    /// 进程物理内存足迹（phys_footprint，jetsam 杀进程口径，比 RSS 更严格）
    private func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1024 / 1024
    }

    /// 固定种子 150 根 OHLC（LCG 与实验室 makeBarLiteral 同思路，跨运行可复现）
    private static func makeBars(_ n: Int = 150, seed: UInt64 = 20261012) -> [[Double]] {
        var x = seed
        func rnd() -> Double {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return Double((x >> 11) & 0x1F_FFFF_FFFF_FFFF) / Double(0x1F_FFFF_FFFF_FFFF)
        }
        var price = 100.0
        var rows: [[Double]] = []
        rows.reserveCapacity(n)
        for _ in 0..<n {
            let o = price
            let c = max(1.0, o * (1 + (rnd() - 0.5) * 0.04))
            let h = max(o, c) * (1 + rnd() * 0.01)
            let l = min(o, c) * (1 - rnd() * 0.01)
            rows.append([o, h, l, c])
            price = c
        }
        return rows
    }

    private func log(_ line: String) {
        print("[FirstFrame] " + line)
    }

    // MARK: - 重估实验（A 预热 + B 稳态端到端；单测试方法保证顺序执行）

    func testFirstFramePreludeAndSteadyState() throws {
        // —— 实验 A-①：ensureReady（dlopen + Py_Initialize；引擎就绪 → skip）——
        if !KlinePythonBridge.shared.isReady {
            let ready = expectation(description: "ensureReady")
            var readyMs = 0.0
            var failMsg: String?
            let t0 = CFAbsoluteTimeGetCurrent()
            KlinePythonBridge.shared.ensureReady { result in
                readyMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                if case .failure(let m) = result { failMsg = m }
                ready.fulfill()
            }
            wait(for: [ready], timeout: 60)
            if let m = failMsg {
                throw XCTSkip("引擎未就绪：\(m)（无引擎构建验证降级路径而非本实验）")
            }
            log(String(format: "实验A-① ensureReady：%.0fms（dlopen + Py_Initialize，重估后为启动后台预热项）", readyMs))
        } else {
            log("实验A-① ensureReady：0ms（引擎已就绪——单独跑本测试才可测到真实加载耗时）")
        }
        let memAfterEngine = physFootprintMB()

        // 150 根 OHLC → series（open/high/low/close 全序列，贴近真实首帧的序列化成本）
        let bars = Self.makeBars()
        let series: [String: [Double]] = [
            "open": bars.map { $0[0] },
            "high": bars.map { $0[1] },
            "low": bars.map { $0[2] },
            "close": bars.map { $0[3] },
        ]
        // 典型首屏负载：双均线 + EMA + MACD（MACD 走垫片 EMA 递推 + 3 列输出）。
        // args 语法：序列直接用 series 键名（"close"）；"$id"/"$id#k" 是前序结果引用
        let calls: [[String: Any]] = [
            ["fn": "MA", "args": ["close", 5]],
            ["fn": "MA", "args": ["close", 10]],
            ["fn": "EMA", "args": ["close", 12]],
            ["fn": "MACD", "args": ["close", 12, 26, 9]],
        ]
        let input: [String: Any] = ["op": "functions", "series": series, "calls": calls]

        // —— 实验 A-②：首调 mytt（numpy import + 模块加载，一次性）——
        let exp1 = expectation(description: "first call")
        var firstMs = 0.0
        DispatchQueue.global(qos: .userInitiated).async {
            let t = CFAbsoluteTimeGetCurrent()
            KlinePythonBridge.shared.call(script: "mytt", input: input, timeout: 30) { r in
                firstMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
                if case .failure = r { firstMs = -1 }
                exp1.fulfill()
            }
        }
        wait(for: [exp1], timeout: 35)
        if firstMs < 0 {
            XCTFail("首调 mytt 失败（引擎就绪后 call 失败属真实缺陷）")
            return
        }
        log(String(format: "实验A-② 首调 mytt：%.0fms（numpy import + 模块加载，一次性；重估后为启动后台预热项）", firstMs))
        let memAfterNumpy = physFootprintMB()

        // —— 实验 B：稳态 20 次首帧端到端（blockingCall 全程）——
        let exp2 = expectation(description: "steady state")
        var samples: [Double] = []
        var steadyFail: String?
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<20 {
                let t = CFAbsoluteTimeGetCurrent()
                let r = KlinePythonBridge.shared.blockingCall(script: "mytt", input: input, timeout: 30)
                samples.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
                if case .failure(let e) = r {
                    steadyFail = "\(e)"
                    break
                }
            }
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 120)
        if let f = steadyFail {
            XCTFail("稳态调用失败：\(f)")
            return
        }
        guard samples.count == 20 else {
            XCTFail("稳态样本不足：\(samples.count)/20")
            return
        }

        let sorted = samples.sorted()
        let sMin = sorted[0]
        let median = (sorted[9] + sorted[10]) / 2
        let p95 = sorted[18]     // 20 样本 p95 ≈ 第 19 个
        let sMax = sorted[19]
        log(String(format: "实验B 稳态端到端（150根 MA5/MA10/EMA12/MACD，20 次）：min=%.1f median=%.1f p95=%.1f max=%.1f ms",
                   sMin, median, p95, sMax))
        let memSteady = physFootprintMB()
        log(String(format: "内存 phys_footprint：引擎后 %.1fMB → numpy 后 %.1fMB（numpy 增量 %.1fMB）→ 稳态 %.1fMB（稳态增量 %.1fMB）",
                   memAfterEngine, memAfterNumpy, memAfterNumpy - memAfterEngine, memSteady, memSteady - memAfterNumpy))

        let verdict: String
        if median < 16 {
            verdict = "稳态 median < 16ms（60fps 一帧预算）——阈值化条件满足，红线可重估"
        } else if median < 33 {
            verdict = "稳态 median < 33ms（30fps 一帧）——勉强可用，需结合单屏指标数与并帧预算评估"
        } else {
            verdict = "稳态 median ≥ 33ms——首帧红线维持"
        }
        log("判定：" + verdict)

        // sanity（非性能阈值）：稳态单次不应接近超时线（>1s = 异常排查信号）
        XCTAssertLessThan(sMax, 1000, "稳态单次端到端 >1s，疑似超时前兆，需排查")
        // 判据锚定：median 必须落在可解释区间（防测量错误，如把首调算进稳态）
        XCTAssertLessThan(median, 200, "稳态 median >200ms 与既有 quote_parse 3-15ms 稳态量级矛盾，疑似测量错误")
    }

    // MARK: - 大序列压力测试（交接文档待执行项 #5：根数-耗时曲线）
    //
    // 实验 B 只有 150 根一个点；生产后台预取粒度是 500 根/块、单屏序列可能
    // 500~2000 根，JSON 序列化 + 临时文件 IO 随根数线性增长。本用例对
    // 150/500/1000/2000 根各热身 1 次 + 采样 20 次稳态端到端（同一典型首屏负载），
    // 产出「根数 vs median」曲线——作为首帧切换序列长度上限/分块阈值、以及
    // 桥接通道优化（二进制批量/零拷贝）是否立项的量化依据。
    //
    // 判定口径不变：median < 16ms（60fps）理想；< 33ms（30fps）可用上限；≥ 33ms 超帧。
    // 本用例只测稳态分布（引擎/numpy 已由前序用例预热），无需进程全新；
    // 但整个测试类仍须单独 -only-testing 跑（保证前序用例 A 组数据有效）。

    func testStressRootsVsLatencyCurve() throws {
        // 引擎未就绪 → 后台确保一次；失败 skip（与降级轮语义一致）
        if !KlinePythonBridge.shared.isReady {
            let ready = expectation(description: "ensureReady")
            var failMsg: String?
            KlinePythonBridge.shared.ensureReady { result in
                if case .failure(let m) = result { failMsg = m }
                ready.fulfill()
            }
            wait(for: [ready], timeout: 60)
            if let m = failMsg {
                throw XCTSkip("引擎未就绪：\(m)（无引擎构建验证降级路径而非本实验）")
            }
        }

        let sizes = [150, 500, 1000, 2000]
        var curve: [(n: Int, sMin: Double, median: Double, p95: Double, sMax: Double)] = []
        var stressFail: String?

        let exp = expectation(description: "stress curve")
        DispatchQueue.global(qos: .userInitiated).async {
            for n in sizes {
                let bars = Self.makeBars(n)
                let series: [String: [Double]] = [
                    "open": bars.map { $0[0] },
                    "high": bars.map { $0[1] },
                    "low": bars.map { $0[2] },
                    "close": bars.map { $0[3] },
                ]
                // 与实验 B 同负载：双均线 + EMA + MACD（args 序列直接用键名）
                let calls: [[String: Any]] = [
                    ["fn": "MA", "args": ["close", 5]],
                    ["fn": "MA", "args": ["close", 10]],
                    ["fn": "EMA", "args": ["close", 12]],
                    ["fn": "MACD", "args": ["close", 12, 26, 9]],
                ]
                let input: [String: Any] = ["op": "functions", "series": series, "calls": calls]
                // 每档先 1 次热身（消除该输入形状的首调抖动），再采 20 次稳态
                if case .failure(let e) = KlinePythonBridge.shared.blockingCall(script: "mytt", input: input, timeout: 60) {
                    stressFail = "热身失败（\(n) 根）：\(e)"
                    break
                }
                var samples: [Double] = []
                for _ in 0..<20 {
                    let t = CFAbsoluteTimeGetCurrent()
                    let r = KlinePythonBridge.shared.blockingCall(script: "mytt", input: input, timeout: 60)
                    samples.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
                    if case .failure(let e) = r {
                        stressFail = "稳态失败（\(n) 根）：\(e)"
                        break
                    }
                }
                if stressFail != nil { break }
                let sorted = samples.sorted()
                let median = (sorted[9] + sorted[10]) / 2
                curve.append((n, sorted[0], median, sorted[18], sorted[19]))
                self.log(String(format: "压测 %4d 根（MA5/MA10/EMA12/MACD，20 次）：min=%.1f median=%.1f p95=%.1f max=%.1f ms",
                               n, sorted[0], median, sorted[18], sorted[19]))
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 600)

        if let f = stressFail {
            XCTFail("压测调用失败：\(f)")
            return
        }
        guard curve.count == sizes.count else {
            XCTFail("压测档位不足：\(curve.count)/\(sizes.count)")
            return
        }

        log("—— 根数-耗时曲线（模拟器稳态；真机 A8 预期 ×5~10）——")
        for c in curve {
            let verdict = c.median < 16 ? "✓ 60fps 预算内" : (c.median < 33 ? "△ 30fps 勉强可用" : "✗ 超帧预算")
            log(String(format: "%5d 根  median=%6.1fms  p95=%6.1fms  %@", c.n, c.median, c.p95, verdict))
        }
        // sanity：2000 根单次不应接近超时线；曲线应近似线性（超线性 = 桥接异常膨胀）
        let last = curve.last!
        XCTAssertLessThan(last.sMax, 5000, "2000 根稳态单次 >5s，疑似桥接异常")
        let perKilo = (curve.last!.median - curve.first!.median) / Double(curve.last!.n - curve.first!.n) * 1000
        log(String(format: "线性斜率：约 %.2f ms / 千根（150→2000）", perKilo))
    }

    // MARK: - 零拷贝 bin 通道对比（tdx_eval：JSON 基线 vs bin 零拷贝）

    /// 首帧真实形状的通道对比：同一批 TDX 公式（MA5/MA10/EMA12/SAR/STD）× 150 根，
    /// 分别走 JSON 通道（原生产路径形状）与 bin 通道（ctypes 零拷贝输入 + 二进制输出），
    /// 各热身 1 + 采样 20 次稳态——量化零拷贝对单次调用开销的实际收益。
    func testFirstFrameTDXEvalJSONvsBin() throws {
        if !KlinePythonBridge.shared.isReady {
            let ready = expectation(description: "ensureReady")
            var failMsg: String?
            KlinePythonBridge.shared.ensureReady { result in
                if case .failure(let m) = result { failMsg = m }
                ready.fulfill()
            }
            wait(for: [ready], timeout: 60)
            if let m = failMsg {
                throw XCTSkip("引擎未就绪：\(m)（无引擎构建验证降级路径而非本实验）")
            }
        }

        let bars = Self.makeBars(150)
        let seriesBin: [String: [Double]] = [
            "c": bars.map { $0[3] }, "h": bars.map { $0[1] },
            "l": bars.map { $0[2] }, "o": bars.map { $0[0] },
            "v": bars.map { _ in 100.0 }, "a": bars.map { _ in 1000.0 },
        ]
        // JSON 通道输入（bin 出现前的生产形状）：bars 全序列进 JSON
        let jsonInput: [String: Any] = [
            "bars": ["c": seriesBin["c"]!, "h": seriesBin["h"]!, "l": seriesBin["l"]!,
                     "o": seriesBin["o"]!, "v": seriesBin["v"]!, "a": seriesBin["a"]!],
            "requests": [
                ["stmts": [["n": "M5", "o": 1, "e": ["t": "call", "fn": "MA", "args": [["t": "var", "n": "C"], ["t": "num", "v": 5]]]]]],
                ["stmts": [["n": "M10", "o": 1, "e": ["t": "call", "fn": "MA", "args": [["t": "var", "n": "C"], ["t": "num", "v": 10]]]]]],
                ["stmts": [["n": "E12", "o": 1, "e": ["t": "call", "fn": "EMA", "args": [["t": "var", "n": "C"], ["t": "num", "v": 12]]]]]],
                ["stmts": [["n": "S", "o": 1, "e": ["t": "call", "fn": "SAR", "args": [["t": "num", "v": 0.02], ["t": "num", "v": 0.2]]]]]],
                ["stmts": [["n": "ST", "o": 1, "e": ["t": "call", "fn": "STD", "args": [["t": "var", "n": "C"], ["t": "num", "v": 10]]]]]],
            ],
        ]
        let binInput: [String: Any] = ["__bin__": 1, "requests": jsonInput["requests"]!]

        let exp = expectation(description: "json vs bin")
        var jsonSamples: [Double] = []
        var binSamples: [Double] = []
        var cmpFail: String?
        DispatchQueue.global(qos: .userInitiated).async {
            // 热身各 1 次（消除输入形状首调抖动）
            if case .failure(let e) = KlinePythonBridge.shared.blockingCall(script: "tdx_eval", input: jsonInput, timeout: 30) {
                cmpFail = "JSON 热身失败：\(e)"
            }
            if cmpFail == nil, case .failure(let e) = KlinePythonBridge.shared.blockingCallBin(script: "tdx_eval", input: binInput, seriesBin: seriesBin, seriesInto: "bars", timeout: 30) {
                cmpFail = "bin 热身失败：\(e)"
            }
            guard cmpFail == nil else { exp.fulfill(); return }
            // 稳态各 20 次
            for _ in 0..<20 {
                let t = CFAbsoluteTimeGetCurrent()
                if case .failure(let e) = KlinePythonBridge.shared.blockingCall(script: "tdx_eval", input: jsonInput, timeout: 30) {
                    cmpFail = "JSON 稳态失败：\(e)"; break
                }
                jsonSamples.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            }
            for _ in 0..<20 {
                let t = CFAbsoluteTimeGetCurrent()
                if case .failure(let e) = KlinePythonBridge.shared.blockingCallBin(script: "tdx_eval", input: binInput, seriesBin: seriesBin, seriesInto: "bars", timeout: 30) {
                    cmpFail = "bin 稳态失败：\(e)"; break
                }
                binSamples.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 120)
        if let f = cmpFail {
            XCTFail("对比调用失败：\(f)")
            return
        }
        guard jsonSamples.count == 20, binSamples.count == 20 else {
            XCTFail("采样不足 json=\(jsonSamples.count) bin=\(binSamples.count)")
            return
        }
        func median(_ s: [Double]) -> Double {
            let sorted = s.sorted()
            return (sorted[9] + sorted[10]) / 2
        }
        let jm = median(jsonSamples), bm = median(binSamples)
        log(String(format: "tdx_eval 150根×5公式：JSON median=%.1fms  bin(零拷贝) median=%.1fms  收益=%.0f%%",
                   jm, bm, jm > 0 ? (1 - bm / jm) * 100 : 0))
        XCTAssertLessThan(bm, 200, "bin 通道稳态 median >200ms 与既有量级矛盾，疑似测量错误")
        XCTAssertLessThan(bm, jm, "bin 通道应不慢于 JSON 通道")
    }
}

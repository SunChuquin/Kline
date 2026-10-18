//
//  PyBridgeTransportBaselineTests.swift
//  KlineTests
//
//  【基线实验】桥接**单次过桥固定开销** vs **payload 规模** 的分解测量。
//
//  背景（§11.34.1）：读路径能不能下沉，取决于「一次过桥的固定开销」是否落在 16.7ms 帧预算里。
//  已知稳态数据点：`tdx_eval` 150 根 × 5 公式 median 13.8ms，bin 零拷贝只省 4%
//  （→ 瓶颈不在序列化）。本实验把**空往返**单独量出来，从而回答：
//    · 若 P0（空往返）≈ 10ms → L2「异步预取 + 投影」必须等桥接管道化（§9.8 A′）才划算；
//    · 若 P0 ≈ 1~3ms  → 13.8ms 里绝大部分是**真实计算**，纯数据读的过桥成本低，L2 可直接做。
//
//  口径：异步 `call` 从发起到完成回调的整段 wall-clock（含 Swift 侧入参序列化/落盘、
//  PyRun、出参读回/解析）；顺序调用（引擎 workQueue 串行）→ 即单次调用延迟。
//  纯 log + 宽松上界断言（防回归）；另**断言每轮都成功**——这条断言正是
//  「脚本 IO 契约」缺陷（`quote_snapshot` / `sim_state` 缺模块级 `kline_result`）的探针。
//

import XCTest
@testable import Kline

@MainActor
final class PyBridgeTransportBaselineTests: XCTestCase {

    private func log(_ s: String) { print("[Transport] \(s)") }

    // MARK: - 引擎就绪

    private func ensureEngineReady() async throws {
        if KlinePythonBridge.shared.isReady { return }
        var failureMsg: String?
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            KlinePythonBridge.shared.ensureReady { r in
                if case .failure(let m) = r { failureMsg = m }
                cont.resume()
            }
        }
        if let m = failureMsg {
            throw XCTSkip("Python 引擎未就绪：\(m)——无引擎构建验证降级路径而非失败")
        }
    }

    // MARK: - 测量

    /// 一次异步往返 → (毫秒, 是否成功)
    private func roundTrip(_ script: String, _ input: [String: Any]) async -> (ms: Double, ok: Bool) {
        let t0 = CFAbsoluteTimeGetCurrent()
        var ok = false
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            KlinePythonBridge.shared.call(script: script, input: input, timeout: 30) { r in
                if case .success = r { ok = true }
                cont.resume()
            }
        }
        return ((CFAbsoluteTimeGetCurrent() - t0) * 1000, ok)
    }

    /// 顺序打 `rounds` 次 → (入参字节数, min, median, max, 失败数) ms
    private func measure(_ script: String, _ input: [String: Any], rounds: Int)
        async -> (bytes: Int, min: Double, median: Double, max: Double, fails: Int) {
        let bytes = (try? JSONSerialization.data(withJSONObject: input).count) ?? 0
        var times: [Double] = []
        var fails = 0
        for _ in 0..<rounds {
            let r = await roundTrip(script, input)
            if r.ok { times.append(r.ms) } else { fails += 1 }
        }
        let sorted = times.sorted()
        return (bytes, sorted.first ?? 0, sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                sorted.last ?? 0, fails)
    }

    private func report(_ name: String, _ m: (bytes: Int, min: Double, median: Double, max: Double, fails: Int)) {
        log(String(format: "%-26@ 入参 %7d B  min %6.2f  median %6.2f  max %6.2f ms  失败 %d",
                   name as NSString, m.bytes, m.min, m.median, m.max, m.fails))
    }

    // MARK: - 测点构造

    /// 与 `MarketRowCache` 生产口径一致的 21 个字段（行情表行内展示）
    private static let fields = ["latestPrice", "prevClose", "open", "high", "low", "volume",
                                 "turnover", "change", "changePct", "amplitude", "volRatio",
                                 "pct3d", "pct5d", "pct10d", "pct20d", "pct60d", "pctYTD",
                                 "ma5", "ma10", "ma20", "ma60"]

    /// 造 `rows` 根日线（确定性伪随机）
    private func bars(seed: Int, rows: Int = 250) -> [[String: Any]] {
        var out: [[String: Any]] = []
        out.reserveCapacity(rows)
        for i in 0..<rows {
            let base = Double(10 + (seed * 7 + i) % 90)
            let drift = Double((i * 13 + seed * 29) % 17) / 100
            out.append(["date": 20250101 + i, "open": base, "high": base + 1.5,
                        "low": base - 1.5, "close": base + drift,
                        "volume": Double(1000 + (i * 37) % 5000),
                        "turnover": Double(10000 + (i * 91) % 90000)])
        }
        return out
    }

    // MARK: - 实验

    /// 三个测点一次跑完：
    ///   P0 空往返（`sim_format`，payload ~50B / handler µs 级）= 纯固定开销
    ///   P1 数据型小包（`quote_snapshot_batch` 1 标的 × 250 根）= 「一个图页的读量」
    ///   P2 数据型大包（30 标的 × 250 根）= 考察 payload 依赖度
    func testBridgeTransportBaseline() async throws {
        try await ensureEngineReady()

        // ① 冷启动首调（引擎刚 ready 后第一次过桥）：量的是「一次性冷启动」而非稳态成本
        let cold = await roundTrip("sim_rules", ["op": "sim_format", "fn": "price", "value": 1500.0])
        log(String(format: "冷启动首调 %.2fms（ok=%@）", cold.ms, cold.ok ? "true" : "false"))

        // ② 预热到稳态（单次预热远远不够：实测首调 27ms 而稳态 1.6ms，相差一个量级）
        for _ in 0..<10 {
            _ = await roundTrip("sim_rules", ["op": "sim_format", "fn": "price", "value": 1.0])
            _ = await roundTrip("quote_snapshot",
                                ["op": "quote_snapshot_batch",
                                 "symbols": [["metaID": 1, "bars": bars(seed: 1)]],
                                 "fields": Self.fields])
        }

        let p0 = await measure("sim_rules",
                               ["op": "sim_format", "fn": "price", "value": 1500.0],
                               rounds: 20)
        let p1 = await measure("quote_snapshot",
                               ["op": "quote_snapshot_batch",
                                "symbols": [["metaID": 1, "bars": bars(seed: 1)]],
                                "fields": Self.fields],
                               rounds: 20)
        let p2 = await measure("quote_snapshot",
                               ["op": "quote_snapshot_batch",
                                "symbols": (1...30).map { ["metaID": $0, "bars": bars(seed: $0)] },
                                "fields": Self.fields],
                               rounds: 8)

        log("—— 桥接单次过桥基线（**稳态**，已预热 10 轮；异步 call 往返）——")
        report("P0 空往返 sim_format", p0)
        report("P1 数据型 1×250 根", p1)
        report("P2 数据型 30×250 根", p2)

        let perKb = p2.bytes > p1.bytes
            ? (p2.median - p1.median) / (Double(p2.bytes - p1.bytes) / 1024.0) : 0
        log(String(format: "分解：稳态固定开销(P0 median)=%.2fms · payload 斜率=%.3f ms/KB",
                   p0.median, perKb))
        log(String(format: "对照：冷启动首调 %.2fms vs 稳态 %.2fms（比值 %.1fx）——"
                   + "冷启动量级差异说明单次预热远不足以进入稳态", cold.ms, p0.median,
                   p0.median > 0 ? cold.ms / p0.median : 0))

        // 契约探针：任一测点出现失败即说明脚本 IO 契约被破坏（2026-10-19 曾真实发生）
        XCTAssertEqual(p0.fails, 0, "sim_rules 调用失败——桥接或脚本 IO 契约回归")
        XCTAssertEqual(p1.fails, 0, "quote_snapshot 调用失败——脚本 IO 契约回归")
        XCTAssertEqual(p2.fails, 0, "quote_snapshot 批量调用失败——脚本 IO 契约回归")
        XCTAssertTrue(p0.median.isFinite && p0.median < 100,
                      "空往返异常（>100ms）——桥接或引擎有回归")
    }
}

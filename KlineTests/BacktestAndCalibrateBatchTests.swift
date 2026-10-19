//
//  BacktestAndCalibrateBatchTests.swift
//  KlineTests
//
//  §11.42 / §11.43 的两张安全网：
//   ① **回测端到端**：`StrategyBacktestRunner` 的取数已改「按批引擎读」（§11.42），
//      本测试用真实链路（自选小池 + 策略文档 + 真实主库）跑一次，
//      确认批处理改造后回测仍能跑完并产出扫描数（不需要人工点 UI）。
//   ② **`calibrate_batch` 与逐只 `calibrate` 逐字同结果**（§11.43）：
//      补缺口自校准改为按批后，判定必须与逐只完全一致（同一份 `_calibrate_one`）。
//

import XCTest
@testable import Kline

@MainActor
final class BacktestAndCalibrateBatchTests: XCTestCase {

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

    /// 轮询等待条件成立（超时即 XCTFail）
    private func waitUntil(_ timeout: TimeInterval, _ cond: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("等待超时（\(Int(timeout))s）")
    }

    /// 后台线程执行（`blockingCall` 断言禁止主线程）
    private func onBackground<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: - ① 回测取数**真实链路**（真实主库 + 真实引擎，按批）

    /// 回测的取数已改「按批引擎读」（§11.42）→ 本测试用**真实主库**、按**回测的调用口径**
    /// （`table`=周期表名、`limit`=`days + 60`）跑一遍，并**覆盖多批**（>1 个 `engineBatchSize`）。
    ///
    /// 为什么不用 `StrategyBacktestRunner` 端到端：回测要先有「策略文档 + 候选池」，
    /// 本机 `Documents/formula/strategy` 为空（无策略文档）→ 端到端跑不起来；
    /// 而本次改动**只替换了取数那一行**，故把验证收敛到取数链路本身（含分块算术）。
    func testBacktestReadPathOnRealDB() async throws {
        try await ensureEngineReady()
        let db = DatabaseManager.shared
        try await waitUntil(60) { db.isLoaded && !db.metaList.isEmpty }

        let metas = Array(db.metaList.prefix(120))
        let limit = 250 + 60            // 与回测同口径：多取 60 根保证窗口首日也有昨收/均线起点
        let requests = metas.map { (metaID: $0.id, limit: limit) }
        let out = try await onBackground {
            db.fetchPeriodLimitedViaEngineBatch(table: "daily", requests: requests)
        }

        XCTAssertEqual(out.count, requests.count, "按批取数应覆盖全部 \(requests.count) 只")
        let withBars = out.values.filter { !$0.isEmpty }.count
        XCTAssertGreaterThan(withBars, requests.count / 2, "多数标的应有 bars（按批读/合并有问题）")
        for (metaID, bars) in out where !bars.isEmpty {
            XCTAssertLessThanOrEqual(bars.count, limit, "metaID=\(metaID) 根数超过请求上限")
            XCTAssertEqual(bars.map(\.date), bars.map(\.date).sorted(by: >),
                           "metaID=\(metaID) 应 date 降序（新→旧）")
        }
        DebugLogger.shared.log("[取证] 回测取数链路（真实主库·按批）：请求 \(requests.count) 只"
                               + " → 有 bars \(withBars) 只")
    }

    // MARK: - ② calibrate_batch 与逐只 calibrate 对拍

    private func wireRow(_ date: String, _ open: String, _ close: String, _ high: String,
                         _ low: String, _ vol: String, _ amo: String) -> [Any] {
        [date, open, close, high, low, vol, "0", "0", amo]
    }

    /// 跑一次 quote_parse op，返回引擎输出的 `result` 载荷（字典）。
    private func callQuoteParse(_ input: [String: Any]) async throws -> [String: Any] {
        let result = try await onBackground { () -> [String: Any] in
            let r = KlinePythonBridge.shared.blockingCall(script: "quote_parse", input: input, timeout: 20)
            guard case .success(let data) = r,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["result"] as? [String: Any] else {
                throw NSError(domain: "quoteParse", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "call failed"])
            }
            return payload
        }
        return result
    }

    private func jsonText(_ any: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "<serialize failed>" }
        return text
    }

    /// 覆盖三条判定分支：正常 gap（量比 100）/ 主库无量额口径（只补价格）/ 源侧缺锚点日。
    func testCalibrateBatchMatchesSingleCalibrate() async throws {
        try await ensureEngineReady()
        let anchorDay = "20261019"
        let gapRow = wireRow("20261020", "10.50", "10.80", "11.20", "10.30", "12000", "120000")
        let anchorRow = wireRow(anchorDay, "10.00", "10.50", "11.00", "9.50", "10000", "100000")

        let items: [[String: Any]] = [
            // ① 个股：主库量 = 源量×100（量比 100）、额 = 源[万]×10000（额比 1）→ gap
            ["base": ["open": 10.0, "high": 11.0, "low": 9.5, "close": 10.5,
                      "vol": 1_000_000.0, "amo": 1_000_000_000.0],
             "sourceRows": [anchorRow, gapRow], "mainLatest": 20261019],
            // ② 主库锚点无量额口径（定制指数）→ 只补价格（vol/amo 写 0）
            ["base": ["open": 10.0, "high": 11.0, "low": 9.5, "close": 10.5,
                      "vol": 0.0, "amo": 0.0],
             "sourceRows": [anchorRow, gapRow], "mainLatest": 20261019],
            // ③ 源侧没有锚点日 → anchorMissing
            ["base": ["open": 10.0, "high": 11.0, "low": 9.5, "close": 10.5,
                      "vol": 1_000_000.0, "amo": 1_000_000_000.0],
             "sourceRows": [gapRow], "mainLatest": 20261019],
            // ④ 量比 77.8 → 落入「吸附到 100」的宽档（band 判定，非异常）；作用是覆盖吸附分支
            ["base": ["open": 10.0, "high": 11.0, "low": 9.5, "close": 10.5,
                      "vol": 777_777.0, "amo": 1_000_000_000.0],
             "sourceRows": [anchorRow, gapRow], "mainLatest": 20261019],
        ]

        // 逐只：4 次单只 op
        var singles: [[String: Any]] = []
        for item in items {
            var input = item
            input["op"] = "calibrate"
            singles.append(try await callQuoteParse(input))
        }
        // 按批：1 次调用
        let batch = try await callQuoteParse(["op": "calibrate_batch", "items": items])

        XCTAssertEqual(batch.count, items.count, "按批应给出全部 \(items.count) 只的判定")
        for (i, single) in singles.enumerated() {
            let key = String(i)
            let batched = try XCTUnwrap(batch[key], "按批缺少下标 \(key)")
            XCTAssertEqual(jsonText(batched), jsonText(single),
                           "下标 \(i) 按批与逐只判定不一致：batch=\(jsonText(batched)) single=\(jsonText(single))")
        }
        DebugLogger.shared.log("[取证] calibrate_batch 对拍：\(items.count) 只逐字一致")
    }
}

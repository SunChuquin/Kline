//
//  PyScriptsBridgeSmokeTests.swift
//  KlineTests
//
//  【回归网】两个曾被「脚本 IO 契约」缺陷打穿的下沉路径的语义冒烟：
//    · `sim_state_*`（阶段 B 状态所有权反转 —— 挂掉 = `SimStore` 的引擎写口全部失败，
//       而 §11.30 已把本地写收口移除 → sim.json 实际不会落盘）
//    · `quote_snapshot_batch`（阶段 C 首批非帧快照 —— 挂掉 = 金融行情快照下沉从未生效）
//
//  为什么需要：这两个缺陷（脚本缺模块级 `kline_result`、bars 形状不一致）在
//  2026-10-19 的桥接基线实验中被发现，而此前**没有任何测试端到端调用过这两个脚本**。
//  契约扫描见 `scripts/verify_pyscript_io_contract.py`；本文件补语义级回归。
//

import XCTest
@testable import Kline

@MainActor
final class PyScriptsBridgeSmokeTests: XCTestCase {

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

    // MARK: - sim_state（阶段 B 状态持久化）

    /// save → load 往返：状态与 revision 必须一致（引擎为唯一写者）。
    func testSimStateSaveLoadRoundTrip() async throws {
        try await ensureEngineReady()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("simstate_\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let state: [String: Any] = ["schemaVersion": 3, "revision": 7,
                                    "accounts": [["id": "A"]], "logs": [["content": "x"]]]

        let saved = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SimStateBridge.simStateSave(filePath: path, state: state) { r in
                if case .success = r { c.resume(returning: true) } else { c.resume(returning: false) }
            }
        }
        XCTAssertTrue(saved, "sim_state_save 失败——脚本 IO 契约或引擎回归")

        let loaded = await withCheckedContinuation { (c: CheckedContinuation<[String: Any]?, Never>) in
            SimStateBridge.simStateLoad(filePath: path) { r in
                if case .success(let s) = r { c.resume(returning: s) } else { c.resume(returning: nil) }
            }
        }
        let s = try XCTUnwrap(loaded, "sim_state_load 失败——脚本 IO 契约或引擎回归")
        XCTAssertEqual(SimRulesCodec.int(s["revision"]), 7, "revision 不一致")
        XCTAssertEqual((s["accounts"] as? [[String: Any]])?.count, 1, "accounts 未落盘")
    }

    /// `sim_state_apply` 的 revision 自增（`SimStore.saveToDisk` 走的就是这个 op）。
    func testSimStateApplyIncrementsRevision() async throws {
        try await ensureEngineReady()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("simstate_apply_\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let rev = await withCheckedContinuation { (c: CheckedContinuation<Int?, Never>) in
            SimStateBridge.simStateApply(filePath: path, changes: ["schemaVersion": 3],
                                         merge: [:]) { r in
                if case .success(let s) = r { c.resume(returning: SimRulesCodec.int(s["revision"])) }
                else { c.resume(returning: nil) }
            }
        }
        XCTAssertEqual(rev, 1, "sim_state_apply 未成功自增 revision（引擎写口实际未生效）")
    }

    // MARK: - quote_snapshot（阶段 C 首批）

    /// Swift 侧传**字典**形状的 bars（生产口径）→ 引擎必须算出正确字段。
    func testQuoteSnapshotBatchAcceptsSwiftDictBars() async throws {
        try await ensureEngineReady()
        // 两根：昨收 10.0（前一根 close），最新 12.0
        let bars: [[String: Any]] = [
            ["date": 20260101, "open": 9.5, "high": 10.5, "low": 9.0, "close": 10.0,
             "volume": 1000, "turnover": 10000],
            ["date": 20260102, "open": 11.0, "high": 12.5, "low": 10.5, "close": 12.0,
             "volume": 1500, "turnover": 18000],
        ]
        let got = await withCheckedContinuation { (c: CheckedContinuation<[String: [String: Any]]?, Never>) in
            QuoteSnapshotBridge.snapshotBatch(symbols: [["metaID": 42, "bars": bars]],
                                              fields: ["latestPrice", "prevClose"]) { r in
                if case .success(let m) = r { c.resume(returning: m) } else { c.resume(returning: nil) }
            }
        }
        let m = try XCTUnwrap(got, "quote_snapshot_batch 失败——bars 形状或脚本 IO 契约回归")
        let fields = try XCTUnwrap(m["42"], "未返回 metaID=42 的结果")
        XCTAssertEqual(fields["latestPrice"] as? Double, 12.0)
        XCTAssertEqual(fields["prevClose"] as? Double, 10.0)
    }
}

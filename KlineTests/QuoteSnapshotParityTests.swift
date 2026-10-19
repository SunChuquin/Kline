//
//  QuoteSnapshotParityTests.swift
//  KlineTests
//
//  §11.41：行情/自选字段（现价 / 昨收 / 涨跌 / 振幅 / 量比 / 区间涨幅 / YTD / 均线）
//  已改为**引擎唯一来源**——app 侧 `MarketRow` 的 Swift 现状算法与其运行时回退已整体删除。
//
//  本测试是该下沉的**回归网**：用测试目标内的 `QuoteSnapshotOracle`（Swift 现状逐字副本）
//  与引擎 `quote_snapshot_batch` 在成组的边界序列上**逐字段双跑对拍**。
//  引擎若有偏离 → 红；按用户要求**修在引擎侧**，不改 oracle。
//

import XCTest
@testable import Kline

@MainActor
final class QuoteSnapshotParityTests: XCTestCase {

    /// 引擎实际被要求计算的全部字段（与 `MarketRowCache.flushPythonSnapshot` 的 allFields 同集）
    private let allFields: [String] = [
        "latestPrice", "prevClose", "open", "high", "low", "volume", "turnover",
        "change", "changePct", "amplitude", "volRatio",
        "pct3d", "pct5d", "pct10d", "pct20d", "pct60d", "pctYTD",
        "ma5", "ma10", "ma20", "ma60",
    ]

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

    // MARK: - 序列构造

    private func bar(_ date: Int, _ close: Double, open: Double = 9.0,
                     high: Double = 11.0, low: Double = 9.5,
                     volume: Double = 1000, turnover: Double = 10000) -> KlineItem {
        KlineItem(date: date, open: open, high: high, low: low, close: close,
                  volume: volume, turnover: turnover)
    }

    /// 逐日序列：date = base + i（只用于不足跨年的短序列，`date/10000` 仍为同一年）
    private func daily(_ count: Int, base: Int = 20250101,
                       close: (Int) -> Double, volume: (Int) -> Double = { _ in 1000 }) -> [KlineItem] {
        (0..<count).map { i in
            let c = close(i)
            return bar(base + i, c, open: c, high: c + 1, low: c - 0.5, volume: volume(i))
        }
    }

    /// 逐月序列：跨年可用（YTD / ma60 / pct60d 需要长序列与年份边界）
    private func monthly(_ count: Int, startYear: Int, startMonth: Int,
                         close: (Int) -> Double, open: ((Int) -> Double)? = nil) -> [KlineItem] {
        var y = startYear, m = startMonth
        var out: [KlineItem] = []
        for i in 0..<count {
            let c = close(i)
            out.append(bar(y * 10000 + m * 100 + 1, c, open: open?(i) ?? c,
                           high: c + 2, low: c - 2))
            m += 1
            if m > 12 { m = 1; y += 1 }
        }
        return out
    }

    /// 覆盖各计算分支的序列集：空 / 单根 / 两根 / 短 / 长 / 跨年 / 零基期
    private func seriesSet() -> [[KlineItem]] {
        [
            // ① 0 根：全部字段应为 nil
            [],
            // ② 1 根：prevClose / change / changePct / 区间涨幅 / 量比 应为 nil，latestPrice 有值
            daily(1) { _ in 10.0 },
            // ③ 2 根：prevClose = 第 1 根 close
            daily(2) { i in i == 0 ? 10.0 : 12.0 },
            // ④ 6 根：量比（前 5 日均量）与短均线生效
            daily(6) { i in 10.0 + Double(i) },
            // ⑤ 6 根且量全为 0：量比 → nil（avg <= 0 分支）
            daily(6, close: { i in 10.0 + Double(i) }, volume: { _ in 0 }),
            // ⑥ 30 根：pct20d / ma20 生效，ma60 / pct60d 应为 nil（不足）
            daily(30) { i in 20.0 + Double(i) * 0.5 },
            // ⑦ 80 根逐月、跨年（2024-01 起）：pct60d / ma60 生效，YTD 取上年末收盘（baseIdx > 0）
            monthly(80, startYear: 2024, startMonth: 1) { i in 10.0 + Double(i) * 0.25 },
            // ⑧ 65 根逐月、2024-11 起 → 数据首根即当年首根：YTD 退化用 open（baseIdx == 0）
            monthly(65, startYear: 2024, startMonth: 11,
                    close: { i in 10.0 + Double(i) * 0.25 }, open: { i in 8.5 + Double(i) * 0.1 }),
            // ⑨ 3 根且倒数第 2 根 close = 0：change / changePct / amplitude → nil（pc <= 0 分支）
            [bar(20250101, 10.0, open: 10, high: 11, low: 9),
             bar(20250102, 0.0, open: 10, high: 11, low: 9),
             bar(20250103, 12.0, open: 10, high: 12, low: 9)],
            // ⑩ 8 根且高低差价大：振幅有值
            (0..<8).map { i in bar(20250101 + i, 10.0 + Double(i),
                                   open: 10, high: 15.0 + Double(i), low: 5.0, volume: 2000 + Double(i)) },
        ]
    }

    // MARK: - 对拍

    /// 引擎 `quote_snapshot_batch` vs Swift 现状 oracle：全部字段逐值比对（含 nil 语义）。
    func testEngineSnapshotMatchesSwiftOracleAcrossSeries() async throws {
        try await ensureEngineReady()
        let series = seriesSet()

        let symbols: [[String: Any]] = series.enumerated().map { idx, bars in
            ["metaID": idx,
             "bars": bars.map { ["date": $0.date, "open": $0.open, "high": $0.high,
                                 "low": $0.low, "close": $0.close,
                                 "volume": $0.volume, "turnover": $0.turnover] }]
        }

        var failureMsg: String?
        let got = await withCheckedContinuation { (c: CheckedContinuation<[String: [String: Any]], Never>) in
            QuoteSnapshotBridge.snapshotBatch(symbols: symbols, fields: allFields) { r in
                switch r {
                case .success(let m): c.resume(returning: m)
                case .failure(let f): failureMsg = String(describing: f); c.resume(returning: [:])
                }
            }
        }
        if let failureMsg {
            XCTFail("quote_snapshot_batch 调用失败：\(failureMsg)——引擎侧问题，不要在 Swift 侧另找退路")
            return
        }

        var compared = 0
        for (idx, bars) in series.enumerated() {
            guard let fields = got[String(idx)] else {
                XCTFail("引擎未返回 metaID=\(idx) 的结果")
                continue
            }
            for name in allFields {
                guard let field = MarketField(rawValue: name) else { continue }
                let expected: Double? = QuoteSnapshotOracle.value(field, bars: bars)
                let actual: Double? = fields[name] as? Double
                let engineText: String = actual.map { "\($0)" } ?? "nil"
                let oracleText: String = expected.map { "\($0)" } ?? "nil"
                XCTAssertEqual(actual, expected,
                               "字段 \(name)（序列 #\(idx)，\(bars.count) 根）不一致："
                               + "engine=\(engineText) oracle=\(oracleText)")
                compared += 1
            }
        }
        DebugLogger.shared.log("[取证] 行情快照对拍：序列 \(series.count) 组 / 字段比对 \(compared) 次")
        XCTAssertEqual(compared, series.count * allFields.count)
    }
}

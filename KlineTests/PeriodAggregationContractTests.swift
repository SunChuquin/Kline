//
//  PeriodAggregationContractTests.swift
//  KlineTests
//
//  契约测试①：周期聚合（周/月/季/年）—— Swift 侧聚合结果 vs PC 侧 golden。
//
//  契约来源：src/contract_golden.py 产出的 KlineTests/Fixtures/period_aggregation.json
//  （fixtures 无独立版本字段，以文件内 notes 为口径说明；golden 由主库权威实现
//  src/tdx_parser.TDXDataGenerator.handle_data 计算，weekly/monthly 另经
//  live_db_builder.aggregate_full_periods 全窗口交叉自检，两路不一致时生成即失败）。
//
//  被测函数：WatchlistSyncManager.mergePeriodBar(file:daily:base:)（增量合并语义）
//          + KlinePeriod.periodDateRange(_:date:)（Swift 侧周期桶规则：周桶键=周一、
//            月桶键=月初、季桶键=季初、年桶键=年初）。
//
//  聚合方式（复刻生产「基期 bar ⊕ 新日线」路径）：按 periodDateRange 把日线分桶
//  （桶内按日期升序），桶内首根以 base=nil 合入（bar.date = 周期内首个交易日，即桶 key），
//  其余逐根把「当前累计结果」转 KlineItem 作 base 合入 → open=首日开 / high=max / low=min /
//  close=末日收 / vol=Σ / amo=Σ，与 golden 口径一致；整周/整月停牌 → 无桶 → 不产 bar。
//
//  数值口径：价格容差 1e-6；vol 为整数累加，断言精确相等；golden 的 amo 经 num6 规整到
//  6 位小数而 Swift 为原始浮点累加（差异 <1e-9），故 amo 用 1e-6 绝对容差
//  （足以拦截任何真实口径错误：真实差异最小为 0.01 量级）。
//
//  重新生成 fixtures：cd 仓库根目录 && python src/contract_golden.py
//

import XCTest
@testable import Kline

final class PeriodAggregationContractTests: XCTestCase {

    // MARK: - fixture 读取（Fixtures/ 子目录优先，取不到退回 bundle 根）

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

    private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    private func intVal(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

    // MARK: - 聚合与断言

    /// 用 Swift 周期桶规则（periodDateRange）把日线分桶，桶内逐根 mergePeriodBar 聚合。
    private func aggregate(_ period: KlinePeriod, daily: [[Any]], caseName: String) -> [LiveUpsertBar] {
        var buckets: [Int: [LiveUpsertBar]] = [:]
        for row in daily {
            guard row.count >= 7, let date = intVal(row[0]),
                  let o = num(row[1]), let h = num(row[2]), let l = num(row[3]),
                  let c = num(row[4]), let v = num(row[5]), let a = num(row[6]) else {
                XCTFail("[\(caseName)] daily 行不足 7 字段或数值非法：\(row)"
                    + "（fixture: period_aggregation.json → cases[\(caseName)].daily）")
                continue
            }
            let key = KlinePeriod.periodDateRange(period, date: date).0
            buckets[key, default: []].append(
                LiveUpsertBar(file: caseName, date: date, open: o, high: h, low: l, close: c, vol: v, amo: a))
        }
        var out: [LiveUpsertBar] = []
        for key in buckets.keys.sorted() {
            var merged: LiveUpsertBar? = nil
            for bar in (buckets[key] ?? []).sorted(by: { $0.date < $1.date }) {
                if let cur = merged {
                    // base 语义：把「当前累计结果」当作主库当期基期 bar 逐根叠加
                    let base = KlineItem(date: cur.date, open: cur.open, high: cur.high, low: cur.low,
                                         close: cur.close, volume: cur.vol, turnover: cur.amo)
                    merged = WatchlistSyncManager.mergePeriodBar(file: caseName, daily: bar, base: base)
                } else {
                    // 桶内首根：无基期 → 直接以该日线开桶（date = 周期内首个交易日）
                    merged = WatchlistSyncManager.mergePeriodBar(file: caseName, daily: bar, base: nil)
                }
            }
            if let m = merged { out.append(m) }
        }
        return out
    }

    private func assertCase(_ caseDict: [String: Any]) {
        guard let caseName = caseDict["caseName"] as? String,
              let daily = caseDict["daily"] as? [[Any]],
              let golden = caseDict["golden"] as? [String: Any] else {
            XCTFail("用例缺 caseName/daily/golden：keys=\(caseDict.keys.sorted())"
                + "（fixture: period_aggregation.json → cases[]）")
            return
        }
        let periods: [(String, KlinePeriod)] = [
            ("weekly", KlinePeriod.weekly), ("monthly", KlinePeriod.monthly),
            ("quarterly", KlinePeriod.quarterly), ("yearly", KlinePeriod.yearly),
        ]
        for (periodName, period) in periods {
            guard let goldenRows = golden[periodName] as? [[Any]] else {
                XCTFail("[\(caseName)] golden 缺周期键 \(periodName)"
                    + "（fixture: period_aggregation.json → cases[\(caseName)].golden）")
                continue
            }
            let swiftRows = aggregate(period, daily: daily, caseName: caseName)
            XCTAssertEqual(swiftRows.count, goldenRows.count,
                "[\(caseName)][\(periodName)] 周期桶数：golden=\(goldenRows.count) swift=\(swiftRows.count)"
                + "（fixture: period_aggregation.json → cases[\(caseName)].golden.\(periodName)；"
                + "停牌周期 golden 无桶，Swift 也不应产桶）")
            for (i, g) in goldenRows.enumerated() where i < swiftRows.count {
                let s = swiftRows[i]
                guard g.count >= 7 else {
                    XCTFail("[\(caseName)][\(periodName)]#\(i) golden 行不足 7 字段：\(g)"
                        + "（fixture: period_aggregation.json → cases[\(caseName)].golden.\(periodName)[\(i)]）")
                    continue
                }
                let key = "period_aggregation.json → cases[\(caseName)].golden.\(periodName)[\(i)]"
                XCTAssertEqual(s.date, intVal(g[0]) ?? -1,
                    "[\(caseName)][\(periodName)]#\(i).date：golden=\(g[0]) swift=\(s.date)"
                    + "（fixture: \(key)[0]；口径=周期内首个交易日）")
                let priceFields: [(String, Int, Double, Double)] = [
                    ("open", 1, num(g[1]) ?? .nan, s.open),
                    ("high", 2, num(g[2]) ?? .nan, s.high),
                    ("low", 3, num(g[3]) ?? .nan, s.low),
                    ("close", 4, num(g[4]) ?? .nan, s.close),
                ]
                for (field, idx, gVal, sVal) in priceFields {
                    XCTAssertEqual(sVal, gVal, accuracy: 1e-6,
                        "[\(caseName)][\(periodName)]#\(i).\(field)：golden=\(gVal) swift=\(sVal)"
                        + "（fixture: \(key)[\(idx)]；容差 1e-6）")
                }
                XCTAssertEqual(s.vol, num(g[5]) ?? -1,
                    "[\(caseName)][\(periodName)]#\(i).vol：golden=\(g[5]) swift=\(s.vol)"
                    + "（fixture: \(key)[5]；口径=Σvol，精确相等）")
                XCTAssertEqual(s.amo, num(g[6]) ?? -1, accuracy: 1e-6,
                    "[\(caseName)][\(periodName)]#\(i).amo：golden=\(g[6]) swift=\(s.amo)"
                    + "（fixture: \(key)[6]；口径=Σamo，golden 经 num6 取 6 位小数 → 容差 1e-6）")
            }
        }
    }

    private func runCase(_ name: String) throws {
        let root = try loadFixture("period_aggregation")
        guard let cases = root["cases"] as? [[String: Any]],
              let caseDict = cases.first(where: { $0["caseName"] as? String == name }) else {
            XCTFail("fixture 缺用例 \(name)（fixture: period_aggregation.json → cases[].caseName）")
            return
        }
        assertCase(caseDict)
    }

    // MARK: - 用例（每组独立可跑，不依赖执行顺序）

    func testFixtureHasSevenCases() throws {
        let root = try loadFixture("period_aggregation")
        let names = ((root["cases"] as? [[String: Any]]) ?? []).compactMap { $0["caseName"] as? String }
        let expected = ["crossYearWeek", "leapFeb29", "quarterSwitch", "yearEndMonthEnd",
                        "suspensionGaps", "singleDayWeek", "singleDayMonth"]
        for e in expected {
            XCTAssertTrue(names.contains(e),
                "fixture 缺用例 \(e)：实际=\(names)（fixture: period_aggregation.json → cases[].caseName）")
        }
    }

    /// 跨年：20241230 周桶横跨 2024/2025（01-01 停牌），周线一根、月/季/年各拆两根。
    func testCrossYearWeek() throws { try runCase("crossYearWeek") }

    /// 闰年：2024-02-29 为 2 月末最后交易日；0226 周桶跨 2 月→3 月。
    func testLeapFeb29() throws { try runCase("leapFeb29") }

    /// 季切换 Q1→Q2：2026-03-31 是 Q1 最后一根，2026-04-01 起 Q2。
    func testQuarterSwitch() throws { try runCase("quarterSwitch") }

    /// 月末/年末最后交易日：2026-01-01/02 停牌，2026 年线 date=20260105。
    func testYearEndMonthEnd() throws { try runCase("yearEndMonthEnd") }

    /// 停牌空档：周内停牌 2 日 + 整周停牌（该周无周线，golden 无桶 → Swift 也无）。
    func testSuspensionGaps() throws { try runCase("suspensionGaps") }

    /// 单日周：本周只剩 2025-01-31 一根日线 → 周线仅一根。
    func testSingleDayWeek() throws { try runCase("singleDayWeek") }

    /// 单日月：整月只在 2025-10-09 交易一天 → 周/月/季/年各仅一根且 date=20251009。
    func testSingleDayMonth() throws { try runCase("singleDayMonth") }
}

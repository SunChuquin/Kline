//
//  QuoteParsingContractTests.swift
//  KlineTests
//
//  契约测试②：行情解析（腾讯 newfqkline / 自校准 calibrate）—— 全部读本地 fixture 对拍，
//          不发任何网络请求。
//
//  契约来源：src/contract_golden.py 产出的 KlineTests/Fixtures/quote_parsing.json
//  （fixture 无独立版本字段，以文件内 notes 为口径说明；样本为 2026-10-04 真实抓包常量内置，
//  golden 离线确定）。
//
//  被测函数：
//    · GapBackfill.parseTencentRow(_:)（⚠️ 腾讯 wire 行价格顺序 开-收-高-低，
//      r[5]=量(手)、r[8]=额(万元)）
//    · GapBackfill.shared.calibrate(job:rows:mainLatest:)（价格逐字段相等 → 量比吸附
//      1/100/1e-4/1e-7 → 额比哨兵 2% → 缺口行折算；expectedReject=true ↔ anomaly 分支）
//
//  （原「东财批量快照」与「file→secid 映射」两组用例于 2026-10-16 随「单源腾讯化」删除：
//    EastmoneyQuoteFetcher 已下线，清单日更改走腾讯 newfqkline。）
//
//  数值口径：价格容差 1e-6；vol/amo 为单值直传（无累加），断言精确相等。
//  calibrate 的入参构造：sourceRows 走生产同款 parseTencentRow 转 SourceBar；
//  base 按 fixture base{open,high,low,close,vol,amo} 构造 KlineItem（vol→volume、amo→turnover）。
//
//  重新生成 fixtures：cd 仓库根目录 && python src/contract_golden.py
//

import XCTest
@testable import Kline

final class QuoteParsingContractTests: XCTestCase {

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
    private func boolVal(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    private func describe(_ o: GapOutcome) -> String {
        switch o {
        case .gap(let bars, let volRatio, let priceOnly):
            return "gap(bars=\(bars.count), volRatio=\(volRatio), priceOnly=\(priceOnly))"
        case .upToDate: return "upToDate"
        case .suspended: return "suspended"
        case .anchorMissing: return "anchorMissing"
        case .anomaly(let why): return "anomaly(\(why))"
        case .failed(let why): return "failed(\(why))"
        }
    }

    // MARK: - ① 腾讯 newfqkline（⚠️ 价格顺序 开-收-高-低）

    private func assertTencentPrice(_ sVal: Double, _ gVal: Any?, _ field: String,
                                    _ market: String, _ idx: Int, _ key: String, wireIdx: Int) {
        guard let gv = num(gVal) else {
            XCTFail("[\(market)]#\(idx).\(field)：golden 值非法 \(String(describing: gVal))（fixture: \(key).\(field)）")
            return
        }
        XCTAssertEqual(sVal, gv, accuracy: 1e-6,
            "⚠️[\(market)]#\(idx).\(field)：golden=\(gv) swift=\(sVal)"
            + " —— 腾讯 newfqkline 价格顺序是 开-收-高-低（本字段=wire r[\(wireIdx)]），"
            + "与东财快照 开-高-低-收 不同，索引取错即此断言失败"
            + "（fixture: \(key).\(field)；容差 1e-6）")
    }

    private func runTencent(_ market: String) throws {
        let root = try loadFixture("quote_parsing")
        guard let list = root["tencentKline"] as? [[String: Any]],
              let item = list.first(where: { $0["marketCode"] as? String == market }),
              let raw = item["raw"] as? String,
              let golden = item["golden"] as? [[String: Any]] else {
            XCTFail("fixture 缺 tencentKline[\(market)].raw/golden（fixture: quote_parsing.json → tencentKline）")
            return
        }
        guard let rootJSON = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let data = rootJSON["data"] as? [String: Any],
              let container = data[market] as? [String: Any],
              let rows = (container["day"] as? [[Any]]) ?? (container["qfqday"] as? [[Any]]) else {
            XCTFail("[\(market)] raw 反序列化失败或缺 data.\(market).day（fixture: quote_parsing.json → tencentKline[\(market)].raw）")
            return
        }
        var bars: [SourceBar] = []
        for (ri, r) in rows.enumerated() {
            guard let bar = GapBackfill.parseTencentRow(r) else {
                XCTFail("[\(market)] 第\(ri)行 parseTencentRow 返回 nil：\(r)"
                    + "（fixture: quote_parsing.json → tencentKline[\(market)].raw）")
                return
            }
            bars.append(bar)
        }
        XCTAssertEqual(bars.count, golden.count,
            "[\(market)] 行数：golden=\(golden.count) swift=\(bars.count)"
            + "（fixture: quote_parsing.json → tencentKline[\(market)]）")
        for (i, g) in golden.enumerated() where i < bars.count {
            let b = bars[i]
            let key = "quote_parsing.json → tencentKline[\(market)].golden[\(i)]"
            XCTAssertEqual(b.date, intVal(g["date"]) ?? -1,
                "[\(market)]#\(i).date：golden=\(String(describing: g["date"])) swift=\(b.date)"
                + "（date 去 '-' 转 YYYYMMDD；fixture: \(key).date）")
            assertTencentPrice(b.open, g["open"], "open", market, i, key, wireIdx: 1)
            assertTencentPrice(b.close, g["close"], "close", market, i, key, wireIdx: 2)
            assertTencentPrice(b.high, g["high"], "high", market, i, key, wireIdx: 3)
            assertTencentPrice(b.low, g["low"], "low", market, i, key, wireIdx: 4)
            XCTAssertEqual(b.vol, num(g["vol"]) ?? -1,
                "[\(market)]#\(i).vol(手)：golden=\(String(describing: g["vol"])) swift=\(b.vol)"
                + "（r[5]=量(手)；fixture: \(key).vol；精确相等）")
            XCTAssertEqual(b.amo, num(g["amo"]) ?? -1,
                "[\(market)]#\(i).amo(万元)：golden=\(String(describing: g["amo"])) swift=\(b.amo)"
                + "（r[8]=额(万元)；fixture: \(key).amo；精确相等）")
        }
    }

    func testTencentKlineSh600000() throws { try runTencent("sh600000") }
    func testTencentKlineSh000001() throws { try runTencent("sh000001") }

    // MARK: - ② 自校准 calibrate（价格 → 量比吸附 → 额比哨兵 → 缺口行折算）

    private func runCalibration(_ name: String) throws {
        let root = try loadFixture("quote_parsing")
        guard let cases = root["calibration"] as? [[String: Any]],
              let c = cases.first(where: { $0["caseName"] as? String == name }) else {
            XCTFail("fixture 缺校准用例 \(name)（fixture: quote_parsing.json → calibration[].caseName）")
            return
        }
        guard let mainLatest = intVal(c["mainLatest"]),
              let baseDict = c["base"] as? [String: Any],
              let wireRows = c["sourceRows"] as? [[Any]],
              let golden = c["golden"] as? [String: Any],
              let goldenOutcome = golden["outcome"] as? String else {
            XCTFail("[\(name)] 校准用例字段缺失（需 mainLatest/base/sourceRows/golden.outcome）"
                + "（fixture: quote_parsing.json → calibration[\(name)]）")
            return
        }
        let key = "quote_parsing.json → calibration[\(name)]"

        // sourceRows（腾讯 wire 行数组）→ SourceBar：走生产同款 parseTencentRow
        var rows: [SourceBar] = []
        for (ri, r) in wireRows.enumerated() {
            guard let bar = GapBackfill.parseTencentRow(r) else {
                XCTFail("[\(name)] sourceRows[\(ri)] parseTencentRow 返回 nil（fixture: \(key).sourceRows[\(ri)]）")
                return
            }
            rows.append(bar)
        }
        guard let item = ProbeItem(file: "SH#600000", type: "股票") else {
            XCTFail("[\(name)] 测试内部 ProbeItem(SH#600000) 映射失败")
            return
        }
        let meta = MetaItem(id: 0, file: "SH#600000", code: "600000", name: name, type: "股票",
                            firstDate: nil, lastDate: mainLatest)
        let base = KlineItem(date: mainLatest,
                             open: num(baseDict["open"]) ?? 0, high: num(baseDict["high"]) ?? 0,
                             low: num(baseDict["low"]) ?? 0, close: num(baseDict["close"]) ?? 0,
                             volume: num(baseDict["vol"]) ?? 0, turnover: num(baseDict["amo"]) ?? 0)
        let job = GapJob(meta: meta, item: item, base: base)
        let outcome = GapBackfill.shared.calibrate(job: job, rows: rows, mainLatest: mainLatest)
        let expectedReject = boolVal(golden["expectedReject"]) ?? false

        switch goldenOutcome {
        case "gap":
            guard case let .gap(bars, volRatio, priceOnly) = outcome else {
                XCTFail("[\(name)] outcome：golden=gap swift=\(describe(outcome))（fixture: \(key).golden.outcome）")
                return
            }
            XCTAssertEqual(priceOnly, boolVal(golden["priceOnly"]) ?? false,
                "[\(name)] priceOnly：golden=\(String(describing: golden["priceOnly"])) swift=\(priceOnly)"
                + "（fixture: \(key).golden.priceOnly）")
            XCTAssertEqual(volRatio, num(golden["volRatio"]) ?? -1, accuracy: 1e-12,
                "[\(name)] volRatio 吸附值：golden=\(String(describing: golden["volRatio"])) swift=\(volRatio)"
                + "（fixture: \(key).golden.volRatio）")
            let goldenBars = (golden["bars"] as? [[String: Any]]) ?? []
            XCTAssertEqual(bars.count, goldenBars.count,
                "[\(name)] 缺口行数：golden=\(goldenBars.count) swift=\(bars.count)"
                + "（fixture: \(key).golden.bars）")
            for (i, gb) in goldenBars.enumerated() where i < bars.count {
                let b = bars[i]
                let bkey = "\(key).golden.bars[\(i)]"
                XCTAssertEqual(b.date, intVal(gb["date"]) ?? -1,
                    "[\(name)] bars[\(i)].date：golden=\(String(describing: gb["date"])) swift=\(b.date)"
                    + "（fixture: \(bkey).date）")
                XCTAssertEqual(b.open, num(gb["open"]) ?? .nan, accuracy: 1e-6,
                    "[\(name)] bars[\(i)].open：golden=\(String(describing: gb["open"])) swift=\(b.open)"
                    + "（fixture: \(bkey).open；容差 1e-6）")
                XCTAssertEqual(b.high, num(gb["high"]) ?? .nan, accuracy: 1e-6,
                    "[\(name)] bars[\(i)].high：golden=\(String(describing: gb["high"])) swift=\(b.high)"
                    + "（fixture: \(bkey).high；容差 1e-6）")
                XCTAssertEqual(b.low, num(gb["low"]) ?? .nan, accuracy: 1e-6,
                    "[\(name)] bars[\(i)].low：golden=\(String(describing: gb["low"])) swift=\(b.low)"
                    + "（fixture: \(bkey).low；容差 1e-6）")
                XCTAssertEqual(b.close, num(gb["close"]) ?? .nan, accuracy: 1e-6,
                    "[\(name)] bars[\(i)].close：golden=\(String(describing: gb["close"])) swift=\(b.close)"
                    + "（fixture: \(bkey).close；容差 1e-6）")
                XCTAssertEqual(b.vol, num(gb["vol"]) ?? -1,
                    "[\(name)] bars[\(i)].vol：golden=\(String(describing: gb["vol"])) swift=\(b.vol)"
                    + "（vol=源(手)×volRatio 折算主库口径；fixture: \(bkey).vol；精确相等）")
                XCTAssertEqual(b.amo, num(gb["amo"]) ?? -1,
                    "[\(name)] bars[\(i)].amo：golden=\(String(describing: gb["amo"])) swift=\(b.amo)"
                    + "（amo=源(万元)×amoScale 折算主库口径；fixture: \(bkey).amo；精确相等）")
            }
        case "upToDate":
            guard case .upToDate = outcome else {
                XCTFail("[\(name)] outcome：golden=upToDate swift=\(describe(outcome))（fixture: \(key).golden.outcome）")
                return
            }
        case "suspended":
            guard case .suspended = outcome else {
                XCTFail("[\(name)] outcome：golden=suspended swift=\(describe(outcome))（fixture: \(key).golden.outcome）")
                return
            }
        case "anchorMissing":
            guard case .anchorMissing = outcome else {
                XCTFail("[\(name)] outcome：golden=anchorMissing swift=\(describe(outcome))（fixture: \(key).golden.outcome）")
                return
            }
        case "anomaly":
            guard case let .anomaly(msg) = outcome else {
                XCTFail("[\(name)] outcome：golden=anomaly swift=\(describe(outcome))（fixture: \(key).golden.outcome）")
                return
            }
            if let reason = golden["reason"] as? String {
                XCTAssertTrue(msg.hasPrefix(String(reason.prefix(4))),
                    "[\(name)] anomaly 原因前缀：golden=\(reason) swift=\(msg)"
                    + "（fixture: \(key).golden.reason）")
            }
        default:
            XCTFail("[\(name)] 未知 golden outcome=\(goldenOutcome)（fixture: \(key).golden.outcome）")
        }

        // expectedReject ↔ anomaly 分支的总映射（拒绝类用例必须落在 anomaly，反之亦然）
        var isAnomaly = false
        if case .anomaly = outcome { isAnomaly = true }
        XCTAssertEqual(isAnomaly, expectedReject,
            "[\(name)] expectedReject：golden=\(expectedReject) swift outcome=\(describe(outcome))"
            + "（fixture: \(key).golden.expectedReject）")
    }

    func testCalibrationStockVolRatio100() throws { try runCalibration("stockVolRatio100") }
    func testCalibrationIndexVolRatio1() throws { try runCalibration("indexVolRatio1") }
    func testCalibrationPriceMismatchReject() throws { try runCalibration("priceMismatchReject") }
    func testCalibrationAmoRatioReject() throws { try runCalibration("amoRatioReject") }
    func testCalibrationVolRatioReject() throws { try runCalibration("volRatioReject") }
    func testCalibrationSuspendedAnchorVol0() throws { try runCalibration("suspendedAnchorVol0") }
    func testCalibrationAnchorMissing() throws { try runCalibration("anchorMissing") }
    func testCalibrationPriceOnlyVol0() throws { try runCalibration("priceOnlyVol0") }
    func testCalibrationUpToDateNoGap() throws { try runCalibration("upToDateNoGap") }
}

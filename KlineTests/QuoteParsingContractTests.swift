//
//  QuoteParsingContractTests.swift
//  KlineTests
//
//  契约测试②：行情解析（东财批量快照 / 腾讯 newfqkline / 自校准 calibrate）
//          + file → 东财 secid 映射 —— 全部读本地 fixture 对拍，不发任何网络请求。
//
//  契约来源：src/contract_golden.py 产出的 KlineTests/Fixtures/quote_parsing.json 与
//  secid_mapping.json（fixtures 无独立版本字段，以文件内 notes 为口径说明；样本为
//  2026-10-04 真实抓包常量内置，golden 离线确定）。
//
//  被测函数：
//    · EastmoneyQuoteFetcher.decodeChunk(data:response:error:) + beijingDate(fromEpoch:)
//      （f17开/f15高/f16低/f2收/f5量/f6额，f124 按 UTC+8 换算 tradeDate；secid=f13.f12，
//      同码消歧：0.000001 平安银行 vs 1.000001 上证指数 须同时在）
//    · GapBackfill.parseTencentRow(_:)（⚠️ 腾讯 wire 行价格顺序 开-收-高-低，
//      与东财快照 开-高-低-收 不同；r[5]=量(手)、r[8]=额(万元)）
//    · GapBackfill.shared.calibrate(job:rows:mainLatest:)（价格逐字段相等 → 量比吸附
//      1/100/1e-4/1e-7 → 额比哨兵 2% → 缺口行折算；expectedReject=true ↔ anomaly 分支）
//    · EastmoneyQuoteFetcher.secid(forFile:overrides:)（特例表 → 前缀规则 → 覆盖表；
//      Python 侧 27#/62#/102# 返回 None 属有意分工，见 knownDivergence，不硬凑一致）
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

    /// decodeChunk 需要 HTTP 200 响应才会走解析分支（只看 statusCode，不发请求）
    private func okResponse() -> URLResponse {
        // Xcode 26 SDK 起 HTTPURLResponse(url:) 为可失败初始化器（合法 URL + 固定参数不会失败）
        guard let resp = HTTPURLResponse(url: URL(fileURLWithPath: "/kline-contract-test"),
                                         statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            fatalError("HTTPURLResponse 初始化失败（契约测试固定参数，不应发生）")
        }
        return resp
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

    // MARK: - ① 东财批量快照（f17开/f15高/f16低/f2收/f5量/f6额/f124→tradeDate）

    func testEastmoneySnapshotGolden() throws {
        let root = try loadFixture("quote_parsing")
        guard let em = root["eastmoneySnapshot"] as? [String: Any],
              let raw = em["raw"] as? String,
              let golden = em["golden"] as? [[String: Any]] else {
            XCTFail("fixture 缺 eastmoneySnapshot.raw/golden（fixture: quote_parsing.json）")
            return
        }
        let outcome = EastmoneyQuoteFetcher.decodeChunk(data: Data(raw.utf8),
                                                        response: okResponse(), error: nil)
        guard case let .ok(snapshots) = outcome else {
            XCTFail("decodeChunk 应 ok，实际=\(outcome)（fixture: quote_parsing.json → eastmoneySnapshot.raw）")
            return
        }
        XCTAssertEqual(snapshots.count, golden.count,
            "标的数：golden=\(golden.count) swift=\(snapshots.count)"
            + "（fixture: quote_parsing.json → eastmoneySnapshot.golden；"
            + "同码消歧 0.000001 平安银行 与 1.000001 上证指数 都须在）")
        for (i, g) in golden.enumerated() {
            guard let secid = g["secid"] as? String else {
                XCTFail("golden[\(i)] 缺 secid（fixture: quote_parsing.json → eastmoneySnapshot.golden[\(i)]）")
                continue
            }
            let key = "quote_parsing.json → eastmoneySnapshot.golden[\(i)](secid=\(secid))"
            guard let snap = snapshots[secid] else {
                XCTFail("decodeChunk 结果缺 secid=\(secid)（fixture: \(key)）")
                continue
            }
            let fields: [(String, Double?, Any?)] = [
                ("open", snap.open, g["open"]), ("high", snap.high, g["high"]),
                ("low", snap.low, g["low"]), ("close", snap.close, g["close"]),
                ("vol", snap.vol, g["vol"]), ("amo", snap.amo, g["amo"]),
            ]
            for (field, sVal, gVal) in fields {
                guard let gv = num(gVal) else {
                    XCTFail("[em:\(secid)] \(field)：golden 值非法 \(String(describing: gVal))（fixture: \(key).\(field)）")
                    continue
                }
                guard let sv = sVal else {
                    XCTFail("[em:\(secid)] \(field)：swift=nil golden=\(gv)（fixture: \(key).\(field)）")
                    continue
                }
                XCTAssertEqual(sv, gv, accuracy: 1e-6,
                    "[em:\(secid)] \(field)：golden=\(gv) swift=\(sv)（fixture: \(key).\(field)；容差 1e-6）")
            }
            let swiftDate = EastmoneyQuoteFetcher.beijingDate(fromEpoch: snap.ts)
            XCTAssertEqual(swiftDate, intVal(g["tradeDate"]) ?? -1,
                "[em:\(secid)] tradeDate：golden=\(String(describing: g["tradeDate"])) swift=\(String(describing: swiftDate))"
                + "（f124 按 UTC+8 换算；fixture: \(key).tradeDate）")
        }
    }

    // MARK: - ② 腾讯 newfqkline（⚠️ 价格顺序 开-收-高-低）

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

    // MARK: - ③ 自校准 calibrate（价格 → 量比吸附 → 额比哨兵 → 缺口行折算）

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

    // MARK: - ④ file → secid 映射（特例表 → 前缀规则 → 覆盖表）

    private func overrideTable(from root: [String: Any]) -> [String: String] {
        guard let table = root["swiftOverrideTable"] as? [String: Any] else {
            XCTFail("fixture 缺 swiftOverrideTable（fixture: secid_mapping.json）")
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in table {
            if let s = v as? String { out[k] = s }
        }
        return out
    }

    /// Python 非空（rule=special/prefix）条目：Swift 与 golden 必须完全一致。
    /// Python 为 None（rule=override）条目属已知分歧，由 testSecidKnownDivergencePreserved 断言。
    func testSecidMappingConsistency() throws {
        let root = try loadFixture("secid_mapping")
        guard let entries = root["entries"] as? [[String: Any]] else {
            XCTFail("fixture 缺 entries（fixture: secid_mapping.json）")
            return
        }
        let overrides = overrideTable(from: root)
        for (i, e) in entries.enumerated() {
            guard let file = e["file"] as? String else {
                XCTFail("entries[\(i)] 缺 file（fixture: secid_mapping.json → entries[\(i)]）")
                continue
            }
            let rule = (e["rule"] as? String) ?? "-"
            // JSON null → NSNull，as? String 得 nil
            guard let pySecid = e["secid"] as? String else { continue }
            let swiftSecid = EastmoneyQuoteFetcher.secid(forFile: file, overrides: overrides)
            XCTAssertEqual(swiftSecid, pySecid,
                "[secid] rule=\(rule) file=\(file)：golden=\(pySecid) swift=\(String(describing: swiftSecid))"
                + "（fixture: secid_mapping.json → entries[\(i)]）")
        }
    }

    /// 已知分歧必须持续可见：golden 记录 Python=None 的条目，Swift 侧必须有覆盖值（≠ None），
    /// 且实际值与 golden 记录的 Swift 侧一致（防止覆盖表静默漂移）。
    func testSecidKnownDivergencePreserved() throws {
        let root = try loadFixture("secid_mapping")
        guard let divergence = root["knownDivergence"] as? [String: Any],
              let entries = divergence["entries"] as? [[String: Any]] else {
            XCTFail("fixture 缺 knownDivergence.entries（fixture: secid_mapping.json）")
            return
        }
        XCTAssertFalse(entries.isEmpty,
            "knownDivergence.entries 不应为空（分歧条目须持续可见，fixture: secid_mapping.json → knownDivergence）")
        let overrides = overrideTable(from: root)
        for (i, e) in entries.enumerated() {
            guard let file = e["file"] as? String else {
                XCTFail("knownDivergence.entries[\(i)] 缺 file（fixture: secid_mapping.json → knownDivergence.entries[\(i)]）")
                continue
            }
            let actual = EastmoneyQuoteFetcher.secid(forFile: file, overrides: overrides)
            let recordedPython = e["python"] as? String
            let recordedSwift = e["swift"] as? String
            if recordedPython == nil {
                XCTAssertNotNil(actual,
                    "[secid-divergence] file=\(file)：golden 记录 Python=None，Swift 侧也变 nil → 分歧消失/漂移"
                    + "（fixture: secid_mapping.json → knownDivergence.entries[\(i)]）")
                if let rs = recordedSwift {
                    XCTAssertEqual(actual, rs,
                        "[secid-divergence] file=\(file)：golden 记录 Swift=\(rs) 实际=\(String(describing: actual))"
                        + "（覆盖表漂移；fixture: secid_mapping.json → knownDivergence.entries[\(i)]）")
                }
            } else {
                XCTAssertEqual(actual, recordedPython,
                    "[secid-divergence] file=\(file)：golden 记录两侧一致=\(String(describing: recordedPython)) "
                    + "实际 Swift=\(String(describing: actual))"
                    + "（fixture: secid_mapping.json → knownDivergence.entries[\(i)]）")
            }
        }
    }
}

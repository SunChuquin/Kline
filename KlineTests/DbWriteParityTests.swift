//
//  DbWriteParityTests.swift
//  KlineTests
//
//  §9.9 S5 写路径下沉的**双跑对拍**：主库合并（`db_write.py` `main_db_merge`）vs
//  Swift 原实现 `MainDBMerger.mergeLocked`（自 S5 起生产不再调用，保留为本对拍的 oracle）。
//
//  打法：在同一套「临时主库 schema + 同一增量快照」上分别跑两条路径，
//  逐字段比对 ① 结果计数 ② 两库五表内容 ③ `meta.last_date`。
//  —— 引擎未就绪（无引擎构建）→ XCTSkip（降级路径不是失败）。
//

import XCTest
import SQLite3
@testable import Kline

@MainActor
final class DbWriteParityTests: XCTestCase {

    private let allTables = ["daily", "weekly", "monthly", "quarterly", "yearly"]

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

    // MARK: - 临时库构造 / 读取

    /// 建一个临时主库：`meta(id,file,code,name,type,first_date,last_date)` + 指定周期表。
    private func makeTempDB(_ tag: String, metas: [(id: Int, file: String)],
                            tables: [String]) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbwrite_\(tag)_\(UUID().uuidString).db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let metaSQL = "CREATE TABLE meta(id INTEGER PRIMARY KEY, file TEXT, code TEXT, name TEXT, "
            + "type INTEGER, first_date INTEGER, last_date INTEGER);"
        XCTAssertEqual(sqlite3_exec(db, metaSQL, nil, nil, nil), SQLITE_OK)
        for (id, file) in metas {
            let insert = "INSERT INTO meta(id,file,code,name,type,first_date,last_date) "
                + "VALUES(\(id),'\(file)','c\(id)','n\(id)',0,20200101,20200101);"
            XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        }
        for table in tables {
            let create = "CREATE TABLE \(table)(meta_id INTEGER, date INTEGER, open REAL, high REAL, "
                + "low REAL, close REAL, vol REAL, amo REAL, PRIMARY KEY(meta_id,date));"
            XCTAssertEqual(sqlite3_exec(db, create, nil, nil, nil), SQLITE_OK)
        }
        sqlite3_close(db)
        return path
    }

    /// 读回五表全部行（含 meta_id），按 (meta_id,date) 排序 → 可比对的确定性视图。
    private func dumpRows(_ path: String, tables: [String]) -> [[String: Any]] {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return [["error": "open failed"]] }
        defer { sqlite3_close(db) }
        var out: [[String: Any]] = []
        for table in tables {
            var st: OpaquePointer?
            let sql = "SELECT meta_id,date,open,high,low,close,vol,amo FROM \(table) "
                + "ORDER BY meta_id,date;"
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { continue }
            while sqlite3_step(st) == SQLITE_ROW {
                out.append(["table": table,
                            "meta_id": Int(sqlite3_column_int64(st, 0)),
                            "date": Int(sqlite3_column_int64(st, 1)),
                            "open": sqlite3_column_double(st, 2),
                            "high": sqlite3_column_double(st, 3),
                            "low": sqlite3_column_double(st, 4),
                            "close": sqlite3_column_double(st, 5),
                            "vol": sqlite3_column_double(st, 6),
                            "amo": sqlite3_column_double(st, 7)])
            }
            sqlite3_finalize(st)
        }
        return out
    }

    /// 读回 `meta.id → last_date`（升序）。
    private func dumpLastDate(_ path: String) -> [[String: Any]] {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return [["error": "open failed"]] }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id,last_date FROM meta ORDER BY id;", -1, &st, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [[String: Any]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(["id": Int(sqlite3_column_int64(st, 0)),
                        "last_date": Int(sqlite3_column_int64(st, 1))])
        }
        return out
    }

    /// 把读回的视图序列化成确定性 JSON 文本（键序固定）→ 逐字节比较，避免 NSNumber 桥接歧义。
    private func jsonText(_ array: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "<serialize failed>" }
        return text
    }

    // MARK: - 快照构造

    private func row(_ file: String, _ date: Int, close: Double = 10.5) -> LiveIncrementRow {
        LiveIncrementRow(file: file, date: date, open: 10.0, high: 11.0, low: 9.5,
                         close: close, vol: 1000, amo: 10000)
    }

    private func payload(_ snapshot: LiveIncrementSnapshot) -> [String: [[String: Any]]] {
        func json(_ rows: [LiveIncrementRow]) -> [[String: Any]] {
            rows.map { ["file": $0.file, "date": $0.date, "open": $0.open, "high": $0.high,
                        "low": $0.low, "close": $0.close, "vol": $0.vol, "amo": $0.amo] }
        }
        return ["daily": json(snapshot.daily), "weekly": json(snapshot.weekly),
                "monthly": json(snapshot.monthly), "quarterly": json(snapshot.quarterly),
                "yearly": json(snapshot.yearly)]
    }

    /// 引擎 op 必须在后台线程调用（`blockingCall` 断言禁止主线程同步等待 Python）。
    private func runEngineMerge(dbPath: String,
                                snapshot: LiveIncrementSnapshot) async throws -> DbWriteBridge.MainMergeOutcome {
        let body = payload(snapshot)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = DbWriteBridge.mainDBMerge(dbPath: dbPath, snapshot: body)
                cont.resume(with: r.mapError { $0 as Error })
            }
        }
    }

    private func runSwiftMerge(dbPath: String,
                               snapshot: LiveIncrementSnapshot) -> MainMergeResult {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        return MainDBMerger.mergeLocked(db: db, snapshot: snapshot)
    }

    // MARK: - 对拍

    /// 场景 1：两标的、五表齐全，含「主库 meta 里没有的 file」（应计入 skippedNoFile）。
    func testMainDBMergeParityFullTables() async throws {
        try await ensureEngineReady()
        let metas = [(id: 1, file: "SH#600000"), (id: 2, file: "SZ#000001")]
        let swiftDB = try makeTempDB("swift1", metas: metas, tables: allTables)
        let engineDB = try makeTempDB("engine1", metas: metas, tables: allTables)

        var snapshot = LiveIncrementSnapshot()
        snapshot.daily = [row("SH#600000", 20260101), row("SH#600000", 20260102),
                          row("SZ#000001", 20260101), row("BJ#999999", 20260101)]
        snapshot.weekly = [row("SH#600000", 20251229)]
        snapshot.monthly = [row("SZ#000001", 20251201)]
        snapshot.quarterly = [row("SH#600000", 20251001)]
        snapshot.yearly = [row("SZ#000001", 20250101)]

        let a = runSwiftMerge(dbPath: swiftDB, snapshot: snapshot)
        let b = try await runEngineMerge(dbPath: engineDB, snapshot: snapshot)

        XCTAssertEqual(b.ok, a.ok)
        XCTAssertEqual(b.dailyRows, a.dailyRows)
        XCTAssertEqual(b.weeklyRows, a.weeklyRows)
        XCTAssertEqual(b.monthlyRows, a.monthlyRows)
        XCTAssertEqual(b.quarterlyRows, a.quarterlyRows)
        XCTAssertEqual(b.yearlyRows, a.yearlyRows)
        XCTAssertEqual(b.hitSymbols, a.hitSymbols)
        XCTAssertEqual(b.skippedNoFile, a.skippedNoFile)
        XCTAssertEqual(b.latestDate, a.latestDate)
        XCTAssertEqual(jsonText(dumpRows(engineDB, tables: allTables)),
                       jsonText(dumpRows(swiftDB, tables: allTables)))
        XCTAssertEqual(jsonText(dumpLastDate(engineDB)), jsonText(dumpLastDate(swiftDB)))
    }

    /// 场景 2：主库只有 daily / weekly 两张表 → 缺失表的行不写、对应计数为 0。
    func testMainDBMergeParityMissingTables() async throws {
        try await ensureEngineReady()
        let metas = [(id: 7, file: "SH#600519")]
        let present = ["daily", "weekly"]
        let swiftDB = try makeTempDB("swift2", metas: metas, tables: present)
        let engineDB = try makeTempDB("engine2", metas: metas, tables: present)

        var snapshot = LiveIncrementSnapshot()
        snapshot.daily = [row("SH#600519", 20260209)]
        snapshot.weekly = [row("SH#600519", 20260202)]
        snapshot.monthly = [row("SH#600519", 20260201)]
        snapshot.quarterly = [row("SH#600519", 20260101)]
        snapshot.yearly = [row("SH#600519", 20260101)]

        let a = runSwiftMerge(dbPath: swiftDB, snapshot: snapshot)
        let b = try await runEngineMerge(dbPath: engineDB, snapshot: snapshot)

        let aTotal = a.dailyRows + a.weeklyRows + a.monthlyRows + a.quarterlyRows + a.yearlyRows
        let bTotal = b.dailyRows + b.weeklyRows + b.monthlyRows + b.quarterlyRows + b.yearlyRows
        XCTAssertEqual(b.ok, a.ok)
        XCTAssertEqual(bTotal, aTotal)
        XCTAssertEqual(a.monthlyRows, 0)
        XCTAssertEqual(a.quarterlyRows, 0)
        XCTAssertEqual(a.yearlyRows, 0)
        XCTAssertEqual(b.monthlyRows, 0)
        XCTAssertEqual(b.quarterlyRows, 0)
        XCTAssertEqual(b.yearlyRows, 0)
        XCTAssertEqual(b.latestDate, a.latestDate)
        XCTAssertEqual(jsonText(dumpRows(engineDB, tables: present)),
                       jsonText(dumpRows(swiftDB, tables: present)))
        XCTAssertEqual(jsonText(dumpLastDate(engineDB)), jsonText(dumpLastDate(swiftDB)))
    }

    // MARK: - 增量库（行级写 / 裁剪）对拍

    /// 建一个临时增量库：`live_meta` + 五张 `live_*` 周期表（schema 与 `LiveDataStore.schemaSQL` 一致）。
    private func makeTempLiveDB(_ tag: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("livewrite_\(tag)_\(UUID().uuidString).db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "CREATE TABLE live_meta(file TEXT PRIMARY KEY, code TEXT, name TEXT, type TEXT, "
            + "updated_at INTEGER);"
            + "CREATE TABLE live_daily(file TEXT, date INTEGER, open REAL, high REAL, low REAL, "
            + "close REAL, vol REAL, amo REAL, PRIMARY KEY(file, date));"
            + "CREATE TABLE live_weekly(file TEXT, date INTEGER, open REAL, high REAL, low REAL, "
            + "close REAL, vol REAL, amo REAL, PRIMARY KEY(file, date));"
            + "CREATE TABLE live_monthly(file TEXT, date INTEGER, open REAL, high REAL, low REAL, "
            + "close REAL, vol REAL, amo REAL, PRIMARY KEY(file, date));"
            + "CREATE TABLE live_quarterly(file TEXT, date INTEGER, open REAL, high REAL, low REAL, "
            + "close REAL, vol REAL, amo REAL, PRIMARY KEY(file, date));"
            + "CREATE TABLE live_yearly(file TEXT, date INTEGER, open REAL, high REAL, low REAL, "
            + "close REAL, vol REAL, amo REAL, PRIMARY KEY(file, date));"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        return path
    }

    /// 读回增量库全部内容（live_meta + 五表），序列化为确定性 JSON。
    private func dumpLive(_ path: String) -> String {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return "<open failed>" }
        defer { sqlite3_close(db) }
        var meta: [[String: Any]] = []
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT file,code,name,type,updated_at FROM live_meta ORDER BY file;",
                              -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                func text(_ i: Int32) -> String {
                    sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
                }
                meta.append(["file": text(0), "code": text(1), "name": text(2), "type": text(3),
                             "updated_at": Int(sqlite3_column_int64(st, 4))])
            }
        }
        sqlite3_finalize(st)
        var bars: [[String: Any]] = []
        for table in ["live_daily", "live_weekly", "live_monthly", "live_quarterly", "live_yearly"] {
            var q: OpaquePointer?
            let sql = "SELECT file,date,open,high,low,close,vol,amo FROM \(table) ORDER BY file,date;"
            guard sqlite3_prepare_v2(db, sql, -1, &q, nil) == SQLITE_OK else { continue }
            while sqlite3_step(q) == SQLITE_ROW {
                bars.append(["table": table,
                             "file": sqlite3_column_text(q, 0).map { String(cString: $0) } ?? "",
                             "date": Int(sqlite3_column_int64(q, 1)),
                             "open": sqlite3_column_double(q, 2),
                             "high": sqlite3_column_double(q, 3),
                             "low": sqlite3_column_double(q, 4),
                             "close": sqlite3_column_double(q, 5),
                             "vol": sqlite3_column_double(q, 6),
                             "amo": sqlite3_column_double(q, 7)])
            }
            sqlite3_finalize(q)
        }
        return jsonText(meta) + "||" + jsonText(bars)
    }

    /// 后台线程执行（`blockingCall` 断言禁止主线程同步等待 Python）。
    private func onBackground<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func liveBar(_ file: String, _ date: Int, close: Double) -> LiveUpsertBar {
        LiveUpsertBar(file: file, date: date, open: 10.0, high: 11.0, low: 9.5,
                      close: close, vol: 1000, amo: 10000)
    }

    private func liveBarJSON(_ b: LiveUpsertBar) -> [String: Any] {
        ["file": b.file, "date": b.date, "open": b.open, "high": b.high,
         "low": b.low, "close": b.close, "vol": b.vol, "amo": b.amo]
    }

    /// 场景 3：增量库行级写（`live_upsert_daily`）—— 库内已有 meta 行与同值 bar 时只写变化部分。
    func testLiveUpsertDailyParity() async throws {
        try await ensureEngineReady()
        let swiftDB = try makeTempLiveDB("swift3")
        let engineDB = try makeTempLiveDB("engine3")

        // 两边预置同样的「库内现状」：已有 SH#600000 的 meta + 同值日线（不应再写）
        for path in [swiftDB, engineDB] {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
            sqlite3_exec(db, "INSERT INTO live_meta VALUES('SH#600000','600000','浦发','1',100);", nil, nil, nil)
            sqlite3_exec(db, "INSERT INTO live_daily VALUES('SH#600000',20260101,10.0,11.0,9.5,10.5,1000,10000);",
                         nil, nil, nil)
            sqlite3_close(db)
        }

        // 原始入参（**不预筛**：写前比对也在引擎内）
        let inputMetas = [LiveUpsertMeta(file: "SZ#000001", code: "000001", name: "平安", type: "1"),
                          LiveUpsertMeta(file: "SH#600000", code: "600000", name: "浦发", type: "1")]
        let inputBars = [liveBar("SH#600000", 20260101, close: 10.5),   // 与库内同值 → 不应写入
                         liveBar("SH#600000", 20260102, close: 12.5),   // 库内无 → 写入
                         liveBar("SZ#000001", 20260101, close: 20.0)]
        let quarterly = [liveBar("SH#600000", 20260101, close: 33.0)]
        let periodBars = ["quarterly": quarterly]

        // A：Swift oracle（写前比对 + 写语句，对任意 handle 执行）
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(swiftDB, &db), SQLITE_OK)
        let a = LiveDataStore.upsertFullOracle(handle: db!, metas: inputMetas, bars: inputBars,
                                               periodBars: periodBars, updatedAt: 999)
        sqlite3_close(db)

        // B：引擎 op（同原始入参）
        let metasJSON = inputMetas.map { ["file": $0.file, "code": $0.code, "name": $0.name, "type": $0.type] }
        let barsJSON = inputBars.map(liveBarJSON)
        let quarterlyJSON = quarterly.map(liveBarJSON)
        let periodJSON = ["quarterly": quarterlyJSON]
        let b = try await onBackground {
            try DbWriteBridge.liveUpsertDaily(dbPath: engineDB, metas: metasJSON,
                                              metaUpdatedAt: 999, bars: barsJSON,
                                              periodBars: periodJSON).get()
        }

        XCTAssertEqual(b.ok, a.ok)
        XCTAssertEqual(b.metaRows, a.metaRows)
        XCTAssertEqual(b.dailyRows, a.dailyRows)
        XCTAssertEqual(b.quarterlyRows, a.quarterlyRows)
        XCTAssertEqual(b.yearlyRows, a.yearlyRows)
        XCTAssertEqual(b.coveredFiles, a.coveredFiles)
        XCTAssertEqual(b.message, a.message)
        XCTAssertEqual(dumpLive(engineDB), dumpLive(swiftDB))
    }

    /// 场景 4：增量库裁剪（`live_trim`）—— 只执行 DELETE，边界由调用方算。
    func testLiveTrimParity() async throws {
        try await ensureEngineReady()
        let swiftDB = try makeTempLiveDB("swift4")
        let engineDB = try makeTempLiveDB("engine4")
        for path in [swiftDB, engineDB] {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
            for date in [20251201, 20260101, 20260201] {
                sqlite3_exec(db, "INSERT INTO live_daily VALUES('SH#600000',\(date),10,11,9,10.5,1000,10000);",
                             nil, nil, nil)
            }
            for date in [20260101, 20260201] {
                sqlite3_exec(db, "INSERT INTO live_quarterly VALUES('SH#600000',\(date),30,31,29,30.5,1,1);",
                             nil, nil, nil)
            }
            sqlite3_close(db)
        }
        // 日线 `<= 20260101`（含等号）；季线 `< 20260101`（当期桶起始，不含等号）
        let items: [(table: String, bound: Int, inclusive: Bool)] =
            [("live_daily", 20260101, true), ("live_quarterly", 20260101, false)]

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(swiftDB, &db), SQLITE_OK)
        let a = LiveDataStore.trimWriteOracle(handle: db!, items: items)
        sqlite3_close(db)

        let payload = items.map { ["table": $0.table, "bound": $0.bound, "inclusive": $0.inclusive] }
        let b = try await onBackground {
            try DbWriteBridge.liveTrim(dbPath: engineDB, beforeDate: 20260101, items: payload).get()
        }

        XCTAssertEqual(b.ok, a.ok)
        XCTAssertEqual(b.deletedRows, a.deletedRows)
        XCTAssertEqual(dumpLive(engineDB), dumpLive(swiftDB))
    }

    // MARK: - 预取读下沉（`db_query_batch`，§11.42 按批摊薄）

    /// 场景 5：`db_query_batch` —— Swift 侧**同 SQL mirror**（等价 `DatabaseManager.runBarsQuery` 取数口径）
    /// vs 引擎按批读，同库同参双跑比对（含 `vol/amo` 的 REAL 类型判定分支、带/不带 LIMIT 两种请求）。
    func testDBQueryBatchParity() async throws {
        try await ensureEngineReady()
        let metas = [(id: 1, file: "SH#600000"), (id: 2, file: "SZ#000001")]
        let tables = ["daily"]
        let swiftDB = try makeTempDB("swiftq", metas: metas, tables: tables)
        let engineDB = try makeTempDB("engineq", metas: metas, tables: tables)

        for path in [swiftDB, engineDB] {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
            for i in 0..<300 {
                // 每 5 根写一次 INTEGER 型 vol（SQLite 动态类型）→ 覆盖「只有 REAL 才取值，否则 0」分支
                let vol = (i % 5 == 0) ? "1000" : "1000.5"
                let sql = "INSERT INTO daily VALUES(1,\(20250101 + i),10.0,11.0,9.0,10.5,\(vol),10000.0);"
                _ = sqlite3_exec(db, sql, nil, nil, nil)
            }
            // metaID=2：少量行 + 不带 LIMIT 的请求分支
            for i in 0..<40 {
                _ = sqlite3_exec(db, "INSERT INTO daily VALUES(2,\(20250101 + i),20.0,21.0,19.0,20.5,\(i % 7),20000.0);",
                                 nil, nil, nil)
            }
            sqlite3_close(db)
        }

        // A：Swift 侧 mirror（等价 runBarsQuery）
        let a1 = swiftBarsMirror(dbPath: swiftDB, table: "daily", metaID: 1, limit: 250)
        let a2 = swiftBarsMirror(dbPath: swiftDB, table: "daily", metaID: 2, limit: nil)
        // B：引擎按批读（一次调用取两只）
        let b = try await onBackground {
            try DbWriteBridge.dbQueryBatch(dbPath: engineDB, table: "daily",
                                           requests: [(metaID: 1, limit: 250),
                                                      (metaID: 2, limit: nil)]).get()
        }

        XCTAssertEqual(a1.count, 250, "Swift mirror 行数异常")
        XCTAssertEqual(a2.count, 40, "Swift mirror 行数异常（不带 LIMIT）")
        XCTAssertEqual(b.count, 2, "引擎按批读应只返回被请求的两只标的")
        XCTAssertEqual(jsonTextAny(b[1] ?? []), jsonTextAny(a1), "metaID=1 逐行不一致")
        XCTAssertEqual(jsonTextAny(b[2] ?? []), jsonTextAny(a2), "metaID=2（不带 LIMIT）逐行不一致")
    }

    /// Swift 侧 SQL mirror（与 `DatabaseManager.runBarsQuery` 逐字同口径）
    private func swiftBarsMirror(dbPath: String, table: String, metaID: Int, limit: Int?) -> [[Any]] {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var q = "SELECT date, open, high, low, close, vol, amo FROM \(table) WHERE meta_id = ? "
            + "ORDER BY date DESC"
        if limit != nil { q += " LIMIT ?" }
        q += ";"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, q, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, Int64(metaID))
        if let limit { sqlite3_bind_int64(st, 2, Int64(max(1, limit))) }
        var out: [[Any]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            func real(_ i: Int32) -> Double {
                sqlite3_column_type(st, i) == SQLITE_FLOAT ? sqlite3_column_double(st, i) : 0
            }
            out.append([Int(sqlite3_column_int64(st, 0)), real(1), real(2), real(3),
                        real(4), real(5), real(6)])
        }
        return out
    }

    private func jsonTextAny(_ rows: [[Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "<serialize failed>" }
        return text
    }

    // MARK: - §11.39 运行期取证（单元测试 + 沙盒日志）

    private func debugLogURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DebugLogger.fileName)
    }

    private func debugLogTail(afterMarker marker: String) -> String {
        let text = (try? String(contentsOf: debugLogURL(), encoding: .utf8)) ?? ""
        return text.components(separatedBy: marker).last ?? ""
    }

    /// 场景 6：**预取读换执行者**的运行期取证 —— 在**临时主库**上
    /// 「引擎按批取数 `DatabaseManager.mainRowsViaEngineBatch` vs Swift mirror」逐行对拍，
    /// 并用沙盒日志证明**确实走到了引擎**（而非静默回退）。
    ///
    /// 另钉住**主线程误用护栏**（§11.41）：`blockingCall` 断言禁止主线程、`dbQueue.sync` 又在调用线程
    /// 内联执行 → 主线程调用必须先被拦下（返回空 + 记错日志），不得阻塞主线程、更不得崩。
    ///
    /// 刻意**不碰真实单例 / 真实主库**（造价路径与场景 1–5 同款：临时库 + 独立实例）。
    func testPrefetchReadEnginePathParityAndLogEvidence() async throws {
        try await ensureEngineReady()
        let dbPath = try makeTempDB("prefetch", metas: [(id: 1, file: "SH#600000")], tables: ["daily"])

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        for i in 0..<300 {
            // 每 5 根写一次 INTEGER 型 vol → 覆盖「只有 REAL 才取值，否则 0」分支
            let vol = (i % 5 == 0) ? "1000" : "1000.5"
            _ = sqlite3_exec(db, "INSERT INTO daily VALUES(1,\(20250101 + i),10.0,11.0,9.0,10.5,\(vol),10000.0);",
                             nil, nil, nil)
        }
        sqlite3_close(db)

        let marker = "—— prefetch 取证标记 ——"
        DebugLogger.shared.log("[取证] " + marker)

        // ① 主线程误用护栏：本测试方法就在主线程 → 必须返回空 + 记错日志，且**没有**触到引擎
        let onMain = DatabaseManager.mainRowsViaEngineBatch(dbPath: dbPath, table: "daily",
                                                            requests: [(metaID: 1, limit: 250)])
        XCTAssertTrue(onMain.isEmpty, "主线程调用未被拦下 → 会同步阻塞主线程等 Python（Debug 断言崩 / Release 卡死）")
        let afterMain = debugLogTail(afterMarker: marker)
        XCTAssertTrue(afterMain.contains("[DB][错误] mainRowsViaEngineBatch 在主线程被调用"),
                      "主线程调用没有留下错误日志 → 护栏失效（静默）")
        XCTAssertFalse(afterMain.contains("[PyBridge] db_write.py 完成"),
                       "主线程调用竟然走到了引擎 → 护栏没拦住")

        // ② 后台线程调用（生产同款上下文：MarketRowCache.computeQueue）
        let batch = try await onBackground {
            DatabaseManager.mainRowsViaEngineBatch(dbPath: dbPath, table: "daily",
                                                   requests: [(metaID: 1, limit: 250)])
        }
        let engineRows = batch[1] ?? []
        let swiftRows = swiftBarsMirror(dbPath: dbPath, table: "daily", metaID: 1, limit: 250)

        // ③ 沙盒日志证据：桥接每次调用都会写 `[PyBridge] db_write.py 完成（总 …）`
        let tail = debugLogTail(afterMarker: marker)
        XCTAssertTrue(tail.contains("[PyBridge] db_write.py 完成"),
                      "沙盒日志里没有引擎调用行 → 预取**没走到引擎**（静默回退）")

        // ④ 逐行对拍
        XCTAssertEqual(engineRows.count, 250, "引擎取数行数异常")
        XCTAssertEqual(jsonTextAny(engineRows), jsonTextAny(swiftRows), "两路径逐行不一致")

        DebugLogger.shared.log("[取证] 预取对拍完成：rows=\(engineRows.count) 一致，主线程护栏生效")
    }
}

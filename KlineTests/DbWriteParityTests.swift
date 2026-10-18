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
}

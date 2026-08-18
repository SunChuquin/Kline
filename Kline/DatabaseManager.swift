//
//  DatabaseManager.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/8/5.
//

import Foundation
import SQLite3
import Combine

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

class DatabaseManager: ObservableObject {
    static let shared = DatabaseManager()

    private var db: OpaquePointer?

    // 所有 sqlite 操作统一走串行队列，避免多线程并发访问同一连接导致崩溃
    private let dbQueue = DispatchQueue(label: "com.sunck.kline.db.serial")

    @Published var isLoaded = false
    @Published var metaList: [MetaItem] = []
    @Published var errorMessage: String? = nil

    private init() {
        dbQueue.async { [weak self] in
            self?.loadDatabase()
        }
    }

    private func loadDatabase() {
        guard let dbPath = Bundle.main.path(forResource: "tdx", ofType: "db") else {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "数据库文件未找到"
            }
            return
        }

        let fileURL = URL(fileURLWithPath: dbPath)

        if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "无法打开数据库"
            }
            return
        }

        loadMetaList()
    }

    func loadMetaList() {
        dbQueue.async { [weak self] in
            guard let self = self else { return }

            let query = "SELECT id, file, code, name, type, first_date, last_date FROM meta ORDER BY id;"

            var statement: OpaquePointer?

            guard sqlite3_prepare_v2(self.db, query, -1, &statement, nil) == SQLITE_OK else {
                DispatchQueue.main.async {
                    self.errorMessage = "准备查询失败"
                }
                return
            }

            var results: [MetaItem] = []

            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(statement, 0))
                let file = String(cString: sqlite3_column_text(statement, 1))
                let code = String(cString: sqlite3_column_text(statement, 2))
                let name = String(cString: sqlite3_column_text(statement, 3))
                let type = String(cString: sqlite3_column_text(statement, 4))
                let firstDate = sqlite3_column_type(statement, 5) == SQLITE_INTEGER ? Int(sqlite3_column_int64(statement, 5)) : nil
                let lastDate = sqlite3_column_type(statement, 6) == SQLITE_INTEGER ? Int(sqlite3_column_int64(statement, 6)) : nil

                let item = MetaItem(
                    id: id,
                    file: file,
                    code: code,
                    name: name,
                    type: type,
                    firstDate: firstDate,
                    lastDate: lastDate
                )
                results.append(item)
            }

            sqlite3_finalize(statement)

            DispatchQueue.main.async {
                self.metaList = results
                self.isLoaded = true
            }
        }
    }

    /// 读取指定标的全量日线数据
    func fetchDailyData(metaId: Int) -> [KlineItem] {
        dbQueue.sync {
            guard let db = db else { return [] }
            let query = "SELECT date, open, high, low, close, vol, amo FROM daily WHERE meta_id = ? ORDER BY date DESC;"
            return runBarsQuery(db: db, query: query, metaId: metaId)
        }
    }

    /// 读取指定标的全量周线数据
    func fetchWeeklyData(metaId: Int) -> [KlineItem] {
        dbQueue.sync {
            guard let db = db else { return [] }
            let query = "SELECT date, open, high, low, close, vol, amo FROM weekly WHERE meta_id = ? ORDER BY date DESC;"
            return runBarsQuery(db: db, query: query, metaId: metaId)
        }
    }

    /// 统一执行 K 线查询并组装结果（需已在 dbQueue 上）
    private func runBarsQuery(db: OpaquePointer, query: String, metaId: Int) -> [KlineItem] {
        var statement: OpaquePointer?
        var results: [KlineItem] = []
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return results
        }
        sqlite3_bind_int64(statement, 1, Int64(metaId))
        while sqlite3_step(statement) == SQLITE_ROW {
            let date = Int(sqlite3_column_int64(statement, 0))
            let open = sqlite3_column_double(statement, 1)
            let high = sqlite3_column_double(statement, 2)
            let low = sqlite3_column_double(statement, 3)
            let close = sqlite3_column_double(statement, 4)
            let vol = sqlite3_column_type(statement, 5) == SQLITE_FLOAT ? sqlite3_column_double(statement, 5) : 0
            let amo = sqlite3_column_type(statement, 6) == SQLITE_FLOAT ? sqlite3_column_double(statement, 6) : 0
            results.append(KlineItem(date: date, open: open, high: high, low: low, close: close, volume: vol, turnover: amo))
        }
        sqlite3_finalize(statement)
        return results
    }

    func searchMeta(keyword: String) -> [MetaItem] {
        dbQueue.sync {
            performSearch(keyword: keyword)
        }
    }

    func searchMetaAsync(keyword: String, completion: @escaping ([MetaItem]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self else { return }
            let results = self.performSearch(keyword: keyword)
            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    /// 假设已在 dbQueue 上执行，直接做查询
    private func performSearch(keyword: String) -> [MetaItem] {
        guard let db = db else { return [] }
        let query = "SELECT id, file, code, name, type, first_date, last_date FROM meta WHERE name LIKE ? OR code LIKE ? ORDER BY id;"

        var statement: OpaquePointer?
        var results: [MetaItem] = []

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return results
        }

        let searchPattern = "%\(keyword)%"
        sqlite3_bind_text(statement, 1, searchPattern, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, searchPattern, -1, SQLITE_TRANSIENT)

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(statement, 0))
            let file = String(cString: sqlite3_column_text(statement, 1))
            let code = String(cString: sqlite3_column_text(statement, 2))
            let name = String(cString: sqlite3_column_text(statement, 3))
            let type = String(cString: sqlite3_column_text(statement, 4))
            let firstDate = sqlite3_column_type(statement, 5) == SQLITE_INTEGER ? Int(sqlite3_column_int64(statement, 5)) : nil
            let lastDate = sqlite3_column_type(statement, 6) == SQLITE_INTEGER ? Int(sqlite3_column_int64(statement, 6)) : nil

            let item = MetaItem(
                id: id,
                file: file,
                code: code,
                name: name,
                type: type,
                firstDate: firstDate,
                lastDate: lastDate
            )
            results.append(item)
        }

        sqlite3_finalize(statement)
        return results
    }

    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }
}
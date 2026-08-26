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

    /// 沙盒内可写数据库文件名（放在 Documents，可通过 Finder / 文件 App 单独替换更新，无需重装 App）
    static let dbFileName = "tdx.db"

    /// 内置种子数据库路径（随 App 打包）
    private var seedPath: String? {
        Bundle.main.path(forResource: "tdx", ofType: "db")
    }

    /// Documents 下可写数据库路径
    static var writableDBPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(dbFileName).path
    }

    /// 首次启动把内置数据库复制到 Documents，之后统一从 Documents 打开，便于单独更新数据库
    private func loadDatabase() {
        guard ensureWritableDBExists() else { return }
        openDatabase()
    }

    /// 确保 Documents 下存在可写数据库（缺失时从内置副本复制）
    @discardableResult
    private func ensureWritableDBExists() -> Bool {
        let target = Self.writableDBPath
        if FileManager.default.fileExists(atPath: target) { return true }
        guard let seed = seedPath else {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "内置数据库文件未找到"
            }
            return false
        }
        do {
            try FileManager.default.copyItem(atPath: seed, toPath: target)
            return true
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "初始化数据库失败：\(error.localizedDescription)"
            }
            return false
        }
    }

    private func openDatabase() {
        guard ensureWritableDBExists() else { return }
        let path = Self.writableDBPath
        if sqlite3_open(path, &db) != SQLITE_OK {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "无法打开数据库"
            }
            return
        }
        loadMetaList()
    }

    /// 外部替换了 Documents/tdx.db 后调用：关闭旧连接、重开并刷新标的列表
    func reload() {
        dbQueue.async { [weak self] in
            guard let self = self else { return }
            if let db = self.db { sqlite3_close(db); self.db = nil }
            self.openDatabase()
        }
    }

    /// 用内置种子数据库覆盖 Documents 中的数据库（恢复默认数据）后重载
    func restoreSeedDatabase() {
        dbQueue.async { [weak self] in
            guard let self = self, let seed = self.seedPath else { return }
            let target = Self.writableDBPath
            if let db = self.db { sqlite3_close(db); self.db = nil }
            try? FileManager.default.removeItem(atPath: target)
            try? FileManager.default.copyItem(atPath: seed, toPath: target)
            self.openDatabase()
        }
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
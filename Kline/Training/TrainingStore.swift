//
//  TrainingStore.swift
//  Kline
//
//  「K 线单人训练」持久化仓库：独立 sqlite 文件 `Documents/Training/training.db`，
//  与会话 / 成交两张表。自持串行队列 + 连接，所有 sqlite 访问都在 `queue.sync` 上完成，
//  写操作**就地落库、同步可见**（写完立即回读刷新 sessions），训练态与主库 / 增量库 / SimStore 完全隔离。
//  参考 `LiveDataStore` 的连接与队列自管写法。
//

import Foundation
import SQLite3
import Combine

final class TrainingStore: ObservableObject {
    static let shared = TrainingStore()

    /// 训练库文件名（Documents/Training 目录下）
    static let dbFileName = "training.db"

    /// 训练库绝对路径：`Documents/Training/training.db`（目录不存在时首次写入前创建）
    static var databasePath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Training", isDirectory: true)
            .appendingPathComponent(dbFileName).path
    }

    // MARK: 内部状态（**只在 queue 上访问**）

    private let queue = DispatchQueue(label: "com.sunck.kline.training.db.serial")
    private var db: OpaquePointer?

    // MARK: 对外只读信号（主线程发布）

    /// 全部会话记录，按 createdAt 倒序
    @Published private(set) var sessions: [TrainSessionRecord] = []

    /// 建表 DDL（全为 IF NOT EXISTS → 可幂等重复执行，用于补齐缺表 / 索引）
    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS train_session (
          id TEXT PRIMARY KEY, meta_id INTEGER NOT NULL, code TEXT NOT NULL DEFAULT '',
          name TEXT NOT NULL DEFAULT '', start_date INTEGER NOT NULL, end_date INTEGER,
          trade_count INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'running',
          created_at REAL NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS train_trade (
          id TEXT PRIMARY KEY, session_id TEXT NOT NULL, seq INTEGER NOT NULL,
          direction TEXT NOT NULL DEFAULT 'buy', trade_date INTEGER NOT NULL,
          price REAL NOT NULL DEFAULT 0, qty INTEGER NOT NULL DEFAULT 0,
          amount REAL NOT NULL DEFAULT 0, fee REAL NOT NULL DEFAULT 0,
          pnl REAL, note TEXT NOT NULL DEFAULT '',
          trigger TEXT NOT NULL DEFAULT 'manual', cond_kind TEXT, mark TEXT NOT NULL DEFAULT 'B');
        CREATE INDEX IF NOT EXISTS idx_train_trade_session ON train_trade(session_id);
        CREATE TABLE IF NOT EXISTS train_cond (
          id TEXT PRIMARY KEY, session_id TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'monitoring',
          created_date INTEGER NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
          payload TEXT NOT NULL DEFAULT '');
        CREATE INDEX IF NOT EXISTS idx_train_cond_session ON train_cond(session_id);
        CREATE TABLE IF NOT EXISTS train_alert (
          id TEXT PRIMARY KEY, session_id TEXT NOT NULL, cond_id TEXT,
          trade_date INTEGER NOT NULL, price REAL NOT NULL DEFAULT 0,
          message TEXT NOT NULL DEFAULT '', occurred_at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS idx_train_alert_session ON train_alert(session_id);
        """

    private init() {
        // 启动即异步建库并加载一次，不阻塞主线程
        queue.async { [weak self] in
            guard let self = self else { return }
            _ = self._ensureWritableOpenLocked()
            let list = self._loadSessionsLocked()
            DispatchQueue.main.async { self.sessions = list }
        }
    }

    // MARK: - 对外 API

    /// 重新从库加载 sessions（主线程发布）
    func refresh() {
        sessions = queue.sync {
            _ = _ensureWritableOpenLocked()
            return _loadSessionsLocked()
        }
    }

    /// 新建训练会话，返回会话 id（UUID 字符串）
    @discardableResult
    func createSession(metaID: Int, code: String, name: String, startDate: Int) -> String {
        let id = UUID().uuidString
        let now = Date()
        let ok = queue.sync { () -> Bool in
            guard _ensureWritableOpenLocked(), let handle = db else { return false }
            let sql = "INSERT INTO train_session"
                + "(id, meta_id, code, name, start_date, end_date, trade_count, status, created_at, updated_at)"
                + " VALUES(?,?,?,?,?,?,?,?,?,?);"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                DebugLogger.shared.log("[Training] 建会话准备失败：\(String(cString: sqlite3_errmsg(handle)))")
                return false
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 2, Int64(metaID))
            sqlite3_bind_text(statement, 3, code, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 5, Int64(startDate))
            sqlite3_bind_null(statement, 6)
            sqlite3_bind_int64(statement, 7, 0)
            sqlite3_bind_text(statement, 8, TrainSessionStatus.running.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 9, now.timeIntervalSince1970)
            sqlite3_bind_double(statement, 10, now.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                DebugLogger.shared.log("[Training] 建会话落库失败：\(String(cString: sqlite3_errmsg(handle)))")
                return false
            }
            return true
        }
        if ok {
            DebugLogger.shared.log("[Training] 建会话 id=\(id) meta=\(metaID) \(code) \(name) 起始=\(startDate)")
            refresh()
        }
        return id
    }

    /// 追加一笔成交；成功时同步把该会话的 trade_count 自增 1、updated_at 刷新，
    /// 并在同一事务内把「同一训练日既有买入又有卖出」的成交统一提升为 T（做 T 标记）。
    /// - Parameters:
    ///   - trigger: 触发来源（手动 / 条件单），落库供管理页与记录页追溯
    ///   - condKind: 触发它的条件单类型中文名（手动为 nil）
    @discardableResult
    func appendTrade(sessionID: String, seq: Int, direction: SimOrderDirection,
                     tradeDate: Int, price: Double, qty: Int,
                     amount: Double, fee: Double, pnl: Double?, note: String,
                     trigger: TrainTradeTrigger = .manual, condKind: String? = nil) -> Bool {
        let id = UUID().uuidString
        let now = Date()
        let mark: TrainTradeMark = direction == .buy ? .buy : .sell
        let ok = queue.sync { () -> Bool in
            guard _ensureWritableOpenLocked(), let handle = db else { return false }
            // 单事务：插成交 + 刷新会话计数/时间 + 做 T 标记提升，保证要么整体成功、要么整体回滚
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
            var success = false
            let sql = "INSERT INTO train_trade"
                + "(id, session_id, seq, direction, trade_date, price, qty, amount, fee, pnl, note,"
                + " trigger, cond_kind, mark) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?);"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, sessionID, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(statement, 3, Int64(seq))
                sqlite3_bind_text(statement, 4, direction.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(statement, 5, Int64(tradeDate))
                sqlite3_bind_double(statement, 6, price)
                sqlite3_bind_int64(statement, 7, Int64(qty))
                sqlite3_bind_double(statement, 8, amount)
                sqlite3_bind_double(statement, 9, fee)
                if let pnl = pnl {
                    sqlite3_bind_double(statement, 10, pnl)
                } else {
                    sqlite3_bind_null(statement, 10)
                }
                sqlite3_bind_text(statement, 11, note, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 12, trigger.rawValue, -1, SQLITE_TRANSIENT)
                if let condKind = condKind {
                    sqlite3_bind_text(statement, 13, condKind, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(statement, 13)
                }
                sqlite3_bind_text(statement, 14, mark.rawValue, -1, SQLITE_TRANSIENT)
                if sqlite3_step(statement) == SQLITE_DONE {
                    success = _bumpTradeCountLocked(handle, sessionID: sessionID, now: now)
                    if success {
                        success = _promoteDayTradeMarkLocked(handle, sessionID: sessionID, tradeDate: tradeDate)
                    }
                }
                sqlite3_finalize(statement)
            }
            if success {
                sqlite3_exec(handle, "COMMIT;", nil, nil, nil)
            } else {
                DebugLogger.shared.log("[Training] 落库失败(成交) session=\(sessionID)：\(String(cString: sqlite3_errmsg(handle)))")
                sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            }
            return success
        }
        if ok { refresh() }
        return ok
    }

    /// 会话成交计数 +1、updated_at 刷新（须已在事务内）
    private func _bumpTradeCountLocked(_ handle: OpaquePointer, sessionID: String, now: Date) -> Bool {
        let usql = "UPDATE train_session SET trade_count = trade_count + 1, updated_at = ? WHERE id = ?;"
        var update: OpaquePointer?
        guard sqlite3_prepare_v2(handle, usql, -1, &update, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(update) }
        sqlite3_bind_double(update, 1, now.timeIntervalSince1970)
        sqlite3_bind_text(update, 2, sessionID, -1, SQLITE_TRANSIENT)
        return sqlite3_step(update) == SQLITE_DONE
    }

    /// 同一训练日内买入与卖出并存 → 该日全部成交标记为 T（做 T）
    private func _promoteDayTradeMarkLocked(_ handle: OpaquePointer,
                                            sessionID: String, tradeDate: Int) -> Bool {
        let sql = "UPDATE train_trade SET mark = 'T' WHERE session_id = ?1 AND trade_date = ?2"
            + " AND (SELECT COUNT(DISTINCT direction) FROM train_trade"
            + " WHERE session_id = ?1 AND trade_date = ?2) > 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Int64(tradeDate))
        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// 结束会话：写 end_date + status='finished' + updated_at
    func finishSession(id: String, endDate: Int) {
        let now = Date()
        let ok = queue.sync { () -> Bool in
            guard _ensureWritableOpenLocked(), let handle = db else { return false }
            let sql = "UPDATE train_session SET end_date = ?, status = ?, updated_at = ? WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(endDate))
            sqlite3_bind_text(statement, 2, TrainSessionStatus.finished.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
            sqlite3_bind_text(statement, 4, id, -1, SQLITE_TRANSIENT)
            return sqlite3_step(statement) == SQLITE_DONE
        }
        if ok { refresh() }
    }

    /// 某会话的全部成交，按 seq 升序
    func trades(sessionID: String) -> [TrainTradeRecord] {
        queue.sync { _loadTradesLocked(sessionID: sessionID) }
    }

    /// 删除会话及其全部成交
    func deleteSession(id: String) {
        let ok = queue.sync { () -> Bool in
            guard _ensureWritableOpenLocked(), let handle = db else { return false }
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
            var success = true
            for sql in ["DELETE FROM train_trade WHERE session_id = ?;",
                        "DELETE FROM train_cond WHERE session_id = ?;",
                        "DELETE FROM train_alert WHERE session_id = ?;",
                        "DELETE FROM train_session WHERE id = ?;"] {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                    success = false
                    break
                }
                sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
                if sqlite3_step(statement) != SQLITE_DONE { success = false }
                sqlite3_finalize(statement)
                if !success { break }
            }
            if success {
                sqlite3_exec(handle, "COMMIT;", nil, nil, nil)
            } else {
                DebugLogger.shared.log("[Training] 删除会话失败 id=\(id)：\(String(cString: sqlite3_errmsg(handle)))")
                sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            }
            return success
        }
        if ok { refresh() }
    }

    /// 清空全部表
    func deleteAll() {
        let ok = queue.sync { () -> Bool in
            guard _ensureWritableOpenLocked(), let handle = db else { return false }
            return sqlite3_exec(handle,
                                "DELETE FROM train_trade; DELETE FROM train_cond;"
                                + " DELETE FROM train_alert; DELETE FROM train_session;",
                                nil, nil, nil) == SQLITE_OK
        }
        if ok { refresh() }
    }

    // MARK: - 训练条件单 / 预警

    /// 新增或整体替换一条训练条件单（整条 `SimCondOrder` 以 JSON 存 payload）
    @discardableResult
    func upsertCondition(sessionID: String, order: SimCondOrder, createdDate: Int) -> Bool {
        guard let payload = Self.encodeOrder(order) else { return false }
        let now = Date()
        return queue.sync { () -> Bool in
            guard _ensureWritableOpenLocked(), let handle = db else { return false }
            let sql = "INSERT INTO train_cond(id, session_id, status, created_date, created_at, updated_at, payload)"
                + " VALUES(?,?,?,?,?,?,?)"
                + " ON CONFLICT(id) DO UPDATE SET session_id=excluded.session_id, status=excluded.status,"
                + " created_date=excluded.created_date, updated_at=excluded.updated_at, payload=excluded.payload;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, order.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, sessionID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, order.status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 4, Int64(createdDate))
            sqlite3_bind_double(statement, 5, now.timeIntervalSince1970)
            sqlite3_bind_double(statement, 6, now.timeIntervalSince1970)
            sqlite3_bind_text(statement, 7, payload, -1, SQLITE_TRANSIENT)
            return sqlite3_step(statement) == SQLITE_DONE
        }
    }

    /// 某会话的全部训练条件单（updated_at 倒序）
    func conditions(sessionID: String) -> [TrainCondRecord] {
        queue.sync {
            guard _ensureWritableOpenLocked(), let handle = db else { return [] }
            let sql = "SELECT created_date, payload FROM train_cond WHERE session_id = ? ORDER BY updated_at DESC;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, sessionID, -1, SQLITE_TRANSIENT)
            var list: [TrainCondRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let createdDate = Int(sqlite3_column_int64(statement, 0))
                guard let order = Self.decodeOrder(_text(statement, 1)) else { continue }
                list.append(TrainCondRecord(order: order, createdDate: createdDate))
            }
            return list
        }
    }

    /// 删除一条训练条件单
    func deleteCondition(id: String) {
        _ = queue.sync { () -> Bool in
            guard _ensureWritableOpenLocked(), let handle = db else { return false }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM train_cond WHERE id = ?;", -1, &statement, nil) == SQLITE_OK
            else { return false }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
            return sqlite3_step(statement) == SQLITE_DONE
        }
    }

    /// 追加一条训练预警记录（「仅提醒」触发时调用）
    @discardableResult
    func appendAlert(_ record: TrainAlertRecord) -> Bool {
        queue.sync { () -> Bool in
            guard _ensureWritableOpenLocked(), let handle = db else { return false }
            let sql = "INSERT INTO train_alert(id, session_id, cond_id, trade_date, price, message, occurred_at)"
                + " VALUES(?,?,?,?,?,?,?);"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, record.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, record.sessionID, -1, SQLITE_TRANSIENT)
            if let condID = record.condID {
                sqlite3_bind_text(statement, 3, condID, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            sqlite3_bind_int64(statement, 4, Int64(record.tradeDate))
            sqlite3_bind_double(statement, 5, record.price)
            sqlite3_bind_text(statement, 6, record.message, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 7, record.occurredAt.timeIntervalSince1970)
            return sqlite3_step(statement) == SQLITE_DONE
        }
    }

    /// 某会话的全部预警记录（触发时间倒序）
    func alerts(sessionID: String) -> [TrainAlertRecord] {
        queue.sync {
            guard _ensureWritableOpenLocked(), let handle = db else { return [] }
            let sql = "SELECT id, session_id, cond_id, trade_date, price, message, occurred_at"
                + " FROM train_alert WHERE session_id = ? ORDER BY occurred_at DESC;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, sessionID, -1, SQLITE_TRANSIENT)
            var list: [TrainAlertRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                list.append(TrainAlertRecord(
                    id: _text(statement, 0),
                    sessionID: _text(statement, 1),
                    condID: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : _text(statement, 2),
                    tradeDate: Int(sqlite3_column_int64(statement, 3)),
                    price: sqlite3_column_double(statement, 4),
                    message: _text(statement, 5),
                    occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))))
            }
            return list
        }
    }

    /// 条件单 → JSON（编码失败返回 nil）
    private static func encodeOrder(_ order: SimCondOrder) -> String? {
        guard let data = try? JSONEncoder().encode(order) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// JSON → 条件单（解码失败返回 nil，坏档案直接跳过而不是崩）
    private static func decodeOrder(_ json: String) -> SimCondOrder? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SimCondOrder.self, from: data)
    }

    // MARK: - 实现（以下 `_xxxLocked` 均需已在 queue 上执行）

    /// 确保训练库可写并已打开：目录不存在则创建，库不存在则按 schema 新建（幂等）
    private func _ensureWritableOpenLocked() -> Bool {
        if let handle = db { return _ensureSchemaLocked(handle) }
        let path = Self.databasePath
        let dir = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) {
            _ = try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let opened = handle else {
            if handle != nil { sqlite3_close(handle) }
            DebugLogger.shared.log("[Training] 训练库打开失败 path=\(path)")
            return false
        }
        sqlite3_exec(opened, "PRAGMA journal_mode=DELETE;", nil, nil, nil)
        guard sqlite3_exec(opened, Self.schemaSQL, nil, nil, nil) == SQLITE_OK else {
            DebugLogger.shared.log("[Training] 建表失败：\(String(cString: sqlite3_errmsg(opened)))")
            sqlite3_close(opened)
            return false
        }
        db = opened
        DebugLogger.shared.log("[Training] 训练库就绪 path=\(path)")
        return true
    }

    /// 已打开连接的幂等建表（补齐缺表 / 索引），并补齐旧库缺少的成交列
    private func _ensureSchemaLocked(_ handle: OpaquePointer) -> Bool {
        guard sqlite3_exec(handle, Self.schemaSQL, nil, nil, nil) == SQLITE_OK else { return false }
        return _ensureTradeColumnsLocked(handle)
    }

    /// 旧库补列：trigger / cond_kind / mark 三列是后加的，CREATE TABLE IF NOT EXISTS 不会补，
    /// 这里按 PRAGMA table_info 逐个判断后 ALTER（幂等，老训练库无需重建）
    private func _ensureTradeColumnsLocked(_ handle: OpaquePointer) -> Bool {
        let existing = _columnNamesLocked(handle, table: "train_trade")
        let additions: [(String, String)] = [
            ("trigger", "ALTER TABLE train_trade ADD COLUMN trigger TEXT NOT NULL DEFAULT 'manual';"),
            ("cond_kind", "ALTER TABLE train_trade ADD COLUMN cond_kind TEXT;"),
            ("mark", "ALTER TABLE train_trade ADD COLUMN mark TEXT NOT NULL DEFAULT 'B';")
        ]
        for (name, sql) in additions where !existing.contains(name) {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                DebugLogger.shared.log("[Training] 补列失败 \(name)：\(String(cString: sqlite3_errmsg(handle)))")
                return false
            }
        }
        return true
    }

    /// 取某表的全部列名（PRAGMA table_info 的第 1 列）
    private func _columnNamesLocked(_ handle: OpaquePointer, table: String) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            names.insert(_text(statement, 1))
        }
        return names
    }

    /// 读全部会话（createdAt 倒序）
    private func _loadSessionsLocked() -> [TrainSessionRecord] {
        guard let handle = db else { return [] }
        let sql = "SELECT id, meta_id, code, name, start_date, end_date, trade_count, status, created_at, updated_at"
            + " FROM train_session ORDER BY created_at DESC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var list: [TrainSessionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let record = TrainSessionRecord(
                id: _text(statement, 0),
                metaID: Int(sqlite3_column_int64(statement, 1)),
                code: _text(statement, 2),
                name: _text(statement, 3),
                startDate: Int(sqlite3_column_int64(statement, 4)),
                endDate: sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(statement, 5)),
                tradeCount: Int(sqlite3_column_int64(statement, 6)),
                status: TrainSessionStatus(rawValue: _text(statement, 7)) ?? .running,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)))
            list.append(record)
        }
        return list
    }

    /// 读某会话全部成交（seq 升序）
    private func _loadTradesLocked(sessionID: String) -> [TrainTradeRecord] {
        guard let handle = db else { return [] }
        let sql = "SELECT id, session_id, seq, direction, trade_date, price, qty, amount, fee, pnl, note,"
            + " trigger, cond_kind, mark FROM train_trade WHERE session_id = ? ORDER BY seq ASC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID, -1, SQLITE_TRANSIENT)
        var list: [TrainTradeRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let record = TrainTradeRecord(
                id: _text(statement, 0),
                sessionID: _text(statement, 1),
                seq: Int(sqlite3_column_int64(statement, 2)),
                direction: SimOrderDirection(rawValue: _text(statement, 3)) ?? .buy,
                tradeDate: Int(sqlite3_column_int64(statement, 4)),
                price: sqlite3_column_double(statement, 5),
                qty: Int(sqlite3_column_int64(statement, 6)),
                amount: sqlite3_column_double(statement, 7),
                fee: sqlite3_column_double(statement, 8),
                pnl: sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 9),
                note: _text(statement, 10),
                trigger: TrainTradeTrigger(rawValue: _text(statement, 11)) ?? .manual,
                condKind: sqlite3_column_type(statement, 12) == SQLITE_NULL ? nil : _text(statement, 12),
                mark: TrainTradeMark(rawValue: _text(statement, 13)) ?? .buy)
            list.append(record)
        }
        return list
    }

    /// 取文本列（NULL → 空串）
    private func _text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: c)
    }
}

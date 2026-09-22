//
//  MainDBMerger.swift
//  Kline
//
//  「合并到 tdx.db」：把本地增量库（Documents/tdx_live.db）里 daily/weekly/monthly 的行
//  按 `(meta_id, date)` 主键 UPSERT 写回主库（Documents/tdx.db），并同步 `meta.last_date`。
//  映射键 = `file`（如 `SH#600000`，3611/3611 唯一；`code` 有 55 处重复不可用）。
//
//  契约与边界：
//   - 全部写操作在 `DatabaseManager.dbQueue` 上、**单事务**执行；任一步失败 → ROLLBACK，主库原样；
//   - 读增量库必须在 `LiveDataStore` 的队列上取快照（本类先取快照，再回 dbQueue 写），避免跨队列嵌套；
//   - 主库缺 daily/weekly/monthly 中某张表时跳过该表（季/年表不参与合并）；
//   - 合并**不删除**主库任何历史行；完成后把已入主库的日期从增量里裁掉（保留最新 3 个交易日缓冲）；
//   - 不持锁做网络 / 文件 IO；`@Published` 与回调一律在主线程。
//

import Foundation
import SQLite3

// MARK: - 结果契约

/// 合并预估值（点「合并」前展示给用户，供二次确认）
struct MainMergePreview {
    var dailyRows = 0
    var weeklyRows = 0
    var monthlyRows = 0
    /// 命中标的数（去重后的 meta_id 数）
    var hitSymbols = 0
    /// 增量里有、主库 meta 里没有的 file 对应的行数
    var skippedNoFile = 0
    /// 将被写入的最大交易日（YYYYMMDD）
    var latestDate = 0

    var totalRows: Int { dailyRows + weeklyRows + monthlyRows }
    var isMergeable: Bool { totalRows > 0 && hitSymbols > 0 }
}

/// 合并结果统计
struct MainMergeResult {
    var ok = false
    var dailyRows = 0
    var weeklyRows = 0
    var monthlyRows = 0
    /// 命中标的数（被写入的 meta_id 数）
    var hitSymbols = 0
    /// 跳过数（主库 meta 里没有该 file）
    var skippedNoFile = 0
    /// 实际写入的最大交易日（YYYYMMDD）
    var latestDate = 0
    var message = ""

    var totalRows: Int { dailyRows + weeklyRows + monthlyRows }
}

// MARK: - 合并器

final class MainDBMerger {
    static let shared = MainDBMerger()

    /// 合并后增量库保留的最新交易日个数（缓冲，避免下次又必须重下）
    private static let keepLatestTradingDays = 3

    private init() {}

    // MARK: - 预估（不写库）

    /// 估算「合并到 tdx.db」将写入的行数 / 覆盖标的数 / 最新交易日；回调在主线程
    func previewMerge(completion: @escaping (MainMergePreview) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = LiveDataStore.shared.allIncrementRows()
            DatabaseManager.shared.performOnDBQueue({ (db: OpaquePointer?) -> MainMergePreview in
                var preview = MainMergePreview()
                guard let db = db else { return preview }
                let map = MainDBMerger.buildFileMap(db: db)
                var ids = Set<Int>()
                let groups: [(rows: [LiveIncrementRow], table: String)] = [
                    (snapshot.daily, "daily"), (snapshot.weekly, "weekly"), (snapshot.monthly, "monthly"),
                ]
                for group in groups {
                    var count = 0
                    for row in group.rows {
                        guard let metaId = map[row.file] else { preview.skippedNoFile += 1; continue }
                        count += 1
                        ids.insert(metaId)
                        if row.date > preview.latestDate { preview.latestDate = row.date }
                    }
                    switch group.table {
                    case "daily":  preview.dailyRows = count
                    case "weekly": preview.weeklyRows = count
                    default:       preview.monthlyRows = count
                    }
                }
                preview.hitSymbols = ids.count
                return preview
            }, completion: completion)
        }
    }

    // MARK: - 合并（写主库 + 裁剪增量）

    /// 合并增量库 → 主库（单事务 UPSERT），随后裁剪增量并热刷新；回调在主线程
    func mergeIncrementIntoMainDB(completion: @escaping (MainMergeResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = LiveDataStore.shared.allIncrementRows()
            if snapshot.isEmpty {
                var r = MainMergeResult()
                r.message = "增量库无可合并行"
                DispatchQueue.main.async { completion(r) }
                return
            }
            DatabaseManager.shared.performOnDBQueue({ (db: OpaquePointer?) -> MainMergeResult in
                MainDBMerger.mergeLocked(db: db, snapshot: snapshot)
            }, completion: { (result: MainMergeResult) in
                guard result.ok else {
                    completion(result)
                    return
                }
                DebugLogger.shared.log("[Merge] 合并到主库完成：\(result.message)"
                    + " 跳过(主库无此file)=\(result.skippedNoFile)")
                // 主库 last_date 已变 → metaList 需要重读（否则下次按缺口取片会重复下载）
                DatabaseManager.shared.loadMetaList()
                // 把已入主库的日期从增量里裁掉（保留最新 3 个交易日作为缓冲），随后统一热刷新
                let dates = LiveDataStore.shared.newestDates(limit: MainDBMerger.keepLatestTradingDays + 1)
                let finish: (LiveTrimResult?) -> Void = { _ in
                    LiveDataStore.shared.reloadAsync(completion: { summary in
                        // 增量库内容没变（裁剪 0 行）时，主库变化仍需一次全 App 重查
                        if !summary.contentChanged { DatabaseManager.shared.notifyMainDBChanged() }
                        completion(result)
                    })
                }
                if dates.count > MainDBMerger.keepLatestTradingDays {
                    // dates 为 date 降序：dates[3] 是第 4 新的交易日 → 删除 date <= 它即保留最新 3 个
                    LiveDataStore.shared.trim(beforeDate: dates[MainDBMerger.keepLatestTradingDays]) { trimResult in
                        DebugLogger.shared.log("[Merge] 增量裁剪：\(trimResult.message)")
                        finish(trimResult)
                    }
                } else {
                    finish(nil)
                }
            })
        }
    }

    // MARK: - 主库侧实现（全部在 dbQueue 上）

    /// 主库 `file → meta_id` 映射（`file` 3611/3611 唯一，无需歧义处理；`code` 有 55 处重复，不能用）
    private static func buildFileMap(db: OpaquePointer) -> [String: Int] {
        var byFile: [String: Int] = [:]
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, file FROM meta ORDER BY id ASC;", -1, &statement, nil) == SQLITE_OK else {
            return byFile
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 1) else { continue }
            let file = String(cString: text)
            if byFile[file] == nil { byFile[file] = Int(sqlite3_column_int64(statement, 0)) }
        }
        return byFile
    }

    /// 主库是否存在某张周期表
    private static func mainTableExists(db: OpaquePointer, name: String) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// 单事务合并（**已在 dbQueue 上**）
    private static func mergeLocked(db: OpaquePointer?, snapshot: LiveIncrementSnapshot) -> MainMergeResult {
        var r = MainMergeResult()
        guard let db = db else {
            r.message = "主库未就绪（连接不可用）"
            return r
        }
        let files = buildFileMap(db: db)
        guard !files.isEmpty else {
            r.message = "主库 meta 为空，无法合并"
            return r
        }
        let present = ["daily", "weekly", "monthly"].filter { mainTableExists(db: db, name: $0) }
        guard !present.isEmpty else {
            r.message = "主库缺少 daily/weekly/monthly 表，无法合并"
            return r
        }

        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            r.message = "开启事务失败：\(String(cString: sqlite3_errmsg(db)))"
            return r
        }

        // 预编译 INSERT OR REPLACE（用 prepared statement 循环 bind，绝不逐行拼 SQL）
        var statements: [String: OpaquePointer] = [:]
        var failed: String?
        for table in present {
            var statement: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO \(table)(meta_id,date,open,high,low,close,vol,amo) "
                    + "VALUES(?,?,?,?,?,?,?,?);"
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement = statement {
                statements[table] = statement
            } else {
                failed = "准备 \(table) 语句失败：\(String(cString: sqlite3_errmsg(db)))"
                break
            }
        }

        var hitIds = Set<Int>()
        var maxDateByMetaId: [Int: Int] = [:]
        if failed == nil {
            let groups: [(table: String, rows: [LiveIncrementRow])] = [
                ("daily", snapshot.daily), ("weekly", snapshot.weekly), ("monthly", snapshot.monthly),
            ]
            for group in groups {
                guard let statement = statements[group.table] else { continue }
                var written = 0
                for row in group.rows {
                    guard let metaId = files[row.file] else {
                        r.skippedNoFile += 1
                        continue
                    }
                    sqlite3_reset(statement)
                    sqlite3_bind_int64(statement, 1, Int64(metaId))
                    sqlite3_bind_int64(statement, 2, Int64(row.date))
                    sqlite3_bind_double(statement, 3, row.open)
                    sqlite3_bind_double(statement, 4, row.high)
                    sqlite3_bind_double(statement, 5, row.low)
                    sqlite3_bind_double(statement, 6, row.close)
                    sqlite3_bind_double(statement, 7, row.vol)
                    sqlite3_bind_double(statement, 8, row.amo)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        failed = "写入 \(group.table) 失败（file=\(row.file) date=\(row.date)）："
                            + String(cString: sqlite3_errmsg(db))
                        break
                    }
                    written += 1
                    hitIds.insert(metaId)
                    if row.date > r.latestDate { r.latestDate = row.date }
                    if row.date > (maxDateByMetaId[metaId] ?? 0) { maxDateByMetaId[metaId] = row.date }
                }
                if failed != nil { break }
                switch group.table {
                case "daily":   r.dailyRows = written
                case "weekly":  r.weeklyRows = written
                default:        r.monthlyRows = written
                }
            }
        }

        // 更新 meta.last_date（该 file 在增量里的最大 date）
        if failed == nil {
            var update: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE meta SET last_date = ? WHERE id = ?;", -1, &update, nil) == SQLITE_OK,
               let update = update {
                for (metaId, date) in maxDateByMetaId {
                    sqlite3_reset(update)
                    sqlite3_bind_int64(update, 1, Int64(date))
                    sqlite3_bind_int64(update, 2, Int64(metaId))
                    if sqlite3_step(update) != SQLITE_DONE {
                        failed = "更新 meta.last_date 失败（id=\(metaId)）：\(String(cString: sqlite3_errmsg(db)))"
                        break
                    }
                }
                sqlite3_finalize(update)
            } else {
                failed = "准备 meta.last_date 语句失败：\(String(cString: sqlite3_errmsg(db)))"
            }
        }

        for statement in statements.values { sqlite3_finalize(statement) }
        r.hitSymbols = hitIds.count

        if let failed = failed {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            r.ok = false
            r.dailyRows = 0
            r.weeklyRows = 0
            r.monthlyRows = 0
            r.hitSymbols = 0
            r.latestDate = 0
            r.message = "合并失败（已回滚）：\(failed)"
            return r
        }
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            r.message = "提交失败（已回滚）：\(String(cString: sqlite3_errmsg(db)))"
            return r
        }
        r.ok = true
        r.message = "已合并 \(r.totalRows) 行（日\(r.dailyRows)/周\(r.weeklyRows)/月\(r.monthlyRows)）"
            + " · 覆盖 \(r.hitSymbols) 只 · 最新 \(r.latestDate)"
        return r
    }
}
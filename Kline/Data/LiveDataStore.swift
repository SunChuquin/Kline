//
//  LiveDataStore.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/9/22.
//
//  增量库读写层：`Documents/tdx_live.db`（外部 USB / 局域网整文件推送，或本类按缺口合并云端分片）。
//  **键 = `file`**（如 `SH#600000`）：主库 meta 的 `file` 3611/3611 唯一；`code` 有 55 处重复
//  （指数与股票同码，如 `62#000995` 全指公用 vs `SZ#000995` 皇台酒业），不可作键。
//  能力：
//   1) 打开 / 校验增量库（缺失、打不开、缺 live_meta 表 → 静默降级 isAvailable=false，不抛异常）；
//   2) 按 file 取某周期表的全部增量行（进程内按 file 缓存，避免重复走 SQL），并给出该 file 的 minDate；
//   3) 指纹 = (size, mtime) 快速键 + 可选 sha256（CryptoKit，iOS 13+）；
//   4) reload()：清缓存、关旧连接、重开、重算指纹、更新 isAvailable，返回重载前后行数 / 日期区间；
//   5) startWatching(interval:)：前台定时指纹检查（指纹未变则什么都不做）+ 回前台立即检查一次；
//   6) **写入**：`mergeBucket(atPath:)` 把云端分片（`bkt_meta/bkt_daily/bkt_weekly/bkt_monthly`）
//      合并进本地 `live_meta/live_daily/live_weekly/live_monthly`（INSERT OR REPLACE，同 date 以分片为准）；
//      `trim(beforeDate:)` 删掉主库已有的冗余日期；本地库不存在时按 schema 新建。
//  只发布 daily/weekly/monthly（季/年线无法被有限窗口完整覆盖 → 视图回落主库）。
//
//  硬约束：
//   - 主库 `tdx.db` 全程只读不改（写回主库是 `MainDBMerger` 显式动作）；增量库不可用时行为与「没有本类」完全一致；
//   - 自持独立串行队列 `com.sunck.kline.live.db.serial`，**绝不**与 `DatabaseManager.dbQueue`
//     交叉嵌套同步（本类任何方法都不会在持锁状态下回调 DatabaseManager，反向亦然）；
//   - 所有 @Published / 通知一律回主线程发布；
//   - 内部写入后刷新自身指纹 `fp`（避免 5 分钟轮询把自写当外部写入），内容变化判定走 `appliedHash`，
//     由随后的 `reloadAsync()` 统一发布一次（不重复发 @Published）。
//

import Foundation
import SQLite3
import Combine
import CryptoKit
import UIKit

// MARK: - 数据契约

/// 某 file 在某周期表上的增量切片（date 降序，与主库查询返回顺序一致）
struct LiveSlice {
    /// 按 date **降序**（新 → 旧）
    var items: [KlineItem] = []
    /// 最小 date（主库补齐切分点：主库只补 `date < minDate` 的部分）；items 为空时无意义
    var minDate: Int = 0
    /// 最大 date；items 为空时无意义
    var maxDate: Int = 0

    var isEmpty: Bool { items.isEmpty }
}

/// 增量库指纹：快速键 (size, mtime) + 内容 sha256
struct LiveDBFingerprint: Equatable {
    var size: Int64 = 0
    var mtime: TimeInterval = 0
    /// 文件内容 sha256（读取失败时为 nil）
    var sha256: String?

    /// 供日志 / 去重使用的展示串：`size-mtime-sha256前8位`
    var display: String {
        let hash = sha256.map { String($0.prefix(8)) } ?? "-"
        return "\(size)-\(Int(mtime))-\(hash)"
    }
}

/// 一次 reload 的摘要（供热刷新日志与外部通知）
struct LiveReloadSummary {
    var reason: String = ""
    /// 增量库是否可用（表齐全、能查询）
    var isAvailable: Bool = false
    /// 重载前是否可用
    var wasAvailable: Bool = false
    /// 内容是否**确实**变化（sha256 变化 或 可用性翻转）；仅此项为 true 才应触发全 App 重查
    var contentChanged: Bool = false
    var metaCountBefore: Int = 0
    var metaCountAfter: Int = 0
    var dailyCountBefore: Int = 0
    var dailyCountAfter: Int = 0
    var latestDateBefore: Int = 0
    var latestDateAfter: Int = 0
    /// 增量库内最早交易日（YYYYMMDD，0 表示无）
    var earliestDateBefore: Int = 0
    var earliestDateAfter: Int = 0
    var fingerprintBefore: String = "-"
    var fingerprintAfter: String = "-"
    var elapsed: TimeInterval = 0
}

/// 增量库对外状态快照（**在主线程更新**，供「数据同步」状态 UI 与 `GET /sync/status` 读取）
struct LiveStatusSnapshot {
    /// 增量库是否可用（缺失 / 打不开 / 缺表 → false，App 走纯主库）
    var isAvailable = false
    /// 指纹展示串 `size-mtime-sha256前8位`
    var fingerprint = "-"
    /// 覆盖标的数（live_meta 行数；键为 `file`）
    var metaCount = 0
    /// 日线行数（live_daily 行数）
    var dailyCount = 0
    /// 增量库内最新交易日（YYYYMMDD，0 表示无）
    var latestDate = 0
    /// 增量库内最早交易日（YYYYMMDD，0 表示无）
    var earliestDate = 0
    /// 已热重载次数（仅内容确实变化时自增）
    var reloadCount = 0
    /// 增量库绝对路径
    var path = LiveDataStore.writableDBPath
}

/// 分片合并结果（云端 `bucket_<id>.db` → 本地 `tdx_live.db`）
struct LiveMergeResult {
    var ok = false
    /// 本次实际写入（INSERT OR REPLACE）的各表行数
    var dailyRows = 0
    var weeklyRows = 0
    var monthlyRows = 0
    var metaRows = 0
    /// 合并后本地增量库覆盖的 file 数（live_meta 行数）
    var coveredFiles = 0
    var message = ""
}

/// 增量裁剪结果
struct LiveTrimResult {
    var ok = false
    var deletedRows = 0
    var message = ""
}

/// 增量库 meta 行（file 为键；code 仅作展示 / 辅助）
struct LiveIncrementMeta {
    var file: String
    var code: String
    var name: String
    var type: String
}

/// 增量库某周期表的一行（供 MainDBMerger 在主库事务里回写；键 = file）
struct LiveIncrementRow {
    var file: String
    var date: Int
    var open: Double
    var high: Double
    var low: Double
    var close: Double
    var vol: Double
    var amo: Double
}

/// 增量库三表 + meta 的全量快照（在 LiveDataStore 队列上取出后交主库写）
struct LiveIncrementSnapshot {
    var meta: [LiveIncrementMeta] = []
    var daily: [LiveIncrementRow] = []
    var weekly: [LiveIncrementRow] = []
    var monthly: [LiveIncrementRow] = []

    var isEmpty: Bool { daily.isEmpty && weekly.isEmpty && monthly.isEmpty }
}

// MARK: - 增量库读取层

final class LiveDataStore: ObservableObject {
    static let shared = LiveDataStore()

    /// 增量库文件名（Documents 下，由外部推送覆盖）
    static let dbFileName = "tdx_live.db"

    /// 增量库只发布的周期表（与主库同名、同字段；**本地实际表名带 `live_` 前缀**）。
    /// 季/年线不发布 → `slice(file:table:)` 对它们返回 nil，查询层自然回落主库。
    static let periodTables = ["daily", "weekly", "monthly"]

    /// 云端分片表名 → 本地表名 的显式映射（分片由生成端发布，表名带 `bkt_` 前缀）
    static let bucketTableMap: [(local: String, bucket: String)] = [
        ("live_daily", "bkt_daily"),
        ("live_weekly", "bkt_weekly"),
        ("live_monthly", "bkt_monthly"),
    ]

    /// 本地表结构（v3：键为 `file`；本地增量库不存在时按此新建）
    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS live_meta(file TEXT PRIMARY KEY, code TEXT, name TEXT,
                     type TEXT, updated_at INTEGER);
        CREATE TABLE IF NOT EXISTS live_daily(file TEXT, date INTEGER, open REAL, high REAL, low REAL,
                     close REAL, vol REAL, amo REAL, PRIMARY KEY(file, date));
        CREATE TABLE IF NOT EXISTS live_weekly(file TEXT, date INTEGER, open REAL, high REAL, low REAL,
                     close REAL, vol REAL, amo REAL, PRIMARY KEY(file, date));
        CREATE TABLE IF NOT EXISTS live_monthly(file TEXT, date INTEGER, open REAL, high REAL, low REAL,
                     close REAL, vol REAL, amo REAL, PRIMARY KEY(file, date));
        """

    /// 旧版（`code` 键）增量库的表清理：增量内容可由分片完全重建，故直接丢弃
    private static let dropLegacySQL = """
        DROP TABLE IF EXISTS live_daily;
        DROP TABLE IF EXISTS live_weekly;
        DROP TABLE IF EXISTS live_monthly;
        DROP TABLE IF EXISTS live_quarterly;
        DROP TABLE IF EXISTS live_yearly;
        DROP TABLE IF EXISTS live_meta;
        """

    /// Documents 下的增量库路径
    static var writableDBPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(dbFileName).path
    }

    // MARK: 对外只读信号（一律在主线程发布）

    /// 最近一次计算 / 重载得到的指纹展示串（未找到文件为 "-"）
    @Published private(set) var fingerprint: String = "-"
    /// 增量库当前是否可用
    @Published private(set) var isAvailable: Bool = false
    /// 已重载次数（仅真正重开连接时自增）
    @Published private(set) var reloadCount: Int = 0
    /// 对外状态快照（主线程更新；供状态 UI 与 /sync/status 读取）
    @Published private(set) var status = LiveStatusSnapshot()

    /// 热重载完成信号（主线程发送）。订阅方按 `contentChanged` 过滤后再刷新数据。
    private let reloadSubject = PassthroughSubject<LiveReloadSummary, Never>()
    var reloadPublisher: AnyPublisher<LiveReloadSummary, Never> { reloadSubject.eraseToAnyPublisher() }

    // MARK: 内部状态（**只在 queue 上访问**）

    private let queue = DispatchQueue(label: "com.sunck.kline.live.db.serial")
    private var db: OpaquePointer?
    private var available = false
    private var fp: LiveDBFingerprint?
    /// 最近一次**已发布/已生效**的内容哈希：内容变化判定以此为准（而不是当前文件指纹 fp）。
    /// 这样「内部写入后先刷新 fp（避免 5 分钟轮询误判为外部写入）→ 再由 reloadAsync 统一发布」
    /// 仍能正确判定为一次内容变化。
    private var appliedHash: String?
    /// 周期名（daily/weekly/…）→ 本地真实表名（live_daily / 兼容旧的无前缀命名）
    private var liveTableNames: [String: String] = [:]
    /// 增量库覆盖的 file 集合（来自 live_meta，用于精确失效行缓存）
    private var covered: Set<String> = []
    /// table → file → 切片（含「已查过、确无增量行」的空切片，避免重复走 SQL）
    private var cache: [String: [String: LiveSlice]] = [:]
    private var metaCount = 0
    private var dailyCount = 0
    private var latestDate = 0
    private var earliestDate = 0

    // MARK: 观察器状态（**只在主线程访问**）

    private var timer: Timer?
    private var isWatching = false
    private var foregroundObserver: NSObjectProtocol?

    private init() {
        // 启动即异步尝试打开，不阻塞调用方线程
        queue.async { [weak self] in
            guard let self = self else { return }
            let summary = self._reloadLocked(reason: "启动首次打开")
            self._publishSummary(summary, notify: false)
        }
    }

    // MARK: - 取数：某 file 在某周期表的全部增量行

    /// 某 file（如 `SH#600000`）在某周期表上的全部增量行（date 降序）。
    /// - 增量库不可用 / 表名不合法（含季/年线）→ 返回 nil（调用方走纯主库路径）；
    /// - 该 file 无增量行 → 返回空切片（`isEmpty == true`）。
    func slice(file: String, table: String) -> LiveSlice? {
        guard !file.isEmpty, Self.periodTables.contains(table) else { return nil }
        return queue.sync {
            guard available, db != nil else { return nil }
            return _sliceLocked(file: file, table: table)
        }
    }

    /// 增量库覆盖的全部 `file`（用于「只重取受影响的行」）；不可用或为空集合 → 返回空集合
    func coveredFiles() -> Set<String> {
        queue.sync { covered }
    }

    /// 最近一次计算 / 重载得到的完整指纹（含 sha256）；未找到文件时 nil
    func currentFingerprint() -> LiveDBFingerprint? {
        queue.sync { fp }
    }

    /// 三表 + meta 的全量快照（在自身队列上取出，供 MainDBMerger 回写主库；不可用时为空快照）
    func allIncrementRows() -> LiveIncrementSnapshot {
        queue.sync { _allIncrementRowsLocked() }
    }

    /// 本地增量库日线里最新的 `limit` 个**不同**交易日（date 降序）；数据库不可用时返回空数组
    func newestDates(limit: Int) -> [Int] {
        queue.sync { _newestDatesLocked(limit: limit) }
    }

    // MARK: - 写入：合并云端分片 / 裁剪冗余（**全部在自身队列上**）

    /// 把云端分片 `bucket_<id>.db` 合并进本地 `tdx_live.db`：
    /// ATTACH 分片 → 单事务内 `INSERT OR REPLACE`（同 date 以分片为准）→ DETACH；
    /// 本地增量库不存在时按 schema 新建。completion 在主线程回调。
    func mergeBucket(atPath path: String, completion: @escaping (LiveMergeResult) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = self._mergeBucketLocked(atPath: path)
            if result.ok { self._refreshAfterInternalWriteLocked(reason: "内部写入合并") }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 删除本地增量三表中 `date <= beforeDate` 的行（主库已有 → 冗余），单事务；completion 在主线程回调
    func trim(beforeDate: Int, completion: @escaping (LiveTrimResult) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = self._trimLocked(beforeDate: beforeDate)
            if result.ok && result.deletedRows > 0 { self._refreshAfterInternalWriteLocked(reason: "内部裁剪") }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - 重载与指纹检查

    /// 清缓存、关旧连接、重开、重算指纹、更新 isAvailable，并返回重载摘要（同步，供日志 / 手动调用）
    @discardableResult
    func reload() -> LiveReloadSummary {
        let summary = queue.sync { _reloadLocked(reason: "手动 reload") }
        _publishSummary(summary, notify: true)
        return summary
    }

    /// 异步重载（Task 4 预留：云端拉取完成、原子替换文件后调用）；completion 在主线程回调
    func reloadAsync(completion: ((LiveReloadSummary) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let summary = self._reloadLocked(reason: "异步 reload")
            self._publishSummary(summary, notify: true)
            if let completion = completion {
                DispatchQueue.main.async { completion(summary) }
            }
        }
    }

    /// 立即做一次指纹检查（异步；指纹未变则什么都不做，不重开连接、不清缓存）
    func checkForChanges(reason: String = "手动检查") {
        queue.async { [weak self] in
            guard let self = self else { return }
            _ = self._checkLocked(reason: reason)
        }
    }

    /// Task 4 预留入口：外部（USB / 局域网 / 云端）写入完成后调用，立即检查指纹并按需热刷新
    func notifyExternalWrite() {
        DebugLogger.shared.log("[Live] 收到外部写入通知 → 立即检查指纹")
        checkForChanges(reason: "外部写入")
    }

    // MARK: - 前台监视

    /// 前台每 interval 秒检查一次指纹；另在回前台时立即检查一次（幂等，重复调用只生效一次）
    func startWatching(interval: TimeInterval = 300) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isWatching else { return }
            self.isWatching = true
            self.scheduleTimer(interval: interval)
            self.observeForeground()
            DebugLogger.shared.log("[Live] 指纹监视启动 interval=\(Int(interval))s path=\(Self.writableDBPath)")
        }
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        // Timer 只在前台 run loop 上走，App 切后台自然停摆；回前台由通知补一次检查
        let t = Timer.scheduledTimer(withTimeInterval: Swift.max(5, interval), repeats: true) { [weak self] _ in
            self?.checkForChanges(reason: "定时指纹检查")
        }
        t.tolerance = 5
        timer = t
    }

    private func observeForeground() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            self?.checkForChanges(reason: "回前台指纹检查")
        }
    }

    // MARK: - 实现（以下 `_xxxLocked` 均需已在 queue 上执行）

    /// 指纹检查：快速键未变 → 直接返回；变了 → 精算 sha256，内容确实变化才重载
    @discardableResult
    private func _checkLocked(reason: String) -> Bool {
        let path = Self.writableDBPath
        let quick = Self.quickKey(ofPath: path)
        if let quick = quick, let cur = fp,
           cur.size == quick.size, abs(cur.mtime - quick.mtime) < 0.0001 {
            return false        // 指纹未变：什么都不做
        }
        if quick == nil, fp == nil, !available {
            return false        // 一直没有增量库：什么都不做
        }
        // 时间戳变了 → 精算内容指纹，避免「仅仅重新拷贝了同一份文件」触发全 App 重查
        let full = Self.fullFingerprint(ofPath: path)
        if let full = full, let cur = fp, cur.sha256 != nil, full.sha256 == cur.sha256 {
            fp = full           // 只更新 size/mtime，不动连接、不清缓存
            DebugLogger.shared.log("[Live] 指纹时间戳变化但内容一致（sha256 未变）→ 跳过热重载 reason=\(reason)")
            return false
        }
        let summary = _reloadLocked(reason: reason)
        _publishSummary(summary, notify: true)
        return true
    }

    /// 关旧连接 + 清缓存 + 重开 + 重算指纹/行数，全部在 queue 上完成
    private func _reloadLocked(reason: String) -> LiveReloadSummary {
        let t0 = Date()
        var s = LiveReloadSummary(reason: reason)
        s.wasAvailable = available
        s.metaCountBefore = metaCount
        s.dailyCountBefore = dailyCount
        s.latestDateBefore = latestDate
        s.earliestDateBefore = earliestDate
        s.fingerprintBefore = fp?.display ?? "-"
        let previousKnown = (fp != nil) || available
        // 内容变化判定以「最近一次已发布内容」为准（fp 可能已被内部写入刷新，见 mergeBucket/trim）
        let oldHash = appliedHash ?? fp?.sha256

        // 1) 清缓存 + 关旧连接
        _closeLocked()
        cache.removeAll()
        covered.removeAll()
        liveTableNames.removeAll()
        metaCount = 0
        dailyCount = 0
        latestDate = 0
        earliestDate = 0

        // 2) 重算指纹
        let path = Self.writableDBPath
        let newFP = Self.fullFingerprint(ofPath: path)
        fp = newFP

        guard let newFP = newFP else {
            s.isAvailable = false
            s.fingerprintAfter = "-"
            s.contentChanged = previousKnown && s.wasAvailable
            appliedHash = nil
            s.elapsed = Date().timeIntervalSince(t0)
            DebugLogger.shared.log("[Live] 增量库不存在 → 降级「仅主库」 path=\(path) 耗时=\(Self.ms(s.elapsed))")
            return s
        }

        // 3) 重开连接（默认可读写：USB/LAN 整文件替换后仍可被内部合并/裁剪写回）
        var handle: OpaquePointer?
        if sqlite3_open(path, &handle) != SQLITE_OK || handle == nil {
            if handle != nil { sqlite3_close(handle) }
            s.isAvailable = false
            s.fingerprintAfter = newFP.display
            s.contentChanged = previousKnown && (s.wasAvailable || oldHash != newFP.sha256)
            appliedHash = nil
            s.elapsed = Date().timeIntervalSince(t0)
            DebugLogger.shared.log("[Live] 增量库打不开 → 降级「仅主库」 path=\(path)")
            return s
        }
        sqlite3_exec(handle, "PRAGMA journal_mode=DELETE;", nil, nil, nil)

        // 4) 校验契约（必须有 live_meta）
        guard _hasTableLocked(handle!, "live_meta") else {
            sqlite3_close(handle)
            s.isAvailable = false
            s.fingerprintAfter = newFP.display
            s.contentChanged = previousKnown && (s.wasAvailable || oldHash != newFP.sha256)
            appliedHash = nil
            s.elapsed = Date().timeIntervalSince(t0)
            DebugLogger.shared.log("[Live] 增量库缺 live_meta 表 → 降级「仅主库」 path=\(path)")
            return s
        }

        db = handle
        available = true
        _loadLiveTableNamesLocked(handle!)
        _loadCoveredLocked()
        metaCount = _scalarLocked(handle!, sql: "SELECT COUNT(*) FROM live_meta;")
        dailyCount = _scalarLocked(handle!, sql: "SELECT COUNT(*) FROM live_daily;")
        latestDate = _scalarLocked(handle!, sql: "SELECT MAX(date) FROM live_daily;")
        earliestDate = _scalarLocked(handle!, sql: "SELECT MIN(date) FROM live_daily;")
        appliedHash = newFP.sha256

        s.isAvailable = true
        s.metaCountAfter = metaCount
        s.dailyCountAfter = dailyCount
        s.latestDateAfter = latestDate
        s.earliestDateAfter = earliestDate
        s.fingerprintAfter = newFP.display
        s.contentChanged = previousKnown && (!s.wasAvailable || oldHash != newFP.sha256)
        s.elapsed = Date().timeIntervalSince(t0)

        DebugLogger.shared.log("[Live] 重载完成 reason=\(reason) 覆盖=\(metaCount)只/日线\(dailyCount)行 区间=\(earliestDate == 0 ? "-" : String(earliestDate))~\(latestDate == 0 ? "-" : String(latestDate)) 耗时=\(Self.ms(s.elapsed)) 指纹 \(s.fingerprintBefore) → \(s.fingerprintAfter) 内容变化=\(s.contentChanged)")
        return s
    }

    private func _closeLocked() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
        available = false
    }

    /// 某 file 在某表的切片（走 cache；未命中则查一次并把结果（含空结果）写回 cache）
    private func _sliceLocked(file: String, table: String) -> LiveSlice {
        if let hit = cache[table]?[file] { return hit }

        var slice = LiveSlice()
        // 本地增量库表名带 `live_` 前缀（periodTables 里的 daily → live_daily）
        guard let localTable = _localTableNameLocked(table) else {
            cache[table, default: [:]][file] = slice
            return slice
        }
        let query = "SELECT date, open, high, low, close, vol, amo FROM \(localTable) WHERE file = ? ORDER BY date DESC;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, file, -1, SQLITE_TRANSIENT)
            while sqlite3_step(statement) == SQLITE_ROW {
                let date = Int(sqlite3_column_int64(statement, 0))
                let open = sqlite3_column_double(statement, 1)
                let high = sqlite3_column_double(statement, 2)
                let low = sqlite3_column_double(statement, 3)
                let close = sqlite3_column_double(statement, 4)
                let vol = sqlite3_column_type(statement, 5) == SQLITE_FLOAT ? sqlite3_column_double(statement, 5) : 0
                let amo = sqlite3_column_type(statement, 6) == SQLITE_FLOAT ? sqlite3_column_double(statement, 6) : 0
                slice.items.append(KlineItem(date: date, open: open, high: high, low: low,
                                             close: close, volume: vol, turnover: amo))
            }
            sqlite3_finalize(statement)
        }
        if let newest = slice.items.first, let oldest = slice.items.last {
            slice.maxDate = newest.date
            slice.minDate = oldest.date
        }
        cache[table, default: [:]][file] = slice
        return slice
    }

    /// 读 live_meta 的全部 file（覆盖集合）
    private func _loadCoveredLocked() {
        guard let db = db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT file FROM live_meta;", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        var set = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                set.insert(String(cString: text))
            }
        }
        covered = set
    }

    private func _hasTableLocked(_ handle: OpaquePointer, _ name: String) -> Bool {
        var statement: OpaquePointer?
        let query = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// 取单值整数（表不存在 / 全 NULL 均返回 0）
    private func _scalarLocked(_ handle: OpaquePointer, sql: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - 表名映射 / 写入实现（以下均需已在 queue 上执行）

    /// 周期名（daily/weekly/…）→ 本地真实表名；本地库不含该表时返回 nil
    /// （优先 `live_<period>`，兼容早期无前缀命名）
    private func _localTableNameLocked(_ table: String) -> String? {
        if let cached = liveTableNames[table] { return cached }
        guard let handle = db else { return nil }
        let name: String?
        if _hasTableLocked(handle, "live_" + table) { name = "live_" + table }
        else if _hasTableLocked(handle, table) { name = table }
        else { name = nil }
        liveTableNames[table] = name
        return name
    }

    /// 一次性解析各周期表的本地表名（重载 / 新建后调用）
    private func _loadLiveTableNamesLocked(_ handle: OpaquePointer) {
        var map: [String: String] = [:]
        for t in Self.periodTables {
            if _hasTableLocked(handle, "live_" + t) { map[t] = "live_" + t }
            else if _hasTableLocked(handle, t) { map[t] = t }
        }
        liveTableNames = map
    }

    /// 取文本列（NULL → 空串）
    private func _textColumnLocked(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: c)
    }

    /// 确保本地增量库可写并已打开：不存在则新建（含 schema）；半成品 / 旧版结构就地重建
    private func _ensureWritableOpenLocked() -> Bool {
        if let handle = db { return _ensureWritableSchemaLocked(handle) }
        let path = Self.writableDBPath
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let opened = handle else {
            if handle != nil { sqlite3_close(handle) }
            return false
        }
        sqlite3_exec(opened, "PRAGMA journal_mode=DELETE;", nil, nil, nil)
        guard _ensureWritableSchemaLocked(opened) else {
            sqlite3_close(opened)
            return false
        }
        db = opened
        available = true
        _loadLiveTableNamesLocked(opened)
        return true
    }

    /// 确保表结构是 v3（键为 `file`、daily/weekly/monthly 三表）：
    /// - 缺 `live_meta`（新库 / 半成品）→ 按 `schemaSQL` 补齐；
    /// - 存在但是**旧版 `code` 键**（v2 及更早）→ 丢弃重建：增量内容可由分片完全重建，无数据损失。
    private func _ensureWritableSchemaLocked(_ handle: OpaquePointer) -> Bool {
        if !_hasTableLocked(handle, "live_meta") {
            return sqlite3_exec(handle, Self.schemaSQL, nil, nil, nil) == SQLITE_OK
        }
        guard _hasLegacySchemaLocked(handle) else { return true }
        DebugLogger.shared.log("[Live] 检测到旧版（code 键）增量库 → 重建为 v3（file 键）表结构")
        guard sqlite3_exec(handle, Self.dropLegacySQL, nil, nil, nil) == SQLITE_OK else { return false }
        return sqlite3_exec(handle, Self.schemaSQL, nil, nil, nil) == SQLITE_OK
    }

    /// `live_meta` 是否为旧版结构（无 `file` 列 → code 键）
    private func _hasLegacySchemaLocked(_ handle: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(live_meta);", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let c = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: c) == "file" { return false }
        }
        return true
    }

    /// ATTACH 分片文件为 `bkt`（路径单引号转义，避免 SQL 注入 / 语法错误）
    private func _attachBucketLocked(_ handle: OpaquePointer, path: String) -> Bool {
        let escaped = path.replacingOccurrences(of: "'", with: "''")
        return sqlite3_exec(handle, "ATTACH DATABASE '\(escaped)' AS bkt;", nil, nil, nil) == SQLITE_OK
    }

    /// 通用存在性判断（raw SQL：可带 schema 前缀，如 `bkt.sqlite_master`）
    private func _existsLocked(_ handle: OpaquePointer, sql: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// 分片 → 本地增量库：ATTACH + 单事务 INSERT OR REPLACE（显式字段顺序）
    private func _mergeBucketLocked(atPath path: String) -> LiveMergeResult {
        var r = LiveMergeResult()
        guard FileManager.default.fileExists(atPath: path) else {
            r.message = "分片文件不存在：\((path as NSString).lastPathComponent)"
            return r
        }
        guard _ensureWritableOpenLocked(), let handle = db else {
            r.message = "本地增量库不可写（打开失败）"
            return r
        }
        guard _attachBucketLocked(handle, path: path) else {
            r.message = "分片 ATTACH 失败：\(String(cString: sqlite3_errmsg(handle)))"
            return r
        }
        defer { sqlite3_exec(handle, "DETACH DATABASE bkt;", nil, nil, nil) }

        // 分片契约：至少要有 bkt_meta / bkt_daily
        let hasMeta = _existsLocked(handle, "SELECT 1 FROM bkt.sqlite_master WHERE type='table' AND name='bkt_meta' LIMIT 1;")
        let hasDaily = _existsLocked(handle, "SELECT 1 FROM bkt.sqlite_master WHERE type='table' AND name='bkt_daily' LIMIT 1;")
        guard hasMeta, hasDaily else {
            r.message = "分片缺少 bkt_meta/bkt_daily 表"
            return r
        }

        // ATTACH 不能在事务内 → 先 ATTACH，再开事务
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            r.message = "开启事务失败：\(String(cString: sqlite3_errmsg(handle)))"
            return r
        }
        var failed: String?
        // ① meta（显式字段顺序：file,code,name,type,updated_at）
        if sqlite3_exec(handle,
                        "INSERT OR REPLACE INTO live_meta(file,code,name,type,updated_at) "
                        + "SELECT file,code,name,type,updated_at FROM bkt.bkt_meta;",
                        nil, nil, nil) == SQLITE_OK {
            r.metaRows = Int(sqlite3_changes(handle))
        } else {
            failed = String(cString: sqlite3_errmsg(handle))
        }
        // ② 三张周期表（分片表名 bkt_* → 本地 live_*，字段顺序 file,date,open,high,low,close,vol,amo）
        if failed == nil {
            for m in Self.bucketTableMap {
                let exists = _existsLocked(handle, "SELECT 1 FROM bkt.sqlite_master WHERE type='table' AND name='\(m.bucket)' LIMIT 1;")
                guard exists else { continue }
                let sql = "INSERT OR REPLACE INTO \(m.local)(file,date,open,high,low,close,vol,amo) "
                        + "SELECT file,date,open,high,low,close,vol,amo FROM bkt.\(m.bucket);"
                guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                    failed = "\(m.bucket)：\(String(cString: sqlite3_errmsg(handle)))"
                    break
                }
                let n = Int(sqlite3_changes(handle))
                switch m.local {
                case "live_daily":   r.dailyRows = n
                case "live_weekly":  r.weeklyRows = n
                case "live_monthly": r.monthlyRows = n
                default: break
                }
            }
        }
        if let failed = failed {
            sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            r.message = "合并失败（已回滚）\(failed)"
            return r
        }
        guard sqlite3_exec(handle, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            r.message = "提交失败（已回滚）：\(String(cString: sqlite3_errmsg(handle)))"
            return r
        }
        r.ok = true
        r.coveredFiles = _scalarLocked(handle, sql: "SELECT COUNT(*) FROM live_meta;")
        r.message = "合并完成 meta=\(r.metaRows) daily=\(r.dailyRows) weekly=\(r.weeklyRows) monthly=\(r.monthlyRows) 覆盖=\(r.coveredFiles)只"
        return r
    }

    /// 删除三表中 `date <= beforeDate` 的行（单事务；表不存在则跳过）
    private func _trimLocked(beforeDate: Int) -> LiveTrimResult {
        var r = LiveTrimResult()
        guard let handle = db, beforeDate > 0 else {
            r.ok = true
            r.message = "无需裁剪"
            return r
        }
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            r.message = "开启事务失败：\(String(cString: sqlite3_errmsg(handle)))"
            return r
        }
        var total = 0
        for period in ["daily", "weekly", "monthly"] {
            guard let table = _localTableNameLocked(period) else { continue }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "DELETE FROM \(table) WHERE date <= ?;", -1, &statement, nil) == SQLITE_OK else {
                sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                r.message = "准备裁剪 \(table) 语句失败"
                return r
            }
            sqlite3_bind_int64(statement, 1, Int64(beforeDate))
            let stepOK = sqlite3_step(statement) == SQLITE_DONE
            sqlite3_finalize(statement)
            guard stepOK else {
                sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                r.message = "裁剪 \(table) 失败（已回滚）：\(String(cString: sqlite3_errmsg(handle)))"
                return r
            }
            total += Int(sqlite3_changes(handle))
        }
        guard sqlite3_exec(handle, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            r.message = "裁剪提交失败（已回滚）"
            return r
        }
        r.ok = true
        r.deletedRows = total
        r.message = "裁剪完成：删除 \(total) 行（date <= \(beforeDate)）"
        return r
    }

    /// 一次读全三表（供 MainDBMerger 在主库侧回写；避免跨队列嵌套）
    private func _allIncrementRowsLocked() -> LiveIncrementSnapshot {
        var snap = LiveIncrementSnapshot()
        guard let handle = db else { return snap }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT file,code,name,type FROM live_meta;", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                snap.meta.append(LiveIncrementMeta(file: _textColumnLocked(statement, 0),
                                                   code: _textColumnLocked(statement, 1),
                                                   name: _textColumnLocked(statement, 2),
                                                   type: _textColumnLocked(statement, 3)))
            }
            sqlite3_finalize(statement)
        }
        snap.daily = _readRowsLocked(handle, period: "daily")
        snap.weekly = _readRowsLocked(handle, period: "weekly")
        snap.monthly = _readRowsLocked(handle, period: "monthly")
        return snap
    }

    /// 读某周期表全部行（无该表 → 空数组）
    private func _readRowsLocked(_ handle: OpaquePointer, period: String) -> [LiveIncrementRow] {
        guard let table = _localTableNameLocked(period) else { return [] }
        var statement: OpaquePointer?
        let sql = "SELECT file,date,open,high,low,close,vol,amo FROM \(table) ORDER BY date ASC;"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [LiveIncrementRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(LiveIncrementRow(
                file: _textColumnLocked(statement, 0),
                date: Int(sqlite3_column_int64(statement, 1)),
                open: sqlite3_column_double(statement, 2),
                high: sqlite3_column_double(statement, 3),
                low: sqlite3_column_double(statement, 4),
                close: sqlite3_column_double(statement, 5),
                vol: sqlite3_column_double(statement, 6),
                amo: sqlite3_column_double(statement, 7)))
        }
        return rows
    }

    /// 最新 limit 个不同交易日（date 降序）
    private func _newestDatesLocked(limit: Int) -> [Int] {
        guard let handle = db, limit > 0, let table = _localTableNameLocked("daily") else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT DISTINCT date FROM \(table) ORDER BY date DESC LIMIT ?;",
                                 -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(limit))
        var out: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW { out.append(Int(sqlite3_column_int64(statement, 0))) }
        return out
    }

    /// 内部写入（合并分片 / 裁剪）之后刷新缓存、行数与**自身指纹**：
    /// 刷新 fp 是为了不让 5 分钟指纹轮询把自己的写入当成「外部写入」再触发一次重载；
    /// 内容变化判定另用 `appliedHash`（此处**不更新**，留给随后的 reloadAsync 统一发布）。
    private func _refreshAfterInternalWriteLocked(reason: String) {
        guard let handle = db else { return }
        cache.removeAll()
        _loadCoveredLocked()
        _loadLiveTableNamesLocked(handle)
        metaCount = _scalarLocked(handle, sql: "SELECT COUNT(*) FROM live_meta;")
        dailyCount = _scalarLocked(handle, sql: "SELECT COUNT(*) FROM live_daily;")
        latestDate = _scalarLocked(handle, sql: "SELECT MAX(date) FROM live_daily;")
        earliestDate = _scalarLocked(handle, sql: "SELECT MIN(date) FROM live_daily;")
        // 只有「写入前已发布过内容」时才刷新 fp（用于抑制 5 分钟轮询误判为外部写入）；
        // 首次新建 / 修复损坏库时保留旧（nil）指纹，让随后的 reloadAsync 能侦测到「不可用 → 可用」的变化。
        if appliedHash != nil {
            fp = Self.fullFingerprint(ofPath: Self.writableDBPath)
        }
        let meta = metaCount, daily = dailyCount, latest = latestDate, earliest = earliestDate
        let fpDisplay = fp?.display ?? "-"
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let snapshot = LiveStatusSnapshot(
                isAvailable: true,
                fingerprint: fpDisplay,
                metaCount: meta,
                dailyCount: daily,
                latestDate: latest,
                earliestDate: earliest,
                reloadCount: self.reloadCount,
                path: Self.writableDBPath)
            if self.status.fingerprint != snapshot.fingerprint || self.status.metaCount != snapshot.metaCount {
                self.status = snapshot
            }
            DebugLogger.shared.log("[Live] \(reason)：覆盖=\(meta)只/日线\(daily)行 区间=\(earliest == 0 ? "-" : String(earliest))~\(latest == 0 ? "-" : String(latest)) 指纹=\(fpDisplay)（已同步 fp，待 reload 统一发布）")
        }
    }

    // MARK: - 主线程发布

    /// 把摘要发布到主线程（@Published 信号 + 热重载通知）
    private func _publishSummary(_ summary: LiveReloadSummary, notify: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isAvailable != summary.isAvailable { self.isAvailable = summary.isAvailable }
            if self.fingerprint != summary.fingerprintAfter { self.fingerprint = summary.fingerprintAfter }
            if notify { self.reloadCount += 1 }
            self.status = LiveStatusSnapshot(
                isAvailable: summary.isAvailable,
                fingerprint: summary.fingerprintAfter,
                metaCount: summary.metaCountAfter,
                dailyCount: summary.dailyCountAfter,
                latestDate: summary.latestDateAfter,
                earliestDate: summary.earliestDateAfter,
                reloadCount: self.reloadCount,
                path: Self.writableDBPath)
            guard notify else { return }
            self.reloadSubject.send(summary)
        }
    }

    /// 当前状态 JSON（**须在主线程调用**，避免与状态写入竞争）
    func currentStatusJSON() -> String {
        let s = status
        return "{\"available\":\(s.isAvailable ? "true" : "false")"
            + ",\"fingerprint\":\"\(s.fingerprint)\""
            + ",\"metaCount\":\(s.metaCount)"
            + ",\"dailyCount\":\(s.dailyCount)"
            + ",\"latestDate\":\(s.latestDate)"
            + ",\"earliestDate\":\(s.earliestDate)"
            + ",\"reloadCount\":\(s.reloadCount)"
            + ",\"path\":\"\(s.path)\"}"
    }

    // MARK: - 指纹工具

    /// 快速键：只读文件属性（每次定时检查走这里，不读文件内容）
    private static func quickKey(ofPath path: String) -> (size: Int64, mtime: TimeInterval)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, mtime)
    }

    /// 完整指纹：(size, mtime) + 内容 sha256（mmap 读取，避免整file进内存）
    private static func fullFingerprint(ofPath path: String) -> LiveDBFingerprint? {
        guard let quick = quickKey(ofPath: path) else { return nil }
        var result = LiveDBFingerprint(size: quick.size, mtime: quick.mtime, sha256: nil)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) {
            result.sha256 = sha256Hex(data)
        }
        return result
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func ms(_ interval: TimeInterval) -> String {
        String(format: "%.0fms", interval * 1000)
    }
}
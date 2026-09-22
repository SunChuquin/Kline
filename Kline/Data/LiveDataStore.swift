//
//  LiveDataStore.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/9/22.
//
//  增量库读取层：`Documents/tdx_live.db`（**只读**，由外部 USB / 局域网 / 云端写入）。
//  能力：
//   1) 打开 / 校验增量库（缺失、打不开、缺 live_meta 表 → 静默降级 isAvailable=false，不抛异常）；
//   2) 按 code 取某周期表的全部增量行（进程内按 code 缓存，避免重复走 SQL），并给出该 code 的 minDate
//      （主库补齐的切分点）；
//   3) 指纹 = (size, mtime) 快速键 + 可选 sha256（CryptoKit，iOS 13+）；
//   4) reload()：清缓存、关旧连接、重开、重算指纹、更新 isAvailable，返回重载前后行数 / 最新日期；
//   5) startWatching(interval:)：前台定时指纹检查（指纹未变则什么都不做）+ 回前台立即检查一次。
//
//  硬约束：
//   - 主库 `tdx.db` 全程只读不改；增量库不可用时行为与「没有本类」完全一致；
//   - 自持独立串行队列 `com.sunck.kline.live.db.serial`，**绝不**与 `DatabaseManager.dbQueue`
//     交叉嵌套同步（本类任何方法都不会在持锁状态下回调 DatabaseManager，反向亦然）；
//   - 所有 @Published / 通知一律回主线程发布。
//

import Foundation
import SQLite3
import Combine
import CryptoKit
import UIKit

// MARK: - 数据契约

/// 某 code 在某周期表上的增量切片（date 降序，与主库查询返回顺序一致）
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
    /// 覆盖标的数（live_meta 行数）
    var metaCount = 0
    /// 日线行数（live_daily 行数）
    var dailyCount = 0
    /// 增量库内最新交易日（YYYYMMDD，0 表示无）
    var latestDate = 0
    /// 已热重载次数（仅内容确实变化时自增）
    var reloadCount = 0
    /// 增量库绝对路径
    var path = LiveDataStore.writableDBPath
}

// MARK: - 增量库读取层

final class LiveDataStore: ObservableObject {
    static let shared = LiveDataStore()

    /// 增量库文件名（Documents 下，由外部推送覆盖）
    static let dbFileName = "tdx_live.db"

    /// 增量库支持的周期表（与主库周期表同名、同字段）
    static let periodTables = ["daily", "weekly", "monthly", "quarterly", "yearly"]

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
    /// 增量库覆盖的 code 集合（来自 live_meta，用于精确失效行缓存）
    private var covered: Set<String> = []
    /// table → code → 切片（含「已查过、确无增量行」的空切片，避免重复走 SQL）
    private var cache: [String: [String: LiveSlice]] = [:]
    private var metaCount = 0
    private var dailyCount = 0
    private var latestDate = 0

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

    // MARK: - 取数：某 code 在某周期表的全部增量行

    /// 某 code 在某周期表上的全部增量行（date 降序）。
    /// - 增量库不可用 / 表名不合法 → 返回 nil（调用方走纯主库路径）；
    /// - 该 code 无增量行 → 返回空切片（`isEmpty == true`）。
    func slice(code: String, table: String) -> LiveSlice? {
        guard !code.isEmpty, Self.periodTables.contains(table) else { return nil }
        return queue.sync {
            guard available, db != nil else { return nil }
            return _sliceLocked(code: code, table: table)
        }
    }

    /// 增量库覆盖的全部 code（用于「只重取受影响的行」）；不可用或为空集合 → 返回空集合
    func coveredCodes() -> Set<String> {
        queue.sync { covered }
    }

    /// 最近一次计算 / 重载得到的完整指纹（含 sha256）；未找到文件时 nil
    func currentFingerprint() -> LiveDBFingerprint? {
        queue.sync { fp }
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
        s.fingerprintBefore = fp?.display ?? "-"
        let previousKnown = (fp != nil) || available
        let oldHash = fp?.sha256

        // 1) 清缓存 + 关旧连接
        _closeLocked()
        cache.removeAll()
        covered.removeAll()
        metaCount = 0
        dailyCount = 0
        latestDate = 0

        // 2) 重算指纹
        let path = Self.writableDBPath
        let newFP = Self.fullFingerprint(ofPath: path)
        fp = newFP

        guard let newFP = newFP else {
            s.isAvailable = false
            s.fingerprintAfter = "-"
            s.contentChanged = previousKnown && s.wasAvailable
            s.elapsed = Date().timeIntervalSince(t0)
            DebugLogger.shared.log("[Live] 增量库不存在 → 降级「仅主库」 path=\(path) 耗时=\(Self.ms(s.elapsed))")
            return s
        }

        // 3) 重开连接
        var handle: OpaquePointer?
        if sqlite3_open(path, &handle) != SQLITE_OK || handle == nil {
            if handle != nil { sqlite3_close(handle) }
            s.isAvailable = false
            s.fingerprintAfter = newFP.display
            s.contentChanged = previousKnown && (s.wasAvailable || oldHash != newFP.sha256)
            s.elapsed = Date().timeIntervalSince(t0)
            DebugLogger.shared.log("[Live] 增量库打不开 → 降级「仅主库」 path=\(path)")
            return s
        }

        // 4) 校验契约（必须有 live_meta）
        guard _hasTableLocked(handle!, "live_meta") else {
            sqlite3_close(handle)
            s.isAvailable = false
            s.fingerprintAfter = newFP.display
            s.contentChanged = previousKnown && (s.wasAvailable || oldHash != newFP.sha256)
            s.elapsed = Date().timeIntervalSince(t0)
            DebugLogger.shared.log("[Live] 增量库缺 live_meta 表 → 降级「仅主库」 path=\(path)")
            return s
        }

        db = handle
        available = true
        _loadCoveredLocked()
        metaCount = _scalarLocked(handle!, sql: "SELECT COUNT(*) FROM live_meta;")
        dailyCount = _scalarLocked(handle!, sql: "SELECT COUNT(*) FROM live_daily;")
        latestDate = _scalarLocked(handle!, sql: "SELECT MAX(date) FROM live_daily;")

        s.isAvailable = true
        s.metaCountAfter = metaCount
        s.dailyCountAfter = dailyCount
        s.latestDateAfter = latestDate
        s.fingerprintAfter = newFP.display
        s.contentChanged = previousKnown && (!s.wasAvailable || oldHash != newFP.sha256)
        s.elapsed = Date().timeIntervalSince(t0)

        DebugLogger.shared.log("[Live] 重载完成 reason=\(reason) 覆盖=\(metaCount)只/日线\(dailyCount)行 最新=\(latestDate == 0 ? "-" : String(latestDate)) 耗时=\(Self.ms(s.elapsed)) 指纹 \(s.fingerprintBefore) → \(s.fingerprintAfter) 内容变化=\(s.contentChanged)")
        return s
    }

    private func _closeLocked() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
        available = false
    }

    /// 某 code 在某表的切片（走 cache；未命中则查一次并把结果（含空结果）写回 cache）
    private func _sliceLocked(code: String, table: String) -> LiveSlice {
        if let hit = cache[table]?[code] { return hit }

        var slice = LiveSlice()
        let query = "SELECT date, open, high, low, close, vol, amo FROM \(table) WHERE code = ? ORDER BY date DESC;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, code, -1, SQLITE_TRANSIENT)
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
        cache[table, default: [:]][code] = slice
        return slice
    }

    /// 读 live_meta 的全部 code（覆盖集合）
    private func _loadCoveredLocked() {
        guard let db = db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT code FROM live_meta;", -1, &statement, nil) == SQLITE_OK else { return }
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
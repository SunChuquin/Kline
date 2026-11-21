//
//  IndicatorCacheDB.swift
//  Kline
//
//  指标缓存磁盘仓库（P2 指标组合体系期3）：按 (组合, 标的, 周期) 持久化指标曲线到
//  独立 sqlite（Documents/indicator_cache.db，不与行情主库混用）。
//
//  写入时机：全量预计算完成（commitPrefetch / commitToCache）与生成引擎——前台近似
//  计算不落盘（避免高频 IO）。读取时机：IndicatorComputationStore.init 内存未命中时
//  同步查单行（主键索引 <10ms），行级校验（fingerprint + 末根日期 + 源根数）全过才注水。
//
//  数据联动失效（补缺口 / 清单标的自动更新）：增量库热重载 → dataVersion 自增 →
//  ChartCacheStore.clearAll()（内存全清，成本为零）；磁盘缓存**不跟随全清**（生成成本高），
//  依赖行级校验自然失效——尾部追加（补缺口）使 last_bar_date 不匹配 → 忽略该行；
//  删除标的 → 孤儿行由 purgeOrphans 按当前 metaList 差集回收；历史被结构性改写 →
//  source_bar_count 不匹配。过期行**保留**（管理页标记过期待更新，可清除或重生成）。
//
//  隔离：sqlite 操作统一走串行队列（DatabaseManager 同款范式）；load 为 queue.sync
//  同步查询（调用方为主线程 init，单行查询延迟可接受）。
//

import Foundation
import SQLite3
import SwiftUI
import UIKit

// MARK: - 序列化投影

/// IndicatorLine 的磁盘投影：Color→RGBA 分量（SwiftUI Color 非 Codable；构造处均为
/// RGB 常量，UIColor 桥往返精确）。样式/线宽/着色模式等线元数据随值一起落盘，
/// 恢复即得完整曲线（样式由生成时的配置派生，指纹校验保证配置一致才复用）。
struct IndicatorLineBlob: Codable {
    var name: String
    var values: [Double]
    var rgba: [Double]
    var style: String
    var lineWidth: Double
    var hideValue: Bool
    var barColor: String
    var markerRgba: [[Double]]?
    var values2: [Double]?
    var stickWidth: Double
    var breakOnNaN: Bool
    var keyIndices: [Int]?
    var chanKind: String?

    init(from line: IndicatorLine) {
        self.name = line.name
        self.values = line.values
        self.rgba = Self.rgba(of: line.color)
        self.style = line.style.rawValue
        self.lineWidth = line.lineWidth
        self.hideValue = line.hideValue
        self.barColor = Self.barColorKey(line.barColor)
        self.markerRgba = line.markerColors?.map { Self.rgba(of: $0) }
        self.values2 = line.values2
        self.stickWidth = line.stickWidth
        self.breakOnNaN = line.breakOnNaN
        self.keyIndices = line.keyIndices
        self.chanKind = line.chanKind
    }

    func toLine() -> IndicatorLine? {
        guard let color = Self.color(from: rgba), let style = TDXLineStyle(rawValue: style) else { return nil }
        var line = IndicatorLine(name: name, values: values, color: color,
                                 style: style, lineWidth: lineWidth, hideValue: hideValue)
        line.barColor = Self.barColorMode(barColor)
        line.markerColors = markerRgba?.compactMap { Self.color(from: $0) }
        line.values2 = values2
        line.stickWidth = stickWidth
        line.breakOnNaN = breakOnNaN
        line.keyIndices = keyIndices
        line.chanKind = chanKind
        return line
    }

    private static func rgba(of color: Color) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b), Double(a)]
    }

    private static func color(from rgba: [Double]) -> Color? {
        guard rgba.count == 4 else { return nil }
        return Color(red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3])
    }

    private static func barColorKey(_ mode: BarColorMode) -> String {
        switch mode {
        case .fixed: return "fixed"
        case .sign: return "sign"
        case .candle: return "candle"
        }
    }

    private static func barColorMode(_ key: String) -> BarColorMode {
        switch key {
        case "sign": return .sign
        case "candle": return .candle
        default: return .fixed
        }
    }
}

/// 缓存行 payload（主图 + 三副图曲线一个 envelope 一次落盘）
struct IndicatorCacheEnvelope: Codable {
    var main: [IndicatorLineBlob]
    var subs: [Int: [IndicatorLineBlob]]
    /// 前台覆盖区间（绝对索引）
    var coverageStart: Int
    var coverageEnd: Int
    /// 后台全量覆盖末端（绝对索引；达到数据末端 = 全量完成）
    var bgCoverageEnd: Int
}

// MARK: - 磁盘仓库

final class IndicatorCacheDB {
    static let shared = IndicatorCacheDB()

    private var db: OpaquePointer?

    /// 所有 sqlite 操作统一走串行队列（DatabaseManager 同款；避免多线程并发访问同一连接）
    private let queue = DispatchQueue(label: "com.sunck.kline.indcache.serial")

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = docs.appendingPathComponent("indicator_cache.db").path
        let rc = sqlite3_open(path, &db)
        guard rc == SQLITE_OK else {
            DebugLogger.shared.log("[IndicatorCache] 打开失败 rc=\(rc) path=\(path)")
            db = nil
            return
        }
        sqlite3_busy_timeout(db, 5000)
        createSchema()
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    private func createSchema() {
        queue.sync {
            guard let db else { return }
            let sql = """
            CREATE TABLE IF NOT EXISTS cache (
              combo_key TEXT NOT NULL,
              meta_id INTEGER NOT NULL,
              period TEXT NOT NULL,
              fingerprint TEXT NOT NULL,
              gen_mode TEXT NOT NULL DEFAULT 'runtime',
              last_bar_date INTEGER NOT NULL,
              source_bar_count INTEGER NOT NULL,
              payload BLOB NOT NULL,
              updated_at INTEGER NOT NULL,
              PRIMARY KEY (combo_key, meta_id, period)
            );
            CREATE INDEX IF NOT EXISTS idx_cache_combo ON cache (combo_key);
            """
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                DebugLogger.shared.log("[IndicatorCache] 建表失败: \(err.map { String(cString: $0) } ?? "?")")
            }
        }
    }

    // MARK: 读取（同步单行；行级校验全过才返回 payload）

    /// 读取一行缓存 payload。校验：fingerprint 一致 + 源根数一致 + 末根日期一致
    /// （补缺口/历史改写/组合配置变化的行视为无效返回 nil，磁盘行保留待重生成或清除）。
    func load(comboKey: String, metaId: Int, period: KlinePeriod,
              fingerprint: String, lastBarDate: Int, sourceBarCount: Int) -> Data? {
        guard let db else { return nil }
        return queue.sync {
            let sql = """
            SELECT payload FROM cache
            WHERE combo_key = ? AND meta_id = ? AND period = ?
              AND fingerprint = ? AND source_bar_count = ? AND last_bar_date = ?;
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(statement, 1, comboKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 2, Int64(metaId))
            sqlite3_bind_text(statement, 3, period.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, fingerprint, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 5, Int64(sourceBarCount))
            sqlite3_bind_int64(statement, 6, Int64(lastBarDate))
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let blob = sqlite3_column_blob(statement, 0) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, 0))
            return Data(bytes: blob, count: count)
        }
    }

    // MARK: 写入（异步；INSERT OR REPLACE 覆盖旧行）

    func save(comboKey: String, metaId: Int, period: KlinePeriod, fingerprint: String,
              genMode: String, lastBarDate: Int, sourceBarCount: Int, payload: Data) {
        queue.async { [weak self] in
            guard let db = self?.db else { return }
            let sql = """
            INSERT OR REPLACE INTO cache
              (combo_key, meta_id, period, fingerprint, gen_mode, last_bar_date,
               source_bar_count, payload, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(statement, 1, comboKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 2, Int64(metaId))
            sqlite3_bind_text(statement, 3, period.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, fingerprint, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 5, genMode, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 6, Int64(lastBarDate))
            sqlite3_bind_int64(statement, 7, Int64(sourceBarCount))
            payload.withUnsafeBytes { buf in
                _ = sqlite3_bind_blob(statement, 8, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(statement, 9, Int64(Date().timeIntervalSince1970))
            if sqlite3_step(statement) != SQLITE_DONE {
                DebugLogger.shared.log("[IndicatorCache] 写入失败 meta=\(metaId) \(period.rawValue)")
            }
        }
    }

    // MARK: 清除（期4 缓存管理页）

    /// 清除：comboKey 传 nil = 清全部组合；metaId 传 nil = 清该组合全部标的
    func clear(comboKey: String? = nil, metaId: Int? = nil) {
        queue.async { [weak self] in
            guard let db = self?.db else { return }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            switch (comboKey, metaId) {
            case (nil, nil):
                guard sqlite3_prepare_v2(db, "DELETE FROM cache;", -1, &statement, nil) == SQLITE_OK else { return }
            case (let c?, nil):
                guard sqlite3_prepare_v2(db, "DELETE FROM cache WHERE combo_key = ?;", -1, &statement, nil) == SQLITE_OK else { return }
                sqlite3_bind_text(statement, 1, c, -1, SQLITE_TRANSIENT)
            case (let c?, let m?):
                guard sqlite3_prepare_v2(db, "DELETE FROM cache WHERE combo_key = ? AND meta_id = ?;", -1, &statement, nil) == SQLITE_OK else { return }
                sqlite3_bind_text(statement, 1, c, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(statement, 2, Int64(m))
            default:
                return
            }
            sqlite3_step(statement)
        }
    }

    /// 统计（同步；组合 → (条目数, payload 字节数)）——缓存管理页占用展示
    func stats() -> [String: (count: Int, bytes: Int)] {
        guard let db else { return [:] }
        return queue.sync {
            var result: [String: (Int, Int)] = [:]
            let sql = "SELECT combo_key, COUNT(*), COALESCE(SUM(LENGTH(payload)),0) FROM cache GROUP BY combo_key;"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let key = sqlite3_column_text(statement, 0) else { continue }
                result[String(cString: key)] = (Int(sqlite3_column_int64(statement, 1)),
                                                Int(sqlite3_column_int64(statement, 2)))
            }
            return result
        }
    }

    /// 行级明细（同步；组合 → 每行的 metaID/period/末根日期/字节数）——缓存管理页过期统计
    func rowsDetail() -> [(comboKey: String, metaID: Int, period: String,
                           lastBarDate: Int, genMode: String, bytes: Int)] {
        guard let db else { return [] }
        return queue.sync {
            var result: [(String, Int, String, Int, String, Int)] = []
            let sql = """
            SELECT combo_key, meta_id, period, last_bar_date, gen_mode, LENGTH(payload)
            FROM cache ORDER BY combo_key, meta_id;
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let key = sqlite3_column_text(statement, 0),
                      let period = sqlite3_column_text(statement, 2),
                      let mode = sqlite3_column_text(statement, 4) else { continue }
                result.append((String(cString: key),
                               Int(sqlite3_column_int64(statement, 1)),
                               String(cString: period),
                               Int(sqlite3_column_int64(statement, 3)),
                               String(cString: mode),
                               Int(sqlite3_column_int64(statement, 5))))
            }
            return result
        }
    }

    /// 孤儿行回收（清单标的自动更新：删除标的的行按当前 metaList 差集清理）——期4
    func purgeOrphans(validMetaIDs: Set<Int>) {
        queue.async { [weak self] in
            guard let db = self?.db else { return }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT DISTINCT meta_id FROM cache;", -1, &statement, nil) == SQLITE_OK else { return }
            var ids: [Int] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                ids.append(Int(sqlite3_column_int64(statement, 0)))
            }
            sqlite3_finalize(statement)
            let orphans = ids.filter { !validMetaIDs.contains($0) }
            guard !orphans.isEmpty else { return }
            var delStatement: OpaquePointer?
            defer { sqlite3_finalize(delStatement) }
            guard sqlite3_prepare_v2(db, "DELETE FROM cache WHERE meta_id = ?;", -1, &delStatement, nil) == SQLITE_OK else { return }
            for id in orphans {
                sqlite3_bind_int64(delStatement, 1, Int64(id))
                sqlite3_step(delStatement)
                sqlite3_reset(delStatement)
            }
            DebugLogger.shared.log("[IndicatorCache] 孤儿行回收 \(orphans.count) 标的")
        }
    }
}

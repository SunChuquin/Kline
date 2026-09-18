//
//  BinDataStore.swift
//  Kline
//
//  二进制行情数据源：读取 Documents/tdx_data/*.bin，提供与 DatabaseManager 对齐的数据语义，
//  可运行时与 SQLite 数据源（tdx.db）互相切换。
//  - meta 索引：扫描目录（Windows 排序，id = 排序序号，与 tdx_parser 分配顺序一致）
//  - 日线整史 / 尾部 N 根快读 / 周月季年实时聚合（语义对齐 tdx_parser.handle_data）
//  - 版本化缓存：key=文件(mtime+size)，数据更新后自动失效
//
//  Created by 孙楚昆 on 2026/9/18.
//

import Foundation

final class BinDataStore {

    static let shared = BinDataStore()

    /// 索引条目：一个 .bin 文件
    final class Entry {
        /// 无扩展名文件名（"SH600000"），与 DB meta.file 一致，供收藏跨数据源重映射
        let file: String
        let meta: MetaItem
        let recordSize: Int
        init(file: String, meta: MetaItem, recordSize: Int) {
            self.file = file
            self.meta = meta
            self.recordSize = recordSize
        }
    }

    // MARK: - 状态

    private let fm = FileManager.default
    /// 所有文件 IO / 索引 / 缓存访问串行执行（近似 DatabaseManager.dbQueue 语义）
    private let queue = DispatchQueue(label: "com.sunck.kline.bindata.serial")

    private var entriesByID: [Int: Entry] = [:]
    private var entriesByFile: [String: Entry] = [:]
    /// 目录内全部 .bin 文件名（Windows 序），id = 下标 + 1（即使个别文件无效也占位，保证 id 稳定）
    private var orderedFiles: [String] = []

    // 版本化缓存
    private struct CacheEntry {
        var bars: [KlineItem]
        var size: Int64
        var mtime: TimeInterval
        var lastUsed: Int
    }
    private var rawDailyCache: [String: CacheEntry] = [:]    // file -> 日线 ASC
    private var periodCache: [String: CacheEntry] = [:]      // "file|period" -> 聚合 ASC
    private var clock = 0
    private let rawCacheCap = 8
    private let periodCacheCap = 12

    // MARK: - 路径

    var dataDirPath: String {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(BinFormat.dataDirName).path
    }

    private func filePath(_ file: String) -> String {
        (dataDirPath as NSString).appendingPathComponent(file + "." + BinFormat.fileExtension)
    }

    // MARK: - 对外接口（内部串行）

    /// 全量重建索引并返回 meta 列表（bin 模式 metaID = Windows 排序序号）
    @discardableResult
    func rebuildMeta() -> [MetaItem] {
        queue.sync {
            buildIndex()
            return currentMetaList()
        }
    }

    /// 当前索引的全部 meta（不重建）
    func allMeta() -> [MetaItem] {
        queue.sync { currentMetaList() }
    }

    /// 索引进度信息（切换 UI 展示用）
    func indexInfo() -> (fileCount: Int, lastDate: Int?) {
        queue.sync {
            var last: Int? = nil
            for e in entriesByID.values {
                if let d = e.meta.lastDate, d > (last ?? 0) { last = d }
            }
            return (entriesByID.count, last)
        }
    }

    /// 某标的整史 K 线，返回 DESC（与 SQL 的 fetchBars 一致）
    func bars(metaId: Int, period: KlinePeriod) -> [KlineItem] {
        queue.sync {
            guard let entry = entriesByID[metaId] else { return [] }
            let daily = dailyAscending(entry)
            guard !daily.isEmpty else { return [] }
            switch period {
            case .daily:
                return Array(daily.reversed())
            default:
                let agg = periodAscending(entry: entry, period: period, daily: daily)
                return Array(agg.reversed())
            }
        }
    }

    /// 最近 limit 根日线，返回 DESC（与 SQL 的 fetchPeriodLimited 一致）
    func tailDaily(metaId: Int, limit: Int) -> [KlineItem] {
        queue.sync {
            guard let entry = entriesByID[metaId] else { return [] }
            let path = filePath(entry.file)
            let tail = BinFormat.readTailRecords(path: path, recordSize: entry.recordSize, count: max(1, limit))
            // 顺带把该版本记录进整史读缓存（若已缓存则无需处理）
            return Array(tail.reversed())
        }
    }

    /// 搜索 name/code（等价 SQL 的 LIKE）
    func search(keyword: String) -> [MetaItem] {
        queue.sync {
            let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !kw.isEmpty else { return currentMetaList() }
            return entriesByID.keys.sorted().compactMap { id -> MetaItem? in
                guard let m = entriesByID[id]?.meta else { return nil }
                return (m.name.localizedCaseInsensitiveContains(kw) || m.code.localizedCaseInsensitiveContains(kw)) ? m : nil
            }
        }
    }

    /// 数据版本指纹（含数据源标识），供指标缓存失效判断
    func dataVersionFingerprint(metaId: Int) -> String {
        queue.sync {
            guard let entry = entriesByID[metaId] else { return "bin:missing" }
            let path = filePath(entry.file)
            let attrs = try? fm.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            return "bin|\(size)|\(mtime)"
        }
    }

    /// 清空进程内缓存（切换数据源 / 数据刷新后调用）
    func resetCaches() {
        queue.sync {
            rawDailyCache.removeAll()
            periodCache.removeAll()
        }
    }

    // MARK: - 索引构建

    private func buildIndex() {
        entriesByID.removeAll()
        entriesByFile.removeAll()
        orderedFiles.removeAll()
        let dir = dataDirPath
        var names: [String] = []
        if let items = try? fm.contentsOfDirectory(atPath: dir) {
            names = items.filter { (($0 as NSString).pathExtension.lowercased()) == BinFormat.fileExtension }
        }
        names.sort(by: Self.windowsOrder)
        orderedFiles = names
        for (idx, name) in names.enumerated() {
            let id = idx + 1
            let base = (name as NSString).deletingPathExtension
            if let e = readEntry(path: filePathFrom(name), file: base, id: id) {
                entriesByID[id] = e
                entriesByFile[base] = e
            }
        }
    }

    private func filePathFrom(_ name: String) -> String {
        (dataDirPath as NSString).appendingPathComponent(name)
    }

    private func readEntry(path: String, file: String, id: Int) -> Entry? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let hdrData = fh.readData(ofLength: BinFormat.headerSize)
        guard hdrData.count == BinFormat.headerSize,
              let hdr = BinFormat.parseHeader(hdrData) else { return nil }
        let size = fh.seekToEndOfFile()
        let n = BinFormat.recordCount(fileSize: Int(size), recordSize: hdr.recordSize)
        guard n > 0 else { return nil }
        let firstDate = BinFormat.readDateAt(path: path, index: 0, recordSize: hdr.recordSize)
        let lastDate = BinFormat.readDateAt(path: path, index: n - 1, recordSize: hdr.recordSize)
        let meta = MetaItem(id: id, file: file, code: hdr.code, name: hdr.name, type: hdr.type,
                            firstDate: firstDate, lastDate: lastDate)
        return Entry(file: file, meta: meta, recordSize: hdr.recordSize)
    }

    private func currentMetaList() -> [MetaItem] {
        entriesByID.keys.sorted().compactMap { entriesByID[$0]?.meta }
    }

    // MARK: - 日线读取（版本化缓存）

    private func dailyAscending(_ entry: Entry) -> [KlineItem] {
        let path = filePath(entry.file)
        let attrs = try? fm.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if let cached = rawDailyCache[entry.file], cached.size == size, cached.mtime == mtime {
            touch(key: entry.file, in: &rawDailyCache)
            return cached.bars
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        let bars = BinFormat.decodeRecords(data, recordSize: entry.recordSize)
        store(key: entry.file, bars: bars, size: size, mtime: mtime,
              in: &rawDailyCache, cap: rawCacheCap)
        return bars
    }

    // MARK: - 周期聚合（语义对齐 tdx_parser.handle_data）

    private func periodAscending(entry: Entry, period: KlinePeriod, daily: [KlineItem]) -> [KlineItem] {
        let path = filePath(entry.file)
        let attrs = try? fm.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(entry.file)|\(period.rawValue)"
        if let cached = periodCache[key], cached.size == size, cached.mtime == mtime {
            touch(key: key, in: &periodCache)
            return cached.bars
        }
        let agg = Self.aggregate(daily: daily, period: period)
        store(key: key, bars: agg, size: size, mtime: mtime, in: &periodCache, cap: periodCacheCap)
        return agg
    }

    /// 聚合桶（date=桶内首日，open=首日开，high/low/close/vol/amo 依次更新）
    private struct AggBucket {
        var date: Int
        var open: Double
        var high: Double
        var low: Double
        var close: Double
        var vol: Double
        var amo: Double
    }

    static func aggregate(daily: [KlineItem], period: KlinePeriod) -> [KlineItem] {
        var out: [KlineItem] = []
        var cur: AggBucket?
        var lastKey = Int.min
        for r in daily {
            let k = periodKey(date: r.date, period: period)
            if cur == nil {
                cur = AggBucket(date: r.date, open: r.open, high: r.high, low: r.low,
                                close: r.close, vol: r.volume, amo: r.turnover)
            } else if k != lastKey {
                out.append(makeKline(cur!))
                cur = AggBucket(date: r.date, open: r.open, high: r.high, low: r.low,
                                close: r.close, vol: r.volume, amo: r.turnover)
            } else {
                cur!.high = max(cur!.high, r.high)
                cur!.low = min(cur!.low, r.low)
                cur!.close = r.close
                cur!.vol += r.volume
                cur!.amo += r.turnover
            }
            lastKey = k
        }
        if let c = cur { out.append(makeKline(c)) }
        return out
    }

    private static func makeKline(_ b: AggBucket) -> KlineItem {
        KlineItem(date: b.date, open: b.open, high: b.high, low: b.low,
                  close: b.close, volume: b.vol, turnover: b.amo)
    }

    /// 周期分组键（对应 tdx_parser.period_key）
    static func periodKey(date: Int, period: KlinePeriod) -> Int {
        switch period {
        case .daily:
            return date
        case .weekly:
            return mondayKey(date)
        case .monthly:
            let (y, m, _) = toYMD(date)
            return y * 100 + m
        case .quarterly:
            let (y, m, _) = toYMD(date)
            return y * 10 + (m - 1) / 3 + 1
        case .yearly:
            let (y, _, _) = toYMD(date)
            return y
        }
    }

    /// 所在周的周一（YYYYMMDD，与 tdx_parser 的 date_cache 语义一致）
    private static func mondayKey(_ d: Int) -> Int {
        let (y, m, day) = toYMD(d)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let dt = cal.date(from: DateComponents(year: y, month: m, day: day)) else { return d }
        let wd = cal.component(.weekday, from: dt)   // 1=周日 ... 7=周六
        let back = (wd + 5) % 7                      // 回到周一
        guard let mon = cal.date(byAdding: .day, value: -back, to: dt) else { return d }
        let c = cal.dateComponents([.year, .month, .day], from: mon)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    private static func toYMD(_ d: Int) -> (Int, Int, Int) {
        (d / 10000, (d / 100) % 100, d % 100)
    }

    // MARK: - 缓存 LRU

    private func touch(key: String, in dict: inout [String: CacheEntry]) {
        guard var e = dict[key] else { return }
        clock += 1
        e.lastUsed = clock
        dict[key] = e
    }

    private func store(key: String, bars: [KlineItem], size: Int64, mtime: TimeInterval,
                       in dict: inout [String: CacheEntry], cap: Int) {
        clock += 1
        dict[key] = CacheEntry(bars: bars, size: size, mtime: mtime, lastUsed: clock)
        while dict.count > cap {
            if let victim = dict.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                dict.removeValue(forKey: victim)
            } else {
                break
            }
        }
    }

    // MARK: - Windows 风格文件名排序（对齐 tdx_parser.windows_sort_key）

    private static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var curIsDigit: Bool?
        for ch in s {
            let d = ch.isNumber
            if curIsDigit != d {
                if !cur.isEmpty { out.append(cur) }
                cur = String(ch)
                curIsDigit = d
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func compareToken(_ x: String, _ y: String) -> ComparisonResult {
        if let xi = Int(x), let yi = Int(y) {
            return xi == yi ? .orderedSame : (xi < yi ? .orderedAscending : .orderedDescending)
        }
        return x.lowercased().compare(y.lowercased())
    }

    static func windowsOrder(_ a: String, _ b: String) -> Bool {
        let ta = tokens(a)
        let tb = tokens(b)
        for i in 0..<min(ta.count, tb.count) {
            let r = compareToken(ta[i], tb[i])
            if r != .orderedSame { return r == .orderedAscending }
        }
        return ta.count < tb.count
    }
}
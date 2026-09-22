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

    /// 数据版本：仅当增量库（tdx_live.db）重载后**内容确实变化**时自增，
    /// 供行情行缓存 / 条件单 / K 线图做热刷新（增量内容不变则不发信号）。
    @Published private(set) var dataVersion = 0

    /// metaID → code 映射（metaList 就绪时一次性建好），避免每次查询线性遍历上万条 metaList
    private let codeMapLock = NSLock()
    private var codeByMetaId: [Int: String] = [:]

    /// 已应用到 dataVersion 的增量库指纹（同一指纹不重复自增，防止重复发布）
    private var appliedLiveFingerprint: String? = nil
    /// 增量库热重载信号订阅
    private var liveReloadCancellable: AnyCancellable?

    private init() {
        dbQueue.async { [weak self] in
            self?.loadDatabase()
        }
        // 增量库热重载（内容确实变化）→ 数据版本自增，各处据 dataVersion 重查
        liveReloadCancellable = LiveDataStore.shared.reloadPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] summary in
                guard let self = self, summary.contentChanged else { return }
                self.bumpDataVersion(summary: summary)
            }
    }

    /// 数据版本自增（主线程）：增量库内容变化后由 liveReloadCancellable 触发。
    /// 同指纹不重复自增 → 不会重复发布（项目教训：@Published 同值赋值也会发布）。
    private func bumpDataVersion(summary: LiveReloadSummary) {
        let key = summary.fingerprintAfter
        guard appliedLiveFingerprint != key else { return }
        guard isLoaded else {
            // 主库 metaList 尚未就绪：此时合并本就查不到 code，等 isLoaded 后的预热读取新数据即可
            DebugLogger.shared.log("[DB] 增量库已变化但主库未就绪，跳过 dataVersion 自增 fp=\(key)")
            return
        }
        appliedLiveFingerprint = key
        dataVersion += 1
        // 底层行情数据整体更新 → 丢弃图表指标曲线缓存（否则指标仍是旧数据算出来的）
        ChartCacheStore.shared.clearAll()
        DebugLogger.shared.log("[DB] dataVersion → \(dataVersion)（增量库内容变化 · \(summary.reason) · 覆盖=\(summary.metaCountAfter)只/日线\(summary.dailyCountAfter)行 · 最新=\(summary.latestDateAfter) · fp=\(key)）")
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
        guard ensureWritableDBExists() else {
            DebugLogger.shared.log("[DB] ensureWritableDBExists 失败")
            return
        }
        let path = Self.writableDBPath
        let rc = sqlite3_open(path, &db)
        if rc != SQLITE_OK {
            DebugLogger.shared.log("[DB] 无法打开数据库 path=\(path)")
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

            // 一次性建好 metaID → code 映射（增量库以 code 为键；避免每次查询线性遍历 metaList）
            var codeMap: [Int: String] = [:]
            codeMap.reserveCapacity(results.count)
            for item in results { codeMap[item.id] = item.code }
            self.codeMapLock.lock()
            self.codeByMetaId = codeMap
            self.codeMapLock.unlock()

            DispatchQueue.main.async {
                self.metaList = results
                self.isLoaded = true
            }
        }
    }

    /// 读取指定标的全量日线数据
    func fetchDailyData(metaId: Int) -> [KlineItem] {
        fetchPeriodTable(metaId: metaId, table: "daily")
    }

    /// 读取指定标的全量周线数据
    func fetchWeeklyData(metaId: Int) -> [KlineItem] {
        fetchPeriodTable(metaId: metaId, table: "weekly")
    }

    /// 读取指定标的全量月线数据（表不存在时返回空，忽略）
    func fetchMonthlyData(metaId: Int) -> [KlineItem] {
        fetchPeriodTable(metaId: metaId, table: "monthly")
    }

    /// 读取指定标的全量季线数据（表不存在时返回空，忽略）
    func fetchquarterlyData(metaId: Int) -> [KlineItem] {
        fetchPeriodTable(metaId: metaId, table: "quarterly")
    }

    /// 读取指定标的全量年线数据（表不存在时返回空，忽略）
    func fetchYearlyData(metaId: Int) -> [KlineItem] {
        fetchPeriodTable(metaId: metaId, table: "yearly")
    }

    /// 按周期读取指定标的的全量数据（联动多视图每个视图可独立(标的,周期)）
    func fetchBars(metaId: Int, period: KlinePeriod) -> [KlineItem] {
        switch period {
        case .daily: return fetchPeriodTable(metaId: metaId, table: "daily")
        case .weekly: return fetchPeriodTable(metaId: metaId, table: "weekly")
        case .monthly: return fetchPeriodTable(metaId: metaId, table: "monthly")
        case .quarterly: return fetchPeriodTable(metaId: metaId, table: "quarterly")
        case .yearly: return fetchPeriodTable(metaId: metaId, table: "yearly")
        }
    }

    /// 通用：读取指定标的某张周期表的数据；字段与日/周线一致，表不存在时 prepare 失败返回空。
    ///
    /// **增量优先 + 主库补齐**（三处出口共用同一规则）：
    /// 结果 = 增量库该 code 的全部行 ∪ 主库该 code 中「增量库里没有该 date」的行；
    /// 同一 date 以增量库为准。
    /// - Note: 不能简单按 `date < 增量最小 date` 切分主库——主库可能比增量库更新
    ///   （例如云端同步中断几天后手动更新了主库），那样会把主库较新的K线丢掉，比不合并还差。
    ///   故按 date 集合去重后再整体降序重排。
    /// 增量库不可用 / 未覆盖该 code / 该表无增量行 → 走纯主库路径，结果与改动前完全一致。
    private func fetchPeriodTable(metaId: Int, table: String) -> [KlineItem] {
        if let live = liveSlice(metaId: metaId, table: table) {
            let main: [KlineItem] = dbQueue.sync {
                guard let db = db else { return [] }
                return runBarsQuery(db: db, table: table, metaId: metaId, limit: nil)
            }
            return merge(live: live, main: main)
        }
        return dbQueue.sync {
            guard let db = db else { return [] }
            return runBarsQuery(db: db, table: table, metaId: metaId, limit: nil)
        }
    }

    /// 增量优先合并：主库剔除与增量库重复的 date，再按 date 降序整体重排
    private func merge(live: LiveSlice, main: [KlineItem]) -> [KlineItem] {
        guard !main.isEmpty else { return live.items }
        let liveDates = Set(live.items.map { $0.date })
        let rest = main.filter { !liveDates.contains($0.date) }
        return (live.items + rest).sorted { $0.date > $1.date }
    }

    /// 增量库该 metaId 对应 code 在某周期表的切片；不可用 / 无 code 映射 / 该表无增量行 → nil
    private func liveSlice(metaId: Int, table: String) -> LiveSlice? {
        guard let code = codeForMetaId(metaId) else { return nil }
        guard let slice = LiveDataStore.shared.slice(code: code, table: table), !slice.isEmpty else { return nil }
        return slice
    }

    /// metaID → code（O(1) 字典查找，映射随 metaList 就绪时一次性建好）
    private func codeForMetaId(_ metaId: Int) -> String? {
        codeMapLock.lock()
        defer { codeMapLock.unlock() }
        return codeByMetaId[metaId]
    }

    /// 统一执行 K 线查询并组装结果（需已在 dbQueue 上）
    /// - Parameter limit: 非 nil 时追加 `LIMIT ?`
    private func runBarsQuery(db: OpaquePointer, table: String,
                              metaId: Int, limit: Int?) -> [KlineItem] {
        var query = "SELECT date, open, high, low, close, vol, amo FROM \(table) WHERE meta_id = ?"
        query += " ORDER BY date DESC"
        if limit != nil { query += " LIMIT ?" }
        query += ";"

        var statement: OpaquePointer?
        var results: [KlineItem] = []
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return results
        }
        var index: Int32 = 1
        sqlite3_bind_int64(statement, index, Int64(metaId)); index += 1
        if let limit = limit {
            sqlite3_bind_int64(statement, index, Int64(Swift.max(1, limit))); index += 1
        }
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

    /// 取某标的某周期表最近 limit 根（ORDER BY date DESC → 结果从新→旧）。
    /// 用于行情/自选列表表单只需要最近 80 根，避免全量读（一次 1K+ 只的话全量读会卡死）。
    /// **增量优先 + 主库补齐**后在合并结果上取前 limit 条。
    func fetchPeriodLimited(metaId: Int, table: String, limit: Int) -> [KlineItem] {
        let wanted = Swift.max(1, limit)
        if let live = liveSlice(metaId: metaId, table: table) {
            // 主库最多会被增量库顶掉 live.items.count 行，故多取这么多，保证合并后仍够 wanted 条
            let main: [KlineItem] = dbQueue.sync {
                guard let db = db else { return [] }
                return runBarsQuery(db: db, table: table, metaId: metaId,
                                    limit: wanted + live.items.count)
            }
            return Array(merge(live: live, main: main).prefix(wanted))
        }
        return dbQueue.sync {
            guard let db = db else { return [] }
            return runBarsQuery(db: db, table: table, metaId: metaId, limit: wanted)
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
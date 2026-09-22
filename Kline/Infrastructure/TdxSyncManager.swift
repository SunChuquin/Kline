//
//  TdxSyncManager.swift
//  Kline
//
//  增量行情库（Documents/tdx_live.db）自动拉取，两种 manifest 版本：
//   - **schema >= 3（v3，主路径）**：manifest 的 `buckets[]` 是**日分片**（一片 = 一个交易日，≈0.5MB），
//     按主库缺口（`metaList.lastDate` 最大值 → 今天）选出相交分片（**上限 30 片**）→
//     逐片下载 → sha256 校验 → LiveDataStore 合并（键 `file`）→ 裁剪冗余 → 单次热刷新；
//   - **schema 缺失 / 1（旧）**：整文件下载 → sha256 校验 → 原子替换 `tdx_live.db`（升级瞬间不失联）。
//
//  关键约束：
//   - 任一环节失败都 **保留上一版文件**，临时文件必清理，绝不产生半成品；
//   - 同一时刻只允许一个同步在跑（主线程 isSyncing 守卫 + 文件工作串行队列）；
//   - 网络请求全部在后台（URLSession 异步），`@Published` 一律回主线程写；
//   - 拉取/校验全程不进入 `LiveDataStore` 与 `DatabaseManager` 的队列，避免交叉嵌套。
//

import Foundation
import Combine
import CryptoKit
import UIKit

// MARK: - manifest 数据契约

/// 云端分片（schema 3）：`bucket_<id>.db`，**一片 = 一个交易日**（`min_date == max_date`）
struct TdxLiveBucket: Codable {
    /// 分片文件名（例：`bucket_20718.db`），与 manifest 同目录
    var file: String
    /// 分片 id = (date - date(1970,1,1)).days，例 20260922 → 20718
    var id: Int
    /// 该分片覆盖的最小 / 最大 date（YYYYMMDD；日分片下两者相等）
    var min_date: Int?
    var max_date: Int?
    /// 文件字节数
    var bytes: Int64?
    /// 分片文件 sha256（十六进制小写）
    var sha256: String?
    /// 各表行数：daily / weekly / monthly / meta
    var rows: [String: Int]?
}

/// 云端 manifest（**向后兼容 schema 1/2**）：
/// - schema 缺失 / 1（旧）：`version/symbols/min_date/max_date/rows/sha256` → 整文件替换 `tdx_live.db`；
/// - schema 2/3（分片）：`buckets[]` → 按缺口取片、逐片合并（v3 为日分片 + 保留 30 片）。
struct TdxLiveManifest: Codable {
    /// >=3 = v3 日分片；缺失 / 1 = 旧单文件；2 = 14 日分片（同样按分片路径处理）
    var schema: Int?
    /// schema 1：每次生成自增的版本号
    var version: Int?
    var generated_at: Int?
    /// 行情的真实交易日（YYYYMMDD）
    var trade_date: Int?
    /// 生成端：`pc_tdx`（电脑侧，覆盖率可达 100%）/ `eastmoney`（云端兜底）
    var source: String?
    /// 覆盖标的数（schema 1）
    var symbols: Int?
    /// schema 1：整库覆盖区间
    var min_date: Int?
    var max_date: Int?
    /// schema 1：各表行数
    var rows: [String: Int]?
    /// schema 1：`tdx_live.db` 的 sha256
    var sha256: String?
    /// schema 2：一个分片覆盖的自然日数
    var bucket_days: Int?
    /// schema 3：清单总量（`universe.txt`，3611）
    var universe: Int?
    /// schema 3：本次实际覆盖数
    var covered: Int?
    /// schema 3：覆盖率 = covered / universe
    var coverage: Double?
    /// schema 3：未覆盖 file 的样例（如云端拿不到的扩展行情指数）
    var missing_sample: [String]?
    /// 最新分片 id
    var latest_bucket: Int?
    /// schema 3：保留分片上限（30）
    var keep_buckets: Int?
    /// 分片列表（按 id 从新到旧）
    var buckets: [TdxLiveBucket]?
    /// schema 3：历史重灌包（差分包）列表，与 `buckets` 并列；元素字段复用分片结构。
    /// **可为 nil（旧 manifest 无该字段）→ 向后兼容，按「无补丁」处理**。
    var patches: [TdxLiveBucket]?

    /// 是否走「分片 + 按缺口取片」路径（schema < 3 且无 buckets 的旧 manifest → false）
    var isSharded: Bool { (schema ?? 1) >= 2 && !(buckets ?? []).isEmpty }
}

/// 单步网络请求结果（不用 `Result`：String 不满足 Error）
private enum NetStep<T> {
    case ok(T)
    case failed(String)
}

// MARK: - 同步管理器

final class TdxSyncManager: ObservableObject {
    static let shared = TdxSyncManager()

    private let config = TdxSyncConfig.shared

    // MARK: - 对外只读状态（一律在主线程发布）

    /// 是否正在同步（true 时重复触发被忽略）
    @Published private(set) var isSyncing = false
    /// 上次同步完成时间
    @Published private(set) var lastSyncAt: Date?
    /// 上次同步得到的 manifest 版本号
    @Published private(set) var lastVersion: Int?
    /// 上次同步得到的行情交易日（YYYYMMDD）
    @Published private(set) var lastTradeDate: Int?
    /// 上次同步成功所用的源（原始填写值）
    @Published private(set) var lastSource: String?
    /// 最近一次失败原因（成功后清空）
    @Published private(set) var lastError: String?
    /// 下一个计划时刻文案，形如 "今日 14:30" / "明日 11:00"
    @Published private(set) var nextScheduledText: String?

    /// 本次下载的分片数 / 总字节（分片模式；schema 1 整库替换时为 0 / 0）
    @Published private(set) var lastBucketCount = 0
    @Published private(set) var lastBucketBytes: Int64 = 0
    /// 本次分片覆盖的日期区间（YYYYMMDD；0 表示无）
    @Published private(set) var lastCoveredFrom = 0
    @Published private(set) var lastCoveredTo = 0
    /// manifest 声明：清单总量 / 实际覆盖数（v3；0 = 未提供）
    @Published private(set) var lastUniverse = 0
    @Published private(set) var lastCovered = 0
    /// 补充说明（如「主库已是最新，无需下载分片」）
    @Published private(set) var lastNote: String?
    /// 主库 metaList 中 lastDate 的最大值（0 = 全部缺失）
    @Published private(set) var mainLatestDate = 0

    /// 是否已启用（透传配置）
    var isEnabled: Bool { config.enabled }

    // MARK: - 本地记录键（UserDefaults：内容相同则跳过的依据 + 状态回显）

    private static let lastVersionKey = "kline.tdxsync.lastVersion"
    private static let lastShaKey = "kline.tdxsync.lastSha"
    private static let lastTradeDateKey = "kline.tdxsync.lastTradeDate"
    private static let lastSyncAtKey = "kline.tdxsync.lastSyncAt"
    private static let lastSourceKey = "kline.tdxsync.lastSource"
    /// 已合并补丁包的幂等记录（sha256 优先，缺省用文件名；截断到最近 `maxMergedPatchRecords` 条）
    private static let mergedPatchesKey = "kline.tdxsync.mergedPatches"

    // MARK: - 本地文件路径

    /// 增量库（与 LiveDataStore 监视的路径一致）
    static var dbPath: String { LiveDataStore.writableDBPath }
    /// 下载落地的临时文件（校验通过前绝不覆盖正式文件）
    static var tmpPath: String {
        documentsPath + "/tdx_live.db.tmp"
    }
    /// 分片下载落地的临时文件（合并后即删）
    static func bucketTmpPath(_ file: String) -> String {
        documentsPath + "/" + file + ".tmp"
    }
    /// 最近一次成功同步的 manifest（留档，便于展示 / 与远端比对）
    static var manifestPath: String {
        documentsPath + "/" + TdxSyncConfig.manifestFileName
    }
    private static var documentsPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }

    // MARK: - 内部状态

    /// 文件哈希 / 原子替换等 CPU-IO 工作串行队列（不在主线程做）
    private let workQueue = DispatchQueue(label: "com.sunck.kline.tdxsync.work")

    /// 无缓存会话：manifest 请求 15s 超时，下载 60s 超时（逐请求覆盖）
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg)
    }()

    /// 定时器（**只在主线程访问**）
    private var timer: Timer?
    /// 当前定时器使用的间隔，用于配置变更后重建
    private var timerInterval: TimeInterval = 0
    private var foregroundObserver: NSObjectProtocol?
    private var isStarted = false
    /// 当天已执行过的时刻（键 = "yyyyMMdd 分钟数"），保证"到点触发且当天不重复"
    private var ranSlots: Set<String> = []
    private var ranSlotsDayKey = ""
    /// 本轮分片同步开始时算得的主库最新交易日（0 = 无）→ 合并后据此裁剪增量（**只在主线程访问**）
    private var pendingMainLatest = 0

    private init() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.lastVersionKey) != nil { lastVersion = d.integer(forKey: Self.lastVersionKey) }
        if d.object(forKey: Self.lastTradeDateKey) != nil { lastTradeDate = d.integer(forKey: Self.lastTradeDateKey) }
        if let t = d.object(forKey: Self.lastSyncAtKey) as? Double { lastSyncAt = Date(timeIntervalSince1970: t) }
        lastSource = d.string(forKey: Self.lastSourceKey)
    }

    // MARK: - 启动调度（由 KlineApp 调用，紧跟 LiveDataStore.startWatching 之后）

    /// 启动前台调度：每 `foregroundCheckInterval` 检查一次"今天该跑的时刻是否已到且未跑"，
    /// 并在回前台时补一次检查（幂等，重复调用只生效一次）
    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isStarted else { return }
            self.isStarted = true
            self.installForegroundObserver()
            self.scheduleTimer()
            self.checkSchedule(trigger: "启动检查")
            DebugLogger.shared.log("[TdxSync] 调度启动 enabled=\(self.config.enabled) 间隔=\(Int(self.config.foregroundCheckInterval))s 时刻=\(self.config.scheduleTimes.joined(separator: ",")) 交易日限制=\(self.config.tradingDaysOnly) 局域网地址=\(LocalNetworkAddress.currentIPv4() ?? "未连接")")
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = Swift.max(15, config.foregroundCheckInterval)
        timerInterval = interval
        // Timer 只在前台 run loop 上走，App 切后台自然停摆；回前台由通知补一次检查
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkSchedule(trigger: "定时检查")
        }
        t.tolerance = 5
        timer = t
    }

    private func installForegroundObserver() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            self?.checkSchedule(trigger: "回前台检查")
        }
    }

    // MARK: - 到点调度（主线程）

    /// 到点检查：enabled 且（交易日限制下）当天最新已过时刻尚未执行 → 触发一次同步
    private func checkSchedule(trigger: String) {
        // 配置里改了轮询间隔 → 重建定时器
        if isStarted, abs(config.foregroundCheckInterval - timerInterval) > 0.5 { scheduleTimer() }
        updateNextScheduledText()

        guard config.enabled else { return }
        let now = Date()
        if config.tradingDaysOnly, !Self.isTradingDay(now) {
            DebugLogger.shared.log("[TdxSync] \(trigger)：非交易日，跳过")
            return
        }
        // 同步进行中：本次触发忽略，且不占用时刻（同步结束后下一轮仍会补上）
        guard !isSyncing else { return }

        // 跨天重置「当天已跑」记录
        let dayKey = Self.dayKey(now)
        if ranSlotsDayKey != dayKey {
            ranSlotsDayKey = dayKey
            ranSlots.removeAll()
        }
        let nowMinutes = Self.minutesOfDay(now)
        // 只取「已到点」中最晚的一个：避免冷启动时把 11:00 / 14:30 / 15:05 / 17:30 四个都跑一遍
        let passed = config.scheduleTimes.compactMap { Self.minutes(of: $0) }.filter { $0 <= nowMinutes }
        guard let slot = passed.max() else { return }
        let slotKey = dayKey + " " + String(slot)
        guard !ranSlots.contains(slotKey) else { return }
        ranSlots.insert(slotKey)
        DebugLogger.shared.log("[TdxSync] \(trigger)：已到点 \(Self.slotText(slot))，触发同步")
        beginSync(reason: trigger)
        // 同一时刻同时触发「清单标的当日K线」东财直连更新（独立通道：与云端 manifest 成败互不影响）
        WatchlistSyncManager.shared.sync(reason: trigger, slot: Self.slotText(slot))
    }

    /// 刷新「下次计划时刻」文案（未启用时也展示，便于用户理解时刻表）
    private func updateNextScheduledText() {
        let text = Self.nextSlotDescription(for: config.scheduleTimes,
                                            now: Date(),
                                            tradingDaysOnly: config.tradingDaysOnly)
        if nextScheduledText != text { nextScheduledText = text }
    }

    // MARK: - 手动触发

    /// 立即更新：走与调度完全相同的拉取/校验/替换流程（同样受 enabled 开关约束）
    func manualSync() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.config.enabled else {
                self.setError("未启用数据同步，请先打开上方开关")
                return
            }
            self.beginSync(reason: "手动更新")
        }
    }

    // MARK: - 同步主流程（以下方法均只在主线程调用，除非另有说明）

    private func beginSync(reason: String) {
        guard !isSyncing else {
            DebugLogger.shared.log("[TdxSync] 已在同步中，忽略本次触发（\(reason)）")
            return
        }
        guard !config.sourceURLs.isEmpty else {
            setError("未配置数据源地址")
            return
        }
        isSyncing = true
        setError(nil)
        if lastNote != nil { lastNote = nil }
        pendingMainLatest = 0
        let latest = Self.mainLatestTradeDate()
        if mainLatestDate != latest { mainLatestDate = latest }
        DebugLogger.shared.log("[TdxSync] 开始同步（\(reason)）源数=\(config.sourceURLs.count) 主库最新=\(latest)")
        trySource(index: 0, reason: reason, errors: [])
    }

    /// 按顺序尝试第 index 个源；失败则换下一个，全部失败统一汇报
    private func trySource(index: Int, reason: String, errors: [String]) {
        guard index < config.sourceURLs.count else {
            var msg = errors.last ?? "全部数据源均失败"
            if errors.count > 1 { msg += "（共 \(errors.count) 个源失败）" }
            finishFailure(msg)
            return
        }
        let raw = config.sourceURLs[index]
        guard let urls = TdxSyncConfig.resolve(raw) else {
            trySource(index: index + 1, reason: reason, errors: errors + ["源\(index + 1) 地址非法：\(raw)"])
            return
        }
        // 候选① 分片布局 `<base>/live/manifest.json`（v3 首选）；候选② 旧布局 `<base>/tdx_live.manifest.json`（兜底）
        let candidates = [urls.liveManifest, urls.manifest]
        DebugLogger.shared.log("[TdxSync] 源\(index + 1) 取 manifest（\(candidates.count) 个候选）")

        fetchFirstManifest(candidates: candidates, index: index) { [weak self] step in
            guard let self = self else { return }
            switch step {
            case .failed(let err):
                DebugLogger.shared.log("[TdxSync] 源\(index + 1) manifest 失败：\(err)")
                self.trySource(index: index + 1, reason: reason, errors: errors + ["源\(index + 1) \(err)"])
            case .ok(let pair):
                let (manifest, manifestURL) = pair
                if let bad = Self.validate(manifest) {
                    DebugLogger.shared.log("[TdxSync] 源\(index + 1) manifest 非法：\(bad)")
                    self.trySource(index: index + 1, reason: reason, errors: errors + ["源\(index + 1) \(bad)"])
                    return
                }
                if manifest.isSharded {
                    self.startShardedSync(urls: urls, manifestURL: manifestURL, manifest: manifest)
                    return
                }
                // schema 1（向后兼容）：整文件下载 + 原子替换
                DebugLogger.shared.log("[TdxSync] 源\(index + 1) 旧版 manifest（schema 1）→ 整文件替换")
                // 内容相同 → 跳过下载（省流量）
                if let v = manifest.version, v == self.recordedVersion,
                   let sha = manifest.sha256, sha == self.recordedSha {
                    DebugLogger.shared.log("[TdxSync] 源\(index + 1) 版本 v\(v) 与本地一致 → 跳过下载")
                    self.finishSuccess(manifest: manifest, source: raw, installed: false, note: "内容与本地一致，跳过下载",
                                       bucketCount: 0, bytes: 0, coveredFrom: 0, coveredTo: 0)
                    return
                }
                self.downloadDB(urls: urls, manifest: manifest, index: index, reason: reason, errors: errors)
            }
        }
    }

    /// 依次尝试 manifest 候选地址，第一个能取到并解析成功的生效
    private func fetchFirstManifest(candidates: [URL], index: Int,
                                    completion: @escaping (NetStep<(TdxLiveManifest, URL)>) -> Void) {
        guard let first = candidates.first else {
            completion(.failed("manifest 候选地址为空"))
            return
        }
        fetchManifest(url: first) { [weak self] step in
            guard let self = self else { return }
            switch step {
            case .ok(let manifest):
                completion(.ok((manifest, first)))
            case .failed(let err):
                if candidates.count > 1 {
                    DebugLogger.shared.log("[TdxSync] 源\(index + 1) manifest \(first.lastPathComponent) 失败（\(err)）→ 试下一个候选")
                    self.fetchFirstManifest(candidates: Array(candidates.dropFirst()), index: index, completion: completion)
                } else {
                    completion(.failed(err))
                }
            }
        }
    }

    // MARK: - 分片模式（schema 2/3）：按缺口取片 → 逐片下载/校验/合并

    /// 用主库 `metaList` 的 `lastDate` 最大值到今日算出缺口，选出所需分片后逐片串行下载合并。
    /// v3：一片 = 一个交易日（≈0.5MB），典型只取 1 片；上限 30 片（保留窗口上限）。
    private func startShardedSync(urls: TdxSyncURLs, manifestURL: URL, manifest: TdxLiveManifest) {
        let needTo = Self.todayYMD()
        let mainLatest = Self.mainLatestTradeDate()
        pendingMainLatest = mainLatest
        if mainLatestDate != mainLatest { mainLatestDate = mainLatest }

        let buckets = manifest.buckets ?? []
        let earliest = buckets.compactMap { $0.min_date }.min() ?? 0
        // 主库无 lastDate → 退化为取最早分片的 min_date（即全部保留窗口都要）
        let needFrom = mainLatest > 0 ? mainLatest : earliest
        let selected = Self.selectBuckets(buckets, needFrom: needFrom, needTo: needTo,
                                          limit: Self.maxBucketSelection)

        let baseDir = manifestURL.deletingLastPathComponent()
        DebugLogger.shared.log("[TdxSync] 分片模式 schema=\(manifest.schema ?? 2) 源=\(manifest.source ?? "-") 覆盖=\(manifest.covered.map(String.init) ?? "-")/\(manifest.universe.map(String.init) ?? "-") 主库最新=\(mainLatest) 缺口 \(needFrom)~\(needTo) 候选分片=\(buckets.count) 选中=\(selected.count) 目录=\(baseDir.absoluteString)")

        guard !selected.isEmpty else {
            DebugLogger.shared.log("[TdxSync] 主库已新于所有分片 → 跳过下载")
            // 分片无需下载，但补丁包（历史重灌）与「缺口」无关，仍须应用
            let ctx = PatchSyncContext(urls: urls, manifest: manifest, bucketCount: 0, bytes: 0,
                                       coveredFrom: 0, coveredTo: 0, note: "主库已是最新，无需下载分片")
            syncPatches(manifest.patches ?? [], at: baseDir, context: ctx, applied: 0)
            return
        }
        downloadBuckets(selected, at: baseDir, urls: urls, manifest: manifest)
    }

    /// 逐片串行：下载 → sha256 校验 → 合并进本地增量库；任一片失败即整体失败
    private func downloadBuckets(_ remaining: [TdxLiveBucket], at baseDir: URL,
                                 urls: TdxSyncURLs, manifest: TdxLiveManifest,
                                 done: [(id: Int, bytes: Int64, minDate: Int, maxDate: Int, rows: Int)] = []) {
        guard let bucket = remaining.first else {
            // 全部成功：先裁剪冗余（主库已有的日期），再一次性热刷新
            let bytes = done.reduce(Int64(0)) { $0 + $1.bytes }
            let minDate = done.map { $0.minDate }.filter { $0 > 0 }.min() ?? 0
            let maxDate = done.map { $0.maxDate }.max() ?? 0
            let rows = done.reduce(0) { $0 + $1.rows }
            DebugLogger.shared.log("[TdxSync] 分片全部合并完成 \(done.count) 片/\(bytes)字节/\(rows)行 区间 \(minDate)~\(maxDate)")
            // 分片之后处理历史重灌包（patches）；二者都处理完再统一收尾（裁剪 + 一次热刷新）
            let ctx = PatchSyncContext(urls: urls, manifest: manifest, bucketCount: done.count,
                                       bytes: bytes, coveredFrom: minDate, coveredTo: maxDate, note: nil)
            syncPatches(manifest.patches ?? [], at: baseDir, context: ctx, applied: 0)
            return
        }
        let file = bucket.file
        let url = baseDir.appendingPathComponent(file)
        let tmp = Self.bucketTmpPath(file)
        DebugLogger.shared.log("[TdxSync] 下载分片 id=\(bucket.id) \(url.absoluteString)")

        downloadFile(url: url, toPath: tmp) { [weak self] step in
            guard let self = self else { return }
            switch step {
            case .failed(let err):
                self.finishFailure("第 \(bucket.id) 片（\(file)）下载失败：\(err)")
            case .ok(let size):
                // 哈希校验放工作串行队列，校验通过后回主线程合并
                self.workQueue.async { [weak self] in
                    let outcome = TdxSyncManager.verifyBucket(tmpPath: tmp, bucket: bucket)
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        switch outcome {
                        case .failed(let err):
                            try? FileManager.default.removeItem(atPath: tmp)
                            self.finishFailure("第 \(bucket.id) 片（\(file)）校验失败：\(err)")
                        case .ok:
                            LiveDataStore.shared.mergeBucket(atPath: tmp) { result in
                                try? FileManager.default.removeItem(atPath: tmp)
                                guard result.ok else {
                                    self.finishFailure("第 \(bucket.id) 片（\(file)）合并失败：\(result.message)")
                                    return
                                }
                                DebugLogger.shared.log("[TdxSync] 分片 id=\(bucket.id) 合并成功：\(result.message)")
                                self.downloadBuckets(Array(remaining.dropFirst()), at: baseDir, urls: urls,
                                                     manifest: manifest,
                                                     done: done + [(id: bucket.id, bytes: size,
                                                                    minDate: bucket.min_date ?? 0,
                                                                    maxDate: bucket.max_date ?? 0,
                                                                    rows: bucket.rows?["daily"] ?? 0)])
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 历史重灌包（patches，schema 3）：分片之后逐包下载 → 校验 → 合并

    /// 补丁同步的固定上下文（分片阶段统计 + 收尾所需字段），逐包递归时透传，避免长参数列表
    private struct PatchSyncContext {
        let urls: TdxSyncURLs
        let manifest: TdxLiveManifest
        let bucketCount: Int
        let bytes: Int64
        let coveredFrom: Int
        let coveredTo: Int
        let note: String?
    }

    /// 逐个处理 manifest 的 `patches[]`：下载到临时文件 → sha256 校验 → 合并进本地增量库 → 删临时文件。
    /// - **幂等**：按 `patchKey`（sha256 优先）跳过已合并过的补丁（记录持久化到 UserDefaults，上限 `maxMergedPatchRecords`）；
    /// - **容错**：任一补丁下载 / 校验 / 合并失败**只记日志并跳过**，绝不影响分片同步的整体成功；
    /// - **收尾**：全部处理完统一 `finishSuccess`；分片有写入或确有补丁写入时才裁剪 + 热刷新（与分片共用同一收尾路径）。
    private func syncPatches(_ remaining: [TdxLiveBucket], at baseDir: URL,
                             context ctx: PatchSyncContext, applied: Int) {
        let rest = Array(remaining.dropFirst())
        guard let patch = remaining.first else {
            finishSuccess(manifest: ctx.manifest, source: ctx.urls.source, installed: true, note: ctx.note,
                          bucketCount: ctx.bucketCount, bytes: ctx.bytes,
                          coveredFrom: ctx.coveredFrom, coveredTo: ctx.coveredTo)
            if ctx.bucketCount > 0 || applied > 0 {
                applyTrimThenReload()
            } else {
                DebugLogger.shared.log("[TdxSync] 无分片亦无补丁写入 → 跳过裁剪热刷新")
            }
            return
        }
        let file = patch.file
        guard !file.isEmpty else {
            DebugLogger.shared.log("[TdxSync] 补丁缺 file 字段 → 跳过")
            syncPatches(rest, at: baseDir, context: ctx, applied: applied)
            return
        }
        let key = Self.patchKey(patch)
        guard !mergedPatchRecords.contains(key) else {
            DebugLogger.shared.log("[TdxSync] 补丁 \(file) 已合并过 → 跳过")
            syncPatches(rest, at: baseDir, context: ctx, applied: applied)
            return
        }
        let url = baseDir.appendingPathComponent(file)
        let tmp = Self.bucketTmpPath(file)
        DebugLogger.shared.log("[TdxSync] 下载补丁 \(file) \(url.absoluteString)")
        downloadFile(url: url, toPath: tmp) { [weak self] step in
            guard let self = self else { return }
            switch step {
            case .failed(let err):
                DebugLogger.shared.log("[TdxSync] 补丁 \(file) 下载失败（跳过，不影响分片）：\(err)")
                try? FileManager.default.removeItem(atPath: tmp)
                self.syncPatches(rest, at: baseDir, context: ctx, applied: applied)
            case .ok:
                // 哈希校验放工作串行队列，通过后回主线程合并
                self.workQueue.async { [weak self] in
                    let outcome = TdxSyncManager.verifyPatch(tmpPath: tmp, patch: patch)
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        switch outcome {
                        case .failed(let err):
                            DebugLogger.shared.log("[TdxSync] 补丁 \(file) 校验失败（跳过，不影响分片）：\(err)")
                            try? FileManager.default.removeItem(atPath: tmp)
                            self.syncPatches(rest, at: baseDir, context: ctx, applied: applied)
                        case .ok:
                            LiveDataStore.shared.mergeBucket(atPath: tmp) { result in
                                try? FileManager.default.removeItem(atPath: tmp)
                                guard result.ok else {
                                    DebugLogger.shared.log("[TdxSync] 补丁 \(file) 合并失败（跳过，不影响分片）：\(result.message)")
                                    self.syncPatches(rest, at: baseDir, context: ctx, applied: applied)
                                    return
                                }
                                DebugLogger.shared.log("[TdxSync] 补丁 \(file) 合并成功：\(result.message)")
                                var records = self.mergedPatchRecords
                                if !records.contains(key) {
                                    records.append(key)
                                    self.mergedPatchRecords = records
                                }
                                self.syncPatches(rest, at: baseDir, context: ctx, applied: applied + 1)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 合并完成后：把「主库已有」的日期从本地增量里裁掉，再一次性 reloadAsync 热刷新
    private func applyTrimThenReload() {
        let trimBefore = pendingMainLatest > 0 ? pendingMainLatest : nil
        guard let trimBefore = trimBefore else {
            DebugLogger.shared.log("[TdxSync] 主库无 lastDate → 不裁剪增量")
            LiveDataStore.shared.reloadAsync(completion: TdxSyncManager.logReload)
            return
        }
        LiveDataStore.shared.trim(beforeDate: trimBefore) { result in
            DebugLogger.shared.log("[TdxSync] 增量裁剪：\(result.message)")
            LiveDataStore.shared.reloadAsync(completion: TdxSyncManager.logReload)
        }
    }

    private static func logReload(_ summary: LiveReloadSummary) {
        DebugLogger.shared.log("[TdxSync] 热刷新完成 可用=\(summary.isAvailable) 覆盖=\(summary.metaCountAfter)只 最新=\(summary.latestDateAfter) 内容变化=\(summary.contentChanged)")
    }

    /// 下载 db 到临时文件 → 后台校验 + 原子替换
    private func downloadDB(urls: TdxSyncURLs, manifest: TdxLiveManifest,
                            index: Int, reason: String, errors: [String]) {
        let tmp = Self.tmpPath
        DebugLogger.shared.log("[TdxSync] 源\(index + 1) 下载 \(urls.db.absoluteString)")
        downloadFile(url: urls.db, toPath: tmp) { [weak self] step in
            guard let self = self else { return }
            switch step {
            case .failed(let err):
                DebugLogger.shared.log("[TdxSync] 源\(index + 1) 下载失败：\(err)")
                self.trySource(index: index + 1, reason: reason, errors: errors + ["源\(index + 1) \(err)"])
            case .ok:
                // 哈希校验 + 原子替换放到工作串行队列，完成后回主线程
                self.workQueue.async { [weak self] in
                    guard let self = self else { return }
                    let outcome = self.verifyAndInstall(tmpPath: tmp, manifest: manifest)
                    DispatchQueue.main.async {
                        switch outcome {
                        case .ok:
                            self.finishSuccess(manifest: manifest, source: urls.source, installed: true,
                                               note: nil, bucketCount: 0, bytes: 0, coveredFrom: 0, coveredTo: 0)
                        case .failed(let err):
                            DebugLogger.shared.log("[TdxSync] 源\(index + 1) 校验/替换失败：\(err)")
                            self.trySource(index: index + 1, reason: reason, errors: errors + ["源\(index + 1) \(err)"])
                        }
                    }
                }
            }
        }
    }

    /// 成功收尾（主线程）：记录版本/哈希/时间/源与分片统计。
    /// - schema 1：文件确实被替换后在此立即热刷新；
    /// - schema 2：由调用方在「合并 + 裁剪」后统一 `reloadAsync`（避免逐片重复刷新）。
    private func finishSuccess(manifest: TdxLiveManifest, source: String, installed: Bool,
                               note: String?, bucketCount: Int, bytes: Int64,
                               coveredFrom: Int, coveredTo: Int) {
        let now = Date()
        let d = UserDefaults.standard
        if let v = manifest.version { d.set(v, forKey: Self.lastVersionKey) }
        if let sha = manifest.sha256 { d.set(sha, forKey: Self.lastShaKey) }
        if let td = manifest.trade_date, td > 0 { d.set(td, forKey: Self.lastTradeDateKey) }
        d.set(now.timeIntervalSince1970, forKey: Self.lastSyncAtKey)
        d.set(source, forKey: Self.lastSourceKey)

        if let v = manifest.version, lastVersion != v { lastVersion = v }
        if let td = manifest.trade_date, lastTradeDate != td { lastTradeDate = td }
        if lastSyncAt != now { lastSyncAt = now }
        if lastSource != source { lastSource = source }
        if lastBucketCount != bucketCount { lastBucketCount = bucketCount }
        if lastBucketBytes != bytes { lastBucketBytes = bytes }
        if lastCoveredFrom != coveredFrom { lastCoveredFrom = coveredFrom }
        if lastCoveredTo != coveredTo { lastCoveredTo = coveredTo }
        // v3：覆盖率取 manifest 声明的 covered / universe（电脑侧可达 100%，云端兜底约 91%）
        let universe = manifest.universe ?? manifest.symbols ?? 0
        let covered = manifest.covered ?? manifest.symbols ?? 0
        if lastUniverse != universe { lastUniverse = universe }
        if lastCovered != covered { lastCovered = covered }
        if lastNote != note { lastNote = note }
        setError(nil)
        if isSyncing { isSyncing = false }

        DebugLogger.shared.log("[TdxSync] 同步成功 schema=\(manifest.schema ?? 1) v\(manifest.version.map(String.init) ?? "-") trade=\(manifest.trade_date.map(String.init) ?? "-") 覆盖=\(covered)/\(universe) 分片=\(bucketCount)片/\(bytes)字节 区间=\(coveredFrom)~\(coveredTo) 源=\(source) 实际写入=\(installed)\(note.map { " · \($0)" } ?? "")")

        // schema 1：文件被替换 → 立即热刷新（分片模式由 applyTrimThenReload 统一刷新一次）
        guard installed, !manifest.isSharded else { return }
        LiveDataStore.shared.reloadAsync(completion: Self.logReload)
    }

    /// 失败收尾（主线程）：保留上一版文件，记录原因
    private func finishFailure(_ message: String) {
        DebugLogger.shared.log("[TdxSync] 同步失败：\(message)")
        setError(message)
        if isSyncing { isSyncing = false }
    }

    /// 写失败原因（值未变不写，避免无谓的 @Published 发布）
    private func setError(_ message: String?) {
        if lastError != message { lastError = message }
    }

    // MARK: - 校验 + 原子替换（在 workQueue 上执行）

    /// 校验临时文件 sha256 == manifest.sha256，通过后原子替换 `Documents/tdx_live.db`；
    /// 任一失败都清理临时文件并保留上一版（返回可读原因）
    private func verifyAndInstall(tmpPath: String, manifest: TdxLiveManifest) -> NetStep<Void> {
        let fm = FileManager.default

        // 1) sha256 内容校验
        guard let expected = manifest.sha256?.lowercased() else {
            try? fm.removeItem(atPath: tmpPath)
            return .failed("manifest 缺少 sha256")
        }
        guard let actual = Self.sha256Hex(ofFile: tmpPath) else {
            try? fm.removeItem(atPath: tmpPath)
            return .failed("临时文件读取失败")
        }
        guard actual == expected else {
            try? fm.removeItem(atPath: tmpPath)
            return .failed("哈希不符（期望 \(expected.prefix(8))… 实际 \(actual.prefix(8))…）")
        }

        // 2) 留档 manifest（供 UI 展示 / 与远端比对；失败不影响主流程）
        if let mData = try? JSONEncoder().encode(manifest) {
            try? mData.write(to: URL(fileURLWithPath: Self.manifestPath), options: .atomic)
        }

        // 3) 原子替换增量库
        let db = Self.dbPath
        let tmpURL = URL(fileURLWithPath: tmpPath)
        let dbURL = URL(fileURLWithPath: db)
        do {
            if fm.fileExists(atPath: db) {
                // 同目录内原子替换（生成备份文件由系统清理）
                _ = try fm.replaceItemAt(dbURL, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: dbURL)
            }
        } catch {
            // replaceItemAt 偶发失败（如目标被占用）→ 退化为先删后移
            do {
                if fm.fileExists(atPath: db) { try fm.removeItem(atPath: db) }
                try fm.moveItem(atPath: tmpPath, toPath: db)
            } catch {
                try? fm.removeItem(atPath: tmpPath)
                return .failed("替换增量库失败：\(error.localizedDescription)")
            }
        }
        // 兜底清理（replaceItemAt 成功时临时文件已不存在）
        if fm.fileExists(atPath: tmpPath) { try? fm.removeItem(atPath: tmpPath) }
        return .ok(())
    }

    // MARK: - 网络（回调一律回主线程）

    /// 取 manifest（15s 超时）
    private func fetchManifest(url: URL, completion: @escaping (NetStep<TdxLiveManifest>) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        session.dataTask(with: req) { data, resp, err in
            let step = Self.decodeManifest(data: data, response: resp, error: err)
            DispatchQueue.main.async { completion(step) }
        }.resume()
    }

    private static func decodeManifest(data: Data?, response: URLResponse?, error: Error?) -> NetStep<TdxLiveManifest> {
        if let error = error { return .failed("manifest 请求失败：\(error.localizedDescription)") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let data = data, (200..<300).contains(status) else { return .failed("manifest HTTP \(status)") }
        guard let manifest = try? JSONDecoder().decode(TdxLiveManifest.self, from: data) else {
            return .failed("manifest 解析失败（\(data.count) 字节）")
        }
        return .ok(manifest)
    }

    /// 下载到指定路径（60s 超时；downloadTask 直接落盘，不把整文件读进内存）
    private func downloadFile(url: URL, toPath path: String, completion: @escaping (NetStep<Int64>) -> Void) {
        try? FileManager.default.removeItem(atPath: path)
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        session.downloadTask(with: req) { tmp, resp, err in
            let step = Self.moveDownloaded(tmp: tmp, response: resp, error: err, toPath: path)
            DispatchQueue.main.async { completion(step) }
        }.resume()
    }

    private static func moveDownloaded(tmp: URL?, response: URLResponse?, error: Error?, toPath path: String) -> NetStep<Int64> {
        if let error = error { return .failed("下载失败：\(error.localizedDescription)") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let tmp = tmp, (200..<300).contains(status) else { return .failed("下载 HTTP \(status)") }
        let fm = FileManager.default
        let dst = URL(fileURLWithPath: path)
        do {
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: tmp, to: dst)
        } catch {
            // 极端情况（跨容器）：退回拷贝
            do {
                try fm.copyItem(at: tmp, to: dst)
                try? fm.removeItem(at: tmp)
            } catch {
                return .failed("临时文件落地失败：\(error.localizedDescription)")
            }
        }
        let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        return .ok(size)
    }

    // MARK: - manifest 合法性 / 工具

    /// manifest 基本合法性：
    /// - schema 2：每个分片都要有 file / 合法 min_date、max_date / 64 位 sha256；
    /// - schema 1：rows.daily > 0、max_date 合法、symbols > 0、sha256 为 64 位十六进制。
    private static func validate(_ m: TdxLiveManifest) -> String? {
        if m.isSharded {
            guard let buckets = m.buckets, !buckets.isEmpty else { return "schema2 manifest 无分片" }
            for b in buckets {
                if b.file.isEmpty { return "分片缺 file 字段" }
                guard let minDate = b.min_date, isValidDate8(minDate) else { return "分片 \(b.id) min_date 非法" }
                guard let maxDate = b.max_date, isValidDate8(maxDate) else { return "分片 \(b.id) max_date 非法" }
                guard minDate <= maxDate else { return "分片 \(b.id) 日期区间倒置" }
                guard let sha = b.sha256, sha.count == 64 else { return "分片 \(b.id) sha256 缺失或长度非法" }
            }
            return nil
        }
        if (m.rows?["daily"] ?? 0) <= 0 { return "manifest 日线行数为 0" }
        guard let maxDate = m.max_date, isValidDate8(maxDate) else { return "manifest max_date 非法" }
        if (m.symbols ?? 0) <= 0 { return "manifest 标的数为 0" }
        guard let sha = m.sha256, sha.count == 64 else { return "manifest sha256 缺失或长度非法" }
        return nil
    }

    /// 分片临时文件校验：sha256 与 manifest 该片声明一致（不一致一律丢弃，绝不合并半成品）
    private static func verifyBucket(tmpPath: String, bucket: TdxLiveBucket) -> NetStep<Void> {
        guard let expected = bucket.sha256?.lowercased() else { return .failed("manifest 该片缺少 sha256") }
        guard let actual = sha256Hex(ofFile: tmpPath) else { return .failed("分片文件读取失败") }
        guard actual == expected else {
            return .failed("哈希不符（期望 \(expected.prefix(8))… 实际 \(actual.prefix(8))…）")
        }
        return .ok(())
    }

    /// 补丁包临时文件校验：sha256 与 manifest 该补丁声明一致（不一致一律丢弃，绝不合并半成品）
    private static func verifyPatch(tmpPath: String, patch: TdxLiveBucket) -> NetStep<Void> {
        guard let expected = patch.sha256?.lowercased(), !expected.isEmpty else {
            return .failed("manifest 该补丁缺少 sha256")
        }
        guard let actual = sha256Hex(ofFile: tmpPath) else { return .failed("补丁文件读取失败") }
        guard actual == expected else {
            return .failed("哈希不符（期望 \(expected.prefix(8))… 实际 \(actual.prefix(8))…）")
        }
        return .ok(())
    }

    // MARK: - 按缺口取片

    /// 主库 `metaList` 中 `lastDate` 的最大值（0 = 全部缺失）；**须在主线程调用**
    static func mainLatestTradeDate() -> Int {
        DatabaseManager.shared.metaList.compactMap { $0.lastDate }.max() ?? 0
    }

    /// 今天（设备本地日期，YYYYMMDD）
    static func todayYMD() -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return Int(f.string(from: Date())) ?? 0
    }

    /// 距今天然天数（date8 为 0 / 非法 → 0）
    static func naturalDaysSince(_ date8: Int) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        guard date8 > 0, let date = f.date(from: String(date8)) else { return 0 }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
    }

    /// 单次同步最多下载的分片数 = 生成端保留窗口上限（30 片 ≈ 6 周）
    static let maxBucketSelection = 30

    /// 补丁包（历史重灌包）的独立上限：仅用于限制设备侧「已合并记录」的条数，
    /// 避免 UserDefaults 无限增长。**与分片 30 片滚动完全独立、互不影响**；
    /// 补丁文件下载后合并即删（与分片同样），故无需按数量滚动保留文件。
    static let maxMergedPatchRecords = 10

    /// 选出与 `[needFrom, needTo]` 相交的分片：按 id 从新到旧，上限 limit 片
    static func selectBuckets(_ buckets: [TdxLiveBucket], needFrom: Int, needTo: Int, limit: Int) -> [TdxLiveBucket] {
        guard needFrom > 0, needTo >= needFrom else { return [] }
        return Array(buckets
            .filter { ($0.min_date ?? 0) <= needTo && ($0.max_date ?? 0) >= needFrom }
            .sorted { $0.id > $1.id }
            .prefix(Swift.max(0, limit)))
    }

    /// YYYYMMDD 合法性（年份 1990~2100，且当月确实存在该日）
    static func isValidDate8(_ value: Int) -> Bool {
        let s = String(value)
        guard s.count == 8 else { return false }
        let y = Int(s.prefix(4)) ?? 0
        let mo = Int(s.dropFirst(4).prefix(2)) ?? 0
        let da = Int(s.dropFirst(6).prefix(2)) ?? 0
        guard (1990...2100).contains(y), (1...12).contains(mo), (1...31).contains(da) else { return false }
        let cal = Calendar(identifier: .gregorian)
        guard let first = cal.date(from: DateComponents(year: y, month: mo, day: 1)),
              let range = cal.range(of: .day, in: .month, for: first) else { return false }
        return range.contains(da)
    }

    /// 文件 sha256（mmap 读取，避免整文件进内存；用独立函数保证 Data 在文件搬运前已释放）
    private static func sha256Hex(ofFile path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 本地已记录内容

    private var recordedVersion: Int? {
        UserDefaults.standard.object(forKey: Self.lastVersionKey) == nil
            ? nil : UserDefaults.standard.integer(forKey: Self.lastVersionKey)
    }

    private var recordedSha: String? {
        UserDefaults.standard.string(forKey: Self.lastShaKey)
    }

    /// 已合并补丁包的幂等记录（UserDefaults 持久化）。
    /// 写入时截断到最近 `maxMergedPatchRecords` 条——这是补丁包**独立**于分片 30 片滚动的清理策略。
    private var mergedPatchRecords: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.mergedPatchesKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(Self.maxMergedPatchRecords)),
                                       forKey: Self.mergedPatchesKey) }
    }

    /// 补丁包幂等键：sha256 优先（可识别「同文件名不同内容」），无 sha 时退化为文件名
    private static func patchKey(_ patch: TdxLiveBucket) -> String {
        if let sha = patch.sha256?.lowercased(), !sha.isEmpty { return sha }
        return patch.file
    }

    // MARK: - 时刻 / 交易日工具

    /// "HH:mm" → 当天分钟数
    static func minutes(of time: String) -> Int? {
        let segs = time.split(separator: ":")
        guard segs.count == 2, let h = Int(segs[0]), let m = Int(segs[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    static func minutesOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    static func slotText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// 交易日 = 周一至周五（不含法定节假日判断）
    static func isTradingDay(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)   // 1=周日 … 7=周六
        return weekday >= 2 && weekday <= 6
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    /// 下一个计划时刻文案："今日 14:30" / "明日 11:00" / "周三 11:00"
    static func nextSlotDescription(for times: [String], now: Date, tradingDaysOnly: Bool) -> String? {
        let slots = times.compactMap { t -> (String, Int)? in
            guard let m = minutes(of: t) else { return nil }
            return (t, m)
        }.sorted { $0.1 < $1.1 }
        guard !slots.isEmpty else { return nil }

        let cal = Calendar.current
        let nowMinutes = minutesOfDay(now)
        for offset in 0...7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { break }
            if tradingDaysOnly, !isTradingDay(day) { continue }
            let prefix = cal.isDate(day, inSameDayAs: now) ? "今日" : dayLabel(day, now: now)
            for (text, m) in slots where offset > 0 || m > nowMinutes {
                return prefix + " " + text
            }
        }
        return nil
    }

    private static func dayLabel(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           cal.isDate(date, inSameDayAs: tomorrow) { return "明日" }
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let weekday = cal.component(.weekday, from: date)
        return names[Swift.max(0, Swift.min(6, weekday - 1))]
    }
}
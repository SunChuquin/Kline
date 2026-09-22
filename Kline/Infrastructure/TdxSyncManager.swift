//
//  TdxSyncManager.swift
//  Kline
//
//  增量行情库（Documents/tdx_live.db）自动拉取：
//    manifest 比对 → 多源回退下载 → sha256 + manifest 合法性校验 → 原子替换 → LiveDataStore 热刷新。
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

/// data 分支上的 `tdx_live.manifest.json`
struct TdxLiveManifest: Codable {
    /// 每次生成自增的版本号
    var version: Int
    var generated_at: Int?
    /// 行情的真实交易日（YYYYMMDD）
    var trade_date: Int?
    var source: String?
    /// 覆盖标的数
    var symbols: Int?
    var min_date: Int?
    var max_date: Int?
    /// 各表行数：daily / weekly / monthly / quarterly / yearly
    var rows: [String: Int]?
    /// `tdx_live.db` 的 sha256（十六进制小写）
    var sha256: String?
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

    /// 是否已启用（透传配置）
    var isEnabled: Bool { config.enabled }

    // MARK: - 本地记录键（UserDefaults：内容相同则跳过的依据 + 状态回显）

    private static let lastVersionKey = "kline.tdxsync.lastVersion"
    private static let lastShaKey = "kline.tdxsync.lastSha"
    private static let lastTradeDateKey = "kline.tdxsync.lastTradeDate"
    private static let lastSyncAtKey = "kline.tdxsync.lastSyncAt"
    private static let lastSourceKey = "kline.tdxsync.lastSource"

    // MARK: - 本地文件路径

    /// 增量库（与 LiveDataStore 监视的路径一致）
    static var dbPath: String { LiveDataStore.writableDBPath }
    /// 下载落地的临时文件（校验通过前绝不覆盖正式文件）
    static var tmpPath: String {
        documentsPath + "/tdx_live.db.tmp"
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
        // 只取「已到点」中最晚的一个：避免冷启动时把 11:00 / 14:30 / 15:05 三个都跑一遍
        let passed = config.scheduleTimes.compactMap { Self.minutes(of: $0) }.filter { $0 <= nowMinutes }
        guard let slot = passed.max() else { return }
        let slotKey = dayKey + " " + String(slot)
        guard !ranSlots.contains(slotKey) else { return }
        ranSlots.insert(slotKey)
        DebugLogger.shared.log("[TdxSync] \(trigger)：已到点 \(Self.slotText(slot))，触发同步")
        beginSync(reason: trigger)
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
        DebugLogger.shared.log("[TdxSync] 开始同步（\(reason)）源数=\(config.sourceURLs.count)")
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
        DebugLogger.shared.log("[TdxSync] 源\(index + 1) 取 manifest \(urls.manifest.absoluteString)")

        fetchManifest(url: urls.manifest) { [weak self] step in
            guard let self = self else { return }
            switch step {
            case .failed(let err):
                DebugLogger.shared.log("[TdxSync] 源\(index + 1) manifest 失败：\(err)")
                self.trySource(index: index + 1, reason: reason, errors: errors + ["源\(index + 1) \(err)"])
            case .ok(let manifest):
                if let bad = Self.validate(manifest) {
                    DebugLogger.shared.log("[TdxSync] 源\(index + 1) manifest 非法：\(bad)")
                    self.trySource(index: index + 1, reason: reason, errors: errors + ["源\(index + 1) \(bad)"])
                    return
                }
                // 内容相同 → 跳过下载（省流量）
                if manifest.version == self.recordedVersion,
                   let sha = manifest.sha256, sha == self.recordedSha {
                    DebugLogger.shared.log("[TdxSync] 源\(index + 1) 版本 v\(manifest.version) 与本地一致 → 跳过下载")
                    self.finishSuccess(manifest: manifest, source: raw, installed: false)
                    return
                }
                self.downloadDB(urls: urls, manifest: manifest, index: index, reason: reason, errors: errors)
            }
        }
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
                            self.finishSuccess(manifest: manifest, source: urls.source, installed: true)
                        case .failed(let err):
                            DebugLogger.shared.log("[TdxSync] 源\(index + 1) 校验/替换失败：\(err)")
                            self.trySource(index: index + 1, reason: reason, errors: errors + ["源\(index + 1) \(err)"])
                        }
                    }
                }
            }
        }
    }

    /// 成功收尾（主线程）：记录版本/哈希/时间/源，热刷新增量库
    private func finishSuccess(manifest: TdxLiveManifest, source: String, installed: Bool) {
        let now = Date()
        let d = UserDefaults.standard
        d.set(manifest.version, forKey: Self.lastVersionKey)
        if let sha = manifest.sha256 { d.set(sha, forKey: Self.lastShaKey) }
        if let td = manifest.trade_date, td > 0 { d.set(td, forKey: Self.lastTradeDateKey) }
        d.set(now.timeIntervalSince1970, forKey: Self.lastSyncAtKey)
        d.set(source, forKey: Self.lastSourceKey)

        if lastVersion != manifest.version { lastVersion = manifest.version }
        if let td = manifest.trade_date, lastTradeDate != td { lastTradeDate = td }
        if lastSyncAt != now { lastSyncAt = now }
        if lastSource != source { lastSource = source }
        setError(nil)
        if isSyncing { isSyncing = false }

        DebugLogger.shared.log("[TdxSync] 同步成功 v\(manifest.version) trade=\(manifest.trade_date.map(String.init) ?? "-") 覆盖=\(manifest.symbols.map(String.init) ?? "-")只 源=\(source) 实际写入=\(installed)")

        // 关键链路：文件确实被替换后立即热刷新（无需重启、无需等 5 分钟指纹检查）
        guard installed else { return }
        LiveDataStore.shared.reloadAsync(completion: { summary in
            DebugLogger.shared.log("[TdxSync] 热刷新完成 可用=\(summary.isAvailable) 覆盖=\(summary.metaCountAfter)只 最新=\(summary.latestDateAfter) 内容变化=\(summary.contentChanged)")
        })
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

    /// manifest 基本合法性：rows.daily > 0、max_date 为 8 位合法日期、symbols > 0、sha256 为 64 位十六进制
    private static func validate(_ m: TdxLiveManifest) -> String? {
        if (m.rows?["daily"] ?? 0) <= 0 { return "manifest 日线行数为 0" }
        guard let maxDate = m.max_date, isValidDate8(maxDate) else { return "manifest max_date 非法" }
        if (m.symbols ?? 0) <= 0 { return "manifest 标的数为 0" }
        guard let sha = m.sha256, sha.count == 64 else { return "manifest sha256 缺失或长度非法" }
        return nil
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
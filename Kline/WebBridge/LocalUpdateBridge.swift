//
//  LocalUpdateBridge.swift
//  Kline
//
//  本地更新桥（协议 v2 update.*）：P2-6c-1 LocalUpdateView Web 化的 Swift 侧。
//  原生视图为个人中心内嵌卡片组，Web 化后提取为全屏页（入口行 profile.localUpdate.entry）。
//
//  状态留原生：GitHubUpdateService（App 行）/ PythonEngineHost（引擎行）/ KlineHTTPServer
//  （在线服务）/ WatchlistSyncManager（清单自动更新）/ GapBackfill（补缺口）；
//  远程更新状态机（RemoteState 六态）从视图迁入本桥持有，Web 经快照消费。
//
//  与原生视图行为对齐：
//   - onOpen（对齐 onAppear）：探测服务 + App/引擎行非 busy 即自动检查一次
//   - 回前台（didBecomeActive）重新探测服务（对齐 scenePhase onChange）
//   - installApp：先归档现有 IPA（保留最新 10 个）→ 下载（官方 sha256 校验）→
//     申请 30s 后台执行时间 → 本地 HTTP + apple-magnifier URL 拉起 TrollStore
//   - installEngine：下载进度采样自 PythonEngineHost.downloadProgress（0.25s Timer）
//   - queryBaselineMissing：异步查询，结果进快照，reason=baselineReady 通知 Web 弹名单
//
//  线程约定：动作入口均在主线程；服务/下载回调已由原生服务切主线程。
//

import Combine
import Foundation
import UIKit

@MainActor
final class LocalUpdateBridge: ObservableObject {

    static let shared = LocalUpdateBridge()

    /// 归档保留数量（对齐原生 LocalUpdateView.archiveKeepCount）
    private static let archiveKeepCount = 10

    /// 远程更新状态（对齐原生 RemoteState；nonisolated 纯值枚举）
    nonisolated enum RemoteState {
        case idle          // 未检查
        case checking      // 检查中
        case latest        // 已是最新
        case outdated      // 有新版（点击 = 下载并安装）
        case downloading   // 下载中
        case failed        // 检查/下载失败（点击 = 重试）
    }

    // MARK: - 在线服务

    @Published private(set) var serverOK = false
    @Published private(set) var serverProbing = false

    // MARK: - App 行（检查新版）

    @Published private(set) var remoteState: RemoteState = .idle
    @Published private(set) var remoteBuildNumber: Int? = nil
    private var remoteIPASHA256: String? = nil
    @Published private(set) var downloadPercent = 0

    // MARK: - 引擎行（更新引擎）

    @Published private(set) var engineState: RemoteState = .idle
    @Published private(set) var engineRemoteBuildNumber: Int? = nil
    private var engineTipaSHA256: String? = nil
    @Published private(set) var engineDownloadPercent = 0

    // MARK: - 基准缺失名单（查询结果，Web 弹层消费）

    private var baselineMainLatest = 0
    private var baselineItems: [GapBaselineMissingItem] = []
    @Published private(set) var baselineLoading = false

    private var cancellables = Set<AnyCancellable>()
    private var changedItem: DispatchWorkItem? = nil
    private var pendingReason = "data"
    /// 外部 Store 变化节流窗口
    private let changedThrottle: TimeInterval = 0.5

    private init() {
        // 外部 Store 变化 → update.changed 节流推送
        WatchlistSyncManager.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged("watchlist") }
            .store(in: &cancellables)
        GapBackfill.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged("gap") }
            .store(in: &cancellables)
        TdxSyncConfig.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged("config") }
            .store(in: &cancellables)
        DatabaseManager.shared.$isLoaded
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleChanged("data") }
            .store(in: &cancellables)
        // 回前台重新探测（对齐原生 scenePhase == .active）
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshServerStatus() }
            .store(in: &cancellables)
    }

    // MARK: - 生命周期

    /// 页面打开（对齐原生 onAppear）：探测服务 + 非检查/下载中即自动检查一次
    func onOpen() {
        refreshServerStatus()
        if !remoteBusy { checkGitHubUpdate() }
        if !engineBusy { checkEngineUpdate() }
    }

    // MARK: - busy 判定

    var remoteBusy: Bool {
        switch remoteState {
        case .checking, .downloading: return true
        default: return false
        }
    }

    var engineBusy: Bool {
        switch engineState {
        case .checking, .downloading: return true
        default: return false
        }
    }

    // MARK: - 变化信号 → update.changed 推送

    private func scheduleChanged(_ reason: String) {
        pendingReason = reason
        guard changedItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.changedItem = nil
            WebMessageRouter.shared.pushEvent("update.changed",
                                              payload: ["reason": self.pendingReason],
                                              route: "page")
        }
        changedItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + changedThrottle, execute: item)
    }

    /// 内部状态变化即时推送（不经节流）
    private func notifyChangedNow(_ reason: String) {
        changedItem?.cancel()
        changedItem = nil
        WebMessageRouter.shared.pushEvent("update.changed", payload: ["reason": reason], route: "page")
    }

    /// 带消息的即时推送（基准缺失查询失败等）
    private func pushAlert(_ reason: String, _ message: String) {
        WebMessageRouter.shared.pushEvent("update.changed",
                                          payload: ["reason": reason, "message": message],
                                          route: "page")
    }

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "snapshot":
            return WebBridgeResponse.ok(request.id, data: snapshotData())
        case "probeServer":
            shared.refreshServerStatus()
            return WebBridgeResponse.ok(request.id)
        case "reconnectServer":
            shared.reconnectServer()
            return WebBridgeResponse.ok(request.id)
        case "checkApp":
            shared.checkGitHubUpdate()
            return WebBridgeResponse.ok(request.id)
        case "installApp":
            shared.downloadAndInstallLatest()
            return WebBridgeResponse.ok(request.id)
        case "checkEngine":
            shared.checkEngineUpdate()
            return WebBridgeResponse.ok(request.id)
        case "installEngine":
            shared.downloadAndInstallEngine()
            return WebBridgeResponse.ok(request.id)
        case "syncNow":
            WatchlistSyncManager.shared.sync(reason: "手动")
            DebugLogger.shared.log("[LocalUpdateBridge] syncNow")
            return WebBridgeResponse.ok(request.id)
        case "runGapBackfill":
            GapBackfill.shared.run()
            return WebBridgeResponse.ok(request.id)
        case "queryBaselineMissing":
            shared.loadBaselineMissing()
            return WebBridgeResponse.ok(request.id, data: ["queued": true])
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "update.\(request.action) 未实现")
        }
    }

    // MARK: - 在线服务（自动探测；离线点击重连）

    private func refreshServerStatus() {
        guard !serverProbing else { return }
        serverProbing = true
        notifyChangedNow("server")
        KlineHTTPServer.shared.probe { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                self.serverOK = ok
                self.serverProbing = false
                self.notifyChangedNow("server")
            }
        }
    }

    private func reconnectServer() {
        serverProbing = true
        notifyChangedNow("server")
        // 旧监听失效后状态可能仍是 .ready，必须强制重建；随后复探确认结果
        KlineHTTPServer.shared.restart()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            KlineHTTPServer.shared.probe { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.serverOK = ok
                    self.serverProbing = false
                    self.notifyChangedNow("server")
                }
            }
        }
    }

    // MARK: - 检查新版（App 行）

    private func checkGitHubUpdate() {
        guard !remoteBusy else { return }
        remoteState = .checking
        notifyChangedNow("remote")
        GitHubUpdateService.fetchLatestRelease { [weak self] info, err in
            DispatchQueue.main.async {
                guard let self else { return }
                if let err = err {
                    self.remoteState = .failed
                    self.notifyChangedNow("remote")
                    DebugLogger.shared.log("检查新版失败：\(err)")
                    return
                }
                let cur = GitHubUpdateService.currentBuildNumber
                self.remoteBuildNumber = info?.buildNumber
                self.remoteIPASHA256 = info?.ipaSHA256
                if let n = info?.buildNumber, let c = cur, n > c {
                    self.remoteState = .outdated
                } else {
                    self.remoteState = .latest
                }
                self.notifyChangedNow("remote")
            }
        }
    }

    private func downloadAndInstallLatest() {
        guard !remoteBusy else { return }
        // 先把现有 Kline.ipa 归档为 Kline_<当前构建号>.ipa（可回退手动安装）
        archiveCurrentIPA()
        downloadPercent = 0
        remoteState = .downloading
        notifyChangedNow("remote")
        GitHubUpdateService.downloadLatestIPA(expectedSHA256: remoteIPASHA256, progress: { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                self.downloadPercent = min(100, max(0, Int((p * 100).rounded())))
                self.notifyChangedNow("remote")
            }
        }, completion: { [weak self] _, err in
            DispatchQueue.main.async {
                guard let self else { return }
                if let err = err {
                    self.remoteState = .failed
                    self.notifyChangedNow("remote")
                    DebugLogger.shared.log("下载最新 IPA 失败：\(err)")
                    return
                }
                // 与 /install-local(scope=sandbox) 同一条链路：沙盒 IPA + opener 守护 → 装完自动打开
                KlineHTTPServer.shared.start()
                let dlURL = "http://127.0.0.1:\(KlineHTTPServer.shared.port)/sandbox/Downloads/Kline.ipa"
                let trollURL = "apple-magnifier://install?url=\(dlURL.percentEncodedForQuery)"
                self.keepServingIPAForInstall()
                KlineHTTPServer.shared.triggerTrollStoreInstall(trollURL: trollURL)
                self.remoteState = .latest
                self.notifyChangedNow("remote")
                DebugLogger.shared.log("已下载最新 IPA，已拉起 TrollStore 安装")
            }
        })
    }

    // MARK: - 更新引擎（引擎行）

    private func checkEngineUpdate() {
        guard !engineBusy else { return }
        engineState = .checking
        notifyChangedNow("engine")
        GitHubUpdateService.fetchEngineRelease { [weak self] info, err in
            DispatchQueue.main.async {
                guard let self else { return }
                if let err = err {
                    self.engineState = .failed
                    self.notifyChangedNow("engine")
                    DebugLogger.shared.log("检查引擎更新失败：\(err)")
                    return
                }
                guard let n = info?.buildNumber else {
                    // Release 说明无「构建：run #N」可解析 → 按失败处理（可点重试）
                    self.engineState = .failed
                    self.notifyChangedNow("engine")
                    DebugLogger.shared.log("引擎 Release 构建号解析失败（notes 缺 run #N）")
                    return
                }
                self.engineRemoteBuildNumber = n
                self.engineTipaSHA256 = info?.ipaSHA256
                let cur = PythonEngineHost.shared.installedEngineBuildNumber
                if let c = cur, n <= c {
                    self.engineState = .latest
                } else {
                    self.engineState = .outdated
                }
                self.notifyChangedNow("engine")
            }
        }
    }

    private func downloadAndInstallEngine() {
        guard !engineBusy else { return }
        engineDownloadPercent = 0
        engineState = .downloading
        notifyChangedNow("engine")
        // 进度采样：PythonEngineHost.downloadTipa 内部维护 downloadProgress（主线程 0~1）
        let poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            DispatchQueue.main.async {
                guard let self else { t.invalidate(); return }
                self.engineDownloadPercent = min(100, max(0,
                    Int((PythonEngineHost.shared.downloadProgress * 100).rounded())))
                self.notifyChangedNow("engine")
                if self.engineState != .downloading { t.invalidate() }
            }
        }
        PythonEngineHost.shared.downloadTipa(from: GitHubUpdateService.engineTipaURL) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { poll.invalidate(); return }
                poll.invalidate()
                switch result {
                case .failure(let msg):
                    self.engineState = .failed
                    self.notifyChangedNow("engine")
                    DebugLogger.shared.log("下载引擎包失败：\(msg)")
                case .success(let path):
                    // Release digest 复核（与 sidecar 校验互为独立来源，双保险）
                    if let problem = GitHubUpdateService.integrityProblem(at: path, expectedSHA256: self.engineTipaSHA256) {
                        try? FileManager.default.removeItem(atPath: path)
                        self.engineState = .failed
                        self.notifyChangedNow("engine")
                        DebugLogger.shared.log("引擎包完整性校验失败：\(problem)")
                        return
                    }
                    PythonEngineHost.shared.installViaTrollStore()
                    self.engineState = .latest
                    self.notifyChangedNow("engine")
                    DebugLogger.shared.log("已下载引擎包并通过校验，已拉起 TrollStore 安装")
                }
            }
        }
    }

    // MARK: - 安装期间保持本地服务可服务（对齐原生）

    /// 拉起 TrollStore 前申请一段后台执行时间（30s）：App 切后台被挂起会让
    /// TrollStore 取 127.0.0.1 的 IPA 卡死。到期自动释放。
    private func keepServingIPAForInstall(seconds: Double = 30) {
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "kline-serve-ipa") {
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        DebugLogger.shared.log("已申请后台执行时间 \(Int(seconds))s，确保 TrollStore 能取到沙盒 IPA")
    }

    // MARK: - 上一版 IPA 归档与清理（对齐原生）

    /// 下载新版前把现有 Kline.ipa 改名为 Kline_<当前构建号>.ipa；只保留版本号最大的 N 个归档
    private func archiveCurrentIPA() {
        let fm = FileManager.default
        let current = GitHubUpdateService.targetIpaPath
        let dir = (current as NSString).deletingLastPathComponent
        guard fm.fileExists(atPath: current) else { return }
        let build = GitHubUpdateService.currentBuildNumber.map(String.init) ?? "unknown"
        let archive = dir + "/Kline_\(build).ipa"
        if fm.fileExists(atPath: archive) { try? fm.removeItem(atPath: archive) }
        do {
            try fm.moveItem(atPath: current, toPath: archive)
            DebugLogger.shared.log("已归档上一版 IPA：Kline_\(build).ipa")
        } catch {
            DebugLogger.shared.log("归档上一版 IPA 失败：\(error)")
        }
        pruneArchives(in: dir, keeping: Self.archiveKeepCount)
    }

    private func pruneArchives(in dir: String, keeping limit: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        var archives: [(version: Int, name: String)] = []
        for name in names where name.hasPrefix("Kline_") && name.hasSuffix(".ipa") {
            if let v = Int(name.dropFirst("Kline_".count).dropLast(".ipa".count)) {
                archives.append((v, name))
            }
        }
        guard archives.count > limit else { return }
        archives.sort { $0.version > $1.version }
        for item in archives.dropFirst(limit) {
            try? fm.removeItem(atPath: dir + "/" + item.name)
            DebugLogger.shared.log("清理旧归档 IPA：\(item.name)")
        }
    }

    // MARK: - 基准缺失名单

    private func loadBaselineMissing() {
        guard !baselineLoading else { return }
        baselineLoading = true
        notifyChangedNow("gap")
        GapBackfill.shared.queryBaselineMissing { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.baselineLoading = false
                switch result {
                case .failure(let message):
                    self.pushAlert("baselineFailed", message)
                case .success(let outcome):
                    self.baselineMainLatest = outcome.mainLatest
                    self.baselineItems = outcome.items
                    self.notifyChangedNow("baselineReady")
                }
            }
        }
    }

    // MARK: - 快照组装（行标题/状态文案原生拼接）

    static func snapshotData() -> [String: Any] {
        let b = shared
        let watchlist = WatchlistSyncManager.shared
        let gap = GapBackfill.shared
        let syncConfig = TdxSyncConfig.shared
        let dbm = DatabaseManager.shared

        // App 行 / 引擎行（RemoteState → 协议六态字符串）
        let appRow: [String: Any] = [
            "state": b.stateKey(b.remoteState),
            "remoteBuild": b.remoteBuildNumber ?? NSNull(),
            "currentBuild": GitHubUpdateService.currentBuildNumber ?? NSNull(),
            "percent": b.downloadPercent,
            "title": b.remoteRowTitle,
        ]
        let engineRow: [String: Any] = [
            "state": b.stateKey(b.engineState),
            "remoteBuild": b.engineRemoteBuildNumber ?? NSNull(),
            "currentBuild": PythonEngineHost.shared.installedEngineBuildNumber ?? NSNull(),
            "percent": b.engineDownloadPercent,
            "title": b.engineRowTitle,
        ]
        let serverAny: [String: Any] = ["ok": b.serverOK, "probing": b.serverProbing]

        // 清单标的自动更新（状态机从视图迁入）
        let wState = b.watchlistState(watchlist, enabled: syncConfig.enabled)
        let slotsAny: [[String: Any]] = syncConfig.scheduleTimes.map { time in
            ["time": time,
             "title": "\(time) · \(slotSemantics(time))",
             "value": watchlist.slotResults[time] ?? "尚未执行"]
        }
        let watchlistAny: [String: Any] = [
            "enabled": syncConfig.enabled,
            "isRunning": watchlist.isRunning,
            "stateText": watchlistStateText(wState, watchlist),
            "stateTone": watchlistStateTone(wState),
            "lastResultText": watchlist.lastResultText ?? "—",
            "unionCount": watchlist.unionCount,
            "requestText": watchlistRequestText(watchlist),
            "lastTradeDate": watchlist.lastTradeDate.map(String.init) ?? "—",
            "slots": slotsAny,
            "note": scheduleSemanticsText(syncConfig),
        ]

        // 补缺口
        let gapAny: [String: Any] = [
            "statusText": gap.statusText,
            "coverageText": gap.coverageText,
            "baselineText": b.mainDBBaselineText(dbm),
            "baselineStale": b.mainDBBaselineStale(dbm),
            "fetchText": gap.fetchText,
            "verdictText": gap.verdictText,
            "isRunning": gap.isRunning,
            "baselineLoading": b.baselineLoading,
            "detailLines": gap.detailLines,
        ]

        // 基准缺失名单（查询成功后非空）
        var baselineAny: Any = NSNull()
        if b.baselineItems.isEmpty == false || b.baselineMainLatest > 0 {
            baselineAny = [
                "mainLatest": b.baselineMainLatest,
                "items": b.baselineItems.map {
                    ["name": $0.name, "code": $0.code, "file": $0.file, "cause": $0.cause]
                },
            ]
        }

        return [
            "server": serverAny,
            "app": appRow,
            "engine": engineRow,
            "watchlist": watchlistAny,
            "gap": gapAny,
            "baseline": baselineAny,
        ]
    }

    // MARK: 快照私有助手（从视图移植）

    private func stateKey(_ s: RemoteState) -> String {
        switch s {
        case .idle: return "idle"
        case .checking: return "checking"
        case .latest: return "latest"
        case .outdated: return "outdated"
        case .downloading: return "downloading"
        case .failed: return "failed"
        }
    }

    private var remoteRowTitle: String {
        let latest = remoteBuildNumber.map { "#\($0)" } ?? "#?"
        let current = GitHubUpdateService.currentBuildNumber.map { "#\($0)" } ?? "#?"
        return "检查新版（最新\(latest) 当前 \(current)）"
    }

    private var engineRowTitle: String {
        let latest = engineRemoteBuildNumber.map { "#\($0)" } ?? "#?"
        let current = PythonEngineHost.shared.installedEngineBuildNumber.map { "#\($0)" } ?? "#?"
        return "更新引擎（最新\(latest) 当前 \(current)）"
    }

    /// 清单自动更新状态机（对齐视图 watchlistState）
    private enum WatchlistState { case disabled, idle, syncing, synced, failed }

    private func watchlistState(_ w: WatchlistSyncManager, enabled: Bool) -> WatchlistState {
        if !enabled { return .disabled }
        if w.isRunning { return .syncing }
        guard let outcome = w.lastOutcome else { return .idle }
        switch outcome {
        case .failed: return .failed
        case .success: return .synced
        case .skipped: return .idle
        }
    }

    private static func watchlistStateText(_ state: WatchlistState, _ w: WatchlistSyncManager) -> String {
        let wasSkipped: Bool
        if case .skipped? = w.lastOutcome { wasSkipped = true } else { wasSkipped = false }
        switch state {
        case .disabled: return "未启用"
        case .idle: return wasSkipped ? "已跳过（见最近结果）" : "等待首次执行"
        case .syncing: return "同步中…"
        case .synced: return "已同步"
        case .failed: return "失败"
        }
    }

    private static func watchlistStateTone(_ state: WatchlistState) -> String {
        switch state {
        case .disabled, .idle: return "gray"
        case .syncing: return "yellow"
        case .synced: return "green"
        case .failed: return "red"
        }
    }

    /// 本次请求文案（尚未执行过 → —）
    private static func watchlistRequestText(_ w: WatchlistSyncManager) -> String {
        guard w.lastOutcome != nil else { return "—" }
        return "命中 \(w.hitCount) · 跳过 \(w.skippedCount) · 取数失败 \(w.batchFailureCount)"
    }

    /// 时刻语义（对齐视图 slotSemantics）
    private static func slotSemantics(_ time: String) -> String {
        if time == "17:30" { return "补缺口" }
        guard let minutes = TdxSyncManager.minutes(of: time) else { return "—" }
        return minutes < 15 * 60 ? "盘中快照" : "收盘"
    }

    /// 时刻表语义说明（跟随 scheduleTimes 动态生成）
    private static func scheduleSemanticsText(_ config: TdxSyncConfig) -> String {
        let gapfix = config.scheduleTimes.filter { $0 == "17:30" }
        let intraday = config.scheduleTimes.filter { slotSemantics($0) == "盘中快照" }
        let close = config.scheduleTimes.filter { slotSemantics($0) == "收盘" }
        var parts: [String] = []
        if !intraday.isEmpty {
            parts.append("\(intraday.joined(separator: " / ")) 为盘中快照（当日未完成K线）")
        }
        if !close.isEmpty {
            parts.append("\(close.joined(separator: " / ")) 为当日完整K线")
        }
        if !gapfix.isEmpty {
            parts.append("\(gapfix.joined(separator: " / ")) 为补缺口（自动合并入主库）")
        }
        return parts.isEmpty ? "未配置更新时刻" : parts.joined(separator: "；")
    }

    /// 主库基线（PC 生成全量 tdx.db 的近似日期）+ 距今天数；超 3 个月提示 PC 重新生成
    private func mainDBBaselineText(_ dbm: DatabaseManager) -> String {
        let d = dbm.mainDBBaselineDate
        guard d > 0 else { return "—" }
        let days = TdxSyncManager.naturalDaysSince(d)
        return "\(d)（\(days) 天）" + (days > 90 ? " · 超3个月，请PC重新生成" : "")
    }

    private func mainDBBaselineStale(_ dbm: DatabaseManager) -> Bool {
        let d = dbm.mainDBBaselineDate
        guard d > 0 else { return false }
        return TdxSyncManager.naturalDaysSince(d) > 90
    }
}

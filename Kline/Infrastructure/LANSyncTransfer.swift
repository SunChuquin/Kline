//
//  LANSyncTransfer.swift
//  Kline
//
//  局域网设备联机同步：客户端传输引擎（URLSession）——**仅拉取**模型。
//
//  主动触发方只能把对端内容拉到本机；代码层面不存在向对端写文件的路径
//  （无 PUT 上传、无对端 /sync/backup、无对端 DELETE 清理、无对端 reload 调用）。
//  run(selections:peer:remoteStatus:) 严格按序执行，任何一步失败即
//  phase = .failed(原因)，已完成的文件保留、不回滚：
//
//    1. 计算文件计划  源端 = 对端 /sync/status 清单快照（remoteStatus）。源端为空的
//                     类别跳过，结果里注明「对端无此内容」。整类模式 = 对端清单全量；
//                     子项模式 = 文件类按相对路径过滤、自选走分组合并路径。
//    2. 配对          POST /sync/request-pair（对端已开启「暴露」即自动授权）→
//                     会话 token；403 = 对端未暴露，无法获取其内容。
//    3. 覆盖前备份    本机将覆盖的文件/目录直接复制到 Documents/Backups/<yyyyMMdd-HHmmss>/
//                     （indicators 仅整类模式做两个根目录整份快照），保持相对结构，记录 backupDir。
//    4. 逐文件拉取    GET /sandbox/<rel> → 本地 <rel>.part（downloadTask 流式落盘）
//                     → 本文件 sha 与对端 GET /sync/sha 声明值比对（防传输损坏）
//                     → 相符后原子替换覆盖本地；失败重试 ≤2 次（指数退避 1s/2s），
//                     sha 失败删除 .part 保留本机原文件。
//                     indicators 整类模式拉完后整目录镜像：本机多余 *.tdx 直接删除；
//                     子项模式纯增改不删。
//                     自选子项模式例外：对端整份 favorites.json 下载到临时文件（下载+sha
//                     同流程，不覆盖本机）→ 按组名合并进本机 favorites.json（同名组替换但
//                     保留本机组 id、本机没有的组名原样新增、未选组/notes/selectedGroupID/
//                     schemaVersion 不动）→ 原子替换落盘。
//    5. 完成后生效    本机生效：needsConfigReload 类 → 主线程 LANSyncReload.apply(scopes:)；
//                     live → LiveDataStore.shared.notifyExternalWrite()；
//                     main → needsRestart = true 并发 lansyncMainDBReplaced 通知
//                     （主库整库替换沿用「启动时打开」语义）。
//    6. 汇总          resultSummary =「已拉取 N 个文件 / X MB；已备份本机原文件：…；…」，
//                     phase = .done。
//
//  限制：
//    - 两端 App 必须都在前台（KlineHTTPServer 仅前台可用），且对端须已打开「暴露」。
//    - 大文件全程流式：下载 downloadTask，sha256 用 FileHandle 每次读 1MB 喂
//      CryptoKit（禁止 readDataToEndOfFile）。
//    - 同步语义 = 文件级整份替换（无合并）；唯一例外是自选子项模式 = 分组合并（见上）；
//      indicators 整类模式为整目录镜像（多余 *.tdx 删除）。
//    - rel 路径拼 URL 逐段 percentEncode（中文指标名），"/" 不编码。
//    - 进度 / 速率经会话 delegate 回调采样（最近 ~1s 窗口），UI 更新统一切主线程。
//    - LANSyncSupport.buildSyncInventory() / LANSyncReload.apply(scopes:) /
//      Notification.Name.lansyncMainDBReplaced 由 LANSyncSupport.swift 提供。
//

import Foundation
import CryptoKit
import UIKit
import Combine

// MARK: - 同步失败原因

/// 同步失败的中文原因（phase = .failed(message) 直接展示）
private struct SyncError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - 细粒度选择模型

/// 单个类别的拉取选择：整类全量 或 子项集合（细粒度）。
/// childKeys 语义：文件类（layouts/indicators）= Documents 相对路径；
/// 自选（favorites）= 分组名；整类模式忽略。
struct LANSyncCategorySelection: Equatable {
    enum Mode: Equatable { case all, children }
    let category: LANSyncCategory
    let mode: Mode
    let childKeys: Set<String>
}

// MARK: - 传输引擎

final class LANSyncTransfer: NSObject, ObservableObject {

    // MARK: 对外状态（LANSyncView 绑定）

    enum Phase: Equatable { case idle, pairing, transferring, done, failed(String) }

    @Published var phase: Phase = .idle
    /// 总体进度 0...1（已拉取字节 / 计划总字节）
    @Published var progress: Double = 0
    /// 正在拉取的文件（Documents 相对路径）
    @Published var currentFile: String = ""
    /// 拉取速率（最近 ~1s 采样窗口），字节/秒
    @Published var bytesPerSecond: Int64 = 0
    /// 结果页文案（完成后汇总）
    @Published var resultSummary: String = ""
    /// 本次备份目录（相对 Documents；仅拉取模型 = 本机原文件的备份位置）
    @Published var backupDir: String?
    /// 主库被替换（本机视角），需重启 App 生效
    @Published var needsRestart = false

    // MARK: 内部状态

    private let fm = FileManager.default
    /// 沙盒 Documents 绝对路径
    private var docsPath: String {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }

    /// 每次传输独立创建，结束时 invalidate（session 强引用 delegate，需显式释放）
    private var session: URLSession?
    /// taskIdentifier → delegate 回调胶水（仅 delegate 型下载任务登记；
    /// JSON 任务走 completion handler，不经会话 delegate）
    private var boxes: [Int: TransferBox] = [:]
    private let boxesLock = NSLock()

    // 进度采样
    private var totalBytes: Int64 = 0      // 计划总字节（进度分母）
    private var transferred: Int64 = 0     // 已拉取字节
    private var samples: [(t: Date, bytes: Int64)] = []   // 速率采样窗口（最近 ~1s）

    // MARK: 文件计划（步骤 1 的内部结构）

    private struct PlanFile {
        let rel: String              // Documents 相对路径
        let size: Int64
        let category: LANSyncCategory
    }

    private struct PlanCategory {
        let category: LANSyncCategory
        let mode: LANSyncCategorySelection.Mode
        let files: [PlanFile]
        let skipped: Bool            // 对端无此内容
        /// 自选子项模式：选中的分组名（分组合并语义）；其余类别为空
        let favoriteGroupNames: Set<String>
    }

    // MARK: - 入口

    /// 异步执行一次拉取：把 peer 上选中类别的内容拉到本机（细粒度：每类别可选整类或子项集合）。
    /// remoteStatus 为连接对端时 /sync/status 返回的清单快照（计划的数据源）。
    func run(selections: [LANSyncCategorySelection],
             peer: LANSyncPeer,
             remoteStatus: LANSyncPeerStatus) async {
        // 可重入保护：配对中 / 传输中再次调用直接忽略（防双击）
        switch phase {
        case .pairing, .transferring: return
        default: break
        }
        // 复位本次会话状态（needsRestart 保留：主库替换过的重启提醒不因重新同步而消失）
        totalBytes = 0
        transferred = 0
        samples.removeAll()
        publishOnMain {
            // 立刻置忙，兼作重入锁（随后的计划计算是同步的，不会被打断）
            self.phase = .pairing
            self.progress = 0
            self.currentFile = ""
            self.bytesPerSecond = 0
            self.resultSummary = ""
            self.backupDir = nil
        }

        // 每次传输独立会话：单请求 60s（局域网足够），资源总超时 3600s（1.4GB 慢速 WiFi）。
        // ⚠️ 禁系统代理（同 LANSyncDiscovery.fetchStatus）：局域网对端不在代理例外名单，
        // 走代理必失败；1.4GB 主库更不能过代理。
        let cfg = URLSessionConfiguration.default
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        defer {
            s.finishTasksAndInvalidate()
            if session === s { session = nil }
            boxesLock.lock(); boxes.removeAll(); boxesLock.unlock()
        }

        do {
            // ---- 步骤 1：计算文件计划（源端 = 对端快照）----
            let plan = buildPlan(selections: selections, remoteStatus: remoteStatus)
            let plannedFiles = plan.flatMap(\.files)
            totalBytes = plannedFiles.reduce(0) { $0 + $1.size }
            DebugLogger.shared.log("LANSync 计划: 拉取 \(plannedFiles.count) 文件 / \(totalBytes) bytes ← \(peer.name)(\(peer.host):\(peer.port))")

            // 对端全部选中类别源端都为空 → 无事可做，不打扰对端，直接汇总收尾
            guard !plannedFiles.isEmpty else {
                finishDone(plan: plan, files: 0, outcome: TransferOutcome())
                return
            }

            // ---- 步骤 2：配对（phase 已是 .pairing；对端未暴露 → 403 失败）----
            let token = try await pair(peer: peer, categories: selections.map(\.category))
            DebugLogger.shared.log("LANSync 配对成功: \(peer.name)")

            // ---- 步骤 3：备份本机将被覆盖的原文件 ----
            if let backup = try backupLocally(plan: plan) {
                DebugLogger.shared.log("LANSync 备份本机原文件: \(backup)")
            }

            // ---- 步骤 4：逐文件拉取 ----
            publishOnMain { self.phase = .transferring }
            let outcome = try await transferFiles(plan: plan, peer: peer, token: token)

            // ---- 步骤 5：完成后本机生效 ----
            await applyEffects(plan: plan)

            // ---- 步骤 6：汇总 ----
            finishDone(plan: plan, files: plannedFiles.count, outcome: outcome)
        } catch {
            DebugLogger.shared.log("LANSync 失败: \(error)")
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            publishOnMain { self.phase = .failed(msg) }
        }
    }

    // MARK: - 步骤 1：计算文件计划

    /// 源端 = 对端 status 快照。对端清单里该类别 files 为空 → skipped = true
    /// （传输阶段跳过、结果注明）。
    /// 整类模式 = 对端清单全量（现行为）；子项模式：文件类按相对路径过滤，
    /// 自选走分组合并路径（计划里保留对端 favorites.json 整份条目，供下载+备份+进度统计）。
    private func buildPlan(selections: [LANSyncCategorySelection],
                           remoteStatus: LANSyncPeerStatus) -> [PlanCategory] {
        let sourceItems = remoteStatus.items
        return selections.map { sel in
            let remoteFiles = sourceItems.first { $0.key == sel.category.rawValue }?.files ?? []
            switch (sel.category, sel.mode) {
            case (.favorites, .children):
                // 自选子项模式：分组合并路径（对端整份 favorites.json 下载后按组名合并写回）
                let files = remoteFiles.map { PlanFile(rel: $0.path, size: $0.size, category: sel.category) }
                return PlanCategory(category: sel.category, mode: .children, files: files,
                                    skipped: files.isEmpty, favoriteGroupNames: sel.childKeys)
            case (.layouts, .children), (.indicators, .children):
                // 文件类子项模式：按子项 key（Documents 相对路径）过滤对端清单
                let files = remoteFiles.filter { sel.childKeys.contains($0.path) }
                    .map { PlanFile(rel: $0.path, size: $0.size, category: sel.category) }
                return PlanCategory(category: sel.category, mode: .children, files: files,
                                    skipped: files.isEmpty, favoriteGroupNames: [])
            default:
                // 整类模式（sim/live/main 无子项语义，任何模式都按整类处理）
                let files = remoteFiles.map { PlanFile(rel: $0.path, size: $0.size, category: sel.category) }
                return PlanCategory(category: sel.category, mode: .all, files: files,
                                    skipped: files.isEmpty, favoriteGroupNames: [])
            }
        }
    }

    // MARK: - 步骤 2：配对

    /// POST /sync/request-pair {"from":设备名,"items":[类别]}
    /// → 对端已暴露：200 {"token":"…"}；未暴露：403（暴露即授权，无逐次确认）。
    private func pair(peer: LANSyncPeer, categories: [LANSyncCategory]) async throws -> String {
        let req = try makeRequest(peer, method: "POST", path: "/sync/request-pair",
                                  jsonBody: ["from": UIDevice.current.name,
                                             "items": categories.map(\.rawValue)])
        let (data, resp) = try await send(req)
        switch resp.statusCode {
        case 200:
            struct PairResp: Decodable { let token: String }
            guard let token = (try? JSONDecoder().decode(PairResp.self, from: data))?.token, !token.isEmpty else {
                throw SyncError(message: "配对响应格式异常")
            }
            return token
        case 403:
            throw SyncError(message: "对端未开启暴露，无法获取其内容")
        default:
            throw SyncError(message: "配对失败 HTTP \(resp.statusCode)")
        }
    }

    // MARK: - 步骤 3：备份本机将被覆盖的原文件

    /// 本机备份：将覆盖的单文件逐个复制、指标目录整份快照到
    /// Documents/Backups/<yyyyMMdd-HHmmss>/，保持相对结构。
    /// 返回备份目录（相对 Documents）；没有会被覆盖的内容时返回 nil。
    private func backupLocally(plan: [PlanCategory]) throws -> String? {
        let docs = docsPath
        let files = plan.flatMap(\.files).filter { fm.fileExists(atPath: docs + "/" + $0.rel) }
        var mirrorRoots: [String] = []
        if let ind = plan.first(where: { $0.category == .indicators }),
           !ind.files.isEmpty, ind.mode == .all {
            // 整目录镜像（仅整类模式；子项模式纯增改不删，只备份实际覆盖的选中文件）：
            // 本机两个根目录整份快照（存在才备份）
            mirrorRoots = ["indicator", "formula"].filter { fm.fileExists(atPath: docs + "/" + $0) }
        }
        guard !files.isEmpty || !mirrorRoots.isEmpty else { return nil }   // 没有会被覆盖的内容

        let ts = Self.backupTimestamp()
        let root = docs + "/Backups/" + ts
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        for f in files {
            let dst = root + "/" + f.rel
            try fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try fm.copyItem(atPath: docs + "/" + f.rel, toPath: dst)
        }
        for d in mirrorRoots {
            try fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true)
            try fm.copyItem(atPath: docs + "/" + d, toPath: root + "/" + d)
        }
        let rel = "Backups/" + ts
        publishOnMain { self.backupDir = rel }
        return rel
    }

    // MARK: - 步骤 4：逐文件拉取

    /// 传输结果（结果汇总用）
    private struct TransferOutcome {
        var mirrorDeleted = 0              // indicators 整类镜像清理掉的多余文件数
        var favoritesNotes: [String] = []  // 自选分组合并结果注明（合并/新增/对端缺组）
    }

    /// 逐文件拉取 + favorites 分组合并 + indicators 整类镜像清理。
    private func transferFiles(plan: [PlanCategory],
                               peer: LANSyncPeer,
                               token: String) async throws -> TransferOutcome {
        var outcome = TransferOutcome()
        for cat in plan {
            guard !cat.files.isEmpty else { continue }   // 对端无此内容：已在结果注明
            // 自选子项模式：不走整文件覆盖，下载对端整份 favorites.json 后按组名合并写回
            if cat.category == .favorites && cat.mode == .children {
                outcome.favoritesNotes += try await mergeFavoriteGroups(peer: peer, token: token, cat: cat)
                continue
            }
            for file in cat.files {
                publishOnMain { self.currentFile = file.rel }
                try await pullFile(peer: peer, file: file, token: token)
            }
            // 整目录镜像清理仅在整类模式执行；子项模式纯增改不删
            if cat.category.isDirectoryMirror && cat.mode == .all {
                outcome.mirrorDeleted += try mirrorCleanup(cat: cat)
            }
        }
        return outcome
    }

    /// 拉取单文件：GET /sandbox/<rel> → 本地 <rel>.part → 与对端 /sync/sha 声明值比对
    /// → 相符后原子替换覆盖本地（备份已在步骤 3 完成）。
    /// 下载失败 / sha 不符都重试 ≤2 次（指数退避 1s / 2s）；sha 失败时 .part 已清理、
    /// 本机原文件保持不动。
    private func pullFile(peer: LANSyncPeer, file: PlanFile, token: String) async throws {
        let dstPath = docsPath + "/" + file.rel
        let partPath = dstPath + ".part"
        // 任何出口都清掉 .part（成功时已被 move 消费，removeItem 幂等）：失败保原文件
        defer { try? fm.removeItem(atPath: partPath) }
        try await withRetry(file.rel, "下载") {
            try? self.fm.removeItem(atPath: partPath)   // 上次尝试的残留
            // ① 下载到 <rel>.part（downloadTask 流式落盘，防内存暴涨）
            let req = try self.makeRequest(peer, method: "GET",
                                           path: "/sandbox/" + Self.encodePathSegments(file.rel),
                                           token: token)
            try await self.download(request: req, toPart: partPath)
            // ② 本文件 sha 与对端声明值比对（防传输损坏）
            let localSha = try Self.streamSHA256(path: partPath)
            let remoteSha = try await self.fetchPeerSHA(peer: peer, rel: file.rel, token: token)
            guard localSha == remoteSha else {
                throw SyncError(message: "sha256 校验不符：\(file.rel)（本地 \(localSha.prefix(8))… / 对端 \(remoteSha.prefix(8))…）")
            }
            // ③ 校验通过 → 原子替换覆盖本地
            try Self.atomicReplace(partPath: partPath, dstPath: dstPath)
        }
    }

    /// 对端计算源文件 sha：GET /sync/sha?path=<rel> → {"path":…,"sha256":"…"}
    /// （带会话 token：对端沙盒读门禁要求暴露态 / 流水线标识 / 有效 token 之一）
    private func fetchPeerSHA(peer: LANSyncPeer, rel: String, token: String) async throws -> String {
        let req = try makeRequest(peer, method: "GET", path: "/sync/sha", query: ["path": rel], token: token)
        let (data, resp) = try await send(req)
        guard (200..<300).contains(resp.statusCode) else {
            throw SyncError(message: "对端 sha 查询失败 HTTP \(resp.statusCode)：\(rel)")
        }
        struct ShaResp: Decodable { let sha256: String }
        guard let sha = (try? JSONDecoder().decode(ShaResp.self, from: data))?.sha256, sha.count == 64 else {
            throw SyncError(message: "对端 sha 响应格式异常：\(rel)")
        }
        return sha.lowercased()
    }

    /// indicators 整目录镜像清理（仅本机）：对端快照里没有、本机多余的 *.tdx 直接删除。
    private func mirrorCleanup(cat: PlanCategory) throws -> Int {
        let planned = Set(cat.files.map(\.rel))
        var deleted = 0
        for root in ["indicator", "formula"] {
            let rootPath = docsPath + "/" + root
            guard let en = fm.enumerator(atPath: rootPath) else { continue }
            for case let sub as String in en where sub.hasSuffix(".tdx") {
                let rel = root + "/" + sub
                guard !planned.contains(rel) else { continue }
                do {
                    try fm.removeItem(atPath: rootPath + "/" + sub)
                    deleted += 1
                } catch {
                    throw SyncError(message: "清理多余指标失败：\(rel)（\(error.localizedDescription)）")
                }
            }
        }
        if deleted > 0 {
            DebugLogger.shared.log("LANSync 镜像清理 \(deleted) 个多余 *.tdx")
        }
        return deleted
    }

    // MARK: - favorites 分组合并（自选子项模式）

    /// 自选分组合并结果
    private struct FavoritesMergeResult {
        var replacedGroups = 0            // 同名组被对端内容替换（保留本机组 id）
        var appendedGroups = 0            // 本机没有的组名，对端组原样新增
        var missingNames: [String] = []   // 对端清单里找不到的选中组名（跳过，不整体失败）
    }

    /// 自选子项模式（分组合并）：
    /// 1. 下载对端整份 favorites.json 到临时文件（复用 pullFile 的下载+sha+重试流程，不覆盖本机）
    /// 2. 按组名合并进本机 favorites.json（语义见 mergeFavoritesJSON），原子替换落盘
    /// 3. 完成后沿用现有 favorites reloadFromDisk 生效路径（applyEffects 按类别触发）
    /// 返回结果注明文案（合并/新增/对端缺组）。
    private func mergeFavoriteGroups(peer: LANSyncPeer, token: String, cat: PlanCategory) async throws -> [String] {
        guard let fav = cat.files.first else { return [] }
        publishOnMain { self.currentFile = fav.rel }
        let peerData = try await downloadPeerFavorites(peer: peer, rel: fav.rel, token: token)
        let localPath = docsPath + "/" + fav.rel
        let result = try Self.mergeFavoritesJSON(localPath: localPath,
                                                 peerData: peerData,
                                                 selectedNames: cat.favoriteGroupNames)
        var notes: [String] = []
        if result.replacedGroups > 0 || result.appendedGroups > 0 {
            var s = "自选合并 \(result.replacedGroups) 个分组"
            if result.appendedGroups > 0 { s += " / 新增 \(result.appendedGroups) 个分组" }
            notes.append(s)
        }
        if !result.missingNames.isEmpty {
            notes.append("对端无此自选分组：" + result.missingNames.joined(separator: "、"))
        }
        return notes
    }

    /// 下载对端 favorites.json 到临时文件并校验 sha（复用 pullFile 的下载+校验+重试流程；
    /// 落系统临时目录，绝不覆盖本机文件）。
    private func downloadPeerFavorites(peer: LANSyncPeer, rel: String, token: String) async throws -> Data {
        let tempPath = NSTemporaryDirectory() + "lansync-peer-favorites.json"
        defer { try? fm.removeItem(atPath: tempPath) }
        try await withRetry(rel, "下载") {
            try? self.fm.removeItem(atPath: tempPath)   // 上次尝试的残留
            let req = try self.makeRequest(peer, method: "GET",
                                           path: "/sandbox/" + Self.encodePathSegments(rel),
                                           token: token)
            try await self.download(request: req, toPart: tempPath)
            let localSha = try Self.streamSHA256(path: tempPath)
            let remoteSha = try await self.fetchPeerSHA(peer: peer, rel: rel, token: token)
            guard localSha == remoteSha else {
                throw SyncError(message: "sha256 校验不符：\(rel)（本地 \(localSha.prefix(8))… / 对端 \(remoteSha.prefix(8))…）")
            }
        }
        return try Data(contentsOf: URL(fileURLWithPath: tempPath))
    }

    /// 按组名把对端 groups 合入本机 favorites.json。用 JSONSerialization 直改根字典，
    /// 只动 "groups"，其余根字段（notes / selectedGroupID / schemaVersion / 全局固顶）原样保留：
    /// - 同名组 → 用对端组内容整体替换，但保留本机组 id（selectedGroupID 引用本地 id 不断链）
    /// - 本机没有的组名 → 对端组原样新增（含对端 id；UUID 冲突概率忽略）
    /// - 未选中的组一律不动
    /// - formulaID 原样带入：引用对端公式库条目 id，本机公式库可能没有该条目，
    ///   打开该分组刷新选股时结果自然为空（不报错、不断链）
    /// - 本机文件缺失 → 以对端根为底、groups 仅保留选中组（全新安装首次同步场景）
    /// - 本机文件存在但解析失败 → 抛错终止（不基于损坏档做合并；本机原文件已在步骤 3 备份）
    /// - 全部选中组在对端缺失 → 零改动、不写盘
    private static func mergeFavoritesJSON(localPath: String, peerData: Data,
                                           selectedNames: Set<String>) throws -> FavoritesMergeResult {
        guard let peerRoot = try JSONSerialization.jsonObject(with: peerData) as? [String: Any],
              let peerGroups = peerRoot["groups"] as? [[String: Any]] else {
            throw SyncError(message: "对端 favorites.json 解析失败，无法合并分组")
        }
        let localURL = URL(fileURLWithPath: localPath)
        var root: [String: Any]
        var localGroups: [[String: Any]] = []
        if let localRaw = try? Data(contentsOf: localURL),
           let parsed = try? JSONSerialization.jsonObject(with: localRaw) as? [String: Any] {
            root = parsed
            localGroups = parsed["groups"] as? [[String: Any]] ?? []
        } else if FileManager.default.fileExists(atPath: localPath) {
            // 本机档存在但解析失败：不基于损坏档合并（原文件已在步骤 3 备份，可人工恢复）
            throw SyncError(message: "本机 favorites.json 解析失败，无法合并分组")
        } else {
            // 本机没有 favorites.json：以对端根为底（无本机内容可保留）
            root = peerRoot
        }
        var result = FavoritesMergeResult()
        for name in selectedNames.sorted() {   // 排序保证合并顺序确定
            guard let peerGroup = peerGroups.first(where: { ($0["name"] as? String) == name }) else {
                result.missingNames.append(name)
                continue
            }
            if let idx = localGroups.firstIndex(where: { ($0["name"] as? String) == name }) {
                var g = peerGroup
                g["id"] = localGroups[idx]["id"]   // 保留本机组 id：selectedGroupID 引用不断链
                localGroups[idx] = g
                result.replacedGroups += 1
            } else {
                localGroups.append(peerGroup)      // 本机没有的组名：对端组原样新增
                result.appendedGroups += 1
            }
        }
        guard result.replacedGroups > 0 || result.appendedGroups > 0 else { return result }
        root["groups"] = localGroups
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: localURL, options: .atomic)
        return result
    }

    // MARK: - 步骤 5：完成后生效（本机）

    /// 只对实际拉取了文件的类别生效（与 KlineHTTPServer 各 reload 分支同语义）。
    private func applyEffects(plan: [PlanCategory]) async {
        let cats = plan.filter { !$0.files.isEmpty }.map(\.category)
        guard !cats.isEmpty else { return }

        let configScopes = cats.filter(\.needsConfigReload)
        if !configScopes.isEmpty {
            // apply(scopes:) 签名以 LANSyncSupport.swift 为准（[String]，取 rawValue）
            await MainActor.run { LANSyncReload.apply(scopes: configScopes.map(\.rawValue)) }
        }
        if cats.contains(.live) {
            await MainActor.run { LiveDataStore.shared.notifyExternalWrite() }
        }
        if cats.contains(.main) {
            publishOnMain {
                self.needsRestart = true
                NotificationCenter.default.post(name: .lansyncMainDBReplaced, object: nil)
            }
        }
    }

    // MARK: - 步骤 6：汇总

    private func finishDone(plan: [PlanCategory], files: Int, outcome: TransferOutcome) {
        var parts: [String] = []
        if files > 0 {
            let mb = Double(transferred) / 1_048_576
            parts.append("已拉取 \(files) 个文件 / \(String(format: "%.1f", mb)) MB")
        } else {
            parts.append("对端没有可拉取的内容")
        }
        parts += outcome.favoritesNotes
        if let b = backupDir {
            parts.append("已备份本机原文件：\(b)")
        }
        if outcome.mirrorDeleted > 0 { parts.append("镜像清理多余指标 \(outcome.mirrorDeleted) 个") }
        let skipped = plan.filter(\.skipped).map { $0.category.title }
        if !skipped.isEmpty { parts.append("对端无此内容：" + skipped.joined(separator: "、")) }
        let cats = plan.filter { !$0.files.isEmpty }.map(\.category)
        if cats.contains(.live) { parts.append("增量库已热重载") }
        if cats.contains(.main) { parts.append("主库需重启 App 生效") }
        let summary = parts.joined(separator: "；")
        publishOnMain {
            self.resultSummary = summary
            self.phase = .done
        }
    }

    // MARK: - HTTP 基础设施

    /// 构造请求（path 里可含经 encodePathSegments 编码的相对路径部分）
    private func makeRequest(_ peer: LANSyncPeer,
                             method: String,
                             path: String,
                             query: [String: String] = [:],
                             token: String? = nil,
                             jsonBody: [String: Any]? = nil) throws -> URLRequest {
        guard let url = Self.makeURL(peer, path: path, query: query) else {
            throw SyncError(message: "URL 构造失败：\(peer.host):\(peer.port)\(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let token = token { req.setValue(token, forHTTPHeaderField: "X-Kline-Pair") }
        if let body = jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// 拼接 http://host:port<path>?<query>；path 段已在外部逐段 percent 编码，
    /// query 值交由 URLComponents 按 RFC 3986 编码（服务端 queryParam 会做 removingPercentEncoding）。
    private static func makeURL(_ peer: LANSyncPeer, path: String, query: [String: String]) -> URL? {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = peer.host
        comps.port = Int(peer.port)
        comps.percentEncodedPath = path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return comps.url
    }

    /// rel 路径逐段 percentEncode（RFC 3986 unreserved：字母数字 + -._~，中文文件名安全），
    /// "/" 不编码。服务端入口统一 removingPercentEncoding 解码。
    private static func encodePathSegments(_ rel: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return rel.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    /// 小型 JSON 请求（completion handler，不经会话 delegate，不参与进度统计）
    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let session = session else { throw SyncError(message: "会话已结束") }
        return try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: req) { data, resp, error in
                if let error = error {
                    cont.resume(throwing: SyncError(message: "网络错误：\(error.localizedDescription)"))
                    return
                }
                guard let http = resp as? HTTPURLResponse else {
                    cont.resume(throwing: SyncError(message: "非 HTTP 响应"))
                    return
                }
                cont.resume(returning: (data ?? Data(), http))
            }.resume()
        }
    }

    /// 统一重试：首次 + ≤2 次重试，指数退避 1s / 2s
    private func withRetry(_ label: String, _ action: String,
                           _ op: () async throws -> Void) async throws {
        var lastError: Error?
        for attempt in 0..<3 {
            if attempt > 0 {
                let backoff: UInt64 = attempt == 1 ? 1_000_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: backoff)
            }
            do {
                try await op()
                return
            } catch {
                lastError = error
                let desc = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                DebugLogger.shared.log("LANSyncTransfer \(action)失败(第\(attempt + 1)次) \(label): \(desc)")
            }
        }
        throw lastError ?? SyncError(message: "\(action)失败：\(label)")
    }

    /// delegate 型流式下载（downloadTask 落系统临时文件，didFinishDownloadingTo 里搬到 <rel>.part）
    private func download(request: URLRequest, toPart partPath: String) async throws {
        guard let session = session else { throw SyncError(message: "会话已结束") }
        try await withCheckedThrowingContinuation { cont in
            let box = TransferBox(continuation: cont, downloadDest: partPath) { [weak self] delta in
                self?.noteBytes(delta)
            }
            let task = session.downloadTask(with: request)
            register(box, for: task)
            task.resume()
        }
    }

    // MARK: - 进度 / 速率

    /// 累计拉取字节 → 总体进度 + 最近 ~1s 窗口速率（delegate 线程回调，UI 更新切主线程）
    private func noteBytes(_ delta: Int64) {
        guard delta > 0 else { return }
        transferred += delta
        let now = Date()
        samples.append((now, transferred))
        // 只保留最近 ~1.2s 的采样（至少留 2 个），窗口内首尾差即速率
        while samples.count > 2, now.timeIntervalSince(samples[0].t) > 1.2 {
            samples.removeFirst()
        }
        var bps: Int64 = 0
        if let first = samples.first, let last = samples.last {
            let dt = last.t.timeIntervalSince(first.t)
            if dt >= 0.25 {
                bps = Int64(Double(last.bytes - first.bytes) / dt)
            }
        }
        let overall = totalBytes > 0 ? min(Double(transferred) / Double(totalBytes), 1) : 0
        publishOnMain {
            self.progress = overall
            self.bytesPerSecond = bps
        }
    }

    /// @Published 属性统一切主线程更新
    private func publishOnMain(_ update: @escaping () -> Void) {
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    // MARK: - 工具

    /// 大文件流式 sha256：FileHandle 每次读 1MB 喂 CryptoKit（禁止 readDataToEndOfFile，
    /// 1.4GB 主库必须分块）
    private static func streamSHA256(path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 备份目录时间戳：yyyyMMdd-HHmmss
    private static func backupTimestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// 原子替换：.part 校验通过后同卷 rename 语义覆盖正式文件
    private static func atomicReplace(partPath: String, dstPath: String) throws {
        let fm = FileManager.default
        // 拉取目标目录可能不存在（如对端新增了 indicator 子目录），先确保父目录
        try fm.createDirectory(atPath: (dstPath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        let part = URL(fileURLWithPath: partPath)
        let dst = URL(fileURLWithPath: dstPath)
        if fm.fileExists(atPath: dstPath) {
            _ = try fm.replaceItemAt(dst, withItemAt: part)
        } else {
            try fm.moveItem(atPath: partPath, toPath: dstPath)
        }
    }

    // MARK: - delegate 回调登记表

    private func register(_ box: TransferBox, for task: URLSessionTask) {
        boxesLock.lock()
        boxes[task.taskIdentifier] = box
        boxesLock.unlock()
    }

    /// 取出但不移除（进度回调阶段）
    private func boxFor(_ task: URLSessionTask) -> TransferBox? {
        boxesLock.lock()
        defer { boxesLock.unlock() }
        return boxes[task.taskIdentifier]
    }

    /// 取出并移除（收尾阶段，保证 continuation 恰好 resume 一次）
    private func takeBox(_ task: URLSessionTask) -> TransferBox? {
        boxesLock.lock()
        defer { boxesLock.unlock() }
        return boxes.removeValue(forKey: task.taskIdentifier)
    }
}

// MARK: - 会话回调胶水

/// delegate 回调 ↔ async 任务的路由载体（按 taskIdentifier 挂在 LANSyncTransfer.boxes 上）。
/// 仅拉取模型：只有下载任务走会话 delegate（上传已随 push 路径删除）。
private final class TransferBox {
    let continuation: CheckedContinuation<Void, Error>
    let onProgress: (Int64) -> Void
    /// 下载任务的目标路径（<rel>.part）
    let downloadDest: String
    /// didFinishDownloadingTo 的处理结果，didCompleteWithError 时统一 resume
    var pendingResult: Result<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>,
         downloadDest: String,
         onProgress: @escaping (Int64) -> Void) {
        self.continuation = continuation
        self.downloadDest = downloadDest
        self.onProgress = onProgress
    }

    /// 下载落盘：把系统临时文件搬到 <rel>.part。
    /// 本回调返回后临时文件即被系统删除，必须同步完成，不能异步。
    func finishDownload(from location: URL, response: URLResponse?) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            pendingResult = .failure(SyncError(message: "下载失败 HTTP \(status)"))
            return
        }
        let fm = FileManager.default
        // 目标目录可能不存在（对端新增的子目录），先确保父目录
        try? fm.createDirectory(atPath: (downloadDest as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        try? fm.removeItem(atPath: downloadDest)
        do {
            try fm.moveItem(at: location, to: URL(fileURLWithPath: downloadDest))
            pendingResult = .success(())
        } catch {
            // 跨卷极端情况退回复制
            do {
                try fm.copyItem(at: location, to: URL(fileURLWithPath: downloadDest))
                try? fm.removeItem(at: location)
                pendingResult = .success(())
            } catch {
                pendingResult = .failure(SyncError(message: "下载落地失败：\(error.localizedDescription)"))
            }
        }
    }
}

// MARK: - URLSession 会话回调
// 仅 delegate 型下载任务进入这里（登记过 box）；
// JSON 任务走 completion handler，不经会话 delegate，按 taskIdentifier 查不到即忽略。

extension LANSyncTransfer: URLSessionDelegate, URLSessionTaskDelegate, URLSessionDownloadDelegate {

    /// 下载进度（urlSessionDownloadTask）
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        boxFor(downloadTask)?.onProgress(bytesWritten)
    }

    /// 下载完成：临时文件必须在本次回调返回前搬走（返回后即被系统删除）
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        boxFor(downloadTask)?.finishDownload(from: location, response: downloadTask.response)
    }

    /// 任务收尾：统一 resume（每个 delegate 任务恰好一次）
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let box = takeBox(task) else { return }
        // 已有结果（如下载已成功落盘）不被迟到的 error 覆盖
        if let error = error, box.pendingResult == nil {
            box.pendingResult = .failure(SyncError(message: "传输中断：\(error.localizedDescription)"))
        }
        if let result = box.pendingResult {
            box.continuation.resume(with: result)
            return
        }
        // 兜底：无 error 且 didFinishDownloadingTo 未到（理论不发生），按 HTTP 状态收口
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        if (200..<300).contains(status) {
            box.continuation.resume(returning: ())
        } else {
            box.continuation.resume(throwing: SyncError(message: "HTTP \(status)"))
        }
    }
}

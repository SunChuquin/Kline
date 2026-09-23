//
//  KlineHTTPServer.swift
//  Kline
//
//  Created on 2026/9/7.
//

import Foundation
import Network
import SQLite3
import UIKit
import Darwin

/// 轻量 HTTP 服务器（Network.framework），前台监听 0.0.0.0:5051。
///
/// 两个用途：
/// 1. **A2 本地更新**：`GET /download/<file>` 暴露公共 Downloads 目录的 IPA，
///    配合 `apple-magnifier://install?url=http://127.0.0.1:5051/download/<file>`
///    拉起 TrollStore 安装（规避 platform-application 下系统共享面板的 CoreImage 崩溃，
///    也规避 TrollStore 不接受 file:// 的限制）。
/// 2. **🥈 远程更新**：`POST /install {"url": "..."}` 触发任意 URL Scheme
///    （如从 Gitee 下载 IPA 的 apple-magnifier 安装 URL）。
///
/// 限制：App 切后台后监听 socket 会被系统冻结，仅前台可用。
/// 因此回前台时自检一次（verifyOrRebuild），失效则自动重建监听。
final class KlineHTTPServer {
    static let shared = KlineHTTPServer()

    /// 监听端口
    let port: UInt16 = 5051

    /// 公共 Downloads 目录（no-sandbox 生效时可读）
    private let downloadsPath = "/var/mobile/Media/Downloads"

    private let queue = DispatchQueue(label: "com.sunck.Kline.httpserver")
    /// 自检/探测专用队列（与监听队列隔离，避免上传等长任务把探测请求堵在后面）
    private let probeQueue = DispatchQueue(label: "com.sunck.Kline.httpserver.probe")
    private var listener: NWListener?

    /// 连续绑定失败次数（用于启动时撞上旧进程未释放端口的自动重试）
    private var bindRetry = 0

    /// 服务器是否就绪（监听中）——仅作提示。
    /// ⚠️ 不可当作在线判据：它只是 NWListener 最后一次状态回调的快照。
    /// App 长时间后台被挂起后监听 socket 已被系统冻结/失效，但进程冻结期间收不到
    /// .failed 回调、回前台也不会补发，本值会一直停在 true（"假在线"）。
    /// 判定是否真的可用请用 probe(_:)。
    private(set) var isRunning = false

    private init() {
        // 回前台自检一次：探测失败即重建监听，避免"切回前台后本地服务已是死的、
        // UI 却显示在线、点重连也无效、只能杀 App 重进"。
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.verifyOrRebuild()
        }
    }

    // MARK: - 在线自检 / 强制重建

    /// 真实探测：连 127.0.0.1:port 并发一个 HTTP 请求，**收到响应才算在线**。
    /// 只连上不算：App 被挂起时内核仍会替它完成 TCP 握手（连接能建立但不会有人回包）。
    /// - Note: completion 在探测队列回调，UI 层需自行切主线程。
    func probe(_ completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(false)
            return
        }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        var finished = false
        func finish(_ ok: Bool) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            isRunning = ok
            completion(ok)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let req = Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: req, completion: .contentProcessed { _ in })
                connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { data, _, _, _ in
                    finish(!(data ?? Data()).isEmpty)
                }
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }
        connection.start(queue: probeQueue)
        probeQueue.asyncAfter(deadline: .now() + 1.5) { finish(false) }
    }

    /// 前台自检：探测失败则强制重建监听。
    /// 仅在「自认为是就绪状态」时才重建：启动瞬间 listener 还没到 .ready，此时探测必然失败，
    /// 若也去重启就会把自己刚开始的绑定砍掉（正常的绑定重试逻辑在 start() 里已覆盖）。
    func verifyOrRebuild() {
        let wasRunning = isRunning
        probe { [weak self] ok in
            guard let self = self, !ok, wasRunning else { return }
            DebugLogger.shared.log("KlineHTTPServer 自检失败：监听已失效，重建")
            self.restart()
        }
    }

    /// 强制重建监听。必须在 start() 之前丢弃旧 listener：
    /// 失效的 listener 其状态可能仍是 .ready，start() 会据此直接跳过，等于什么都没做。
    func restart() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.bindRetry = 0
            self.isRunning = false
            self.start()
        }
    }

    /// 启动/重连服务器（幂等：已就绪则跳过；failed 状态会重建监听）
    func start() {
        if let existing = listener {
            let st = existing.state
            switch st {
            case .ready:
                isRunning = true
                return
            case .waiting(_), .setup, .cancelled:
                isRunning = false
                return
            default:
                break
            }
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNew(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.bindRetry = 0
                    self.isRunning = true
                    DebugLogger.shared.log("KlineHTTPServer ready: 0.0.0.0:\(self.port)")
                case .failed(let error):
                    self.isRunning = false
                    DebugLogger.shared.log("KlineHTTPServer failed: \(error)")
                    // 自动拉起常撞上"旧进程 5051 尚未释放"（Address already in use），
                    // 首次绑定失败后按退避自动重建监听，免去手动点"重新连接"。
                    // 上限 10 次，避免端口始终被占时无限重试。
                    if self.bindRetry < 10 {
                        self.bindRetry += 1
                        let delay = 0.8 * Double(self.bindRetry)
                        self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self = self, !self.isRunning else { return }
                            DebugLogger.shared.log("KlineHTTPServer bind retry #\(self.bindRetry)...")
                            self.start()
                        }
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            DebugLogger.shared.log("KlineHTTPServer start error: \(error)")
        }
    }

    // MARK: - 连接处理

    /// 单连接状态：解析 header 后按请求类型分流（upload 流式写盘 / 普通请求攒 body）
    private final class HTTPConnectionState {
        var headerParsed = false
        var method = ""
        var path = ""
        var contentLength = 0
        var received = 0
        var isUpload = false
        var uploadTarget = ""
        var uploadHandle: FileHandle?
        var bodyBuffer = Data()
        var done = false
    }

    private func handleNew(_ connection: NWConnection) {
        connection.start(queue: queue)
        let state = HTTPConnectionState()
        var requestBuffer = Data()

        func processBody(_ data: Data) {
            guard !state.done else { return }
            if state.isUpload {
                guard let handle = state.uploadHandle else { return }
                try? handle.write(contentsOf: data)
                state.received += data.count
                if state.received >= state.contentLength {
                    try? handle.close()
                    state.uploadHandle = nil
                    state.done = true
                    DebugLogger.shared.log("上传完成: \(state.received) bytes")
                    respond(connection, status: 200, contentType: "application/json", body: "{\"ok\":true}")
                }
            } else {
                state.bodyBuffer.append(data)
                state.received += data.count
                if state.received >= state.contentLength {
                    state.done = true
                    let requestLine = state.method + " " + state.path + " HTTP/1.1"
                    dispatch(requestLine: requestLine, body: state.bodyBuffer, connection: connection)
                }
            }
        }

        func readLoop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if let data = data, !data.isEmpty {
                    if state.headerParsed {
                        processBody(data)
                        if state.done { return }
                        readLoop()
                        return
                    }
                    requestBuffer.append(data)
                    if let headerEnd = requestBuffer.range(of: Data("\r\n\r\n".utf8)) {
                        let headerData = requestBuffer.subdata(in: requestBuffer.startIndex..<headerEnd.lowerBound)
                        let headerText = String(data: headerData, encoding: .utf8) ?? ""
                        let requestLine = headerText.components(separatedBy: "\r\n").first ?? ""
                        let parts = requestLine.split(separator: " ")
                        let method = parts.count > 0 ? String(parts[0]) : ""
                        let rawPath = parts.count > 1 ? String(parts[1]) : ""
                        // 百分号解码 path（支持中文文件名/目录名），失败时退回原始串
                        let decoded = (rawPath.split(separator: "?").first.map(String.init) ?? rawPath)
                            .removingPercentEncoding ?? rawPath
                        let path = decoded
                        let contentLength = Self.parseContentLength(from: headerText)

                        state.headerParsed = true
                        state.method = method
                        state.path = path
                        state.contentLength = contentLength

                        // 流式写盘目标：/upload → 公共 Downloads；POST/PUT /sandbox/<rel> → 沙盒 Documents
                        let isSandboxWrite = (method == "POST" || method == "PUT") && path.hasPrefix("/sandbox/")
                        if (method == "POST" || method == "PUT"), path == "/upload" || isSandboxWrite {
                            state.isUpload = true
                            let targetPath: String
                            if path == "/upload" {
                                let name = Self.queryParam(rawPath, "name") ?? "upload.bin"
                                targetPath = downloadsPath + "/" + (name as NSString).lastPathComponent
                            } else {
                                let rel = String(path.dropFirst("/sandbox/".count))
                                guard let resolved = Self.resolveSandboxPath(rel, sandboxRoot: sandboxRoot) else {
                                    respond(connection, status: 400, body: "bad path")
                                    return
                                }
                                targetPath = resolved
                            }
                            state.uploadTarget = targetPath
                            // 确保父目录存在（PUT 沙盒子目录时，Documents 下可能没有目标目录）
                            let parentDir = (targetPath as NSString).deletingLastPathComponent
                            try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
                            FileManager.default.createFile(atPath: targetPath, contents: nil)
                            state.uploadHandle = FileHandle(forWritingAtPath: targetPath)
                            DebugLogger.shared.log("沙盒上传开始: \(targetPath) len=\(contentLength)")
                            if requestBuffer.count > headerEnd.upperBound {
                                let rest = requestBuffer.subdata(in: headerEnd.upperBound..<requestBuffer.endIndex)
                                requestBuffer.removeAll()
                                processBody(rest)
                                if state.done { return }
                            }
                            readLoop()
                            return
                        }

                        // 普通请求：等待完整 body 后分发
                        let bodyStart = headerEnd.upperBound
                        let available = requestBuffer.count - bodyStart
                        if available > 0 {
                            state.bodyBuffer = requestBuffer.subdata(in: bodyStart..<requestBuffer.endIndex)
                            state.received = available
                            requestBuffer.removeAll()
                        }
                        if state.received >= contentLength {
                            state.done = true
                            dispatch(requestLine: requestLine, body: state.bodyBuffer, connection: connection)
                            return
                        }
                        readLoop()
                        return
                    }
                }
                if isComplete || error != nil {
                    if let h = state.uploadHandle { try? h.close() }
                    connection.cancel()
                    return
                }
                readLoop()
            }
        }
        readLoop()
    }

    // MARK: - 路由

    private func dispatch(requestLine: String, body: Data, connection: NWConnection) {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(connection, status: 400, body: "bad request")
            return
        }
        let method = String(parts[0])
        let rawPath = String(parts[1])
        // 入口统一百分号解码（请求可能来自 handleNew 的原始行或重组行）
        let path = (rawPath.split(separator: "?").first.map(String.init) ?? rawPath)
            .removingPercentEncoding ?? rawPath

        switch (method, path) {
        case ("GET", "/"):
            // 状态 JSON 含 version 字段：电脑侧部署助手据此判断"新版 Kline 已重新打开"
            respond(connection, status: 200, contentType: "application/json",
                    body: Self.statusJSON())
        case ("GET", "/files"):
            let files = listIPAFiles()
            let json = (try? JSONSerialization.data(withJSONObject: files)) ?? Data("[]".utf8)
            respond(connection, status: 200, contentType: "application/json",
                    body: String(data: json, encoding: .utf8) ?? "[]")
        case ("POST", "/install"):
            handleInstall(body: body, connection: connection)
        case ("POST", "/install-local"):
            handleInstallLocal(body: body, connection: connection)
        case ("POST", "/spawnroot-test"):
            handleSpawnRootTest(connection: connection)
        case ("POST", "/sync/reload"):
            // 增量库外部写入完成（USB / 局域网推送后）→ 立即做一次指纹检查并按需热刷新，
            // 免去等下一次前台定时检查（默认 5 分钟）
            DispatchQueue.main.async {
                LiveDataStore.shared.notifyExternalWrite()
            }
            respond(connection, status: 200, contentType: "application/json",
                    body: "{\"ok\":true,\"action\":\"reload\"}")
        case ("POST", let p) where p.hasPrefix("/sync/merge-bucket"):
            // 电脑侧直推分片 / 历史重灌包（绕过设备侧无外网/防火墙的场景）：
            // 文件先经 PUT /sandbox/live/<file> 落在 Documents/live/，这里直接把它
            // 合并进本地增量库（与云端"下载→校验→合并"共用同一 mergeBucket 通路）。
            // 放行 `bucket_`（日分片）与 `patch_`（差分包，表结构一致）两种前缀。
            // 可选参数 sha256=<hex>：与沙盒文件内容比对，不符则拒绝合并。
            let name = (Self.queryParam(rawPath, "name") ?? "") as NSString
            // ① lastPathComponent 先剥掉任何目录分量（如 `../../x` → `x`），只留纯文件名
            let safeName = name.lastPathComponent
            // ② 只放行 bucket_ / patch_ 两种前缀 + `.db` 后缀（白名单）
            let hasAllowedPrefix = safeName.hasPrefix("bucket_") || safeName.hasPrefix("patch_")
            guard !safeName.isEmpty, hasAllowedPrefix, safeName.hasSuffix(".db") else {
                respond(connection, status: 400, body: "{\"error\":\"bad name\"}")
                return
            }
            // ③ 再经 resolveSandboxPath 做一次「解析后必须落在 Documents 内」的包含性校验（防穿越）
            guard let bucketPath = Self.resolveSandboxPath("live/" + safeName, sandboxRoot: sandboxRoot),
                  FileManager.default.fileExists(atPath: bucketPath) else {
                respond(connection, status: 404, body: "{\"error\":\"bucket not found, PUT /sandbox/live/<file> first\"}")
                return
            }
            let expectedSha = Self.queryParam(rawPath, "sha256")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.mergeBucketAndRespond(bucketPath: bucketPath, expectedSha: expectedSha,
                                           name: safeName, connection: connection)
            }
        case ("POST", let p) where p.hasPrefix("/sync/apply-patch"):
            // 电脑侧把补丁包（patch_<seq>.db）**直接按行应用到主库 tdx.db**：不经过增量库、
            // 不替换整库、不需要重启（App 内手点「合并到 tdx.db」走的是 MainDBMerger 那条路，
            // 这里只是把同一套语义换成「补丁文件 → 主库」，用一条集合式 SQL 完成映射与写入）。
            // 文件先经 PUT /sandbox/live/<file> 落在 Documents/live/。
            // 放行 `bucket_`（日分片）与 `patch_`（差分包，表结构一致）两种前缀。
            // 可选参数 sha256=<hex>：与沙盒文件内容比对，不符则拒绝应用（同 /sync/merge-bucket）。
            let patchName = (Self.queryParam(rawPath, "name") ?? "") as NSString
            // ① lastPathComponent 先剥掉任何目录分量（如 `../../x` → `x`），只留纯文件名
            let safePatchName = patchName.lastPathComponent
            // ② 只放行 bucket_ / patch_ 两种前缀 + `.db` 后缀（白名单）
            let patchPrefixOK = safePatchName.hasPrefix("bucket_") || safePatchName.hasPrefix("patch_")
            guard !safePatchName.isEmpty, patchPrefixOK, safePatchName.hasSuffix(".db") else {
                respond(connection, status: 400, body: "{\"error\":\"bad name\"}")
                return
            }
            // ③ 再经 resolveSandboxPath 做一次「解析后必须落在 Documents 内」的包含性校验（防穿越）
            guard let patchPath = Self.resolveSandboxPath("live/" + safePatchName, sandboxRoot: sandboxRoot),
                  FileManager.default.fileExists(atPath: patchPath) else {
                respond(connection, status: 404, body: "{\"error\":\"patch not found, PUT /sandbox/live/<file> first\"}")
                return
            }
            let expectedPatchSha = Self.queryParam(rawPath, "sha256")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.applyPatchAndRespond(patchPath: patchPath, expectedSha: expectedPatchSha,
                                          name: safePatchName, connection: connection)
            }
        case ("POST", "/sync/patch-session/begin"):
            // 会话式单事务落主库（Task 5）：开一条**独立连接** + BEGIN IMMEDIATE，跨多个 HTTP 请求保持。
            // 让设备落库与 PC 出包完全重叠（PC 出第 i+1 片的同时设备在 apply 第 i 片）。
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.beginPatchSessionAndRespond(connection: connection)
            }
        case ("POST", "/sync/patch-session/apply"):
            // apply?name=<片>：在会话连接上 ATTACH 该片（唯一别名）→ 写五张表。可多次调用（每片一次）。
            // 注：DETACH 不能在活跃事务内做（SQLite 报 locked），故别名保持到会话结束随连接关闭释放。
            let sName = ((Self.queryParam(rawPath, "name") ?? "") as NSString).lastPathComponent
            let sPrefixOK = sName.hasPrefix("bucket_") || sName.hasPrefix("patch_")
            guard !sName.isEmpty, sPrefixOK, sName.hasSuffix(".db") else {
                respond(connection, status: 400, body: "{\"error\":\"bad name\"}")
                return
            }
            guard let sPath = Self.resolveSandboxPath("live/" + sName, sandboxRoot: sandboxRoot),
                  FileManager.default.fileExists(atPath: sPath) else {
                respond(connection, status: 404, body: "{\"error\":\"patch not found, PUT /sandbox/live/<file> first\"}")
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.applyPatchSessionShard(name: sName, path: sPath, connection: connection)
            }
        case ("POST", "/sync/patch-session/commit"):
            // commit：UPDATE meta.last_date（MAX 防回退）+ COMMIT + 关连接 + loadMetaList + notifyMainDBChanged
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.commitPatchSessionAndRespond(connection: connection)
            }
        case ("POST", "/sync/patch-session/rollback"):
            // rollback：ROLLBACK + 关连接（释放写锁，已喂入的片全部丢弃）
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.rollbackPatchSessionAndRespond(connection: connection)
            }
        case ("GET", "/sync/status"):
            // 增量库当前状态（供推送脚本与排查使用）
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.respond(connection, status: 200, contentType: "application/json",
                             body: LiveDataStore.shared.currentStatusJSON())
            }
        case ("GET", "/sync/probe"):
            // ?file=SH%23600519：在 App 自身连接上读回该标的的日线末日 / 最新季线 bar（只读核对用）
            let probeFile = Self.queryParam(rawPath, "file") ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.probeMainDB(file: probeFile, connection: connection)
            }
        case ("GET", "/opener-log"):
            handleOpenerLog(connection: connection)
        case ("GET", "/sandbox"), ("GET", "/sandbox/"):
            listSandboxDirectory(sandboxRoot, connection: connection)
        case ("DELETE", let p) where p.hasPrefix("/sandbox/"):
            deleteSandboxPath(String(p.dropFirst("/sandbox/".count)), connection: connection)
        default:
            if method == "GET", path.hasPrefix("/sandbox/") {
                serveSandboxPath(String(path.dropFirst("/sandbox/".count)), connection: connection)
            } else if method == "GET", path.hasPrefix("/download/") {
                let filename = String(path.dropFirst("/download/".count))
                serveFile(filename, connection: connection)
            } else {
                respond(connection, status: 404, body: "not found")
            }
        }
    }

    // MARK: - 沙盒直连（GET 列目录/读文件、POST/PUT 流式写、DELETE 删除，限 Documents 内）

    /// 当前 App 沙盒 Documents 根路径
    private var sandboxRoot: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }

    /// 把沙盒相对路径解析为 Documents 内绝对路径（防路径穿越，结果必须落在 Documents 内）
    static func resolveSandboxPath(_ rel: String, sandboxRoot: String) -> String? {
        let root = URL(fileURLWithPath: sandboxRoot).standardizedFileURL
        let target = root.appendingPathComponent(rel).standardizedFileURL
        let targetPath = target.path
        guard targetPath == root.path || targetPath.hasPrefix(root.path + "/") else {
            return nil
        }
        return targetPath
    }

    /// 列出沙盒目录（JSON：name/size/mod/dir）
    private func listSandboxDirectory(_ dir: String, connection: NWConnection) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else {
            respond(connection, status: 404, body: "dir not found")
            return
        }
        var arr: [[String: Any]] = []
        for name in items {
            let full = dir + "/" + name
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            let attrs = try? fm.attributesOfItem(atPath: full)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mod = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            arr.append(["name": name, "size": size, "mod": mod, "dir": isDir.boolValue])
        }
        let json = (try? JSONSerialization.data(withJSONObject: arr)) ?? Data("[]".utf8)
        respond(connection, status: 200, contentType: "application/json",
                body: String(data: json, encoding: .utf8) ?? "[]")
    }

    /// GET /sandbox/<path>：目录则列出，文件则返回内容
    private func serveSandboxPath(_ rel: String, connection: NWConnection) {
        guard let target = Self.resolveSandboxPath(rel, sandboxRoot: sandboxRoot) else {
            respond(connection, status: 400, body: "bad path")
            return
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target, isDirectory: &isDir)
        DebugLogger.shared.log("沙盒GET rel=[\(rel)] target=[\(target)] exists=\(exists) dir=\(isDir.boolValue)")
        guard exists else {
            respond(connection, status: 404, body: "not found")
            return
        }
        if isDir.boolValue {
            listSandboxDirectory(target, connection: connection)
            return
        }
        guard let handle = FileHandle(forReadingAtPath: target) else {
            respond(connection, status: 500, body: "read failed")
            return
        }
        // 大文件（如 1.4GB 主库 tdx.db）**流式**返回：先发 header（带 Content-Length），
        // 再分块 FileHandle 读 + send，避免整份读进内存。
        // 原实现 `readDataToEndOfFile()` 把整个 1.4GB 读进内存再一次性 send →
        // 内存爆掉 / 单次 send 超大 content 失败 → 客户端拿到 503 / 连接中断。
        let size = Int(((try? FileManager.default.attributesOfItem(atPath: target))?[.size] as? NSNumber)?.int64Value ?? 0)
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "Content-Length: \(size)\r\n"
            + "Connection: close\r\n\r\n"
        DebugLogger.shared.log("沙盒GET 流式返回 target=[\(target)] size=\(size)")
        streamFileLocked(handle: handle, connection: connection, header: Data(head.utf8))
    }

    /// 分块把 FileHandle 内容写进 socket（每块 1MB），全部写完后以 finalMessage 收尾并关连接。
    /// 与 `/upload` 的流式**写**对称：这里只保留一块在内存，不做整份缓冲。
    private func streamFileLocked(handle: FileHandle, connection: NWConnection, header: Data) {
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self = self, error == nil else {
                try? handle.close()
                connection.cancel()
                return
            }
            self.sendNextChunkLocked(handle: handle, connection: connection)
        })
    }

    /// 读下一块（1MB）并发送；读到 EOF 则发一个 isComplete 的 finalMessage 关闭流。
    private func sendNextChunkLocked(handle: FileHandle, connection: NWConnection) {
        let chunk = handle.readData(ofLength: 1 << 20)
        guard !chunk.isEmpty else {
            try? handle.close()
            // Content-Length 已给出，这里显式标记流结束（TCP 半关），客户端据此判定下载完成
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self = self, error == nil else {
                try? handle.close()
                connection.cancel()
                return
            }
            self.sendNextChunkLocked(handle: handle, connection: connection)
        })
    }

    /// DELETE /sandbox/<path>：删除沙盒内文件
    private func deleteSandboxPath(_ rel: String, connection: NWConnection) {
        guard let target = Self.resolveSandboxPath(rel, sandboxRoot: sandboxRoot) else {
            respond(connection, status: 400, body: "bad path")
            return
        }
        DebugLogger.shared.log("沙盒DEL rel=[\(rel)] target=[\(target)] exists=\(FileManager.default.fileExists(atPath: target))")
        do {
            try FileManager.default.removeItem(atPath: target)
            respond(connection, status: 200, contentType: "application/json", body: "{\"ok\":true}")
        } catch {
            DebugLogger.shared.log("沙盒DEL 失败: \(error)")
            respond(connection, status: 500, body: "delete failed")
        }
    }

    // MARK: - 处理函数

    /// POST /install：打开任意 URL Scheme（🥈 远程更新用）
    private func handleInstall(body: Data, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let urlString = json["url"] as? String,
              let url = URL(string: urlString) else {
            respond(connection, status: 400, body: "{\"error\":\"bad body\"}")
            return
        }
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
        respond(connection, status: 200, contentType: "application/json", body: "{\"ok\":true}")
    }

    /// POST /install-local：拉起 TrollStore 安装 IPA
    /// body 二选一：
    ///   {"url": "http://<外部下载源>/Kline.ipa"} —— 直接打开外部 http/https URL（推荐：
    ///     下载源放电脑/公网，避免 Kline 切后台后本地 HTTP 被冻结导致下载失败）
    ///   {"file": "Kline.ipa", "scope": "download"|"sandbox"} —— 走 KlineHTTP 本地下载
    ///     （scope=download 用 /download/<file>；scope=sandbox 用 /sandbox/<path>，文件在沙盒 Documents 下）
    private func handleInstallLocal(body: Data, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            respond(connection, status: 400, body: "{\"error\":\"bad body\"}")
            return
        }
        var trollURL: String?
        if let direct = json["url"] as? String, !direct.isEmpty {
            // 外部下载源：直接打开
            trollURL = direct
        } else if let file = json["file"] as? String {
            let scope = (json["scope"] as? String) ?? "download"
            if scope == "sandbox" {
                trollURL = "apple-magnifier://install?url=\(("http://127.0.0.1:\(port)/sandbox/\(file)").percentEncodedForQuery)"
            } else {
                let safeName = (file as NSString).lastPathComponent
                trollURL = "apple-magnifier://install?url=\(("http://127.0.0.1:\(port)/download/\(safeName)").percentEncodedForQuery)"
            }
        }
        guard let finalURL = trollURL, let url = URL(string: finalURL) else {
            respond(connection, status: 400, body: "{\"error\":\"bad body\"}")
            return
        }
        DebugLogger.shared.log("install-local received body=\(String(decoding: body, as: UTF8.self))")
        // 方案A「装完自动打开新版」：opener 守护 + apple-magnifier URL，见 triggerTrollStoreInstall
        triggerTrollStoreInstall(trollURL: url.absoluteString)
        respond(connection, status: 200, contentType: "application/json", body: "{\"ok\":true}")
    }

    /// 构造「本地 HTTP 文件 → TrollStore 安装」的 URL Scheme
    static func trollStoreInstallURL(localFile: String, port: UInt16) -> String {
        let downloadURL = "http://127.0.0.1:\(port)/download/\(localFile.percentEncodedForQuery)"
        return "apple-magnifier://install?url=\(downloadURL.percentEncodedForQuery)"
    }

    /// 触发 TrollStore 安装：先以 root spawn 一个 opener 守护（独立于 App 生命周期，
    /// 装完检测到版本与当前不同后自动拉起新版 Kline），再打开 apple-magnifier URL。
    /// 当前版本号作为首个 argv 传给 opener，供其判定"已装新版本"。
    /// /install-local 与 App 内远程更新（LocalUpdateView）共用此链路。
    func triggerTrollStoreInstall(trollURL: String) {
        let curVer = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
        // 等待窗口给足 600s：用户走完「打开 TrollStore → 下载 IPA → Install」可能远超旧默认 90s，
        // 到点自退后就再没人把新版拉到前台（表现为"装完了但没自动打开"）
        let maxWait = "600"
        // 让 opener 的诊断日志同时落到 App 沙盒（root 可写；跨版本升级容器路径不变，便于事后回看）
        let openerLog = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
            + "/opener_log.txt"
        DebugLogger.shared.log("triggerTrollStoreInstall trollURL=\(trollURL) curVer=\(curVer)")
        let srOpen = RootRunner.spawnDetached(
            executable: Bundle.main.bundlePath + "/opener",
            arguments: [curVer, maxWait, openerLog])
        DebugLogger.shared.log("triggerTrollStoreInstall spawned opener => sr=\(srOpen) maxWait=\(maxWait)s")
        if srOpen != 0 {
            DebugLogger.shared.log("⚠️ opener spawn 失败（sr=\(srOpen)）：装完不会自动打开新版")
        }
        DispatchQueue.main.async {
            if let url = URL(string: trollURL) {
                UIApplication.shared.open(url)
            }
        }
    }

    /// POST /spawnroot-test：以 root（persona 99）spawn /usr/bin/id，验证 persona-mgmt 生效（方案A 阶段1冒烟）
    private func handleSpawnRootTest(connection: NWConnection) {
        let result = RootRunner.verifyRoot()
        DebugLogger.shared.log("spawnroot-test: \(result)")
        let safe = result.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        respond(connection, status: 200, contentType: "application/json",
                body: "{\"result\":\"\(safe)\"}")
    }

    /// GET /opener-log：读取 opener（root daemon）写下的诊断日志，供排查"装完自动打开"是否生效
    private func handleOpenerLog(connection: NWConnection) {
        let path = "/private/var/tmp/opener.log"
        var text = "(opener.log 不存在或不可读)"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let s = String(data: data, encoding: .utf8) {
            text = s
        }
        let safe = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\n")
            .replacingOccurrences(of: "\"", with: "'")
        respond(connection, status: 200, contentType: "text/plain",
                body: safe)
    }

    /// /sync/merge-bucket 的执行体（主线程入口）：可选 sha256 校验 → mergeBucket → JSON 汇报。
    /// 合并结果里带「合并后的覆盖标的数 / 最新交易日」，推送脚本据此判断是否生效。
    private func mergeBucketAndRespond(bucketPath: String, expectedSha: String?,
                                       name: String, connection: NWConnection) {
        if let expected = expectedSha, !expected.isEmpty {
            guard let actual = LiveDataStore.sha256Hex(ofFile: bucketPath),
                  actual.lowercased() == expected.lowercased() else {
                DebugLogger.shared.log("[TdxSync] 分片 \(name) sha256 不符，拒绝合并")
                respond(connection, status: 400, contentType: "application/json",
                        body: "{\"error\":\"sha256 mismatch\"}")
                return
            }
        }
        LiveDataStore.shared.mergeBucket(atPath: bucketPath) { [weak self] result in
            guard let self = self else { return }
            if result.ok {
                let s = LiveDataStore.shared.status
                DebugLogger.shared.log("[TdxSync] 电脑侧直推分片 \(name) 合并成功：\(result.message)")
                self.respond(connection, status: 200, contentType: "application/json",
                             body: "{\"ok\":true,\"message\":\"\(Self.jsonEsc(result.message))\""
                                 + ",\"metaCount\":\(s.metaCount),\"dailyCount\":\(s.dailyCount)"
                                 + ",\"latestDate\":\(s.latestDate)}")
            } else {
                DebugLogger.shared.log("[TdxSync] 电脑侧直推分片 \(name) 合并失败：\(result.message)")
                self.respond(connection, status: 500, contentType: "application/json",
                             body: "{\"error\":\"\(Self.jsonEsc(result.message))\"}")
            }
        }
    }

    /// /sync/apply-patch 的执行体（主线程入口）：可选 sha256 校验 → 主库按行 UPSERT → JSON 汇报。
    /// 合并可能耗时数秒，故真正的写库动作全部落到 `DatabaseManager.dbQueue` 上串行执行，
    /// 完成后由 performOnDBQueue 回主线程写响应（**不在 HTTP 线程同步执行**）。
    private func applyPatchAndRespond(patchPath: String, expectedSha: String?,
                                      name: String, connection: NWConnection) {
        if let expected = expectedSha, !expected.isEmpty {
            guard let actual = LiveDataStore.sha256Hex(ofFile: patchPath),
                  actual.lowercased() == expected.lowercased() else {
                DebugLogger.shared.log("[Patch] 补丁 \(name) sha256 不符，拒绝应用")
                respond(connection, status: 400, contentType: "application/json",
                        body: "{\"error\":\"sha256 mismatch\"}")
                return
            }
        }
        DatabaseManager.shared.performOnDBQueue({ (db: OpaquePointer?) -> PatchApplyOutcome in
            KlineHTTPServer.applyPatchLocked(db: db, patchPath: patchPath)
        }, completion: { [weak self] outcome in
            guard let self = self else { return }
            if outcome.ok {
                DebugLogger.shared.log("[Patch] 补丁 \(name) 应用进主库成功：\(outcome.message)")
                // 主库 last_date 已变 → metaList 必须重读；主库内容被改写 → dataVersion 自增热刷新
                DatabaseManager.shared.loadMetaList()
                DatabaseManager.shared.notifyMainDBChanged()
                self.respond(connection, status: 200, contentType: "application/json",
                             body: "{\"ok\":true,\"message\":\"\(Self.jsonEsc(outcome.message))\""
                                 + ",\"dailyRows\":\(outcome.dailyRows)"
                                 + ",\"weeklyRows\":\(outcome.weeklyRows)"
                                 + ",\"monthlyRows\":\(outcome.monthlyRows)"
                                 + ",\"quarterlyRows\":\(outcome.quarterlyRows)"
                                 + ",\"yearlyRows\":\(outcome.yearlyRows)"
                                 + ",\"coveredFiles\":\(outcome.coveredFiles)"
                                 + ",\"skippedFiles\":\(outcome.skippedFiles)"
                                 + ",\"latestDate\":\(outcome.latestDate)}")
            } else {
                DebugLogger.shared.log("[Patch] 补丁 \(name) 应用进主库失败：\(outcome.message)")
                self.respond(connection, status: 500, contentType: "application/json",
                             body: "{\"error\":\"\(Self.jsonEsc(outcome.message))\"}")
            }
        })
    }

    // MARK: - 会话式单事务落主库（Task 5）

    /// POST /sync/patch-session/begin：开独立连接 + BEGIN IMMEDIATE，启动 120s 看门狗。
    private func beginPatchSessionAndRespond(connection: NWConnection) {
        PatchSessionManager.shared.begin(dbPath: DatabaseManager.writableDBPath) { [weak self] result in
            guard let self = self else { return }
            if result.ok {
                DebugLogger.shared.log("[Patch] 会话 begin：\(result.message)")
                self.respond(connection, status: 200, contentType: "application/json",
                             body: "{\"ok\":true,\"message\":\"\(Self.jsonEsc(result.message))\"}")
            } else {
                DebugLogger.shared.log("[Patch] 会话 begin 失败：\(result.message)")
                self.respond(connection, status: 500, contentType: "application/json",
                             body: "{\"error\":\"\(Self.jsonEsc(result.message))\"}")
            }
        }
    }

    /// POST /sync/patch-session/apply?name=<片>：在会话连接上 ATTACH 该片 + 写五张表 + DETACH。
    private func applyPatchSessionShard(name: String, path: String, connection: NWConnection) {
        PatchSessionManager.shared.applyShard(name: name, path: path) { [weak self] result in
            guard let self = self else { return }
            if result.ok {
                DebugLogger.shared.log("[Patch] 会话 apply 片 \(name)：\(result.message)")
                self.respond(connection, status: 200, contentType: "application/json",
                             body: "{\"ok\":true,\"message\":\"\(Self.jsonEsc(result.message))\"}")
            } else {
                DebugLogger.shared.log("[Patch] 会话 apply 片 \(name) 失败：\(result.message)")
                self.respond(connection, status: 500, contentType: "application/json",
                             body: "{\"error\":\"\(Self.jsonEsc(result.message))\"}")
            }
        }
    }

    /// POST /sync/patch-session/commit：UPDATE meta.last_date（MAX 防回退）+ COMMIT + 关连接，
    /// 随后重读 metaList + 自增 dataVersion（主库内容已变）。
    ///
    /// ⚠️ 时序要点（真机实测后调整）：会话连接在 `begin` 置 `wal_autocheckpoint=0`，COMMIT 不再在
    /// 提交语句内做全量 checkpoint（否则 12s）；故**响应发出后**用 `deferredWALCheckpoint()`
    /// 异步补一次 PASSIVE checkpoint（独立短连接，不阻塞 App 的 dbQueue，也不阻塞读响应）。
    private func commitPatchSessionAndRespond(connection: NWConnection) {
        let tHttp = DispatchTime.now()
        PatchSessionManager.shared.commit { [weak self] r in
            guard let self = self else { return }
            let tMain = DispatchTime.now()
            if r.ok {
                DebugLogger.shared.log("[Patch] 会话 commit：\(r.message)")
                DebugLogger.shared.log("[Patch] commit 分段（主线程）：HTTP 入口→主线程回调=\(elapsedMsSince(tHttp))ms"
                    + " · 回调排队=\(elapsedMsSince(tMain))ms")
                let tMeta = DispatchTime.now()
                DatabaseManager.shared.loadMetaList()
                let metaMs = elapsedMsSince(tMeta)
                let tNotify = DispatchTime.now()
                DatabaseManager.shared.notifyMainDBChanged()
                let notifyMs = elapsedMsSince(tNotify)
                let tResp = DispatchTime.now()
                self.respond(connection, status: 200, contentType: "application/json",
                             body: "{\"ok\":true,\"message\":\"\(Self.jsonEsc(r.message))\""
                                 + ",\"dailyRows\":\(r.dailyRows)"
                                 + ",\"weeklyRows\":\(r.weeklyRows)"
                                 + ",\"monthlyRows\":\(r.monthlyRows)"
                                 + ",\"quarterlyRows\":\(r.quarterlyRows)"
                                 + ",\"yearlyRows\":\(r.yearlyRows)"
                                 + ",\"coveredFiles\":\(r.coveredFiles)"
                                 + ",\"shards\":\(r.shardCount)"
                                 + ",\"latestDate\":\(r.latestDate)}")
                DebugLogger.shared.log("[Patch] commit 分段（主线程）：loadMetaList 入队=\(metaMs)ms"
                    + " · notifyMainDBChanged=\(notifyMs)ms"
                    + " · 拼+写响应=\(elapsedMsSince(tResp))ms"
                    + " · 至此总耗时=\(elapsedMsSince(tHttp))ms")
                self.deferredWALCheckpoint()
            } else {
                DebugLogger.shared.log("[Patch] 会话 commit 失败：\(r.message)")
                self.respond(connection, status: 500, contentType: "application/json",
                             body: "{\"error\":\"\(Self.jsonEsc(r.message))\"}")
            }
        }
    }

    /// 响应发出后的**异步** WAL 回写（best-effort，**有界循环**）：用一条**独立短连接**反复
    /// `wal_checkpoint(PASSIVE)` 直到 `log == checkpointed`（WAL 已全部回写），随后再 `TRUNCATE`
    /// 把 WAL 文件真正截断。
    ///
    /// 为什么需要：会话连接关闭了 autocheckpoint（见 `PatchSessionManager.begin`），主库 WAL 会停在
    /// 几百 MB；这里把它回写进主库，避免 WAL 随会话数无限增长，也让「按文件拉 tdx.db」的核对工具
    /// （verify_main_db.py）拿到完整数据。
    ///
    /// 为什么用独立连接而不是 App 的 `dbQueue`：PASSIVE 会拷贝上百 MB，走 dbQueue 会把 App 自己的
    /// 查询（热刷新 3611 行）堵在它后面十几秒；独立连接则与 App 读并发，拿不到锁时只回写能回写的部分。
    /// **正确性无关**：WAL 语义下已提交数据对其它连接立即可见（不依赖 checkpoint），此处只做空间回收。
    ///
    /// 为什么循环：PASSIVE 只回写到「最老读者快照」处，App 侧持续有短读事务时**单次可能只推进一部分**，
    /// 留下的尾巴长期累积就是 WAL 缓慢膨胀。**必须有界**（最多 10 次 / 总预算 60s / 间隔 1s），否则遇到
    /// 持续读事务会退化成无限循环；到上限仍未完成就正常收尾并打警告，不报错、不卡死、不重试到卡死。
    ///
    /// 为什么要额外 TRUNCATE（真机实测 2026-09-23）：观察到的状态是 PASSIVE **一次就能** log==checkpointed
    /// （共 1 次、约 15s），但 WAL **文件**仍不收敛（连跑 3 次：321.9 → 429.2 → 536.8MB，每次追加一个
    /// 会话的帧量）——因为文件截断只在「日志被 reset」时发生，而 reset 需要独占全部读者槽位，App 侧并发读
    /// 会让写方/回写方都拿不到，`journal_size_limit` 因此也没机会生效。改用 `TRUNCATE`（独占 + 截断为 0）
    /// 才能真正让文件收敛；它遇活跃读者/写者返回 `busy=1`（本连接无 busy_timeout → 立即失败、绝不阻塞）→ 交给下一轮重试。
    private func deferredWALCheckpoint() {
        let dbPath = DatabaseManager.writableDBPath
        // 有界策略参数（明确写死，便于从日志一眼看出是否在膨胀）
        // 间隔 2s + 上限 30 次 → 实际由 `budgetSec`（60s）收敛，把重试窗口拉到能覆盖「提交后 App 侧
        // 3611 行热刷新（约 15~20s 的连续短读）」这个窗口。
        // ⚠️ **绝不能给这条连接设 busy_timeout**：实测（2026-09-23）把 busy_timeout 设成 15s 后，
        // 等待中的 TRUNCATE 会让**下一轮会话的 `BEGIN IMMEDIATE` 立刻报 `database is locked`**
        // （会话连接 busy_timeout=0 → 拿不到写锁立即失败），直接打断流水线（第 3 连跑 begin 失败）。
        // 故一律用「立即失败 + 有界重试」，宁可这次不截断，也绝不阻塞同步链路。
        let maxAttempts = 30
        let budgetSec: Double = 60
        let intervalSec: Double = 2.0
        // journal_size_limit = 64MB：**连接级**设置（本地实测新连接读回 -1，不随库文件持久化）。
        // 兜底作用：万一某次日志复位不经 TRUNCATE 路径，文件也会被裁到 ≤64MB。取 64MB 的理由：它
        // **不限制事务期间的 WAL 增长**（只在日志复位时裁剪），故不会拖慢 COMMIT；同时明显小于观测到的
        // 峰值（107~537MB），又留出余量避免下轮会话刚写入就要重新扩展文件而多付一次分配/IO。
        let journalSizeLimit = 64 * 1024 * 1024
        DispatchQueue.global(qos: .utility).async {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                  let db = handle else {
                if let h = handle { sqlite3_close(h) }
                DebugLogger.shared.log("[Patch] 延迟回写：打开独立连接失败")
                return
            }
            let walBeforeMB = fileSizeMB(dbPath + "-wal")
            sqlite3_exec(db, "PRAGMA journal_size_limit = \(journalSizeLimit);", nil, nil, nil)
            let t0 = DispatchTime.now()
            var attempt = 0
            var logBytes = 0
            var ckptBytes = 0
            var truncateBusy = -1
            var backfilled = false
            var finished = false
            var stopReason = "尝试次数用尽(\(maxAttempts)次)"
            while attempt < maxAttempts {
                attempt += 1
                let passive = walCheckpoint(db: db, mode: "PASSIVE")
                logBytes = passive.logBytes
                ckptBytes = passive.ckptBytes
                var line = "[Patch] 延迟回写 第\(attempt)次: log=\(logBytes) checkpointed=\(ckptBytes)"
                    + " rc=\(passive.rc)"
                backfilled = logBytes <= ckptBytes          // 已全部回写（日志已复位时为 0==0）
                if backfilled {
                    // 全部回写到位 → 再尝试真正截断 WAL 文件（并复位日志，使下轮写从帧 1 开始）
                    let trunc = walCheckpoint(db: db, mode: "TRUNCATE")
                    truncateBusy = trunc.busy
                    line += " · TRUNCATE: busy=\(trunc.busy) log=\(trunc.logBytes)"
                        + " checkpointed=\(trunc.ckptBytes) rc=\(trunc.rc)"
                    finished = trunc.busy == 0 && trunc.logBytes == 0
                }
                line += " · WAL=\(String(format: "%.1f", fileSizeMB(dbPath + "-wal")))MB"
                DebugLogger.shared.log(line)
                if finished { break }
                if Double(elapsedMsSince(t0)) / 1000.0 >= budgetSec {
                    stopReason = "总预算 \(Int(budgetSec))s 用尽"
                    break
                }
                Thread.sleep(forTimeInterval: intervalSec)
            }
            let costSec = Double(elapsedMsSince(t0)) / 1000.0
            let walNowMB = fileSizeMB(dbPath + "-wal")
            if finished {
                DebugLogger.shared.log("[Patch] 延迟回写完成（共\(attempt)次，耗时 "
                    + "\(String(format: "%.1f", costSec))s，WAL "
                    + "\(String(format: "%.1f", walBeforeMB))MB → \(String(format: "%.1f", walNowMB))MB）")
            } else if backfilled {
                DebugLogger.shared.log("[Patch] 延迟回写已回写未截断（共\(attempt)/\(maxAttempts)次，"
                    + "log=\(logBytes) checkpointed=\(ckptBytes) TRUNCATE busy=\(truncateBusy)，WAL "
                    + "\(String(format: "%.1f", walNowMB))MB，\(stopReason)）")
            } else {
                DebugLogger.shared.log("[Patch] 延迟回写未完成（共\(attempt)/\(maxAttempts)次，"
                    + "log=\(logBytes) checkpointed=\(ckptBytes)，WAL "
                    + "\(String(format: "%.1f", walNowMB))MB，\(stopReason)）")
            }
            sqlite3_close(db)
        }
    }

    /// GET /sync/probe?file=<file>：在 **App 自身连接**（`DatabaseManager.dbQueue`）上读回指定标的的
    /// 日线末日与该标的最新季线 bar，供校验「延后 checkpoint / 异步刷新后 App 仍能读到新数据」。
    /// 只读、单行查询，不写任何状态。
    private func probeMainDB(file: String, connection: NWConnection) {
        guard !file.isEmpty else {
            respond(connection, status: 400, contentType: "application/json",
                    body: "{\"error\":\"missing file\"}")
            return
        }
        let escaped = file.replacingOccurrences(of: "'", with: "''")
        let dbPath = DatabaseManager.writableDBPath   // 主线程取值后带入 dbQueue 闭包（避免跨隔离域读）
        DatabaseManager.shared.performOnDBQueue({ (db: OpaquePointer?) -> String in
            guard let db = db else { return "{\"ok\":false,\"error\":\"主库未就绪\"}" }
            let metaId = KlineHTTPServer.scalarInt(db: db,
                sql: "SELECT id FROM meta WHERE file = '\(escaped)' LIMIT 1;")
            let dailyMax = KlineHTTPServer.scalarInt(db: db,
                sql: "SELECT MAX(date) FROM daily WHERE meta_id = \(metaId);")
            let dailyCount = KlineHTTPServer.scalarInt(db: db,
                sql: "SELECT COUNT(*) FROM daily WHERE meta_id = \(metaId);")
            var qDate = 0
            var qClose = "null"
            var st: OpaquePointer?
            let q = "SELECT date, close FROM quarterly WHERE meta_id = \(metaId) ORDER BY date DESC LIMIT 1;"
            if sqlite3_prepare_v2(db, q, -1, &st, nil) == SQLITE_OK {
                if sqlite3_step(st) == SQLITE_ROW {
                    qDate = Int(sqlite3_column_int64(st, 0))
                    qClose = String(format: "%.4f", sqlite3_column_double(st, 1))
                }
                sqlite3_finalize(st)
            }
            return "{\"ok\":\(metaId > 0),\"file\":\"\(file)\",\"metaId\":\(metaId)"
                + ",\"dailyMaxDate\":\(dailyMax),\"dailyCount\":\(dailyCount)"
                + ",\"quarterlyLastDate\":\(qDate),\"quarterlyLastClose\":\(qClose)"
                + ",\"walMB\":\(String(format: "%.1f", fileSizeMB(dbPath + "-wal")))"
                + ",\"mainDBMB\":\(String(format: "%.1f", fileSizeMB(dbPath)))}"
        }, completion: { [weak self] json in
            DebugLogger.shared.log("[Patch] 主库读回探针（App 连接）：\(json)")
            self?.respond(connection, status: 200, contentType: "application/json", body: json)
        })
    }

    /// POST /sync/patch-session/rollback：ROLLBACK + 关连接（释放写锁，已喂入的片全部丢弃）。
    private func rollbackPatchSessionAndRespond(connection: NWConnection) {
        PatchSessionManager.shared.rollback(reason: "客户端请求") { [weak self] result in
            guard let self = self else { return }
            DebugLogger.shared.log("[Patch] 会话 rollback：\(result.message)")
            self.respond(connection, status: result.ok ? 200 : 500, contentType: "application/json",
                         body: result.ok
                             ? "{\"ok\":true,\"message\":\"\(Self.jsonEsc(result.message))\"}"
                             : "{\"error\":\"\(Self.jsonEsc(result.message))\"}")
        }
    }

    // MARK: - 补丁 → 主库（全部在 DatabaseManager.dbQueue 上）

    /// ATTACH 补丁包 → 单事务 → 五张周期表各**一条集合式 SQL**（`INSERT OR REPLACE ... SELECT`，
    /// 映射键 = `file`）→ 一条集合式 SQL 更新 `meta.last_date` → COMMIT / DETACH。
    /// 任一步失败：ROLLBACK，主库原样，返回原因。**不触碰增量库、不整库替换**。
    nonisolated private static func applyPatchLocked(db: OpaquePointer?, patchPath: String) -> PatchApplyOutcome {
        var outcome: PatchApplyOutcome = (false, 0, 0, 0, 0, 0, 0, 0, 0, "")
        guard let db = db else {
            outcome.message = "主库未就绪（连接不可用）"
            return outcome
        }
        // ATTACH 不能在事务内 → 先 ATTACH；路径里的单引号必须转义（同 LiveDataStore）
        let escaped = patchPath.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(db, "ATTACH DATABASE '\(escaped)' AS bkt;", nil, nil, nil) == SQLITE_OK else {
            outcome.message = "补丁 ATTACH 失败：\(String(cString: sqlite3_errmsg(db)))"
            return outcome
        }
        defer { sqlite3_exec(db, "DETACH DATABASE bkt;", nil, nil, nil) }

        // 补丁契约：至少要有 bkt_daily（映射键 = file；主库 meta.file 3611/3611 唯一）
        guard tableExists(db: db, schema: "bkt", name: "bkt_daily") else {
            outcome.message = "补丁缺少 bkt_daily 表"
            return outcome
        }
        let patchFiles = scalarInt(db: db, sql: "SELECT COUNT(DISTINCT file) FROM bkt.bkt_daily;")
        outcome.coveredFiles = scalarInt(db: db,
            sql: "SELECT COUNT(DISTINCT b.file) FROM bkt.bkt_daily b JOIN main.meta m ON m.file = b.file;")
        outcome.skippedFiles = max(0, patchFiles - outcome.coveredFiles)   // 主库 meta 里没有的 file（如新上市）
        outcome.latestDate = scalarInt(db: db, sql: "SELECT MAX(date) FROM bkt.bkt_daily;")

        // 批量写入的会话级 pragma（主库连接上原本**一个 pragma 都没设**，用的是默认值，
        // 对 84 万行的 UPSERT 是偏慢的配置）。这三条都是**会话级、不改变库文件属性**，
        // 且在 `defer` 里还原，不影响其它读写路径：
        //   · cache_size：默认约 8MB，对 1400 万行表的 B-tree 遍历太小 → 32MB
        //   · temp_store：JOIN 的临时结构放内存，避免落盘
        //   · synchronous：**仍是单事务**（只有一次 commit），这里显式设 NORMAL 只影响本次提交的 fsync 策略；
        //     WAL 下 NORMAL 对「App 崩溃」是安全的（仅掉电可能丢最近提交），且随时可重推补丁恢复
        let pragmas = ["PRAGMA cache_size = -32768;",
                       "PRAGMA temp_store = MEMORY;",
                       "PRAGMA synchronous = NORMAL;"]
        for p in pragmas { sqlite3_exec(db, p, nil, nil, nil) }
        defer { sqlite3_exec(db, "PRAGMA cache_size = -2000; PRAGMA temp_store = DEFAULT; PRAGMA synchronous = FULL;", nil, nil, nil) }

        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            outcome.message = "开启事务失败：\(String(cString: sqlite3_errmsg(db)))"
            return outcome
        }

        var failure: String?
        // 五张周期表（Task 2.3）：补丁携带 bkt_quarterly/bkt_yearly 后，季/年线也要跟上。
        // 主库缺该表 → 跳过；补丁缺该表 → 跳过（老补丁不含季/年线时行为与原来一致）。
        for table in ["daily", "weekly", "monthly", "quarterly", "yearly"] {
            guard tableExists(db: db, schema: "main", name: table),
                  tableExists(db: db, schema: "bkt", name: "bkt_" + table) else { continue }
            let sql = "INSERT OR REPLACE INTO \(table)(meta_id,date,open,high,low,close,vol,amo) "
                    + "SELECT m.id, b.date, b.open, b.high, b.low, b.close, b.vol, b.amo "
                    + "FROM bkt.bkt_\(table) b JOIN main.meta m ON m.file = b.file;"
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                failure = "写入 \(table) 失败：\(String(cString: sqlite3_errmsg(db)))"
                break
            }
            let written = Int(sqlite3_changes(db))
            switch table {
            case "daily":     outcome.dailyRows = written
            case "weekly":    outcome.weeklyRows = written
            case "quarterly": outcome.quarterlyRows = written
            case "yearly":    outcome.yearlyRows = written
            default:          outcome.monthlyRows = written
            }
        }

        // meta.last_date 语义 = **日线末日**（与 tdx_parser 里 `last_date = content[-1][:8]` 一致）
        // → 周/月线不改它。同样用一条集合式 SQL，不逐行 bind。
        // MAX(...) 兜底：补丁只含**旧日期**时（该 file 尾部无差异）不能让 last_date **回退**，
        // 否则下一轮「按缺口取片」会把已同步过的分片再取一遍。
        if failure == nil {
            let sql = "UPDATE meta SET last_date = "
                    + "MAX(COALESCE(last_date, 0), "
                    + "COALESCE((SELECT MAX(b.date) FROM bkt.bkt_daily b WHERE b.file = meta.file), 0)) "
                    + "WHERE file IN (SELECT DISTINCT file FROM bkt.bkt_daily);"
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                failure = "更新 meta.last_date 失败：\(String(cString: sqlite3_errmsg(db)))"
            }
        }

        if let failure = failure {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            outcome.ok = false
            outcome.dailyRows = 0
            outcome.weeklyRows = 0
            outcome.monthlyRows = 0
            outcome.quarterlyRows = 0
            outcome.yearlyRows = 0
            outcome.coveredFiles = 0
            outcome.skippedFiles = 0
            outcome.latestDate = 0
            outcome.message = "应用补丁失败（已回滚）：\(failure)"
            return outcome
        }
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            outcome.ok = false
            outcome.message = "提交失败（已回滚）：\(String(cString: sqlite3_errmsg(db)))"
            return outcome
        }
        outcome.ok = true
        outcome.message = "已按行写入主库 \(outcome.dailyRows + outcome.weeklyRows + outcome.monthlyRows + outcome.quarterlyRows + outcome.yearlyRows) 行"
            + "（日\(outcome.dailyRows)/周\(outcome.weeklyRows)/月\(outcome.monthlyRows)/季\(outcome.quarterlyRows)/年\(outcome.yearlyRows)）"
            + " · 覆盖 \(outcome.coveredFiles) 只 · 最新 \(outcome.latestDate)"
            + (outcome.skippedFiles > 0 ? " · 跳过(主库无此file) \(outcome.skippedFiles) 只" : "")
        return outcome
    }

    /// 指定 schema（`main` / `bkt`）下是否存在某张表
    /// （`fileprivate`：同文件的 `PatchSessionManager` 复用同一套存在性/取值判断）
    nonisolated fileprivate static func tableExists(db: OpaquePointer, schema: String, name: String) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM \(schema).sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// 取单值整数查询结果（无结果 / NULL 均返回 0）
    nonisolated fileprivate static func scalarInt(db: OpaquePointer, sql: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    /// GET /download/<file>：返回 Downloads 目录下的文件
    private func serveFile(_ filename: String, connection: NWConnection) {
        let safeName = (filename as NSString).lastPathComponent
        let filePath = downloadsPath + "/" + safeName
        guard FileManager.default.fileExists(atPath: filePath),
              let handle = FileHandle(forReadingAtPath: filePath) else {
            respond(connection, status: 404, body: "file not found")
            return
        }
        defer { try? handle.close() }
        let fileData = handle.readDataToEndOfFile()

        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "Content-Length: \(fileData.count)\r\n"
            + "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(fileData)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// 列出 Downloads 目录的 IPA 文件
    private func listIPAFiles() -> [[String: Any]] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: downloadsPath) else {
            return []
        }
        var result: [[String: Any]] = []
        for entry in entries where entry.lowercased().hasSuffix(".ipa") {
            let full = downloadsPath + "/" + entry
            let attrs = try? FileManager.default.attributesOfItem(atPath: full)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            result.append(["name": entry, "size": size])
        }
        return result
    }

    // MARK: - 工具

    private static func parseContentLength(from headerText: String) -> Int {
        for line in headerText.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    /// 从原始路径中取 query 参数值（如 /upload?name=tdx.db → "tdx.db"）
    private static func queryParam(_ rawPath: String, _ key: String) -> String? {
        guard let query = rawPath.split(separator: "?").last, query.contains("=") else { return nil }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, String(kv[0]) == key {
                return String(kv[1]).removingPercentEncoding
            }
        }
        return nil
    }

    /// 状态 JSON（供电脑侧部署助手检测"新版 Kline 已重新打开"并校验版本号）
    static func statusJSON() -> String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        let dn = info?["CFBundleDisplayName"] as? String ?? "Kline"
        let bid = Bundle.main.bundleIdentifier ?? "?"
        return "{\"status\":\"ok\",\"app\":\"Kline\",\"displayName\":\"\(Self.jsonEsc(dn))\","
            + "\"version\":\"\(Self.jsonEsc(v)) (\(Self.jsonEsc(b)))\",\"bundle\":\"\(Self.jsonEsc(bid))\"}"
    }

    private static func jsonEsc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func respond(_ connection: NWConnection, status: Int, contentType: String = "text/plain", body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default: statusText = "Error"
        }
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(statusText)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(bodyData)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - /sync/apply-patch 结果契约

/// 补丁 → 主库的执行结果（在 `DatabaseManager.dbQueue` 上产出，回主线程用于拼响应 JSON）。
/// 用元组别名而非结构体：避免默认 MainActor 隔离下在非主线程上下文构造类型的额外约束。
private typealias PatchApplyOutcome = (
    ok: Bool,
    dailyRows: Int,
    weeklyRows: Int,
    monthlyRows: Int,
    quarterlyRows: Int,
    yearlyRows: Int,
    coveredFiles: Int,
    skippedFiles: Int,
    latestDate: Int,
    message: String
)

// MARK: - 会话式单事务落主库（Task 5）

/// 会话状态：**一条独立 sqlite3 连接** + 进度时间戳 + 累计计数。
/// `nonisolated`：只在 `PatchSessionManager.queue` 上读写（默认 MainActor 隔离下需显式放开）。
nonisolated final class PatchSessionState {
    let db: OpaquePointer
    /// 主库路径（用于插桩读取 `-wal` 文件大小，判断 checkpoint 规模）
    let dbPath: String
    var lastProgress: DispatchTime
    var shardCount = 0
    var coveredFiles = 0
    var skippedFiles = 0
    var dailyRows = 0
    var weeklyRows = 0
    var monthlyRows = 0
    var quarterlyRows = 0
    var yearlyRows = 0
    var latestDate = 0
    init(db: OpaquePointer, dbPath: String) {
        self.db = db
        self.dbPath = dbPath
        self.lastProgress = DispatchTime.now()
    }
}

/// 会话单步结果（元组别名：避免默认 MainActor 隔离下在非主线程上下文构造类型的额外约束）
typealias PatchSessionResult = (ok: Bool, message: String)
/// 会话提交结果（含 commit 返回的合计行数 / 覆盖标的数 / 片数 / 最新交易日）
typealias PatchSessionCommitResult = (
    ok: Bool, message: String,
    dailyRows: Int, weeklyRows: Int, monthlyRows: Int, quarterlyRows: Int, yearlyRows: Int,
    coveredFiles: Int, shardCount: Int, latestDate: Int
)

/// 会话式单事务落主库的管理器（Task 5）：用**一条独立连接**跨多个 HTTP 请求保持一个写事务，
/// 使设备落库与 PC 出包**完全重叠**（PC 出第 i+1 片的同时设备在 apply 第 i 片）。
///
/// **连接隔离是硬要求**：本管理器用 `sqlite3_open_v2` 自开一条连接打开同一个主库路径，
/// 会话的全部 SQL（ATTACH / 写五表 / 更新 last_date / COMMIT / ROLLBACK）都只在这条连接上执行；
/// **不走** `DatabaseManager.performOnDBQueue`——那条连接属于 App，在它上面开事务会把 App 期间的
/// 所有写操作**静默卷进我们的事务**，回滚时一起丢。
///
/// 状态只在 `queue` 上读写 → 天然串行，不会与 App 的 dbQueue 争用同一连接。
/// 主库是 WAL：长写事务**不阻塞读**，但会阻塞其它**写**（拿 SQLITE_BUSY），故有 120s 看门狗兜底。
nonisolated final class PatchSessionManager {
    static let shared = PatchSessionManager()

    /// 会话专用串行队列：保护会话状态（连接句柄 / 计时 / 计数），也保证同一时刻只有一步在跑。
    private let queue = DispatchQueue(label: "com.sunck.Kline.patchsession")

    /// 看门狗超时：120s（2 分钟）。取 2 分钟而非更短：冷缓存下 PC 单分片出包 / 设备单分片写入
    /// 都可能到十几秒，30s 会误杀「正常但慢」的会话；2 分钟给足余量，同时仍能兜住真正被遗弃的会话。
    private static let watchdogTimeout: Double = 120

    private var session: PatchSessionState?

    private init() {}

    // MARK: - begin

    /// 打开独立连接 + 会话级 pragma + BEGIN IMMEDIATE，把连接与会话状态存下、启动看门狗。
    /// 若已有活跃会话 → **先 ROLLBACK 旧会话**（选「自动回滚旧会话」而非报错，避免半开连接占着写锁）。
    func begin(dbPath: String, completion: @escaping (PatchSessionResult) -> Void) {
        queue.async {
            if let old = self.session {
                self.teardownLocked(old, rollback: true, reason: "被新会话 begin 顶替")
            }
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            guard sqlite3_open_v2(dbPath, &handle, flags, nil) == SQLITE_OK, let db = handle else {
                let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open 失败"
                if let h = handle { sqlite3_close(h) }
                DebugLogger.shared.log("[Patch] 会话 begin 打开主库失败：\(msg)")
                self.replyMain((ok: false, message: "打开主库连接失败：\(msg)"), completion)
                return
            }
            // 会话级 pragma（不改变库文件属性）：cache_size 32MB / temp_store 内存 / synchronous NORMAL
            // `wal_autocheckpoint = 0`：**真机实测（2026-09-23）的关键改动** —— 本会话一个大事务累积
            // ~215MB WAL，默认 autocheckpoint（1000 页 = 4MB）会让 SQLite 在 **COMMIT 语句内部**做一次
            // 全量 PASSIVE checkpoint（把 215MB 回写主库），实测 COMMIT 因此高达 **13829ms**（另见
            // close=8ms / UPDATE=62ms，即 12s 全在 COMMIT 这一步）。置 0 后 COMMIT 只追加提交记录，
            // 写响应不再等这次大回写；WAL 回写改由响应之后的 `deferredWALCheckpoint()` 异步补齐。
            //
            // `journal_size_limit = 64MB`：**连接级**设置（本地实测：新连接读回 -1，不随库文件持久化），
            // 故两条会发生「WAL 复位→截断」的路径各自的连接上都要设：这里（提交时日志复位）与
            // `deferredWALCheckpoint()` 的短连接（回写完成时复位）。它只在日志复位时裁剪文件大小，
            // 不限制事务期内的 WAL 增长 → 不影响 COMMIT 延迟。
            for p in ["PRAGMA cache_size = -32768;",
                      "PRAGMA temp_store = MEMORY;",
                      "PRAGMA synchronous = NORMAL;",
                      "PRAGMA wal_autocheckpoint = 0;",
                      "PRAGMA journal_size_limit = 67108864;"] {
                sqlite3_exec(db, p, nil, nil, nil)
            }
            // 会话临时表（TEMP 只属于本连接、随连接关闭消失）：各片 apply 时累积「file → 该片最大日期」，
            // commit 时据此更新 meta.last_date（无需知道各片的挂载别名，逻辑与单包 apply-patch 等价）。
            sqlite3_exec(db, "CREATE TEMP TABLE IF NOT EXISTS patch_file_max(file TEXT PRIMARY KEY, last_date INTEGER);",
                         nil, nil, nil)
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                sqlite3_close(db)
                DebugLogger.shared.log("[Patch] 会话 begin BEGIN IMMEDIATE 失败：\(msg)")
                self.replyMain((ok: false, message: "开启事务失败：\(msg)"), completion)
                return
            }
            let st = PatchSessionState(db: db, dbPath: dbPath)
            self.session = st
            self.armWatchdogLocked(st)
            DebugLogger.shared.log("[Patch] 会话 begin：已开独立连接并 BEGIN IMMEDIATE · \(dbSizeDesc(dbPath))")
            self.replyMain((ok: true, message: "会话已开启（独立连接 · BEGIN IMMEDIATE）"), completion)
        }
    }

    // MARK: - apply

    /// 在会话连接上 ATTACH 该片（唯一别名）→ 写**五张表** → 累积 last_date。可被多次调用（每片一次）。
    ///
    /// ⚠️ 与 spec 措辞的偏差（实测 SQLite 3.40.1）：**在活跃事务内 `DETACH` 会返回
    /// `SQLITE_LOCKED: database bkt is locked`**（无论该片是否被读过）。本会话是「一个事务跨多个
    /// HTTP 请求」，因此每片的 DETACH **不能**在事务内做 → 改为：每片用**唯一别名** `bkt<seq>`
    /// 保持挂载，直到会话结束时随连接关闭一并释放（`sqlite3_close` 隐式 DETACH）。
    /// 代价：同一会话最多同时挂载 N 个片（SQLite 默认 `SQLITE_MAX_ATTACHED=10`，N≤6 足够）。
    ///
    /// 每次成功后刷新看门狗计时；任一步失败 → 整体 ROLLBACK + 关连接，返回原因（含失败片名）。
    func applyShard(name: String, path: String, completion: @escaping (PatchSessionResult) -> Void) {
        queue.async {
            let t0 = DispatchTime.now()
            guard let st = self.session else {
                self.replyMain((ok: false, message: "无活跃会话（请先 POST /sync/patch-session/begin）"), completion)
                return
            }
            if let failure = Self.applyShardLocked(st, name: name, path: path) {
                self.teardownLocked(st, rollback: true, reason: "apply \(name) 失败")
                self.replyMain((ok: false, message: failure), completion)
                return
            }
            st.lastProgress = DispatchTime.now()   // 刷新看门狗计时
            DebugLogger.shared.log("[Patch] 会话 apply 片 \(name) 完成（累计 \(st.shardCount) 片）"
                + " · 写库耗时=\(elapsedMsSince(t0))ms · \(dbSizeDesc(st.dbPath))")
            self.replyMain((ok: true, message: "已写入片 \(name)（累计 \(st.shardCount) 片）"), completion)
        }
    }

    // MARK: - commit

    /// UPDATE meta.last_date（MAX 防回退）→ COMMIT → 关连接。返回合计行数/覆盖标的数/片数/最新日期。
    /// 成功后由调用方（主线程）重读 metaList + 自增 dataVersion。
    func commit(completion: @escaping (PatchSessionCommitResult) -> Void) {
        queue.async {
            let t0 = DispatchTime.now()
            guard let st = self.session else {
                self.replyCommitMain((ok: false, message: "无活跃会话（请先 POST /sync/patch-session/begin）",
                                      dailyRows: 0, weeklyRows: 0, monthlyRows: 0, quarterlyRows: 0, yearlyRows: 0,
                                      coveredFiles: 0, shardCount: 0, latestDate: 0), completion)
                return
            }
            guard st.shardCount > 0 else {
                // 空会话（没喂入任何片）→ 直接回滚关连接，避免「空提交」也自增 dataVersion
                self.teardownLocked(st, rollback: true, reason: "commit 时无已应用分片")
                self.replyCommitMain((ok: false, message: "会话中没有任何已应用分片",
                                      dailyRows: 0, weeklyRows: 0, monthlyRows: 0, quarterlyRows: 0, yearlyRows: 0,
                                      coveredFiles: 0, shardCount: 0, latestDate: 0), completion)
                return
            }
            // meta.last_date 语义 = **日线末日**；用会话临时表（各片 apply 时累积）做 MAX(...) 防回退，
            // 与单包 apply-patch 的 `MAX(COALESCE(last_date,0), 补丁该 file 最大日期)` 等价。
            let sql = "UPDATE meta SET last_date = "
                    + "MAX(COALESCE(last_date, 0), "
                    + "COALESCE((SELECT t.last_date FROM temp.patch_file_max t WHERE t.file = meta.file), 0)) "
                    + "WHERE file IN (SELECT file FROM temp.patch_file_max);"
            DebugLogger.shared.log("[Patch] commit 步前：\(dbSizeDesc(st.dbPath))"
                + " · 队列排队=\(elapsedMsSince(t0))ms")
            let tUpdate = DispatchTime.now()
            if sqlite3_exec(st.db, sql, nil, nil, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(st.db))
                self.teardownLocked(st, rollback: true, reason: "commit 更新 last_date 失败")
                self.replyCommitMain((ok: false, message: "更新 meta.last_date 失败（已回滚）：\(msg)",
                                      dailyRows: 0, weeklyRows: 0, monthlyRows: 0, quarterlyRows: 0, yearlyRows: 0,
                                      coveredFiles: 0, shardCount: 0, latestDate: 0), completion)
                return
            }
            let updateMs = elapsedMsSince(tUpdate)
            let tCommit = DispatchTime.now()
            if sqlite3_exec(st.db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(st.db))
                self.teardownLocked(st, rollback: true, reason: "commit 提交失败")
                self.replyCommitMain((ok: false, message: "提交失败（已回滚）：\(msg)",
                                      dailyRows: 0, weeklyRows: 0, monthlyRows: 0, quarterlyRows: 0, yearlyRows: 0,
                                      coveredFiles: 0, shardCount: 0, latestDate: 0), completion)
                return
            }
            let commitMs = elapsedMsSince(tCommit)
            let walAfterCommit = fileSizeMB(st.dbPath + "-wal")
            let message = "已提交 \(st.shardCount) 片 · 合计 \(st.dailyRows + st.weeklyRows + st.monthlyRows + st.quarterlyRows + st.yearlyRows) 行"
                + "（日\(st.dailyRows)/周\(st.weeklyRows)/月\(st.monthlyRows)/季\(st.quarterlyRows)/年\(st.yearlyRows)）"
                + " · 覆盖 \(st.coveredFiles) 只 · 最新 \(st.latestDate)"
                + (st.skippedFiles > 0 ? " · 跳过(主库无此file) \(st.skippedFiles) 只" : "")
            let result: PatchSessionCommitResult = (ok: true, message: message,
                                                    dailyRows: st.dailyRows, weeklyRows: st.weeklyRows,
                                                    monthlyRows: st.monthlyRows, quarterlyRows: st.quarterlyRows,
                                                    yearlyRows: st.yearlyRows, coveredFiles: st.coveredFiles,
                                                    shardCount: st.shardCount, latestDate: st.latestDate)
            let closeMs = self.teardownLocked(st, rollback: false, reason: "commit 成功")
            DebugLogger.shared.log("[Patch] commit 分解：队列排队=\(elapsedMsSince(t0) - updateMs - commitMs - closeMs)ms"
                + " · UPDATE meta.last_date=\(updateMs)ms · COMMIT=\(commitMs)ms"
                + " · sqlite3_close(含 WAL checkpoint)=\(closeMs)ms"
                + " · 会话队列合计=\(elapsedMsSince(t0))ms"
                + " · COMMIT 后 WAL=\(String(format: "%.1f", walAfterCommit))MB"
                + " · 关闭后 \(dbSizeDesc(st.dbPath))")
            DebugLogger.shared.log("[Patch] 会话 commit：片=\(result.shardCount) 覆盖=\(result.coveredFiles) 最新=\(result.latestDate)")
            self.replyCommitMain(result, completion)
        }
    }

    // MARK: - rollback

    /// ROLLBACK + 关连接（释放写锁，已喂入的片全部丢弃）。
    func rollback(reason: String, completion: @escaping (PatchSessionResult) -> Void) {
        queue.async {
            guard let st = self.session else {
                self.replyMain((ok: false, message: "无活跃会话"), completion)
                return
            }
            self.teardownLocked(st, rollback: true, reason: reason)
            self.replyMain((ok: true, message: "会话已回滚并关闭连接（\(reason)）"), completion)
        }
    }

    // MARK: - 看门狗

    /// `watchdogTimeout` 内无进展 → 自动 ROLLBACK + 关连接（释放写锁）。
    /// 每次成功 apply 刷新 `st.lastProgress`，这里按「剩余时间」重新计时。
    private func armWatchdogLocked(_ st: PatchSessionState) {
        queue.asyncAfter(deadline: .now() + Self.watchdogTimeout) { [weak self] in
            guard let self = self, self.session === st else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - st.lastProgress.uptimeNanoseconds) / 1_000_000_000
            if elapsed < Self.watchdogTimeout {
                self.armWatchdogLocked(st)   // 期间有进展 → 按剩余时间重新计时
                return
            }
            DebugLogger.shared.log("[Patch] 会话看门狗触发：\(Int(elapsed))s 无进展 → 自动回滚关连接")
            self.teardownLocked(st, rollback: true, reason: "看门狗超时")
        }
    }

    // MARK: - 内部（全部在 queue 上）

    /// ATTACH（唯一别名）+ 写五张表 + 累积 last_date（全在会话连接上、同一未提交事务内）。
    /// 返回 nil 表示成功，否则返回失败原因（含失败片名）。
    /// ⚠️ **不在事务内 DETACH**（SQLite 会报 `database ... is locked`）；别名保持到连接关闭时隐式释放。
    private static func applyShardLocked(_ st: PatchSessionState, name: String, path: String) -> String? {
        // 每片一个唯一别名，避免同一会话内多次 ATTACH 同名冲突
        let alias = "bkt" + String(st.shardCount)
        // ATTACH 路径里的单引号必须转义（同 LiveDataStore / applyPatchLocked）
        let escaped = path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(st.db, "ATTACH DATABASE '\(escaped)' AS \(alias);", nil, nil, nil) == SQLITE_OK else {
            return "片 \(name) ATTACH 失败：\(String(cString: sqlite3_errmsg(st.db)))"
        }

        guard KlineHTTPServer.tableExists(db: st.db, schema: alias, name: "bkt_daily") else {
            return "片 \(name) 缺少 bkt_daily 表"
        }
        let patchFiles = KlineHTTPServer.scalarInt(db: st.db, sql: "SELECT COUNT(DISTINCT file) FROM \(alias).bkt_daily;")
        let covered = KlineHTTPServer.scalarInt(db: st.db,
            sql: "SELECT COUNT(DISTINCT b.file) FROM \(alias).bkt_daily b JOIN main.meta m ON m.file = b.file;")
        let latest = KlineHTTPServer.scalarInt(db: st.db, sql: "SELECT MAX(date) FROM \(alias).bkt_daily;")

        // 五张周期表各一条集合式 SQL（映射键 = file；主库缺该表 / 补丁缺该表 → 跳过）
        for table in ["daily", "weekly", "monthly", "quarterly", "yearly"] {
            guard KlineHTTPServer.tableExists(db: st.db, schema: "main", name: table),
                  KlineHTTPServer.tableExists(db: st.db, schema: alias, name: "bkt_" + table) else { continue }
            let sql = "INSERT OR REPLACE INTO \(table)(meta_id,date,open,high,low,close,vol,amo) "
                    + "SELECT m.id, b.date, b.open, b.high, b.low, b.close, b.vol, b.amo "
                    + "FROM \(alias).bkt_\(table) b JOIN main.meta m ON m.file = b.file;"
            guard sqlite3_exec(st.db, sql, nil, nil, nil) == SQLITE_OK else {
                return "片 \(name) 写入 \(table) 失败：\(String(cString: sqlite3_errmsg(st.db)))"
            }
            let written = Int(sqlite3_changes(st.db))
            switch table {
            case "daily":     st.dailyRows += written
            case "weekly":    st.weeklyRows += written
            case "quarterly": st.quarterlyRows += written
            case "yearly":    st.yearlyRows += written
            default:          st.monthlyRows += written
            }
        }
        // 累积「file → 该片最大日期」到会话临时表（供 commit 更新 meta.last_date；各片不相交，
        // UPSERT 取 MAX 只为稳妥，防止同 file 出现在多片时被较小值覆盖）
        let upsert = "INSERT INTO temp.patch_file_max(file, last_date) "
            + "SELECT b.file, MAX(b.date) FROM \(alias).bkt_daily b JOIN main.meta m ON m.file = b.file GROUP BY b.file "
            + "ON CONFLICT(file) DO UPDATE SET last_date = MAX(last_date, excluded.last_date);"
        if sqlite3_exec(st.db, upsert, nil, nil, nil) != SQLITE_OK {
            return "片 \(name) 累积 last_date 失败：\(String(cString: sqlite3_errmsg(st.db)))"
        }
        st.shardCount += 1
        st.coveredFiles += covered
        st.skippedFiles += max(0, patchFiles - covered)
        st.latestDate = max(st.latestDate, latest)
        return nil
    }

    /// 结束会话：可选 ROLLBACK → 关连接（`sqlite3_close` 会隐式 DETACH 所有已挂载的片）→ 清空会话（幂等）。
    /// 所有调用都在 `queue` 上。返回 `sqlite3_close` 的耗时（ms），供插桩定位 WAL checkpoint 开销。
    @discardableResult
    private func teardownLocked(_ st: PatchSessionState, rollback: Bool, reason: String) -> Int {
        let walBefore = fileSizeMB(st.dbPath + "-wal")
        if rollback {
            sqlite3_exec(st.db, "ROLLBACK;", nil, nil, nil)
        }
        let tClose = DispatchTime.now()
        sqlite3_close(st.db)
        let closeMs = elapsedMsSince(tClose)
        if self.session === st { self.session = nil }
        DebugLogger.shared.log("[Patch] 会话关闭（\(reason)）：\(rollback ? "已回滚" : "已提交")"
            + " · close=\(closeMs)ms · 关前 WAL=\(String(format: "%.1f", walBefore))MB")
        return closeMs
    }

    /// 把会话结果回主线程交付（避免调用方在非主线程触碰 App 状态 / 写响应）
    private func replyMain(_ r: PatchSessionResult, _ completion: @escaping (PatchSessionResult) -> Void) {
        DispatchQueue.main.async { completion(r) }
    }

    private func replyCommitMain(_ r: PatchSessionCommitResult,
                                 _ completion: @escaping (PatchSessionCommitResult) -> Void) {
        DispatchQueue.main.async { completion(r) }
    }
}

// MARK: - 插桩工具（`[Patch]` 前缀日志共用；文件级 nonisolated，供同文件的 PatchSessionManager 调用）

/// 距 `t` 的毫秒数
nonisolated func elapsedMsSince(_ t: DispatchTime) -> Int {
    Int((DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000)
}

/// 文件大小（MB）；不存在返回 0
nonisolated func fileSizeMB(_ path: String) -> Double {
    let n = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
    return Double(n?.int64Value ?? 0) / 1_048_576.0
}

/// 「主库=X MB WAL=Y MB」描述（判断 checkpoint 规模用）
nonisolated func dbSizeDesc(_ dbPath: String) -> String {
    String(format: "主库=%.1fMB WAL=%.1fMB", fileSizeMB(dbPath), fileSizeMB(dbPath + "-wal"))
}

/// 执行**一次** `PRAGMA wal_checkpoint(<mode>)`，返回 `(rc, busy, log 字节, 已回写字节)`。
/// 该 pragma 返回一行 `(busy, log, checkpointed)`，后两列单位是**页**，按库的 page_size 折算成字节。
/// PASSIVE 不会等读者（拿不到就只回写一部分、busy 恒 0）；TRUNCATE 需要独占全部读者/写者槽位，
/// 有活跃写事务时返回 `busy=1`（是否阻塞等待取决于该连接自己的 `busy_timeout`）。
nonisolated func walCheckpoint(db: OpaquePointer, mode: String)
    -> (rc: Int32, busy: Int, logBytes: Int, ckptBytes: Int) {
    let pageSize = walPageSize(db: db)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA wal_checkpoint(\(mode));", -1, &statement, nil) == SQLITE_OK else {
        return (sqlite3_errcode(db), -1, 0, 0)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return (sqlite3_errcode(db), -1, 0, 0) }
    return (SQLITE_OK,
            Int(sqlite3_column_int64(statement, 0)),
            Int(sqlite3_column_int64(statement, 1)) * pageSize,
            Int(sqlite3_column_int64(statement, 2)) * pageSize)
}

/// 库的 page_size（字节）；读不到时按 SQLite 默认 4096
nonisolated func walPageSize(db: OpaquePointer) -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA page_size;", -1, &statement, nil) == SQLITE_OK else { return 4096 }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return 4096 }
    let n = Int(sqlite3_column_int64(statement, 0))
    return n > 0 ? n : 4096
}

// MARK: - URL 参数编码

extension String {
    /// 用于 URL query 参数值的安全编码（保留 RFC 3986 unreserved 字符）
    var percentEncodedForQuery: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

// MARK: - RootRunner（方案A：以 root 运行子进程，对应 TrollStore 的 spawnRoot）

// persona 私有函数：这些符号未导出动态符号表，dlsym 取不到，需用 @_silgen_name 让链接器
// 直接解析（与 TrollStore 的 ObjC 直接链接一致），底层来自 libSystem。
@_silgen_name("posix_spawnattr_set_persona_np")
private func rrSetPersona(_ attr: UnsafeMutableRawPointer!, _ id: Int32, _ flags: UInt32) -> Int32
@_silgen_name("posix_spawnattr_set_persona_uid_np")
private func rrSetUid(_ attr: UnsafeMutableRawPointer!, _ uid: UInt32) -> Int32
@_silgen_name("posix_spawnattr_set_persona_gid_np")
private func rrSetGid(_ attr: UnsafeMutableRawPointer!, _ gid: UInt32) -> Int32

/// 以 root（persona 99 + uid/gid 0）spawn 子进程。
///
/// 需要调用方具备 `com.apple.private.persona-mgmt`（已注入 Kline.entitlements）。
/// iOS SDK 里 posix_spawnattr_t 等被桥接为不透明指针，且 persona 函数为私有符号，
/// 故全部经 `dlsym` 取符号 + 统一用 `OpaquePointer` 传参，避免依赖具体类型桥接而编译失败。
enum RootRunner {

    private static func load<F>(_ name: String) -> F? {
        // 注意：Apple 的 RTLD_DEFAULT 是 (void*)-2，不是 NULL；dlsym(nil,…) 全局搜索会失效。
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: F.self)
    }

    /// 以 root spawn 一条命令并捕获 stdout/stderr。
    /// - Returns: (code, stdout, stderr)。spawn 本身失败时 code 为 posix 错误码（>0，如 2=ENOENT）。
    @discardableResult
    static func spawnRoot(executable: String, arguments: [String] = []) -> (code: Int32, stdout: String, stderr: String) {
        typealias SpawnFn = @convention(c) (UnsafeMutablePointer<pid_t>?, UnsafePointer<CChar>?, OpaquePointer?, OpaquePointer?, UnsafePointer<UnsafeMutablePointer<CChar>?>?, UnsafePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        typealias AttrFn = @convention(c) (OpaquePointer) -> Int32
        typealias AddDupFn = @convention(c) (OpaquePointer, Int32, Int32) -> Int32
        typealias AddCloseFn = @convention(c) (OpaquePointer, Int32) -> Int32

        guard let spawnFn: SpawnFn = load("posix_spawn"),
              let attrInit: AttrFn = load("posix_spawnattr_init"),
              let actInit: AttrFn = load("posix_spawn_file_actions_init"),
              let addDup: AddDupFn = load("posix_spawn_file_actions_adddup2"),
              let addClose: AddCloseFn = load("posix_spawn_file_actions_addclose") else {
            // 软失败：任一必需符号缺失时返回错误串（并列出具体缺失，便于诊断），不要闪退
            let std = ["posix_spawn", "posix_spawnattr_init", "posix_spawnattr_destroy",
                       "posix_spawn_file_actions_init", "posix_spawn_file_actions_destroy",
                       "posix_spawn_file_actions_adddup2", "posix_spawn_file_actions_addclose"]
            let missing = std.filter { dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0) == nil }
            return (-200, "", "MISSING: " + (missing.isEmpty ? "?" : missing.joined(separator: ",")))
        }
        let attrDestroy: AttrFn? = load("posix_spawnattr_destroy")
        let actDestroy: AttrFn? = load("posix_spawn_file_actions_destroy")

        var args = arguments
        args.insert(executable, at: 0)
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        // attr / actions：分配一块不透明缓冲区（opaque 结构体实际远小于 512B）
        let attr = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 16)
        let actions = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 16)
        attrInit(OpaquePointer(attr))
        actInit(OpaquePointer(actions))
        defer {
            attrDestroy?(OpaquePointer(attr))
            actDestroy?(OpaquePointer(actions))
            attr.deallocate()
            actions.deallocate()
        }

        // persona 99 + uid/gid 0（POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE = 0；符号经链接器直接解析）
        rrSetPersona(attr, 99, 0)
        rrSetUid(attr, 0)
        rrSetGid(attr, 0)

        // 捕获 stdout/stderr
        var pipeOut = [Int32](repeating: -1, count: 2)
        var pipeErr = [Int32](repeating: -1, count: 2)
        pipe(&pipeOut)
        pipe(&pipeErr)
        addDup(OpaquePointer(actions), pipeOut[1], STDOUT_FILENO)
        addDup(OpaquePointer(actions), pipeErr[1], STDERR_FILENO)
        addClose(OpaquePointer(actions), pipeOut[0])
        addClose(OpaquePointer(actions), pipeErr[0])
        addClose(OpaquePointer(actions), pipeOut[1])
        addClose(OpaquePointer(actions), pipeErr[1])

        var pid: pid_t = 0
        let spawnErr = spawnFn(&pid, executable, OpaquePointer(actions), OpaquePointer(attr), argv, nil)
        // 父进程关闭写端（子进程已继承），开始读取
        close(pipeOut[1]); close(pipeErr[1])
        guard spawnErr == 0 else {
            close(pipeOut[0]); close(pipeErr[0])
            return (spawnErr, "", "posix_spawn error \(spawnErr)")
        }

        var outData = Data()
        var errData = Data()
        readAll(pipeOut[0], into: &outData)
        readAll(pipeErr[0], into: &errData)
        close(pipeOut[0]); close(pipeErr[0])

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let code = (status >> 8) & 0xff
        return (code,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }

    /// 便捷：spawn 内嵌的 rootprobe 助手，确认是否真的拿到 root（方案A 阶段1/2 验收）。
    /// rootprobe 由 CI 编译嵌入 Kline.app，以【退出码】表达结果：0=已拿到 root，1=非 root。
    static func verifyRoot() -> String {
        let exe = Bundle.main.bundlePath + "/rootprobe"
        let r = spawnRoot(executable: exe, arguments: [])
        if r.code == 0 {
            return "⬇ CODE=0 => UID=0 (ROOT 已拿到)"
        } else {
            return "CODE=\(r.code) => 非 root（期望 0） stdout=[\(r.stdout)] stderr=[\(r.stderr)]"
        }
    }

    /// fire-and-forget：以 root（persona 99）后台 spawn 一个独立进程并立即返回（不等待、不读输出）。
    /// 用于 spawn opener 这类“与 App 生命周期无关、须在 App 被终止后依然存活”的守护。
    @discardableResult
    static func spawnDetached(executable: String, arguments: [String] = []) -> Int32 {
        typealias SpawnFn = @convention(c) (UnsafeMutablePointer<pid_t>?, UnsafePointer<CChar>?, OpaquePointer?, OpaquePointer?, UnsafePointer<UnsafeMutablePointer<CChar>?>?, UnsafePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        typealias AttrFn = @convention(c) (OpaquePointer) -> Int32
        guard let spawnFn: SpawnFn = load("posix_spawn"),
              let attrInit: AttrFn = load("posix_spawnattr_init") else { return -100 }

        var args = arguments
        args.insert(executable, at: 0)
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        let attr = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 16)
        defer { attr.deallocate() }
        attrInit(OpaquePointer(attr))

        // persona 99 + uid/gid 0（继承 symbol 直接链接）
        rrSetPersona(attr, 99, 0)
        rrSetUid(attr, 0)
        rrSetGid(attr, 0)

        var pid: pid_t = 0
        let sr = spawnFn(&pid, executable, nil, OpaquePointer(attr), argv, nil)
        // 不回读、不 waitpid：让子进程（opener）独立存活，成为孤儿由 launchd 收养。
        DebugLogger.shared.log("spawnDetached \(executable) args=\(arguments) => sr=\(sr) pid=\(pid)")
        _ = pid
        return sr
    }

    /// 阻塞读满 fd 到 Data（子进程退出/EOF 结束）。
    /// 用 withUnsafeMutableBytes 取得真实连续内存指针，避免 Swift 数组桥接导致读不到数据。
    private static func readAll(_ fd: Int32, into data: inout Data) {
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                read(fd, raw.baseAddress!, raw.count)
            }
            if n <= 0 { return }
            data.append(contentsOf: buf.prefix(n))
        }
    }
}

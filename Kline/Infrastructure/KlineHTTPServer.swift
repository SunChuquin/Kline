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
        case ("GET", "/sync/status"):
            // 增量库当前状态（供推送脚本与排查使用）
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.respond(connection, status: 200, contentType: "application/json",
                             body: LiveDataStore.shared.currentStatusJSON())
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
        defer { try? handle.close() }
        let data = handle.readDataToEndOfFile()
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(data)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
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

    // MARK: - 补丁 → 主库（全部在 DatabaseManager.dbQueue 上）

    /// ATTACH 补丁包 → 单事务 → 三张周期表各**一条集合式 SQL**（`INSERT OR REPLACE ... SELECT`，
    /// 映射键 = `file`）→ 一条集合式 SQL 更新 `meta.last_date` → COMMIT / DETACH。
    /// 任一步失败：ROLLBACK，主库原样，返回原因。**不触碰增量库、不整库替换**。
    nonisolated private static func applyPatchLocked(db: OpaquePointer?, patchPath: String) -> PatchApplyOutcome {
        var outcome: PatchApplyOutcome = (false, 0, 0, 0, 0, 0, 0, "")
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
        for table in ["daily", "weekly", "monthly"] {
            // 主库缺该表 → 跳过；补丁缺该表 → 跳过（季/年线不参与）
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
            case "daily":   outcome.dailyRows = written
            case "weekly":  outcome.weeklyRows = written
            default:        outcome.monthlyRows = written
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
        outcome.message = "已按行写入主库 \(outcome.dailyRows + outcome.weeklyRows + outcome.monthlyRows) 行"
            + "（日\(outcome.dailyRows)/周\(outcome.weeklyRows)/月\(outcome.monthlyRows)）"
            + " · 覆盖 \(outcome.coveredFiles) 只 · 最新 \(outcome.latestDate)"
            + (outcome.skippedFiles > 0 ? " · 跳过(主库无此file) \(outcome.skippedFiles) 只" : "")
        return outcome
    }

    /// 指定 schema（`main` / `bkt`）下是否存在某张表
    nonisolated private static func tableExists(db: OpaquePointer, schema: String, name: String) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM \(schema).sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// 取单值整数查询结果（无结果 / NULL 均返回 0）
    nonisolated private static func scalarInt(db: OpaquePointer, sql: String) -> Int {
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
    coveredFiles: Int,
    skippedFiles: Int,
    latestDate: Int,
    message: String
)

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

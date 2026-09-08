//
//  KlineHTTPServer.swift
//  Kline
//
//  Created on 2026/9/7.
//

import Foundation
import Network
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
final class KlineHTTPServer {
    static let shared = KlineHTTPServer()

    /// 监听端口
    let port: UInt16 = 5051

    /// 公共 Downloads 目录（no-sandbox 生效时可读）
    private let downloadsPath = "/var/mobile/Media/Downloads"

    private let queue = DispatchQueue(label: "com.sunck.Kline.httpserver")
    private var listener: NWListener?

    /// 服务器是否就绪（监听中）——供 UI 显示连接状态
    private(set) var isRunning = false

    private init() {}

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
                    self.isRunning = true
                    DebugLogger.shared.log("KlineHTTPServer ready: 0.0.0.0:\(self.port)")
                case .failed(let error):
                    self.isRunning = false
                    DebugLogger.shared.log("KlineHTTPServer failed: \(error)")
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
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
        respond(connection, status: 200, contentType: "application/json", body: "{\"ok\":true}")
    }

    /// 构造「本地 HTTP 文件 → TrollStore 安装」的 URL Scheme
    static func trollStoreInstallURL(localFile: String, port: UInt16) -> String {
        let downloadURL = "http://127.0.0.1:\(port)/download/\(localFile.percentEncodedForQuery)"
        return "apple-magnifier://install?url=\(downloadURL.percentEncodedForQuery)"
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
        guard let sym = dlsym(nil, name) else { return nil }
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
            // 软失败：任一必需符号缺失时返回错误串，不要闪退
            return (-200, "", "required symbol(s) not found")
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

    /// 便捷：spawn /usr/bin/id 确认是否真的拿到 root（方案A 阶段1 验收）
    static func verifyRoot() -> String {
        let r = spawnRoot(executable: "/usr/bin/id", arguments: [])
        return "code=\(r.code) out=[\(r.stdout)] err=[\(r.stderr)]"
    }

    /// 阻塞读满 fd 到 Data（子进程退出/EOF 结束）
    private static func readAll(_ fd: Int32, into data: inout Data) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, 4096)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
    }
}

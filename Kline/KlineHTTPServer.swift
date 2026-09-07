//
//  KlineHTTPServer.swift
//  Kline
//
//  Created on 2026/9/7.
//

import Foundation
import Network
import UIKit

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

    private init() {}

    /// 启动服务器（幂等，重复调用不重复监听）
    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNew(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    DebugLogger.shared.log("KlineHTTPServer ready: 0.0.0.0:\(self?.port ?? 0)")
                case .failed(let error):
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
                        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath
                        let contentLength = Self.parseContentLength(from: headerText)

                        state.headerParsed = true
                        state.method = method
                        state.path = path
                        state.contentLength = contentLength

                        // /upload：流式写盘到公共 Downloads（大文件不缓存内存）
                        if (method == "POST" || method == "PUT"), path == "/upload" {
                            state.isUpload = true
                            let name = Self.queryParam(rawPath, "name") ?? "upload.bin"
                            let safeName = (name as NSString).lastPathComponent
                            let targetPath = downloadsPath + "/" + safeName
                            FileManager.default.createFile(atPath: targetPath, contents: nil)
                            state.uploadHandle = FileHandle(forWritingAtPath: targetPath)
                            DebugLogger.shared.log("上传开始: \(targetPath) len=\(contentLength)")
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
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath

        switch (method, path) {
        case ("GET", "/"):
            respond(connection, status: 200, contentType: "application/json",
                    body: "{\"status\":\"ok\",\"app\":\"Kline\"}")
        case ("GET", "/files"):
            let files = listIPAFiles()
            let json = (try? JSONSerialization.data(withJSONObject: files)) ?? Data("[]".utf8)
            respond(connection, status: 200, contentType: "application/json",
                    body: String(data: json, encoding: .utf8) ?? "[]")
        case ("POST", "/install"):
            handleInstall(body: body, connection: connection)
        case ("POST", "/install-local"):
            handleInstallLocal(body: body, connection: connection)
        default:
            if method == "GET", path.hasPrefix("/download/") {
                let filename = String(path.dropFirst("/download/".count))
                serveFile(filename, connection: connection)
            } else {
                respond(connection, status: 404, body: "not found")
            }
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

    /// POST /install-local：用本地 HTTP URL 拉起 TrollStore 安装 Downloads 下的 IPA（A2 本地更新）
    private func handleInstallLocal(body: Data, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let file = json["file"] as? String else {
            respond(connection, status: 400, body: "{\"error\":\"bad body\"}")
            return
        }
        let safeName = (file as NSString).lastPathComponent
        let trollURL = Self.trollStoreInstallURL(localFile: safeName, port: port)
        DispatchQueue.main.async {
            if let url = URL(string: trollURL) {
                UIApplication.shared.open(url)
            }
        }
        respond(connection, status: 200, contentType: "application/json", body: "{\"ok\":true}")
    }

    /// 构造「本地 HTTP 文件 → TrollStore 安装」的 URL Scheme
    static func trollStoreInstallURL(localFile: String, port: UInt16) -> String {
        let downloadURL = "http://127.0.0.1:\(port)/download/\(localFile.percentEncodedForQuery)"
        return "apple-magnifier://install?url=\(downloadURL.percentEncodedForQuery)"
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

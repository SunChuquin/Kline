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

    private func handleNew(_ connection: NWConnection) {
        connection.start(queue: queue)
        var requestBuffer = Data()

        func readLoop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if let data = data, !data.isEmpty {
                    requestBuffer.append(data)
                    if let headerEnd = requestBuffer.range(of: Data("\r\n\r\n".utf8)) {
                        let headerData = requestBuffer.subdata(in: requestBuffer.startIndex..<headerEnd.lowerBound)
                        let headerText = String(data: headerData, encoding: .utf8) ?? ""
                        let requestLine = headerText.components(separatedBy: "\r\n").first ?? ""
                        let bodyStart = headerEnd.upperBound
                        let contentLength = Self.parseContentLength(from: headerText)
                        if requestBuffer.count - bodyStart >= contentLength {
                            let body = requestBuffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                            self.dispatch(requestLine: requestLine, body: body, connection: connection)
                            return
                        }
                    }
                }
                if isComplete || error != nil {
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

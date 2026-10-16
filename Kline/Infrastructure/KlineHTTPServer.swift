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
import CryptoKit

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

    /// 监听端口：可用环境变量 KLINE_HTTP_PORT 覆盖（双模拟器联测时对端实例用 5052），缺省 5051。
    /// probe() / TrollStore 安装 URL 均引用本属性，改这里即全局生效。
    let port: UInt16 = {
        if let s = ProcessInfo.processInfo.environment["KLINE_HTTP_PORT"],
           let p = UInt16(s), p > 0 {
            return p
        }
        return 5051
    }()

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
                    // 仅拉取模型：监听本身不注册 Bonjour 广播（默认对外隐藏）。
                    // 若用户在联机同步页开启了「暴露」，监听就绪后自动恢复 mDNS 广播
                    //（覆盖 restart() 重建路径：restart 最终也会走到这里）。
                    if LANSyncPairing.shared.isExposed {
                        LANSyncAdvertiser.shared.publish(port: self.port, name: Self.deviceName())
                    }
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
            // 仅拉取模型：不再随监听自动注册 Bonjour 服务（监听即广播 = 对外持续暴露）。
            // 本机是否可被发现由用户在联机同步页的「暴露」开关显式控制
            //（LANSyncAdvertiser.publish / unpublish，见 LANSyncDiscovery.swift）。
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
        /// 沙盒原子写的最终目标（非空 = 先写 uploadTarget(<target>.part)，收完校验后 rename 到此；空 = /upload 直写）
        var uploadFinalPath = ""
        /// 可选完整性校验值（PUT/POST /sandbox/<rel>?sha256=<hex>，收完校验不符即弃 .part）
        var uploadSha256: String?
        /// 请求头 X-Kline-Pair 会话 token（/sync/backup、/sync/reload-config、沙盒读门禁校验）
        var pairToken = ""
        /// 请求头 X-Kline-Client: pipeline（PC 流水线脚本标识，沙盒写门禁豁免用）
        var pipelineClient = false
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
                    if state.uploadFinalPath.isEmpty {
                        // /upload（IPA → 公共 Downloads）：保持原有直写语义，收完即完成
                        DebugLogger.shared.log("上传完成: \(state.received) bytes")
                        respond(connection, status: 200, contentType: "application/json", body: "{\"ok\":true}")
                    } else {
                        // 沙盒写（PUT/POST /sandbox/<rel>）：原子收尾（可选 sha256 校验 → rename 到目标）
                        finalizeSandboxUpload(state: state, connection: connection)
                    }
                }
            } else {
                state.bodyBuffer.append(data)
                state.received += data.count
                if state.received >= state.contentLength {
                    state.done = true
                    let requestLine = state.method + " " + state.path + " HTTP/1.1"
                    dispatch(requestLine: requestLine, body: state.bodyBuffer, pairToken: state.pairToken,
                             pipelineClient: state.pipelineClient, connection: connection)
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
                        // 提取 X-Kline-Pair 会话 token（/sync/backup、/sync/reload-config、沙盒读门禁校验用）
                        // 与 X-Kline-Client: pipeline（PC 流水线脚本标识，沙盒写门禁豁免）
                        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
                            let kv = line.split(separator: ":", maxSplits: 1)
                            guard kv.count == 2 else { continue }
                            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                            let value = kv[1].trimmingCharacters(in: .whitespaces)
                            if key == "x-kline-pair" {
                                state.pairToken = value
                            } else if key == "x-kline-client", value.lowercased() == "pipeline" {
                                state.pipelineClient = true
                            }
                        }

                        // 流式写盘目标：/upload → 公共 Downloads（直写）；
                        // POST/PUT /sandbox/<rel> → 沙盒 Documents（先写 <target>.part，收完原子 rename：
                        // 中断只留残片，绝不把目标文件（如 tdx.db）写坏——直接写目标中断即损坏且无法恢复）
                        let isSandboxWrite = (method == "POST" || method == "PUT") && path.hasPrefix("/sandbox/")
                        if (method == "POST" || method == "PUT"), path == "/upload" || isSandboxWrite {
                            // 沙盒写门禁：未暴露且非 PC 流水线 → 403（取消暴露后本机不可被写入）
                            if isSandboxWrite,
                               !allowSandboxWrite(pairToken: state.pairToken,
                                                  pipelineHeader: state.pipelineClient,
                                                  connection: connection) {
                                state.done = true
                                return
                            }
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
                                // 原子写：实际落盘到 <target>.part；可选 sha256 校验参数留到收尾用
                                state.uploadFinalPath = resolved
                                state.uploadSha256 = Self.queryParam(rawPath, "sha256")
                                targetPath = resolved + ".part"
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
                            dispatch(requestLine: requestLine, body: state.bodyBuffer, pairToken: state.pairToken,
                                     pipelineClient: state.pipelineClient, connection: connection)
                            return
                        }
                        readLoop()
                        return
                    }
                }
                if isComplete || error != nil {
                    if let h = state.uploadHandle { try? h.close() }
                    // 沙盒原子写中断：清掉 .part 残片（目标文件不受影响）；/upload 直写保持原样不删
                    if state.isUpload, !state.uploadFinalPath.isEmpty {
                        try? FileManager.default.removeItem(atPath: state.uploadTarget)
                    }
                    connection.cancel()
                    return
                }
                readLoop()
            }
        }
        readLoop()
    }

    /// 沙盒 .part 上传收尾：可选 sha256 校验 → 原子 rename 到最终目标（同名覆盖）。
    /// 校验不符 → 删 .part、目标保持原状 400；rename 失败 → 删 .part、500。
    private func finalizeSandboxUpload(state: HTTPConnectionState, connection: NWConnection) {
        let fm = FileManager.default
        let tmp = state.uploadTarget
        let target = state.uploadFinalPath
        if let expected = state.uploadSha256, !expected.isEmpty {
            let actual = Self.fileSHA256Hex(at: tmp) ?? ""
            guard actual.lowercased() == expected.lowercased() else {
                try? fm.removeItem(atPath: tmp)
                DebugLogger.shared.log("沙盒上传 sha256 不符: \(target) expected=\(expected) actual=\(actual)")
                respond(connection, status: 400, contentType: "application/json",
                        body: "{\"error\":\"sha256 mismatch\"}")
                return
            }
        }
        do {
            // 同名覆盖：moveItem 不允许目标已存在，先移除旧目标再 rename（窗口极小，
            // 且 LAN 同步流程保证覆盖前已走 /sync/backup 快照）
            if fm.fileExists(atPath: target) {
                try fm.removeItem(atPath: target)
            }
            try fm.moveItem(atPath: tmp, toPath: target)
            DebugLogger.shared.log("沙盒上传原子落盘: \(target) \(state.received) bytes")
            respond(connection, status: 200, contentType: "application/json", body: "{\"ok\":true}")
        } catch {
            try? fm.removeItem(atPath: tmp)
            DebugLogger.shared.log("沙盒上传 rename 失败: \(target) \(error)")
            respond(connection, status: 500, contentType: "application/json",
                    body: "{\"error\":\"rename failed\"}")
        }
    }

    // MARK: - 路由

    private func dispatch(requestLine: String, body: Data, pairToken: String,
                          pipelineClient: Bool = false, connection: NWConnection) {
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
        case ("POST", "/install-engine"):
            // 引擎部署全自动通道：body 校验通过后整体跳主线程——isBusy 主线程发布，
            // downloadTipa / fetchEngineRelease 的回调也都在主线程
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.handleInstallEngine(body: body, connection: connection)
            }
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
        case ("GET", "/sync/sha"):
            // ?path=<rel>：流式计算 Documents 内文件的 sha256（LAN 同步传输完整性核对用）
            // 读门禁：未暴露且无有效会话 → 403（取消暴露后内容元信息也不可读）
            guard allowSandboxRead(pairToken: pairToken, pipelineHeader: pipelineClient, connection: connection) else { return }
            let shaRel = Self.queryParam(rawPath, "path") ?? ""
            guard !shaRel.isEmpty,
                  let shaTarget = Self.resolveSandboxPath(shaRel, sandboxRoot: sandboxRoot),
                  FileManager.default.fileExists(atPath: shaTarget) else {
                respond(connection, status: 404, contentType: "application/json", body: "{\"error\":\"not found\"}")
                return
            }
            var shaIsDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: shaTarget, isDirectory: &shaIsDir), shaIsDir.boolValue {
                respond(connection, status: 400, contentType: "application/json", body: "{\"error\":\"not a file\"}")
                return
            }
            guard let shaHex = Self.fileSHA256Hex(at: shaTarget) else {
                respond(connection, status: 500, contentType: "application/json", body: "{\"error\":\"hash failed\"}")
                return
            }
            respond(connection, status: 200, contentType: "application/json",
                    body: "{\"path\":\"\(Self.jsonEsc(shaRel))\",\"sha256\":\"\(shaHex)\"}")
        case ("POST", "/sync/request-pair"):
            // 发起方请求配对：接收方前台弹确认（LANSyncPairing），同意 → 200 {"token":...}；
            // 拒绝 / 60s 超时 → 403 {"error":"denied"}。响应在用户应答后才发出（连接保持等待）。
            handleSyncRequestPair(body: body, connection: connection)
        case ("POST", "/sync/backup"):
            // 覆盖前备份（门禁：token / 环回 / pipeline，见 allowSyncAction——USB 通道不依赖暴露）
            guard allowSyncAction(pairToken: pairToken, pipelineHeader: pipelineClient, connection: connection) else { return }
            handleSyncBackup(body: body, connection: connection)
        case ("POST", "/sync/reload-config"):
            // 配置/指标热重载（门禁：token / 环回 / pipeline，见 allowSyncAction——USB 通道不依赖暴露）
            guard allowSyncAction(pairToken: pairToken, pipelineHeader: pipelineClient, connection: connection) else { return }
            handleSyncReloadConfig(body: body, connection: connection)
        case ("POST", "/sync/live-reset"):
            // 清空增量库（门禁：token / 环回 / pipeline，见 allowSyncAction）：
            // PC 推送「沙盒无增量库 = 清空设备增量库」——关闭连接 → 删文件 → 热降级「仅主库」，无需重启
            guard allowSyncAction(pairToken: pairToken, pipelineHeader: pipelineClient, connection: connection) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { connection.cancel(); return }
                LiveDataStore.shared.closeAndRemove { removed in
                    let removedJSON = removed.map { "\"\(Self.jsonEsc($0))\"" }.joined(separator: ",")
                    self.respond(connection, status: 200, contentType: "application/json",
                                 body: "{\"ok\":true,\"removed\":[\(removedJSON)]}")
                }
            }
        case ("GET", "/sync/status"):
            // 增量库当前状态（既有 PC 推送脚本是本端点的消费者，原字段绝不能动）；
            // LAN 同步在解析结果上合并 device / items 两个新增键（旧消费者不受新增键影响）
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                var obj: [String: Any] = [:]
                if let data = LiveDataStore.shared.currentStatusJSON().data(using: .utf8),
                   let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    obj = parsed
                }
                obj["device"] = [
                    "name": Self.deviceName(),
                    "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                    "app": "Kline",
                    "id": LANSyncSupport.deviceUniqueID,
                ]
                // 暴露态（发起方连接时校验：false = 已取消暴露，提示并从列表移除）
                obj["exposed"] = LANSyncPairing.shared.isExposed
                // items 走 LANSyncItem 的 Codable 编码再转 Any 拼回：字段名与 LANSyncModels 契约强一致
                if let itemsData = try? JSONEncoder().encode(LANSyncSupport.buildSyncInventory()),
                   let itemsAny = try? JSONSerialization.jsonObject(with: itemsData) {
                    obj["items"] = itemsAny
                }
                let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
                self.respond(connection, status: 200, contentType: "application/json",
                             body: String(data: data, encoding: .utf8) ?? "{}")
            }
        case ("GET", "/opener-log"):
            handleOpenerLog(connection: connection)
        case ("GET", "/sandbox"), ("GET", "/sandbox/"):
            // 沙盒列目录门禁：未暴露且无有效会话/流水线标识 → 403
            guard allowSandboxRead(pairToken: pairToken, pipelineHeader: pipelineClient, connection: connection) else { return }
            listSandboxDirectory(sandboxRoot, connection: connection)
        case ("DELETE", let p) where p.hasPrefix("/sandbox/"):
            // 沙盒删除门禁（写类操作）：未暴露且非 PC 流水线 → 403
            guard allowSandboxWrite(pairToken: pairToken, pipelineHeader: pipelineClient, connection: connection) else { return }
            deleteSandboxPath(String(p.dropFirst("/sandbox/".count)), connection: connection)
        default:
            if method == "GET", path.hasPrefix("/sandbox/") {
                // 沙盒读文件门禁：未暴露且无有效会话/流水线标识 → 403
                //（/download/<file> 公共下载保持开放，供 PC 脚本取 IPA/导出，不含敏感配置）
                guard allowSandboxRead(pairToken: pairToken, pipelineHeader: pipelineClient, connection: connection) else { return }
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

    /// DELETE /sandbox/<path>：删除沙盒内文件/目录（FileManager.removeItem 自带目录递归删除）。
    /// 保护：Documents 根与 Backups/ 备份目录本身不可删（Backups/<时间戳> 子目录可删，防误删备份）。
    private func deleteSandboxPath(_ rel: String, connection: NWConnection) {
        guard let target = Self.resolveSandboxPath(rel, sandboxRoot: sandboxRoot) else {
            respond(connection, status: 400, body: "bad path")
            return
        }
        // resolveSandboxPath("") 会返回根本身，必须显式拦下（防整库误删）
        if target == sandboxRoot {
            respond(connection, status: 400, contentType: "application/json",
                    body: "{\"error\":\"cannot delete documents root\"}")
            return
        }
        if target == sandboxRoot + "/Backups" {
            respond(connection, status: 400, contentType: "application/json",
                    body: "{\"error\":\"cannot delete Backups\"}")
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

    // MARK: - LAN 设备联机同步（服务端）

    /// 本机名称（Bonjour 服务名与 /sync/status 的 device.name 共用）；空名回退 "Kline"
    static func deviceName() -> String {
        let n = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Kline" : n
    }

    /// 会话 token 校验（/sync/backup、/sync/reload-config）。
    /// 取舍：**不给** PUT/GET/DELETE /sandbox 加 token —— 既有 PC 流水线脚本
    /// （pipeline-shard-patch-sync / A2 部署助手等）没有 token 概念，加校验会直接打断现有流程；
    /// LAN 同步的写覆盖安全由「配对确认 + /sync/backup 覆盖前备份」保证。
    private func requirePairToken(_ token: String, connection: NWConnection) -> Bool {
        guard !token.isEmpty, LANSyncPairing.shared.isValidToken(token) else {
            respond(connection, status: 401, contentType: "application/json",
                    body: "{\"error\":\"unauthorized\"}")
            return false
        }
        return true
    }

    /// LAN 同步辅助动作（/sync/backup、/sync/reload-config）门禁，与沙盒写门禁同语义：
    /// 本机回环（USB 转发的 PC 工具链）/ 已暴露 / pipeline 标识 / 有效会话 token 之一即放行。
    /// 设计约定：**关闭「暴露」只影响 WiFi 发现与访问，USB 工具链通道不受限**。
    private func allowSyncAction(pairToken: String, pipelineHeader: Bool, connection: NWConnection) -> Bool {
        if Self.isLoopbackConnection(connection.endpoint)
            || isLANAccessible || pipelineHeader
            || (!pairToken.isEmpty && LANSyncPairing.shared.isValidToken(pairToken)) {
            return true
        }
        DebugLogger.shared.log("[LAN门禁] 非本机来源且未暴露且无有效会话，拒绝同步辅助请求")
        respond(connection, status: 403, contentType: "application/json",
                body: "{\"error\":\"not exposed\"}")
        return false
    }

    // MARK: 沙盒访问门禁（隐私要求：未暴露的本机不可被局域网读写）

    /// 本机是否处于「允许被局域网访问」状态：
    /// 已暴露（用户打开「暴露」开关）或 KLINE_AUTOPAIR=1（UI 测试实例）。
    var isLANAccessible: Bool {
        LANSyncPairing.shared.isExposed
            || ProcessInfo.processInfo.environment["KLINE_AUTOPAIR"] == "1"
    }

    /// 连接是否来自本机回环（127.0.0.1 / ::1）。
    /// USB 转发（pymobiledevice3/itunes 隧道）在设备侧由 usbmuxd 以回环身份连入，
    /// PC 部署助手 / 取日志 / 差分推送流水线全部经此通道；TrollStore 安装回读也走设备内
    /// 127.0.0.1。这些都不是「局域网访问」，不应受暴露开关约束（用户明确要求：
    /// 取消暴露只挡局域网联机同步，不限制 PC 工具链）。
    /// 外部 LAN 设备的 TCP 源地址不可能是 127.0.0.1，伪造不了回环判据。
    static func isLoopbackConnection(_ endpoint: NWEndpoint?) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let v4):
            return v4 == .loopback || v4.rawValue.first == 127
        case .ipv6(let v6):
            return v6 == .loopback
        default:
            return false
        }
    }

    /// 沙盒写操作（PUT/POST/DELETE /sandbox）门禁：
    ///   - 本机回环连接（USB 转发的 PC 工具链 / TrollStore 本地下载）→ 放行
    ///   - 已暴露 / AUTOPAIR → 放行（暴露即授权）
    ///   - PC 流水线脚本（X-Kline-Client: pipeline）→ 放行（兜底，覆盖隧道源非回环的未知场景）
    ///   - 其余（局域网来源且未暴露）→ 403：取消暴露后局域网不可写入本机
    private func allowSandboxWrite(pairToken: String, pipelineHeader: Bool, connection: NWConnection) -> Bool {
        if Self.isLoopbackConnection(connection.endpoint)
            || isLANAccessible || pipelineHeader {
            return true
        }
        DebugLogger.shared.log("[LAN门禁] 非本机来源且未暴露，拒绝沙盒写请求")
        respond(connection, status: 403, contentType: "application/json",
                body: "{\"error\":\"not exposed\"}")
        return false
    }

    /// 沙盒读操作（GET /sandbox、GET /sync/sha）门禁：
    /// 在写门禁条件之上，额外放行「持有效会话 token」的已配对拉取方——
    /// 取消暴露即吊销全部 token（revokeAllTokens），进行中的拉取立即中断。
    private func allowSandboxRead(pairToken: String, pipelineHeader: Bool, connection: NWConnection) -> Bool {
        let tokenValid = !pairToken.isEmpty && LANSyncPairing.shared.isValidToken(pairToken)
        if Self.isLoopbackConnection(connection.endpoint)
            || isLANAccessible || pipelineHeader || tokenValid {
            return true
        }
        DebugLogger.shared.log("[LAN门禁] 非本机来源且未暴露且无有效会话，拒绝沙盒读请求")
        respond(connection, status: 403, contentType: "application/json",
                body: "{\"error\":\"not exposed\"}")
        return false
    }

    /// POST /sync/request-pair：{"from":"设备名","items":["favorites","sim"]}
    /// → 用户同意 200 {"token":...}；拒绝/60s 超时 403 {"error":"denied"}
    private func handleSyncRequestPair(body: Data, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let from = json["from"] as? String, !from.isEmpty else {
            respond(connection, status: 400, contentType: "application/json", body: "{\"error\":\"bad body\"}")
            return
        }
        let items = (json["items"] as? [String]) ?? []
        LANSyncPairing.shared.requestPair(from: from, items: items) { [weak self] token in
            guard let self = self else { connection.cancel(); return }
            if let token {
                self.respond(connection, status: 200, contentType: "application/json",
                             body: "{\"token\":\"\(token)\"}")
            } else {
                self.respond(connection, status: 403, contentType: "application/json",
                             body: "{\"error\":\"denied\"}")
            }
        }
    }

    /// 备份目录时间戳（yyyyMMdd-HHmmss）
    private static func backupTimestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// POST /sync/backup（需会话 token）：{"paths":[..],"dirs":[..]} → 把已存在的文件/目录
    /// 复制到 Documents/Backups/<ts>/（相对结构保持不变），返回 {"ok","backupDir","backedUp"}。
    private func handleSyncBackup(body: Data, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            respond(connection, status: 400, contentType: "application/json", body: "{\"error\":\"bad body\"}")
            return
        }
        let paths = (json["paths"] as? [String]) ?? []
        let dirs = (json["dirs"] as? [String]) ?? []
        // 白名单：与 LANSyncCategory 的可同步范围一致，防止借备份端点探测/搬运任意沙盒文件
        let allowedPathPrefixes = ["Favorites/", "Simulation/", "Layouts/"]
        let allowedExactPaths: Set<String> = ["tdx.db", "tdx_live.db", "tdx_live.manifest.json"]
        let allowedDirs: Set<String> = ["indicator", "formula"]
        let pathsAllowed = paths.allSatisfy { rel in
            allowedExactPaths.contains(rel) || allowedPathPrefixes.contains { rel.hasPrefix($0) }
        }
        guard pathsAllowed, dirs.allSatisfy({ allowedDirs.contains($0) }) else {
            respond(connection, status: 400, contentType: "application/json",
                    body: "{\"error\":\"path not allowed\"}")
            return
        }
        let fm = FileManager.default
        let ts = Self.backupTimestamp()
        let backupRoot = sandboxRoot + "/Backups/" + ts
        try? fm.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)
        var backedUp = 0
        // 单文件：保持相对结构复制（不存在的跳过——对端本来就没有这项，不算失败）
        for rel in paths {
            guard let target = Self.resolveSandboxPath(rel, sandboxRoot: sandboxRoot),
                  fm.fileExists(atPath: target) else { continue }
            let dest = backupRoot + "/" + rel
            try? fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            try? fm.removeItem(atPath: dest)   // 同一秒内重复请求时覆盖旧备份
            if (try? fm.copyItem(atPath: target, toPath: dest)) != nil { backedUp += 1 }
        }
        // 目录：copyItem 递归整份快照（indicator / formula）
        for rel in dirs {
            guard let target = Self.resolveSandboxPath(rel, sandboxRoot: sandboxRoot),
                  fm.fileExists(atPath: target) else { continue }
            let dest = backupRoot + "/" + rel
            try? fm.removeItem(atPath: dest)
            if (try? fm.copyItem(atPath: target, toPath: dest)) != nil { backedUp += 1 }
        }
        DebugLogger.shared.log("[LANSync] 备份完成 Backups/\(ts)，共 \(backedUp) 项")
        let resp: [String: Any] = ["ok": true, "backupDir": "Backups/" + ts, "backedUp": backedUp]
        let respData = (try? JSONSerialization.data(withJSONObject: resp)) ?? Data("{}".utf8)
        respond(connection, status: 200, contentType: "application/json",
                body: String(data: respData, encoding: .utf8) ?? "{}")
    }

    /// POST /sync/reload-config（需会话 token）：{"scopes":[...]} → 主线程按 scope 热重载各 Store；
    /// scope 含 main 时由 LANSyncReload 发 LANSyncMainDBReplaced 通知（App 弹「主库已替换，请重启」）
    private func handleSyncReloadConfig(body: Data, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            respond(connection, status: 400, contentType: "application/json", body: "{\"error\":\"bad body\"}")
            return
        }
        let scopes = (json["scopes"] as? [String]) ?? []
        // 各 Store 均为主线程对象：与 /sync/reload 同款主线程跳转
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            LANSyncReload.apply(scopes: scopes)
            let respData = (try? JSONSerialization.data(withJSONObject: ["ok": true, "reloaded": scopes]))
                ?? Data("{}".utf8)
            self.respond(connection, status: 200, contentType: "application/json",
                         body: String(data: respData, encoding: .utf8) ?? "{}")
        }
    }

    /// 流式计算文件 sha256（CryptoKit，每块 1MB，不整份载入内存——1.4GB 主库也稳）
    static func fileSHA256Hex(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

    /// POST /install-engine：引擎部署全自动通道（电脑侧部署助手触发，本函数整体在主线程）。
    /// body: {"url": "<Engine .tipa 的 https 直链>"}。
    /// 链路：下载 tipa + sidecar（sidecar sha256 校验内建在 downloadTipa）→
    /// Release 官方 digest 复核（双保险）→ installViaTrollStore（opener --engine 守护 +
    /// apple-magnifier URL，装完自动把主 App 拉回前台）。
    /// 响应：200 {"ok":true,"engineBuild":<安装前构建号|null>}；400 bad body / not a tipa url；
    /// 409 busy；502 下载失败或 digest mismatch（坏包已删，绝不交给 TrollStore）。
    private func handleInstallEngine(body: Data, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let urlString = json["url"] as? String, !urlString.isEmpty,
              let url = URL(string: urlString) else {
            respond(connection, status: 400, contentType: "application/json", body: "{\"error\":\"bad body\"}")
            return
        }
        // 剥掉 query 后必须以 .tipa 结尾（下载侧会自加缓存穿透参数，这里只认纯资源地址）
        let noQuery = url.absoluteString.split(separator: "?").first.map(String.init) ?? url.absoluteString
        guard noQuery.hasSuffix(".tipa") else {
            respond(connection, status: 400, contentType: "application/json",
                    body: "{\"error\":\"not a tipa url\"}")
            return
        }
        // 引擎下载/安装串行：busy 主线程发布，与 downloadTipa 内部的 busy 检查双保险
        guard !PythonEngineHost.shared.isBusy else {
            respond(connection, status: 409, contentType: "application/json", body: "{\"error\":\"busy\"}")
            return
        }
        // 快照安装前构建号（响应带回）：电脑侧轮询 statusJSON 看 engineBuild 变化即知 Engine.app 就位
        let preBuild = PythonEngineHost.shared.installedEngineBuildNumber
        DebugLogger.shared.log("[install-engine] url=\(urlString) preBuild=\(preBuild.map(String.init) ?? "nil")")
        PythonEngineHost.shared.downloadTipa(from: url) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let msg):
                DebugLogger.shared.log("[install-engine] 下载失败：\(msg)")
                // 换行折平：jsonEsc 不转义 \n，残留会把响应 JSON 撕裂（失败信息可能含多行原因）
                let safe = Self.jsonEsc(msg)
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                self.respond(connection, status: 502, contentType: "application/json",
                             body: "{\"error\":\"\(safe)\"}")
            case .success(let path):
                self.verifyDigestThenInstall(path: path, preBuild: preBuild, connection: connection)
            }
        }
    }

    /// install-engine 中段：Release 官方 digest 复核（downloadTipa 已过 sidecar 校验，这里是
    /// 第二道）。GitHub API 抖动不阻断本地可信链路——release 不可达/digest 缺失时记日志继续装
    /// （502 的 digest mismatch 场景指 digest 可得但不匹配）；不匹配即删坏包，绝不交给 TrollStore。
    private func verifyDigestThenInstall(path: String, preBuild: Int?, connection: NWConnection) {
        GitHubUpdateService.fetchEngineRelease { [weak self] info, err in
            guard let self = self else { return }
            if err != nil || info?.ipaSHA256 == nil {
                DebugLogger.shared.log("[install-engine] digest 复核跳过（release 不可达）：\(err ?? "digest 缺失")")
                self.installEngineAndRespond(preBuild: preBuild, connection: connection)
                return
            }
            if let expected = info?.ipaSHA256,
               let problem = GitHubUpdateService.integrityProblem(at: path, expectedSHA256: expected) {
                try? FileManager.default.removeItem(atPath: path)
                DebugLogger.shared.log("[install-engine] digest mismatch，坏包已删除：\(path)（\(problem)）")
                self.respond(connection, status: 502, contentType: "application/json",
                             body: "{\"error\":\"digest mismatch\"}")
                return
            }
            DebugLogger.shared.log("[install-engine] digest 复核通过 → 拉起 TrollStore 安装")
            self.installEngineAndRespond(preBuild: preBuild, connection: connection)
        }
    }

    /// install-engine 收尾：installViaTrollStore（拉起 opener --engine 守护 + TrollStore）并回 200。
    private func installEngineAndRespond(preBuild: Int?, connection: NWConnection) {
        PythonEngineHost.shared.installViaTrollStore()
        let buildJSON = preBuild.map(String.init) ?? "null"
        respond(connection, status: 200, contentType: "application/json",
                body: "{\"ok\":true,\"engineBuild\":\(buildJSON)}")
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
    /// engineBuild 有值时切 opener --engine 模式（引擎部署全自动通道）：盯 Engine.app
    /// （com.sunck.KlineEngine）的安装，确认后拉回主 App；nil 保持默认模式（盯 Kline.app
    /// 自更新），/install-local 等既有调用方零感知。
    func triggerTrollStoreInstall(trollURL: String, engineBuild: Int? = nil) {
        let curVer = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
        // 等待窗口给足 600s：用户走完「打开 TrollStore → 下载 IPA → Install」可能远超旧默认 90s，
        // 到点自退后就再没人把新版拉到前台（表现为"装完了但没自动打开"）
        let maxWait = "600"
        // 让 opener 的诊断日志同时落到 App 沙盒（root 可写；跨版本升级容器路径不变，便于事后回看）
        let openerLog = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
            + "/opener_log.txt"
        DebugLogger.shared.log("triggerTrollStoreInstall trollURL=\(trollURL) curVer=\(curVer) engineMode=\(engineBuild != nil)")
        // 两种模式首参语义一致：「与该构建号不同即视为新包已装」。--engine 带引擎构建号，
        // 默认模式带 App 自身版本号
        let args = engineBuild.map { ["--engine", String($0), maxWait, openerLog] }
            ?? [curVer, maxWait, openerLog]
        let srOpen = RootRunner.spawnDetached(
            executable: Bundle.main.bundlePath + "/opener",
            arguments: args)
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
        // engineBuild：已装 Engine.app 的构建号（未装/仅内嵌引擎时为 null，等价 NSNull 序列化；
        // 手写拼接须显式给 null——Int? 直接塞字典字面量 nil 会整键缺失）。电脑侧部署助手
        // 轮询此字段确认引擎包就位（与 /install-engine 响应里的 preBuild 快照配对判断）
        let eb = PythonEngineHost.shared.installedEngineBuildNumber
        let engineBuildJSON = eb.map { "\"engineBuild\":\($0)" } ?? "\"engineBuild\":null"
        return "{\"status\":\"ok\",\"app\":\"Kline\",\"displayName\":\"\(Self.jsonEsc(dn))\","
            + "\"version\":\"\(Self.jsonEsc(v)) (\(Self.jsonEsc(b)))\",\"bundle\":\"\(Self.jsonEsc(bid))\","
            + engineBuildJSON + "}"
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
        case 401: statusText = "Unauthorized"
        case 403: statusText = "Forbidden"
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
        // 注意：Apple 的 RTLD_DEFAULT 是 (void*)-2，不是 NULL；dlsym(nil,…) 全局搜索会失效。
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: F.self)
    }

    /// 以 root spawn 一条命令并捕获 stdout/stderr。
    /// - Returns: (code, rawStatus, stdout, stderr)。spawn 本身失败时 code 为 posix 错误码（>0，如 2=ENOENT）。
    ///   rawStatus 为原始 waitpid status：`rawStatus & 0x7f != 0` = 被信号杀死（9=SIGKILL，
    ///   AMFI exec 拒绝的典型形态——此时 code 恒为 0，不区分会误判成「成功」）。
    @discardableResult
    static func spawnRoot(executable: String, arguments: [String] = []) -> (code: Int32, rawStatus: Int32, stdout: String, stderr: String) {
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
            return (-200, -1, "", "MISSING: " + (missing.isEmpty ? "?" : missing.joined(separator: ",")))
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
        _ = attrInit(OpaquePointer(attr))
        _ = actInit(OpaquePointer(actions))
        defer {
            _ = attrDestroy?(OpaquePointer(attr))
            _ = actDestroy?(OpaquePointer(actions))
            attr.deallocate()
            actions.deallocate()
        }

        // persona 99 + uid/gid 0（POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE = 0；符号经链接器直接解析）
        _ = rrSetPersona(attr, 99, 0)
        _ = rrSetUid(attr, 0)
        _ = rrSetGid(attr, 0)

        // 捕获 stdout/stderr
        var pipeOut = [Int32](repeating: -1, count: 2)
        var pipeErr = [Int32](repeating: -1, count: 2)
        pipe(&pipeOut)
        pipe(&pipeErr)
        _ = addDup(OpaquePointer(actions), pipeOut[1], STDOUT_FILENO)
        _ = addDup(OpaquePointer(actions), pipeErr[1], STDERR_FILENO)
        _ = addClose(OpaquePointer(actions), pipeOut[0])
        _ = addClose(OpaquePointer(actions), pipeErr[0])
        _ = addClose(OpaquePointer(actions), pipeOut[1])
        _ = addClose(OpaquePointer(actions), pipeErr[1])

        var pid: pid_t = 0
        let spawnErr = spawnFn(&pid, executable, OpaquePointer(actions), OpaquePointer(attr), argv, nil)
        // 父进程关闭写端（子进程已继承），开始读取
        close(pipeOut[1]); close(pipeErr[1])
        guard spawnErr == 0 else {
            close(pipeOut[0]); close(pipeErr[0])
            return (spawnErr, -1, "", "posix_spawn error \(spawnErr)")
        }

        var outData = Data()
        var errData = Data()
        readAll(pipeOut[0], into: &outData)
        readAll(pipeErr[0], into: &errData)
        close(pipeOut[0]); close(pipeErr[0])

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let code = (status >> 8) & 0xff
        return (code, status,
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
        _ = attrInit(OpaquePointer(attr))

        // persona 99 + uid/gid 0（继承 symbol 直接链接）
        _ = rrSetPersona(attr, 99, 0)
        _ = rrSetUid(attr, 0)
        _ = rrSetGid(attr, 0)

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

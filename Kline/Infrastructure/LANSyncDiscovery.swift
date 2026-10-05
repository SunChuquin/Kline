//
//  LANSyncDiscovery.swift
//  Kline
//
//  Created on 2026/10/5.
//

import Foundation
import Network
import Combine

/// 局域网设备联机同步——发现与连接层（仅拉取模型：手动扫描 / 暴露）。
///
/// 三个职责：
/// 1. **单次 Bonjour 扫描**（scanOnce）：点「扫描」按钮时浏览同网段 `_klinesync._tcp`
///    服务约 4 秒后自动停止，结果保留在列表（不持续浏览、不清空）。App 启动 / 进页面
///    都不注册广播、不启动浏览——本机默认对外隐藏。
///    用 NetService（dnssd）把服务端点解析成 mDNS 主机名:端口。
///    ⚠️ 不能用「NWConnection 连上去读 remoteEndpoint」拿地址——Mac 开系统代理时该连接
///    被代理劫持，拿到的是代理地址（实测 127.0.0.1:10808），见 startResolve 注释。
/// 2. **暴露广播**（LANSyncAdvertiser）：用户在联机同步页打开「暴露」开关后才发布
///    mDNS 服务（_klinesync._tcp），让同网段对端能扫描到本机；关闭开关或退出页面即
///    unpublish。监听（KlineHTTPServer）本身不再自动注册 Bonjour。
/// 3. **手动直连校验**：手动输入 `IP:端口` 时 GET `http://<host>:<port>/sync/status`
///    （5s 超时）校验对端是可同步的 Kline，并取回设备信息与 6 类内容清单
///    （LANSyncPeerStatus，契约见 LANSyncModels.swift）。
///
/// 限制：
/// - 对端服务仅前台可用（KlineHTTPServer 切后台即被系统冻结），且对端须已打开「暴露」
///   开关才会广播；扫描不到 / 连不上多为对端不在前台或未暴露。扫描失败只记日志
///   （DebugLogger），不崩溃，UI 靠手动直连兜底。
/// - iOS 模拟器共享 Mac 网络栈，Bonjour 可用；同一 Mac 跑两个模拟器实例时端口可能
///   不同（对端会用 5052），因此手动直连是关键兜底路径。
final class LANSyncDiscovery: ObservableObject {
    static let shared = LANSyncDiscovery()

    /// Bonjour 服务类型（与 LANSyncAdvertiser 发布的服务一致）
    private static let serviceType = "_klinesync._tcp"
    /// 单次解析超时（秒）：NetService.resolve(withTimeout:) 的 SRV 解析上限
    static let resolveTimeout: TimeInterval = 5

    /// 当前发现的对端设备（按 host:port 去重；只在主线程更新）。
    /// 单次扫描结束后结果保留，直到下次扫描开始才重建。
    @Published var peers: [LANSyncPeer] = []
    /// 是否正在扫描（只在主线程更新；扫描窗口约 4s，结束后自动复位）
    @Published var isBrowsing = false

    /// 浏览 / 解析共用的专属串行队列：browse 回调、解析连接回调、超时定时全部
    /// 落在它上面，内部状态天然免锁
    private let queue = DispatchQueue(label: "com.sunck.Kline.lansync.discovery")
    private var browser: NWBrowser?
    /// 当前仍在广播的服务端点：.removed 先摘除，解析完成后据此丢弃解析期间已下线的服务
    private var liveEndpoints: Set<NWEndpoint> = []
    /// 服务端点 → 已解析出的 peer id（"host:port"），.removed 时据此移除对应设备
    private var endpointIDs: [NWEndpoint: String] = [:]
    /// 解析中的端点（防止重复发起解析连接）
    private var resolving: Set<NWEndpoint> = []
    /// 活跃的 NetService 解析器（主线程访问）。
    /// ⚠️ NetServiceDelegate 回调要求 service（及其 delegate）存活，必须强持有。
    private var activeResolvers: [NWEndpoint: ServiceResolver] = [:]
    /// peers 的队列侧工作副本：先在队列上合并去重，再快照到主线程发布
    private var workingPeers: [LANSyncPeer] = []

    private init() {}

    // MARK: - 单次扫描（scanOnce / stopScan）

    /// 单次扫描：启动 Bonjour 浏览 `timeout` 秒后自动停止，结果保留在列表。
    /// 由「扫描」按钮显式触发（App 启动 / 进页面都不扫描）；正在扫描时重复调用直接
    /// 忽略（防重入）。
    func scanOnce(timeout: TimeInterval = 4) {
        queue.async { [weak self] in
            guard let self, self.browser == nil else { return }   // 防重入：扫描中直接忽略
            let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] _, changes in
                self?.handleBrowseChanges(changes)
            }
            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let error):
                    // 扫描失败只记日志：常见于本地网络权限被拒 / Wi-Fi 隔离，不中断，
                    // UI 靠手动直连兜底
                    self?.log("扫描失败：\(error)")
                case .waiting(let error):
                    self?.log("扫描等待中（网络不可用 / 本地网络权限？）：\(error)")
                default:
                    break
                }
            }
            // 每次扫描重建结果：清掉上一轮残留（离线设备 / 陈旧条目），窗口内的发现
            // 全量重新解析入库
            self.browser = browser
            self.liveEndpoints = []
            self.endpointIDs = [:]
            self.resolving = []
            self.workingPeers = []
            browser.start(queue: self.queue)
            DispatchQueue.main.async { self.isBrowsing = true }
            log("开始单次扫描（\(Int(timeout))s 窗口）")
            // 超时自动收口：停止浏览但保留结果（含仍在解析中的端点，解析完成后自然入库）
            self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.stopScan()
            }
        }
    }

    /// 停止浏览但保留已发现结果（scanOnce 的超时收口，幂等）。
    /// 只 cancel 浏览器与复位 isBrowsing；liveEndpoints / workingPeers / 解析中的
    /// resolver 全部保留——窗口结束时可能还有端点在解析（resolve 上限 5s > 4s 窗口），
    /// 让它们解析完自然进入列表。
    private func stopScan() {
        guard let browser = self.browser else { return }
        browser.cancel()
        self.browser = nil
        DispatchQueue.main.async { self.isBrowsing = false }
        log("扫描结束，已发现 \(self.workingPeers.count) 台设备")
    }

    // MARK: - 浏览结果处理

    /// 处理浏览结果变化：.added 逐个解析出 IP 与端口，.removed 按 id 移除；
    /// .identical 忽略；.changed（服务重启 / 接口变化）按「旧移除 + 新解析」处理。
    private func handleBrowseChanges(_ changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                liveEndpoints.insert(result.endpoint)
                handleAdded(result.endpoint)
            case .removed(let result):
                liveEndpoints.remove(result.endpoint)
                resolving.remove(result.endpoint)
                if let id = endpointIDs.removeValue(forKey: result.endpoint) {
                    removePeer(id: id)
                }
            case .changed(let old, let new, _):
                // 关联值是 NWBrowser.Result（非 NWEndpoint），取 .endpoint 处理
                liveEndpoints.remove(old.endpoint)
                if let id = endpointIDs.removeValue(forKey: old.endpoint) {
                    removePeer(id: id)
                }
                liveEndpoints.insert(new.endpoint)
                handleAdded(new.endpoint)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    /// 处理新增端点：Bonjour 服务端点发起解析（设备名取服务名）；
    /// hostPort 端点（理论上 Bonjour 浏览不会出现）直接成条目，名字退化为 host:port。
    private func handleAdded(_ endpoint: NWEndpoint) {
        switch endpoint {
        case .service(let name, _, _, _):
            startResolve(endpoint, serviceName: name)
        case .hostPort(let host, let port):
            let hostText = Self.hostText(host)
            let portValue = port.rawValue
            let id = "\(hostText):\(portValue)"
            upsertPeer(LANSyncPeer(id: id, name: id, host: hostText, port: portValue))
        default:
            log("忽略无法识别的端点：\(endpoint)")
        }
    }

    // MARK: - 服务端点 → 主机名:端口 解析（NetService / dnssd）

    /// 解析 Bonjour 服务端点为主机名与端口。
    ///
    /// 为什么不用「NWConnection 连上去读 currentPath.remoteEndpoint」：Mac 开系统代理
    /// （如 SOCKS @127.0.0.1:10808）时该连接会被代理劫持，remoteEndpoint 返回的是
    /// **代理地址**而非对端地址（实测 UD1 发现 UD2 显示 127.0.0.1:10808），Network.framework
    /// 也没有可用的禁代理开关。改用 NetService（dnssd 封装）做 SRV 解析：拿到 mDNS
    /// 主机名 + 真实端口，全程不建 socket、不过代理；后续 URLSession 已禁代理直连。
    /// 解析失败则放弃，等服务重新广播（.added / .changed）再试。
    private func startResolve(_ endpoint: NWEndpoint, serviceName: String) {
        guard !resolving.contains(endpoint) else { return }
        resolving.insert(endpoint)
        let resolver = ServiceResolver(endpoint: endpoint, serviceName: serviceName) { [weak self] endpoint, peer in
            guard let self else { return }
            // 回调在主线程（NetService delegate / 超时兜底都在主线程收口）：
            // 先解除对 resolver 的强持有，再转 queue 处理结果
            DispatchQueue.main.async { self.activeResolvers.removeValue(forKey: endpoint) }
            self.queue.async {
                self.resolving.remove(endpoint)
                guard let peer else {
                    self.log("解析服务失败（等服务重新广播）：\(serviceName) \(endpoint)")
                    return
                }
                // 服务可能在解析期间下线（.removed / stop() 已清空）
                guard self.liveEndpoints.contains(endpoint) else { return }
                self.endpointIDs[endpoint] = peer.id
                self.upsertPeer(peer)
            }
        }
        // NetService 必须挂在 RunLoop 上异步解析（delegate 回调随主 RunLoop 回来）；
        // ⚠️ resolver 必须被强持有：局部变量出作用域即释放，NetServiceDelegate 回调将
        // 永远不会到来（实测表现为 devices 页始终无设备）。存入 activeResolvers 持有。
        DispatchQueue.main.async {
            self.activeResolvers[endpoint] = resolver
            resolver.start()
        }
    }

    /// 单个 Bonjour 服务的解析器：包装 NetService 的 delegate 回调为一次性结果回调。
    /// 5s 超时自动收口；resolve / stop 都在主线程执行（schedule 在主 RunLoop）。
    private final class ServiceResolver: NSObject, NetServiceDelegate {
        private let endpoint: NWEndpoint
        private let serviceName: String
        private let onResult: (NWEndpoint, LANSyncPeer?) -> Void
        private var service: NetService?
        /// 收口标志：resolve 成功 / 失败 / 超时只走一次
        private var finished = false

        init(endpoint: NWEndpoint, serviceName: String,
             onResult: @escaping (NWEndpoint, LANSyncPeer?) -> Void) {
            self.endpoint = endpoint
            self.serviceName = serviceName
            self.onResult = onResult
        }

        func start() {
            let service = NetService(domain: "local.",
                                     type: LANSyncDiscovery.serviceType + ".",
                                     name: serviceName)
            service.delegate = self
            service.schedule(in: .main, forMode: .common)
            service.resolve(withTimeout: LANSyncDiscovery.resolveTimeout)
            self.service = service
            // ⚠️ 超时兜底：NetService.resolve(withTimeout:) 超时后**静默停止**，既不回调
            // netServiceDidResolveAddress 也不回调 didNotResolve，必须自己兜底收口
            timeoutWork = DispatchWorkItem { [weak self] in self?.finish(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + LANSyncDiscovery.resolveTimeout + 1,
                                          execute: timeoutWork!)
        }

        private func finish(_ peer: LANSyncPeer?) {
            guard !finished else { return }
            finished = true
            timeoutWork?.cancel()
            if let service {
                service.stop()
                service.remove(from: .main, forMode: .common)
            }
            self.service = nil
            onResult(endpoint, peer)
        }

        /// 超时兜底任务（主线程）
        private var timeoutWork: DispatchWorkItem?

        /// 解析成功：hostName 形如 "sunchukundeMac-mini.local."（剥尾点），
        /// port 为 SRV 记录的真实监听端口（5051/5052）。
        func netServiceDidResolveAddress(_ sender: NetService) {
            let host = (sender.hostName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !host.isEmpty, sender.port > 0, sender.port <= Int32(UInt16.max) else {
                finish(nil)
                return
            }
            let port = UInt16(sender.port)
            let id = "\(host):\(port)"
            finish(LANSyncPeer(id: id,
                               name: serviceName.isEmpty ? id : serviceName,
                               host: host,
                               port: port))
        }

        func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
            finish(nil)
        }
    }

    // MARK: - peers 合并与发布

    /// 按 id（即 host:port）去重合并：已存在则原地更新（设备改名 / 地址复用场景），
    /// 新设备追加。同一设备的 IPv4 / IPv6 两条解析结果天然归并为一条。
    private func upsertPeer(_ peer: LANSyncPeer) {
        if let idx = workingPeers.firstIndex(where: { $0.id == peer.id }) {
            workingPeers[idx] = peer
        } else {
            workingPeers.append(peer)
            log("发现设备：\(peer.name) @ \(peer.host):\(peer.port)")
        }
        commitPeers()
    }

    /// 主动移除一个对端（连接时发现其已取消暴露 → 从扫描列表清除陈旧条目）
    func removePeer(id: String) {
        queue.async { [weak self] in
            self?.removePeerLocked(id: id)
        }
    }

    private func removePeerLocked(id: String) {
        guard let idx = workingPeers.firstIndex(where: { $0.id == id }) else { return }
        let peer = workingPeers.remove(at: idx)
        log("移除对端（已取消暴露）：\(peer.name) @ \(peer.host):\(peer.port)")
        commitPeers()
    }

    /// 快照发布：@Published 属性只在主线程写
    private func commitPeers() {
        let snapshot = workingPeers
        DispatchQueue.main.async { [weak self] in
            self?.peers = snapshot
        }
    }

    private func log(_ message: String) {
        DebugLogger.shared.log("LANSyncDiscovery " + message)
    }

    private static func logStatic(_ message: String) {
        DebugLogger.shared.log("LANSyncDiscovery " + message)
    }

    /// NWEndpoint.Host → 文本：IPv4 点分十进制；IPv6 去掉链路本地地址的作用域后缀
    /// （"fe80::1%en0" → "fe80::1"，URL 的 host 无法携带作用域）；兜底为 mDNS 主机名
    private static func hostText(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let v4):
            return v4.debugDescription
        case .ipv6(let v6):
            let text = v6.debugDescription
            if let pct = text.firstIndex(of: "%") {
                return String(text[..<pct])
            }
            return text
        case .name(let name, _):
            return name
        @unknown default:
            return host.debugDescription
        }
    }
}

// MARK: - 暴露广播（mDNS publish）

/// 本机「暴露」广播器：把 HTTP 监听端口以 Bonjour 服务 `_klinesync._tcp` 发布到
/// 局域网，让同网段对端能扫描到本机。仅拉取模型下本机默认隐藏（不广播），
/// 只有用户在联机同步页打开「暴露」开关（或 KLINE_EXPOSED=1 启动的测试实例）才发布；
/// 关闭开关 / 退出联机同步页即 unpublish。发布失败只记日志（不影响 HTTP 监听本身）。
final class LANSyncAdvertiser: NSObject, NetServiceDelegate {
    static let shared = LANSyncAdvertiser()

    /// 当前发布中的服务（强持有：delegate 回调要求 service 存活）；nil = 未发布
    private var service: NetService?

    private override init() {}

    /// 发布（重复调用先撤掉旧服务再发新的；幂等恢复语义见 KlineHTTPServer.start 的
    /// 就绪回调）。publish / unpublish 统一收口主线程执行，避免 service 属性跨线程竞态。
    func publish(port: UInt16, name: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopCurrentService()   // 先撤旧（同线程同步执行，保证先停后发的顺序）
            let s = NetService(domain: "local.",
                               type: "_klinesync._tcp.",
                               name: name,
                               port: Int32(port))
            s.delegate = self
            s.schedule(in: .main, forMode: .common)
            s.publish()
            self.service = s
            DebugLogger.shared.log("[LANSyncAdvertiser] 已发布 _klinesync._tcp：\(name):\(port)")
        }
    }

    /// 停止广播（幂等：未发布时是 no-op）
    func unpublish() {
        DispatchQueue.main.async { [weak self] in
            self?.stopCurrentService()
        }
    }

    /// 主线程调用：停止当前发布中的服务并置 nil（幂等）
    private func stopCurrentService() {
        guard let s = service else { return }
        s.stop()
        s.remove(from: .main, forMode: .common)
        service = nil
        DebugLogger.shared.log("[LANSyncAdvertiser] 已停止广播")
    }

    /// 发布失败只记日志：常见于服务名冲突未解决 / mDNSResponder 异常；HTTP 监听不受
    /// 影响，对端仍可手动直连 IP:端口。
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        DebugLogger.shared.log("[LANSyncAdvertiser] 发布失败：\(errorDict)")
    }
}

// MARK: - 手动直连（IP:端口 兜底路径）

/// 发现 / 连接层错误
enum LANSyncDiscoveryError: Error {
    /// 对端不是可同步的 Kline：/sync/status 返回体不是 JSON、或缺 device / items 键
    /// （旧版本 Kline），或根本不是 Kline 服务。
    /// UI 据此提示「对端不是可同步的 Kline（或版本过旧）」。
    case peerIncompatible(underlying: Error)
}

extension LANSyncDiscovery {

    /// 手动 IP:端口 直连校验：GET `http://<host>:<port>/sync/status`（5s 超时），
    /// 解码为 LANSyncPeerStatus（对端设备信息 + 6 类内容清单）。
    ///
    /// 错误约定：
    /// - 网络层失败（超时 / 拒连等，URLError）：原样抛出，UI 提示「无法连接」；
    /// - 收到响应但解码失败：抛 `peerIncompatible(underlying:)`。
    static func fetchStatus(host: String, port: UInt16) async throws -> LANSyncPeerStatus {
        // IPv6 字面量在 URL 里必须套方括号（parseHostPort 返回的 host 不含括号）
        let hostPart = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(hostPart):\(port)/sync/status") else {
            throw URLError(.badURL)
        }
        // 固定路径无需百分号编码；无缓存会话，请求级 5s 超时。
        // ⚠️ 禁系统代理：对端 host（如 sunchukundeMac-mini.local / 192.168.x.x）不在
        // 代理例外名单（通常只有 localhost/127.0.0.0/8）时，请求会被 HTTP/SOCKS 代理
        // 劫持 → 局域网直连全部失败（「无法连接」）。联机同步必须点对点直连。
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 8
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg)

        let data: Data
        do {
            (data, _) = try await session.data(from: url)
        } catch {
            logStatic("直连 \(host):\(port) 失败：\(error)")
            throw error
        }
        do {
            return try JSONDecoder().decode(LANSyncPeerStatus.self, from: data)
        } catch {
            // 旧版 Kline 的 /sync/status 没有 device/items 键；非 Kline 服务多半返回
            // HTML/空体——表现都是解码失败，UI 统一按「对端不可同步」提示
            logStatic("/sync/status 解码失败（对端可能是旧版 Kline 或非 Kline 服务）：\(error)")
            throw LANSyncDiscoveryError.peerIncompatible(underlying: error)
        }
    }

    /// 解析手动输入的地址，支持三种形式：
    /// - "192.168.1.5:5052" → ("192.168.1.5", 5052)
    /// - "192.168.1.5"      → ("192.168.1.5", 5051)（缺省端口 = KlineHTTPServer 默认监听端口）
    /// - "[::1]:5052"       → ("::1", 5052)（IPv6 字面量必须带方括号，返回值不含括号）
    /// 无法解析（端口非法 / 裸 IPv6 与端口冒号无法区分等）返回 nil。
    static func parseHostPort(_ text: String) -> (host: String, port: UInt16)? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        // [IPv6 字面量][:端口]
        if input.hasPrefix("[") {
            guard let closeIdx = input.firstIndex(of: "]") else { return nil }
            let host = String(input[input.index(after: input.startIndex)..<closeIdx])
            guard !host.isEmpty, !host.contains("/"), !host.contains(" ") else { return nil }
            var port: UInt16 = 5051
            let rest = String(input[input.index(after: closeIdx)...])
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()), p > 0 else { return nil }
                port = p
            }
            return (host, port)
        }

        // host[:端口]：不带方括号时只允许一个冒号——裸 IPv6（多个冒号）与 host:port
        // 无法区分，不支持（用户应写成方括号形式）
        if let colonIdx = input.firstIndex(of: ":") {
            let host = String(input[..<colonIdx])
            let rest = String(input[input.index(after: colonIdx)...])
            guard !host.isEmpty, !rest.isEmpty, !rest.contains(":"),
                  let p = UInt16(rest), p > 0,
                  !host.contains("/"), !host.contains(" ") else { return nil }
            return (host, p)
        }

        // 纯 host，缺省端口 5051
        guard !input.contains("/"), !input.contains(" ") else { return nil }
        return (input, 5051)
    }
}

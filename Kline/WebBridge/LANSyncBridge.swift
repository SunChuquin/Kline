//
//  LANSyncBridge.swift
//  Kline
//
//  联机同步桥（协议 v2 lan.*）：P2-6c-1 LANSyncView Web 化的 Swift 侧。
//
//  状态留原生：LANSyncDiscovery（扫描）/ LANSyncPairing（暴露）/ LANSyncTransfer（传输引擎）
//  全部原生单例或页面级实例，Web 只发动作与消费快照（写回模式 v2）。
//  Web 本地态（不进桥）：子页切换（devices/configure/running）、各类勾选粒度、展开集合、
//  手动直连输入——start 动作一次性提交选择集合。
//
//  与原生 LANSyncView 的行为对齐：
//   - onOpen：KlineHTTPServer.start()（幂等）+ probe（不自动扫描）
//   - 关闭：busy（pairing/transferring）拒绝；否则 unpublish + isExposed=false + 吊销全部
//     会话 token（对齐原生 onDisappear「退出即取消暴露」）
//   - 连接失败 fail/事件返回中文文案（不能连接本机 / 对端已取消暴露 / 对端不可同步 / 无法连接）
//   - 主库被对端替换（.lansyncMainDBReplaced）→ lan.changed {reason:"mainDBReplaced"} 弹重启提示
//
//  线程约定：动作入口均在主线程；probe 回调经 DispatchQueue.main 切回。
//

import Combine
import Foundation

@MainActor
final class LANSyncBridge: ObservableObject {

    static let shared = LANSyncBridge()

    // MARK: - 页面级状态（快照消费；外部变化走订阅推送）

    /// 本机服务真实探测结果（不用 isRunning 快照——那有「假在线」问题）
    @Published private(set) var serverOnline = false
    /// 探测中（防刷新连点）
    @Published private(set) var probing = false
    /// 连接中（设备卡与手动直连共用，防重复点击）
    @Published private(set) var connecting = false
    /// 当前对端（连接成功后写入；关闭时清空）
    @Published private(set) var peer: LANSyncPeer?
    /// 对端 /sync/status 快照（6 类清单 + 细粒度子项）
    @Published private(set) var remoteStatus: LANSyncPeerStatus?
    /// 本机 6 类清单（进入 configure 时构建一次）
    @Published private(set) var localInventory: [LANSyncItem] = []

    /// 传输引擎（页面生命周期内一次会话；对齐原生 @StateObject transfer）
    let transfer = LANSyncTransfer()

    /// 同步进行中（等待对端确认 / 传输中）——期间禁止关闭页面
    var isSyncBusy: Bool {
        switch transfer.phase {
        case .pairing, .transferring: return true
        default: return false
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var changedItem: DispatchWorkItem? = nil
    private var pendingReason = "data"
    /// 节流窗口（transfer 进度逐块更新，0.3s 合并足够顺滑）
    private let changedThrottle: TimeInterval = 0.3

    private init() {
        LANSyncDiscovery.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged("data") }
            .store(in: &cancellables)
        LANSyncPairing.shared.$isExposed
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleChanged("expose") }
            .store(in: &cancellables)
        transfer.objectWillChange
            .sink { [weak self] _ in self?.scheduleChanged("transfer") }
            .store(in: &cancellables)
        // 主库被对端整库替换：SQLite 连接需重启 App 重建（原生 onReceive 同款）
        NotificationCenter.default.publisher(for: .lansyncMainDBReplaced)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pushAlert("mainDBReplaced", "对端已向本机替换主库 tdx.db，请重启 App 生效")
            }
            .store(in: &cancellables)
        // 关闭仲裁：传输中拒绝关闭（Web 端返回按钮同步禁用，此处兜底）
        WebPageBridge.shared.closeHooks["lanSync"] = { [weak self] in
            guard let self else { return true }
            if self.isSyncBusy { return false }
            self.teardownOnClose()
            return true
        }
    }

    // MARK: - 生命周期

    /// 页面打开（对齐原生 onAppear）：确保本机监听在跑（幂等）+ 真实探测；不自动扫描
    func onOpen() {
        KlineHTTPServer.shared.start()
        probe()
    }

    /// 页面关闭清理（对齐原生 onDisappear）：停止广播 + 关闭暴露 + 吊销全部会话 token；
    /// 连接上下文清空（已发现的 peers 保留，下次进入可直接看到上次扫描结果）
    private func teardownOnClose() {
        LANSyncAdvertiser.shared.unpublish()
        LANSyncPairing.shared.isExposed = false
        LANSyncPairing.shared.revokeAllTokens()
        peer = nil
        remoteStatus = nil
        localInventory = []
    }

    // MARK: - 变化信号 → lan.changed 节流推送

    private func scheduleChanged(_ reason: String) {
        pendingReason = reason
        guard changedItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.changedItem = nil
            WebMessageRouter.shared.pushEvent("lan.changed", payload: ["reason": self.pendingReason], route: "page")
        }
        changedItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + changedThrottle, execute: item)
    }

    /// 带消息的即时推送（连接失败 / 主库替换提示；不经节流）
    private func pushAlert(_ reason: String, _ message: String) {
        WebMessageRouter.shared.pushEvent("lan.changed",
                                          payload: ["reason": reason, "message": message],
                                          route: "page")
    }

    // MARK: - 动作

    /// 本机服务真实探测（probe 回调在探测队列，切主线程）
    func probe() {
        guard !probing else { return }
        probing = true
        scheduleChanged("probe")
        KlineHTTPServer.shared.probe { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                self.serverOnline = ok
                self.probing = false
                self.scheduleChanged("probe")
            }
        }
    }

    /// 暴露开关（对齐原生 setExposed）：开 = 记录授权 + 发布 mDNS 广播；
    /// 关 = 停止广播 + 收回授权 + 吊销全部会话 token
    func setExposed(_ on: Bool) {
        LANSyncPairing.shared.isExposed = on
        if on {
            LANSyncAdvertiser.shared.publish(port: KlineHTTPServer.shared.port,
                                             name: KlineHTTPServer.deviceName())
        } else {
            LANSyncAdvertiser.shared.unpublish()
            LANSyncPairing.shared.revokeAllTokens()
        }
        scheduleChanged("expose")
    }

    /// 扫描一次（约 4s 窗口；isBrowsing @Published 驱动推送，结果保留在列表）
    func scan() {
        LANSyncDiscovery.shared.scanOnce()
    }

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "snapshot":
            return WebBridgeResponse.ok(request.id, data: snapshotData())
        case "probe":
            shared.probe()
            return WebBridgeResponse.ok(request.id)
        case "setExposed":
            guard let on = request.payload["on"] as? Bool else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要 on")
            }
            shared.setExposed(on)
            return WebBridgeResponse.ok(request.id)
        case "scan":
            shared.scan()
            return WebBridgeResponse.ok(request.id)
        case "connect":
            return connect(request)
        case "start":
            return start(request)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "lan.\(request.action) 未实现")
        }
    }

    /// lan.connect {peerId?|address?}：取对端 /sync/status；成功写入 configure 数据并推送
    /// （Web 切配置页）；失败 lan.changed {reason:"connectFailed", message} 弹提示。
    private static func connect(_ request: WebBridgeRequest) -> [String: Any] {
        let p = request.payload
        let target: LANSyncPeer?
        if let id = p["peerId"] as? String {
            target = LANSyncDiscovery.shared.peers.first { $0.id == id }
        } else if let addr = p["address"] as? String,
                  let parsed = LANSyncDiscovery.parseHostPort(addr) {
            target = LANSyncPeer(id: "\(parsed.host):\(parsed.port)",
                                 name: "\(parsed.host):\(parsed.port)",
                                 host: parsed.host, port: parsed.port)
        } else {
            target = nil
        }
        guard let target else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "需要 peerId 或有效 address（IP:端口）")
        }
        let bridge = shared
        guard !bridge.connecting else {
            // 连接中重复触发 no-op（原生 disabled 同语义）
            return WebBridgeResponse.ok(request.id, data: ["queued": true])
        }
        bridge.connecting = true
        bridge.scheduleChanged("connect")

        let host = target.host, port = target.port, id = target.id
        Task {
            do {
                let status = try await LANSyncDiscovery.fetchStatus(host: host, port: port)
                await MainActor.run {
                    let bridge = LANSyncBridge.shared
                    bridge.connecting = false
                    // 防自连：对端唯一 ID 与本机相同 = 连到了自己的服务端口
                    if status.device.id == LANSyncSupport.deviceUniqueID {
                        bridge.pushAlert("connectFailed", "不能连接本机")
                        return
                    }
                    if status.exposed == false {
                        // 对端已取消暴露：明确拒绝并移除陈旧条目（mDNS 缓存滞后）
                        LANSyncDiscovery.shared.removePeer(id: id)
                        bridge.pushAlert("connectFailed", "对端已取消暴露")
                        return
                    }
                    bridge.peer = target
                    bridge.remoteStatus = status
                    bridge.localInventory = LANSyncSupport.buildSyncInventory()
                    bridge.scheduleChanged("connected")
                }
            } catch {
                await MainActor.run {
                    let bridge = LANSyncBridge.shared
                    bridge.connecting = false
                    let message: String
                    if let e = error as? LANSyncDiscoveryError, case .peerIncompatible = e {
                        message = "对端不可同步：对端不是可同步的 Kline（或版本过旧）"
                    } else {
                        message = "无法连接 \(host):\(port)，请确认对端 Kline 在前台且与本机在同一局域网"
                    }
                    bridge.pushAlert("connectFailed", message)
                }
            }
        }
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    /// lan.start {selections:[{category, mode, childKeys?}]}：发起拉取（传输引擎 async run，
    /// phase/progress 经订阅推送）。busy 重入保护由引擎自身承担。
    private static func start(_ request: WebBridgeRequest) -> [String: Any] {
        guard let selAny = request.payload["selections"] as? [[String: Any]], !selAny.isEmpty else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要 selections")
        }
        var sels: [LANSyncCategorySelection] = []
        for item in selAny {
            guard let catRaw = item["category"] as? String, let cat = LANSyncCategory(rawValue: catRaw),
                  let modeRaw = item["mode"] as? String else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                              message: "selections 格式错误（category/mode）")
            }
            let keys = Set((item["childKeys"] as? [String]) ?? [])
            let mode: LANSyncCategorySelection.Mode = (modeRaw == "children") ? .children : .all
            sels.append(LANSyncCategorySelection(category: cat, mode: mode, childKeys: keys))
        }
        let bridge = shared
        guard let peer = bridge.peer, let remote = bridge.remoteStatus, !bridge.isSyncBusy else {
            // 防御：Web 端仅在配置页可发起，正常不会出现
            return WebBridgeResponse.ok(request.id)
        }
        Task { await bridge.transfer.run(selections: sels, peer: peer, remoteStatus: remote) }
        DebugLogger.shared.log("[LANSyncBridge] start \(sels.count) 类拉取")
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    // MARK: - 快照组装（文案原生格式化）

    static func snapshotData() -> [String: Any] {
        let bridge = shared
        let discovery = LANSyncDiscovery.shared
        let pairing = LANSyncPairing.shared
        let t = bridge.transfer

        let transferAny: [String: Any] = [
            "phase": phaseKey(t.phase),
            "progress": t.progress,
            "bytesPerSecond": t.bytesPerSecond,
            "currentFile": t.currentFile,
            "resultSummary": t.resultSummary,
            "backupDir": t.backupDir ?? NSNull(),
            "needsRestart": t.needsRestart,
            "failMessage": failMessage(t.phase),
        ]
        let peersAny: [[String: Any]] = discovery.peers.map {
            ["id": $0.id, "name": $0.name, "host": $0.host, "port": Int($0.port)]
        }
        var configureAny: Any = NSNull()
        if let peer = bridge.peer, let remote = bridge.remoteStatus {
            let categories: [[String: Any]] = LANSyncCategory.allCases.map { cat in
                let local = bridge.localInventory.first { $0.key == cat.rawValue }
                let rem = remote.item(cat)
                let children = rem?.children ?? []
                return [
                    "key": cat.rawValue,
                    "title": cat.title,
                    "localSummary": sideSummary(local),
                    "remoteSummary": sideSummary(rem),
                    "hasChildren": !children.isEmpty,
                    "children": children.map {
                        ["key": $0.key, "name": $0.name, "quantity": childQuantity($0)]
                    },
                ]
            }
            configureAny = [
                "peer": ["name": peer.name, "host": peer.host, "port": Int(peer.port),
                         "appVersion": remote.device.appVersion],
                "categories": categories,
            ]
        }
        return [
            "serverOnline": bridge.serverOnline,
            "probing": bridge.probing,
            "port": Int(KlineHTTPServer.shared.port),
            "deviceName": KlineHTTPServer.deviceName(),
            "isExposed": pairing.isExposed,
            "isBrowsing": discovery.isBrowsing,
            "connecting": bridge.connecting,
            "peers": peersAny,
            "busy": bridge.isSyncBusy,
            "transfer": transferAny,
            "configure": configureAny,
        ]
    }

    private static func phaseKey(_ phase: LANSyncTransfer.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .pairing: return "pairing"
        case .transferring: return "transferring"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private static func failMessage(_ phase: LANSyncTransfer.Phase) -> Any {
        if case .failed(let message) = phase { return message }
        return NSNull()
    }

    /// 类别清单人性化摘要（对齐原生 LANSyncView.sideSummary）
    static func sideSummary(_ item: LANSyncItem?) -> String {
        guard let item else { return "—" }
        guard !item.files.isEmpty else { return "—" }
        if item.files.count == 1 {
            let f = item.files[0]
            return "\(byteText(f.size)) · \(mtimeText(f.mod))"
        }
        return "\(item.files.count) 个文件 / \(byteText(item.totalBytes))"
    }

    /// 子项对端量文案：分组 → "N 个"；文件 → 字节数
    static func childQuantity(_ child: LANSyncChild) -> String {
        if let count = child.count { return "\(count) 个" }
        return byteText(child.size)
    }

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static let mtimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static func mtimeText(_ ts: TimeInterval) -> String {
        Self.mtimeFormatter.string(from: Date(timeIntervalSince1970: ts))
    }
}

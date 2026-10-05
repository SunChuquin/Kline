//
//  LANSyncView.swift
//  Kline
//
//  局域网设备联机同步 · UI 层（个人中心「联机同步」入口的全屏页面）。
//
//  页面三态（页内 @State 切换，不做 NavigationStack，与个人中心全屏 overlay 模式一致）：
//    devices   设备列表：本机服务状态（真实探测）+ Bonjour 已发现设备 + 手动 IP 直连兜底
//    configure 同步配置：方向（推送/拉取）+ 6 类内容勾选（本机量 vs 对端量）+ 开始同步
//    running   进度与结果：等待对端确认 / 传输进度 / 完成汇总 / 失败重试
//
//  本机作为接收方时的确认弹窗监听 LANSyncPairing.shared.pendingRequest（服务端路由置位，
//  60s 无应答对端侧自动超时）；主库被对端替换监听 .lansyncMainDBReplaced 通知弹重启提示。
//  基础设施（LANSyncModels / Discovery / Transfer / Support / KlineHTTPServer）只读不改。
//

import SwiftUI
import Combine
import UIKit

struct LANSyncView: View {

    /// 全屏 overlay 关闭回调（个人中心无 NavigationStack，页面跳转走既有 overlay 模式）
    var onClose: () -> Void

    // MARK: - 页面三态

    private enum Page { case devices, configure, running }
    @State private var page: Page = .devices

    // MARK: - 基础设施

    /// 设备发现（全局单例，onAppear start / onDisappear stop）
    @ObservedObject private var discovery = LANSyncDiscovery.shared
    /// 本机作为接收方的配对确认（服务端路由置 pendingRequest，UI 弹窗应答）
    @ObservedObject private var pairing = LANSyncPairing.shared
    /// 传输引擎（页面生命周期内一次会话）
    @StateObject private var transfer = LANSyncTransfer()

    // MARK: - devices 页状态

    /// 本机服务在线（probe 真实探测结果；不用 isRunning 快照——那有「假在线」问题）
    @State private var serverOnline = false
    /// 探测中（防刷新按钮连点）
    @State private var probing = false
    /// 手动直连输入（IP:端口）
    @State private var manualAddress = ""
    /// 连接中（设备卡片与手动直连共用，防重复点击）
    @State private var connecting = false
    /// 手动直连解析失败 shake 计数（+1 触发一次抖动动画）
    @State private var shakeAttempts = 0

    // MARK: - configure 页状态

    /// 当前对端（连接成功后写入）
    @State private var peer: LANSyncPeer?
    /// 对端 /sync/status 快照（设备信息 + 6 类清单）
    @State private var remoteStatus: LANSyncPeerStatus?
    /// 本机 6 类清单（进入 configure 时构建一次）
    @State private var localInventory: [LANSyncItem] = []
    /// 同步方向（默认推送：本机 → 对端）
    @State private var direction: LANSyncDirection = .push
    /// 勾选的同步类别
    @State private var selected: Set<LANSyncCategory> = []

    // MARK: - 弹窗状态

    /// 通用提示（连接失败等），标题与内容分离
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    /// 主库被对端替换（.lansyncMainDBReplaced）
    @State private var mainDBReplacedAlert = false

    // MARK: - 主体

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch page {
                    case .devices: devicesPage
                    case .configure: configurePage
                    case .running: runningPage
                    }
                }
                .padding()
            }
        }
        // 内容延伸到物理屏幕底边 + 背景铺满（与个人中心同做法）
        .background(Color(.systemBackground).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            KlineHTTPServer.shared.start()   // 确保本机监听在跑（幂等）
            probeServer()
            discovery.start()
        }
        .onDisappear {
            discovery.stop()
        }
        // 主库被对端整库替换：SQLite 连接与内存缓存需重启 App 重建
        .onReceive(NotificationCenter.default.publisher(for: .lansyncMainDBReplaced)) { _ in
            mainDBReplacedAlert = true
        }
        // 通用提示（连接失败等）
        .alert(alertTitle, isPresented: $showAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        // 接收方确认：对端发起同步请求时弹窗（deny() 对无挂起请求是幂等 no-op，
        // 供系统侧关闭弹窗时兜底释放挂起的 completion）
        .alert("联机同步请求", isPresented: pairingAlertPresented) {
            Button("允许") { pairing.approve() }
                .accessibilityIdentifier("lansync.pair.allow")
            Button("拒绝", role: .destructive) { pairing.deny() }
                .accessibilityIdentifier("lansync.pair.deny")
        } message: {
            Text(pairingAlertMessage)
        }
        // 主库被替换提示
        .alert("主库已替换", isPresented: $mainDBReplacedAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("对端已向本机替换主库 tdx.db，请重启 App 生效")
        }
    }

    // MARK: - 顶部返回栏（与个人中心同款）

    private var navBar: some View {
        HStack {
            Button(action: backTapped) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 24))
            }
            .padding(.leading, 16)
            .disabled(isSyncBusy)   // 配对中 / 传输中不允许返回，防同步任务与页面状态错乱

            Text("联机同步")
                .font(.title)
                .fontWeight(.bold)

            Spacer()
        }
        .background(Color(.systemBackground))
        .frame(height: 56)
    }

    /// 同步进行中（等待对端确认 / 传输中）
    private var isSyncBusy: Bool {
        switch transfer.phase {
        case .pairing, .transferring: return true
        default: return false
        }
    }

    /// 返回：devices 页关整页，configure / running 页回设备列表
    private func backTapped() {
        switch page {
        case .devices:
            onClose()
        case .configure, .running:
            withAnimation(.easeOut(duration: 0.15)) { page = .devices }
        }
    }

    // MARK: - ① devices：设备列表

    private var devicesPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("本机服务")
            localServiceCard

            sectionLabel("已发现设备")
            if discovery.isBrowsing {
                searchingRow
            }
            ForEach(Array(discovery.peers.enumerated()), id: \.element.id) { index, item in
                peerCard(item, index: index)
            }

            sectionLabel("手动直连")
            manualCard
        }
    }

    /// 区块小标题（与 Python 引擎实验室同款）
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Color.gray.opacity(0.85))
    }

    /// 本机服务卡片：在线状态（真实探测）+ 设备名 + 监听端口 + 前台提示 + 刷新探测
    private var localServiceCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    // 在线绿点 / 离线红点
                    Circle()
                        .fill(serverOnline ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(serverOnline ? "在线" : "离线")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color.primary)
                    Spacer(minLength: 8)
                    // 刷新探测（探测中转圈）
                    Button(action: { probeServer() }) {
                        Group {
                            if probing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .font(.system(size: 18))
                        .foregroundColor(.blue)
                        .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(probing)
                }
                Text("\(UIDevice.current.name) · 端口 \(KlineHTTPServer.shared.port)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Text("对端设备需保持 Kline 在前台")
                    .font(.system(size: 12))
                    .foregroundColor(Color(.tertiaryLabel))
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .accessibilityIdentifier("lansync.local.status")
    }

    /// 搜索中提示行
    private var searchingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("正在搜索同网段设备…")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    /// 已发现设备卡片：设备名 + host:port + chevron，点击取对端清单进入配置页
    private func peerCard(_ peer: LANSyncPeer, index: Int) -> some View {
        Button(action: { connect(peer: peer) }) {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 16))
                    .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(peer.name)
                        .font(.system(size: 16))
                        .foregroundColor(Color.primary)
                        .lineLimit(1)
                    Text("\(peer.host):\(peer.port)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 12)
                if connecting {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(.tertiaryLabel))
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(connecting)
        .accessibilityIdentifier("lansync.peer.\(index)")
    }

    /// 手动直连卡片：IP:端口 输入 + 连接按钮（Bonjour 浏览不到时的兜底路径）
    private var manualCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("对端 IP:端口，如 192.168.1.5:5051", text: $manualAddress)
                    .font(.system(size: 15))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.asciiCapable)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Color(.tertiarySystemBackground))
                    .cornerRadius(10)
                    .accessibilityIdentifier("lansync.manual.field")

                Button(action: connectManual) {
                    Text(connecting ? "连接中" : "连接")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(connecting ? Color(.tertiaryLabel) : Color.blue)
                        .frame(width: 76, height: 40)
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(connecting)
                .accessibilityIdentifier("lansync.manual.connect")
            }
            Text("对端未出现在列表时可直接输入其 IP 与端口（缺省端口 5051）")
                .font(.system(size: 12))
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        // 解析失败水平抖动（GeometryEffect 动画驱动）
        .modifier(ShakeEffect(animatableData: CGFloat(shakeAttempts)))
    }

    // MARK: - ② configure：同步配置

    @ViewBuilder
    private var configurePage: some View {
        if let peer = peer, let remote = remoteStatus {
            VStack(alignment: .leading, spacing: 12) {
                // 对端信息行：名称 + IP:port + App 版本
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(peer.name)
                            .font(.system(size: 16))
                            .foregroundColor(Color.primary)
                            .lineLimit(1)
                        Text("\(peer.host):\(peer.port) · \(remote.device.appVersion)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                .frame(minHeight: 48)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)

                sectionLabel("同步方向")
                Picker("方向", selection: $direction) {
                    Text("推送（本机 → 对端）")
                        .tag(LANSyncDirection.push)
                        .accessibilityIdentifier("lansync.direction.push")
                    Text("拉取（对端 → 本机）")
                        .tag(LANSyncDirection.pull)
                        .accessibilityIdentifier("lansync.direction.pull")
                }
                .pickerStyle(.segmented)

                sectionLabel("同步内容（本机 ↔ 对端）")
                VStack(spacing: 0) {
                    ForEach(LANSyncCategory.allCases) { cat in
                        categoryRow(cat)
                        if let last = LANSyncCategory.allCases.last, cat != last {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)

                // 主库警示：勾选 main 时出现
                if selected.contains(.main) {
                    mainDBWarning
                }

                startButton
            }
        } else {
            // 防御：configure 只在连接成功后进入，正常不会出现
            Text("未选择对端设备")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
    }

    /// 单类内容勾选行：勾选圈 + 类别名 + 本机量 vs 对端量
    private func categoryRow(_ cat: LANSyncCategory) -> some View {
        let local = localInventory.first { $0.key == cat.rawValue }
        let remote = remoteStatus?.item(cat)
        let checked = selected.contains(cat)
        return Button(action: {
            if checked {
                selected.remove(cat)
            } else {
                selected.insert(cat)
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(checked ? .blue : Color(.tertiaryLabel))
                VStack(alignment: .leading, spacing: 3) {
                    Text(cat.title)
                        .font(.system(size: 16))
                        .foregroundColor(Color.primary)
                    Text("本机 \(sideSummary(local)) ｜ 对端 \(sideSummary(remote))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("lansync.category.\(cat.rawValue)")
    }

    /// 主库警示块（黄色）
    private var mainDBWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(.yellow)
                .padding(.top, 2)
            Text("主库约 GB 级，WiFi 传输耗时较长；替换后需重启 App 生效")
                .font(.system(size: 13))
                .foregroundColor(Color.primary)
        }
        .padding(12)
        .background(Color.yellow.opacity(0.15))
        .cornerRadius(12)
    }

    /// 开始同步（无选中类别时禁用）
    private var startButton: some View {
        Button(action: startSync) {
            Text("开始同步")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Color.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(selected.isEmpty ? Color.blue.opacity(0.35) : Color.blue)
                .cornerRadius(12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selected.isEmpty)
        .accessibilityIdentifier("lansync.start")
    }

    // MARK: - ③ running：进度与结果

    @ViewBuilder
    private var runningPage: some View {
        switch transfer.phase {
        case .idle:
            // 开始同步后 run() 立刻置 .pairing，此态仅一瞬间
            VStack(spacing: 12) {
                ProgressView()
                Text("正在准备…")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)

        case .pairing:
            VStack(spacing: 12) {
                ProgressView()
                Text("等待对端确认…")
                    .font(.system(size: 17, weight: .semibold))
                Text("请在对端设备上允许本次同步")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Text(directionText)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)

        case .transferring:
            VStack(alignment: .leading, spacing: 14) {
                Text(directionText)
                    .font(.system(size: 15, weight: .medium))
                ProgressView(value: transfer.progress)
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int((transfer.progress * 100).rounded()))%")
                        .font(.system(size: 30, weight: .bold))
                    Spacer()
                    Text(String(format: "%.1f MB/s", Double(transfer.bytesPerSecond) / 1_048_576))
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                Text("当前文件：\(transfer.currentFile.isEmpty ? "—" : transfer.currentFile)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

        case .done:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.green)
                    Text("同步完成")
                        .font(.system(size: 17, weight: .semibold))
                }
                Text(transfer.resultSummary)
                    .font(.system(size: 14))
                    .foregroundColor(Color.primary)
                    .accessibilityIdentifier("lansync.result.summary")
                if let backup = transfer.backupDir {
                    Text("已备份到 Documents/\(backup)")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                if transfer.needsRestart {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.yellow)
                            .padding(.top, 2)
                        Text("主库已替换，请重启 App 生效")
                            .font(.system(size: 13))
                            .foregroundColor(Color.primary)
                    }
                }
                // 完成按钮：回设备列表
                Button(action: { withAnimation(.easeOut(duration: 0.15)) { page = .devices } }) {
                    Text("完成")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.blue)
                        .cornerRadius(12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lansync.done.button")
            }
            .padding(16)
            .background(Color.green.opacity(0.12))
            .cornerRadius(12)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.red)
                    Text("同步失败")
                        .font(.system(size: 17, weight: .semibold))
                }
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(Color.primary)
                    .accessibilityIdentifier("lansync.fail.message")
                Text(directionText)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                // 重试：回配置页重新发起
                Button(action: { withAnimation(.easeOut(duration: 0.15)) { page = .configure } }) {
                    Text("重试")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.blue)
                        .cornerRadius(12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(Color.red.opacity(0.12))
            .cornerRadius(12)
        }
    }

    /// 方向与对端名（running 页各状态共用）
    private var directionText: String {
        let name = peer?.name ?? "对端"
        return direction == .push ? "推送：本机 → \(name)" : "拉取：\(name) → 本机"
    }

    // MARK: - 动作

    /// 本机服务真实探测（probe 回调在探测队列，UI 需切主线程）
    private func probeServer() {
        guard !probing else { return }
        probing = true
        KlineHTTPServer.shared.probe { ok in
            DispatchQueue.main.async {
                self.serverOnline = ok
                self.probing = false
            }
        }
    }

    /// 连接对端：取 /sync/status，成功进入配置页，失败按错误类型提示
    private func connect(peer target: LANSyncPeer) {
        guard !connecting else { return }
        connecting = true
        Task {
            do {
                let status = try await LANSyncDiscovery.fetchStatus(host: target.host, port: target.port)
                await MainActor.run {
                    self.connecting = false
                    enterConfigure(peer: target, status: status)
                }
            } catch {
                await MainActor.run {
                    self.connecting = false
                    showConnectError(error, target: target)
                }
            }
        }
    }

    /// 手动直连：解析输入 → 构造 peer → 同 connect；空输入 / 解析失败抖动提示
    private func connectManual() {
        let text = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let parsed = LANSyncDiscovery.parseHostPort(text) else {
            withAnimation(.easeInOut(duration: 0.4)) { shakeAttempts += 1 }
            return
        }
        let target = LANSyncPeer(id: "\(parsed.host):\(parsed.port)",
                                 name: "\(parsed.host):\(parsed.port)",
                                 host: parsed.host,
                                 port: parsed.port)
        connect(peer: target)
    }

    /// 连接失败提示：对端不可同步 vs 网络错误分开提示
    private func showConnectError(_ error: Error, target: LANSyncPeer) {
        if let e = error as? LANSyncDiscoveryError, case .peerIncompatible = e {
            alertTitle = "对端不可同步"
            alertMessage = "对端不是可同步的 Kline（或版本过旧）"
        } else {
            alertTitle = "无法连接"
            alertMessage = "无法连接 \(target.host):\(target.port)，请确认对端 Kline 在前台且与本机在同一局域网"
        }
        showAlert = true
    }

    /// 进入配置页：存对端 peer + 对端清单快照，并构建本机清单
    private func enterConfigure(peer newPeer: LANSyncPeer, status: LANSyncPeerStatus) {
        self.peer = newPeer
        self.remoteStatus = status
        localInventory = LANSyncSupport.buildSyncInventory()
        selected = []
        withAnimation(.easeOut(duration: 0.15)) { page = .configure }
    }

    /// 发起同步：切进度页并交传输引擎执行（phase 状态由引擎发布）
    private func startSync() {
        guard let peer = peer, let remote = remoteStatus, !selected.isEmpty else { return }
        let cats = LANSyncCategory.allCases.filter { selected.contains($0) }
        withAnimation(.easeOut(duration: 0.15)) { page = .running }
        Task {
            await transfer.run(direction: direction, categories: cats, peer: peer, remoteStatus: remote)
        }
    }

    // MARK: - 接收方确认弹窗（本机作为接收方）

    /// pendingRequest 非空时呈现；系统侧关闭弹窗时 deny() 兜底释放挂起的 completion
    private var pairingAlertPresented: Binding<Bool> {
        Binding(
            get: { pairing.pendingRequest != nil },
            set: { shown in
                if !shown { pairing.deny() }
            }
        )
    }

    /// 弹窗正文：「设备 X 请求同步：自选、模拟交易…」（类别 rawValue 映射中文标题）
    private var pairingAlertMessage: String {
        guard let req = pairing.pendingRequest else { return "" }
        let titles = req.items.compactMap { LANSyncCategory(rawValue: $0)?.title }
        let text = titles.isEmpty ? req.items.joined(separator: "、") : titles.joined(separator: "、")
        return "设备 \(req.from) 请求同步：\(text)"
    }

    // MARK: - 私有小助手

    /// 类别清单人性化摘要：单文件 → 字节 + 修改时间；多文件 → N 个文件 / X MB；空 → 「—」
    private func sideSummary(_ item: LANSyncItem?) -> String {
        guard let item = item, !item.files.isEmpty else { return "—" }
        if item.files.count == 1 {
            let f = item.files[0]
            return "\(byteText(f.size)) · \(mtimeText(f.mod))"
        }
        return "\(item.files.count) 个文件 / \(byteText(item.totalBytes))"
    }

    /// 字节人性化（ByteCountFormatter，file 计数风格，KB / MB / GB 自适应）
    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// mtime 显示格式（静态缓存，避免每行每帧新建 DateFormatter）
    private static let mtimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private func mtimeText(_ ts: TimeInterval) -> String {
        Self.mtimeFormatter.string(from: Date(timeIntervalSince1970: ts))
    }
}

// MARK: - 手动直连解析失败抖动

/// 水平抖动效果：animatableData 从旧值动画到新值期间，正弦产生左右摆动
private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(animatableData * .pi * 3), y: 0))
    }
}

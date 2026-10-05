//
//  LANSyncView.swift
//  Kline
//
//  局域网设备联机同步 · UI 层（个人中心「联机同步」入口的全屏页面）。
//  仅拉取模型：手动扫描 / 暴露，本机只能获取对端内容到本机（无推送）。
//
//  页面三态（页内 @State 切换，不做 NavigationStack，与个人中心全屏 overlay 模式一致）：
//    devices   设备列表：本机服务状态（真实探测）+「暴露」开关（默认关：不广播不授权）+
//              「扫描一次」按钮（约 4s 窗口，结果保留）+ 已发现设备 + 手动 IP 直连兜底
//    configure 同步配置：固定方向为拉取 + 6 类内容勾选（本机量 vs 对端量）+ 开始拉取；
//              细粒度选择：自选可选具体分组、页面布局/指标公式可选具体文件（子项来自
//              对端 status.items[].children，旧版对端无此键 → 退回整类勾选行为）
//    running   进度与结果：建立同步会话 / 拉取进度 / 完成汇总 / 失败重试
//
//  暴露即授权：本机打开「暴露」开关后（LANSyncPairing.isExposed + LANSyncAdvertiser
//  广播），对端发起拉取无需逐次确认；退出本页自动取消暴露（unpublish + isExposed=false）。
//  主库被对端替换监听 .lansyncMainDBReplaced 通知弹重启提示。
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

    /// 设备发现（全局单例；点「扫描一次」触发 scanOnce，进页面不自动扫描）
    @ObservedObject private var discovery = LANSyncDiscovery.shared
    /// 本机暴露状态（isExposed；对端请求配对时服务端据此暴露即授权）
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

    /// 类别选择粒度：未选 / 整类全选 / 自定义子项集合（细粒度）
    private enum CategoryPick: Equatable {
        case none
        case all
        case custom(Set<String>)
    }

    /// 当前对端（连接成功后写入）
    @State private var peer: LANSyncPeer?
    /// 对端 /sync/status 快照（设备信息 + 6 类清单 + 细粒度子项）
    @State private var remoteStatus: LANSyncPeerStatus?
    /// 本机 6 类清单（进入 configure 时构建一次）
    @State private var localInventory: [LANSyncItem] = []
    /// 各类别的选择粒度（缺省 = .none）
    @State private var picks: [LANSyncCategory: CategoryPick] = [:]
    /// 展开（显示子项行）的类别集合
    @State private var expandedCats: Set<LANSyncCategory> = []

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
            // 不自动扫描（默认隐藏且不扫描）；若实例以 KLINE_EXPOSED=1 启动（UI 测试），
            // 开关已随 pairing.isExposed 显示为开，广播由 server 就绪回调恢复，无需在此补发
        }
        .onDisappear {
            // 退出联机同步页即取消暴露：停止 mDNS 广播 + 关闭暴露授权 + 吊销全部会话 token
            //（默认隐藏；已配对拉取方的后续请求立即 403）
            LANSyncAdvertiser.shared.unpublish()
            pairing.isExposed = false
            pairing.revokeAllTokens()
            // 已发现的 peers 保留（下次进入页面可直接看到上次扫描结果）
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
            exposeCard

            sectionLabel("已发现设备")
            scanButton
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

    /// 暴露开关卡片：开 = 对外发布 mDNS 广播并自动接受对端拉取请求（暴露即授权）；
    /// 关 = 本机对外隐藏（默认）。退出本页自动关闭。
    private var exposeCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("允许对端获取本机内容")
                    .font(.system(size: 16))
                    .foregroundColor(Color.primary)
                Text(pairing.isExposed ? "已暴露：对端可扫描到本机并拉取其内容" : "已隐藏：不广播、不接受同步")
                    .font(.system(size: 12))
                    .foregroundColor(pairing.isExposed ? .orange : Color(.tertiaryLabel))
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { pairing.isExposed },
                set: { setExposed($0) }
            ))
            .labelsHidden()
            .accessibilityIdentifier("lansync.expose.toggle")
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    /// 扫描一次按钮：单次浏览约 4s 后自动停止，结果保留在列表
    private var scanButton: some View {
        Button(action: { discovery.scanOnce() }) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                Text(discovery.isBrowsing ? "扫描中…" : "扫描一次")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(discovery.isBrowsing)
        .accessibilityIdentifier("lansync.scan.once")
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

                sectionLabel("获取内容（对端 → 本机）")
                VStack(spacing: 0) {
                    ForEach(LANSyncCategory.allCases) { cat in
                        categoryRow(cat)
                        // 展开的子项清单（细粒度选择：分组 / 具体文件）
                        if expandedCats.contains(cat) {
                            ForEach(children(of: cat), id: \.key) { child in
                                childRow(cat, child)
                            }
                        }
                        if let last = LANSyncCategory.allCases.last, cat != last {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)

                // 主库警示：勾选 main 时出现
                if case .all = pick(of: .main) {
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

    /// 单类内容行：勾选圈（点 = 整类全选/全不选切换，混合态 → 整类全选）+ 类别名 +
    /// 本机量 vs 对端量 +（对端提供子项时）展开箭头
    private func categoryRow(_ cat: LANSyncCategory) -> some View {
        let local = localInventory.first { $0.key == cat.rawValue }
        let remote = remoteStatus?.item(cat)
        let pick = pick(of: cat)
        return HStack(spacing: 0) {
            // 勾选圈（整类全选/全不选切换）
            Button(action: { toggleCategoryPick(cat) }) {
                HStack(spacing: 12) {
                    Image(systemName: pickIconName(pick))
                        .font(.system(size: 20))
                        .foregroundColor(pick == .none ? Color(.tertiaryLabel) : .blue)
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
                .padding(.leading, 16)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lansync.category.\(cat.rawValue)")

            // 子项展开箭头（仅对端提供 children 时显示；旧版对端无此键 → 行为与旧版一致）
            if !children(of: cat).isEmpty {
                Button(action: { toggleExpanded(cat) }) {
                    Image(systemName: expandedCats.contains(cat) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(.tertiaryLabel))
                        .padding(.horizontal, 18)
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lansync.expand.\(cat.rawValue)")
            }
        }
    }

    /// 子项行：勾选圈 + 名称 + 对端量（count 个 / 字节）
    private func childRow(_ cat: LANSyncCategory, _ child: LANSyncChild) -> some View {
        let checked = childChecked(child, of: cat)
        return Button(action: { toggleChildPick(cat, key: child.key) }) {
            HStack(spacing: 12) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(checked ? .blue : Color(.tertiaryLabel))
                Text(child.name)
                    .font(.system(size: 14))
                    .foregroundColor(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(childQuantity(child))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.leading, 48)
            .padding(.trailing, 16)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("lansync.child.\(cat.rawValue).\(child.key)")
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

    /// 开始拉取（无选中内容时禁用）：把对端勾选内容获取到本机（整类或子项集合）
    private var startButton: some View {
        Button(action: startSync) {
            Text("开始拉取")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Color.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(hasAnyPick ? Color.blue : Color.blue.opacity(0.35))
                .cornerRadius(12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasAnyPick)
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
                Text("正在建立同步会话…")
                    .font(.system(size: 17, weight: .semibold))
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
                    Text("已备份本机原文件到 Documents/\(backup)")
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

    /// 固定方向（仅拉取）与对端名（running 页各状态共用）
    private var directionText: String {
        "拉取：\(peer?.name ?? "对端") → 本机"
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

    /// 连接对端：取 /sync/status，成功进入配置页，失败按错误类型提示。
    /// 对端 exposed == false（已取消暴露）→ 提示并从扫描列表移除陈旧条目（mDNS 缓存滞后）。
    private func connect(peer target: LANSyncPeer) {
        guard !connecting else { return }
        connecting = true
        Task {
            do {
                let status = try await LANSyncDiscovery.fetchStatus(host: target.host, port: target.port)
                await MainActor.run {
                    self.connecting = false
                    if status.exposed == false {
                        // 对端已取消暴露：明确拒绝连接（而非放行到配对再 403）
                        self.discovery.removePeer(id: target.id)
                        self.alertTitle = "对端已取消暴露"
                        self.showAlert = true
                        return
                    }
                    self.enterConfigure(peer: target, status: status)
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
        picks = [:]
        expandedCats = []
        withAnimation(.easeOut(duration: 0.15)) { page = .configure }
    }

    /// 发起拉取：切进度页并交传输引擎执行（phase 状态由引擎发布）。
    /// 把各类别的选择粒度转成传输引擎的选择模型（整类 / 子项集合）。
    private func startSync() {
        guard let peer = peer, let remote = remoteStatus else { return }
        let sels: [LANSyncCategorySelection] = LANSyncCategory.allCases.compactMap { cat in
            switch pick(of: cat) {
            case .none:
                return nil
            case .all:
                return LANSyncCategorySelection(category: cat, mode: .all, childKeys: [])
            case .custom(let keys):
                return LANSyncCategorySelection(category: cat, mode: .children, childKeys: keys)
            }
        }
        guard !sels.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) { page = .running }
        Task {
            await transfer.run(selections: sels, peer: peer, remoteStatus: remote)
        }
    }

    /// 暴露开关动作：开 = 记录授权状态 + 发布 mDNS 广播（对端可扫描到并直接拉取）；
    /// 关 = 停止广播 + 收回授权 + 吊销全部会话 token（已配对的拉取方立即 403 中断，
    /// 直至再次暴露重新配对——「取消暴露后不能再被连接和访问」）。
    private func setExposed(_ on: Bool) {
        pairing.isExposed = on
        if on {
            LANSyncAdvertiser.shared.publish(port: KlineHTTPServer.shared.port,
                                             name: KlineHTTPServer.deviceName())
        } else {
            LANSyncAdvertiser.shared.unpublish()
            pairing.revokeAllTokens()
        }
    }

    // MARK: - 私有小助手

    /// 是否有任何选中内容（开始按钮可用性）
    private var hasAnyPick: Bool {
        picks.values.contains { pick in
            switch pick {
            case .all: return true
            case .custom(let keys): return !keys.isEmpty
            case .none: return false
            }
        }
    }

    /// 该类别当前的选择粒度（缺省 = 未选）
    private func pick(of cat: LANSyncCategory) -> CategoryPick {
        picks[cat] ?? .none
    }

    /// 对端提供的该类别子项清单（旧版对端 / 整类类别为 []，不显示展开箭头）
    private func children(of cat: LANSyncCategory) -> [LANSyncChild] {
        remoteStatus?.item(cat)?.children ?? []
    }

    /// 类别勾选圈动作：整类全选 ↔ 全不选切换（混合态 / 未选 → 整类全选）
    private func toggleCategoryPick(_ cat: LANSyncCategory) {
        picks[cat] = (pick(of: cat) == .all) ? .none : .all
    }

    /// 子项勾选动作：在自定义集合中增删；空集归一为未选、全集归一为整类全选
    private func toggleChildPick(_ cat: LANSyncCategory, key: String) {
        let allKeys = Set(children(of: cat).map(\.key))
        switch pick(of: cat) {
        case .none:
            picks[cat] = .custom([key])                    // 未选 → 勾第一个子项
        case .all:
            picks[cat] = .custom(allKeys.subtracting([key]))  // 全选 → 取消该子项
        case .custom(var set):
            if set.contains(key) {
                set.remove(key)
            } else {
                set.insert(key)
            }
            if set.isEmpty {
                picks[cat] = .none
            } else if set == allKeys {
                picks[cat] = .all
            } else {
                picks[cat] = .custom(set)
            }
        }
    }

    /// 子项当前是否勾选（整类 = 全勾；自定义 = 在集合内）
    private func childChecked(_ child: LANSyncChild, of cat: LANSyncCategory) -> Bool {
        switch pick(of: cat) {
        case .all: return true
        case .custom(let keys): return keys.contains(child.key)
        case .none: return false
        }
    }

    /// 展开 / 收起子项清单
    private func toggleExpanded(_ cat: LANSyncCategory) {
        if expandedCats.contains(cat) {
            expandedCats.remove(cat)
        } else {
            expandedCats.insert(cat)
        }
    }

    /// 类别勾选圈图标：整类=实心勾 / 混合态（部分子项选中）=空心勾 / 未选=空圈
    private func pickIconName(_ pick: CategoryPick) -> String {
        switch pick {
        case .all: return "checkmark.circle.fill"
        case .custom: return "checkmark.circle"
        case .none: return "circle"
        }
    }

    /// 子项对端量文案：分组 → "N 个"；文件 → 字节数
    private func childQuantity(_ child: LANSyncChild) -> String {
        if let count = child.count { return "\(count) 个" }
        return byteText(child.size)
    }

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

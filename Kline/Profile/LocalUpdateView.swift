//
//  LocalUpdateView.swift
//  Kline
//
//  Created on 2026/9/4.
//

import SwiftUI
import UIKit

/// 「本地更新」卡片组（个人中心内）：只保留两条状态行，行高固定 48，
/// 任何状态与点击都只替换右侧状态图标（图标位固定 24x24），
/// 不新增文本 / 额外行 / 列表，**布局永不变形**。
///
/// 1. 在线服务：进入个人中心（或回前台）自动探测一次本地 HTTP 服务（部署助手链路依赖它）；
///    探测中 = 黄「=」，在线 = 绿勾，离线 = 红叉且整行可点 = 重连。
/// 2. 检查新版（最新#N 当前 #M）：**页面打开即自动检查一次**，之后也可点这一行复检；
///    未检查 = 灰「=」，检查中 = 黄「…」，下载中 = 黄「圆圈+百分比数字」，
///    已是最新 = 绿勾，有新版或失败 = 红叉（点击 = 下载并安装 / 重试）。
///
/// 下载新版前会把沙盒内现有的 Kline.ipa 归档为 Kline_<当前构建号>.ipa（可回退手动安装），
/// 归档只保留版本号最大的 10 个，避免磁盘被历史 IPA 占满。
///
/// 另附「数据同步」卡片组：增量行情库（Documents/tdx_live.db）自动拉取开关 / 数据源 /
/// 更新时刻 / 同步状态 / 上次同步与版本 / 覆盖标的 / 局域网地址 / 立即更新。规格与「本地更新」完全一致
/// （13 semibold 灰标题、48pt 行高、16pt 左右 padding、secondarySystemBackground + 12 圆角）。
struct LocalUpdateView: View {

    @Environment(\.scenePhase) private var scenePhase

    /// 第二行的远程更新状态
    private enum RemoteState {
        case idle          // 未检查
        case checking      // 检查中
        case latest        // 已是最新
        case outdated      // 有新版（点击 = 下载并安装）
        case downloading   // 下载中
        case failed        // 检查/下载失败（点击 = 重试）
    }

    /// 归档保留数量：下载前归档上一版，超过该数量则按版本号从大到小保留
    private static let archiveKeepCount = 10

    @State private var serverOK = false
    @State private var serverProbing = false          // 在线服务探测中
    @State private var remoteState: RemoteState = .idle
    /// 远程最新构建号（检查成功后写入，用于标题「最新#N」）
    @State private var remoteBuildNumber: Int? = nil
    /// 下载进度 0~100（下载中显示在圆圈里）
    @State private var downloadPercent = 0

    // MARK: - 数据同步（增量行情库自动拉取）

    @ObservedObject private var syncConfig = TdxSyncConfig.shared
    @ObservedObject private var syncManager = TdxSyncManager.shared
    /// 增量库只读状态（覆盖标的数 / 最新交易日）
    @ObservedObject private var liveStore = LiveDataStore.shared
    /// 主库 meta（覆盖率分母 / 主库最新交易日）
    @ObservedObject private var dbManager = DatabaseManager.shared

    // MARK: - 合并到 tdx.db（增量库 → 主库）

    /// 合并流程状态
    private enum MergeState: Equatable { case idle, merging, done, failed }
    @State private var mergeState: MergeState = .idle
    @State private var showMergeAlert = false
    @State private var mergeAlertMessage = ""
    @State private var mergeResultText: String?

    /// 数据源地址编辑框内容（", " 分隔多个源）
    @State private var syncSourceText = ""
    /// 更新时刻编辑框内容（", " 分隔多个时刻）
    @State private var syncScheduleText = ""
    /// 输入防抖：停止输入 1s 后才写入配置
    @State private var syncCommitWork: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            localUpdateSection
            syncSection
        }
        .onAppear {
            refreshServerStatus()
            // 页面打开即自动检查一次 Git 最新版本；已在检查/下载中则不打断
            if !remoteBusy { checkGitHubUpdate() }
            // 编辑框回填当前配置（文本可能被规范化，如 "9:5" → "09:05"）
            syncSourceText = TdxSyncConfig.sourceText(syncConfig.sourceURLs)
            syncScheduleText = TdxSyncConfig.scheduleText(syncConfig.scheduleTimes)
        }
        // 回前台重新探测：服务器此时会自检并可能重建监听，界面要跟着显示真实结果
        .onChange(of: scenePhase) { phase in
            if phase == .active { refreshServerStatus() }
        }
        .onChange(of: syncSourceText) { _ in scheduleSyncConfigCommit() }
        .onChange(of: syncScheduleText) { _ in scheduleSyncConfigCommit() }
        // 二次确认（iOS 15：isPresented + actions/message）
        .alert("合并到 tdx.db", isPresented: $showMergeAlert) {
            Button("取消", role: .cancel) { }
            Button("合并") { performMerge() }
        } message: {
            Text(mergeAlertMessage)
        }
    }

    /// 「本地更新」卡片组（原有两条状态行，规格不变）
    private var localUpdateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 卡片组标题：与行情表设置的分组标题同规格（13 semibold 灰、左对齐卡片边缘）
            Text("本地更新")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.gray.opacity(0.85))

            VStack(spacing: 0) {
                statusRow(title: "在线服务",
                          enabled: !serverOK && !serverProbing,
                          action: reconnectServer) {
                    Image(systemName: serverIcon.0)
                        .font(.system(size: 18))
                        .foregroundColor(serverIcon.1)
                }

                Divider()

                statusRow(title: remoteTitle,
                          enabled: remoteTappable,
                          action: onRemoteRowTap) {
                    remoteStatusIcon
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
    }

    // MARK: - 状态行

    /// 状态行：行高固定、右侧图标位固定 —— 换图标/换色都不改变布局
    private func statusRow<Icon: View>(title: String, enabled: Bool,
                                       action: @escaping () -> Void,
                                       @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 16))
                Spacer(minLength: 12)
                icon()
                    .frame(width: 24, height: 24)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// 在线服务行：黄「=」探测中 / 绿勾在线 / 红叉离线
    private var serverIcon: (String, Color) {
        if serverProbing { return ("minus.circle.fill", .yellow) }
        return serverOK ? ("checkmark.circle.fill", .green) : ("xmark.circle.fill", .red)
    }

    /// 检查新版行：灰「=」未检查 / 黄「…」检查中 / 黄进度圈 下载中 / 绿勾最新 / 红叉有新版或失败
    @ViewBuilder
    private var remoteStatusIcon: some View {
        switch remoteState {
        case .idle:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.gray)
        case .checking:
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.yellow)
        case .downloading:
            downloadProgressIcon
        case .latest:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.green)
        case .outdated, .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.red)
        }
    }

    /// 下载进度：圆圈包着百分比数字（0~100），占位与其它状态图标一致（24x24）
    private var downloadProgressIcon: some View {
        ZStack {
            Circle()
                .stroke(Color.yellow.opacity(0.3), lineWidth: 2)
            Circle()
                .trim(from: 0, to: CGFloat(downloadPercent) / 100)
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(downloadPercent)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.yellow)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private var remoteTitle: String {
        let latest = remoteBuildNumber.map { "#\($0)" } ?? "#?"
        let current = GitHubUpdateService.currentBuildNumber.map { "#\($0)" } ?? "#?"
        return "检查新版（最新\(latest) 当前 \(current)）"
    }

    /// 检查/下载进行中
    private var remoteBusy: Bool {
        switch remoteState {
        case .checking, .downloading: return true
        default: return false
        }
    }

    /// 进行中不可点；其余状态都可点（最新时再点 = 复检）
    private var remoteTappable: Bool { !remoteBusy }

    // MARK: - 在线服务（自动探测；离线点击重连）

    private func refreshServerStatus() {
        serverProbing = true
        KlineHTTPServer.shared.probe { ok in
            DispatchQueue.main.async {
                self.serverOK = ok
                self.serverProbing = false
                DebugLogger.shared.log("本地更新面板探测本地服务：\(ok ? "在线" : "离线")")
            }
        }
    }

    private func reconnectServer() {
        serverProbing = true
        // 旧监听失效后状态可能仍是 .ready，必须强制重建；随后复探确认结果
        KlineHTTPServer.shared.restart()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            KlineHTTPServer.shared.probe { ok in
                DispatchQueue.main.async {
                    self.serverOK = ok
                    self.serverProbing = false
                    DebugLogger.shared.log("本地服务重连：\(ok ? "成功" : "失败")")
                }
            }
        }
    }

    // MARK: - 检查新版（页面打开自动检查一次；有新版时点击 = 下载并安装）

    private func onRemoteRowTap() {
        switch remoteState {
        case .idle, .latest, .failed: checkGitHubUpdate()
        case .outdated:               downloadAndInstallLatest()
        case .checking, .downloading: break
        }
    }

    private func checkGitHubUpdate() {
        remoteState = .checking
        GitHubUpdateService.fetchLatestRelease { info, err in
            if let err = err {
                self.remoteState = .failed
                DebugLogger.shared.log("检查新版失败：\(err)")
                return
            }
            let cur = GitHubUpdateService.currentBuildNumber
            self.remoteBuildNumber = info?.buildNumber
            if let n = info?.buildNumber, let c = cur, n > c {
                self.remoteState = .outdated
                DebugLogger.shared.log("发现新版本 #\(n)（当前 #\(c)）")
            } else {
                self.remoteState = .latest
                let remoteText = info?.buildNumber.map(String.init) ?? "?"
                DebugLogger.shared.log("已是最新（远程 #\(remoteText)，当前 #\(cur.map(String.init) ?? "?")）")
            }
        }
    }

    private func downloadAndInstallLatest() {
        // 先把现有 Kline.ipa 归档为 Kline_<当前构建号>.ipa，避免下载直接覆盖上一版
        archiveCurrentIPA()
        downloadPercent = 0
        remoteState = .downloading
        GitHubUpdateService.downloadLatestIPA(progress: { p in
            let pct = Int((p * 100).rounded())
            self.downloadPercent = min(100, max(0, pct))
        }) { _, err in
            if let err = err {
                self.remoteState = .failed
                DebugLogger.shared.log("下载最新 IPA 失败：\(err)")
                return
            }
            // 与 /install-local(scope=sandbox) 同一条链路：
            // 沙盒路径 IPA + opener 守护 → 装完自动打开新版（届时本页状态归零）
            KlineHTTPServer.shared.start()
            let dlURL = "http://127.0.0.1:\(KlineHTTPServer.shared.port)/sandbox/Downloads/Kline.ipa"
            let trollURL = "apple-magnifier://install?url=\(dlURL.percentEncodedForQuery)"
            // 拉起 TrollStore 前先申请后台执行时间：否则 App 切后台被挂起后，
            // TrollStore 从 127.0.0.1 取 IPA 会一直连得上却收不到数据，安装卡死（更谈不上自动打开）
            keepServingIPAForInstall()
            KlineHTTPServer.shared.triggerTrollStoreInstall(trollURL: trollURL)
            self.remoteState = .latest
            DebugLogger.shared.log("已下载最新 IPA，已拉起 TrollStore 安装")
        }
    }

    // MARK: - 安装期间保持本地服务可服务

    /// 拉起 TrollStore 前申请一段后台执行时间：App 会随 URL scheme 切到后台，
    /// 若被系统挂起，本地 HTTP 监听虽然还能被连上，但没人回包 →
    /// TrollStore 取 127.0.0.1 的 IPA 会卡住（部署助手那条路有 USB 转发兜底，故只有手动安装会踩到）。
    /// 到期自动释放，不影响正常后台行为。
    private func keepServingIPAForInstall(seconds: Double = 30) {
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "kline-serve-ipa") {
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        DebugLogger.shared.log("已申请后台执行时间 \(Int(seconds))s，确保 TrollStore 能取到沙盒 IPA")
    }

    // MARK: - 上一版 IPA 归档与清理（沙盒 Documents/Downloads）

    /// 下载新版前：把现有 Kline.ipa 改名为 Kline_<当前构建号>.ipa，
    /// 以便新版本有问题时可用归档包手动装回；随后只保留版本号最大的 N 个归档。
    private func archiveCurrentIPA() {
        let fm = FileManager.default
        let current = GitHubUpdateService.targetIpaPath                  // .../Documents/Downloads/Kline.ipa
        let dir = (current as NSString).deletingLastPathComponent
        guard fm.fileExists(atPath: current) else { return }             // 首次下载：无可归档
        let build = GitHubUpdateService.currentBuildNumber.map(String.init) ?? "unknown"
        let archive = dir + "/Kline_\(build).ipa"
        // 同版本重复下载：先清掉旧归档，避免同名 move 失败
        if fm.fileExists(atPath: archive) { try? fm.removeItem(atPath: archive) }
        do {
            // 同容器内直接 rename（跨容器会 EPERM，故不做跨目录搬运）
            try fm.moveItem(atPath: current, toPath: archive)
            DebugLogger.shared.log("已归档上一版 IPA：Kline_\(build).ipa")
        } catch {
            // 归档失败不阻断下载（下载流程会自行重建 Kline.ipa）
            DebugLogger.shared.log("归档上一版 IPA 失败：\(error)")
        }
        pruneArchives(in: dir, keeping: Self.archiveKeepCount)
    }

    /// 归档清理：目录内 Kline_<版本号>.ipa 超过 limit 个时，按版本号从大到小保留 limit 个
    private func pruneArchives(in dir: String, keeping limit: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        var archives: [(version: Int, name: String)] = []
        for name in names where name.hasPrefix("Kline_") && name.hasSuffix(".ipa") {
            if let v = Int(name.dropFirst("Kline_".count).dropLast(".ipa".count)) {
                archives.append((v, name))
            }
        }
        guard archives.count > limit else { return }
        archives.sort { $0.version > $1.version }
        for item in archives.dropFirst(limit) {
            try? fm.removeItem(atPath: dir + "/" + item.name)
            DebugLogger.shared.log("清理旧归档 IPA：\(item.name)")
        }
    }

    // MARK: - 数据同步（增量行情库自动拉取）

    /// 「数据同步」卡片组：开关 / 数据源 / 更新时刻 / 状态 / 上次同步 / 版本 / 覆盖标的 /
    /// 局域网地址 / 立即更新。行高统一 48、左右 padding 16，与「本地更新」卡片组完全同规格。
    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("数据同步")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.gray.opacity(0.85))

            // 各段均为 spacing 0 的 VStack，视觉上等价于一张连续卡片（分段只为控制 ViewBuilder 子视图数量）
            VStack(spacing: 0) {
                syncConfigRows
                syncStatusRows
                syncCoverageRows
                syncNetworkRows
                syncActionRows
                syncMergeRows
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
    }

    /// ① 开关 / ② 数据源地址 / ③ 更新时刻
    private var syncConfigRows: some View {
        VStack(spacing: 0) {
            // ① 启用开关：整行可点（命中区 48pt ≥ 44pt），Toggle 本身不拦截点击
            Button(action: { syncConfig.enabled.toggle() }) {
                HStack(spacing: 10) {
                    Text("启用自动更新")
                        .font(.system(size: 16))
                    Spacer(minLength: 12)
                    Toggle("", isOn: $syncConfig.enabled)
                        .labelsHidden()
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            // ② 数据源地址（可编辑：多个源用逗号分隔，按顺序回退）
            editRow(title: "数据源地址") {
                TextField("https://raw.githubusercontent.com/SunChuquin/Kline/data",
                          text: $syncSourceText)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }

            Divider()

            // ③ 更新时刻（可编辑："HH:mm"，逗号分隔）
            editRow(title: "更新时刻") {
                TextField("11:00, 14:30, 15:05", text: $syncScheduleText)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    /// ④ 同步状态 / ⑤ 上次同步 / ⑥ 数据版本 / ⑦ 覆盖标的
    private var syncStatusRows: some View {
        VStack(spacing: 0) {
            Divider()

            // ④ 同步状态（未启用 / 等待首次同步 / 同步中 / 已同步 / 失败）
            infoRow(title: "同步状态", value: syncStateText, valueColor: syncStateColor)

            Divider()

            // ⑤ 上次同步时间
            infoRow(title: "上次同步", value: syncLastTimeText)

            Divider()

            // ⑥ manifest 版本 + 行情交易日
            infoRow(title: "数据版本", value: syncVersionText)

            Divider()

            // ⑦ 增量库覆盖标的数与最新交易日（取 LiveDataStore 状态）
            infoRow(title: "覆盖标的", value: liveStore.status.isAvailable
                    ? "\(liveStore.status.metaCount) 只 · 最新 \(dateText(liveStore.status.latestDate))"
                    : "无增量库")
        }
    }

    /// ⑧ 覆盖率 / ⑨ 数据覆盖区间 / ⑩ 本次下载分片 / ⑪ 主库最新与缺口
    private var syncCoverageRows: some View {
        VStack(spacing: 0) {
            Divider()

            // ⑧ 增量覆盖标的数 / 主库标的数
            infoRow(title: "覆盖率", value: coverageText)

            Divider()

            // ⑨ 增量库覆盖的日期区间（min ~ max）
            infoRow(title: "数据覆盖", value: coverageRangeText)

            Divider()

            // ⑩ 本次下载的分片数与总字节（无分片时显示说明 / —）
            infoRow(title: "本次下载", value: bucketDownloadText)

            Divider()

            // ⑪ 主库最新交易日 + 到今日的缺口天数
            infoRow(title: "主库最新", value: mainLatestText)
        }
    }

    /// ⑫ 局域网地址：电脑侧局域网直推脚本要用的 `http://<设备IP>:5051`（只读信息，不可点）
    private var syncNetworkRows: some View {
        VStack(spacing: 0) {
            Divider()

            infoRow(title: "局域网地址", value: syncLanURLText)

            Text("电脑与设备同一 Wi-Fi 时，可用它做局域网直推（见项目文档 Kline-增量行情库自动同步）")
                .font(.system(size: 12))
                .foregroundColor(Color.gray.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ⑬ 本次所用源 / ⑭ 失败原因 / ⑮ 立即更新 / ⑯ 语义说明
    private var syncActionRows: some View {
        VStack(spacing: 0) {
            Divider()

            // ⑨ 本次同步实际使用的源
            infoRow(title: "本次所用源", value: syncUsedSourceText)

            // ⑩ 失败原因（仅失败时出现；多行不裁切，故用 minHeight）
            if let error = syncManager.lastError {
                Divider()
                HStack(spacing: 10) {
                    Text("失败原因")
                        .font(.system(size: 16))
                    Spacer(minLength: 12)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minHeight: 48)
            }

            Divider()

            // ⑪ 立即更新：整行可点（命中区 48pt ≥ 44pt），同步中显示进度圈
            Button(action: { syncManager.manualSync() }) {
                HStack(spacing: 10) {
                    Text("立即更新")
                        .font(.system(size: 16))
                        .foregroundColor(syncTappable ? Color.primary : Color.gray)
                    Spacer(minLength: 12)
                    if syncManager.isSyncing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18))
                            .foregroundColor(syncTappable ? Color.blue : Color.gray)
                            .frame(width: 24, height: 24)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!syncTappable)

            Divider()

            // ⑯ 语义说明：区分盘中快照与当日完整K线，避免误判
            Text("11:00 / 14:30 为盘中快照，15:05 为当日完整K线")
                .font(.system(size: 12))
                .foregroundColor(Color.gray.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ⑰ 合并到 tdx.db（二次确认）/ ⑱ 合并结果 / ⑲ 说明
    private var syncMergeRows: some View {
        VStack(spacing: 0) {
            Divider()

            // ⑰ 合并到 tdx.db：整行可点（命中区 48pt ≥ 44pt）；同步中 / 无增量 / 无可合并行时禁用
            Button(action: onMergeTap) {
                HStack(spacing: 10) {
                    Text("合并到 tdx.db")
                        .font(.system(size: 16))
                        .foregroundColor(mergeTappable ? Color.primary : Color.gray)
                    Spacer(minLength: 12)
                    if mergeState == .merging {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 18))
                            .foregroundColor(mergeTappable ? Color.blue : Color.gray)
                            .frame(width: 24, height: 24)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!mergeTappable)

            // ⑱ 合并结果（仅执行过合并后出现；多行不裁切，故用 minHeight）
            if let text = mergeResultText {
                Divider()
                HStack(spacing: 10) {
                    Text("合并结果")
                        .font(.system(size: 16))
                    Spacer(minLength: 12)
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundColor(mergeState == .failed ? .red : Color(.secondaryLabel))
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minHeight: 48)
            }

            Divider()

            // ⑲ 语义说明：合并只按主键 UPSERT，不删除主库历史
            Text("合并会把增量库的日/周/月线写回 tdx.db（按 标的+日期 主键覆盖，不删除历史行；失败自动回滚）")
                .font(.system(size: 12))
                .foregroundColor(Color.gray.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 同步状态（四态 + 已启用但尚未同步过）
    private enum SyncState { case disabled, idle, syncing, synced, failed }

    private var syncState: SyncState {
        if !syncConfig.enabled { return .disabled }
        if syncManager.isSyncing { return .syncing }
        if syncManager.lastError != nil { return .failed }
        return syncManager.lastSyncAt == nil ? .idle : .synced
    }

    private var syncStateText: String {
        switch syncState {
        case .disabled: return "未启用"
        case .idle:     return "等待首次同步" + syncNextSuffix
        case .syncing:  return "同步中…"
        case .synced:   return "已同步" + syncNextSuffix
        case .failed:   return "失败"
        }
    }

    /// 追加"下次计划时刻"（形如"（下次 今日 14:30）"）
    private var syncNextSuffix: String {
        syncManager.nextScheduledText.map { "（下次 \($0)）" } ?? ""
    }

    private var syncStateColor: Color {
        switch syncState {
        case .disabled, .idle: return .gray
        case .syncing:         return .yellow
        case .synced:          return .green
        case .failed:          return .red
        }
    }

    private var syncLastTimeText: String {
        guard let date = syncManager.lastSyncAt else { return "—" }
        return Self.syncTimeFormatter.string(from: date)
    }

    /// 形如 "v12（20260922）"；交易日缺失时只显示版本号
    private var syncVersionText: String {
        guard let version = syncManager.lastVersion else { return "—" }
        let trade = syncManager.lastTradeDate.map { "（\($0)）" } ?? ""
        return "v\(version)\(trade)"
    }

    private var syncUsedSourceText: String {
        guard let source = syncManager.lastSource else { return "—" }
        return URL(string: source)?.host ?? source
    }

    /// 局域网直推地址：`http://<设备IP>:5051`（端口取自 KlineHTTPServer，避免硬编码两份）；
    /// 每次渲染重算（LocalNetworkAddress 不缓存），取不到 IP 时提示未连接 Wi-Fi
    private var syncLanURLText: String {
        guard let ip = LocalNetworkAddress.currentIPv4() else { return "未连接 Wi-Fi" }
        return "http://\(ip):\(KlineHTTPServer.shared.port)"
    }

    /// 仅"已启用且当前不在同步中"可点（未启用时不允许拉取）
    private var syncTappable: Bool { syncConfig.enabled && !syncManager.isSyncing }

    // MARK: - 覆盖率 / 分片 / 主库缺口（取不到一律显示 —）

    /// 覆盖率：优先取 manifest 声明的 `covered/universe`（v3；电脑侧 3611/3611，云端兜底约 3312/3611），
    /// 未同步过时回落到「本地增量覆盖 file 数 / 主库 meta 总数」
    private var coverageText: String {
        let universe = syncManager.lastUniverse
        let covered = syncManager.lastCovered
        if universe > 0 {
            return "覆盖 \(covered)/\(universe)（\(percentText(covered, universe))）"
        }
        let total = dbManager.metaList.count
        let local = liveStore.status.metaCount
        guard liveStore.status.isAvailable else { return "—" }
        guard total > 0 else { return "覆盖 \(local) 只" }
        return "覆盖 \(local)/\(total)（\(percentText(local, total))）"
    }

    /// 百分比文案（分母为 0 → "0%"）
    private func percentText(_ part: Int, _ whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        return "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
    }

    /// 增量库覆盖的日期区间（最早 ~ 最新）
    private var coverageRangeText: String {
        let earliest = liveStore.status.earliestDate
        let latest = liveStore.status.latestDate
        guard liveStore.status.isAvailable, earliest > 0, latest > 0 else { return "—" }
        return "\(earliest) ~ \(latest)"
    }

    /// 本次下载分片数与总字节；无分片时回落到说明文案
    private var bucketDownloadText: String {
        if syncManager.lastBucketCount > 0 {
            let bytes = ByteCountFormatter.string(fromByteCount: syncManager.lastBucketBytes, countStyle: .file)
            return "\(syncManager.lastBucketCount) 片 · \(bytes)"
        }
        return syncManager.lastNote ?? "—"
    }

    /// 主库最新交易日 + 到今日的缺口天数
    private var mainLatestText: String {
        let latest = dbManager.metaList.compactMap { $0.lastDate }.max() ?? 0
        guard latest > 0 else { return "—" }
        return "\(latest)（缺口 \(TdxSyncManager.naturalDaysSince(latest)) 天）"
    }

    // MARK: - 合并到 tdx.db

    /// 合并可点条件：增量库可用且有日线行、当前不在同步、也不在合并中
    private var mergeTappable: Bool {
        guard liveStore.status.isAvailable, liveStore.status.dailyCount > 0 else { return false }
        return !syncManager.isSyncing && mergeState != .merging
    }

    /// 点击「合并到 tdx.db」：先后台算出「写入 N 根 / 覆盖 M 只 / 最新交易日」，再弹二次确认
    private func onMergeTap() {
        guard mergeTappable else { return }
        mergeState = .merging          // 预估期间同样显示进度并禁用按钮
        mergeResultText = nil
        MainDBMerger.shared.previewMerge { preview in
            mergeState = .idle
            if preview.isMergeable {
                // M = 按 `file` 命中主库 meta 的标的数（`code` 有 55 处重复，不能作键）
                mergeAlertMessage = "将写入 \(preview.totalRows) 根K线、覆盖 \(preview.hitSymbols) 只标的、"
                    + "最新交易日 \(preview.latestDate)。\n\n"
                    + "按「标的 + 日期」主键写回 tdx.db，不删除任何历史行；任一步失败会自动回滚。"
            } else {
                mergeAlertMessage = "增量库暂无可合并到主库的行（可能已合并过或已被裁剪）。"
            }
            showMergeAlert = true
        }
    }

    /// 确认后执行合并（主库单事务 UPSERT → 裁剪增量 → 热刷新）
    private func performMerge() {
        mergeState = .merging
        mergeResultText = nil
        MainDBMerger.shared.mergeIncrementIntoMainDB { result in
            DebugLogger.shared.log("[Merge] \(result.message)")
            if result.ok {
                mergeState = .done
                mergeResultText = "已合并 \(result.totalRows) 根 / 覆盖 \(result.hitSymbols) 只 / 最新 \(result.latestDate)"
            } else {
                mergeState = .failed
                mergeResultText = result.message
            }
        }
    }

    /// YYYYMMDD 原样展示（0 = 无数据）
    private func dateText(_ value: Int) -> String {
        value == 0 ? "—" : String(value)
    }

    private static let syncTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// 可编辑行（左标题 + 右侧编辑控件），行高 48，与只读信息行同规格
    private func editRow<Field: View>(title: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 16))
                .fixedSize()
            Spacer(minLength: 12)
            field()
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    /// 只读信息行（左标题 + 右值），行高固定 48
    private func infoRow(title: String, value: String,
                         valueColor: Color = Color(.secondaryLabel)) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 16))
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 15))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    // MARK: - 编辑框 → 配置（1s 防抖，避免每敲一个字符就持久化）

    private func scheduleSyncConfigCommit() {
        syncCommitWork?.cancel()
        let item = DispatchWorkItem { commitSyncTexts() }
        syncCommitWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func commitSyncTexts() {
        let urls = TdxSyncConfig.parseSourceText(syncSourceText)
        if !urls.isEmpty, urls != syncConfig.sourceURLs {
            syncConfig.sourceURLs = urls
            DebugLogger.shared.log("[TdxSync] 数据源已更新为 \(urls.count) 条")
        }
        let times = TdxSyncConfig.parseScheduleText(syncScheduleText)
        guard !times.isEmpty else { return }
        if times != syncConfig.scheduleTimes {
            syncConfig.scheduleTimes = times
            DebugLogger.shared.log("[TdxSync] 更新时刻已更新为 \(times.joined(separator: ","))")
        }
        let normalized = TdxSyncConfig.scheduleText(times)
        if normalized != syncScheduleText { syncScheduleText = normalized }
    }
}
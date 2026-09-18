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

    var body: some View {
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
        .onAppear {
            refreshServerStatus()
            // 页面打开即自动检查一次 Git 最新版本；已在检查/下载中则不打断
            if !remoteBusy { checkGitHubUpdate() }
        }
        // 回前台重新探测：服务器此时会自检并可能重建监听，界面要跟着显示真实结果
        .onChange(of: scenePhase) { phase in
            if phase == .active { refreshServerStatus() }
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
}
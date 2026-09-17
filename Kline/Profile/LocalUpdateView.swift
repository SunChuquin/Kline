//
//  LocalUpdateView.swift
//  Kline
//
//  Created on 2026/9/4.
//

import SwiftUI

/// 「本地更新」卡片组（个人中心内）：只保留两条状态行，行高固定 48，
/// 任何状态与点击都只替换右侧状态图标（图标占位固定 24x24），
/// 不新增文本 / 进度块 / 列表，**布局永不变形**。
///
/// 1. 在线服务：进入个人中心（或回前台）自动探测一次本地 HTTP 服务（部署助手链路依赖它）；
///    探测中 = 黄「=」，在线 = 绿勾，离线 = 红叉且整行可点 = 重连。
/// 2. 检查新版（当前 #N）：只由用户点这一行触发检查（不自动）；
///    未检查 = 灰「=」，检查/下载中 = 黄「=」，已是最新 = 绿勾（可再点复检），
///    有新版或失败 = 红叉（点击 = 下载并安装 / 重试检查）。
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

    @State private var serverOK = false
    @State private var serverProbing = false          // 在线服务探测中
    @State private var remoteState: RemoteState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 卡片组标题：与行情表设置的分组标题同规格（13 semibold 灰、左对齐卡片边缘）
            Text("本地更新")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.gray.opacity(0.85))

            VStack(spacing: 0) {
                statusRow(title: "在线服务",
                          icon: serverIcon.0,
                          tint: serverIcon.1,
                          enabled: !serverOK && !serverProbing,
                          action: reconnectServer)

                Divider()

                statusRow(title: remoteTitle,
                          icon: remoteIcon.0,
                          tint: remoteIcon.1,
                          enabled: remoteTappable,
                          action: onRemoteRowTap)
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
        .onAppear {
            refreshServerStatus()
        }
        // 回前台重新探测：服务器此时会自检并可能重建监听，界面要跟着显示真实结果
        .onChange(of: scenePhase) { phase in
            if phase == .active { refreshServerStatus() }
        }
    }

    // MARK: - 状态行

    /// 状态行：行高固定、右侧状态图标占位固定 —— 换图标/换色都不改变布局
    private func statusRow(title: String, icon: String, tint: Color,
                           enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 16))
                Spacer(minLength: 12)
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(tint)
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

    /// 检查新版行：灰「=」未检查 / 黄「=」进行中 / 绿勾最新 / 红叉有新版或失败
    private var remoteIcon: (String, Color) {
        switch remoteState {
        case .idle:                   return ("minus.circle.fill", .gray)
        case .checking, .downloading: return ("minus.circle.fill", .yellow)
        case .latest:                 return ("checkmark.circle.fill", .green)
        case .outdated, .failed:      return ("xmark.circle.fill", .red)
        }
    }

    private var remoteTitle: String {
        "检查新版（当前 #\(GitHubUpdateService.currentBuildNumber.map(String.init) ?? "?")）"
    }

    /// 检查/下载进行中时不可点，其余状态都可点（最新时再点 = 复检）
    private var remoteTappable: Bool {
        switch remoteState {
        case .checking, .downloading: return false
        default: return true
        }
    }

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

    // MARK: - 检查新版（仅手动触发；有新版时点击 = 下载并安装）

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
        remoteState = .downloading
        // 行内不展示百分比：进度只体现为「黄=进行中」，保证布局不变形（细节见 debug_log）
        GitHubUpdateService.downloadLatestIPA(progress: { _ in }) { _, err in
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
            KlineHTTPServer.shared.triggerTrollStoreInstall(trollURL: trollURL)
            self.remoteState = .latest
            DebugLogger.shared.log("已下载最新 IPA，已拉起 TrollStore 安装")
        }
    }
}
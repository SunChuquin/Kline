//
//  LocalUpdateView.swift
//  Kline
//
//  Created on 2026/9/4.
//

import SwiftUI

/// 更新面板：扫描公共 Downloads 目录的 IPA 文件（支持共享到 TrollStore 安装），
/// 以及远程更新（GitHub Release 最新构建：检查新版 → 下载 → 自动拉起 TrollStore，免 USB）。
/// 需要 no-sandbox 权限才能访问 /var/mobile/Media/Downloads（TrollStore 版可用，
/// Xcode 调试版降级显示错误，不崩溃）。
struct LocalUpdateView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var ipaFiles: [IPAFileInfo] = []
    @State private var isScanning = false
    @State private var scanResult: String = ""
    @State private var logScanResult: String = ""
    @State private var entitlementCheckResult: String = ""
    /// 本地 HTTP 服务是否在线（供状态标签显示，点击可重连）
    @State private var serverOK = false
    /// 远程更新（GitHub Release 最新构建）状态
    @State private var ghChecking = false
    @State private var ghMessage = ""
    @State private var ghDownloading = false
    @State private var ghProgress: Double = 0
    @State private var ghHasNewer = false

    /// 沙盒 Documents 根路径
    private var sandboxRoot: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }
    /// 沙盒内 IPA 目录（自动部署助手把 IPA 传到沙盒 Downloads/ 下）
    private var downloadsPath: String {
        sandboxRoot + "/Downloads"
    }
    /// 沙盒内日志文件（DebugLogger 统一写 Documents/debug_log.txt）
    private var logFilePath: String {
        sandboxRoot + "/debug_log.txt"
    }

    /// 当前 App 版本号
    private var currentVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }

    var body: some View {
        // 视觉层级上限 = 2 层：页面底（L1）+ 本卡片（L2）。
        // 卡内一律不再铺第二层底色，内容靠 Divider + 统一行式按钮区分层级。
        VStack(spacing: 0) {
            // 标题行
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.blue)
                Text("本地更新")
                    .font(.headline)
                Spacer()
                Text("当前: \(currentVersion)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            // 本地服务连接状态（点击可重连；断开时显示红色）
            Button(action: reconnectServer) {
                HStack(spacing: 8) {
                    Image(systemName: serverOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(serverOK ? .green : .red)
                    Text(serverOK ? "本地服务在线（点击检测）" : "本地服务离线（点击重连）")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            // 扫描按钮
            actionRow(icon: "magnifyingglass",
                      title: isScanning ? "扫描中..." : "扫描本地 IPA",
                      busy: isScanning,
                      action: scanDownloads)

            Divider()

            // 扫描本地日志按钮（只显示文件信息，不读内容）
            actionRow(icon: "doc.text.magnifyingglass",
                      title: "扫描本地日志",
                      action: scanLocalLog)

            // 日志扫描结果
            infoText(logScanResult)

            // 扫描结果列表：每个 IPA 一行（文件名 + 大小/日期 + 右侧安装）
            ForEach(Array(ipaFiles.enumerated()), id: \.element.id) { index, file in
                Divider()
                IPARowView(file: file) {
                    shareIPA(file)
                }
                if index == ipaFiles.count - 1 { Divider() }
            }

            // 扫描状态
            infoText(scanResult)

            Divider()

            // 远程更新（GitHub Release 最新构建）：免 USB，iPad 联网即可拉取 CI 最新 IPA 安装
            HStack {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundColor(.blue)
                Text("远程更新（GitHub 最新构建）")
                    .font(.system(size: 15))
                Spacer()
                Text("当前 #\(GitHubUpdateService.currentBuildNumber.map(String.init) ?? "?")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)

            infoText(ghMessage, tint: ghHasNewer ? .green : nil)

            actionRow(icon: "arrow.triangle.2.circlepath",
                      title: ghChecking ? "检查中..." : "检查新版",
                      busy: ghChecking,
                      action: checkGitHubUpdate)

            Divider()

            actionRow(icon: "arrow.down.circle",
                      title: ghDownloading ? "下载中..." : "下载并安装",
                      busy: ghDownloading,
                      action: downloadAndInstallLatest)

            if ghDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: ghProgress)
                    Text("\(Int(ghProgress * 100))% · 下载完成后自动拉起 TrollStore")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 10)
            }

            Divider()

            // 权限自检（非主流程入口：保留橙色与蓝色主操作区分）
            actionRow(icon: "shield.checkered",
                      title: "权限自检（no-sandbox 验证）",
                      tint: .orange,
                      action: checkEntitlements)

            infoText(entitlementCheckResult)
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .onAppear {
            refreshServerStatus()
        }
        // 回前台重新探测：服务器此时会自检并可能重建监听，界面要跟着显示真实结果
        .onChange(of: scenePhase) { phase in
            if phase == .active { refreshServerStatus() }
        }
    }

    // MARK: - 卡内构建块（统一规格：无自有底色、行高 44、单一强调色）

    /// 行式操作按钮：左图标 + 标题 + 右箭头（忙碌时右箭头换成转圈）
    private func actionRow(icon: String, title: String, busy: Bool = false,
                           tint: Color = .blue, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 22, alignment: .leading)
                Text(title)
                    .font(.system(size: 15))
                Spacer(minLength: 8)
                if busy {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.gray.opacity(0.6))
                }
            }
            .foregroundColor(tint)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    /// 卡内结果/说明文本（统一缩进与字色；tint 仅用于“有新版本”这类语义强调）
    @ViewBuilder
    private func infoText(_ text: String, tint: Color? = nil) -> some View {
        if !text.isEmpty {
            Text(text)
                .font(.caption)
                .foregroundColor(tint ?? .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
    }

    // MARK: - 本地服务状态（点击重连）

    private func refreshServerStatus() {
        // 必须真探测：isRunning 只是 NWListener 的状态快照，长时间后台后会失真（假在线）
        KlineHTTPServer.shared.probe { ok in
            DispatchQueue.main.async { self.serverOK = ok }
        }
    }

    private func reconnectServer() {
        scanResult = "已尝试重连本地服务…"
        // 强制重建监听：旧 listener 失效后状态可能仍是 .ready，直接 start() 会被跳过（点了没反应）
        KlineHTTPServer.shared.restart()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            KlineHTTPServer.shared.probe { ok in
                DispatchQueue.main.async {
                    self.serverOK = ok
                    self.scanResult = ok ? "✅ 本地服务已恢复在线" : "❌ 重连失败，请检查 App 状态"
                }
            }
        }
    }

    // MARK: - 扫描 Downloads 目录

    private func scanDownloads() {
        isScanning = true
        scanResult = ""
        ipaFiles = []

        DispatchQueue.global(qos: .userInitiated).async {
            var files: [IPAFileInfo] = []

            do {
                let entries = try FileManager.default.contentsOfDirectory(atPath: downloadsPath)
                for entry in entries where entry.lowercased().hasSuffix(".ipa") {
                    let fullPath = "\(downloadsPath)/\(entry)"
                    let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    let modDate = (attrs?[.modificationDate] as? Date) ?? Date()

                    files.append(IPAFileInfo(
                        path: fullPath,
                        name: entry,
                        size: size,
                        modDate: modDate
                    ))
                }

                files.sort { $0.modDate > $1.modDate }

                DispatchQueue.main.async {
                    self.ipaFiles = files
                    self.isScanning = false
                    if files.isEmpty {
                        self.scanResult = "Downloads 目录无 IPA 文件"
                    } else {
                        self.scanResult = "找到 \(files.count) 个 IPA 文件"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isScanning = false
                    self.scanResult = "❌ 无法访问 \(self.downloadsPath)\n\(error.localizedDescription)\n\n此功能需要 TrollStore 版（no-sandbox 权限）"
                }
            }
        }
    }

    // MARK: - 扫描本地日志（只显示文件信息，不读日志内容）

    private func scanLocalLog() {
        logScanResult = "检测中..."

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var result: String
            if fm.fileExists(atPath: logFilePath),
               let attrs = try? fm.attributesOfItem(atPath: logFilePath) {
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let modDate = (attrs[.modificationDate] as? Date) ?? Date()

                let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm:ss"
                result = "✅ \(logFilePath.components(separatedBy: "/").last ?? "debug_log.txt")\n   大小: \(sizeStr) · 修改: \(df.string(from: modDate))"
            } else {
                result = "❌ 未找到日志文件\n   \(logFilePath)\n   (需 TrollStore 版启动过 Kline 才会生成)"
            }
            DispatchQueue.main.async {
                self.logScanResult = result
            }
        }
    }

    // MARK: - 远程更新（GitHub Release 最新构建）：检查最新版 + 下载安装

    /// 查询 GitHub 最新 release，与当前构建号比对并提示
    private func checkGitHubUpdate() {
        ghChecking = true
        ghMessage = "正在检查 GitHub 最新构建..."
        ghHasNewer = false
        GitHubUpdateService.fetchLatestRelease { info, err in
            self.ghChecking = false
            if let err = err {
                self.ghMessage = "❌ 检查失败：\(err)"
                return
            }
            let pub = info?.publishedText.map { " · \($0)" } ?? ""
            let cur = GitHubUpdateService.currentBuildNumber
            if let n = info?.buildNumber {
                if let c = cur {
                    if n > c {
                        self.ghHasNewer = true
                        self.ghMessage = "✅ 发现新版本 #\(n)（当前 #\(c)）\(pub)"
                    } else if n == c {
                        self.ghMessage = "当前已是最新版本 #\(n)\(pub)"
                    } else {
                        self.ghMessage = "远程 #\(n) 不高于当前 #\(c)，可重新安装\(pub)"
                    }
                } else {
                    self.ghMessage = "远程最新版 #\(n)\(pub)（当前构建号未知，可下载覆盖安装）"
                }
            } else {
                self.ghMessage = "远程最新版可用\(pub)（构建号未知，可下载覆盖安装）"
            }
        }
    }

    /// 下载最新 IPA 到公共 Downloads，再经本地 HTTP + opener 拉起 TrollStore 安装
    private func downloadAndInstallLatest() {
        ghDownloading = true
        ghProgress = 0
        ghMessage = "正在下载最新 IPA ..."
        GitHubUpdateService.downloadLatestIPA(progress: { p in
            self.ghProgress = p
        }) { size, err in
            self.ghDownloading = false
            if let err = err {
                self.ghMessage = "❌ 下载失败：\(err)"
                return
            }
            let sizeText = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
            self.ghMessage = "✅ 已下载 \(sizeText)，正在拉起 TrollStore 安装..."
            // 与 /install-local(scope=sandbox)、shareIPA 同一链路：
            // KlineHTTP /sandbox/Downloads 供 IPA + opener 装完自动打开新版（沙盒路径，避开公共目录写权限）
            KlineHTTPServer.shared.start()
            let dlURL = "http://127.0.0.1:\(KlineHTTPServer.shared.port)/sandbox/Downloads/Kline.ipa"
            let trollURL = "apple-magnifier://install?url=\(dlURL.percentEncodedForQuery)"
            KlineHTTPServer.shared.triggerTrollStoreInstall(trollURL: trollURL)
            self.ghMessage += "\n(弹「在 TrollStore 中打开？」→ 打开 → Install；装完自动回到新版)"
        }
    }

    // MARK: - 安装 IPA 到 TrollStore（沙盒本地 HTTP + URL Scheme，绕过共享面板崩溃）

    /// 原理：platform-application 权限下系统共享面板（UIActivityViewController）
    /// 生成 AirDrop 图标时 CoreImage GL 上下文空指针崩溃（iOS 系统组件问题）。
    /// 改为 Kline 起本地 HTTP 服务器暴露 /sandbox/Downloads/<file>，用
    /// `apple-magnifier://install?url=http://127.0.0.1:5051/sandbox/Downloads/<file>` 拉起 TrollStore。
    private func shareIPA(_ file: IPAFileInfo) {
        // 确保本地 HTTP 服务器已启动（提供 /sandbox/Downloads/<file>）
        KlineHTTPServer.shared.start()

        let safeName = (file.name as NSString).lastPathComponent
        // 沙盒直连 URL：TrollStore 经 KlineHTTP /sandbox 下载沙盒 IPA 安装
        let downloadURL = "http://127.0.0.1:\(KlineHTTPServer.shared.port)/sandbox/Downloads/\(safeName.percentEncodedForQuery)"
        let trollURL = "apple-magnifier://install?url=\(downloadURL.percentEncodedForQuery)"

        scanResult = "正在拉起 TrollStore 安装 \(safeName) ...\n(如系统弹确认框请选择「打开」)"

        DispatchQueue.main.async {
            if let url = URL(string: trollURL) {
                UIApplication.shared.open(url) { success in
                    if !success {
                        self.scanResult = "❌ 无法拉起 TrollStore\n请手动打开 TrollStore → + → 沙盒 Downloads/\(safeName)"
                    }
                }
            }
        }
    }

    // MARK: - 权限自检（验证 no-sandbox 是否生效）

    private func checkEntitlements() {
        entitlementCheckResult = "检测中..."

        DispatchQueue.global(qos: .userInitiated).async {
            var results: [String] = []

            // 测试 1：读 Downloads 目录
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: "/var/mobile/Media/Downloads") {
                results.append("✅ Downloads/ 可读（\(entries.count) 项）")
            } else {
                results.append("❌ Downloads/ 不可读")
            }

            // 测试 2：读根目录
            if let _ = try? FileManager.default.contentsOfDirectory(atPath: "/") {
                results.append("✅ / 根目录可读")
            } else {
                results.append("❌ / 根目录不可读")
            }

            DispatchQueue.main.async {
                self.entitlementCheckResult = results.joined(separator: "\n")
            }
        }
    }
}

// MARK: - IPA 文件信息

struct IPAFileInfo: Identifiable {
    let id = UUID()
    let path: String
    let name: String
    let size: Int64
    let modDate: Date
}

// MARK: - IPA 文件行（卡内扁平行，无自有底色）

struct IPARowView: View {
    let file: IPAFileInfo
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "app.badge")
                .font(.system(size: 15))
                .foregroundColor(.blue)
                .frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.system(size: 15))
                    .lineLimit(1)
                Text("\(formatSize(file.size)) · \(formatDate(file.modDate))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onShare) {
                Text("安装")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}

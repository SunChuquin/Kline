//
//  LocalUpdateView.swift
//  Kline
//
//  Created on 2026/9/4.
//

import SwiftUI

/// 本地更新面板：扫描公共 Downloads 目录的 IPA 文件，支持共享到 TrollStore 安装。
/// 需要 no-sandbox 权限才能访问 /var/mobile/Media/Downloads（TrollStore 版可用，
/// Xcode 调试版降级显示错误，不崩溃）。
struct LocalUpdateView: View {
    @State private var ipaFiles: [IPAFileInfo] = []
    @State private var isScanning = false
    @State private var scanResult: String = ""
    @State private var logScanResult: String = ""
    @State private var importResult: String = ""
    @State private var legacyResult: String = ""
    @State private var entitlementCheckResult: String = ""

    private let downloadsPath = "/var/mobile/Media/Downloads"
    /// 日志文件名（TrollStore 版写到公共 Downloads/KlineLogs/ 下）
    private let logFilePath = "/var/mobile/Media/Downloads/KlineLogs/debug_log.txt"
    /// Xcode 旧版 Kline（com.sunck.Kline.4G3V8W86TN）的容器数据库路径
    private let legacyDBPath = "/private/var/mobile/Containers/Data/Application/CA1413A6-9D2A-4291-A2F6-A079B8AFD26C/Documents/tdx.db"

    /// 当前 App 版本号
    private var currentVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 16) {
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

            // 扫描按钮
            Button(action: scanDownloads) {
                HStack {
                    if isScanning {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text(isScanning ? "扫描中..." : "扫描本地 IPA")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
            .disabled(isScanning)

            // 扫描本地日志按钮（只显示文件信息，不读内容）
            Button(action: scanLocalLog) {
                HStack {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("扫描本地日志")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.teal.opacity(0.12))
                .cornerRadius(8)
            }

            // 日志扫描结果
            if !logScanResult.isEmpty {
                Text(logScanResult)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 导入 tdx.db 按钮（把公共 Downloads 的完整数据库复制进本 App 容器）
            Button(action: importTdxDB) {
                HStack {
                    Image(systemName: "square.and.arrow.down.on.square")
                    Text("导入 tdx.db（从 Downloads）")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.purple.opacity(0.12))
                .cornerRadius(8)
            }

            // 导入结果
            if !importResult.isEmpty {
                Text(importResult)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 使用旧版行情库按钮（直接只读挂载 Xcode 旧版容器数据库，不拷贝）
            Button(action: useLegacyDB) {
                HStack {
                    Image(systemName: "externaldrive.fill.badge.checkmark")
                    Text("使用旧版行情库（Xcode 版）")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.indigo.opacity(0.12))
                .cornerRadius(8)
            }

            // 旧版库切换结果
            if !legacyResult.isEmpty {
                Text(legacyResult)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 扫描结果列表
            if !ipaFiles.isEmpty {
                ForEach(ipaFiles) { file in
                    IPACardView(file: file) {
                        shareIPA(file)
                    }
                }
            }

            // 扫描状态
            if !scanResult.isEmpty {
                Text(scanResult)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 分隔线
            Divider()

            // 权限自检
            Button(action: checkEntitlements) {
                HStack {
                    Image(systemName: "shield.checkered")
                    Text("权限自检（no-sandbox 验证）")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            if !entitlementCheckResult.isEmpty {
                Text(entitlementCheckResult)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
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

    // MARK: - 导入 tdx.db（优先公共 Downloads，其次自动扫描其他 Kline 容器）

    /// 场景：TrollStore 版是新容器，只有 bundle 种子库（1 个演示标的）。
    /// 数据源按优先级：
    /// 1. 公共 Downloads/tdx.db（用户手动导出的）
    /// 2. 自动扫描 /var/mobile/Containers/Data/Application/ 下其他容器的 tdx.db
    ///    （Xcode 旧版的数据通常最大，自动选最大的一份；no-sandbox 可读容器目录）
    private func importTdxDB() {
        let fm = FileManager.default

        // 候选 1：公共 Downloads
        var src: String? = nil
        var sourceNote = "公共 Downloads"
        let pubPath = "/var/mobile/Media/Downloads/tdx.db"
        if fm.fileExists(atPath: pubPath) {
            src = pubPath
        }

        // 候选 2：自动扫描其他容器
        if src == nil {
            if let other = findLargestOtherTdxDB() {
                src = other
                sourceNote = "自动找到的其他容器（Xcode 旧版）"
            }
        }

        guard let source = src else {
            importResult = "❌ 未找到 tdx.db\n公共 Downloads 无，且无法扫描到其他容器的数据库\n可用「文件」App 把旧版 Kline 的 tdx.db 存到「我的 iPad/下载」后再试"
            return
        }

        let dst = DatabaseManager.writableDBPath
        let srcSize = (try? fm.attributesOfItem(atPath: source)[.size] as? NSNumber)?.int64Value ?? -1
        DebugLogger.shared.log("导入开始 src=\(source)(\(srcSize)) dst=\(dst) dstExists=\(fm.fileExists(atPath: dst)) srcExists=\(fm.fileExists(atPath: source))")

        do {
            // 覆盖前先备份旧库（种子库），万一失败可回退
            if fm.fileExists(atPath: dst) {
                let backup = dst + ".bak"
                try? fm.removeItem(atPath: backup)
                try? fm.copyItem(atPath: dst, toPath: backup)
            }
            try fm.removeItem(atPath: dst)
            try fm.copyItem(atPath: source, toPath: dst)
            importResult = "✅ tdx.db 已导入（来源：\(sourceNote)）\n请完全退出并重新打开 Kline 生效"
            DebugLogger.shared.log("导入 tdx.db 成功: \(source) -> \(dst)")
        } catch {
            importResult = "❌ 导入失败：\(error.localizedDescription)"
            DebugLogger.shared.log("导入 tdx.db 失败: \(error)")
        }
    }

    /// 扫描所有 App 容器下的 Documents/tdx.db，返回本容器之外最大的那份（旧版完整数据）
    private func findLargestOtherTdxDB() -> String? {
        let containersRoot = "/var/mobile/Containers/Data/Application"
        let myHome = NSHomeDirectory()
        let fm = FileManager.default
        guard let uuids = try? fm.contentsOfDirectory(atPath: containersRoot) else {
            DebugLogger.shared.log("导入扫描 容器根不可读: \(containersRoot)")
            return nil
        }
        var best: (path: String, size: Int64)?
        for uuid in uuids {
            let db = "\(containersRoot)/\(uuid)/Documents/tdx.db"
            guard fm.fileExists(atPath: db),
                  let attrs = try? fm.attributesOfItem(atPath: db),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { continue }
            if db.hasPrefix(myHome) { continue } // 跳过自身容器
            DebugLogger.shared.log("导入扫描 候选: \(db) 大小 \(size)")
            if best == nil || size > best!.size {
                best = (db, size)
            }
        }
        return best?.path
    }

    // MARK: - 使用旧版行情库（只读挂载 Xcode 旧版容器数据库）

    /// TrollStore 版新容器只有种子库（1 个演示标的）。旧版（Xcode 签名，bundle id
    /// com.sunck.Kline.4G3V8W86TN）容器里有 1.35GB 完整行情库。no-sandbox + 同 uid
    /// (mobile) 下可直接只读打开该文件，零拷贝、零空间占用、即时生效。
    private func useLegacyDB() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyDBPath) else {
            legacyResult = "❌ 未找到旧版数据库\n\(legacyDBPath)"
            DebugLogger.shared.log("使用旧版库失败 文件不存在: \(legacyDBPath)")
            return
        }
        if DatabaseManager.shared.switchToExternalReadonly(path: legacyDBPath) {
            legacyResult = "✅ 已启用旧版行情库（只读挂载）\n正在刷新列表，稍候查看行情"
            DebugLogger.shared.log("使用旧版库成功: \(legacyDBPath)")
        } else {
            legacyResult = "❌ 打开旧版数据库失败（可能被占用或损坏）"
            DebugLogger.shared.log("使用旧版库打开失败: \(legacyDBPath)")
        }
    }

    // MARK: - 安装 IPA 到 TrollStore（本地 HTTP + URL Scheme，绕过共享面板崩溃）

    /// 原理：platform-application 权限下系统共享面板（UIActivityViewController）
    /// 生成 AirDrop 图标时 CoreImage GL 上下文空指针崩溃（iOS 系统组件问题）。
    /// 改为 Kline 起本地 HTTP 服务器暴露 /download/<file>，用
    /// `apple-magnifier://install?url=http://127.0.0.1:5051/download/<file>` 拉起 TrollStore。
    private func shareIPA(_ file: IPAFileInfo) {
        // 确保本地 HTTP 服务器已启动（提供 /download/<file>）
        KlineHTTPServer.shared.start()

        let safeName = (file.name as NSString).lastPathComponent
        let trollURL = KlineHTTPServer.trollStoreInstallURL(localFile: safeName, port: KlineHTTPServer.shared.port)

        scanResult = "正在拉起 TrollStore 安装 \(safeName) ...\n(如系统弹确认框请选择「打开」)"

        DispatchQueue.main.async {
            if let url = URL(string: trollURL) {
                UIApplication.shared.open(url) { success in
                    if !success {
                        self.scanResult = "❌ 无法拉起 TrollStore\n请手动打开 TrollStore → + → Downloads/\(safeName)"
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

            // 测试 2：读系统禁区 SMS 目录
            if let _ = try? FileManager.default.contentsOfDirectory(atPath: "/private/var/mobile/Library/SMS") {
                results.append("✅ /private/var/mobile/Library/SMS/ 可读")
            } else {
                results.append("❌ SMS 目录不可读（no-sandbox 未生效）")
            }

            // 测试 3：读根目录
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

// MARK: - IPA 卡片视图

struct IPACardView: View {
    let file: IPAFileInfo
    let onShare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "app.badge")
                    .foregroundColor(.blue)
                Text(file.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
            }

            HStack {
                Text(formatSize(file.size))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatDate(file.modDate))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button(action: onShare) {
                HStack {
                    Image(systemName: "icloud.and.arrow.down")
                    Text("安装到 TrollStore")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.15))
                .cornerRadius(6)
            }
        }
        .padding()
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(8)
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

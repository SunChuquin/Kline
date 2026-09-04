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
    @State private var entitlementCheckResult: String = ""

    private let downloadsPath = "/var/mobile/Media/Downloads"

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

    // MARK: - 共享 IPA 到 TrollStore（B1 系统共享面板）

    private func shareIPA(_ file: IPAFileInfo) {
        let url = URL(fileURLWithPath: file.path)

        DispatchQueue.main.async {
            let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)

            // iPad 需要 popover
            if let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
               let rootVC = windowScene.windows.first?.rootViewController
            {
                av.popoverPresentationController?.sourceView = rootVC.view
                av.popoverPresentationController?.sourceRect = CGRect(
                    x: rootVC.view.bounds.midX,
                    y: rootVC.view.bounds.midY,
                    width: 0,
                    height: 0
                )
                av.popoverPresentationController?.permittedArrowDirections = []

                rootVC.present(av, animated: true)
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
                    Image(systemName: "square.and.arrow.up")
                    Text("共享到 TrollStore")
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

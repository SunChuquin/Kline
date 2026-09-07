//
//  DebugLogger.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/8/31.
//

import Foundation

/// 轻量调试日志器：把关键运行状态写入沙盒 Documents/debug_log.txt，
/// 供外部工具（如 pymobiledevice3 apps pull）读取后做文本分析。
/// Release 构建同样写入，方便装到真机后离线读取；写入开销极小。
///
/// A1 日志双写（2026-09-07）：TrollStore 版不在 Installation Lookup 登记，
/// `apps pull`/house_arrest 读不了沙盒。因此把日志镜像一份到 AFC 公共目录
/// `/var/mobile/Media/Downloads/KlineLogs/debug_log.txt`（no-sandbox 生效时
/// 可写，Xcode 沙盒版静默降级），TRAE 用 `afc pull` 读取。
final class DebugLogger {
    static let shared = DebugLogger()

    /// 日志文件名（落在 Documents 下）
    static let fileName = "debug_log.txt"

    /// 日志最大字节数，超过则截断重写，避免无限膨胀
    private let maxBytes = 1 << 20 // 1 MB

    private let queue = DispatchQueue(label: "com.sunck.Kline.debuglog")
    private let logURL: URL

    /// A1 日志双写：公共镜像路径（AFC 公共区，no-sandbox 生效时可写）
    private let publicLogURL = URL(fileURLWithPath: "/var/mobile/Media/Downloads/KlineLogs/debug_log.txt")

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logURL = docs.appendingPathComponent(Self.fileName)
    }

    /// 追加写一行日志（线程安全）
    func log(_ message: String) {
        queue.async { [self] in
            let line = Self.timestamp() + " " + message + "\n"
            do {
                let data = Data(line.utf8)
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } catch {
                // 文件不存在等：直接创建/覆盖
                try? Data(line.utf8).write(to: logURL, options: .atomic)
            }
            trimIfNeeded()
            mirrorToPublic(Data(line.utf8))
        }
    }

    /// 清空日志文件（沙盒 + 公共镜像同步清空，保证只保留本次会话）
    func clear() {
        queue.async { [self] in
            try? Data().write(to: logURL, options: .atomic)
            // 公共镜像：尝试删除（存在才删），失败静默
            try? FileManager.default.removeItem(at: publicLogURL)
        }
    }

    /// A1 日志双写：把最新一行追加到公共目录镜像。
    /// 整体包裹在 do-catch 里，失败静默降级（Xcode 沙盒版无权限时不影响 App）。
    private func mirrorToPublic(_ data: Data) {
        do {
            let dir = publicLogURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: publicLogURL.path) {
                let handle = try FileHandle(forWritingTo: publicLogURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try data.write(to: publicLogURL, options: .atomic)
            }
        } catch {
            // 静默降级：沙盒版无 no-sandbox 权限时忽略
        }
    }

    /// 超过上限时截断，避免日志无限增长
    private func trimIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size > maxBytes else { return }
        try? Data(("=== 日志超限已截断 ===\n").utf8).write(to: logURL, options: .atomic)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}

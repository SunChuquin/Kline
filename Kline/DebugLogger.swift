//
//  DebugLogger.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/8/31.
//

import Foundation

/// 轻量调试日志器：把关键运行状态写入日志文件，供外部工具读取后做文本分析。
/// Release 构建同样写入，方便装到真机后离线读取；写入开销极小。
///
/// 日志落点（2026-09-07 起为单选，不再双写）：
/// - **TrollStore 版**（no-sandbox 生效，公共目录可写）：只写公共
///   `/var/mobile/Media/Downloads/KlineLogs/debug_log.txt`，**不写沙盒**，
///   避免沙盒容器写日志占用空间/影响性能。TRAE 用 `deploy_kline_to_ipad.py --pull-logs`（AFC）读取。
/// - **Xcode 沙盒版**（公共目录不可写）：只写沙盒 `Documents/debug_log.txt`，
///   TRAE 用 `apps pull` 读取（旧路径）。
final class DebugLogger {
    static let shared = DebugLogger()

    /// 日志文件名（沙盒 Documents 或公共 KlineLogs 下同名）
    static let fileName = "debug_log.txt"

    /// 日志最大字节数，超过则截断重写，避免无限膨胀
    private let maxBytes = 1 << 20 // 1 MB

    private let queue = DispatchQueue(label: "com.sunck.Kline.debuglog")

    /// 实际写入的日志文件 URL（公共目录 或 沙盒 Documents，二选一）
    private let logURL: URL

    /// 是否 TrollStore 版（no-sandbox 生效）：true=只写公共目录，false=只写沙盒
    let isTrollStore: Bool

    private init() {
        // 检测公共日志目录是否可写：可写 = no-sandbox 生效 = TrollStore 版
        let publicLogURL = URL(fileURLWithPath: "/var/mobile/Media/Downloads/KlineLogs/debug_log.txt")
        let publicDir = publicLogURL.deletingLastPathComponent()
        let publicWritable = (try? FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)) != nil
        isTrollStore = publicWritable
        if publicWritable {
            // TrollStore 版：只写公共目录，不写沙盒（避免沙盒写日志占用容器空间/影响性能）
            logURL = publicLogURL
        } else {
            // 沙盒版（Xcode 调试）：写 Documents
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            logURL = docs.appendingPathComponent(Self.fileName)
        }
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
        }
    }

    /// 清空日志文件（只清当前生效的目标，保证只保留本次会话）
    func clear() {
        queue.async { [self] in
            try? Data().write(to: logURL, options: .atomic)
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

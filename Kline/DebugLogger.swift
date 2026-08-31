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
final class DebugLogger {
    static let shared = DebugLogger()

    /// 日志文件名（落在 Documents 下）
    static let fileName = "debug_log.txt"

    /// 日志最大字节数，超过则截断重写，避免无限膨胀
    private let maxBytes = 1 << 20 // 1 MB

    private let queue = DispatchQueue(label: "com.sunck.Kline.debuglog")
    private let logURL: URL

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
        }
    }

    /// 清空日志文件
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

//
//  WebUIFiles.swift
//  Kline
//
//  bundle 根 WebUI/ dist 的统一读取工具：kline:// scheme handler 与
//  KlineHTTPServer /web/ 调试路由共用同一份 MIME 映射与路径防御，
//  保证两条通道（App 内加载 / PC 浏览器调试）行为一致。
//

import Foundation

enum WebUIFiles {

    /// 读 bundle 根 WebUI/<relPath>；relPath 为空 → index.html。
    /// 返回 (data, mime, absolutePath)；路径非法（含 ".."）或文件不存在返回 nil。
    static func read(_ relPath: String) -> (data: Data, mime: String, path: String)? {
        let rel = relPath.isEmpty ? "index.html" : relPath
        // 路径穿越防御：拒绝 ".." 段
        guard !rel.components(separatedBy: "/").contains("..") else { return nil }
        guard let root = Bundle.main.resourceURL?.appendingPathComponent(WebBridgeConst.bundleDir, isDirectory: true) else {
            return nil
        }
        let fileURL = root.appendingPathComponent(rel)
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return (data, mimeType(forExtension: fileURL.pathExtension), path)
    }

    static func mimeType(forExtension ext: String) -> String {
        mimeTypes[ext.lowercased()] ?? "application/octet-stream"
    }

    /// 扩展名 → MIME。js 必须是 text/javascript：dist 使用 type="module"，
    /// WebKit 对模块脚本的 MIME 校验严格，application/octet-stream 会被拒绝执行。
    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "map": "application/json; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "txt": "text/plain; charset=utf-8",
    ]
}

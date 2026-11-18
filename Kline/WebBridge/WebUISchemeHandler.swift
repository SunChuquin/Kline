//
//  WebUISchemeHandler.swift
//  Kline
//
//  kline://app/<path> → bundle 根 WebUI/ 目录（"Copy PyScripts" 构建阶段拷入；
//  CI 由 build.yml 先执行 npm build 生成 Web/dist，本机构建需先在 Web/ 下 npm run build）。
//
//  设计：P0 为单页应用、无 SPA 路由需求，未知路径直接 404；拒绝 ".." 路径穿越。
//  文件读取与 MIME 映射统一走 WebUIFiles（与 KlineHTTPServer /web/ 调试路由共用）。
//  加载全程同步完成（dist 静态资源总量 <100KB），无流式/取消需求。
//

import Foundation
import WebKit

final class WebUISchemeHandler: NSObject, WKURLSchemeHandler {

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            return fail(task, status: 400, reason: "请求无 URL")
        }

        let relPath = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        // 路径穿越防御：拒绝 ".." 段（独立于"文件不存在"的 404）
        if relPath.components(separatedBy: "/").contains("..") {
            return fail(task, status: 403, reason: "非法路径 \(relPath)")
        }

        guard let file = WebUIFiles.read(relPath) else {
            if relPath == "index.html" {
                return fail(task, status: 404,
                            reason: "WebUI 资源缺失：构建时未生成 Web/dist（先在 Web/ 下执行 npm install && npm run build）")
            }
            return fail(task, status: 404, reason: "未找到 \(relPath)")
        }

        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": file.mime,
                                                            "Cache-Control": "no-store"]) else {
            return fail(task, status: 500, reason: "响应构造失败")
        }
        task.didReceive(response)
        task.didReceive(file.data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // 加载在 start 内同步完成，无进行中任务可取消
    }

    /// 404/403/500：以带状态码的 HTTP 响应结束，页面可感知；原因落日志
    private func fail(_ task: WKURLSchemeTask, status: Int, reason: String) {
        let url = task.request.url ?? URL(string: "\(WebBridgeConst.scheme)://app/")!
        let body = reason.data(using: .utf8) ?? Data()
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                          headerFields: ["Content-Type": "text/plain; charset=utf-8"]) {
            task.didReceive(response)
            task.didReceive(body)
            task.didFinish()
        }
        DebugLogger.shared.log("[WebBridge] kline:// 请求失败(\(status)): \(reason)")
    }
}

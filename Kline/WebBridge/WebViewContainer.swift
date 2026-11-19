//
//  WebViewContainer.swift
//  Kline
//
//  Web SPA 宿容器的共享 UIViewRepresentable：kline://app/index.html#/<route>
//  加载 + 单 channel 桥接注册 + didFinish 就绪回调 + 失败报错。
//  宿主形态（WebTabHost 的 Tab 内容 / WebHostView 的全屏入口页）共用本容器。
//

import SwiftUI
import WebKit

struct WebViewContainer: UIViewRepresentable {
    /// hash 路由（如 "profile" / "favorites"）→ 加载 kline://app/index.html#/<route>
    let route: String
    /// 不透明底（Tab 内容宿主需要白底；弹层浮层传 false → 透明 WebView，让遮罩/下层内容透出）
    var isOpaque: Bool = true
    let onReady: (WKWebView) -> Void
    let onError: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 自定义 scheme 必须在 WKWebView 初始化前注册
        config.setURLSchemeHandler(WebUISchemeHandler(), forURLScheme: WebBridgeConst.scheme)
        let controller = WKUserContentController()
        controller.add(WebMessageRouter.shared, name: WebBridgeConst.channel)
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.backgroundColor = isOpaque ? .systemBackground : .clear
        webView.isOpaque = isOpaque
        WebMessageRouter.shared.attach(webView: webView)

        if let url = URL(string: "\(WebBridgeConst.scheme)://app/index.html#/\(route)") {
            DebugLogger.shared.log(String(format: "[WebBridge] WebView 打开前 phys_footprint=%.1fMB",
                                          MemoryFootprint.physFootprintMB()))
            webView.load(URLRequest(url: url))
        } else {
            onError("加载地址无效")
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onError: onError)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onReady: (WKWebView) -> Void
        let onError: (String) -> Void
        private var didReportReady = false

        init(onReady: @escaping (WKWebView) -> Void, onError: @escaping (String) -> Void) {
            self.onReady = onReady
            self.onError = onError
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 只报一次就绪（防页面内部二次导航重复推送）
            guard !didReportReady else { return }
            didReportReady = true
            onReady(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError("页面加载失败: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            // 404/资源缺失在 custom scheme 下多走 provisional 失败路径
            onError("页面加载失败: \(error.localizedDescription)")
        }
    }
}

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
    /// 复用池 key（nil = 不复用，销毁即释放）。P2-9 白屏治理：懒创建+关闭即销毁的宿主
    /// （全屏 Web 页 / 公式编辑器）传 key 后，dismantle 时实例入池、重建时取池中已加载
    /// 实例（零重载零白屏）。⚠️ 不能用「常驻 + opacity/isHidden 隐藏」替代——WKWebView 的
    /// Web 内容元素由 WebKit 远程合成进系统无障碍树，opacity/accessibilityHidden/isHidden
    /// 均无法让它从 XCUITest 树消失（2026-11-20 实测「返回后 Web 页仍可达」断言挂）；
    /// 唯有把视图从 SwiftUI 层级移除（条件渲染）才能剪枝，池化保住已加载实例。
    var reuseKey: String? = nil
    /// 外观覆盖（主题偏好切换时经 updateUIView 同步已创建实例——makeUIView 一次性设置
    /// 会定格创建时偏好，夜间切日间后底色仍白，2026-11-20 自选页实测）；
    /// nil = 跟随系统不干预
    var themeStyle: UIUserInterfaceStyle?
    let onReady: (WKWebView) -> Void
    let onError: (String) -> Void

    /// 复用池：key → 已完成加载的 WebView 实例（每 key 至多 1 个，新入池覆盖旧的）
    static var reusePool: [String: WKWebView] = [:]

    func makeUIView(context: Context) -> WKWebView {
        // 复用命中：池中实例已加载到目标路由，直接返回（不再 load，didFinish 不会再来）
        if let reuseKey, let cached = Self.reusePool.removeValue(forKey: reuseKey) {
            DebugLogger.shared.log("[WebBridge] WebView 复用命中（\(reuseKey)）——零重载")
            return cached
        }
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
        // 夜间模式外观强制：App 主题偏好（KlineTheme）驱动整个 App preferredColorScheme，
        // 但不透传进 WKWebView 的网页环境——不设置时 prefers-color-scheme 恒 light、
        // systemBackground 底色取日间值（夜间加载瞬间闪白）。dark/light 显式覆盖，
        // 跟随系统时不干预（trait 自然继承）。
        if let themeStyle { webView.overrideUserInterfaceStyle = themeStyle }
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

    func updateUIView(_ webView: WKWebView, context: Context) {
        // 主题偏好切换 → 同步已创建实例的外观（makeUIView 只定格创建时偏好）
        if let themeStyle, webView.overrideUserInterfaceStyle != themeStyle {
            webView.overrideUserInterfaceStyle = themeStyle
        }
    }

    /// SwiftUI 从层级移除本容器时回调：复用 key 的实例入池（强引用持有，随取随用），
    /// 无 key 或加载未就绪（didFail 白屏实例）的正常释放，防污染复用池
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        guard let key = coordinator.reuseKey, coordinator.didReportReady else { return }
        reusePool[key] = uiView
        DebugLogger.shared.log("[WebBridge] WebView 入复用池（\(key)）——实例保留防白屏")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(route: route, reuseKey: reuseKey, onReady: onReady, onError: onError)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let route: String
        let reuseKey: String?
        let onReady: (WKWebView) -> Void
        let onError: (String) -> Void
        fileprivate var didReportReady = false

        init(route: String, reuseKey: String?, onReady: @escaping (WKWebView) -> Void,
             onError: @escaping (String) -> Void) {
            self.route = route
            self.reuseKey = reuseKey
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

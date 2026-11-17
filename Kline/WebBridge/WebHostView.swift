//
//  WebHostView.swift
//  Kline
//
//  Web UI 宿主页（混合架构 P0）：全屏 WKWebView + kline:// 内嵌资源 + 单 channel 桥接。
//  首帧红线（方案 §6）：仅由个人中心入口按需打开（懒加载），不参与启动链路。
//  呈现方式对齐 PythonEngineLabView：个人中心容器层全屏 overlay，页内「返回」关闭。
//  状态快照全部来自原生 Store（Web 侧不持有状态），主题经 theme.changed 事件实时推送。
//

import SwiftUI
import WebKit

struct WebHostView: View {
    let onClose: () -> Void

    @ObservedObject private var themeStore = KlineThemeStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var router = WebMessageRouter()
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏（与个人中心同款）
            HStack {
                Button(action: { onClose() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24))
                }
                .padding(.leading, 16)

                Text("Web 试点（P0）")
                    .font(.title)
                    .fontWeight(.bold)

                Spacer()
            }
            .background(Color(.systemBackground))
            .frame(height: 56)
            .padding(.top, -5)

            Divider()

            if let loadError = loadError {
                // 加载失败（如 WebUI 资源缺失）：明确报错，不给白屏
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text(loadError)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WebViewContainer(router: router,
                                 onReady: { markReady() },
                                 onError: { loadError = $0 })
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        // 主题推送数据源：解析外观变化（跟随系统切深浅色）→ 更新路由并推事件
        .onChange(of: colorScheme) { newScheme in
            router.updateResolvedMode(newScheme == .dark ? "dark" : "light")
            router.pushTheme(preference: themeStore.theme.rawValue)
        }
        // 主题偏好变化（个人中心切换）→ 推事件（解析外观可能滞后一拍，由上面 colorScheme onChange 补推）
        .onChange(of: themeStore.theme) { _ in
            router.pushTheme(preference: themeStore.theme.rawValue)
        }
        .onAppear {
            router.updateResolvedMode(colorScheme == .dark ? "dark" : "light")
        }
        .onDisappear {
            router.detach()
        }
    }

    /// 页面 didFinish：打开推送门控并推送初始主题/内存事件
    private func markReady() {
        DebugLogger.shared.log(String(format: "[WebBridge] WebView 加载完成 phys_footprint=%.1fMB",
                                      MemoryFootprint.physFootprintMB()))
        router.markPageReady(preference: themeStore.theme.rawValue)
    }
}

// MARK: - WKWebView 容器

private struct WebViewContainer: UIViewRepresentable {
    let router: WebMessageRouter
    let onReady: () -> Void
    let onError: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 自定义 scheme 必须在 WKWebView 初始化前注册
        config.setURLSchemeHandler(WebUISchemeHandler(), forURLScheme: WebBridgeConst.scheme)
        let controller = WKUserContentController()
        controller.add(router, name: WebBridgeConst.channel)
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.backgroundColor = .systemBackground
        webView.isOpaque = true
        router.attach(webView: webView)

        if let url = URL(string: "\(WebBridgeConst.scheme)://app/index.html") {
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
        let onReady: () -> Void
        let onError: (String) -> Void
        private var didReportReady = false

        init(onReady: @escaping () -> Void, onError: @escaping (String) -> Void) {
            self.onReady = onReady
            self.onError = onError
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 只报一次就绪（防页面内部二次导航重复推送）
            guard !didReportReady else { return }
            didReportReady = true
            onReady()
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

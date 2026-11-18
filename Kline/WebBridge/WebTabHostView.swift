//
//  WebTabHostView.swift
//  Kline
//
//  Tab 内容的 Web 宿主（混合架构 P2）：单 WebView 常驻承载 Vue SPA 的对应路由页。
//  底部 Tab 栏保留原生（ContentView.bottomMenuBar）；本容器只渲染 Tab 内容区。
//  懒创建（首次切到该 Tab 才实例化）；keep-alive 由 Vue keep-alive 承担，切 Tab 不销毁。
//

import SwiftUI
import WebKit

struct WebTabHostView: View {
    /// hash 路由名（"favorites" / "market" / "home" / "simulation"）
    let route: String

    @ObservedObject private var themeStore = KlineThemeStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var loadError: String?

    var body: some View {
        Group {
            if let loadError = loadError {
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
                WebViewContainer(route: route,
                                 onReady: { webView in markReady(webView) },
                                 onError: { loadError = $0 })
            }
        }
        .background(Color(.systemBackground))
        .onChange(of: colorScheme) { newScheme in
            router.updateResolvedMode(newScheme == .dark ? "dark" : "light")
            router.pushTheme(preference: themeStore.theme.rawValue)
        }
        .onChange(of: themeStore.theme) { _ in
            router.pushTheme(preference: themeStore.theme.rawValue)
        }
        .onAppear {
            router.updateResolvedMode(colorScheme == .dark ? "dark" : "light")
        }
    }

    private var router: WebMessageRouter { WebMessageRouter.shared }

    private func markReady(_ webView: WKWebView) {
        router.markPageReady(webView: webView, preference: themeStore.theme.rawValue)
    }
}

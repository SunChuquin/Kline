//
//  WebHostView.swift
//  Kline
//
//  Web 全屏入口宿主页（混合架构）：全屏 WKWebView + kline:// 内嵌资源 + 单 channel 桥接。
//  首帧红线（方案 §6）：仅由个人中心入口按需打开（懒加载），不参与启动链路。
//  呈现方式对齐 PythonEngineLabView：个人中心容器层全屏 overlay，页内「返回」关闭。
//  Tab 内容宿主见 WebTabHostView（共用 WebViewContainer / WebMessageRouter.shared）。
//

import SwiftUI
import WebKit

struct WebHostView: View {
    let onClose: () -> Void

    @ObservedObject private var themeStore = KlineThemeStore.shared
    @Environment(\.colorScheme) private var colorScheme
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

                Text("Web 试点（P1）")
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
                WebViewContainer(route: "profile",
                                 onReady: { webView in markReady(webView) },
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

    private var router: WebMessageRouter { WebMessageRouter.shared }

    /// 页面 didFinish：登记就绪并推送初始主题/内存事件
    private func markReady(_ webView: WKWebView) {
        DebugLogger.shared.log(String(format: "[WebBridge] WebView 加载完成 phys_footprint=%.1fMB",
                                      MemoryFootprint.physFootprintMB()))
        router.markPageReady(webView: webView, preference: themeStore.theme.rawValue)
    }
}

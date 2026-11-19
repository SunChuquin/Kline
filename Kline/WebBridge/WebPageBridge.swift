//
//  WebPageBridge.swift
//  Kline
//
//  全屏 Web 页容器（协议 v2 page.*）：P2-6c-1 三页（lanSync / localUpdate / pythonLab）
//  Web 化的呈现宿主与 page 模块。各页业务动作在各自域桥（lan.* / update.* / lab.*）。
//
//  与 SheetWebOverlayHost（弹层浮层）的三点差异：
//   1. 不透明：WebTabHostView(route:"page", isOpaque:true)——弹层是透明遮罩+面板，全屏页是整页。
//   2. 懒创建 + 关闭即销毁：首次 open 创建 WebView，close 时随条件渲染整体销毁（对齐原生页
//      生命周期，2GB 设备优先省内存；弹层常驻是因为打开频率高）。每次打开由 Web 端 mounted
//      调 page.ready 补推 page.open（首开时序：事件先于 WebView 就绪会丢失——sheet.ready 同款坑）。
//   3. 挂载点在 HomeWebShellView overlay（zIndex 1002，盖过原生 overlay 组 1000 与个人中心），
//      保持原生 UX：底部 Tab 栏不被盖住（原生 LANSyncView 等即以内容区 overlay 呈现）。
//
//  关闭仲裁：closeHooks 每页注册（返回 false = 拒绝，如 LAN 传输中）；原生实现保留可回退。
//
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Combine
import SwiftUI

@MainActor
final class WebPageBridge: ObservableObject {

    static let shared = WebPageBridge()

    /// 当前打开的全屏 Web 页名（nil = 无；宿主按此条件创建/销毁 WebView）
    @Published private(set) var activePage: String? = nil

    /// 各页关闭钩子（页名 → 返回 false 拒绝关闭；LANSyncBridge 注册传输中拒绝）
    var closeHooks: [String: () -> Bool] = [:]

    /// 打开全屏 Web 页（同页 no-op 防环）
    func open(_ name: String) {
        guard activePage != name else { return }
        activePage = name
        // 定向推 route:"page"（Tab 宿主 + 弹层浮层并存时按 URL hash 过滤）
        WebMessageRouter.shared.pushEvent("page.open", payload: ["name": name], route: "page")
        DebugLogger.shared.log("[WebPageBridge] open \(name)")
        onOpen(name)
    }

    /// 打开时的每页生命周期（对齐原生 onAppear：探测/自动检查）
    private func onOpen(_ name: String) {
        switch name {
        case "lanSync":     LANSyncBridge.shared.onOpen()
        case "localUpdate": LocalUpdateBridge.shared.onOpen()
        case "pythonLab":   EngineLabBridge.shared.onOpen()
        default: break
        }
    }

    /// 关闭当前全屏页（closeHooks 拒绝时不动）
    func close() {
        guard let name = activePage else { return }
        if let hook = closeHooks[name], !hook() {
            DebugLogger.shared.log("[WebPageBridge] close \(name) 被拒绝（busy）")
            return
        }
        activePage = nil
        DebugLogger.shared.log("[WebPageBridge] close \(name)")
    }

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "close":
            shared.close()
            return WebBridgeResponse.ok(request.id)
        case "ready":
            // ⚠️ 全屏 WebView 就绪拉取：page.open 事件可能早于 WebView 创建/加载完成发出
            // （懒创建时序同弹层浮层）→ Web 端 mounted 后调本动作，宿主若有待展示页则补推。
            if let name = shared.activePage {
                WebMessageRouter.shared.pushEvent("page.open", payload: ["name": name], route: "page")
            }
            return WebBridgeResponse.ok(request.id)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "page.\(request.action) 未实现")
        }
    }
}

// MARK: - 全屏 Web 页宿主（HomeWebShellView overlay 挂载）

/// 全屏 Web 页宿主：activePage 非 nil 时创建 route="page" 的 WebView，关闭即随条件渲染销毁。
struct WebFullscreenPageHost: View {
    @ObservedObject private var bridge = WebPageBridge.shared

    var body: some View {
        Group {
            if bridge.activePage != nil {
                WebTabHostView(route: "page", isOpaque: true)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: bridge.activePage != nil)
    }
}

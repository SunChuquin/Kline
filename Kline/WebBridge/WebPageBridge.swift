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
import WebKit

/// 预热实例的导航代理：didFinish（文档加载完成）即入复用池（key="page"）——
/// JS mounted 的 page.ready 由 Router/宿主兜底（activePage 已设则补推 page.open）。
private final class PrewarmNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        WebViewContainer.reusePool["page"] = webView
        DebugLogger.shared.log("[WebPageBridge] page 域 WebView 预热完成入池")
    }
}

@MainActor
final class WebPageBridge: ObservableObject {

    static let shared = WebPageBridge()

    /// 当前打开的全屏 Web 页名（nil = 无；宿主按此条件创建/销毁 WebView）
    @Published private(set) var activePage: String? = nil

    /// 各页关闭钩子（页名 → 返回 false 拒绝关闭；LANSyncBridge 注册传输中拒绝）
    var closeHooks: [String: () -> Bool] = [:]

    /// 预热是否已执行（每启动一次）
    private static var didPrewarm = false
    /// 预热实例的导航代理（static 持有——WKWebView.navigationDelegate 是弱引用）
    private static let prewarmDelegate = PrewarmNavigationDelegate()

    /// page 域 WebView 预热（App 启动 3s 后后台调用）：懒创建的白屏消除——提前创建并加载
    /// kline://app/index.html#/page，didFinish 即入复用池（key="page"）。用户首次点开
    /// 个人中心等 page 页时宿主 makeUIView 直接命中已加载实例（零白屏）。
    /// 事件时序兜底：预热实例的 JS mounted 晚于 page.open 事件也不丢——Web 端 mounted 调
    /// page.ready，宿主检测 activePage 非空即补推 page.open（首开时序坑的既有兜底通道）。
    static func prewarmPageWebView() {
        guard !didPrewarm, WebViewContainer.reusePool["page"] == nil else { return }
        didPrewarm = true
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(WebUISchemeHandler(), forURLScheme: WebBridgeConst.scheme)
        let controller = WKUserContentController()
        controller.add(WebMessageRouter.shared, name: WebBridgeConst.channel)
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.backgroundColor = .systemBackground
        webView.isOpaque = true
        webView.navigationDelegate = prewarmDelegate
        if let url = URL(string: "\(WebBridgeConst.scheme)://app/index.html#/page") {
            DebugLogger.shared.log("[WebPageBridge] page 域 WebView 预热启动")
            webView.load(URLRequest(url: url))
        }
    }

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
        case "backtest":    BacktestBridge.shared.onOpen()
        case "trainingRecords": TrainingBridge.shared.onOpen()
        case "formulaEditor": FormulaEditorBridge.shared.onOpen()
        case "strategyEditor": StrategyEditorBridge.shared.onOpen()
        case "pickerEditor": PickerEditBridge.shared.onOpen()
        case "ticket": break   // 下单页无 onOpen 生命周期（上下文在 openTicket 解析时已暂存）
        case "condManage", "condEditor": break   // 条件单页无 onOpen 生命周期（上下文在入口动作暂存）
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
        case "open":
            // P2-9b：Web 页内切换另一全屏页（如个人中心 → 本地更新）：同 WebView
            // activeName 切换（page.open 推送驱动），复用池实例复用
            let name = request.payload["name"] as? String ?? ""
            guard !name.isEmpty else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "需要 name")
            }
            shared.open(name)
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

/// 全屏 Web 页宿主：activePage 非 nil 时创建 route="page" 的 WebView。
/// P2-9 白屏治理：条件渲染销毁时 WebViewContainer dismantle 入复用池（实例保留），
/// 重开时 makeUIView 从池取已加载实例——「关闭后元素消失」（XCUITest 断言语义）与
/// 「二次打开零白屏」两全。formulaEditor 由 SheetWebOverlayHost 呈现（入口在图表
/// 详情页弹层，shell 层会被详情页盖住）；activePage 仍是单一事实源，page.ready
/// 补推对本页照常生效。
struct WebFullscreenPageHost: View {
    @ObservedObject private var bridge = WebPageBridge.shared

    var body: some View {
        Group {
            if let name = bridge.activePage, name != "formulaEditor" {
                WebTabHostView(route: "page", isOpaque: true, reuseKey: "page")
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: bridge.activePage != nil)
    }
}

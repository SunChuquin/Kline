//
//  WebMessageRouter.swift
//  Kline
//
//  Web↔Swift 动作路由：module + action 分发，响应按 id 配对回传页面。
//  P0 模块清单：
//    app     ping（延迟探针）/ reportRtt（页面实测 RTT 落日志）/ memory（内存足迹）/ info（版本）
//    theme   get（主题偏好 + 解析外观；变化另走 theme.changed 事件推送）
//    profile snapshot（个人中心只读快照：版本 / 主题 / 同步调度 / 主库状态）
//  事件推送：theme.changed（外观或偏好变化）/ app.memory（页面就绪后一次）。
//
//  生命周期：WKUserContentController.add 持有本对象；webView 为弱引用，
//  视图销毁时由 WebHostView.onDisappear 调 detach() 释放引用并复位推送门控。
//

import Foundation
import UIKit
import WebKit

final class WebMessageRouter: NSObject, WKScriptMessageHandler {

    /// 单例：信封分发与通道无关（真机走 WKScriptMessageHandler，PC 调试走
    /// KlineHTTPServer POST /bridge——两者共用同一 dispatch）。
    static let shared = WebMessageRouter()

    // MARK: - 状态

    private weak var webView: WKWebView?
    /// 已就绪（didFinish）页面集合：事件推送目标；弱引用随宿主销毁自动移除。
    /// 支持多 WebView 实例并存（Tab 常驻宿主 + 个人中心入口宿主），响应回发起者、
    /// 事件推最近就绪者。
    private let readyWebViews = NSHashTable<WKWebView>.weakObjects()
    /// 解析后的实际外观（"light"/"dark"）：由宿主视图注入（跟随系统时视图环境是唯一真相）
    private(set) var resolvedMode = "light"
    /// Web 请求切 Tab 的落点（ContentView 注入，写原生 selectedTab）
    var switchTabHandler: ((Int) -> Void)?

    // MARK: - 生命周期

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    /// 宿主视图在 onAppear / colorScheme 变化时注入解析外观
    func updateResolvedMode(_ mode: String) {
        resolvedMode = mode
    }

    /// 单实例宿主销毁时移除其就绪标记（多实例并存时其余实例不受影响）
    func detach() {
        if let w = webView {
            readyWebViews.remove(w)
        }
        DebugLogger.shared.log("[WebBridge] 路由已分离（宿主销毁）")
    }

    /// 页面 didFinish：登记就绪（按实例）并推送初始快照类事件
    func markPageReady(webView: WKWebView, preference: String) {
        readyWebViews.add(webView)
        pushTheme(preference: preference, to: webView)
        pushMemoryFootprint(to: webView)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == WebBridgeConst.channel else { return }
        // 响应回发起者（多实例并存：Tab 常驻宿主 + 个人中心入口宿主各自独立收发）
        guard let target = message.webView ?? webView else { return }
        let started = CFAbsoluteTimeGetCurrent()

        guard let request = WebBridgeRequest.parse(message.body) else {
            respond(WebBridgeResponse.fail("unknown", code: "bad_request", message: "信封解析失败"), to: target)
            return
        }
        let response = dispatch(request)
        respond(response, to: target)

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        DebugLogger.shared.log("[WebBridge] \(request.module).\(request.action) 处理 \(String(format: "%.2f", elapsedMs))ms")
    }

    // MARK: - 分发

    /// HTTP 通道（PC 调试桥 POST /bridge）专用入口：同一 dispatch，响应由调用方回 JSON。
    /// 注意：调用方负责主线程（Store 均为主线程对象）。
    func dispatchHTTP(_ request: WebBridgeRequest) -> [String: Any] {
        dispatch(request)
    }

    private func dispatch(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.module {
        case "app":        return handleApp(request)
        case "theme":      return handleTheme(request)
        case "profile":    return handleProfile(request)
        case "nav":        return handleNav(request)
        case "favorites":  return FavoritesBridge.handle(request)
        case "market":     return MarketBridge.handle(request)
        case "home":       return HomeBridge.handle(request)
        case "sim":        return SimulationBridge.handle(request)
        case "sheet":      return SheetBridge.handle(request)
        case "chart":      return SheetBridge.handleChart(request)
        case "quick":      return QuickBridge.handle(request)
        case "trade":      return QuickBridge.handleTrade(request)
        case "page":       return WebPageBridge.handle(request)
        case "formulaEdit": return FormulaEditorBridge.handle(request)
        case "lan":        return LANSyncBridge.handle(request)
        case "update":     return LocalUpdateBridge.handle(request)
        case "lab":        return EngineLabBridge.handle(request)
        case "backtest":   return BacktestBridge.handle(request)
        case "training":   return TrainingBridge.handle(request)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_module", message: "未知模块 \(request.module)")
        }
    }

    /// nav 模块：Tab 导航桥接。switchTab 由 ContentView.onAppear 注入落点写原生 selectedTab。
    private func handleNav(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "switchTab":
            let index = (request.payload["index"] as? Int) ?? -1
            DebugLogger.shared.log("[WebBridge] nav.switchTab index=\(index)")
            switchTabHandler?(index)
            return WebBridgeResponse.ok(request.id, data: ["index": index])
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action", message: "nav.\(request.action) 未实现")
        }
    }

    private func handleApp(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "ping":
            // 页面据 clientTs 与本响应实测往返延迟；serverMs 供页面校验时钟
            let clientTs = (request.payload["clientTs"] as? Double) ?? 0
            let serverMs = Date().timeIntervalSince1970 * 1000
            return WebBridgeResponse.ok(request.id, data: ["clientTs": clientTs, "serverMs": serverMs])
        case "reportRtt":
            let rtt = (request.payload["rttMs"] as? Double) ?? 0
            DebugLogger.shared.log("[WebBridge] 页面实测桥接往返 \(String(format: "%.1f", rtt))ms")
            return WebBridgeResponse.ok(request.id)
        case "jsdiag":
            // 页面环境自报（桥接排障）：只落日志并回 ok
            let hasWindowBus = (request.payload["hasWindowBus"] as? String) ?? "?"
            let hasWebkit = (request.payload["hasWebkitHandler"] as? Bool) ?? false
            DebugLogger.shared.log("[WebBridge][jsdiag] window.klineBus=\(hasWindowBus) webkitHandler=\(hasWebkit)")
            return WebBridgeResponse.ok(request.id)
        case "jsError":
            // 页面全局 JS 异常回报（window.onerror / unhandledrejection）
            let message = (request.payload["message"] as? String) ?? "?"
            let line = (request.payload["line"] as? Int) ?? 0
            DebugLogger.shared.log("[WebBridge][页面JS异常] \(message) @line \(line)")
            return WebBridgeResponse.ok(request.id)
        case "memory":
            return WebBridgeResponse.ok(request.id, data: ["footprintMB": MemoryFootprint.physFootprintMB()])
        case "info":
            return WebBridgeResponse.ok(request.id, data: Self.appInfo())
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action", message: "app.\(request.action) 未实现")
        }
    }

    private func handleTheme(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "get":
            // mode 由偏好 + 系统 trait 计算（PC HTTP 通道下宿主视图未运行，
            // resolvedMode 无真值——恒为默认 light 导致 PC 调试深色失效，2026-11-18 实测）
            let theme = KlineThemeStore.shared.theme
            return WebBridgeResponse.ok(request.id, data: ["preference": theme.rawValue,
                                                           "mode": Self.resolvedMode(for: theme)])
        case "set":
            // 协议 v2 首个写回动作（幂等）：写 KlineThemeStore 即完成；
            // 状态变化不在此回推——由宿主视图 onChange(themeStore) 链路推 theme.changed（写回模式单一数据流）
            guard let pref = request.payload["preference"] as? String,
                  let theme = KlineTheme(rawValue: pref) else {
                return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                              message: "preference 必须为 system / light / dark")
            }
            KlineThemeStore.shared.theme = theme
            DebugLogger.shared.log("[WebBridge] 主题写回: \(theme.rawValue)")
            return WebBridgeResponse.ok(request.id, data: ["preference": theme.rawValue])
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action", message: "theme.\(request.action) 未实现")
        }
    }

    private func handleProfile(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "snapshot":
            return WebBridgeResponse.ok(request.id, data: Self.profileSnapshot())
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action", message: "profile.\(request.action) 未实现")
        }
    }

    // MARK: - 快照数据（全部来自原生 Store，Web 侧不持有状态）

    /// 偏好 → 解析外观：dark/light 直接映射；跟随系统读当前 trait（主线程调用）
    static func resolvedMode(for preference: KlineTheme) -> String {
        switch preference {
        case .dark: return "dark"
        case .light: return "light"
        case .system:
            return UITraitCollection.current.userInterfaceStyle == .dark ? "dark" : "light"
        }
    }

    private static func appInfo() -> [String: Any] {
        let info = Bundle.main.infoDictionary
        return [
            "version": info?["CFBundleShortVersionString"] as? String ?? "",
            "build": info?["CFBundleVersion"] as? String ?? "",
        ]
    }

    private static func profileSnapshot() -> [String: Any] {
        let sync = TdxSyncConfig.shared
        var snapshot = appInfo()
        snapshot["syncEnabled"] = sync.enabled
        snapshot["scheduleTimes"] = sync.scheduleTimes
        snapshot["tradingDaysOnly"] = sync.tradingDaysOnly
        snapshot["dbLoaded"] = DatabaseManager.shared.isLoaded
        return snapshot
    }

    // MARK: - 回传与事件推送

    private func respond(_ message: [String: Any], to webView: WKWebView) {
        guard let js = WebBridgeJS.dispatchCall(message) else {
            DebugLogger.shared.log("[WebBridge] 注入串构造失败（消息不可序列化）")
            return
        }
        webView.evaluateJavaScript(js, completionHandler: { _, error in
            if let error = error {
                DebugLogger.shared.log("[WebBridge] 响应回传失败: \(error.localizedDescription)")
            }
        })
    }

    /// 事件推送（泛化入口）：默认推给最近就绪的页面；无就绪页面（如 PC 调试桥触发）
    /// 时静默跳过——pc 模式由页面回读权威状态，不依赖推送。
    /// - Parameter route: 传定时按 hash 路由**定向推送**（如 "sheet" 只推弹层浮层 WebView）。
    ///   ⚠️ readyWebViews 是弱引用无序集合，多 WebView 并存时
    ///   allObjects.last 不保证是最近打开的实例——2026-11-19 UITest 实测 sheet.open 被推到
    ///   Tab 宿主导致浮层面板永不渲染；宿主专属事件必须传 route。
    /// - Parameter routes: 多播（如 nav.tab 同时推 4 个 Tab 宿主、training.changed 双播
    ///   sheet + page）；Tab WebView 常驻化后数据事件必须 route/routes 定向，否则
    ///   会被无序弱表推给错误实例（2026-11-20 P2-9 白屏治理引入常驻后收紧）。
    func pushEvent(_ name: String, payload: [String: Any], route: String? = nil, routes: [String]? = nil) {
        let targets: [WKWebView]
        if let routes {
            targets = readyWebViews.allObjects.filter { w in
                routes.contains { w.url?.absoluteString.contains("#/\($0)") == true }
            }
        } else if let route {
            targets = readyWebViews.allObjects.filter {
                $0.url?.absoluteString.contains("#/\(route)") == true
            }
            if targets.isEmpty {
                DebugLogger.shared.log("[WebBridge] 事件定向推送无目标(\(name) → #/\(route))——目标 WebView 未就绪")
            }
        } else {
            targets = [readyWebViews.allObjects.last].compactMap { $0 }
        }
        let event = WebBridgeEvent.make(name, payload: payload)
        guard let js = WebBridgeJS.dispatchCall(event) else {
            DebugLogger.shared.log("[WebBridge] 事件推送串构造失败(\(name))")
            return
        }
        for webView in targets {
            webView.evaluateJavaScript(js, completionHandler: { _, error in
                if let error = error {
                    DebugLogger.shared.log("[WebBridge] 事件推送失败(\(name)): \(error.localizedDescription)")
                }
            })
        }
    }

    /// 主题变化推送（偏好变化或系统外观变化时由宿主视图调用，推给全部就绪页面）
    func pushTheme(preference: String, to target: WKWebView? = nil) {
        let targets = target.map { [$0] } ?? readyWebViews.allObjects
        guard !targets.isEmpty else { return }
        let event = WebBridgeEvent.make("theme.changed", payload: ["preference": preference, "mode": resolvedMode])
        guard let js = WebBridgeJS.dispatchCall(event) else {
            DebugLogger.shared.log("[WebBridge] 事件推送串构造失败(theme)")
            return
        }
        for webView in targets {
            webView.evaluateJavaScript(js, completionHandler: { _, error in
                if let error = error {
                    DebugLogger.shared.log("[WebBridge] 事件推送失败(theme): \(error.localizedDescription)")
                }
            })
        }
    }

    /// 内存足迹推送（页面就绪后一次；探针数据仅落日志与页面探针卡片）
    func pushMemoryFootprint(to target: WKWebView) {
        let event = WebBridgeEvent.make("app.memory", payload: ["footprintMB": MemoryFootprint.physFootprintMB()])
        guard let js = WebBridgeJS.dispatchCall(event) else {
            DebugLogger.shared.log("[WebBridge] 事件推送串构造失败(memory)")
            return
        }
        target.evaluateJavaScript(js, completionHandler: { _, error in
            if let error = error {
                DebugLogger.shared.log("[WebBridge] 事件推送失败(memory): \(error.localizedDescription)")
            }
        })
    }
}

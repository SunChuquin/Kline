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
import WebKit

final class WebMessageRouter: NSObject, WKScriptMessageHandler {

    // MARK: - 状态

    private weak var webView: WKWebView?
    /// 页面 didFinish 后才允许注入事件（避免对未就绪页面 evaluate 报错刷日志）
    private var isPageReady = false
    /// 解析后的实际外观（"light"/"dark"）：由宿主视图注入（跟随系统时视图环境是唯一真相）
    private(set) var resolvedMode = "light"

    // MARK: - 生命周期

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    /// 宿主视图在 onAppear / colorScheme 变化时注入解析外观
    func updateResolvedMode(_ mode: String) {
        resolvedMode = mode
    }

    func detach() {
        webView = nil
        isPageReady = false
        DebugLogger.shared.log("[WebBridge] 路由已分离（页面销毁）")
    }

    /// 页面 didFinish：打开事件推送门控并推送初始快照类事件
    func markPageReady(preference: String) {
        guard !isPageReady else { return }
        isPageReady = true
        pushTheme(preference: preference)
        pushMemoryFootprint()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == WebBridgeConst.channel, let webView = webView else { return }
        let started = CFAbsoluteTimeGetCurrent()

        guard let request = WebBridgeRequest.parse(message.body) else {
            respond(WebBridgeResponse.fail("unknown", code: "bad_request", message: "信封解析失败"), to: webView)
            return
        }
        let response = dispatch(request)
        respond(response, to: webView)

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        DebugLogger.shared.log("[WebBridge] \(request.module).\(request.action) 处理 \(String(format: "%.2f", elapsedMs))ms")
    }

    // MARK: - 分发

    private func dispatch(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.module {
        case "app":     return handleApp(request)
        case "theme":   return handleTheme(request)
        case "profile": return handleProfile(request)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_module", message: "未知模块 \(request.module)")
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
            return WebBridgeResponse.ok(request.id, data: ["preference": KlineThemeStore.shared.theme.rawValue,
                                                           "mode": resolvedMode])
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

    /// 注入完成回调采样（排障期）：前 3 次无条件记录 evaluateJavaScript 的 error 形态，
    /// 用于判明注入是否真的成功执行（2026-11-18：响应全丢但零错误日志的矛盾取证）
    private var injectionSampleRemaining = 3

    private func respond(_ message: [String: Any], to webView: WKWebView) {
        guard let js = WebBridgeJS.dispatchCall(message) else {
            DebugLogger.shared.log("[WebBridge] 注入串构造失败（消息不可序列化）")
            return
        }
        webView.evaluateJavaScript(js, completionHandler: { [weak self] _, error in
            guard let self = self else { return }
            if self.injectionSampleRemaining > 0 {
                self.injectionSampleRemaining -= 1
                DebugLogger.shared.log("[WebBridge] 注入采样: error=\(error?.localizedDescription ?? "nil")")
            } else if let error = error {
                DebugLogger.shared.log("[WebBridge] 响应回传失败: \(error.localizedDescription)")
            }
        })
    }

    /// 主题变化推送（偏好变化或系统外观变化时由 WebHostView 调用）
    func pushTheme(preference: String) {
        guard isPageReady, let webView = webView else { return }
        let event = WebBridgeEvent.make("theme.changed", payload: ["preference": preference, "mode": resolvedMode])
        guard let js = WebBridgeJS.dispatchCall(event) else {
            DebugLogger.shared.log("[WebBridge] 事件推送串构造失败(theme)")
            return
        }
        webView.evaluateJavaScript(js, completionHandler: { _, error in
            if let error = error {
                DebugLogger.shared.log("[WebBridge] 事件推送失败(theme): \(error.localizedDescription)")
            }
        })
    }

    /// 内存足迹推送（页面就绪后一次；探针数据仅落日志与页面探针卡片）
    func pushMemoryFootprint() {
        guard isPageReady, let webView = webView else { return }
        let event = WebBridgeEvent.make("app.memory", payload: ["footprintMB": MemoryFootprint.physFootprintMB()])
        guard let js = WebBridgeJS.dispatchCall(event) else {
            DebugLogger.shared.log("[WebBridge] 事件推送串构造失败(memory)")
            return
        }
        webView.evaluateJavaScript(js, completionHandler: { _, error in
            if let error = error {
                DebugLogger.shared.log("[WebBridge] 事件推送失败(memory): \(error.localizedDescription)")
            }
        })
    }
}

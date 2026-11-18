//
//  WebBridgeEnvelope.swift
//  Kline
//
//  Web↔Swift 桥接协议 v1 信封（单一事实源对齐 Web/src/types/protocol.ts）：
//    请求  { id, module, action, payload }   （Web → Swift，JSON 字符串经 messageHandler 传入）
//    响应  { id, ok, data | error }          （Swift → Web，按 id 配对）
//    事件  { event, payload }                （Swift → Web，Store 变化广播）
//  约定见 .trae/documents/Kline-混合架构改造方案.md §4。
//
//  P0 采用 JSONSerialization 宽松解析（payload 形态随试点页演化）；
//  P1 引入类型化 Codable schema + golden 测试锁定（方案 §4.4）。
//

import Foundation

/// 桥接常量（channel 与自定义 scheme 的单一命名来源）
enum WebBridgeConst {
    /// WKScriptMessageHandler 通道名（Web 侧 window.webkit.messageHandlers.kline）
    static let channel = "kline"
    /// 自定义 URL scheme（WebUISchemeHandler 注册）
    static let scheme = "kline"
    /// bundle 内 Web 资源目录（"Copy PyScripts" 构建阶段拷入，与 PyScripts 同模式）
    static let bundleDir = "WebUI"
}

struct WebBridgeRequest {
    let id: String
    let module: String
    let action: String
    let payload: [String: Any]

    /// 从 WKScriptMessage body（JSON 字符串）解析；形态不符返回 nil
    static func parse(_ body: Any) -> WebBridgeRequest? {
        guard let text = body as? String,
              let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["id"] as? String,
              let module = obj["module"] as? String,
              let action = obj["action"] as? String
        else { return nil }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        return WebBridgeRequest(id: id, module: module, action: action, payload: payload)
    }
}

/// 响应构造：{ id, ok, data | error }
enum WebBridgeResponse {
    static func ok(_ id: String, data: [String: Any] = [:]) -> [String: Any] {
        ["id": id, "ok": true, "data": data]
    }

    static func fail(_ id: String, code: String, message: String) -> [String: Any] {
        ["id": id, "ok": false, "error": ["code": code, "message": message]]
    }
}

/// 事件构造：{ event, payload }
enum WebBridgeEvent {
    static func make(_ event: String, payload: [String: Any] = [:]) -> [String: Any] {
        ["event": event, "payload": payload]
    }
}

/// JSON 消息 → evaluateJavaScript 注入调用串。
/// 注入安全性：JSON 文本 → JS 字符串字面量采用**手工转义**（\、"、控制字符），
/// 不依赖 JSONSerialization 编码 top-level String —— iOS 真机实测其对字符串顶层
/// 返回失败（2026-11-18 Build #613-615 根因：dispatchCall 恒 nil，响应从未注入，
/// 表现为页面 6s 超时且无任何错误日志）。页面侧 JSON.parse 还原对象。
enum WebBridgeJS {
    /// 生成 `window.klineBus.dispatch(JSON.parse(<literal>));` 调用串；消息不可序列化时返回 nil
    static func dispatchCall(_ message: [String: Any]) -> String? {
        guard let json = WebBridgeJSON.string(from: message) else { return nil }
        return "window.klineBus.dispatch(JSON.parse(\(Self.jsStringLiteral(json))));"
    }

    /// Swift String → 合法 JS 字符串字面量（含两侧引号）
    private static func jsStringLiteral(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
        return out
    }
}

enum WebBridgeJSON {
    /// dict/array → JSON 文本（sortedKeys 保证日志/注入内容确定性）；非合法对象返回 nil。
    /// 注意：仅用于 **dict/array 顶层**——iOS 真机实测 JSONSerialization 拒绝 String 顶层。
    static func string(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }
}

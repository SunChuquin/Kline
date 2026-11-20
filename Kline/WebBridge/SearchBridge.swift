//
//  SearchBridge.swift
//  Kline
//
//  搜索页桥（协议 v2 search.*）：P2-9b 搜索页 Web 化的 Swift 侧。
//  入口：market.openSearch / home.openEntry(search) → WebPageBridge.open("search")
//  全屏 Web 页；query 与 chart.search.query 同口径（searchMeta），openDetail 复用 DetailRouter。
//
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Combine
import Foundation

enum SearchBridge {

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "query":
            return query(request)
        case "openDetail":
            return openDetail(request)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "search.\(request.action) 未实现")
        }
    }

    /// search.query {keyword}：代码/名称模糊搜索（DatabaseManager.searchMeta 同口径）
    private static func query(_ request: WebBridgeRequest) -> [String: Any] {
        let kw = ((request.payload["keyword"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else {
            return WebBridgeResponse.ok(request.id, data: ["results": []])
        }
        let hits = DatabaseManager.shared.searchMeta(keyword: kw)
        let results: [[String: Any]] = hits.map { m in
            ["file": m.file, "code": m.displayCode, "name": m.name, "type": m.type]
        }
        return WebBridgeResponse.ok(request.id, data: ["results": results])
    }

    /// search.openDetail {file}：选中结果进 K 线详情（关闭搜索页）
    private static func openDetail(_ request: WebBridgeRequest) -> [String: Any] {
        let dbm = DatabaseManager.shared
        guard let file = request.payload["file"] as? String,
              let meta = dbm.metaList.first(where: { $0.file == file }) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "未找到标的 \(request.payload["file"] ?? "")")
        }
        WebPageBridge.shared.close()   // 进详情前关搜索页（对齐原生搜索选中即关）
        DetailRouter.shared.item = meta
        return WebBridgeResponse.ok(request.id)
    }
}

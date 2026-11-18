//
//  FavoritesBridge.swift
//  Kline
//
//  Favorites 域的桥接动作实现（协议 v2 favorites.*）：快照组装 / 刷新 / 进详情。
//  数据全部来自原生 Store（FavoritesStore / FavoritesPageModel / MarketRowCache），
//  Web 侧零状态。快照行顺序 = 原生 sortedRows（列配置排序 + 固顶优先稳定分区）。
//
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Foundation

enum FavoritesBridge {

    /// favorites 域动作分发
    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "snapshot":
            return WebBridgeResponse.ok(request.id, data: snapshotData())
        case "refresh":
            return refresh(groupIDString: request.payload["group"] as? String, id: request.id)
        case "openDetail":
            return openDetail(file: (request.payload["file"] as? String) ?? "", id: request.id)
        case "setNote":
            // P2-1b 实装（写回）
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "favorites.setNote 属 P2-1b")
        case "setPinned":
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "favorites.setPinned 属 P2-1b")
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "favorites.\(request.action) 未实现")
        }
    }

    /// favorites.snapshot：分组结构 + 行情行最小字段集
    /// rows 字段 = fixtures reserved 锁定的最小集（file/code/name/latestPrice/change/
    /// changePct/volume/turnover/lastDate/pinned/note）；数值未就绪发 null（Web 端显示 "-"）。
    static func snapshotData() -> [String: Any] {
        let model = FavoritesPageModel()
        let fav = FavoritesStore.shared
        var outGroups: [[String: Any]] = []
        for g in model.tabs {
            let rows = model.sortedRows(groupID: g.id)
            let pinned = Set(fav.pinnedIDs(groupID: g.id))
            let rowsAny: [[String: Any]] = rows.map { row in
                var d: [String: Any] = [
                    "file": row.meta.file,
                    "code": row.meta.displayCode,
                    "name": row.meta.name,
                    "pinned": pinned.contains(row.metaID),
                    "note": fav.note(for: row.metaID) ?? "",
                    "lastDate": row.meta.formattedLastDate,
                ]
                for (key, field) in [("latestPrice", MarketField.latestPrice),
                                     ("change", MarketField.change),
                                     ("changePct", MarketField.changePct),
                                     ("volume", MarketField.volume),
                                     ("turnover", MarketField.turnover)] {
                    d[key] = row.number(field) ?? NSNull()
                }
                return d
            }
            outGroups.append([
                "id": g.id.uuidString,
                "kind": g.kind == .manual ? "manual" : "formula",
                "name": g.name,
                "rows": rowsAny,
            ])
        }
        return ["groups": outGroups, "loaded": DatabaseManager.shared.isLoaded]
    }

    /// favorites.refresh {group?}：手动分组 → rowCache.refresh(metas:)；
    /// 公式分组 → fav.refreshFormulaGroup(id:candidates:cache:completion:)。
    /// 网络任务异步执行，本动作立即返回 queued；完成后 native 模式推 favorites.changed，
    /// pc 模式由页面定时回读 snapshot。
    static func refresh(groupIDString: String?, id: String) -> [String: Any] {
        let model = FavoritesPageModel()
        let fav = FavoritesStore.shared
        let rowCache = MarketRowCache.shared

        let groupID: UUID
        if let s = groupIDString, let u = UUID(uuidString: s),
           model.tabs.contains(where: { $0.id == u }) {
            groupID = u
        } else {
            groupID = model.currentGroup.id
        }
        guard let group = model.tabs.first(where: { $0.id == groupID }) else {
            return WebBridgeResponse.fail(id, code: "invalid_payload", message: "分组不存在")
        }
        let metas = model.items(groupID: groupID)

        let finished = {
            WebMessageRouter.shared.pushEvent("favorites.changed", payload: ["reason": "refresh"])
        }
        if group.kind == .formula {
            fav.refreshFormulaGroup(id: groupID, candidates: metas, cache: rowCache,
                                    completion: { _ in finished() })
        } else {
            rowCache.refresh(metas: metas)
            // refresh(metas:) 内部异步拉数：延迟一次推送兜底（缓存写入时机不确定）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finished() }
        }
        DebugLogger.shared.log("[FavoritesBridge] refresh group=\(group.name) metas=\(metas.count)")
        return WebBridgeResponse.ok(id, data: ["queued": true, "count": metas.count])
    }

    /// favorites.openDetail {file}：按 file 反查 MetaItem → DetailRouter 全屏 K 线图。
    static func openDetail(file: String, id: String) -> [String: Any] {
        guard let meta = DatabaseManager.shared.metaList.first(where: { $0.file == file }) else {
            return WebBridgeResponse.fail(id, code: "invalid_payload",
                                          message: "未找到标的 \(file)")
        }
        DetailRouter.shared.item = meta
        DebugLogger.shared.log("[FavoritesBridge] openDetail \(file)")
        return WebBridgeResponse.ok(id)
    }
}

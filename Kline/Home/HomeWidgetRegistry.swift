//
//  HomeWidgetRegistry.swift
//  Kline
//
//  首页控件注册表：把 JSON 配置里的控件名映射到具体视图。
//  6 个 home.* 控件名与内置默认配置（HomeLayoutDefaults.swift）中的 name 一一对应；
//  末尾另并入页面无关的通用控件（common.*，见 CommonLayoutWidgets.swift）；
//  未注册的控件名由 PageLayoutRenderer 渲染可诊断占位（不崩溃、不静默空白）。
//

import SwiftUI

/// 首页控件注册表（控件名 → 视图构建器；构建器接收 HomeLayoutContext + WidgetParams）
struct HomeWidgetRegistry {
    static let shared = HomeWidgetRegistry()

    /// 通用引擎的控件注册表
    let registry: PageWidgetRegistry<HomeLayoutContext>

    private init() {
        var r = PageWidgetRegistry<HomeLayoutContext>()

        r.register("home.header") { ctx, _ in
            AnyView(HomeHeaderBar(onProfile: ctx.onProfile))
        }

        r.register("home.quickEntryRow") { ctx, p in
            // entries 缺省 = 全量入口；空数组 = 零高度；未知 id 过滤；去重并保持配置顺序
            let kinds: [HomeEntryKind]
            if let rawIDs = p.strings("entries") {
                var seen = Set<String>()
                kinds = rawIDs.compactMap { raw in
                    guard let kind = HomeEntryKind(rawValue: raw), seen.insert(raw).inserted else { return nil }
                    return kind
                }
            } else {
                kinds = HomeEntryKind.allCases
            }
            return AnyView(HomeQuickEntryRow(kinds: kinds, onTap: ctx.onEntry))
        }

        r.register("home.marketOverview") { ctx, p in
            // indices 缺省 = 默认前 4；breadth 固定主板口径（概览条只展示一套涨跌家数）
            AnyView(HomeMarketOverviewStrip(rows: ctx.model.indexRows(selectedIDs: p.strings("indices")),
                                            breadth: ctx.model.breadth,
                                            compact: p.bool("compact", default: false)))
        }

        r.register("home.favorites") { ctx, p in
            // group 缺省 / 失效 = 「全部」虚拟分组；limit 0 = 默认前 5（口径在模型内归一）
            let rows = ctx.model.favoriteRows(groupIDString: p.optionalString("group"),
                                              limit: p.int("limit", default: 0))
            return AnyView(HomeFavoritesBlock(rows: rows,
                                              compact: p.bool("compact", default: false),
                                              showsSparkline: p.bool("showsSparkline", default: false),
                                              onOpen: HomeWidgetRegistry.openDetail,
                                              onEmptyTap: { ctx.onSelectTab(1) }))
        }

        r.register("home.simSummary") { ctx, p in
            AnyView(HomeSimSummaryBlock(model: ctx.model,
                                        accountIDString: p.optionalString("account"),
                                        compact: p.bool("compact", default: false),
                                        onTap: { ctx.onSelectTab(3) }))
        }

        r.register("home.topGainers") { ctx, p in
            let style: HomeTopGainersBlock.Style =
                p.string("style", default: "list") == "chips" ? .chips : .list
            let board = p.string("board", default: "mainBoard")
            return AnyView(HomeTopGainersBlock(rows: ctx.model.gainersRows(board: board),
                                               style: style,
                                               compact: p.bool("compact", default: false),
                                               isReady: ctx.model.gainersReady(board: board),
                                               onOpen: HomeWidgetRegistry.openDetail))
        }

        // 页面无关的通用控件（横滑卡片 / 列表卡片）：
        // 只吃 WidgetParams、不读 HomeLayoutContext，未来其它页面的注册表可直接复用同一组
        registerCommonLayoutWidgets(into: &r)

        registry = r
    }

    /// 打开 K 线详情（与各档布局视图同机制，带上当前列表作为副图切换上下文）
    private static func openDetail(_ meta: MetaItem, in context: [MetaItem]) {
        DetailRouter.shared.open(meta, in: context)
    }
}
//
//  HomeWidgetRegistry.swift
//  Kline
//
//  首页控件注册表：把 JSON 配置里的 7 个控件名映射到具体视图。
//  控件名与内置默认配置（HomeLayoutDefaults.swift）中的 name 一一对应；
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

        r.register("home.quickEntryRow") { ctx, _ in
            AnyView(HomeQuickEntryRow(onTap: ctx.onEntry))
        }

        r.register("home.placeholder") { _, _ in
            AnyView(HomePlaceholderBlock())
        }

        r.register("home.marketOverview") { ctx, p in
            AnyView(HomeMarketOverviewStrip(rows: ctx.model.indexQuotes,
                                            breadth: ctx.model.breadth,
                                            compact: p.bool("compact", default: false)))
        }

        r.register("home.favorites") { ctx, p in
            let limit = p.int("limit", default: 0)
            let rows = limit > 0 ? Array(ctx.model.favoriteRows.prefix(limit))
                                 : ctx.model.favoriteRows
            return AnyView(HomeFavoritesBlock(rows: rows,
                                              compact: p.bool("compact", default: false),
                                              showsSparkline: p.bool("showsSparkline", default: false),
                                              onOpen: HomeWidgetRegistry.openDetail,
                                              onEmptyTap: { ctx.onSelectTab(1) }))
        }

        r.register("home.simSummary") { ctx, p in
            AnyView(HomeSimSummaryBlock(model: ctx.model,
                                        compact: p.bool("compact", default: false),
                                        onTap: { ctx.onSelectTab(3) }))
        }

        r.register("home.topGainers") { ctx, p in
            let style: HomeTopGainersBlock.Style =
                p.string("style", default: "list") == "chips" ? .chips : .list
            return AnyView(HomeTopGainersBlock(rows: ctx.model.topGainers,
                                               style: style,
                                               compact: p.bool("compact", default: false),
                                               isReady: ctx.model.isMarketReady,
                                               onOpen: HomeWidgetRegistry.openDetail))
        }

        registry = r
    }

    /// 打开 K 线详情（与各档布局视图同机制，带上当前列表作为副图切换上下文）
    private static func openDetail(_ meta: MetaItem, in context: [MetaItem]) {
        DetailRouter.shared.open(meta, in: context)
    }
}
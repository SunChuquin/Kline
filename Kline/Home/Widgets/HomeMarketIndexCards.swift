//
//  HomeMarketIndexCards.swift
//  Kline
//
//  首页 JSON 布局控件：指数卡片（home.marketIndexCards）。
//
//  与 MarketIndexCard 的分工：
//  · MarketIndexCard 是纯视觉组件（只认 MarketIndexQuote，不碰数据层）；
//  · 本文件负责把首页的 MarketRow 映射成卡片模型、订阅行缓存刷新、并承接点击进详情。
//
//  参数（与 HomeWidgetEditorSchema 的 home.marketIndexCards 一一对应）：
//  · indices     有序多选（缺省 = 默认前 4 只，最多 6 只）
//  · columns     每行列数 2~6（首卡单独展示时，其余指数按此列数排紧凑卡）
//  · lead        首卡形态 standard / chart / none
//

import SwiftUI

// MARK: - 行情行 → 卡片模型

extension MarketIndexQuote {

    /// 由行情行映射为卡片模型：展示文本全部取自行内已渲染值（与行情表口径完全一致），
    /// 不在卡片层二次格式化，避免两处小数位/舍入口径不一致。
    init(row: MarketRow) {
        let meta = row.meta
        let pct = row.number(.changePct)
        self.init(
            id: String(meta.id),
            name: meta.name,
            code: meta.code,
            market: Self.marketLabel(for: meta.code),
            status: nil,
            priceText: row.text(.latestPrice),
            changeText: row.text(.change),
            pctText: row.text(.changePct),
            direction: MarketQuoteDirection.from(changePct: pct.map { Decimal($0) }),
            sparkline: row.recentCloses,
            highText: Self.displayText(row.text(.high)),
            lowText: Self.displayText(row.text(.low)),
            turnoverText: Self.displayText(row.text(.turnover)),
            updatedText: nil
        )
    }

    /// 市场标记：由代码前缀推导（SH → SSE / SZ → SZSE / BJ → BSE），未知前缀不显示
    private static func marketLabel(for code: String) -> String? {
        let upper = code.uppercased()
        if upper.hasPrefix("SH") { return "SSE" }
        if upper.hasPrefix("SZ") { return "SZSE" }
        if upper.hasPrefix("BJ") { return "BSE" }
        return nil
    }

    /// 行情行无值时渲染为 "-"：卡片底部统计对占位符改为「不展示」，避免一排 "-"
    private static func displayText(_ text: String) -> String? {
        text == "-" ? nil : text
    }
}

// MARK: - 指数卡片控件

/// 首页指数卡片：首卡（标准 / 图表 / 不展示）+ 其余按列数排紧凑卡。
/// 直接观察行缓存与数据库加载态：bars / 引擎字段陆续到位时本块自行刷新。
struct HomeMarketIndexCards: View {

    /// 首卡形态
    enum LeadStyle {
        case standard
        case chart
        case none
    }

    /// 指数行（HomePageModel.indexRows）
    let rows: [MarketRow]
    /// 其余指数的每行列数（2~6）
    var columnCount: Int = 2
    /// 首卡形态
    var lead: LeadStyle = .standard
    /// 点击卡片：打开该指数 K 线详情（带上当前指数集合作为副图切换上下文）
    let onOpen: (MetaItem, [MetaItem]) -> Void

    /// 行缓存：字段/走势陆续到位时刷新
    @ObservedObject private var rowCache = MarketRowCache.shared
    /// 数据库加载态：区分「加载中」与「加载完但没有指数数据」
    @ObservedObject private var db = DatabaseManager.shared

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12),
              count: min(max(columnCount, 2), 6))
    }

    /// 行 → (卡片模型, meta) 配对；meta 用于点击进详情
    private var items: [(quote: MarketIndexQuote, meta: MetaItem)] {
        rows.map { (MarketIndexQuote(row: $0), $0.meta) }
    }

    private var context: [MetaItem] { rows.map { $0.meta } }

    var body: some View {
        if rows.isEmpty {
            Text(db.isLoaded ? "暂无指数数据" : "指数加载中")
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        } else {
            VStack(spacing: 12) {
                if lead != .none, let first = items.first {
                    MarketIndexCard(quote: first.quote,
                                    style: lead == .chart ? .chart : .standard,
                                    onTap: { _ in onOpen(first.meta, context) })
                }
                let gridItems = lead == .none ? items : Array(items.dropFirst())
                if !gridItems.isEmpty {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(gridItems.indices, id: \.self) { index in
                            let item = gridItems[index]
                            MarketIndexCard(quote: item.quote,
                                            style: .compact,
                                            showsFooter: false,
                                            onTap: { _ in onOpen(item.meta, context) })
                        }
                    }
                }
            }
        }
    }
}

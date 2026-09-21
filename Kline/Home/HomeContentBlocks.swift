//
//  HomeContentBlocks.swift
//  Kline
//
//  首页内容区共享块（B/C/D 三档共用，只参数化呈现）：
//  大盘概览条 / 我的自选 / 模拟账户汇总 / 涨幅榜，外层统一套 HomeSectionCard 卡片容器。
//  设计要点：
//  - 口径（哪些行、什么顺序、聚合统计）全部来自 HomePageModel 快照；块内只遍历传入的
//    5 条行数组，不做任何全表遍历 / O(n) 聚合（body 内禁止重计算）；
//  - 行情数值一律经 `@ObservedObject rowCache = MarketRowCache.shared` 读 `MarketRow`：
//    MarketRow 是引用类型，bars 陆续到位时只有走 ObservedObject 才会触发重绘
//    （与 MarketTileCard 同机制；HomePageModel 的快照在 metaID 集合不变时不重发）；
//  - 全部语义色（涨红跌绿，平盘 / 无值走语义灰）；行 / 卡点击区 contentShape(Rectangle())，
//    命中区 ≥ 44pt（紧凑行 40pt 时外层补足），空态 / 加载态高度固定、切换不抖动。
//

import SwiftUI

// MARK: - 区块容器

/// 内容区块容器：小标题 + 内容，浅灰卡片。
/// 内边距紧凑 10 / 常规 12；块间距（12）由各档布局视图控制。
struct HomeSectionCard<Content: View>: View {
    let title: String
    /// 紧凑档：内边距更小（C 档通栏、D 档小卡）
    var compact: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            content
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - 文件内配色助手（涨红跌绿，平盘 / 无值用语义灰）

/// 涨跌数字着色：涨红 / 跌绿 / 平盘或无值用主色
private func homeQuoteTint(_ pct: Double?) -> Color {
    guard let p = pct else { return .primary }
    if p > 0 { return .red }
    if p < 0 { return .green }
    return .primary
}

/// 涨跌幅胶囊底色：平盘 / 无值用系统灰（避免暗示方向）
private func homePillColor(_ pct: Double?) -> Color {
    guard let p = pct else { return Color(.systemGray) }
    if p > 0 { return .red }
    if p < 0 { return .green }
    return Color(.systemGray)
}

/// 盈亏配色（涨红跌绿）：与模拟模块 simProfitColor 同口径（后者为文件内私有，故此处重写）
private func homeProfitColor(_ v: Double) -> Color {
    v < 0 ? Color(.systemGreen) : Color(.systemRed)
}

// MARK: - 行情行（自选块 / 涨幅榜列表共用）

/// 行情行：名称 + 代码 / 现价 / 涨跌幅胶囊（可选迷你走势）。
/// 行高固定（常规 48 / 紧凑 40），点整行打开该标的 K 线详情。
struct HomeQuoteRow: View {
    let row: MarketRow
    /// 点击上下文（详情页副图左右滑动切换用）
    let context: [MarketRow]
    let compact: Bool
    let showsSparkline: Bool
    let onOpen: (MetaItem, [MetaItem]) -> Void

    var body: some View {
        let meta = row.meta
        let pct = row.number(.changePct)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.name)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(meta.displayCode)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(row.text(.latestPrice))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(homeQuoteTint(pct))
                .lineLimit(1)

            Text(row.text(.changePct))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(homePillColor(pct))
                .cornerRadius(6)

            if showsSparkline {
                MarketSparkline(closes: Array(row.recentCloses.suffix(20)), up: (pct ?? 0) >= 0)
                    .frame(width: 60, height: 24)
            }
        }
        .frame(height: compact ? 40 : 48)
        // 紧凑行 40pt：行外层上下各补 2pt（透明），命中区补足到 ≥ 44pt，视觉高度不变
        .padding(.vertical, compact ? 2 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen(meta, context.map { $0.meta })
        }
    }
}

// MARK: - 大盘概览条

/// 大盘概览条：横向 4 项指数（名称 / 现价 / 涨跌幅，涨红跌绿）+ 沪深主板涨跌家数。
/// 点指数项 → 打开该指数 K 线详情；`breadth == nil` 时显示「加载中」，不伪造数值。
struct HomeMarketOverviewStrip: View {
    /// 指数行（HomePageModel.indexQuotes）
    let rows: [MarketRow]
    /// 沪深主板涨跌家数（nil = 尚无有效聚合）
    let breadth: HomeBreadth?
    let compact: Bool

    /// 直接观察行缓存：bars 陆续到位时本块自行刷新
    @ObservedObject private var rowCache = MarketRowCache.shared

    /// 指数区固定高度（≥ 44pt 命中区）：加载态与就绪态一致，bars 到位时不抖动
    private var indexAreaHeight: CGFloat { compact ? 50 : 52 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            if rows.isEmpty {
                Text("指数加载中")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: indexAreaHeight, alignment: .leading)
            } else {
                HStack(spacing: 0) {
                    ForEach(rows) { row in
                        indexCell(row)
                    }
                }
            }
            breadthLine
        }
    }

    /// 单个指数：名称 / 现价 / 涨跌幅，点开该指数 K 线详情
    private func indexCell(_ row: MarketRow) -> some View {
        let meta = row.meta
        let pct = row.number(.changePct)
        return VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            Text(meta.name)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(row.text(.latestPrice))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(homeQuoteTint(pct))
                .lineLimit(1)
            Text(row.text(.changePct))
                .font(.system(size: 12))
                .foregroundColor(homeQuoteTint(pct))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: indexAreaHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            DetailRouter.shared.open(meta, in: rows.map { $0.meta })
        }
    }

    /// 涨跌家数：涨 N · 平 N · 跌 N / 涨停 N / 跌停 N（涨红、跌绿、平用次要色）
    @ViewBuilder
    private var breadthLine: some View {
        if let b = breadth {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("涨 \(b.up)").foregroundColor(.red)
                    Text("·").foregroundColor(.secondary)
                    Text("平 \(b.flat)").foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                    Text("跌 \(b.down)").foregroundColor(.green)
                }
                .font(.system(size: 12))

                HStack(spacing: 6) {
                    Text("涨停 \(b.limitUp)").foregroundColor(.red)
                    Text("/").foregroundColor(.secondary)
                    Text("跌停 \(b.limitDown)").foregroundColor(.green)
                }
                .font(.system(size: 12))
            }
        } else {
            Text("加载中")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        }
    }
}

// MARK: - 我的自选

/// 我的自选：每行 = 名称 + 代码 / 现价 / 涨跌幅胶囊（可选迷你走势）；点行打开 K 线详情。
/// 空态整块可点 → 切自选页（由容器把 `onEmptyTap` 接到 `onSelectTab(1)`）。
struct HomeFavoritesBlock: View {
    let rows: [MarketRow]
    let compact: Bool
    let showsSparkline: Bool
    let onOpen: (MetaItem, [MetaItem]) -> Void
    let onEmptyTap: () -> Void

    /// 直接观察行缓存：bars 陆续到位时本块自行刷新
    @ObservedObject private var rowCache = MarketRowCache.shared

    var body: some View {
        if rows.isEmpty {
            Text("暂无自选，去自选页添加")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: compact ? 44 : 48, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onEmptyTap() }
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HomeQuoteRow(row: row, context: rows, compact: compact,
                                 showsSparkline: showsSparkline, onOpen: onOpen)
                }
            }
        }
    }
}

// MARK: - 模拟账户汇总

/// 模拟账户汇总（全部账户）：总资产 / 当日盈亏（金额 + 百分比）/ 持仓占比 + 持仓 Top N。
/// 金额与百分比格式化复用 SimFormat（与模拟页 SimSummaryBand 同口径）；
/// 整块可点 → 切模拟页（由容器把 `onTap` 接到 `onSelectTab(3)`）。
struct HomeSimSummaryBlock: View {
    @ObservedObject var model: HomePageModel
    let compact: Bool
    let onTap: () -> Void

    /// 直接观察行缓存：持仓现价 / 盈亏随 bars 到位刷新
    @ObservedObject private var rowCache = MarketRowCache.shared

    var body: some View {
        let summary = model.simSummary
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            // 总资产（大字）
            VStack(alignment: .leading, spacing: 2) {
                Text("总资产")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(SimFormat.amount0(summary.totalAssets))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }

            // 当日盈亏 + 持仓占比
            HStack(alignment: .top, spacing: 14) {
                metric(label: "当日盈亏", value: SimFormat.signed0(summary.dayProfit),
                       extra: SimFormat.pct(summary.dayProfitPct * 100),
                       color: homeProfitColor(summary.dayProfit))
                metric(label: "持仓占比", value: SimFormat.pct(summary.positionPct * 100),
                       extra: nil, color: .primary)
            }

            // 持仓 Top N（行高与自选块一致）
            if model.simTopPositions.isEmpty {
                Text("暂无持仓")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: compact ? 44 : 48, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.simTopPositions) { p in
                        positionRow(p)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    /// 指标项：标签 + 数值（+ 可选百分比）
    private func metric(label: String, value: String, extra: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(color)
                    .lineLimit(1)
                if let extraText = extra {
                    Text(extraText)
                        .font(.system(size: 11))
                        .foregroundColor(color)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 持仓行：名称 + 代码 / 现价 / 盈亏（金额 + 百分比，着色）
    private func positionRow(_ p: SimPosition) -> some View {
        let snap = model.simSnapshot(for: p)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(p.code)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(SimFormat.price(snap.lastPrice))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            VStack(alignment: .trailing, spacing: 2) {
                Text(SimFormat.signed(snap.profit))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(homeProfitColor(snap.profit))
                    .lineLimit(1)
                Text(SimFormat.pct(snap.profitPct * 100))
                    .font(.system(size: 11))
                    .foregroundColor(homeProfitColor(snap.profitPct))
                    .lineLimit(1)
            }
        }
        .frame(height: compact ? 40 : 48)
        // 紧凑行 40pt：外层上下各补 2pt，命中区补足（整块本身可点，此处仅保证行高一致）
        .padding(.vertical, compact ? 2 : 0)
    }
}

// MARK: - 涨幅榜

/// 涨幅榜 Top5：两种呈现（列表行 / 横滑 chips），口径同一份数据（HomePageModel.topGainers）。
/// 点任一项打开该标的 K 线详情；`rows` 为空且 `!isReady` 时显示「数据加载中」。
struct HomeTopGainersBlock: View {
    /// 呈现方式：列表行 / 横滑 chips
    enum Style {
        case list
        case chips
    }

    let rows: [MarketRow]
    let style: Style
    let compact: Bool
    let isReady: Bool
    let onOpen: (MetaItem, [MetaItem]) -> Void

    /// 直接观察行缓存：bars 陆续到位时本块自行刷新
    @ObservedObject private var rowCache = MarketRowCache.shared

    var body: some View {
        if rows.isEmpty {
            Text(isReady ? "暂无数据" : "数据加载中")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: compact ? 44 : 48, alignment: .leading)
        } else {
            switch style {
            case .list:
                listBody
            case .chips:
                chipsBody
            }
        }
    }

    /// 列表行呈现（与自选块同款行，无走势图）
    private var listBody: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HomeQuoteRow(row: row, context: rows, compact: compact,
                             showsSparkline: false, onOpen: onOpen)
            }
        }
    }

    /// 横滑 chips 呈现（每 chip 宽 150 / 高 72）
    private var chipsBody: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(rows) { row in
                    chip(row)
                }
            }
        }
    }

    private func chip(_ row: MarketRow) -> some View {
        let meta = row.meta
        let pct = row.number(.changePct)
        return VStack(alignment: .leading, spacing: 4) {
            Text(meta.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
            Text(row.text(.latestPrice))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(homeQuoteTint(pct))
                .lineLimit(1)
            Text(row.text(.changePct))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(homePillColor(pct))
                .cornerRadius(6)
        }
        .padding(.horizontal, 10)
        .frame(width: 150, height: 72, alignment: .leading)
        .background(Color(.systemBackground))
        .cornerRadius(10)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen(meta, rows.map { $0.meta })
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 12) {
            HomeSectionCard(title: "大盘概览") {
                HomeMarketOverviewStrip(rows: [], breadth: nil, compact: false)
            }
            HomeSectionCard(title: "我的自选") {
                HomeFavoritesBlock(rows: [], compact: false, showsSparkline: true,
                                   onOpen: { _, _ in }, onEmptyTap: {})
            }
            HomeSectionCard(title: "模拟账户") {
                HomeSimSummaryBlock(model: HomePageModel(), compact: false, onTap: {})
            }
            HomeSectionCard(title: "涨幅榜") {
                HomeTopGainersBlock(rows: [], style: .list, compact: false,
                                    isReady: false, onOpen: { _, _ in })
            }
        }
        .padding(16)
    }
}
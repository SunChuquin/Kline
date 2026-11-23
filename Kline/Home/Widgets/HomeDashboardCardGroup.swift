//
//  HomeDashboardCardGroup.swift
//  Kline
//
//  首页 JSON 布局控件：通用功能卡片组（home.dashboardGroup）。
//
//  架构原则：**容器负责布局，子组件负责内容**。
//  · DashboardCardGroup —— 统一容器（标题/副标题、底色、圆角、内边距、描边，日/夜自动切换）；
//  · DashboardShortcutGrid —— 快捷功能入口宫格（图标 + 名称 + 角标）；
//  · DashboardIndexGrid —— 行情指数卡片网格（复用 MarketIndexCard 紧凑卡，真实数据）；
//  · DashboardCustomList —— 自定义条目（标题 / 副标题 / 角标）。
//  容器不认识任何业务细节，只负责排列与分页；新增内容类型时只加一个子网格，改容器。
//
//  参数（与 HomeWidgetEditorSchema 的 home.dashboardGroup 一一对应）：
//  · title / subtitle  分组标题 / 副标题（留空不显示）
//  · content           shortcuts / indices / custom
//  · columns           每行列数 1~100
//  · rowsPerPage       每页行数 1~5（开启分页时生效）
//  · paging            横向分页：每页容量 = 列数 × 每页行数，最多 10 页（与内容类型无关）
//  · entries / hotEntries / badgeText   快捷入口项 / 加角标的入口 / 角标文字
//  · indices           指数卡片类型展示哪些指数（个数不限，缺省 = 前 4 只）
//  · items             自定义条目，每行「标题|副标题|角标」
//

import SwiftUI

// MARK: - 自定义条目

/// 自定义条目：标题必填，副标题 / 角标可选
struct DashboardCustomItem: Identifiable, Equatable {
    let id: Int
    let title: String
    let subtitle: String?
    let badge: String?
}

// MARK: - 分组配色（日 / 夜两套）

private struct DashboardGroupPalette {
    let isDark: Bool
    /// 组容器底色（比内层卡片浅/深一档，形成层次）
    let groupFill: Color
    let border: Color
    let primaryText: Color
    let secondaryText: Color
    let divider: Color
    /// 角标底色（HOT 等）
    let badgeFill: Color

    static func resolve(_ scheme: ColorScheme) -> DashboardGroupPalette {
        if scheme == .dark {
            return DashboardGroupPalette(
                isDark: true,
                groupFill: Color(red: 0.055, green: 0.082, blue: 0.133),   // #0E1522
                border: Color.white.opacity(0.06),
                primaryText: .white,
                secondaryText: Color.white.opacity(0.55),
                divider: Color.white.opacity(0.06),
                badgeFill: Color(red: 1.00, green: 0.30, blue: 0.32)       // #FF4D52
            )
        }
        return DashboardGroupPalette(
            isDark: false,
            groupFill: Color(red: 0.969, green: 0.976, blue: 0.988),       // #F7F9FC
            border: Color(red: 0.929, green: 0.941, blue: 0.957),          // #EDF0F4
            primaryText: Color(red: 0.090, green: 0.125, blue: 0.200),     // #172033
            secondaryText: Color(red: 0.573, green: 0.608, blue: 0.667),   // #929BAA
            divider: Color(red: 0.929, green: 0.941, blue: 0.957),         // #EDF0F4
            badgeFill: Color(red: 0.890, green: 0.302, blue: 0.302)        // #E34D4D
        )
    }
}

// MARK: - 统一容器

/// 功能卡片组容器：标题 + 副标题 + 任意内容，统一底色 / 圆角 / 内边距 / 描边。
struct DashboardCardGroup<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var colorScheme

    private var palette: DashboardGroupPalette { .resolve(colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasHeader {
                VStack(alignment: .leading, spacing: 3) {
                    if let title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(palette.primaryText)
                            .lineLimit(1)
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(palette.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.groupFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(palette.border, lineWidth: 0.5)
                )
        )
    }

    private var hasHeader: Bool {
        (title?.isEmpty == false) || (subtitle?.isEmpty == false)
    }
}

// MARK: - 横向分页器（TabView page 样式 + 自绘页点）

private struct DashboardPager<Content: View>: View {
    let pageCount: Int
    let pageHeight: CGFloat
    @ViewBuilder let content: (Int) -> Content

    @State private var selection = 0

    var body: some View {
        VStack(spacing: 8) {
            TabView(selection: $selection) {
                ForEach(0..<max(pageCount, 1), id: \.self) { index in
                    content(index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: pageHeight)

            if pageCount > 1 {
                HStack(spacing: 5) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Circle()
                            .fill(index == selection ? Color.accentColor
                                                     : Color.accentColor.opacity(0.25))
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - 快捷功能入口宫格

private struct DashboardShortcutGrid: View {
    let entries: [HomeEntryKind]
    let hotEntries: Set<HomeEntryKind>
    let badgeText: String
    let columns: Int
    let rowsPerPage: Int
    let paging: Bool
    let onTap: (HomeEntryKind) -> Void

    /// 固定行高：分页高度必须可预算，不允许子项高度浮动
    private let cellHeight: CGFloat = 78
    private let spacing: CGFloat = 12

    var body: some View {
        if entries.isEmpty {
            DashboardEmptyHint(text: "未选择快捷入口")
        } else if paging {
            let rows = max(rowsPerPage, 1)
            let perPage = max(columns, 1) * rows
            let pages = Array(chunked(entries, size: perPage).prefix(DashboardPaging.maxPages))
            DashboardPager(pageCount: pages.count,
                           pageHeight: CGFloat(rows) * cellHeight
                                      + CGFloat(rows - 1) * spacing) { index in
                grid(pages[index])
            }
        } else {
            grid(entries)
        }
    }

    private func grid(_ items: [HomeEntryKind]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing),
                                 count: max(columns, 1)),
                  spacing: spacing) {
            ForEach(items) { kind in
                DashboardShortcutCell(kind: kind,
                                      badge: hotEntries.contains(kind) ? badgeText : nil,
                                      cellHeight: cellHeight,
                                      action: { onTap(kind) })
            }
        }
    }
}

/// 单个快捷入口：图标（入口色）+ 名称 + 可选角标
private struct DashboardShortcutCell: View {
    let kind: HomeEntryKind
    let badge: String?
    let cellHeight: CGFloat
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var palette: DashboardGroupPalette { .resolve(colorScheme) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(kind.tint.opacity(palette.isDark ? 0.18 : 0.12))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: kind.icon)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(kind.tint)
                        )

                    if let badge, !badge.isEmpty {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(palette.badgeFill)
                            .clipShape(Capsule())
                            .offset(x: 8, y: -5)
                    }
                }
                Text(kind.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(palette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(height: cellHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dashboard.entry.\(kind.rawValue)")
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = "\(kind.title)，\(kind.subtitle)"
        if let badge, !badge.isEmpty { text += "，\(badge)" }
        return text
    }
}

// MARK: - 行情指数卡片网格

private struct DashboardIndexGrid: View {
    let rows: [MarketRow]
    let columns: Int
    let rowsPerPage: Int
    let paging: Bool
    let onOpen: (MetaItem, [MetaItem]) -> Void

    /// 行缓存：字段 / 走势陆续到位时本块自行刷新
    @ObservedObject private var rowCache = MarketRowCache.shared
    @ObservedObject private var db = DatabaseManager.shared

    private let spacing: CGFloat = 12
    /// 单行高度（紧凑卡约 153pt，留出动态字体余量）
    private let rowHeight: CGFloat = 172

    private var quotes: [MarketIndexQuote] { rows.map { MarketIndexQuote(row: $0) } }

    var body: some View {
        if rows.isEmpty {
            DashboardEmptyHint(text: db.isLoaded ? "暂无指数数据" : "指数加载中")
        } else if paging {
            let rowsPer = max(rowsPerPage, 1)
            let perPage = max(columns, 1) * rowsPer
            let pages = Array(chunked(quotes, size: perPage).prefix(DashboardPaging.maxPages))
            let pageHeight = CGFloat(rowsPer) * rowHeight + CGFloat(rowsPer - 1) * spacing
            DashboardPager(pageCount: pages.count, pageHeight: pageHeight) { index in
                grid(pages[index])
                    .frame(height: pageHeight, alignment: .top)
            }
        } else {
            grid(quotes)
        }
    }

    private func grid(_ items: [MarketIndexQuote]) -> some View {
        let metas = rows.map { $0.meta }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing),
                                        count: max(columns, 1)),
                         spacing: spacing) {
            ForEach(items) { quote in
                MarketIndexCard(quote: quote,
                                style: .compact,
                                showsFooter: false,
                                onTap: { tapped in
                                    guard let row = rows.first(where: {
                                        String($0.meta.id) == tapped.id
                                    }) else { return }
                                    onOpen(row.meta, metas)
                                })
            }
        }
    }
}

// MARK: - 自定义条目列表

private struct DashboardCustomList: View {
    let items: [DashboardCustomItem]
    let rowsPerPage: Int
    let paging: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var palette: DashboardGroupPalette { .resolve(colorScheme) }

    private let rowHeight: CGFloat = 52
    private let rowSpacing: CGFloat = 10

    var body: some View {
        if items.isEmpty {
            DashboardEmptyHint(text: "未配置条目：在检查器里填写「自定义条目」（每行：标题|副标题|角标）")
        } else if paging {
            let rows = max(rowsPerPage, 1)
            let pages = Array(chunked(items, size: rows).prefix(DashboardPaging.maxPages))
            DashboardPager(pageCount: pages.count,
                           pageHeight: CGFloat(rows) * rowHeight
                                      + CGFloat(rows - 1) * rowSpacing) { index in
                list(pages[index])
            }
        } else {
            list(items)
        }
    }

    private func list(_ items: [DashboardCustomItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(palette.primaryText)
                            .lineLimit(1)
                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundColor(palette.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if let badge = item.badge, !badge.isEmpty {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(palette.badgeFill)
                            .clipShape(Capsule())
                    }
                }
                .frame(height: rowHeight)

                if item.id != items.last?.id {
                    Rectangle()
                        .fill(palette.divider)
                        .frame(height: 0.5)
                }
            }
        }
    }
}

// MARK: - 空态提示

private struct DashboardEmptyHint: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 13))
            Text(text)
                .font(.system(size: 12))
                .lineLimit(2)
        }
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

// MARK: - 分页 / 网格口径（与内容类型无关）

private enum DashboardPaging {
    /// 横向最多页数
    static let maxPages = 10
    /// 每行最多列数
    static let maxColumns = 100
    /// 每页最多行数
    static let maxRowsPerPage = 5
}

// MARK: - 分组切页工具

/// 按 size 切块（size ≤ 0 或空数组返回空）
private func chunked<T>(_ items: [T], size: Int) -> [[T]] {
    guard size > 0, !items.isEmpty else { return [] }
    return stride(from: 0, to: items.count, by: size).map {
        Array(items[$0..<min($0 + size, items.count)])
    }
}

// MARK: - 控件主体（注册表入口）

/// 功能卡片组控件：按内容类型分发到对应子网格，容器只管布局。
struct HomeDashboardCardGroup: View {

    enum ContentKind {
        case shortcuts
        case indices
        case custom
    }

    var kind: ContentKind = .shortcuts
    var title: String?
    var subtitle: String?
    /// 每行列数（1~100）
    var columns: Int = 2
    /// 每页行数（1~5）
    var rowsPerPage: Int = 2
    /// 横向分页（最多 10 页，与内容类型无关）
    var paging: Bool = false
    // 快捷入口
    var entries: [HomeEntryKind] = []
    var hotEntries: Set<HomeEntryKind> = []
    var badgeText: String = "HOT"
    // 指数卡片
    var indexRows: [MarketRow] = []
    // 自定义条目
    var customItems: [DashboardCustomItem] = []
    // 交互
    var onEntry: (HomeEntryKind) -> Void = { _ in }
    var onOpenIndex: (MetaItem, [MetaItem]) -> Void = { _, _ in }

    private var safeColumns: Int {
        min(max(columns, 1), DashboardPaging.maxColumns)
    }

    private var safeRowsPerPage: Int {
        min(max(rowsPerPage, 1), DashboardPaging.maxRowsPerPage)
    }

    var body: some View {
        DashboardCardGroup(title: title, subtitle: subtitle) {
            switch kind {
            case .shortcuts:
                DashboardShortcutGrid(entries: entries,
                                      hotEntries: hotEntries,
                                      badgeText: badgeText,
                                      columns: safeColumns,
                                      rowsPerPage: safeRowsPerPage,
                                      paging: paging,
                                      onTap: onEntry)
            case .indices:
                DashboardIndexGrid(rows: indexRows,
                                   columns: safeColumns,
                                   rowsPerPage: safeRowsPerPage,
                                   paging: paging,
                                   onOpen: onOpenIndex)
            case .custom:
                DashboardCustomList(items: customItems,
                                    rowsPerPage: safeRowsPerPage,
                                    paging: paging)
            }
        }
    }
}

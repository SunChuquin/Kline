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
//  · columns           每行列数：0 = 自适应（先保证子组件最小可用宽度再定列数），1~100 = 列数上限
//  · rowsPerPage       每页行数 1~5（开启分页时生效）
//  · paging            横向分页：每页容量 = 列数 × 每页行数，最多 10 页（与内容类型无关）
//  · entries / hotEntries / badgeText   快捷入口项 / 加角标的入口 / 角标文字
//  · indices           指数卡片类型展示哪些指数（个数不限，缺省 = 前 4 只）
//  · items             自定义条目，每行「标题|副标题|角标」
//
//  尺寸规范（2026-11-23）：
//  · 容器统一：圆角 20 / 内边距 15 / 网格横向 10、纵向 16 / 分页点 5pt；
//  · 子组件按类型独立：快捷入口最小宽 72、单元高 68（图标 44 / 图标实际 28 / 标题 13，
//    角标为浮层不占位）；指数卡片最小宽 150、单行 156；自定义条目最小宽 130、单行 56；
//  · **先保证子组件最小可用尺寸，再决定每行几列**：容器实测内容区宽度后按最小宽算列数，
//    绝不为了填满宽度把子组件压小；配置的列数只作上限。
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

// MARK: - 尺寸规范（容器统一 / 子组件按类型独立）

private enum DashboardMetrics {
    /// 外层容器：圆角 20 / 内边距 15
    static let cardRadius: CGFloat = 20
    static let cardPadding: CGFloat = 15
    static let headerSpacing: CGFloat = 12

    /// 网格间距
    static let hSpacing: CGFloat = 10
    static let vSpacing: CGFloat = 16

    /// 快捷入口：图标 44、图标实际 28、标题 13、最小可用宽 72；
    /// 单元高 = 图标 44 + 间距 7 + 标题行高约 17 = 68（角标为浮层，不额外预留高度）
    static let shortcutMinWidth: CGFloat = 72
    static let shortcutHeight: CGFloat = 68
    static let shortcutIconTile: CGFloat = 44
    static let shortcutIconSize: CGFloat = 28

    /// 指数卡片：最小可用宽 150、单行高 156（紧凑卡约 153）、行间距 12
    static let indexMinWidth: CGFloat = 150
    static let indexRowHeight: CGFloat = 156
    static let indexVSpacing: CGFloat = 12

    /// 自定义条目：最小可用宽 130、单行高 56、行间距 10
    static let customMinWidth: CGFloat = 130
    static let customRowHeight: CGFloat = 56
    static let customVSpacing: CGFloat = 10

    /// 可用宽度 → 能放下的列数：**先保证子组件最小可用尺寸，再决定每行放几列**
    static func fitColumns(minItemWidth: CGFloat, availableWidth: CGFloat) -> Int {
        guard availableWidth > 0, minItemWidth > 0 else { return 0 }
        let count = Int((availableWidth + hSpacing) / (minItemWidth + hSpacing))
        return max(1, count)
    }

    /// 生效列数：configured = 0 → 全自适应；>0 → 作为上限，且仍不压破最小宽度
    static func effectiveColumns(configured: Int,
                                 minItemWidth: CGFloat,
                                 availableWidth: CGFloat) -> Int {
        let fit = fitColumns(minItemWidth: minItemWidth, availableWidth: availableWidth)
        if configured <= 0 { return fit > 0 ? fit : 1 }
        guard fit > 0 else { return max(configured, 1) }
        return max(1, min(configured, fit))
    }
}

// MARK: - 内容区实测宽度（由容器注入给子网格）

private struct DashboardContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// 功能卡片组内容区实测可用宽度（pt）；0 = 尚未测量
    fileprivate var dashboardContentWidth: CGFloat {
        get { self[DashboardContentWidthKey.self] }
        set { self[DashboardContentWidthKey.self] = newValue }
    }
}

private struct DashboardWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 统一容器

/// 功能卡片组容器：标题 + 副标题 + 任意内容，统一底色 / 圆角 / 内边距 / 描边。
/// 容器负责测量自身内容区宽度并注入环境，子网格据此按「最小可用尺寸」计算列数。
struct DashboardCardGroup<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var colorScheme
    @State private var measuredWidth: CGFloat = 0

    private var palette: DashboardGroupPalette { .resolve(colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardMetrics.headerSpacing) {
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
        .padding(DashboardMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous)
                .fill(palette.groupFill)
                .overlay(
                    RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous)
                        .stroke(palette.border, lineWidth: 0.5)
                )
        )
        // 实测「内边距之后」的内容区宽度：背景测量的是含内边距的外框，故减两倍内边距
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: DashboardWidthPreferenceKey.self,
                    value: max(geo.size.width - DashboardMetrics.cardPadding * 2, 0)
                )
            }
        )
        .onPreferenceChange(DashboardWidthPreferenceKey.self) { measuredWidth = $0 }
        .environment(\.dashboardContentWidth, measuredWidth)
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
    /// 配置列数：0 = 自适应；>0 = 列数上限（仍不压破最小可用宽度）
    let configuredColumns: Int
    let rowsPerPage: Int
    let paging: Bool
    let onTap: (HomeEntryKind) -> Void

    @Environment(\.dashboardContentWidth) private var contentWidth

    /// 生效列数：先保证 72pt 最小可用宽度，再决定列数
    private var columns: Int {
        DashboardMetrics.effectiveColumns(configured: configuredColumns,
                                          minItemWidth: DashboardMetrics.shortcutMinWidth,
                                          availableWidth: contentWidth)
    }

    var body: some View {
        if entries.isEmpty {
            DashboardEmptyHint(text: "未选择快捷入口")
        } else if paging {
            let rows = max(rowsPerPage, 1)
            let perPage = columns * rows
            let pages = Array(chunked(entries, size: perPage).prefix(DashboardPaging.maxPages))
            DashboardPager(pageCount: pages.count,
                           pageHeight: CGFloat(rows) * DashboardMetrics.shortcutHeight
                                      + CGFloat(rows - 1) * DashboardMetrics.vSpacing) { index in
                grid(pages[index])
            }
        } else {
            grid(entries)
        }
    }

    private func grid(_ items: [HomeEntryKind]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                     spacing: DashboardMetrics.hSpacing),
                                 count: columns),
                  spacing: DashboardMetrics.vSpacing) {
            ForEach(items) { kind in
                DashboardShortcutCell(kind: kind,
                                      badge: hotEntries.contains(kind) ? badgeText : nil,
                                      action: { onTap(kind) })
            }
        }
    }
}

/// 单个快捷入口：图标（入口色）+ 名称 + 可选角标；**不加独立卡片背景**，保持整体宫格观感
private struct DashboardShortcutCell: View {
    let kind: HomeEntryKind
    let badge: String?
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var palette: DashboardGroupPalette { .resolve(colorScheme) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(kind.tint.opacity(palette.isDark ? 0.18 : 0.12))
                    .frame(width: DashboardMetrics.shortcutIconTile,
                           height: DashboardMetrics.shortcutIconTile)
                    .overlay(
                        Image(systemName: kind.icon)
                            .font(.system(size: DashboardMetrics.shortcutIconSize,
                                          weight: .medium))
                            .foregroundColor(kind.tint)
                    )
                    // 角标纯浮层：不参与布局尺寸，无角标时零占位
                    .overlay(alignment: .topTrailing) {
                        if let badge, !badge.isEmpty {
                            Text(badge)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(palette.badgeFill)
                                .clipShape(Capsule())
                                .offset(x: 8, y: -5)
                        }
                    }

                Text(kind.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(palette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(height: DashboardMetrics.shortcutHeight)
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
    /// 配置列数：0 = 自适应；>0 = 列数上限（仍不压破最小可用宽度）
    let configuredColumns: Int
    let rowsPerPage: Int
    let paging: Bool
    let onOpen: (MetaItem, [MetaItem]) -> Void

    /// 行缓存：字段 / 走势陆续到位时本块自行刷新
    @ObservedObject private var rowCache = MarketRowCache.shared
    @ObservedObject private var db = DatabaseManager.shared

    @Environment(\.dashboardContentWidth) private var contentWidth

    /// 生效列数：先保证 150pt 最小可用宽度，再决定列数
    private var columns: Int {
        DashboardMetrics.effectiveColumns(configured: configuredColumns,
                                          minItemWidth: DashboardMetrics.indexMinWidth,
                                          availableWidth: contentWidth)
    }

    private var quotes: [MarketIndexQuote] { rows.map { MarketIndexQuote(row: $0) } }

    var body: some View {
        if rows.isEmpty {
            DashboardEmptyHint(text: db.isLoaded ? "暂无指数数据" : "指数加载中")
        } else if paging {
            let rowsPer = max(rowsPerPage, 1)
            let perPage = columns * rowsPer
            let pages = Array(chunked(quotes, size: perPage).prefix(DashboardPaging.maxPages))
            let pageHeight = CGFloat(rowsPer) * DashboardMetrics.indexRowHeight
                              + CGFloat(rowsPer - 1) * DashboardMetrics.indexVSpacing
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
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                           spacing: DashboardMetrics.hSpacing),
                                       count: columns),
                         spacing: DashboardMetrics.indexVSpacing) {
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
    /// 配置列数：0 = 自适应；>0 = 列数上限（仍不压破最小可用宽度）
    let configuredColumns: Int
    let rowsPerPage: Int
    let paging: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dashboardContentWidth) private var contentWidth

    private var palette: DashboardGroupPalette { .resolve(colorScheme) }

    /// 生效列数：先保证 130pt 最小可用宽度，再决定列数
    private var columns: Int {
        DashboardMetrics.effectiveColumns(configured: configuredColumns,
                                          minItemWidth: DashboardMetrics.customMinWidth,
                                          availableWidth: contentWidth)
    }

    var body: some View {
        if items.isEmpty {
            DashboardEmptyHint(text: "未配置条目：在检查器里填写「自定义条目」（每行：标题|副标题|角标）")
        } else if paging {
            let rows = max(rowsPerPage, 1)
            let perPage = columns * rows
            let pages = Array(chunked(items, size: perPage).prefix(DashboardPaging.maxPages))
            DashboardPager(pageCount: pages.count,
                           pageHeight: CGFloat(rows) * DashboardMetrics.customRowHeight
                                      + CGFloat(rows - 1) * DashboardMetrics.customVSpacing) { index in
                grid(pages[index])
            }
        } else {
            grid(items)
        }
    }

    private func grid(_ items: [DashboardCustomItem]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                     spacing: DashboardMetrics.hSpacing),
                                 count: columns),
                  spacing: DashboardMetrics.customVSpacing) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(palette.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 4)
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
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(palette.secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: DashboardMetrics.customRowHeight, alignment: .leading)
                .contentShape(Rectangle())
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
    /// 每行列数：0 = 自适应（按子组件最小可用宽度算），1~100 = 列数上限
    var columns: Int = 0
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

    /// 配置列数（0 保留 = 自适应；上限 100）
    private var safeColumns: Int {
        min(max(columns, 0), DashboardPaging.maxColumns)
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
                                      configuredColumns: safeColumns,
                                      rowsPerPage: safeRowsPerPage,
                                      paging: paging,
                                      onTap: onEntry)
            case .indices:
                DashboardIndexGrid(rows: indexRows,
                                   configuredColumns: safeColumns,
                                   rowsPerPage: safeRowsPerPage,
                                   paging: paging,
                                   onOpen: onOpenIndex)
            case .custom:
                DashboardCustomList(items: customItems,
                                    configuredColumns: safeColumns,
                                    rowsPerPage: safeRowsPerPage,
                                    paging: paging)
            }
        }
    }
}

//
//  MarketLayoutCView.swift
//  Kline
//
//  行情页 C 档布局（磁贴卡片网格）：
//  顶部一级菜单 + 二级胶囊（右侧「磁贴 / 表格」分段切换），下面是自适应列数的磁贴网格；
//  切到「表格」态即复用共享表格主体（能力与 A 档一致）。
//

import SwiftUI

struct MarketLayoutCView: View {
    @ObservedObject var model: MarketPageModel
    /// 数据库加载态（与 A 档一致）
    @ObservedObject private var databaseManager = DatabaseManager.shared

    var body: some View {
        VStack(spacing: 0) {
            MarketHeaderBar(model: model)
            Divider()
            // 二级胶囊行：一级菜单展开时胶囊由 MarketHeaderBar 呈现，此处仅保留「磁贴 / 表格」切换，避免重复一行
            HStack(spacing: 8) {
                if model.secondLevelVisible {
                    Spacer(minLength: 0)
                } else {
                    MarketSecondLevelBar(model: model)
                }
                MarketTileModeSwitch(model: model)
                    .padding(.trailing, 12)
            }
            .frame(height: 44)
            // 胶囊可见时灰底由 MarketSecondLevelBar 自带（避免半透明灰叠出深色带）；胶囊移到 header 后本行补同款灰底
            .background(model.secondLevelVisible ? Color(.systemGray6).opacity(0.4) : Color.clear)

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if databaseManager.isLoaded {
            if model.tabItems.isEmpty {
                MarketEmptyStateView(icon: "magnifyingglass", message: "暂无标的")
            } else if model.showsTileMode {
                tileGrid
            } else {
                MarketTableBody(model: model)
            }
        } else {
            VStack(spacing: 16) {
                ProgressView()
                Text("加载中...").foregroundColor(.gray)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// 磁贴网格：列数按可用宽度自适应（≥960 三列 / ≥640 两列 / 否则一列），间距与水平内边距 12
    private var tileGrid: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVGrid(columns: Self.gridColumns(for: geo.size.width), spacing: 12) {
                    ForEach(model.displayRows) { row in
                        MarketTileCard(model: model, row: row)
                    }
                }
                .padding(12)
            }
            .refreshable {
                model.rowCache.refresh(metas: model.tabItems)
                model.scheduleRefresh()
            }
        }
    }

    private static func gridColumns(for width: CGFloat) -> [GridItem] {
        let count: Int
        if width >= 960 {
            count = 3
        } else if width >= 640 {
            count = 2
        } else {
            count = 1
        }
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }
}

// MARK: - 磁贴卡

/// 磁贴卡（高 108pt）：名称 + 代码 / 大字现价 / 涨跌幅胶囊 + 涨跌额 / 迷你走势 / 右上角自选星标。
/// 点击打开 K 线详情（按当前分类列表上下文），长按打开与表格同一套操作面板（容器层 overlay）。
struct MarketTileCard: View {
    @ObservedObject var model: MarketPageModel
    let row: MarketRow
    /// 直接观察行缓存：bars 陆续到位时本卡自行刷新（与 MarketTableRow 同机制），避免一直显示 "-"
    @ObservedObject private var rowCache = MarketRowCache.shared

    private var meta: MetaItem { row.meta }
    private var isFaved: Bool { model.fav.isFavorited(row.meta.id) }

    /// 涨跌方向着色（无有效涨跌幅时用主色）
    private var tint: Color {
        guard let pct = row.number(.changePct) else { return .primary }
        if pct > 0 { return .red }
        if pct < 0 { return .green }
        return .primary
    }

    /// 涨跌幅胶囊底色（平盘 / 无值时用系统灰，避免暗示方向）
    private var pillColor: Color {
        guard let pct = row.number(.changePct) else { return Color(.systemGray) }
        if pct > 0 { return .red }
        if pct < 0 { return .green }
        return Color(.systemGray)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(meta.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isFaved ? .red : .primary)
                        .lineLimit(1)
                    Text(meta.displayCode)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(row.text(.latestPrice))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(tint)
                    .lineLimit(1)
                    .padding(.top, 6)
                HStack(spacing: 8) {
                    Text(row.text(.changePct))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(pillColor)
                        .cornerRadius(6)
                    Text(row.text(.change))
                        .font(.system(size: 11.5))
                        .foregroundColor(tint)
                        .lineLimit(1)
                }
                .padding(.top, 6)
                Spacer(minLength: 0)
            }
            VStack(alignment: .trailing, spacing: 0) {
                // 自选星标：44×44 命中区，已自选为橙色实心星
                Button {
                    model.fav.toggleFavorite(meta.id)
                } label: {
                    Image(systemName: isFaved ? "star.fill" : "star")
                        .font(.system(size: 15))
                        .foregroundColor(isFaved ? .orange : Color.secondary.opacity(0.6))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                MarketSparkline(closes: row.recentCloses, up: (row.number(.changePct) ?? 0) >= 0)
                    .frame(width: 120, height: 28)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: 108)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .contentShape(Rectangle())
        .accessibilityIdentifier("market.rowCard")
        .onTapGesture {
            DetailRouter.shared.open(meta, in: model.displayRows.map { $0.meta })
        }
        // 长按出与表格同一套操作面板（挂在容器层 overlay，磁贴自身零样式改动）；
        // 不用 .contextMenu：它会把磁贴抬升快照 / 换宿主，卡片高与内部布局会被重排
        .onLongPressGesture(minimumDuration: 0.5) {
            withAnimation(.easeOut(duration: 0.15)) {
                model.openRowMenu(model.menuTarget(for: meta))
            }
        }
    }
}

// MARK: - 迷你走势折线

/// 迷你走势：近 N 日（最多 20 根）收盘价折线，涨红跌绿；数据不足 2 个点时留白
struct MarketSparkline: View {
    let closes: [Double]
    let up: Bool

    var body: some View {
        GeometryReader { geo in
            let pts = Array(closes.suffix(20))
            if pts.count >= 2 {
                let mn = pts.min() ?? 0
                let mx = pts.max() ?? 0
                let span = (mx - mn) > 0 ? (mx - mn) : 1
                let w = geo.size.width
                let h = geo.size.height
                Path { path in
                    for (i, v) in pts.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(pts.count - 1)
                        let y = h - 3 - CGFloat((v - mn) / span) * (h - 8)
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(up ? Color.red : Color.green, lineWidth: 1.5)
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - 「磁贴 / 表格」分段切换

/// 磁贴 / 表格分段切换（C 档）：与自选页 C 档同一套样式（当前态蓝底白字，命中区 44pt）
private struct MarketTileModeSwitch: View {
    @ObservedObject var model: MarketPageModel

    var body: some View {
        HStack(spacing: 2) {
            segment("磁贴", active: model.showsTileMode) { model.toggleTileMode(true) }
            segment("表格", active: !model.showsTileMode) { model.toggleTileMode(false) }
        }
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    /// 分段按钮：视觉 36pt，纵向补 4pt → 命中区 44pt
    private func segment(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(active ? .white : .secondary)
                .frame(width: 54, height: 36)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Color.blue : Color.clear))
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MarketLayoutCView(model: MarketPageModel())
}
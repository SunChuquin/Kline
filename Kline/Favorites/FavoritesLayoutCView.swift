//
//  FavoritesLayoutCView.swift
//  Kline
//
//  自选页 C 档布局：自选卡片流（卡片 / 表格双形态）。
//  顶部 = 页标题 + 「卡片 / 表格」分段切换 + 图标按钮组；其下为共享分组 Tab 条。
//  卡片形态：每卡一只（名称/代码 + 近 20 日迷你走势 + 今开/最高/最低/成交额 + 现价/涨跌幅胶囊 + 更多菜单），
//  整卡点击进详情、长按（或点右上「更多」）打开与 A 档同一套操作面板（FavoritesRowMenu.swift）；
//  表格形态直接复用 FavoritesTableBody（能力与 A 档一致）。
//

import SwiftUI

struct FavoritesLayoutCView: View {
    @ObservedObject var model: FavoritesPageModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            FavoritesGroupTabs(model: model)
            Divider()
            content
        }
    }

    // MARK: - 顶部工具条

    private var topBar: some View {
        HStack(spacing: 4) {
            Text("自选")
                .font(.system(size: 18, weight: .bold))
                .accessibilityIdentifier("favorites.title")
                .padding(.leading, 16)
            Spacer(minLength: 8)
            modeSwitch
            // 编辑态开关：与 A/B/D 档同一按钮（文案「编辑」→「完成」，退出时清空多选）
            FavoritesEditToggleButton(model: model)
            iconButton("slider.horizontal.3") { model.showColumnPanel = true }
            iconButton("plus", color: .blue) { model.showAddSheet = true }
                .padding(.trailing, 4)
        }
        .frame(height: 48)
        .background(Color(.systemBackground))
    }

    /// 「卡片 / 表格」分段切换（当前态蓝底白字）
    private var modeSwitch: some View {
        HStack(spacing: 2) {
            segmentButton("卡片", active: model.showsCardMode) {
                setCardMode(true)
            }
            segmentButton("表格", active: !model.showsCardMode) {
                setCardMode(false)
            }
        }
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    /// 分段按钮：视觉 36pt，纵向补 4pt → 命中区 44pt
    private func segmentButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
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

    private func setCardMode(_ on: Bool) {
        if model.showsCardMode != on { model.showsCardMode = on }
    }

    /// 顶部图标按钮：统一 44x44 命中区
    private func iconButton(_ systemName: String, color: Color = .secondary,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16))
                .foregroundColor(color)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 内容区（卡片流 / 表格 / 编辑态）

    @ViewBuilder
    private var content: some View {
        if !model.dbm.isLoaded {
            loadingView
        } else if model.currentItems.isEmpty {
            MarketEmptyStateView(icon: "star.slash",
                                 message: model.currentGroup.name == "全部"
                                        ? "还没有自选股" : "此分组暂无股票",
                                 subtitle: "在行情页面长按股票行即可加自选，或点击右上角 + 新建分组")
        } else if model.showsCardMode {
            if model.showEditingMode {
                // 编辑态：三类分组都进同一套多选列表（其下方自带批量条；不提供拖拽排序则仅手动组有手柄）
                FavoritesManualEditingList(model: model)
            } else {
                cardList
            }
        } else {
            // 表格形态：能力与 A 档一致（含编辑态 / 横向滚动 / 吸顶表头）
            FavoritesTableBody(model: model)
        }
    }

    private var cardList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.sortedRows) { row in
                    stockCard(row)
                    Divider().padding(.leading, 16)
                }
            }
        }
        .refreshable {
            model.refreshCurrentGroup()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("自选页面准备中...").foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 卡片

    private func stockCard(_ row: MarketRow) -> some View {
        let meta = row.meta
        // 点击上下文取当前分组标的快照（与 A 档一致）
        let items = model.currentItems
        let pctValue = row.number(.changePct)
        return HStack(spacing: 12) {
            nameBlock(meta)
            trendBlock(row)
            statBlock(meta)
            priceBlock(meta, pct: pctValue)
            moreButton(meta)
        }
        .padding(.horizontal, 16)
        .frame(height: 72)
        .contentShape(Rectangle())
        .onTapGesture {
            model.detailRouter.open(meta, in: items)
        }
        // 长按出与 A 档同一套操作面板（挂在容器层 overlay，卡片自身零样式改动）；
        // 不用 .contextMenu：它会抬升快照 / 换宿主，卡片高与内部布局会被重排
        .onLongPressGesture(minimumDuration: 0.5) {
            withAnimation(.easeOut(duration: 0.15)) {
                model.openRowMenu(model.menuTarget(for: meta))
            }
        }
    }

    /// 左：名称（14 粗）+ 代码（10.5 灰）双行
    private func nameBlock(_ meta: MetaItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meta.name)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(1)
            Text(meta.displayCode)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(width: 104, alignment: .leading)
    }

    /// 中左：近 20 日迷你走势（无数据时该区域留空不画）
    private func trendBlock(_ row: MarketRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("近 20 日")
                .font(.system(size: 9.5))
                .foregroundColor(Color(.tertiaryLabel))
            FavoritesMiniTrend(closes: Array(row.recentCloses.suffix(20)))
                .frame(width: 120, height: 32)
        }
        .frame(width: 120, alignment: .leading)
    }

    /// 中右：今开 / 最高 / 最低 / 成交额（等分弹性宽，窄屏自动压缩不溢出）
    private func statBlock(_ meta: MetaItem) -> some View {
        HStack(spacing: 10) {
            miniStat(meta, field: .open)
            miniStat(meta, field: .high)
            miniStat(meta, field: .low)
            miniStat(meta, field: .turnover)
        }
        .frame(maxWidth: .infinity)
    }

    private func miniStat(_ meta: MetaItem, field: MarketField) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.title)
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
            Text(model.rowCache.textFor(meta.id, field))
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundColor(model.rowCache.colorFor(meta.id, field))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 右：现价（16 粗）+ 涨跌幅胶囊（红/绿底白字）
    private func priceBlock(_ meta: MetaItem, pct: Double?) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(model.rowCache.textFor(meta.id, .latestPrice))
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(model.rowCache.colorFor(meta.id, .latestPrice))
                .lineLimit(1)
            Text(model.rowCache.textFor(meta.id, .changePct))
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 76, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Self.pctColor(pct)))
                .lineLimit(1)
        }
        .frame(width: 88, alignment: .trailing)
    }

    /// 涨跌幅胶囊底色：涨红 / 跌绿 / 平或无效用灰
    private static func pctColor(_ pct: Double?) -> Color {
        guard let p = pct else { return Color(.systemGray) }
        if p > 0 { return Color(.systemRed) }
        if p < 0 { return Color(.systemGreen) }
        return Color(.systemGray)
    }

    /// 最右：44x44「更多」按钮，点击打开与长按**同一**面板（同一份 items / 同一套动作）
    private func moreButton(_ meta: MetaItem) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                model.openRowMenu(model.menuTarget(for: meta))
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 迷你走势（Path 手绘，近 20 日收盘价）

/// 卡片迷你走势：近 N 日收盘价折线，按区间涨跌着色（涨红 / 跌绿 / 平灰）；
/// 数据不足 2 个点时整块留空（不画）。
struct FavoritesMiniTrend: View {
    let closes: [Double]

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            if pts.count >= 2 {
                Path { path in
                    path.move(to: pts[0])
                    for pt in pts.dropFirst() { path.addLine(to: pt) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// 区间涨跌配色：末值 > 首值红、< 首值绿、相等灰
    private var tint: Color {
        guard let first = closes.first, let last = closes.last else { return Color(.systemGray) }
        if last > first { return Color(.systemRed) }
        if last < first { return Color(.systemGreen) }
        return Color(.systemGray)
    }

    /// 把收盘价序列归一化到视图尺寸（上下各留 2pt 内边距，避免线贴边被裁）
    private func points(in size: CGSize) -> [CGPoint] {
        guard closes.count >= 2 else { return [] }
        let minValue = closes.min() ?? 0
        let maxValue = closes.max() ?? 0
        let span = maxValue - minValue
        let width = max(size.width, 1)
        let height = max(size.height - 4, 1)
        let stepX = width / CGFloat(closes.count - 1)
        return closes.enumerated().map { index, value in
            let ratio = span > 0 ? (value - minValue) / span : 0.5
            let y = 2 + height - CGFloat(ratio) * height
            return CGPoint(x: CGFloat(index) * stepX, y: y)
        }
    }
}

#Preview {
    FavoritesLayoutCView(model: FavoritesPageModel())
}
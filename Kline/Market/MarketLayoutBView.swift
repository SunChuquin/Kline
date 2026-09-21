//
//  MarketLayoutBView.swift
//  Kline
//
//  行情页 B 档布局（分类侧栏 + 表格）：
//  左侧 200pt 常驻分类侧栏（一级分区标题 + 二级条目 + 数量角标），
//  右侧工作区（当前分类名 + 数量 + 工具条 + 共享表格主体）。
//  分类状态与 A 档共用（topMenu / selectedTab / pickerSeg / favSeg），切换布局不丢分类。
//

import SwiftUI

struct MarketLayoutBView: View {
    @ObservedObject var model: MarketPageModel
    /// 数据库加载态（与 A 档一致：未加载完显示「加载中」，加载完按有无标的显示空态或表格）
    @ObservedObject private var databaseManager = DatabaseManager.shared

    var body: some View {
        HStack(spacing: 0) {
            MarketCategorySidebar(model: model)
                .frame(width: 200)
            Divider()
            VStack(spacing: 0) {
                MarketWorkspaceBar(model: model)
                Divider()
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        if databaseManager.isLoaded {
            if model.tabItems.isEmpty {
                MarketEmptyStateView(icon: "magnifyingglass", message: "暂无标的")
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
}

// MARK: - 左侧分类侧栏

/// 分类侧栏：按一级分区（市场 / 选股 / 自选）列出全部二级条目，
/// 条目不折叠、点击即切（一级分区标题行复用无障碍标识 `market.topMenu.<一级名>`）。
private struct MarketCategorySidebar: View {
    @ObservedObject var model: MarketPageModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(TopField.allCases) { field in
                    sectionHeader(field)
                    ForEach(model.topMenuItems(for: field)) { item in
                        itemRow(item)
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .background(Color(.secondarySystemBackground))
    }

    /// 一级分区标题行：小字灰色，非「条目」语义；保留 `market.topMenu.<一级名>` 标识，
    /// 点击等同切换一级分类（既有 UITest 仍可定位到「市场」）。
    private func sectionHeader(_ field: TopField) -> some View {
        Button {
            model.tapTopMenu(field)
        } label: {
            HStack(spacing: 0) {
                Text(field.rawValue)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("market.topMenu.\(field.rawValue)")
    }

    /// 二级条目行：图标 + 名称 + 数量角标（无数据源显示「-」），选中项蓝底高亮
    private func itemRow(_ item: MarketTopMenuItem) -> some View {
        let selected = isSelected(item)
        return Button {
            model.setSidebarSelection(item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: item))
                    .font(.system(size: 14))
                    .foregroundColor(selected ? .blue : .secondary)
                    .frame(width: 24)
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(selected ? .blue : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(item.badge ?? "-")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(selected ? Color.blue.opacity(0.12) : Color.clear)
            .cornerRadius(9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    /// 选中判定：一级 + 对应的二级状态都命中
    private func isSelected(_ item: MarketTopMenuItem) -> Bool {
        guard model.topMenu == item.field else { return false }
        switch item.field {
        case .market: return model.selectedTab.rawValue == item.key
        case .picker: return model.pickerSeg.rawValue == item.key
        case .fav: return model.favSeg.rawValue == item.key
        }
    }

    /// 条目图标（按二级分类区分）
    private func icon(for item: MarketTopMenuItem) -> String {
        switch item.field {
        case .market:
            return item.key == MarketTab.mainBoard.rawValue ? "chart.bar.xaxis" : "chart.line.uptrend.xyaxis"
        case .picker:
            if item.key == PickerField.trend.rawValue { return "arrow.up.right" }
            if item.key == PickerField.oscillation.rawValue { return "waveform" }
            if item.key == PickerField.reversal.rawValue { return "arrow.uturn.backward" }
            return "flame"
        case .fav:
            return item.key == FavField.holdings.rawValue ? "briefcase" : "square.stack.3d.up"
        }
    }
}

// MARK: - 右侧工作区工具条

/// 工作区工具条：当前二级分类名 + 数量（当前展示行数）+ 表头设置 / 边线调整 / 搜索（选股额外给公式）
private struct MarketWorkspaceBar: View {
    @ObservedObject var model: MarketPageModel

    var body: some View {
        HStack(spacing: 8) {
            Text(model.currentCategoryTitle)
                .font(.system(size: 16, weight: .bold))
                .lineLimit(1)
            Text("\(model.displayRows.count) 只")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            MarketToolBar(model: model)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(.systemBackground))
    }
}

#Preview {
    MarketLayoutBView(model: MarketPageModel())
}
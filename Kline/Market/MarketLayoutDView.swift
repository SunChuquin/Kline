//
//  MarketLayoutDView.swift
//  Kline
//
//  行情页 D 档布局（概览 + 紧凑表格）：
//  一级菜单 → 市场宽度概览带（涨 / 跌 / 平家数、涨停 / 跌停、总成交额）→ 二级胶囊 → 工具条
//  → 行高 32 / 34、字号 15 的紧凑表格。
//  概览统计由 MarketPageModel.scheduleRefresh() 一次性算好（body 内不遍历全表）。
//

import SwiftUI
import Combine

struct MarketLayoutDView: View {
    @ObservedObject var model: MarketPageModel
    /// 数据库加载态（与 A 档一致）
    @ObservedObject private var databaseManager = DatabaseManager.shared

    /// 紧凑表格参数（配合 MarketTableRow 的 heightOverride / fontSizeOverride 透传）
    private static let compactMetrics = MarketRowMetrics(headerHeight: 32, rowHeight: 34, fontSize: 15)

    var body: some View {
        VStack(spacing: 0) {
            MarketHeaderBar(model: model)
            MarketOverviewBar(overview: model.overview)
            Divider()
            // 二级胶囊：一级菜单展开时胶囊由 MarketHeaderBar 呈现，此处仅保留工具条，避免重复一行
            if !model.secondLevelVisible {
                MarketSecondLevelBar(model: model)
            }
            HStack(spacing: 8) {
                MarketToolBar(model: model)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color(.systemBackground))
            Divider()

            content
        }
        // bars 陆续到位 → 防抖重算概览（统计仍由 model 计算，body 内不遍历全表）
        .onReceive(model.rowCache.objectWillChange) { _ in
            model.scheduleOverviewRefresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        if databaseManager.isLoaded {
            if model.tabItems.isEmpty {
                MarketEmptyStateView(icon: "magnifyingglass", message: "暂无标的")
            } else {
                MarketTableBody(model: model, metrics: Self.compactMetrics)
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

// MARK: - 市场宽度概览带

/// 概览带：涨 / 跌 / 平家数、涨停 / 跌停、总成交额（涨红跌绿，指标块间竖线分隔）。
/// 数据来自 `model.overview`（快照阶段算好），`overview` 为 nil 时显示「-」。
struct MarketOverviewBar: View {
    let overview: MarketOverview?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                HStack(spacing: 28) {
                    metric("上涨", countText(overview?.up), .red)
                    metric("下跌", countText(overview?.down), .green)
                    metric("平盘", countText(overview?.flat), .primary)
                }
                separator
                HStack(spacing: 28) {
                    metric("涨停", countText(overview?.limitUp), .red)
                    metric("跌停", countText(overview?.limitDown), .green)
                }
                separator
                metric("总成交额", turnoverText, .primary)
            }
            .padding(.horizontal, 12)
            // 横向可滚（窄屏不截断指标），纵向固定 56 保证指标块垂直居中
            .frame(height: 56)
        }
        .frame(height: 56)
        .background(Color(.systemBackground))
    }

    /// 单个指标块：小字灰色标签 + 大字数值
    private func metric(_ key: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .fixedSize()
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: 1, height: 30)
            .padding(.horizontal, 20)
    }

    private func countText(_ v: Int?) -> String {
        guard let v = v else { return "-" }
        return "\(v)"
    }

    /// 总成交额展示：复用表格同一套格式化（元 → 亿 / 万）
    private var turnoverText: String {
        guard let t = overview?.totalTurnover, t > 0 else { return "—" }
        return MarketRow.formatTurnover(t)
    }
}

#Preview {
    MarketLayoutDView(model: MarketPageModel())
}
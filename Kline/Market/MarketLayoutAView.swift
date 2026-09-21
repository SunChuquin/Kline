//
//  MarketLayoutAView.swift
//  Kline
//
//  行情页 A 档布局（经典表格式）：改造前 MarketView 的等价搬运，
//  状态与数据全部来自共享的 MarketPageModel。
//

import SwiftUI

struct MarketLayoutAView: View {
    @ObservedObject var model: MarketPageModel
    /// 数据库加载态（与改造前一致：未加载完显示「加载中」，加载完按有无标的显示空态或表格）
    @ObservedObject private var databaseManager = DatabaseManager.shared

    var body: some View {
        VStack(spacing: 0) {
            MarketHeaderBar(model: model)
            Divider()
            if databaseManager.isLoaded {
                if model.tabItems.isEmpty {
                    MarketEmptyStateView(icon: "magnifyingglass", message: "暂无标的")
                } else {
                    // 表头（吸顶，冻结前 N 列）+ 列表（横向手势滚动 / 边线调节覆盖层）
                    MarketTableBody(model: model)
                }
            } else {
                loadingView
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("加载中...")
                .foregroundColor(.gray)
        }
        .frame(maxHeight: .infinity)
    }
}

#Preview {
    MarketLayoutAView(model: MarketPageModel())
}

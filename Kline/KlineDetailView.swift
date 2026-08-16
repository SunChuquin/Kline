//
//  KlineDetailView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/8/5.
//

import SwiftUI
import Combine
import UIKit

/// 全局详情页路由：在根视图以全屏 overlay 呈现 K 线详情，避免 fullScreenCover 偶发白屏
final class DetailRouter: ObservableObject {
    static let shared = DetailRouter()
    @Published var item: MetaItem? = nil
}

struct KlineDetailView: View {
    @ObservedObject private var databaseManager = DatabaseManager.shared

    let item: MetaItem
    var onClose: () -> Void
    @State private var selectedPeriod: KlinePeriod = .daily
    @State private var chartStyle: ChartStyle = .kline
    @State private var showSettings = false
    @State private var dailyData: [KlineItem] = []
    @State private var weeklyData: [KlineItem] = []
    @State private var isLoading = true

    private var currentData: [KlineItem] { selectedPeriod == .daily ? dailyData : weeklyData }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // 顶部安全区留白，保证返回按钮始终在可视区域
                Color.clear
                    .frame(height: geometry.safeAreaInsets.top)

                headerView
                periodSelector

                // 图表区域：始终占满剩余空间，内部显示加载/空/图表
                chartArea
            }
            .frame(maxHeight: .infinity)
            .background(Color.white.ignoresSafeArea())
            .overlay {
                if showSettings {
                    settingsOverlay(geometry: geometry)
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
        }
        .onAppear {
            if databaseManager.isLoaded {
                loadData()
            } else {
                // 数据库还没就绪，等就绪后再查
                isLoading = true
            }
        }
        .onChange(of: databaseManager.isLoaded) { loaded in
            if loaded && isLoading {
                loadData()
            }
        }
    }

    private var chartArea: some View {
        ZStack {
            Color.white

            Group {
                if isLoading {
                    loadingView
                } else if currentData.isEmpty {
                    emptyDataView
                } else {
                    chartView(data: currentData)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .gray))
            Text("正在加载行情数据...")
                .font(.system(size: 13))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    private var headerView: some View {
        HStack {
            Button(action: {
                onClose()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(8)
            }
            .padding(.leading, 16)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.black)
                    Text(item.displayCode)
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                Text(item.type)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .background(Color.white)
    }

    private var periodSelector: some View {
        HStack(spacing: 0) {
            ForEach(KlinePeriod.allCases) { period in
                Button(action: {
                    withAnimation {
                        selectedPeriod = period
                    }
                }) {
                    Text(period.rawValue)
                        .font(.system(size: 13))
                        .foregroundColor(selectedPeriod == period ? .black : .gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selectedPeriod == period ? Color.gray.opacity(0.15) : Color.clear)
                }
            }

            // 设置按钮：打开 K 线类型配置面板
            Button {
                withAnimation { showSettings = true }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundColor(.gray)
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .background(Color.white)
        .overlay(
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    /// 设置面板：底部 3/4 高度，点击顶部 1/4 区域关闭
    private func settingsOverlay(geometry: GeometryProxy) -> some View {
        ZStack(alignment: .bottom) {
            // 顶部非面板区域，点击关闭
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation { showSettings = false }
                }

            // 底部设置面板
            VStack(spacing: 0) {
                HStack {
                    Text("K线类型")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.black)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                VStack(spacing: 0) {
                    ForEach(ChartStyle.allCases) { style in
                        Button {
                            withAnimation { chartStyle = style }
                        } label: {
                            HStack {
                                Text(style.rawValue)
                                    .font(.system(size: 15))
                                    .foregroundColor(.black)
                                Spacer()
                                if chartStyle == style {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        Divider()
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: geometry.size.height * 0.75)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chartView(data: [KlineItem]) -> some View {
        KlineChartView(data: data, chartStyle: $chartStyle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDataView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundColor(.gray)

            Text("暂无K线数据")
                .foregroundColor(.gray)

            Text("\(item.name) (\(item.code))")
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
        .frame(maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .background(Color.white)
    }

    private func loadData() {
        // 数据库未就绪时先不查询，等待 isLoaded 触发
        guard databaseManager.isLoaded else {
            isLoading = true
            return
        }
        isLoading = true

        // 在后台串行加载（避免多个线程同时访问同一个 SQLite 连接）
        DispatchQueue.global(qos: .userInitiated).async {
            let daily = databaseManager.fetchDailyData(metaId: item.id, limit: 300)
            let weekly = databaseManager.fetchWeeklyData(metaId: item.id, limit: 150)

            DispatchQueue.main.async {
                self.dailyData = daily
                self.weeklyData = weekly
                self.isLoading = false
            }
        }
    }
}
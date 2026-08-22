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
    /// 打开详情时的候选标的列表与当前位置（用于第二副图左右滑动切换标的）
    @Published var navItems: [MetaItem] = []
    @Published var navIndex: Int = 0

    /// 从列表打开：记录候选列表与当前位置，便于第二副图左右滑动切换标的
    func open(_ item: MetaItem, in list: [MetaItem]) {
        navItems = list
        navIndex = list.firstIndex(where: { $0.id == item.id }) ?? 0
        self.item = item
    }

    /// 切换标的：dir = -1 上一个 / +1 下一个；越界返回 nil（不切换）
    func neighbor(_ dir: Int) -> MetaItem? {
        let i = navIndex + dir
        guard i >= 0, i < navItems.count else { return nil }
        navIndex = i
        let next = navItems[i]
        item = next
        return next
    }
}

struct KlineDetailView: View {
    @ObservedObject private var databaseManager = DatabaseManager.shared
    @ObservedObject private var detailRouter = DetailRouter.shared

    /// 当前展示的标的（第二副图左右滑动时可在候选列表中切换）
    @State private var item: MetaItem
    var onClose: () -> Void
    @State private var selectedPeriod: KlinePeriod = .daily
    @State private var showSettings = false
    /// 自定义指标公式编辑器是否打开（由 K 线图内部触发，此处负责隐藏顶部栏实现真全屏）
    @State private var showCustomEditor = false
    @ObservedObject private var config = ChartConfigStore.shared
    @State private var dailySeries: ChartSeries? = nil
    @State private var weeklySeries: ChartSeries? = nil
    @State private var isLoading = true

    init(item: MetaItem, onClose: @escaping () -> Void) {
        self._item = State(initialValue: item)
        self.onClose = onClose
    }

    private var currentSeries: ChartSeries? { selectedPeriod == .daily ? dailySeries : weeklySeries }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // 自定义指标公式编辑器（真全屏）打开时隐藏顶部栏
                if !showCustomEditor {
                    // 顶部留白压缩为小固定值，减少状态栏区域的空白
                    Color.clear
                        .frame(height: 2)

                    topBar
                }

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

    /// 顶部单行：返回 + 名称/代码/类型 + 周期切换 + K线设置
    private var topBar: some View {
        HStack(spacing: 6) {
            // 返回
            Button(action: {
                onClose()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 30, height: 30)
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(6)
            }

            // 名称 / 代码 / 类型
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.black)
                        .lineLimit(1)
                    Text(item.displayCode)
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
                Text(item.type)
                    .font(.system(size: 8))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            // K线设置
            Button(action: {
                withAnimation { showSettings = true }
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundColor(.gray)
                    .frame(width: 32, height: 30)
                    .contentShape(Rectangle())
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(Color.white)
        .overlay(
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var chartArea: some View {
        ZStack {
            Color.white

            Group {
                if isLoading {
                    loadingView
                } else if currentSeries == nil {
                    emptyDataView
                } else if let s = currentSeries {
                    chartView(series: s)
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
                    Text("K线设置")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.black)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // 0. 行情周期（日线/周线）
                        settingsSectionTitle("行情周期")
                        Menu {
                            ForEach(KlinePeriod.allCases) { period in
                                Button {
                                    withAnimation { selectedPeriod = period }
                                } label: {
                                    if selectedPeriod == period {
                                        Label(period.rawValue, systemImage: "checkmark")
                                    } else {
                                        Text(period.rawValue)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(selectedPeriod.rawValue)
                                    .font(.system(size: 15))
                                    .foregroundColor(.black)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.gray.opacity(0.12))
                            .cornerRadius(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)

                        // 1. K线类型（下拉选项，压缩占位）
                        settingsSectionTitle("K线类型")
                        Menu {
                            ForEach(ChartStyle.allCases) { style in
                                Button {
                                    withAnimation { config.chartStyle = style }
                                } label: {
                                    if config.chartStyle == style {
                                        Label(style.rawValue, systemImage: "checkmark")
                                    } else {
                                        Text(style.rawValue)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(config.chartStyle.rawValue)
                                    .font(.system(size: 15))
                                    .foregroundColor(.black)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.gray.opacity(0.12))
                            .cornerRadius(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)

                        // 2. 区间统计
                        settingsSectionTitle("区间统计")
                        toggleRow(title: "显示区间统计", isOn: $config.displaySettings.showRangeStats) {
                            Text("在图表右上角显示可见区间的涨跌幅、高低、量额统计")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }

                        // 3. 图层显示
                        settingsSectionTitle("图层显示")
                        toggleRow(title: "跳空缺口", isOn: $config.displaySettings.showGap) {
                            Text("在 K 线之间标出跳空缺口区域")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        toggleRow(title: "缺口回补后消失", isOn: $config.displaySettings.gapDisappearAfterFill) {
                            Text("开启时缺口被回补后整体隐藏；关闭时仅截止到回补位置、保留形成到截止区域")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        toggleRow(title: "最新价线", isOn: $config.displaySettings.showLatestPriceLine) {
                            Text("在最新收盘价位置绘制虚线")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        toggleRow(title: "指标不挤压K线", isOn: $config.displaySettings.indicatorNotSqueezeKline) {
                            Text("开启时主图价格范围仅按K线计算，指标线超出部分被裁剪；关闭后指标线会撑大价格范围")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        toggleRow(title: "裸K", isOn: $config.showBareK) {
                            Text("开启后只显示K线、隐藏主图指标")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                    }
                }

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: geometry.size.height * 0.75)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func settingsSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.gray)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    private func toggleRow(title: String, isOn: Binding<Bool>, @ViewBuilder subtitle: () -> some View) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: isOn.animation()) {
                    Text(title)
                        .font(.system(size: 15))
                        .foregroundColor(.black)
                }
                .tint(.blue)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                subtitle()
                    .padding(.horizontal, 16)
            }
            .padding(.vertical, 2)
            Divider().padding(.leading, 16)
        }
    }

    private func chartView(series: ChartSeries) -> some View {
        KlineChartView(series: series, chartStyle: $config.chartStyle, displaySettings: $config.displaySettings,
                       showCustomEditor: $showCustomEditor, period: selectedPeriod,
                       onPeriodSwitch: { newPeriod in
                           withAnimation { selectedPeriod = newPeriod }
                       },
                       onSwitchItem: { dir in
                           // 第二副图左右滑动切换标的：dir = -1 上一个 / +1 下一个
                           if let next = detailRouter.neighbor(dir) {
                               item = next
                               loadData()
                           }
                       })
            .id(series.sorted)
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

        // 后台串行加载并预计算指标（全量历史），避免阻塞主线程
        DispatchQueue.global(qos: .userInitiated).async {
            let daily = databaseManager.fetchDailyData(metaId: item.id)
            let weekly = databaseManager.fetchWeeklyData(metaId: item.id)

            DispatchQueue.main.async {
                self.dailySeries = daily.isEmpty ? nil : ChartSeries(data: daily)
                self.weeklySeries = weekly.isEmpty ? nil : ChartSeries(data: weekly)
                self.isLoading = false
            }
        }
    }
}

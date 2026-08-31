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

    /// 查询某方向是否可切换（-1 上一个 / +1 下一个），用于副图滑动提示
    func canSwitch(_ dir: Int) -> Bool {
        let i = navIndex + dir
        return i >= 0 && i < navItems.count
    }
}

/// 双视图联动同步对象：左右两个 K 线图（左日线/右周线）通过它按日期（YYYYMMDD 整数）同步十字光标
final class DualLinkSync: ObservableObject {
    @Published var cursorDate: Int? = nil
    /// 最近一次 cursorDate 是否由「右侧视图用户直接操作」产生。
    /// 左视图据此决定是否把联动K线居中显示；左视图自身拖动产生的回声不算
    var lastCursorFromRightUser = false
}

struct KlineDetailView: View {
    @ObservedObject private var databaseManager = DatabaseManager.shared
    @ObservedObject private var detailRouter = DetailRouter.shared

    /// 当前展示的标的（第二副图左右滑动时可在候选列表中切换）
    @State private var item: MetaItem
    var onClose: () -> Void
    @State private var showSettings = false
    /// 自定义指标公式编辑器是否打开（由 K 线图内部触发，此处负责隐藏顶部栏实现真全屏）
    @State private var showCustomEditor = false
    /// 系统指标公式编辑器是否打开（同样需隐藏顶部栏实现真全屏）
    @State private var showSystemEditor = false
    @ObservedObject private var config = ChartConfigStore.shared
    @State private var dailySeries: ChartSeries? = nil
    @State private var weeklySeries: ChartSeries? = nil
    @State private var monthlySeries: ChartSeries? = nil
    @State private var seasonalSeries: ChartSeries? = nil
    @State private var yearlySeries: ChartSeries? = nil
    @State private var isLoading = true
    /// 📌 固定光标模式开关（高亮表示已开启）
    @State private var pinEnabled = false
    /// 图表当前是否已有任意十字光标（控制 📌 按钮是否可开启）
    @State private var chartHasCursor = false
    /// 单视图 / 双联动模式：双联动时左右对半分，左日线、右周线，十字光标按日期联动
    @State private var dualLink = false
    /// 双视图联动同步（日线/周线图共享）
    @State private var linkSync = DualLinkSync()

    init(item: MetaItem, onClose: @escaping () -> Void) {
        self._item = State(initialValue: item)
        self.onClose = onClose
    }

    private var currentSeries: ChartSeries? {
        switch config.selectedPeriod {
        case .daily: return dailySeries
        case .weekly: return weeklySeries
        case .monthly: return monthlySeries
        case .seasonal: return seasonalSeries
        case .yearly: return yearlySeries
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // 自定义/系统指标公式编辑器（真全屏）打开时隐藏顶部栏
                if !showCustomEditor && !showSystemEditor {
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

            // 📌 固定光标：关闭时只允许单光标；有光标时才能开启，开启后固定第一个光标并可点击产生第二个
            Button(action: {
                if pinEnabled {
                    pinEnabled = false
                } else if chartHasCursor {
                    pinEnabled = true
                }
            }) {
                Image(systemName: pinEnabled ? "pin.fill" : "pin")
                    .font(.system(size: 15))
                    .foregroundColor(pinEnabled ? .blue : .gray)
                    .frame(width: 32, height: 30)
                    .contentShape(Rectangle())
            }
            .disabled(!pinEnabled && !chartHasCursor)

            // 单视图 / 双联动：双联动时左右对半分（左日线/右周线），十字光标联动
            Button(action: {
                withAnimation { dualLink.toggle() }
            }) {
                Text(dualLink ? "2️⃣" : "1️⃣")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(dualLink ? .blue : .gray)
                    .frame(width: 32, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(dualLink ? "切换为单视图" : "切换为双联动")

            // 多/空 全局镜像：开启后主图与所有副图数值取负镜像（空头）
            Button(action: {
                config.mainMirrored.toggle()
            }) {
                Text(config.mainMirrored ? "空" : "多")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(config.mainMirrored ? .blue : .gray)
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(config.mainMirrored ? "关闭空头镜像" : "开启空头镜像")

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
                } else if dualLink, let daily = dailySeries, let weekly = weeklySeries {
                    dualLinkArea(daily: daily, weekly: weekly)
                } else if currentSeries == nil {
                    emptyDataView
                } else if let s = currentSeries {
                    chartView(series: s, period: config.selectedPeriod, linked: false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 双联动：左右对半分，左日线、右周线，十字光标按日期联动。
    /// 左右各用独立的副图模型（isolatedSubs），避免共享副图模型被不同数据长度的曲线互相覆盖
    private func dualLinkArea(daily: ChartSeries, weekly: ChartSeries) -> some View {
        HStack(spacing: 0) {
            // 左日线：接收联动光标时把联动K线居中显示
            chartView(series: daily, period: .daily, linked: true, isolated: true, linkAutoCenter: true)
            Divider().frame(width: 0.5)
            // 右周线：保持现有联动逻辑（贴右边缘）
            chartView(series: weekly, period: .weekly, linked: true, isolated: true, linkAutoCenter: false)
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
                                    withAnimation { config.selectedPeriod = period }
                                } label: {
                                    if config.selectedPeriod == period {
                                        Label(period.rawValue, systemImage: "checkmark")
                                    } else {
                                        Text(period.rawValue)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(config.selectedPeriod.rawValue)
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

    private func chartView(series: ChartSeries, period: KlinePeriod, linked: Bool, isolated: Bool = false, linkAutoCenter: Bool = false) -> some View {
        KlineChartView(series: series, chartStyle: $config.chartStyle, displaySettings: $config.displaySettings,
                       showCustomEditor: $showCustomEditor, showSystemEditor: $showSystemEditor, metaId: item.id, period: period,
                       isolatedSubs: isolated, linkAutoCenter: linkAutoCenter,
                       onPeriodSwitch: linked ? { _ in } : { newPeriod in
                           // 切换周期后图表重建，固定光标随之失效，重置 pin
                           pinEnabled = false
                           withAnimation { config.selectedPeriod = newPeriod }
                       },
                       onPeriodPrefetched: { finished in
                           // 当前周期已全部算完：后台继续预计算其它未计算周期（不切换可见周期）
                           prefetchOtherPeriods(excluding: finished)
                       },
                       onSwitchItem: { dir in
                           // 第二副图左右滑动切换标的：dir = -1 上一个 / +1 下一个
                           if let next = detailRouter.neighbor(dir) {
                               pinEnabled = false
                               item = next
                               loadData()
                           }
                       },
                       canSwitchItem: { dir in
                           detailRouter.canSwitch(dir)
                       },
                       pinEnabled: $pinEnabled,
                       onHasCursorChange: { has in
                           chartHasCursor = has
                       },
                       linkSync: linked ? linkSync : nil)
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

        // 后台串行加载并预计算指标（全量历史），避免阻塞主线程。
        // 月/季/年线表可能不存在，不存在时对应查询返回空、series 为 nil，仅加载日/周线
        DispatchQueue.global(qos: .userInitiated).async {
            let daily = databaseManager.fetchDailyData(metaId: item.id)
            let weekly = databaseManager.fetchWeeklyData(metaId: item.id)
            let monthly = databaseManager.fetchMonthlyData(metaId: item.id)
            let seasonal = databaseManager.fetchSeasonalData(metaId: item.id)
            let yearly = databaseManager.fetchYearlyData(metaId: item.id)

            DispatchQueue.main.async {
                self.dailySeries = daily.isEmpty ? nil : ChartSeries(data: daily)
                self.weeklySeries = weekly.isEmpty ? nil : ChartSeries(data: weekly)
                self.monthlySeries = monthly.isEmpty ? nil : ChartSeries(data: monthly)
                self.seasonalSeries = seasonal.isEmpty ? nil : ChartSeries(data: seasonal)
                self.yearlySeries = yearly.isEmpty ? nil : ChartSeries(data: yearly)
                self.isLoading = false
            }
        }
    }

    /// 当前周期已全部算完后，在后台继续预计算其它未计算周期：
    /// 结果写入 ChartCacheStore，用户切到该周期时由 K 线图直接从缓存恢复，无需等待。
    /// 只处理已加载出数据、且尚未标记预计算完成的周期；不切换可见周期。
    /// 注意：当前正在显示的周期由可见 K 线图自己分块预计算，后台只补「不可见」的周期，
    /// 避免后台提前把可见周期标记为完成、与可见视图的进行中计算产生竞态
    private func prefetchOtherPeriods(excluding finished: KlinePeriod) {
        let metaId = item.id
        let visible = config.selectedPeriod
        for period in KlinePeriod.allCases where period != finished && period != visible {
            let data: [KlineItem]?
            switch period {
            case .daily: data = dailySeries?.sorted
            case .weekly: data = weeklySeries?.sorted
            case .monthly: data = monthlySeries?.sorted
            case .seasonal: data = seasonalSeries?.sorted
            case .yearly: data = yearlySeries?.sorted
            }
            guard let data, !data.isEmpty else { continue }
            // 是否已预计算、配置是否已过期，由 KlineChartView.prefetchOtherPeriod 内部判断
            KlineChartView.prefetchOtherPeriod(metaId: metaId, period: period, data: data)
        }
    }
}

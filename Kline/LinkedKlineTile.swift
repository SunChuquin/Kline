//
//  LinkedKlineTile.swift
//  Kline
//
//  联动多视图中的单个视图块：持有独立(标的,周期)，自行加载该标的该周期的数据，
//  并渲染 KlineChartView。副图一滑动切周期、副图二滑动切标的（与常规一致），
//  副图二指标栏最右侧提供 🔍 搜索（覆盖式搜索栏 + 系统键盘）。
//
//  Created by 孙楚昆 on 2026/8/31.
//

import SwiftUI
import UIKit
import Combine

/// 联动单视图块：负责加载数据 + 渲染图表 + 副图搜索
struct LinkedKlineTile: View {
    /// 当前视图的配置（标的 + 周期），父层驱动；变化时本视图重新加载
    var view: LinkedViewConfig
    /// 所属主标的（用于把本视图的周期/标的变更持久化到该标的名下）
    let ownerMetaID: Int
    /// 是否第一个视图（左游标居中）
    let linkAutoCenter: Bool
    /// 当前是否处于「边」边线调节（禁止十字光标）
    let suppressCrosshair: Bool

    @Binding var showCustomEditor: Bool
    @Binding var showSystemEditor: Bool

    let onCursorChange: (Bool) -> Void

    @ObservedObject private var databaseManager = DatabaseManager.shared
    @ObservedObject private var linkedStore = LinkedViewStore.shared
    @ObservedObject private var config = ChartConfigStore.shared

    /// 本视图标的对应的数据（按当前 view.metaID+period 加载）
    @State private var chartSeries: ChartSeries? = nil
    @State private var isLoading = true
    /// 当前加载的(标的,周期)，用于校验 chartSeries 是否仍与 view 同步
    @State private var loadedKey: (Int, KlinePeriod)? = nil
    /// 递增加载序号：丢弃过期异步结果，避免快速切周期时旧结果覆盖新周期数据
    @State private var loadTicket = 0

    /// 副图二 🔍 搜索栏是否展开
    @State private var showSearch = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    /// 副图二滑动切周期用到的联动同步对象（本视图自持）
    @StateObject private var localLinkSync = DualLinkSync()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                // 仅当数据(标的,周期)与当前视图一致时显示图表，否则转加载/空，杜绝错配
                if isLoading || loadedKey != .some((view.metaID, view.period)) {
                    Color.white
                        .overlay(ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .gray)))
                } else if let series = chartSeries {
                    kline(series: series)
                } else {
                    emptyView
                }
            }
            // 每个联动视图的标的+周期标识（左上角覆盖显示，方便辨认当前视图内容）
            viewTag
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: loadData)
        .onChange(of: view.metaID) { _ in loadData() }
        .onChange(of: view.period) { _ in loadData() }
    }

    /// 左上角标识条：标的代码 + 名称 + 周期（透明底，不拦截图表手势）
    private var viewTag: some View {
        HStack(spacing: 4) {
            Text(view.code.isEmpty ? "\(view.metaID)" : view.displayCode)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.blue)
            Text(view.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.black)
                .lineLimit(1)
            Text(view.period.rawValue)
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.85))
        .cornerRadius(4)
        .padding(.leading, 4)
        .padding(.top, 2)
        .allowsHitTesting(false)
    }

    // MARK: - 数据加载

    private func loadData() {
        guard databaseManager.isLoaded else {
            isLoading = true
            return
        }
        let ticket = loadTicket + 1
        loadTicket = ticket
        let targetKey = (view.metaID, view.period)
        // 同步先清掉与当前不匹配的旧数据，避免「新周期身份 + 旧周期数据」渲染
        if loadedKey != .some(targetKey) {
            chartSeries = nil
            loadedKey = nil
        }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = databaseManager.fetchBars(metaId: view.metaID, period: view.period)
            DispatchQueue.main.async {
                // 只有仍是最新一轮、且请求的(标的,周期)与当前一致才写入，否则丢弃
                guard self.loadTicket == ticket, self.view.metaID == targetKey.0, self.view.period == targetKey.1 else { return }
                self.chartSeries = rows.isEmpty ? nil : ChartSeries(data: rows)
                self.loadedKey = (self.view.metaID, self.view.period)
                self.isLoading = false
            }
        }
    }

    // MARK: - 子视图

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 40))
                .foregroundColor(.gray.opacity(0.5))
            Text("暂无\(view.displayCode) \(view.period.rawValue)数据")
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    /// 渲染单个 K 线图，并把副图二搜索栏作为 overlay 覆盖
    private func kline(series: ChartSeries) -> some View {
        KlineChartView(series: series, chartStyle: $config.chartStyle, displaySettings: $config.displaySettings,
                       showCustomEditor: $showCustomEditor, showSystemEditor: $showSystemEditor,
                       // metaId 传 nil：联动多视图不使用共享 ChartCacheStore，
                       // 避免多个 tile 用相同 metaId 并行预计算互相污染缓存（方向相关的副图空白根因）。
                       // 每次周期/标的切换，.id 变化触发全新图表状态，前台完整重算主图+副图。
                       metaId: nil, period: view.period,
                       isolatedSubs: true, linkAutoCenter: linkAutoCenter,
                       onPeriodSwitch: { newPeriod in
                           // 副图二切周期（联动态）：只改本视图周期，持久化到 owner
                           pinReservedHelper()
                           var v = view
                           v.period = newPeriod
                           linkedStore.setConfigs(replace(v, in: ownerMetaID), for: ownerMetaID)
                       },
                       onPeriodPrefetched: { _ in },
                       onSwitchItem: { dir in
                           // 副图一切标的（联动态）
                           pinReservedHelper()
                           switchItem(dir)
                       },
                       canSwitchItem: { dir in
                           linkedStore.canSwitchItem(current: view, dir: dir)
                       },
                       pinEnabled: .constant(false),
                       onHasCursorChange: onCursorChange,
                       suppressCrosshair: suppressCrosshair,
                       swapSubSwipeRoles: false,
                       showSubTwoSearchButton: true,
                       onSubTwoSearch: {
                           showSearch = true
                           // 打开搜索栏时弹起系统键盘
                           DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                               searchFocused = true
                           }
                       },
                       linkSync: localLinkSync)
            .overlay {
                if showSearch {
                    chartSearchBar
                }
            }
            .id(chartIdentity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 图表身份：绑定(标的,周期)。配合 metaId=nil，周期/标的切换必定创建全新图表状态
    /// （全新隔离副图 @StateObject + 前台完整重算），避免折返复用残留或共享缓存串扰。
    private var chartIdentity: String {
        "\(view.metaID)-\(view.period.rawValue)"
    }

    /// 占位（原详情页在切周期/标的时会重置 pin；本 tile 已无全局 pin，保留空实现保证类型一致）
    private func pinReservedHelper() {}

    /// 在本 owner 的配置里替换第 view.index 个视图
    private func replace(_ newView: LinkedViewConfig, in metaID: Int) -> [LinkedViewConfig] {
        var list = linkedStore.configs(for: metaID)
        if newView.index < list.count {
            list[newView.index] = newView
        } else {
            list.append(newView)
        }
        return list
    }

    /// 本视图按候选列表切换标的（dir = -1 上一个 / +1 下一个）
    private func switchItem(_ dir: Int) {
        guard let routerItem = DetailRouter.shared.item else { return }
        let candidates = DetailRouter.shared.navItems
        guard !candidates.isEmpty else { return }
        guard let curIdx = candidates.firstIndex(where: { $0.id == view.metaID }) else { return }
        let t = curIdx + dir
        guard t >= 0, t < candidates.count else { return }
        let next = candidates[t]
        var v = view
        v.metaID = next.id
        v.name = next.name
        v.code = next.code
        v.type = next.type
        linkedStore.setConfigs(replace(v, in: ownerMetaID), for: ownerMetaID)
    }

    // MARK: - 副图二搜索栏（覆盖式）

    private var chartSearchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    showSearch = false
                    searchText = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                TextField("搜索\(view.name)", text: $searchText)
                    .font(.system(size: 14))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(6)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.white)

            if !searchText.isEmpty {
                searchResultList
            }
        }
        .background(Color.white)
        .transition(.opacity)
    }

    private var searchResultList: some View {
        SearchContentView(searchText: $searchText) { result in
            // 副图二搜索：把选中标的应用到本视图（只改本视图，选中后关闭搜索栏）
            var v = view
            v.metaID = result.id
            v.name = result.name
            v.code = result.code
            v.type = result.type
            linkedStore.setConfigs(replace(v, in: ownerMetaID), for: ownerMetaID)
            showSearch = false
            searchText = ""
            searchFocused = false
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 搜索候选项列表（复用行情页搜索逻辑）

/// 搜索候选结果容器：内部执行与行情页相同的模糊搜索，把命中项回调给父层
struct SearchContentView: View {
    @Binding var searchText: String
    /// 点击某条时回调选中标的
    let onSelect: (MetaItem) -> Void
    @ObservedObject private var databaseManager = DatabaseManager.shared
    @State private var results: [MetaItem] = []
    @State private var searchTask: DispatchWorkItem?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if results.isEmpty {
                    Text("没有匹配的标的")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                        .padding(12)
                } else {
                    ForEach(results) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            row(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onChange(of: searchText) { newValue in
            performSearch(keyword: newValue)
        }
        .onAppear { performSearch(keyword: searchText) }
    }

    private func row(_ item: MetaItem) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.name)
                    .font(.system(size: 14))
                    .foregroundColor(.black)
                    .lineLimit(1)
                Spacer()
                Text(item.displayCode)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            Divider().padding(.leading, 12)
        }
    }

    private func performSearch(keyword: String) {
        searchTask?.cancel()
        let task = DispatchWorkItem {
            let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !kw.isEmpty else {
                DispatchQueue.main.async { self.results = [] }
                return
            }
            let hits = databaseManager.searchMeta(keyword: kw)
            DispatchQueue.main.async { self.results = hits }
        }
        searchTask = task
        DispatchQueue.global(qos: .userInitiated).async(execute: task)
    }
}
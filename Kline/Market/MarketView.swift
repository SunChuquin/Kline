//
//  MarketView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/23.
//  2026/09/01 重构为通达信式表单（可配置字段 + 自定义排序 + 表头显隐 + 加自选）
//  2026/09/20 改为按布局偏好分发的容器（A/B/C/D），共享骨架见 MarketPageKit.swift
//

import SwiftUI
import Combine

/// 行情页顶部一级菜单（参考测试页2：居中 Tab）
enum TopField: String, CaseIterable, Identifiable {
    case market = "市场"
    case picker = "选股"
    case fav = "自选"
    var id: String { rawValue }
}

/// 选股 → 二级
enum PickerField: String, CaseIterable, Identifiable {
    case trend = "趋势"
    case oscillation = "震荡"
    case reversal = "反转"
    case sentiment = "情绪"
    var id: String { rawValue }
}

/// 自选 → 二级
enum FavField: String, CaseIterable, Identifiable {
    case holdings = "持仓"
    case pool = "股池"
    var id: String { rawValue }
}

/// 行情页「市场」二级分类（对应 tdx_parser.py 生成的 meta.type 取值；
/// 「ETF指数」= 沪深京指数 + 扩展行情指数 合并展示）
enum MarketTab: String, CaseIterable, Identifiable {
    case mainBoard = "沪深主板"
    case etfIndex = "ETF指数"
    var id: String { rawValue }
}

/// 行情页容器：按 `PageLayoutStore.marketLayout` 分发到四档布局。
/// 页面状态（分类 / 列表快照 / 浮层 / 横向滚动）统一由 `MarketPageModel` 持有，
/// 容器层只保留副作用（刷新触发）与浮层挂载。
struct MarketView: View {
    @StateObject private var model = MarketPageModel()
    @ObservedObject private var layoutStore = PageLayoutStore.shared

    // 容器层保留的观测对象：仅用于 onChange / onReceive 触发刷新
    @ObservedObject private var databaseManager = DatabaseManager.shared
    @ObservedObject private var fav = FavoritesStore.shared
    @ObservedObject private var rowCache = MarketRowCache.shared
    @ObservedObject private var colCfg = MarketConfigStore.shared

    var body: some View {
        layoutContent
            // 浮层（设置面板 / 加分组 / 搜索页 / 公式中心）挂在容器层，四档共用
            .marketSheets(model: model)
            // 异形屏横屏贴边已由 ContentView 根布局统一处理，此处仅实测宿主宽度
            // （贴边后的真实可视宽），供 maxHOffset 计算横向滚动上限
            .marketTableHostWidth(to: $model.tableVisibleWidth)
            // 键盘避让已由 ContentView 根部全局禁用，此处无需重复处理
            .onAppear { model.scheduleRefresh() }
            // 切 Tab / 数据库加载完毕
            .onChange(of: model.selectedTab) { _ in model.scheduleRefresh() }
            .onChange(of: databaseManager.isLoaded) { _ in model.scheduleRefresh() }
            // 收藏变化（加 / 删自选会触发置顶分组）
            .onReceive(fav.objectWillChange) { _ in model.scheduleRefresh() }
            // 排序规则变化
            .onChange(of: colCfg.visibleColumns(for: .marketBoard)) { _ in model.scheduleRefresh() }
            .onChange(of: colCfg.sortRule(for: .marketBoard)) { _ in model.scheduleRefresh() }
            // 字段筛选变化（「表头设置」面板里调整筛选后）
            .onChange(of: model.filterConfigKey) { _ in model.scheduleRefresh() }
            // **关键**：每只标的的 bars 从后台到达后，rowCache 会 objectWillChange。
            // 由于 displayRows 里存的是 MarketRow（class，引用不变），如果不主动做一次 copy，
            // SwiftUI 会认为 displayRows 没变，ForEach 不会重算行内部的 Text → 一直显示 "-"。
            // 这里做一次轻量 copy，保证行内 Text 重算。
            .onReceive(rowCache.objectWillChange) { _ in
                // 已展示行的数值先做轻量 copy 立即刷新
                model.displayRows = model.displayRows
                // 有字段筛选时，把「值刚到、此前被排除」的行加回：防抖 250ms 合并，避免每行刷全表
                if model.hasActiveFilters {
                    model.filterDebounce?.cancel()
                    // 显式切回 MainActor 再调用（DispatchWorkItem 的 block 不保证隔离继承）
                    let m = model
                    let item = DispatchWorkItem {
                        Task { @MainActor in m.scheduleRefresh() }
                    }
                    model.filterDebounce = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
                }
            }
    }

    /// 布局分发：A 档为现有实现；B/C/D 暂回落 A。
    @ViewBuilder
    private var layoutContent: some View {
        switch layoutStore.marketLayout {
        case .a:
            MarketLayoutAView(model: model)
        case .b, .c, .d:
            // TODO: 后续阶段接入 B / C / D 三套布局，当前暂回落 A
            MarketLayoutAView(model: model)
        }
    }
}

#Preview {
    MarketView()
}

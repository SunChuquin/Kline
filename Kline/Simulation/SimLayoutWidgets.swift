//
//  SimLayoutWidgets.swift
//  Kline
//
//  模拟页 JSON 布局控件注册表（sim.* 前缀控件名 → 视图构建器）。
//
//  控件从既有 A/B/C 硬编码布局视图原样搬迁：视觉与行为口径不变，差别只在——
//  控件自身**不持交互状态、不直接呈现浮层**：页面级状态与浮层统一读
//  `SimulationPageModel`（由容器 SimulationView 持有并下发给上下文），
//  fullScreenCover / alert / toast / 抽屉在容器统一挂载。
//  通用引擎的容器（vstack/hstack/scroll/card/frame 等）与页面无关通用控件
//  （common.* 横滑卡片 / 列表卡片，见 CommonLayoutWidgets.swift）直接复用，不重复开发。
//  未注册的控件名由 PageLayoutRenderer 渲染可诊断占位（不崩溃、不静默空白）。
//
//  控件名、本文件的注册名、SimWidgetEditorSchema 的描述、JSON 里的 widget.name 四处一致。
//

import SwiftUI

// MARK: - 控件名（JSON 里的 widget.name）

/// 模拟页控件的控件名
enum SimWidgetName {
    static let title = "sim.title"
    static let topBar = "sim.topBar"
    static let assetMetrics = "sim.assetMetrics"
    static let summaryBand = "sim.summaryBand"
    static let moduleToolbar = "sim.moduleToolbar"
    static let logFilterBar = "sim.logFilterBar"
    static let moduleTable = "sim.moduleTable"
    static let bottomActionBar = "sim.bottomActionBar"
    static let accountSidebar = "sim.accountSidebar"
    static let accountCards = "sim.accountCards"
    static let moduleGrid = "sim.moduleGrid"
    static let pendingCard = "sim.pendingCard"
    static let fillsCard = "sim.fillsCard"
}

// MARK: - 顶栏入口项（sim.topBar 的 entries 参数）

/// 顶栏可配置的功能入口（显式、缺省 = 全部按声明顺序）
enum SimTopBarEntry: String, CaseIterable {
    case condOrder
    case strategyFormula
    case trainingRecord
    case wallet
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .condOrder: return "条件单"
        case .strategyFormula: return "策略公式"
        case .trainingRecord: return "训练记录"
        case .wallet: return "资金管理"
        case .settings: return "设置"
        }
    }
}

// MARK: - 注册表

/// 模拟页控件注册表（控件名 → 视图构建器；构建器接收 SimLayoutContext + WidgetParams）
struct SimWidgetRegistry {
    static let shared = SimWidgetRegistry()

    /// 通用引擎的控件注册表
    let registry: PageWidgetRegistry<SimLayoutContext>

    private init() {
        var r = PageWidgetRegistry<SimLayoutContext>()

        r.register(SimWidgetName.title) { _, p in
            AnyView(SimTitleWidget(text: p.string("text", default: "模拟交易")))
        }

        r.register(SimWidgetName.topBar) { ctx, p in
            // entries 缺省 = 全部入口；未知 id 过滤；去重并保持配置顺序
            let kinds: [SimTopBarEntry]
            if let rawIDs = p.strings("entries") {
                var seen = Set<String>()
                kinds = rawIDs.compactMap { raw in
                    guard let kind = SimTopBarEntry(rawValue: raw), seen.insert(raw).inserted else { return nil }
                    return kind
                }
            } else {
                kinds = SimTopBarEntry.allCases
            }
            return AnyView(SimTopBarWidget(model: ctx.model,
                                           title: p.string("title", default: "模拟交易"),
                                           hint: p.string("hint", default: ""),
                                           showsAccountChip: p.bool("chip", default: false),
                                           entries: kinds))
        }

        r.register(SimWidgetName.assetMetrics) { ctx, _ in
            AnyView(SimAssetMetricsWidget(model: ctx.model))
        }

        r.register(SimWidgetName.summaryBand) { ctx, _ in
            AnyView(SimSummaryBand(accountID: SimStore.shared.queryAccountID))
        }

        r.register(SimWidgetName.moduleToolbar) { ctx, p in
            AnyView(SimModuleToolbarWidget(model: ctx.model,
                                           sidebarOffset: CGFloat(p.int("sidebarOffset", default: 0)),
                                           logActions: p.bool("logActions", default: false),
                                           showsSearch: p.bool("showsSearch", default: true)))
        }

        r.register(SimWidgetName.logFilterBar) { ctx, _ in
            AnyView(SimLogFilterWidget(model: ctx.model))
        }

        r.register(SimWidgetName.moduleTable) { ctx, p in
            AnyView(SimModuleTableWidget(model: ctx.model,
                                         sidebarOffset: CGFloat(p.int("sidebarOffset", default: 0))))
        }

        r.register(SimWidgetName.bottomActionBar) { ctx, p in
            AnyView(SimBottomBarWidget(model: ctx.model,
                                       hint: p.optionalString("hint")))
        }

        r.register(SimWidgetName.accountSidebar) { ctx, _ in
            AnyView(SimAccountSidebarWidget(model: ctx.model))
        }

        r.register(SimWidgetName.accountCards) { ctx, p in
            AnyView(SimAccountCardsWidget(model: ctx.model,
                                          showsNewCard: p.bool("showsNewCard", default: true)))
        }

        r.register(SimWidgetName.moduleGrid) { ctx, p in
            AnyView(SimModuleGridWidget(model: ctx.model,
                                        summaryRows: p.int("summaryRows", default: 3)))
        }

        r.register(SimWidgetName.pendingCard) { _, p in
            AnyView(SimPendingCardWidget(maxRows: p.int("maxRows", default: 2)))
        }

        r.register(SimWidgetName.fillsCard) { _, p in
            AnyView(SimFillsCardWidget(maxRows: p.int("maxRows", default: 3)))
        }

        // 页面无关的通用控件（横滑卡片 / 列表卡片）：直接复用，不重复开发
        registerCommonLayoutWidgets(into: &r)

        registry = r
    }
}

// MARK: - 标题

/// 大标题（19pt bold，A/B/C 布局顶部共用视觉令牌）
struct SimTitleWidget: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 19, weight: .bold))
            .foregroundColor(Color.primary)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - 顶栏（B/C 顶部条：标题 + 提示 + 账户 chip + 功能入口组）

/// 顶部条：宽屏单行（title + [hint] + [chip] + 右侧入口组），
/// 紧凑宽（<600）且无账户 chip 时拆两行（第一行标题+提示、第二行入口右对齐）；
/// 有 chip 的形态（C 券商经典顶栏）内容窄，紧凑宽保持单行不变（与 C 布局一致）。
struct SimTopBarWidget: View {
    @ObservedObject var model: SimulationPageModel
    let title: String
    let hint: String
    let showsAccountChip: Bool
    let entries: [SimTopBarEntry]

    @ObservedObject private var store = SimStore.shared
    @CompactWidthValue private var isCompactWidth

    var body: some View {
        Group {
            if showsAccountChip {
                singleRow
            } else if isCompactWidth {
                compactRows
            } else {
                singleRow
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    /// 单行形态（C 顶栏 / B 宽屏）
    private var singleRow: some View {
        HStack(spacing: showsAccountChip ? 12 : 10) {
            if showsAccountChip {
                SimTitleWidget(text: title)
                Spacer(minLength: 8)
                accountChip
                Spacer(minLength: 8)
            } else {
                SimTitleWidget(text: title)
                if !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(.secondaryLabel))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
            }
            entryButtons
        }
        .padding(.horizontal, showsAccountChip ? 16 : 18)
        .frame(height: 52)
    }

    /// 紧凑两行形态（B 顶栏：第一行标题+提示，第二行入口右对齐）
    private var compactRows: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                SimTitleWidget(text: title)
                if !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(.secondaryLabel))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                entryButtons
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    // MARK: 入口组

    @ViewBuilder
    private var entryButtons: some View {
        ForEach(entries, id: \.rawValue) { entry in
            switch entry {
            case .condOrder:
                SimCondEntryWidget(model: model)
            case .strategyFormula:
                SimStrategyFormulaEntryButton { model.showStrategyFormulas = true }
            case .trainingRecord:
                SimTrainingRecordEntryButton { model.showTrainingRecords = true }
            case .wallet:
                miniButton(icon: "wallet.pass", title: entry.title) {
                    model.showWalletAlert = true
                }
            case .settings:
                miniButton(icon: "gear", title: entry.title) {
                    model.showRulesAlert = true
                }
            }
        }
    }

    /// 账户下拉 chip（C 顶部条同款：列出「全部账户汇总」+ 各可用账户）
    private var accountChip: some View {
        Menu {
            Button("全部账户汇总") { store.selectedAccountID = SimStore.allAccountID }
            ForEach(store.activeAccounts) { account in
                Button(account.name) { store.selectedAccountID = account.id }
            }
        } label: {
            HStack(spacing: 6) {
                Text(store.accountName(id: store.selectedAccountID))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(.secondaryLabel))
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(.secondarySystemBackground)))
        }
        .accessibilityIdentifier("sim.account.menu")
    }

    /// 蓝描边小按钮（资金管理 / 设置，26pt 高，与 A/B/C 顶部动作一致）
    private func miniButton(icon: String, title: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12))
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 工具栏「条件单」入口

/// 「条件单」入口（文字右上角叠监控中数量角标；A/B/C 工具栏共用视觉令牌）
struct SimCondEntryWidget: View {
    @ObservedObject var model: SimulationPageModel
    @ObservedObject private var store = SimStore.shared

    var body: some View {
        let monitoring = store.condCounts(accountID: store.queryAccountID).monitoring
        return Button(action: { model.condPresentation = .list(UUID()) }) {
            Text("条件单")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.blue)
                .overlay(alignment: .topTrailing) {
                    if monitoring > 0 {
                        Text("\(monitoring)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color(.systemRed)))
                            .offset(x: 12, y: -8)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.cond.entry")
    }
}

// MARK: - 资产指标行（C：七项等宽；紧凑宽垂直堆叠）

/// 七项等宽指标行（总资产 / 可用 / 市值 / 仓位 / 当日盈亏 / 累计盈亏 / 在途委托）：
/// 宽屏单行等宽（视觉令牌与 C 布局一致）；
/// 紧凑宽（<600）垂直堆叠——每项独占一行全宽（label 左灰 / value 右着色加粗）。
struct SimAssetMetricsWidget: View {
    @ObservedObject var model: SimulationPageModel
    @ObservedObject private var store = SimStore.shared
    @CompactWidthValue private var isCompactWidth

    /// 紧凑态指标胶囊（label 即 id，七项标签互不重复）
    private struct Pill: Identifiable {
        let label: String
        let value: String
        let color: Color
        var id: String { label }
    }

    private func profitColor(_ value: Double) -> Color {
        value < 0 ? Color(.systemGreen) : Color(.systemRed)
    }

    var body: some View {
        let summary = store.summary(accountID: store.queryAccountID)
        let pendingCount = store.activeOrders(accountID: store.queryAccountID).count
        return Group {
            if isCompactWidth {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pills(summary: summary, pendingCount: pendingCount)) { pill in
                        pillRow(pill)
                    }
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 0) {
                    metricItem("总资产", SimFormat.amount0(summary.totalAssets))
                    metricSeparator
                    metricItem("可用", SimFormat.amount0(summary.cash))
                    metricSeparator
                    metricItem("市值", SimFormat.amount0(summary.marketValue))
                    metricSeparator
                    metricItem("仓位", SimFormat.pct(summary.positionPct * 100))
                    metricSeparator
                    metricItem("当日盈亏", SimFormat.signed0(summary.dayProfit),
                               color: profitColor(summary.dayProfit))
                    metricSeparator
                    metricItem("累计盈亏", SimFormat.signed0(summary.totalProfit),
                               color: profitColor(summary.totalProfit))
                    metricSeparator
                    metricItem("在途委托", "\(pendingCount)", color: Color.orange)
                }
                .frame(height: 52)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    private func pills(summary: SimStore.SimAccountSummary, pendingCount: Int) -> [Pill] {
        [
            Pill(label: "总资产", value: SimFormat.amount0(summary.totalAssets), color: Color.primary),
            Pill(label: "可用", value: SimFormat.amount0(summary.cash), color: Color.primary),
            Pill(label: "市值", value: SimFormat.amount0(summary.marketValue), color: Color.primary),
            Pill(label: "仓位", value: SimFormat.pct(summary.positionPct * 100), color: Color.primary),
            Pill(label: "当日盈亏", value: SimFormat.signed0(summary.dayProfit),
                 color: profitColor(summary.dayProfit)),
            Pill(label: "累计盈亏", value: SimFormat.signed0(summary.totalProfit),
                 color: profitColor(summary.totalProfit)),
            Pill(label: "在途委托", value: "\(pendingCount)", color: Color.orange),
        ]
    }

    /// 紧凑态单行（label 左灰 / value 右着色加粗，全宽行高 26）
    private func pillRow(_ pill: Pill) -> some View {
        HStack(spacing: 6) {
            Text(pill.label)
                .font(.system(size: 10.5))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(pill.value)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(pill.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 26)
    }

    private func metricItem(_ label: String, _ value: String,
                            color: Color = Color.primary) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricSeparator: some View {
        Rectangle().fill(Color(.separator)).frame(width: 0.5, height: 26)
    }
}

// MARK: - 模块工具栏（分段控件 + 功能入口 + 搜索 / 刷新）

/// 模块行（A/C 布局的 moduleRow 原样搬迁）：
/// 单行形态「分段控件 + 条件单 / 策略公式 / 训练记录 + 搜索框 + 刷新」；
/// 窄行（可用宽 − 侧栏偏移 < ~800，或紧凑宽 <600）拆两行——分段控件独占横滚行，
/// 搜索框改弹性宽（单行固有宽 ~795pt，窄行放不下）。
/// logActions = true（A 方案）：日志模块时工具栏切「近 30 天 / 搜索 / 导出」。
/// sidebarOffset：本行左侧被固定侧栏占用的宽（A 方案填 216，其余填 0）。
struct SimModuleToolbarWidget: View {
    @ObservedObject var model: SimulationPageModel
    var sidebarOffset: CGFloat = 0
    var logActions: Bool = false
    var showsSearch: Bool = true

    @ObservedObject private var store = SimStore.shared
    @Environment(\.klineAvailableWidth) private var availableWidth
    @CompactWidthValue private var isCompactWidth

    /// 行固有最小宽 ~795pt（分段控件 + 三入口 + 固定 148pt 搜索框 + 刷新）；
    /// 实测可用行宽低于它时拆两行收敛（与 A 布局 moduleRowSplits 同口径）。
    private var rowSplit: Bool {
        let effectiveWidth = availableWidth - sidebarOffset
        if isCompactWidth { return true }
        if effectiveWidth <= 0 { return false }
        return effectiveWidth < 800
    }

    var body: some View {
        Group {
            if rowSplit {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        SimModuleSegmentedBar(module: $model.module,
                                              accountID: store.queryAccountID)
                            .frame(height: 44)
                    }
                    .frame(height: 44)
                    HStack(spacing: 8) {
                        entryGroup
                        toolbar
                    }
                    .frame(height: 44)
                }
            } else {
                HStack(spacing: 10) {
                    SimModuleSegmentedBar(module: $model.module,
                                          accountID: store.queryAccountID)
                    Spacer(minLength: 8)
                    entryGroup
                    toolbar
                }
                .frame(height: 44)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var entryGroup: some View {
        SimCondEntryWidget(model: model)
        SimStrategyFormulaEntryButton { model.showStrategyFormulas = true }
        SimTrainingRecordEntryButton { model.showTrainingRecords = true }
    }

    /// 工具栏：日志模块（logActions）切「近 30 天 / 搜索 / 导出」，其余为搜索 / 刷新
    @ViewBuilder
    private var toolbar: some View {
        if logActions && model.module == .log {
            HStack(spacing: 8) {
                toolbarButton(icon: "calendar", title: "近 30 天") {
                    model.showToast("日志范围：近 30 天（更早记录请继续向下滚动加载）")
                }
                if showsSearch {
                    searchBox(placeholder: "搜索操作内容")
                }
                toolbarButton(icon: "square.and.arrow.down", title: "导出") {
                    model.exportLogs()
                }
            }
        } else {
            HStack(spacing: 8) {
                if showsSearch {
                    searchBox(placeholder: "搜索标的名称/代码")
                }
                toolbarButton(icon: "arrow.clockwise", title: "刷新") {
                    Task { await model.refreshQuotes() }
                }
            }
        }
    }

    /// 搜索框：单行形态固定 148pt；拆行形态改弹性宽（吃掉行内剩余空间，
    /// 固定宽与其他固定入口共存必然把「刷新 / 导出」挤出屏，与 A/C 同因同解）
    private func searchBox(placeholder: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
            TextField(placeholder, text: $model.keyword)
                .font(.system(size: 11.5))
                .foregroundColor(Color.primary)
                .frame(width: rowSplit ? nil : 148)
                .frame(maxWidth: rowSplit ? .infinity : nil)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemBackground)))
    }

    private func toolbarButton(icon: String?, title: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon).font(.system(size: 11))
                }
                Text(title).font(.system(size: 11.5))
            }
            .foregroundColor(Color(.secondaryLabel))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(.separator), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 日志模块筛选条

/// 操作日志模块筛选条：仅日志模块占位（其余模块零高度，让位给业务区）
struct SimLogFilterWidget: View {
    @ObservedObject var model: SimulationPageModel

    var body: some View {
        if model.module == .log {
            SimLogModuleFilterBar(selected: $model.logModule)
        } else {
            Color.clear.frame(height: 0)
        }
    }
}

// MARK: - 业务模块表格

/// 五模块业务表（持仓 / 委托 / 成交 / 流水 / 日志），跟随页面状态：
/// 当前模块 / 搜索词 / 日志筛选都读页面模型；行内「买 / 卖 / 条件单 / 改价」回调交模型路由。
/// sidebarOffset：左侧固定侧栏宽（A 方案填 216）——行固有宽 ~806pt，行宽低于
/// 「可用宽 − 侧栏偏移」时整表包横向滚动（与 A 布局 workspaceNarrow 同口径）；
/// 紧凑宽（<600）必包横滚。
struct SimModuleTableWidget: View {
    @ObservedObject var model: SimulationPageModel
    var sidebarOffset: CGFloat = 0

    @ObservedObject private var store = SimStore.shared
    @Environment(\.klineAvailableWidth) private var availableWidth
    @CompactWidthValue private var isCompactWidth

    var body: some View {
        let wraps = isCompactWidth
            || (sidebarOffset > 0 && availableWidth > 0 && availableWidth - sidebarOffset < 760)
        return SimModuleTable(module: model.module,
                              accountID: store.queryAccountID,
                              onTrade: { position, direction in
                                  model.openTicket(accountID: position.accountID,
                                                   metaID: position.metaID,
                                                   code: position.code,
                                                   name: position.name,
                                                   direction: direction)
                              },
                              onAmend: { order in model.beginAmend(order) },
                              onCondition: { position in model.openCondEditor(for: position) },
                              keyword: model.keyword,
                              logModuleFilter: model.module == .log ? model.logModule : nil,
                              isCompact: wraps)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 底部买卖条

/// 底部常驻买入 / 卖出条；提示文案由「hint」参数配置（缺省 = SimBottomActionBar 自带文案），
/// 紧凑宽（<600）隐藏提示文案（比值共享既有实现，见 SimBottomActionBar）
struct SimBottomBarWidget: View {
    @ObservedObject var model: SimulationPageModel
    /// nil = 用缺省提示文案
    let hint: String?

    @CompactWidthValue private var isCompactWidth

    var body: some View {
        SimBottomActionBar(onTrade: { model.openBottomTicket($0) },
                           hint: hint ?? SimBottomActionBar.defaultHintText,
                           isCompact: isCompactWidth)
    }
}

// MARK: - 账户侧栏（A：宽屏 216pt 常驻列；紧凑态锚点行 + 抽屉）

/// 宽屏：账户侧栏（账户标题 + 账户行 + 新建 + 底部提示 / 操作入口）；
/// 紧凑宽（<600）：收纳为顶部「账户」锚点行（切换 model.accountDrawerActive），
/// 抽屉面板由容器 overlay 呈现（SimAccountDrawerView）。
struct SimAccountSidebarWidget: View {
    @ObservedObject var model: SimulationPageModel
    @ObservedObject private var store = SimStore.shared
    @CompactWidthValue private var isCompactWidth

    var body: some View {
        if isCompactWidth {
            compactAnchorRow
        } else {
            wideSidebar
        }
    }

    // MARK: 宽屏侧栏

    private var wideSidebar: some View {
        VStack(spacing: 0) {
            Text("账户")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Color(.secondaryLabel))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 12, leading: 16, bottom: 5, trailing: 16))

            ScrollView {
                LazyVStack(spacing: 2) {
                    SimAccountSummaryRow(store: store, then: nil)
                    ForEach(store.activeAccounts) { account in
                        SimAccountRow(store: store, account: account, then: nil)
                    }                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }

            SimNewAccountRow {
                model.showCreateAccount = true
            }

            if let hint = model.sidebarHint {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            sidebarBottomActions
        }
        .frame(width: 216, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
    }

    /// 侧栏底部操作入口（交易规则 / 账户管理的说明文案展示在侧栏提示区）
    private var sidebarBottomActions: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
            bottomActionRow(icon: "gear", title: "交易规则设置") {
                model.sidebarHint = SimulationPageModel.rulesText
            }
            bottomActionRow(icon: "doc.text", title: "账户管理") {
                model.sidebarHint = SimulationPageModel.accountHelpText
            }
        }
    }

    private func bottomActionRow(icon: String, title: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundColor(Color(.secondaryLabel))
            .padding(.horizontal, 16)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 紧凑态锚点行

    /// 紧凑态「账户」抽屉入口行：侧栏图标 + 当前账户名 + 下拉箭头
    /// （与自选 B 分组入口同一形态；新建账户弹窗挂在容器）
    private var compactAnchorRow: some View {
        HStack(spacing: 8) {
            Button {
                model.accountDrawerActive.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(.secondaryLabel))
                    Text(store.accountName(id: store.selectedAccountID))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(.secondaryLabel))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 低布局优先级：空间不足时优先压缩账户名（截断显示），行内其余内容保持完整
            .layoutPriority(-1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }
}

// MARK: - 账户行（侧栏 / 抽屉共用）

/// 「全部账户汇总」行（聚合视图）：常驻侧栏与紧凑抽屉共用同一份视图；
/// `then` 在切换动作后调用（抽屉里顺带收抽屉）
struct SimAccountSummaryRow: View {
    @ObservedObject var store: SimStore
    /// 抽屉用：切换账户后收起抽屉
    var then: (() -> Void)?

    private func profitColor(_ value: Double) -> Color {
        value < 0 ? Color(.systemGreen) : Color(.systemRed)
    }

    var body: some View {
        let selected = store.isAllAccountsSelected
        let summary = store.summary(accountID: nil)
        return Button(action: {
            store.selectedAccountID = SimStore.allAccountID
            then?()
        }) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "globe")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color.white)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("全部账户汇总")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color.primary)
                        .lineLimit(1)
                    Text("\(store.activeAccounts.count) 个账户 · 聚合视图")
                        .font(.system(size: 10))
                        .foregroundColor(Color(.secondaryLabel))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(SimFormat.pct(summary.dayProfitPct * 100))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(profitColor(summary.dayProfit))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color(.systemBackground) : Color.clear))
            .shadow(color: selected ? Color.black.opacity(0.08) : Color.clear,
                    radius: 2, x: 0, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.account.all")
    }
}

/// 单个账户行（色块 + 名称 + 总资产 + 当日盈亏%）：常驻侧栏与紧凑抽屉共用同一份视图
struct SimAccountRow: View {
    @ObservedObject var store: SimStore
    let account: SimAccount
    var then: (() -> Void)?

    private func colorFromHex(_ hex: String) -> Color {
        Color(hex: hex) ?? Color(.systemGray)
    }

    private func profitColor(_ value: Double) -> Color {
        value < 0 ? Color(.systemGreen) : Color(.systemRed)
    }

    var body: some View {
        let selected = store.selectedAccountID == account.id
        let summary = store.summary(accountID: account.id)
        return Button(action: {
            store.selectedAccountID = account.id
            then?()
        }) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(colorFromHex(account.colorHex))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Text(account.badge)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(Color.white)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color.primary)
                        .lineLimit(1)
                    Text(SimFormat.amount0(summary.totalAssets))
                        .font(.system(size: 10))
                        .foregroundColor(Color(.secondaryLabel))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(SimFormat.pct(summary.dayProfitPct * 100))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(profitColor(summary.dayProfit))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color(.systemBackground) : Color.clear))
            .shadow(color: selected ? Color.black.opacity(0.08) : Color.clear,
                    radius: 2, x: 0, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.account.\(account.name)")
    }
}

/// 「新建账户」行（侧栏底部蓝色入口）
struct SimNewAccountRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle").font(.system(size: 12))
                Text("新建账户").font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.account.new")
    }
}

// MARK: - 账户抽屉（容器 overlay 呈现；行 / 底部入口与侧栏共用同一份）

/// 账户抽屉：行复用常驻侧栏同一份（全部汇总行 / 账户行），底部入口复用
/// 新建 / 交易规则设置 / 账户管理；由容器（SimConfigHost）overlay 挂载。
/// 紧凑态没有侧栏提示区，「交易规则设置 / 账户管理」说明文案改工作区轻提示呈现。
struct SimAccountDrawerView: View {
    @ObservedObject var model: SimulationPageModel
    @ObservedObject private var store = SimStore.shared

    /// 选项约束（SidebarDrawer 要求 Hashable）：「全部账户汇总」置顶 + 各账户
    private enum Option: Hashable {
        case all
        case one(UUID)
    }

    private var options: [Option] {
        [.all] + store.activeAccounts.map { .one($0.id) }
    }

    private var currentSelection: Option {
        if store.isAllAccountsSelected { return .all }
        if let id = store.selectedAccountID { return .one(id) }
        return .all
    }

    var body: some View {
        SidebarDrawer(
            isPresented: $model.accountDrawerActive,
            title: "账户",
            options: options,
            selection: currentSelection,
            onSelect: { option in
                switch option {
                case .all: store.selectedAccountID = SimStore.allAccountID
                case .one(let id): store.selectedAccountID = id
                }
            },
            rowContent: { option, _ in
                // 选中高亮由行内部按 store 状态自算（与侧栏同一判定源），第二个参数不用
                switch option {
                case .all:
                    SimAccountSummaryRow(store: store) { model.accountDrawerActive = false }
                case .one(let id):
                    if let account = store.account(id: id) {
                        SimAccountRow(store: store, account: account) { model.accountDrawerActive = false }
                    }
                }
            },
            footer: {
                VStack(spacing: 0) {
                    Divider()
                    VStack(spacing: 6) {
                        footerButton("新建账户", icon: "plus") {
                            model.showCreateAccount = true
                        }
                        .accessibilityIdentifier("sim.account.new")
                        HStack(spacing: 6) {
                            footerButton("交易规则设置", icon: "gear") {
                                model.showToast(SimulationPageModel.rulesText)
                            }
                            footerButton("账户管理", icon: "doc.text") {
                                model.showToast(SimulationPageModel.accountHelpText)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                }
            }
        )
    }

    /// 抽屉底部操作按钮（与自选 B 抽屉底部入口同一形态）
    private func footerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.blue)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 账户卡片横排（B）

/// 账户卡片行（B 布局 accountStrip 搬迁）：
/// 宽屏横排横滚（全部汇总卡 + 各账户卡 + 新建卡）；
/// 紧凑宽（<600）单列垂直堆叠，每卡独占一行全宽（视觉令牌不变）。
struct SimAccountCardsWidget: View {
    @ObservedObject var model: SimulationPageModel
    var showsNewCard: Bool = true

    @ObservedObject private var store = SimStore.shared
    @Environment(\.klineAvailableWidth) private var availableWidth
    @CompactWidthValue private var isCompactWidth

    /// 页面可用宽条目（紧凑态全宽卡用）；0 时按横排固有宽
    private var compactCardWidth: CGFloat {
        availableWidth > 0 ? max(0, availableWidth - 16 * 2) : 320
    }

    /// 卡片统一尺寸（全部汇总 / 各账户 / 新建账户三态对齐）
    private let cardWidth: CGFloat = 218
    private let cardHeight: CGFloat = 104
    private let newCardWidth: CGFloat = 150

    var body: some View {
        Group {
            if isCompactWidth {
                VStack(spacing: 12) {
                    SimAccountSummaryCard(width: compactCardWidth, height: cardHeight)
                    ForEach(store.activeAccounts) { account in
                        SimAccountCard(account: account,
                                       width: compactCardWidth, height: cardHeight)
                    }
                    if showsNewCard {
                        SimNewAccountCard(width: compactCardWidth, height: cardHeight,
                                          action: { model.showCreateAccount = true })
                    }
                }
                .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        SimAccountSummaryCard(width: cardWidth, height: cardHeight)
                        ForEach(store.activeAccounts) { account in
                            SimAccountCard(account: account,
                                           width: cardWidth, height: cardHeight)
                        }
                        if showsNewCard {
                            SimNewAccountCard(width: newCardWidth, height: cardHeight,
                                              action: { model.showCreateAccount = true })
                        }
                    }
                    .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
            }
        }
        .background(Color(.systemBackground))
    }
}

/// 账户卡副行：「当日 +2,841 ｜ 累计 +2.84%」；textColor 为 nil 时用盈亏色
private func simCardProfitLine(label1: String, value1: String, sign1: Double,
                               label2: String, value2: String, sign2: Double,
                               textColor: Color?) -> some View {
    func profitColor(_ value: Double) -> Color {
        value < 0 ? Color(.systemGreen) : Color(.systemRed)
    }
    return HStack(spacing: 3) {
        Text(label1)
            .font(.system(size: 10.5))
            .foregroundColor(textColor?.opacity(0.8) ?? Color(.secondaryLabel))
        Text(value1)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(textColor ?? profitColor(sign1))
        Text("｜")
            .font(.system(size: 10.5))
            .foregroundColor(textColor?.opacity(0.6) ?? Color(.tertiaryLabel))
        Text(label2)
            .font(.system(size: 10.5))
            .foregroundColor(textColor?.opacity(0.8) ?? Color(.secondaryLabel))
        Text(value2)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(textColor ?? profitColor(sign2))
        Spacer(minLength: 0)
    }
    .frame(height: 13)
    .lineLimit(1)
    .minimumScaleFactor(0.8)
}

/// 全部账户汇总卡（语义色背景 + 语义色文字）；宽度由调用方给（横排 218 / 紧凑全宽）
struct SimAccountSummaryCard: View {
    @ObservedObject private var store = SimStore.shared
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let selected = store.isAllAccountsSelected
        let summary = store.summary(accountID: nil)
        let series = store.netValueSeries(accountID: nil, days: 30)
        return Button(action: { store.selectedAccountID = SimStore.allAccountID }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(.secondaryLabel))
                    Text("全部账户汇总")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: 16)

                Text(SimFormat.amount0(summary.totalAssets))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                simCardProfitLine(label1: "当日", value1: SimFormat.signed0(summary.dayProfit),
                                  sign1: summary.dayProfit,
                                  label2: "累计", value2: SimFormat.signed0(summary.totalProfit),
                                  sign2: summary.totalProfit,
                                  textColor: nil)

                SimSparkline(values: series, tint: Color(.systemRed))
                    .frame(height: 26)
                    .opacity(0.85)
            }
            .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
            .frame(width: width, height: height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color.blue : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.account.all")
    }
}

/// 单个账户卡（底色取账户 colorHex，卡内文字为白色唯一的场景）
struct SimAccountCard: View {
    @ObservedObject private var store = SimStore.shared
    let account: SimAccount
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let selected = store.selectedAccountID == account.id
        let summary = store.summary(accountID: account.id)
        let series = store.netValueSeries(accountID: account.id, days: 30)
        return Button(action: { store.selectedAccountID = account.id }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(account.badge)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(Color(hex: account.colorHex) ?? Color(.systemGray))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(0.92)))
                    Text(account.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: 16)

                Text(SimFormat.amount0(summary.totalAssets))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                simCardProfitLine(label1: "当日", value1: SimFormat.signed0(summary.dayProfit),
                                  sign1: summary.dayProfit,
                                  label2: "累计", value2: SimFormat.pct(summary.totalProfitPct * 100),
                                  sign2: summary.totalProfit,
                                  textColor: Color.white)

                SimSparkline(values: series, tint: Color.white.opacity(0.9))
            }
            .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
            .frame(width: width, height: height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: account.colorHex) ?? Color(.systemGray)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color.blue : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.account.\(account.name)")
    }
}

/// 新建账户卡（虚线边框 + 蓝色文字）
struct SimNewAccountCard: View {
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                Text("新建账户")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundColor(.blue)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundColor(Color(.separator)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.account.new")
    }
}

// MARK: - 模块宫格（B）

/// 四张模块卡宫格（持仓 / 当日委托 / 当日成交 / 历史中心）：
/// 卡内只有摘要与快捷计数，整卡可点 → 全屏明细页（容器 fullScreenCover 呈现）。
/// 宽屏两列 Elastic 网格；紧凑宽（<600）SwiftUI 自动降为单列（ inherent 2 列自适应收缩）。
struct SimModuleGridWidget: View {
    @ObservedObject var model: SimulationPageModel
    /// 卡内摘要行数（默认 3，对齐既有实现）
    var summaryRows: Int = 3

    @ObservedObject private var store = SimStore.shared

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            SimModuleCard(model: model, store: store, module: .position,
                          title: "持仓", icon: "chart.bar", iconTint: .blue,
                          summaryRows: summaryRows)
            SimModuleCard(model: model, store: store, module: .order,
                          title: "当日委托", icon: "clock", iconTint: .orange,
                          summaryRows: summaryRows)
            SimModuleCard(model: model, store: store, module: .fill,
                          title: "当日成交", icon: "doc.text",
                          iconTint: Color(.systemGreen),
                          summaryRows: summaryRows)
            SimModuleCard(model: model, store: store, module: .log,
                          title: "历史中心", icon: "list.bullet",
                          iconTint: Color(.secondaryLabel),
                          summaryRows: summaryRows)
        }
        .padding(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// 模块卡外壳：图标 + 标题 + 计数胶囊 + 摘要行 + 底部入口（整卡可点，进入全屏明细）
private struct SimModuleCard: View {
    let model: SimulationPageModel
    @ObservedObject var store: SimStore
    let module: SimModuleTab
    let title: String
    let icon: String
    let iconTint: Color
    let summaryRows: Int

    private func profitColor(_ value: Double) -> Color {
        value < 0 ? Color(.systemGreen) : Color(.systemRed)
    }

    private func emptyText(_ module: SimModuleTab) -> String {
        switch module {
        case .position: return "暂无持仓"
        case .order:    return "暂无在途委托"
        case .fill:     return "暂无成交"
        case .cash:     return "暂无资金流水"
        case .log:      return "暂无操作日志"
        }
    }

    private var badge: String {
        switch module {
        case .position:
            let list = store.positions(accountID: store.queryAccountID)
            return "\(list.count) 只"
        case .order:
            let list = store.activeOrders(accountID: store.queryAccountID)
            return "\(list.count) 笔在途"
        case .fill:
            let list = store.fills(accountID: store.queryAccountID)
            return "\(list.count) 笔"
        case .cash:
            return "—"
        case .log:
            let list = store.actionLogs(accountID: store.queryAccountID)
            return "\(list.count) 条"
        }
    }

    private var footer: String {
        switch module {
        case .position: return "查看全部 \(store.positions(accountID: store.queryAccountID).count) 只 →"
        case .order:    return "查看全部委托 →"
        case .fill:     return "查看全部成交 →"
        case .cash:     return "查看全部流水 →"
        case .log:      return "进入历史中心 →"
        }
    }

    var body: some View {
        Button(action: { model.detailModule = module }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(iconTint)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(badge)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(Color(.secondaryLabel))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(.tertiarySystemBackground)))
                }
                .frame(height: 18)

                summaryRowsView

                Spacer(minLength: 0)

                Text(footer)
                    .font(.system(size: 11))
                    .foregroundColor(.blue)
                    .lineLimit(1)
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.module.\(module.rawValue)")
    }

    /// 摘要行（行数由 summaryRows 参数决定；空态给可诊断提示）
    @ViewBuilder
    private var summaryRowsView: some View {
        switch module {
        case .position:
            let list = store.positions(accountID: store.queryAccountID)
            if list.isEmpty {
                SimModuleCardEmptyHint(text: emptyText(module))
            } else {
                ForEach(Array(list.prefix(summaryRows))) { position in
                    let snapshot = store.snapshot(for: position)
                    summaryRow {
                        Text(position.name)
                            .font(.system(size: 11.5))
                            .foregroundColor(Color.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(SimFormat.shares(position.qty))
                            .font(.system(size: 11))
                            .foregroundColor(Color(.secondaryLabel))
                        Text(SimFormat.signed0(snapshot.profit))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(profitColor(snapshot.profit))
                            .frame(width: 78, alignment: .trailing)
                    }
                }
            }
        case .order:
            let list = store.activeOrders(accountID: store.queryAccountID)
            if list.isEmpty {
                SimModuleCardEmptyHint(text: emptyText(module))
            } else {
                ForEach(Array(list.prefix(summaryRows))) { order in
                    summaryRow {
                        SimDirectionTag(direction: order.direction)
                        Text(order.name)
                            .font(.system(size: 11.5))
                            .foregroundColor(Color.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(order.price.map { SimFormat.price($0) } ?? "市价") × \(SimFormat.shares(order.qty))")
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(.secondaryLabel))
                            .lineLimit(1)
                        SimStatusTag(status: order.status)
                    }
                }
            }
        case .fill:
            let list = store.fills(accountID: store.queryAccountID)
            if list.isEmpty {
                SimModuleCardEmptyHint(text: emptyText(module))
            } else {
                ForEach(Array(list.prefix(summaryRows))) { fill in
                    summaryRow {
                        Text(SimFormat.time(fill.tradedAt))
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(.secondaryLabel))
                        SimDirectionTag(direction: fill.direction)
                        Text(fill.name)
                            .font(.system(size: 11.5))
                            .foregroundColor(Color.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(SimFormat.amount(fill.amount))
                            .font(.system(size: 11))
                            .foregroundColor(Color.primary)
                    }
                }
            }
        case .cash:
            SimModuleCardEmptyHint(text: "在明细页查看资金流水")
        case .log:
            let list = store.actionLogs(accountID: store.queryAccountID)
            if list.isEmpty {
                SimModuleCardEmptyHint(text: emptyText(module))
            } else {
                ForEach(Array(list.prefix(summaryRows))) { log in
                    summaryRow {
                        Text(SimFormat.dateTime(log.occurredAt))
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(.secondaryLabel))
                        Text(log.content)
                            .font(.system(size: 11.5))
                            .foregroundColor(Color.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(log.result)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(simResultColorInCard(log.result))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func summaryRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .frame(height: 22)
    }
}

/// 模块卡摘要行空态
private struct SimModuleCardEmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Color(.tertiaryLabel))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 22)
    }
}

/// 操作结果文案配色（成功绿 / 在途橙 / 其余灰；卡内摘要用）
private func simResultColorInCard(_ text: String) -> Color {
    let success = ["成功", "已成交", "全部成交"]
    let pending = ["部成", "已报", "待报"]
    if success.contains(where: { text.contains($0) }) { return Color(.systemGreen) }
    if pending.contains(where: { text.contains($0) }) { return Color(.orange) }
    return Color(.secondaryLabel)
}

// MARK: - 在途委托 / 当日成交小卡（C）

/// 左卡：在途委托（最多 maxRows 行 + 撤单）
struct SimPendingCardWidget: View {
    var maxRows: Int = 2

    @ObservedObject private var store = SimStore.shared

    var body: some View {
        let all = store.activeOrders(accountID: store.queryAccountID)
        let list = Array(all.prefix(maxRows))
        return VStack(spacing: 0) {
            cardTitleRow("在途委托", count: all.count, unit: "")
            if list.isEmpty {
                emptyCardHint("暂无在途委托")
            } else {
                ForEach(list) { order in
                    pendingRow(order)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 110, alignment: .top)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 1))
    }

    private func cardTitleRow(_ title: String, count: Int, unit: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color.primary)
            Text("\(count)\(unit)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(.systemRed))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
    }

    private func pendingRow(_ order: SimOrder) -> some View {
        HStack(spacing: 6) {
            SimDirectionTag(direction: order.direction)
            Text(order.name)
                .font(.system(size: 11.5))
                .foregroundColor(Color.primary)
                .lineLimit(1)
            Text(pendingDetail(order))
                .font(.system(size: 10.5))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
            Spacer(minLength: 4)
            SimInlineButton(title: "撤单", tint: Color(.secondaryLabel)) {
                Task { await store.cancelOrder(id: order.id) }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    /// 委托摘要：「市价 500 · 部成300」
    private func pendingDetail(_ order: SimOrder) -> String {
        let priceText = order.price.map { SimFormat.price($0) } ?? "市价"
        var text = "\(priceText) \(SimFormat.shares(order.qty))"
        if order.filledQty > 0 {
            text += " · 部成\(SimFormat.shares(order.filledQty))"
        }
        return text
    }

    private func emptyCardHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Color(.tertiaryLabel))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 右卡：当日成交（最多 maxRows 行）
struct SimFillsCardWidget: View {
    var maxRows: Int = 3

    @ObservedObject private var store = SimStore.shared

    var body: some View {
        let all = store.fills(accountID: store.queryAccountID)
        let list = Array(all.prefix(maxRows))
        return VStack(spacing: 0) {
            cardTitleRow("当日成交", count: all.count, unit: " 笔")
            if list.isEmpty {
                emptyCardHint("暂无成交")
            } else {
                ForEach(list) { fill in
                    fillCardRow(fill)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 110, alignment: .top)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 1))
    }

    private func cardTitleRow(_ title: String, count: Int, unit: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color.primary)
            Text("\(count)\(unit)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(.systemRed))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
    }

    private func fillCardRow(_ fill: SimFill) -> some View {
        HStack(spacing: 6) {
            Text(SimFormat.time(fill.tradedAt))
                .font(.system(size: 10.5))
                .foregroundColor(Color(.secondaryLabel))
                .frame(width: 52, alignment: .leading)
            Text(fill.name)
                .font(.system(size: 11.5))
                .foregroundColor(Color.primary)
                .lineLimit(1)
            Text("\(fill.direction.isBuy ? "买" : "卖") \(SimFormat.shares(fill.qty))")
                .font(.system(size: 10.5))
                .foregroundColor(fill.direction.isBuy ? Color(.systemRed) : Color(.systemGreen))
            Spacer(minLength: 4)
            Text(SimFormat.price(fill.price))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.primary)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    private func emptyCardHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Color(.tertiaryLabel))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

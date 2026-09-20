//
//  SimSharedViews.swift
//  Kline
//
//  模拟页共享视图：五模块枚举、全屏下单请求、资产总览带、模块分段控件、
//  五张业务表（持仓 / 委托 / 成交 / 流水 / 日志）、底部买卖条、全屏下单页，
//  以及方向标签 / 状态标签 / 行内小按钮 / 净值迷你折线等原子件。
//  约定：iOS 15 兼容（不用 Table / Chart / NavigationStack / @Observable）；
//  配色买入 Color(.systemRed)、卖出 Color(.systemGreen)，背景一律语义色（支持深色模式）。
//

import SwiftUI

// MARK: - 模块

/// 模拟页五个业务模块
enum SimModuleTab: String, CaseIterable, Identifiable {
    case position, order, fill, cash, log

    var id: String { rawValue }

    var title: String {
        switch self {
        case .position: return "持仓"
        case .order:    return "当日委托"
        case .fill:     return "当日成交"
        case .cash:     return "资金流水"
        case .log:      return "操作日志"
        }
    }
}

// MARK: - 全屏下单请求

/// 全屏下单页的呈现请求（各布局用 .fullScreenCover(item:) 呈现）
struct SimTicketRequest: Identifiable {
    /// 每次新建请求都换新 UUID，保证同一标的可重复呈现
    let id: UUID
    let accountID: UUID
    let metaID: Int
    let code: String
    let name: String
    var direction: SimOrderDirection

    init(accountID: UUID, metaID: Int, code: String, name: String, direction: SimOrderDirection) {
        self.id = UUID()
        self.accountID = accountID
        self.metaID = metaID
        self.code = code
        self.name = name
        self.direction = direction
    }
}

// MARK: - 文件内配色助手

/// 盈亏配色（涨红跌绿）：>= 0 红，< 0 绿
private func simProfitColor(_ value: Double) -> Color {
    value < 0 ? Color(.systemGreen) : Color(.systemRed)
}

/// 操作结果文案配色：成功类绿、在途类橙、其余灰
private func simResultColor(_ text: String) -> Color {
    let success = ["成功", "已成交", "全部成交"]
    let pending = ["部成", "已报", "待报"]
    if success.contains(where: { text.contains($0) }) { return Color(.systemGreen) }
    if pending.contains(where: { text.contains($0) }) { return Color(.orange) }
    return Color(.secondaryLabel)
}

// MARK: - 原子件

/// 方向标签（买红 / 卖绿，10.5 bold，圆角 4）
struct SimDirectionTag: View {
    let direction: SimOrderDirection

    private var tint: Color { direction.isBuy ? Color(.systemRed) : Color(.systemGreen) }

    var body: some View {
        Text(direction.title)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(tint)
            .frame(width: 36, height: 17)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.12)))
    }
}

/// 委托状态标签（已成交灰 / 已报红 / 部成橙 / 待报灰 / 已撤灰）
struct SimStatusTag: View {
    let status: SimOrderStatus

    private var tint: Color {
        switch status {
        case .reported: return Color(.systemRed)
        case .partial:  return Color(.orange)
        case .filled, .pending, .cancelled: return Color(.secondaryLabel)
        }
    }

    var body: some View {
        Text(status.title)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(tint)
            .frame(width: 46, height: 17)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.12)))
    }
}

/// 行内小操作按钮（11pt、1pt 描边、圆角 6）
struct SimInlineButton: View {
    let title: String
    var tint: Color = .blue
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.6), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 净值迷你折线（Path 绘制，不用 Canvas / Chart）
struct SimSparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if pts.count >= 2 {
                    Path { path in
                        path.move(to: pts[0])
                        for pt in pts.dropFirst() { path.addLine(to: pt) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: 28)
    }

    /// 把净值序列归一化到视图尺寸（上下各留 2pt 内边距，避免线贴边被裁）
    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let span = maxValue - minValue
        let width = max(size.width, 1)
        let height = max(size.height - 4, 1)
        let stepX = width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let ratio = span > 0 ? (value - minValue) / span : 0.5
            let y = 2 + height - CGFloat(ratio) * height
            return CGPoint(x: CGFloat(index) * stepX, y: y)
        }
    }
}

// MARK: - 资产总览带

/// 资产总览带：六项指标（总资产 / 可用资金 / 持仓市值 / 持仓占比 / 当日盈亏 / 累计盈亏）
/// + 近 30 日净值折线；accountID == nil 表示「全部账户汇总」
struct SimSummaryBand: View {
    let accountID: UUID?

    @ObservedObject private var store = SimStore.shared

    var body: some View {
        let summary = store.summary(accountID: accountID)
        let series = store.netValueSeries(accountID: accountID, days: 30)

        HStack(spacing: 0) {
            metric("总资产", SimFormat.amount0(summary.totalAssets), big: true, color: Color.primary)
            separator
            metric("可用资金", SimFormat.amount0(summary.cash), big: false, color: Color.primary)
            separator
            metric("持仓市值", SimFormat.amount0(summary.marketValue), big: false, color: Color.primary)
            separator
            metric("持仓占比", SimFormat.pct(summary.positionPct * 100), big: false, color: Color.primary)
            separator
            metric("当日盈亏", SimFormat.signed0(summary.dayProfit), big: false,
                   color: simProfitColor(summary.dayProfit))
            separator
            metric("累计盈亏", SimFormat.signed0(summary.totalProfit), big: false,
                   color: simProfitColor(summary.totalProfit))

            VStack(alignment: .trailing, spacing: 3) {
                Text("近 30 日净值")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(.secondaryLabel))
                SimSparkline(values: series, tint: Color(.systemRed))
                    .frame(width: 172)
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
        }
        .frame(height: 62)
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    private func metric(_ label: String, _ value: String, big: Bool, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
            Text(value)
                .font(.system(size: big ? 16 : 14, weight: .bold))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var separator: some View {
        Rectangle().fill(Color(.separator)).frame(width: 0.5, height: 28)
    }
}

// MARK: - 模块分段控件

/// 五模块分段控件（选中项 systemBackground + 圆角 6 + 阴影，未选中文字灰；
/// 持仓 / 在途委托数量以红色小胶囊角标显示）
struct SimModuleSegmentedBar: View {
    @Binding var module: SimModuleTab
    let accountID: UUID?

    @ObservedObject private var store = SimStore.shared

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SimModuleTab.allCases) { tab in
                Button(action: { module = tab }) {
                    HStack(spacing: 5) {
                        Text(tab.title)
                            .font(.system(size: 12.5, weight: module == tab ? .semibold : .regular))
                            .foregroundColor(module == tab ? Color.primary : Color(.secondaryLabel))
                        if let count = badgeCount(tab), count > 0 {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Color.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color(.systemRed)))
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(module == tab ? Color(.systemBackground) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(module == tab ? Color(.separator) : Color.clear, lineWidth: 0.5))
                    .shadow(color: module == tab ? Color.black.opacity(0.08) : Color.clear,
                            radius: 2, x: 0, y: 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
    }

    /// 角标数量：持仓数 / 在途委托数（其余模块无角标）
    private func badgeCount(_ tab: SimModuleTab) -> Int? {
        switch tab {
        case .position: return store.positions(accountID: accountID).count
        case .order:    return store.activeOrders(accountID: accountID).count
        default:        return nil
        }
    }
}

// MARK: - 操作日志模块筛选条

/// 操作日志模块筛选条：全部 / 委托 / 成交 / 撤单 / 改价 / 资金 / 账户 / 提醒 / 条件单
/// （三个布局共用一份；选中 nil 表示「全部」）
struct SimLogModuleFilterBar: View {
    @Binding var selected: ActionModule?

    /// ActionModule 未实现 CaseIterable（不改动 SimModels.swift），此处按标题顺序手写一份
    private static let all: [ActionModule] = [.order, .fill, .cancel, .amend,
                                              .cash, .account, .alert, .condition]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", value: nil)
                ForEach(Self.all, id: \.rawValue) { module in
                    chip(title: module.title, value: module)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(minHeight: 44)
    }

    /// 单个筛选 chip：选中 = 蓝字 + 1pt 蓝边 + 蓝底 8%；未选中 = 灰字 + 0.5pt 分隔线边
    private func chip(title: String, value: ActionModule?) -> some View {
        let isSelected = selected == value
        return Button(action: { selected = value }) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? Color.blue : Color(.secondaryLabel))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.blue.opacity(0.08) : Color(.secondarySystemBackground)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.blue : Color(.separator),
                            lineWidth: isSelected ? 1 : 0.5))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 业务模块表格

/// 业务模块表格：按 module 切换五张表（表头吸顶 + 数据行懒加载，不用 Table）
struct SimModuleTable: View {
    let module: SimModuleTab
    let accountID: UUID?
    /// 行内「买 / 卖」回调（持仓表用）；由父视图打开全屏下单页
    let onTrade: (SimPosition, SimOrderDirection) -> Void
    /// 委托表「改价」回调
    var onAmend: (SimOrder) -> Void = { _ in }
    /// 持仓表行内「条件单」回调（默认止盈止损、卖出方向、成本价预填）；由父视图打开条件单编辑器
    var onCondition: (SimPosition) -> Void = { _ in }
    /// 搜索关键词：持仓 / 委托 / 成交表过滤标的名称或代码，流水表过滤说明，日志表过滤操作内容
    var keyword: String = ""
    /// 操作日志的模块筛选：nil = 全部（仅 module == .log 时生效）
    var logModuleFilter: ActionModule? = nil

    @ObservedObject private var store = SimStore.shared
    @ObservedObject private var rowCache = MarketRowCache.shared

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if isEmpty {
                Spacer(minLength: 0)
                Text(emptyText)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(.tertiaryLabel))
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                listBody
            }
            if module == .log {
                Text("共 \(logRows.count) 条操作记录 · 滚动加载更早记录")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // MARK: 数据

    private var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchesKeyword(_ name: String, _ code: String) -> Bool {
        let key = trimmedKeyword
        guard !key.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(key) || code.localizedCaseInsensitiveContains(key)
    }

    private var positionRows: [SimPosition] {
        store.positions(accountID: accountID).filter { matchesKeyword($0.name, $0.code) }
    }

    private var orderRows: [SimOrder] {
        store.orders(accountID: accountID).filter { matchesKeyword($0.name, $0.code) }
    }

    private var fillRows: [SimFill] {
        store.fills(accountID: accountID).filter { matchesKeyword($0.name, $0.code) }
    }

    private var ledgerRows: [LedgerEntry] {
        let key = trimmedKeyword
        guard !key.isEmpty else { return store.ledgerEntries(accountID: accountID) }
        return store.ledgerEntries(accountID: accountID).filter {
            $0.note.localizedCaseInsensitiveContains(key) || $0.kind.title.contains(key)
        }
    }

    private var logRows: [ActionLog] {
        let key = trimmedKeyword
        var all = store.actionLogs(accountID: accountID)
        if let filter = logModuleFilter {
            all = all.filter { $0.module == filter }
        }
        guard !key.isEmpty else { return all }
        return all.filter { $0.content.localizedCaseInsensitiveContains(key) }
    }

    private var isEmpty: Bool {
        switch module {
        case .position: return positionRows.isEmpty
        case .order:    return orderRows.isEmpty
        case .fill:     return fillRows.isEmpty
        case .cash:     return ledgerRows.isEmpty
        case .log:      return logRows.isEmpty
        }
    }

    private var emptyText: String {
        switch module {
        case .position: return "暂无持仓"
        case .order:    return "暂无委托"
        case .fill:     return "暂无成交"
        case .cash:     return "暂无资金流水"
        case .log:      return "暂无操作日志"
        }
    }

    // MARK: 表头

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            switch module {
            case .position:
                headCell("名称/代码", width: PosCol.name)
                headCell("持仓", width: PosCol.qty, align: .trailing)
                headCell("可用", width: PosCol.available, align: .trailing)
                headCell("成本价", width: PosCol.cost, align: .trailing)
                headCell("现价", width: PosCol.last, align: .trailing)
                headCell("持仓市值", width: PosCol.marketValue, align: .trailing)
                headCell("盈亏", width: PosCol.profit, align: .trailing)
                headCell("盈亏%", width: PosCol.profitPct, align: .trailing)
                headCell("操作", width: PosCol.action, align: .trailing)
            case .order:
                headCell("时间", width: OrdCol.time)
                headCell("名称", width: OrdCol.name)
                headCell("方向", width: OrdCol.direction)
                headCell("类型", width: OrdCol.type)
                headCell("委托价", width: OrdCol.price, align: .trailing)
                headCell("委托量", width: OrdCol.qty, align: .trailing)
                headCell("已成", width: OrdCol.filled, align: .trailing)
                headCell("状态", width: OrdCol.status)
                headCell("操作", width: OrdCol.action, align: .trailing)
            case .fill:
                headCell("成交时间", width: FillCol.time)
                headCell("名称", width: FillCol.name)
                headCell("方向", width: FillCol.direction)
                headCell("成交价", width: FillCol.price, align: .trailing)
                headCell("成交量", width: FillCol.qty, align: .trailing)
                headCell("成交额", width: FillCol.amount, align: .trailing)
                headCell("费用", width: FillCol.fee, align: .trailing)
                headCell("合同编号", width: FillCol.contract)
            case .cash:
                headCell("时间", width: CashCol.time)
                headCell("类型", width: CashCol.kind)
                headCell("说明", width: CashCol.note)
                headCell("发生额", width: CashCol.amount, align: .trailing)
                headCell("账户余额", width: CashCol.balance, align: .trailing)
                headCell("账户", width: CashCol.account)
            case .log:
                headCell("时间", width: LogCol.time)
                headCell("账户", width: LogCol.account)
                headCell("模块", width: LogCol.module)
                headCell("操作内容", width: LogCol.content)
                headCell("结果", width: LogCol.result)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    // MARK: 列表

    @ViewBuilder
    private var listBody: some View {
        switch module {
        case .position:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(positionRows) { positionRow($0) }
                }
            }
        case .order:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(orderRows) { orderRow($0) }
                }
            }
        case .fill:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(fillRows) { fillRow($0) }
                }
            }
        case .cash:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(ledgerRows) { ledgerRow($0) }
                }
            }
        case .log:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(logRows) { logRow($0) }
                }
            }
        }
    }

    // MARK: 数据行

    /// 持仓：名称/代码 | 持仓 | 可用 | 成本价 | 现价 | 持仓市值 | 盈亏 | 盈亏% | 操作
    private func positionRow(_ position: SimPosition) -> some View {
        let snapshot = store.snapshot(for: position)
        let lastColor = rowCache.colorFor(position.metaID, .changePct)
        return dataRow {
            nameCell(position.name, position.code, width: PosCol.name)
            textCell(SimFormat.shares(position.qty), width: PosCol.qty, align: .trailing)
            textCell(SimFormat.shares(position.availableQty), width: PosCol.available, align: .trailing,
                     color: position.availableQty > 0 ? Color.primary : Color(.secondaryLabel))
            textCell(SimFormat.price(position.costPrice), width: PosCol.cost, align: .trailing)
            textCell(SimFormat.price(snapshot.lastPrice), width: PosCol.last, align: .trailing, color: lastColor)
            textCell(SimFormat.amount0(snapshot.marketValue), width: PosCol.marketValue, align: .trailing)
            textCell(SimFormat.signed0(snapshot.profit), width: PosCol.profit, align: .trailing,
                     color: simProfitColor(snapshot.profit))
            textCell(SimFormat.pct(snapshot.profitPct * 100), width: PosCol.profitPct, align: .trailing,
                     color: simProfitColor(snapshot.profit))
            HStack(spacing: 6) {
                SimInlineButton(title: "买", tint: Color(.systemRed)) { onTrade(position, .buy) }
                SimInlineButton(title: "卖", tint: Color(.systemGreen)) { onTrade(position, .sell) }
                SimInlineButton(title: "条件单", tint: .blue) { onCondition(position) }
            }
            .frame(width: PosCol.action, alignment: .trailing)
        }
    }

    /// 当日委托：时间 | 名称 | 方向 | 类型 | 委托价 | 委托量 | 已成 | 状态 | 操作
    private func orderRow(_ order: SimOrder) -> some View {
        dataRow {
            textCell(SimFormat.time(order.createdAt), width: OrdCol.time, color: Color(.secondaryLabel))
            nameCell(order.name, order.code, width: OrdCol.name)
            SimDirectionTag(direction: order.direction)
                .frame(width: OrdCol.direction, alignment: .leading)
            textCell(order.priceType.title, width: OrdCol.type, color: Color(.secondaryLabel))
            textCell(order.price.map { SimFormat.price($0) } ?? "—",
                     width: OrdCol.price, align: .trailing,
                     color: order.price == nil ? Color(.secondaryLabel) : Color.primary)
            textCell(SimFormat.shares(order.qty), width: OrdCol.qty, align: .trailing)
            textCell(SimFormat.shares(order.filledQty), width: OrdCol.filled, align: .trailing,
                     color: order.filledQty > 0 ? Color.primary : Color(.secondaryLabel))
            SimStatusTag(status: order.status)
                .frame(width: OrdCol.status, alignment: .leading)
            HStack(spacing: 6) {
                if order.status.isActive {
                    SimInlineButton(title: "撤单", tint: Color(.secondaryLabel)) {
                        store.cancelOrder(id: order.id)
                    }
                    SimInlineButton(title: "改价", tint: .blue) { onAmend(order) }
                }
            }
            .frame(width: OrdCol.action, alignment: .trailing)
        }
    }

    /// 当日成交：成交时间 | 名称 | 方向 | 成交价 | 成交量 | 成交额 | 费用 | 合同编号
    private func fillRow(_ fill: SimFill) -> some View {
        dataRow {
            textCell(SimFormat.time(fill.tradedAt), width: FillCol.time, color: Color(.secondaryLabel))
            nameCell(fill.name, fill.code, width: FillCol.name)
            SimDirectionTag(direction: fill.direction)
                .frame(width: FillCol.direction, alignment: .leading)
            textCell(SimFormat.price(fill.price), width: FillCol.price, align: .trailing)
            textCell(SimFormat.shares(fill.qty), width: FillCol.qty, align: .trailing)
            textCell(SimFormat.amount(fill.amount), width: FillCol.amount, align: .trailing)
            textCell(SimFormat.amount(fill.fee), width: FillCol.fee, align: .trailing,
                     color: Color(.secondaryLabel))
            textCell(fill.contractNo, width: FillCol.contract, color: Color(.secondaryLabel))
        }
    }

    /// 资金流水：时间 | 类型 | 说明 | 发生额 | 账户余额 | 账户
    private func ledgerRow(_ entry: LedgerEntry) -> some View {
        dataRow {
            textCell(SimFormat.dateTime(entry.occurredAt), width: CashCol.time, color: Color(.secondaryLabel))
            textCell(entry.kind.title, width: CashCol.kind)
            textCell(entry.note, width: CashCol.note, color: Color(.secondaryLabel))
            textCell(SimFormat.signed(entry.amount), width: CashCol.amount, align: .trailing,
                     color: simProfitColor(entry.amount))
            textCell(SimFormat.amount(entry.balanceAfter), width: CashCol.balance, align: .trailing)
            textCell(store.accountName(id: entry.accountID), width: CashCol.account,
                     color: Color(.secondaryLabel))
        }
    }

    /// 操作日志：时间 | 账户 | 模块 | 操作内容 | 结果
    private func logRow(_ log: ActionLog) -> some View {
        dataRow {
            textCell(SimFormat.dateTime(log.occurredAt), width: LogCol.time, color: Color(.secondaryLabel))
            textCell(logAccountName(log.accountID), width: LogCol.account, color: Color(.secondaryLabel))
            textCell(log.module.title, width: LogCol.module)
            textCell(log.content, width: LogCol.content)
            textCell(log.result, width: LogCol.result, color: simResultColor(log.result))
        }
    }

    /// 日志账户名（accountID 为 nil 的全局事件显示「系统」）
    private func logAccountName(_ id: UUID?) -> String {
        guard let id = id else { return "系统" }
        return store.accountName(id: id)
    }

    // MARK: 单元格

    private func dataRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(.separator)).frame(height: 0.5)
            }
    }

    private func headCell(_ text: String, width: CGFloat, align: Alignment = .leading) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(Color(.secondaryLabel))
            .lineLimit(1)
            .frame(width: width, alignment: align)
    }

    private func textCell(_ text: String, width: CGFloat, align: Alignment = .leading,
                          color: Color = Color.primary, size: CGFloat = 12.5,
                          weight: Font.Weight = .regular) -> some View {
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, alignment: align)
    }

    /// 名称（主）+ 代码（副）双行单元格
    private func nameCell(_ name: String, _ code: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(Color.primary)
                .lineLimit(1)
            Text(code)
                .font(.system(size: 10))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
}

// MARK: - 列宽（按可用宽 1024 - 216 = 808pt 折算；表头与数据行共用，保证对齐）

private enum PosCol {
    static let name: CGFloat = 110
    static let qty: CGFloat = 72
    static let available: CGFloat = 64
    static let cost: CGFloat = 80
    static let last: CGFloat = 80
    static let marketValue: CGFloat = 92
    static let profit: CGFloat = 86
    static let profitPct: CGFloat = 76
    /// 买 / 卖 / 条件单 三个行内小按钮并排
    static let action: CGFloat = 122
}

private enum OrdCol {
    static let time: CGFloat = 74
    static let name: CGFloat = 190
    static let direction: CGFloat = 52
    static let type: CGFloat = 50
    static let price: CGFloat = 78
    static let qty: CGFloat = 72
    static let filled: CGFloat = 64
    static let status: CGFloat = 58
    static let action: CGFloat = 146
}

private enum FillCol {
    static let time: CGFloat = 80
    static let name: CGFloat = 184
    static let direction: CGFloat = 60
    static let price: CGFloat = 86
    static let qty: CGFloat = 82
    static let amount: CGFloat = 108
    static let fee: CGFloat = 82
    static let contract: CGFloat = 102
}

private enum CashCol {
    static let time: CGFloat = 84
    static let kind: CGFloat = 72
    static let note: CGFloat = 288
    static let amount: CGFloat = 112
    static let balance: CGFloat = 118
    static let account: CGFloat = 110
}

private enum LogCol {
    static let time: CGFloat = 84
    static let account: CGFloat = 116
    static let module: CGFloat = 68
    static let content: CGFloat = 384
    static let result: CGFloat = 132
}

// MARK: - 底部买卖条

/// 底部常驻买入 / 卖出条（左侧规则提示，右侧买入红 / 卖出绿）
struct SimBottomActionBar: View {
    let onTrade: (SimOrderDirection) -> Void
    /// 左侧提示文案，默认 T+1 / 佣金 / 印花税说明
    var hint: String = "T+1：当日买入次日可卖 ｜ 佣金万 2.5、最低 5 元 ｜ 卖出印花税千一"

    var body: some View {
        HStack(spacing: 12) {
            Text(hint)
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            actionButton("买入", color: Color(.systemRed)) { onTrade(.buy) }
            actionButton("卖出", color: Color(.systemGreen)) { onTrade(.sell) }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    private func actionButton(_ title: String, color: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(Color.white)
                .frame(width: 120, height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(color))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.bottomAction.\(title)")
    }
}

// MARK: - 全屏下单页

/// 全屏下单页（.fullScreenCover 内容）：复用 TradeTicketView 的 full 形态
struct SimFullScreenTicket: View {
    let request: SimTicketRequest
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("模拟下单")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color.primary)
                Text("\(request.name) \(request.code)")
                    .font(.system(size: 12))
                    .foregroundColor(Color(.secondaryLabel))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(.secondaryLabel))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("simTicket.close")
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(.separator)).frame(height: 0.5)
            }

            ScrollView {
                TradeTicketView(style: .full,
                                accountID: request.accountID,
                                metaID: request.metaID,
                                code: request.code,
                                name: request.name,
                                initialDirection: request.direction,
                                initialPriceType: .limit,
                                initialQty: 100) { _ in
                    // 提交成功后关闭全屏页
                    onClose()
                }
                .padding(.vertical, 12)
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}

extension View {
    /// 便捷修饰器：`content.simFullScreenTicket($request)`
    func simFullScreenTicket(_ request: Binding<SimTicketRequest?>) -> some View {
        fullScreenCover(item: request) { req in
            SimFullScreenTicket(request: req) { request.wrappedValue = nil }
        }
    }
}

// MARK: - 条件单入口呈现

/// 条件单入口的呈现请求（管理页 / 编辑器二选一）。
/// 同一页面里的两个入口（工具栏、持仓行）共用一份 @State 与一个 .fullScreenCover：
/// iOS 15 上同一宿主视图叠加多个 fullScreenCover 会相互压制，故用单一呈现状态收敛。
enum SimCondEntryRequest: Identifiable {
    /// 打开条件单管理页（携带 UUID，保证可重复呈现）
    case list(UUID)
    /// 打开条件单编辑器（请求自带 UUID）
    case editor(SimCondEditorRequest)

    var id: UUID {
        switch self {
        case .list(let id):    return id
        case .editor(let req): return req.id
        }
    }
}

extension View {
    /// 便捷修饰器：`content.simCondEntryPresentation($request, accountID: ...)`
    func simCondEntryPresentation(_ request: Binding<SimCondEntryRequest?>,
                                  accountID: UUID?) -> some View {
        fullScreenCover(item: request) { item in
            switch item {
            case .list(_):
                SimCondListView(accountID: accountID,
                                onClose: { request.wrappedValue = nil })
            case .editor(let req):
                SimCondEditorView(accountID: req.accountID, metaID: req.metaID,
                                  code: req.code, name: req.name,
                                  initialKind: req.initialKind,
                                  initialDirection: req.initialDirection,
                                  initialQty: req.initialQty,
                                  initialPrice: req.initialPrice,
                                  editing: req.editing) { request.wrappedValue = nil }
            }
        }
    }
}

// MARK: - 策略公式入口

/// 工具栏「策略公式」入口按钮：模拟页三个布局（A / B / C）共用，
/// 置于各自工具栏既有的「条件单」入口旁，点击打开公式管理中心的「交易策略」段。
/// 视觉令牌与各布局工具栏「条件单」入口完全对齐（12.5pt semibold + 语义蓝 + 44×44 命中区），
/// 不加内边距与圆角描边，以免撑高 44pt 工具栏行、挤压既有按钮。
/// 边界：只出现在模拟页三个布局的工具栏；K 线图页 / 行情页 / 个人中心不出现本入口
/// （行情页的公式入口另接「选股指标」段，与本入口互不影响）。
struct SimStrategyFormulaEntryButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("策略公式")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.blue)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.strategyFormula.entry")
    }
}

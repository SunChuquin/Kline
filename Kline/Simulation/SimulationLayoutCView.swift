//
//  SimulationLayoutCView.swift
//  Kline
//
//  模拟页布局方案 C：券商经典顶栏式（最接近通达信 / 同花顺 iPad）。
//  顶部条（标题 / 账户下拉 chip / 资金与设置）→ 一行资产指标（七项等宽）
//  → 模块行（分段控件 + 搜索 + 刷新）→ 全宽大表 → 在途委托 / 当日成交两个小卡
//  → 底部买卖条；多账户收进顶部下拉，表格宽度最大。
//  复用 SimSharedViews 的共享组件；iOS 15 兼容，背景一律语义色（支持深色模式）。
//

import SwiftUI

struct SimulationLayoutCView: View {
    @ObservedObject private var store = SimStore.shared
    @ObservedObject private var db = DatabaseManager.shared

    /// 当前业务模块
    @State private var module: SimModuleTab = .position
    /// 表格搜索词
    @State private var keyword = ""
    /// 操作日志模块筛选（nil = 全部；仅日志模块显示筛选条）
    @State private var logModule: ActionModule? = nil
    /// 全屏下单请求（每次新建都换新 UUID，保证可重复呈现）
    @State private var ticketRequest: SimTicketRequest? = nil
    /// 条件单呈现请求（工具栏入口 → 管理页；持仓行入口 → 编辑器，二者共用一个呈现状态）
    @State private var condPresentation: SimCondEntryRequest? = nil
    /// 改价目标委托
    @State private var amendTarget: SimOrder? = nil
    @State private var amendPriceText = ""
    /// 交易规则弹窗（设置）
    @State private var showRulesAlert = false
    /// 轻提示（资金概览 / 刷新结果等，2 秒后自动消失）
    @State private var toast: String? = nil

    private static let rulesText = """
    T+1：当日买入次日可卖
    佣金万 2.5，最低 5 元
    卖出印花税千一
    涨跌停 ±10%
    盘后委托转为待报
    """

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            topBar
            metricsRow
            moduleRow
            if module == .log {
                SimLogModuleFilterBar(selected: $logModule)
            }
            SimModuleTable(module: module,
                           accountID: store.queryAccountID,
                           onTrade: { position, direction in
                               openTicket(accountID: position.accountID,
                                          metaID: position.metaID,
                                          code: position.code,
                                          name: position.name,
                                          direction: direction)
                           },
                           onAmend: { order in beginAmend(order) },
                           onCondition: { position in openCondEditor(for: position) },
                           keyword: keyword,
                           logModuleFilter: module == .log ? logModule : nil)
                .frame(maxHeight: .infinity)
            bottomCardsRow
            SimBottomActionBar(onTrade: { openBottomTicket($0) },
                               hint: "最接近通达信 / 同花顺 iPad 的经典布局，表格最宽；多账户收进顶部下拉")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { toastView }
        .simFullScreenTicket($ticketRequest)
        .alert("修改委托价", isPresented: amendBinding) {
            TextField("委托价", text: $amendPriceText)
                .keyboardType(.decimalPad)
            Button("确认") { confirmAmend() }
            Button("取消", role: .cancel) { amendTarget = nil }
        } message: {
            Text(amendTarget.map {
                "\($0.name) \($0.code) · 当前 \($0.price.map { SimFormat.price($0) } ?? "市价")"
            } ?? "")
        }
        .onAppear { SimStore.shared.prepareQuotes() }
    }

    // MARK: - 顶部条

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("模拟交易")
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(Color.primary)
            Spacer(minLength: 8)
            accountChip
            Spacer(minLength: 8)
            smallActionButton(icon: "wallet.pass", title: "资金") { showWalletInfo() }
            smallActionButton(icon: "gear", title: "设置") { showRulesAlert = true }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
        // 交易规则详情（与根视图的「修改委托价」弹窗分开挂载，避免同视图多 alert 冲突）
        .alert("交易规则", isPresented: $showRulesAlert) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text(Self.rulesText)
        }
    }

    /// 账户下拉 chip：列出「全部账户汇总」+ 各可用账户
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

    private func smallActionButton(icon: String, title: String,
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

    // MARK: - 资产指标行

    private var metricsRow: some View {
        let summary = store.summary(accountID: store.queryAccountID)
        let pendingCount = store.activeOrders(accountID: store.queryAccountID).count
        return HStack(spacing: 0) {
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
        .padding(.horizontal, 12)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
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

    // MARK: - 模块行

    private var moduleRow: some View {
        HStack(spacing: 10) {
            SimModuleSegmentedBar(module: $module, accountID: store.queryAccountID)
            Spacer(minLength: 8)
            condEntryButton
            searchBox
            refreshButton
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
        // 条件单全屏呈现挂在本行（与根视图的全屏下单页分开宿主，避免同视图多个 fullScreenCover）
        .simCondEntryPresentation($condPresentation, accountID: store.queryAccountID)
    }

    /// 工具栏「条件单」入口（文字右上角叠监控中数量角标）
    private var condEntryButton: some View {
        let monitoring = store.condCounts(accountID: store.queryAccountID).monitoring
        return Button(action: { condPresentation = .list(UUID()) }) {
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

    private var searchBox: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
            TextField("搜索标的名称/代码", text: $keyword)
                .font(.system(size: 11.5))
                .foregroundColor(Color.primary)
                .frame(width: 148)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemBackground)))
    }

    private var refreshButton: some View {
        Button(action: { refreshQuotes() }) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
                Text("刷新").font(.system(size: 11.5))
            }
            .foregroundColor(Color(.secondaryLabel))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(.separator), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 在途委托 / 当日成交

    private var bottomCardsRow: some View {
        HStack(spacing: 10) {
            pendingCard
            fillsCard
        }
        .padding(EdgeInsets(top: 6, leading: 14, bottom: 0, trailing: 14))
    }

    /// 左卡：在途委托（最多 2 行 + 撤单）
    private var pendingCard: some View {
        let all = store.activeOrders(accountID: store.queryAccountID)
        let list = Array(all.prefix(2))
        return VStack(spacing: 0) {
            cardTitleRow("在途委托", count: all.count, unit: "")
            if list.isEmpty {
                emptyCardHint("暂无在途委托")
            } else {
                ForEach(list) { pendingRow($0) }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 110, alignment: .top)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 1))
    }

    /// 右卡：当日成交（最多 3 行）
    private var fillsCard: some View {
        let all = store.fills(accountID: store.queryAccountID)
        let list = Array(all.prefix(3))
        return VStack(spacing: 0) {
            cardTitleRow("当日成交", count: all.count, unit: " 笔")
            if list.isEmpty {
                emptyCardHint("暂无成交")
            } else {
                ForEach(list) { fillCardRow($0) }
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
                store.cancelOrder(id: order.id)
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

    // MARK: - 下单入口

    /// 下单账户：具体账户优先；「全部账户汇总」时取第一个可用账户
    private var orderAccountID: UUID? {
        if let id = store.queryAccountID, store.account(id: id) != nil { return id }
        return store.activeAccounts.first?.id
    }

    /// 下单标的：优先该账户第一只持仓，无持仓时取数据库第一只标的
    private func defaultTarget(accountID: UUID) -> (metaID: Int, code: String, name: String)? {
        if let position = store.positions(accountID: accountID).first {
            return (position.metaID, position.code, position.name)
        }
        if let meta = db.metaList.first {
            return (meta.id, meta.code, meta.name)
        }
        return nil
    }

    private func openTicket(accountID: UUID, metaID: Int, code: String, name: String,
                            direction: SimOrderDirection) {
        ticketRequest = SimTicketRequest(accountID: accountID, metaID: metaID,
                                         code: code, name: name, direction: direction)
    }

    /// 持仓行「条件单」入口：默认止盈止损 / 卖出，数量取可卖整手，基准价预填成本价
    private func openCondEditor(for position: SimPosition) {
        let rules = SimTradingRules.default
        let qty = rules.sellableQty(position: position)
        condPresentation = .editor(SimCondEditorRequest(accountID: position.accountID,
                                                        metaID: position.metaID,
                                                        code: position.code,
                                                        name: position.name,
                                                        initialKind: .stopLoss,
                                                        initialDirection: .sell,
                                                        initialQty: qty > 0 ? qty : rules.lotSize,
                                                        initialPrice: position.costPrice,
                                                        editing: nil))
    }

    private func openBottomTicket(_ direction: SimOrderDirection) {
        guard let accountID = orderAccountID else {
            showToast("请先在顶部下拉新建一个模拟账户")
            return
        }
        guard let target = defaultTarget(accountID: accountID) else {
            showToast("暂无可用标的，无法下单")
            return
        }
        openTicket(accountID: accountID, metaID: target.metaID, code: target.code,
                   name: target.name, direction: direction)
    }

    // MARK: - 改价

    private var amendBinding: Binding<Bool> {
        Binding(get: { amendTarget != nil },
                set: { if !$0 { amendTarget = nil } })
    }

    private func beginAmend(_ order: SimOrder) {
        amendPriceText = order.price.map { SimFormat.price($0) } ?? ""
        amendTarget = order
    }

    private func confirmAmend() {
        guard let order = amendTarget else { return }
        let price = Double(amendPriceText.filter { $0.isNumber || $0 == "." }) ?? 0
        guard price > 0 else {
            showToast("请输入有效的委托价")
            return
        }
        store.amendOrderPrice(id: order.id, newPrice: price)
        amendTarget = nil
        showToast("已改价：\(order.name) → \(SimFormat.price(price))")
    }

    // MARK: - 顶部动作

    /// 资金：提示当前选中口径的资产概览
    private func showWalletInfo() {
        let summary = store.summary(accountID: store.queryAccountID)
        showToast("可用 \(SimFormat.amount0(summary.cash)) ｜ 市值 \(SimFormat.amount0(summary.marketValue)) ｜ 总资产 \(SimFormat.amount0(summary.totalAssets))")
    }

    private func refreshQuotes() {
        store.prepareQuotes()
        showToast("已请求最新行情")
    }

    // MARK: - 助手

    /// 盈亏配色（涨红跌绿）
    private func profitColor(_ value: Double) -> Color {
        value < 0 ? Color(.systemGreen) : Color(.systemRed)
    }

    @ViewBuilder
    private var toastView: some View {
        if let text = toast {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemBackground)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 0.5))
                .padding(.top, 6)
        }
    }

    /// 轻提示：2 秒后自动消失
    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if toast == text { toast = nil }
        }
    }
}

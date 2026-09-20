//
//  SimulationLayoutBView.swift
//  Kline
//
//  模拟页布局方案 B：账户卡片横排 + 模块宫格。
//  顶部条（标题 / 操作提示 / 资金管理）→ 账户卡片横排（全部汇总 / 各账户 / 新建账户）
//  → 四张模块卡宫格（持仓 / 当日委托 / 当日成交 / 历史中心，卡内只放摘要与快捷动作）
//  → 底部买卖条；点模块卡以全屏明细页呈现完整表格（表格内的买卖 / 改价在本页内处理）。
//  复用 SimSharedViews 的共享组件；iOS 15 兼容，背景一律语义色（支持深色模式）。
//

import SwiftUI

struct SimulationLayoutBView: View {
    @ObservedObject private var store = SimStore.shared
    @ObservedObject private var db = DatabaseManager.shared

    /// 全屏明细模块（SimModuleTab 已是 Identifiable，可直接用于 fullScreenCover(item:)）
    @State private var detailModule: SimModuleTab? = nil
    /// 全屏下单请求（每次新建都换新 UUID，保证可重复呈现）
    @State private var ticketRequest: SimTicketRequest? = nil
    /// 条件单呈现请求（顶部条入口 → 管理页）
    @State private var condPresentation: SimCondEntryRequest? = nil
    /// 新建账户
    @State private var showCreateAccount = false
    @State private var newAccountName = ""
    @State private var newAccountCapital = "100000"
    /// 资金管理弹窗
    @State private var showWalletAlert = false
    /// 轻提示（下单拦截 / 创建成功等，2 秒后自动消失）
    @State private var toast: String? = nil

    /// 账户卡片统一尺寸（全部汇总 / 各账户 / 新建账户三态对齐）
    private let cardWidth: CGFloat = 218
    private let cardHeight: CGFloat = 104
    private let newCardWidth: CGFloat = 150

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            topBar
            accountStrip
            moduleGrid
            SimBottomActionBar(onTrade: { openBottomTicket($0) },
                               hint: "模块卡只放摘要与快捷动作，明细进入全屏列表")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { toastView }
        .simFullScreenTicket($ticketRequest)
        .fullScreenCover(item: $detailModule) { module in
            SimModuleDetailSheet(module: module,
                                 accountID: store.queryAccountID,
                                 onClose: { detailModule = nil })
        }
        .onAppear { SimStore.shared.prepareQuotes() }
    }

    /// 顶部条「条件单」入口（文字右上角叠监控中数量角标）
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

    // MARK: - 顶部条

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("模拟交易")
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(Color.primary)
            Text("点账户卡进入该账户，点模块卡进入明细")
                .font(.system(size: 11.5))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            condEntryButton
            Button(action: { showWalletAlert = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "wallet.pass").font(.system(size: 11))
                    Text("资金管理").font(.system(size: 12))
                }
                .foregroundColor(.blue)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.5), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
        .alert("资金管理", isPresented: $showWalletAlert) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text(walletMessage)
        }
    }

    /// 资金管理弹窗文案：当前选中口径的资产概览
    private var walletMessage: String {
        let summary = store.summary(accountID: store.queryAccountID)
        let name = store.accountName(id: store.queryAccountID)
        return """
        \(name)
        总资产 \(SimFormat.amount0(summary.totalAssets)) 元
        可用资金 \(SimFormat.amount0(summary.cash)) 元
        持仓市值 \(SimFormat.amount0(summary.marketValue)) 元
        持仓占比 \(SimFormat.pct(summary.positionPct * 100))
        当日盈亏 \(SimFormat.signed0(summary.dayProfit)) 元
        累计盈亏 \(SimFormat.signed0(summary.totalProfit)) 元
        """
    }

    // MARK: - 账户卡片横排

    private var accountStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                allAccountsCard
                ForEach(store.activeAccounts) { accountCard($0) }
                newAccountCard
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        }
        .background(Color(.systemBackground))
        .alert("新建账户", isPresented: $showCreateAccount) {
            TextField("账户名称", text: $newAccountName)
            TextField("初始资金", text: $newAccountCapital)
                .keyboardType(.decimalPad)
            Button("创建") { createAccount() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("初始资金默认 100000 元，创建后自动选中该账户。")
        }
    }

    /// 全部账户汇总卡（语义色背景 + 语义色文字）
    private var allAccountsCard: some View {
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

                profitLine(label1: "当日", value1: SimFormat.signed0(summary.dayProfit),
                           sign1: summary.dayProfit,
                           label2: "累计", value2: SimFormat.signed0(summary.totalProfit),
                           sign2: summary.totalProfit,
                           textColor: nil)

                SimSparkline(values: series, tint: Color(.systemRed))
                    .frame(height: 26)
                    .opacity(0.85)
            }
            .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
            .frame(width: cardWidth, height: cardHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color.blue : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.account.all")
    }

    /// 单个账户卡：底色取账户 colorHex，卡内文字用白色（彩色卡面唯一允许写死白色的场景）
    private func accountCard(_ account: SimAccount) -> some View {
        let selected = store.selectedAccountID == account.id
        let summary = store.summary(accountID: account.id)
        let series = store.netValueSeries(accountID: account.id, days: 30)
        return Button(action: { store.selectedAccountID = account.id }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(account.badge)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(colorFromHex(account.colorHex))
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

                profitLine(label1: "当日", value1: SimFormat.signed0(summary.dayProfit),
                           sign1: summary.dayProfit,
                           label2: "累计", value2: SimFormat.pct(summary.totalProfitPct * 100),
                           sign2: summary.totalProfit,
                           textColor: Color.white)

                SimSparkline(values: series, tint: Color.white.opacity(0.9))
            }
            .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
            .frame(width: cardWidth, height: cardHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(colorFromHex(account.colorHex)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Color.blue : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.account.\(account.name)")
    }

    /// 账户卡副行：「当日 +2,841 ｜ 累计 +2.84%」；textColor 为 nil 时用盈亏色
    private func profitLine(label1: String, value1: String, sign1: Double,
                            label2: String, value2: String, sign2: Double,
                            textColor: Color?) -> some View {
        HStack(spacing: 3) {
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

    /// 新建账户卡（虚线边框 + 蓝色文字）
    private var newAccountCard: some View {
        Button(action: { showCreateAccount = true }) {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                Text("新建账户")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundColor(.blue)
            .frame(width: newCardWidth, height: cardHeight)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundColor(Color(.separator)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sim.account.new")
    }

    // MARK: - 模块宫格

    private var moduleGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            positionCard
            orderCard
            fillCard
            logCard
        }
        .padding(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
        .frame(maxHeight: .infinity, alignment: .top)
        // 条件单全屏呈现挂在本宫格（与根视图的全屏下单页 / 明细页分开宿主）
        .simCondEntryPresentation($condPresentation, accountID: store.queryAccountID)
    }

    private var positionCard: some View {
        let list = store.positions(accountID: store.queryAccountID)
        return moduleCard(module: .position, title: "持仓", icon: "chart.bar", iconTint: .blue,
                          badge: "\(list.count) 只",
                          footer: "查看全部 \(list.count) 只 →") {
            if list.isEmpty {
                emptyHint("暂无持仓")
            } else {
                ForEach(Array(list.prefix(3))) { positionSummaryRow($0) }
            }
        }
    }

    private var orderCard: some View {
        let list = store.activeOrders(accountID: store.queryAccountID)
        return moduleCard(module: .order, title: "当日委托", icon: "clock", iconTint: .orange,
                          badge: "\(list.count) 笔在途",
                          footer: "查看全部委托 →") {
            if list.isEmpty {
                emptyHint("暂无在途委托")
            } else {
                ForEach(Array(list.prefix(3))) { orderSummaryRow($0) }
            }
        }
    }

    private var fillCard: some View {
        let list = store.fills(accountID: store.queryAccountID)
        return moduleCard(module: .fill, title: "当日成交", icon: "doc.text",
                          iconTint: Color(.systemGreen),
                          badge: "\(list.count) 笔",
                          footer: "查看全部成交 →") {
            if list.isEmpty {
                emptyHint("暂无成交")
            } else {
                ForEach(Array(list.prefix(3))) { fillSummaryRow($0) }
            }
        }
    }

    private var logCard: some View {
        let list = store.actionLogs(accountID: store.queryAccountID)
        return moduleCard(module: .log, title: "历史中心",
                          icon: "list.bullet", iconTint: Color(.secondaryLabel),
                          badge: "\(list.count) 条",
                          footer: "进入历史中心 →") {
            if list.isEmpty {
                emptyHint("暂无操作日志")
            } else {
                ForEach(Array(list.prefix(3))) { logSummaryRow($0) }
            }
        }
    }

    /// 模块卡外壳：图标 + 标题 + 计数胶囊 + 摘要行 + 底部入口（整卡可点，进入全屏明细）
    private func moduleCard<Rows: View>(module: SimModuleTab, title: String,
                                        icon: String, iconTint: Color,
                                        badge: String, footer: String,
                                        @ViewBuilder rows: () -> Rows) -> some View {
        Button(action: { detailModule = module }) {
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

                rows()

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

    /// 持仓摘要行：名称 + 持仓股数 + 盈亏（按正负着色）
    private func positionSummaryRow(_ position: SimPosition) -> some View {
        let snapshot = store.snapshot(for: position)
        return HStack(spacing: 6) {
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
        .frame(height: 22)
    }

    /// 委托摘要行：方向标签 + 名称 + 委托价量 + 状态标签
    private func orderSummaryRow(_ order: SimOrder) -> some View {
        HStack(spacing: 6) {
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
        .frame(height: 22)
    }

    /// 成交摘要行：时间 + 方向 + 名称 + 成交额
    private func fillSummaryRow(_ fill: SimFill) -> some View {
        HStack(spacing: 6) {
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
        .frame(height: 22)
    }

    /// 历史中心摘要行：时间 + 操作内容 + 结果
    private func logSummaryRow(_ log: ActionLog) -> some View {
        HStack(spacing: 6) {
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
                .foregroundColor(resultColor(log.result))
                .lineLimit(1)
        }
        .frame(height: 22)
    }

    /// 摘要行空态
    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Color(.tertiaryLabel))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 22)
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

    private func openBottomTicket(_ direction: SimOrderDirection) {
        guard let accountID = orderAccountID else {
            showToast("请先新建一个模拟账户")
            return
        }
        guard let target = defaultTarget(accountID: accountID) else {
            showToast("暂无可用标的，无法下单")
            return
        }
        ticketRequest = SimTicketRequest(accountID: accountID,
                                         metaID: target.metaID,
                                         code: target.code,
                                         name: target.name,
                                         direction: direction)
    }

    // MARK: - 账户

    private func createAccount() {
        let name = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let capital = Double(newAccountCapital.filter { $0.isNumber || $0 == "." }) ?? 100_000
        guard capital > 0 else {
            showToast("初始资金需大于 0")
            return
        }
        let account = store.createAccount(name: name.isEmpty ? "新账户" : name,
                                          initialCapital: capital)
        store.selectedAccountID = account.id
        newAccountName = ""
        newAccountCapital = "100000"
        showToast("已创建账户「\(account.name)」")
    }

    // MARK: - 助手

    /// 账户底色：解析 "#RRGGBB"，失败回退 systemGray
    private func colorFromHex(_ hex: String) -> Color {
        Color(hex: hex) ?? Color(.systemGray)
    }

    /// 盈亏配色（涨红跌绿）
    private func profitColor(_ value: Double) -> Color {
        value < 0 ? Color(.systemGreen) : Color(.systemRed)
    }

    /// 操作结果文案配色：成功类绿、在途类橙、其余灰
    private func resultColor(_ text: String) -> Color {
        let success = ["成功", "已成交", "全部成交"]
        let pending = ["部成", "已报", "待报"]
        if success.contains(where: { text.contains($0) }) { return Color(.systemGreen) }
        if pending.contains(where: { text.contains($0) }) { return Color(.orange) }
        return Color(.secondaryLabel)
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

// MARK: - 模块明细全屏页

/// 模块明细全屏页（B 布局内部使用）：顶部条（模块名 + 关闭）+ 搜索框 + 完整表格。
/// 表格内的「买 / 卖」与「改价」在本页内自行呈现全屏下单页与改价弹窗，
/// 避免在已被覆盖的根视图上再次呈现 fullScreenCover。
private struct SimModuleDetailSheet: View {
    let module: SimModuleTab
    let accountID: UUID?
    let onClose: () -> Void

    @ObservedObject private var store = SimStore.shared

    @State private var keyword = ""
    @State private var ticketRequest: SimTicketRequest? = nil
    /// 条件单呈现请求（持仓行入口 → 编辑器）
    @State private var condPresentation: SimCondEntryRequest? = nil
    @State private var amendTarget: SimOrder? = nil
    @State private var amendPriceText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            searchRow
            SimModuleTable(module: module,
                           accountID: accountID,
                           onTrade: { position, direction in
                               ticketRequest = SimTicketRequest(accountID: position.accountID,
                                                                metaID: position.metaID,
                                                                code: position.code,
                                                                name: position.name,
                                                                direction: direction)
                           },
                           onAmend: { order in beginAmend(order) },
                           onCondition: { position in openCondEditor(for: position) },
                           keyword: keyword)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
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
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(module.title)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Color.primary)
            Text(store.accountName(id: accountID))
                .font(.system(size: 11.5))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Text("关闭")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sim.detail.close")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
            TextField("搜索标的名称/代码", text: $keyword)
                .font(.system(size: 12.5))
                .foregroundColor(Color.primary)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        // 条件单全屏呈现挂在本行（与根视图的全屏下单页分开宿主，避免同视图多个 fullScreenCover）
        .simCondEntryPresentation($condPresentation, accountID: accountID)
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

    // MARK: 改价

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
        amendTarget = nil
        guard price > 0 else { return }
        store.amendOrderPrice(id: order.id, newPrice: price)
    }
}

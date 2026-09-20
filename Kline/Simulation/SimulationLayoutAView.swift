//
//  SimulationLayoutAView.swift
//  Kline
//
//  模拟页布局方案 A：账户侧栏 + 工作区。
//  左栏 216pt 固定宽（账户列表 / 新建账户 / 交易规则与账户管理入口），
//  右栏自适应工作区（资产总览带 → 五模块分段 + 工具条 → 模块表格 → 底部买卖条），
//  全屏下单页由 .simFullScreenTicket 呈现。iOS 15 兼容，背景一律语义色。
//

import SwiftUI

struct SimulationLayoutAView: View {
    @ObservedObject private var store = SimStore.shared
    @ObservedObject private var db = DatabaseManager.shared

    /// 当前业务模块
    @State private var module: SimModuleTab = .position
    /// 全屏下单请求（每次新建都换新 UUID，保证可重复呈现）
    @State private var ticketRequest: SimTicketRequest? = nil
    /// 条件单呈现请求（工具栏入口 → 管理页；持仓行入口 → 编辑器，二者共用一个呈现状态）
    @State private var condPresentation: SimCondEntryRequest? = nil
    /// 新建账户
    @State private var showCreateAccount = false
    @State private var newAccountName = ""
    @State private var newAccountCapital = "100000"
    /// 侧栏底部提示（交易规则 / 账户管理说明）
    @State private var sidebarHint: String? = nil
    /// 日志搜索词
    @State private var logKeyword = ""
    /// 其他模块搜索词（标的名称 / 代码）
    @State private var tableKeyword = ""
    /// 改价目标委托
    @State private var amendTarget: SimOrder? = nil
    @State private var amendPriceText = ""
    /// 工作区轻提示（刷新 / 导出 / 拦截提示，2 秒后自动消失）
    @State private var toast: String? = nil

    private let sidebarWidth: CGFloat = 216

    private static let rulesText = """
    T+1：当日买入次日可卖
    佣金万 2.5，最低 5 元
    卖出印花税千一
    涨跌停 ±10%
    盘后委托转为待报
    """

    private static let accountHelpText = "账户管理：点「＋ 新建账户」创建账户；选中账户后在右侧工作区下单、查看流水与日志。"

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 0.5)
            workspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .simFullScreenTicket($ticketRequest)
    }

    // MARK: - 左栏：账户侧栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            Text("账户")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Color(.secondaryLabel))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 12, leading: 16, bottom: 5, trailing: 16))

            ScrollView {
                LazyVStack(spacing: 2) {
                    allAccountsRow
                    ForEach(store.activeAccounts) { accountRow($0) }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }

            newAccountRow

            if let hint = sidebarHint {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
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

    /// 「全部账户汇总」行（聚合视图）
    private var allAccountsRow: some View {
        let selected = store.isAllAccountsSelected
        let summary = store.summary(accountID: nil)
        return Button(action: { store.selectedAccountID = SimStore.allAccountID }) {
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

    /// 单个账户行：色块 + 名称 + 总资产 + 当日盈亏%
    private func accountRow(_ account: SimAccount) -> some View {
        let selected = store.selectedAccountID == account.id
        let summary = store.summary(accountID: account.id)
        return Button(action: { store.selectedAccountID = account.id }) {
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

    private var newAccountRow: some View {
        Button(action: { showCreateAccount = true }) {
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

    private var sidebarBottomActions: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
            bottomActionRow(icon: "gear", title: "交易规则设置") {
                sidebarHint = Self.rulesText
            }
            bottomActionRow(icon: "doc.text", title: "账户管理") {
                sidebarHint = Self.accountHelpText
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

    // MARK: - 右栏：工作区

    private var workspace: some View {
        VStack(spacing: 0) {
            SimSummaryBand(accountID: store.queryAccountID)
            moduleRow
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
                           keyword: module == .log ? logKeyword : tableKeyword)
                .frame(maxHeight: .infinity)
            SimBottomActionBar(onTrade: { direction in openBottomTicket(direction) },
                               hint: bottomHint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { toastView }
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

    /// 模块行：分段控件 + 右侧工具条（日志模块为筛选/导出，其余为搜索/刷新）
    private var moduleRow: some View {
        HStack(spacing: 10) {
            SimModuleSegmentedBar(module: $module, accountID: store.queryAccountID)
            Spacer(minLength: 8)
            condEntryButton
            if module == .log {
                logToolbar
            } else {
                standardToolbar
            }
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

    private var standardToolbar: some View {
        HStack(spacing: 8) {
            searchBox(text: $tableKeyword, placeholder: "搜索标的名称/代码")
            toolbarButton(icon: "arrow.clockwise", title: "刷新") {
                refreshQuotes()
            }
        }
    }

    private var logToolbar: some View {
        HStack(spacing: 8) {
            toolbarButton(icon: "calendar", title: "近 30 天") {
                showToast("日志范围：近 30 天（更早记录请继续向下滚动加载）")
            }
            toolbarButton(icon: nil, title: "类型 ▾") {
                showToast("类型筛选：全部 / 委托 / 成交 / 撤单 / 改价 / 资金 / 账户 / 提醒")
            }
            searchBox(text: $logKeyword, placeholder: "搜索操作内容")
            toolbarButton(icon: "square.and.arrow.down", title: "导出") {
                exportLogs()
            }
        }
    }

    private func searchBox(text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
            TextField(placeholder, text: text)
                .font(.system(size: 11.5))
                .foregroundColor(Color.primary)
                .frame(width: 148)
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

    // MARK: - 下单入口

    /// 下单账户：具体账户优先；「全部账户汇总」时取第一个可用账户
    private var orderAccountID: UUID? {
        if let id = store.queryAccountID, store.account(id: id) != nil { return id }
        return store.activeAccounts.first?.id
    }

    /// 下单标的：优先当前账户第一只持仓，无持仓时取数据库第一只可用标的
    private func defaultTarget(accountID: UUID) -> (metaID: Int, code: String, name: String)? {
        if let position = store.positions(accountID: accountID).first {
            return (position.metaID, position.code, position.name)
        }
        if let meta = db.metaList.first(where: { !$0.code.isEmpty }) {
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
            showToast("请先在左侧新建一个模拟账户")
            return
        }
        guard let target = defaultTarget(accountID: accountID) else {
            showToast("暂无可用标的，无法下单")
            return
        }
        openTicket(accountID: accountID, metaID: target.metaID, code: target.code,
                   name: target.name, direction: direction)
    }

    /// 底部提示：聚合视图下明确下单账户
    private var bottomHint: String {
        guard store.isAllAccountsSelected else {
            return "T+1：当日买入次日可卖 ｜ 佣金万 2.5、最低 5 元 ｜ 卖出印花税千一"
        }
        let name = store.activeAccounts.first?.name ?? "—"
        return "下单账户：\(name)（切换请点左侧账户） ｜ T+1：当日买入次日可卖 ｜ 佣金万 2.5、最低 5 元"
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

    // MARK: - 账户与行情

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

    private func refreshQuotes() {
        store.prepareQuotes()
        showToast("已请求最新行情")
    }

    // MARK: - 日志导出

    /// 当前筛选条件下的日志（与表格同一口径）
    private var exportableLogs: [ActionLog] {
        let all = store.actionLogs(accountID: store.queryAccountID)
        let key = logKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return all }
        return all.filter { $0.content.localizedCaseInsensitiveContains(key) }
    }

    /// 导出当前日志为 CSV 到 Documents/Simulation/
    private func exportLogs() {
        let logs = exportableLogs
        guard !logs.isEmpty else {
            showToast("当前没有可导出的操作日志")
            return
        }
        let header = "时间,账户,模块,操作内容,结果"
        let lines = logs.map { log -> String in
            let cells = [SimFormat.dateTime(log.occurredAt),
                         logAccountName(log.accountID),
                         log.module.title,
                         log.content,
                         log.result]
            return cells.map(csvCell).joined(separator: ",")
        }
        let content = ([header] + lines).joined(separator: "\n")

        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            showToast("导出失败：无法访问 Documents 目录")
            return
        }
        let dir = docs.appendingPathComponent("Simulation", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "sim_logs_\(formatter.string(from: Date())).csv"
        do {
            try content.write(to: dir.appendingPathComponent(fileName),
                              atomically: true, encoding: .utf8)
            showToast("已导出 \(logs.count) 条日志 → Documents/Simulation/\(fileName)")
        } catch {
            showToast("导出失败：\(error.localizedDescription)")
        }
    }

    private func csvCell(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func logAccountName(_ id: UUID?) -> String {
        guard let id = id else { return "系统" }
        return store.accountName(id: id)
    }

    // MARK: - 助手

    /// 账户色块颜色：解析 "#RRGGBB"，失败回退 systemGray
    private func colorFromHex(_ hex: String) -> Color {
        Color(hex: hex) ?? Color(.systemGray)
    }

    /// 盈亏配色（涨红跌绿）
    private func profitColor(_ value: Double) -> Color {
        value < 0 ? Color(.systemGreen) : Color(.systemRed)
    }

    /// 工作区轻提示：2 秒后自动消失
    private func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if toast == text { toast = nil }
        }
    }
}

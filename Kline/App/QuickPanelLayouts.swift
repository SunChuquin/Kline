//
//  QuickPanelLayouts.swift
//  Kline
//
//  快捷面板三套布局：方案 A（上下文自适应交易卡）的真实实现。
//  方案 B（分页式面板）/ C（闪电下单条）见同目录 QuickPanelLayoutsBC.swift。
//  底部面板容器 FloatingAccessoryPanel 按 TradingLayoutStore.shared.panelLayout
//  分发到这两处（面板只收到 onClose，故分发与取数都由各自文件自行完成）。
//
//  方案 A 按 DetailRouter.shared.item 是否存在分两种上下文：
//  - 详情页态（有标的）：账户条 + 行情头 + 下单卡 + 该股持仓内联 + 快捷动作行；
//  - 列表页态（无标的）：账户摘要 + 四个快捷入口 + 自选迷你列表 + 在途委托块；
//    点行内「买 / 卖」在面板内原地切到下单卡（不关闭面板、不跳页）。
//
//  配色：涨红跌绿；买入 Color(.systemRed)、卖出 Color(.systemGreen)；
//  背景一律语义色（systemBackground / secondarySystemBackground / tertiarySystemBackground /
//  separator），支持深色模式。iOS 15 兼容：不使用 iOS 16+ API。
//

import SwiftUI
import Foundation

// MARK: - 方案 A：上下文自适应交易卡

struct QuickPanelAView: View {
    let onClose: () -> Void

    // MARK: 数据源（均为单例，只在 body / onAppear 等主线程上下文访问）

    @ObservedObject private var store = SimStore.shared
    @ObservedObject private var detailRouter = DetailRouter.shared
    @ObservedObject private var rowCache = MarketRowCache.shared
    @ObservedObject private var fav = FavoritesStore.shared
    @ObservedObject private var dbm = DatabaseManager.shared

    // MARK: 交互状态

    /// 列表态点行内「买 / 卖」带入的标的（非 nil 时面板内容原地切到下单卡）
    @State private var pickedMeta: MetaItem?
    @State private var pickedDirection: SimOrderDirection = .buy
    /// 动作结果反馈（成功绿 / 失败红），3 秒后自动清空
    @State private var actionMessage: String?
    @State private var actionMessageIsError = false
    /// 反馈自动清空令牌：每次新消息自增，使在途的清空作废（防止串消息）
    @State private var messageToken = 0
    /// 一键清仓二次确认
    @State private var showCloseAllConfirm = false

    private var rules: SimTradingRules { SimTradingRules.default }

    var body: some View {
        VStack(spacing: 0) {
            if let item = detailRouter.item {
                detailContext(meta: item)
            } else if let meta = pickedMeta {
                pickedTicketContext(meta: meta)
            } else {
                listContext
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear(perform: handleAppear)
        .confirmationDialog("确认一键清仓 \(detailRouter.item?.name ?? "")？",
                            isPresented: $showCloseAllConfirm,
                            titleVisibility: .visible) {
            Button("确认清仓", role: .destructive) { performCloseAll() }
            Button("取消", role: .cancel) { }
        }
    }

    private func handleAppear() {
        // 注册持仓标的行情预取（幂等，内部会做 T+1 日切）
        store.prepareQuotes()
        // 自选迷你列表的行情预取
        let metas = Array(watchlistMetas.prefix(6))
        if !metas.isEmpty { _ = rowCache.rows(for: metas) }
    }

    // MARK: - 派生数据

    /// 可下单的具体账户 id（「全部账户汇总」或无效账户时为 nil）
    private var concreteAccountID: UUID? {
        guard let id = store.selectedAccountID, id != SimStore.allAccountID,
              store.account(id: id) != nil else { return nil }
        return id
    }

    /// 当前选中口径下的在途委托笔数（快捷入口角标 / 「一键撤单 (N)」）
    private var activeOrderCount: Int {
        store.activeOrders(accountID: store.queryAccountID).count
    }

    /// 自选标的池（写法同 FavoritesView.prefetchAllGroups）
    private var watchlistMetas: [MetaItem] {
        let ids = Set(fav.allGroup.manualMetaIDs)
        return dbm.metaList.filter { ids.contains($0.id) }
    }

    // MARK: - 方案 A：详情页态（有标的）

    @ViewBuilder
    private func detailContext(meta: MetaItem) -> some View {
        VStack(spacing: 0) {
            accountBar
            quoteHeader(meta: meta)

            if let accountID = concreteAccountID {
                // 下单卡：成功后不关闭面板，让用户继续操作
                TradeTicketView(style: .panel,
                                accountID: accountID,
                                metaID: meta.id,
                                code: meta.code,
                                name: meta.name,
                                initialDirection: pickedDirection,
                                initialPriceType: .limit,
                                initialQty: 100,
                                onSubmit: { _ in })
                    .id("quickPanel.ticket.\(meta.id).\(pickedDirection.rawValue)")

                if let position = store.position(accountID: accountID, metaID: meta.id) {
                    positionBlock(position: position)
                }
            } else {
                allAccountsHint
            }

            quickActionRow(meta: meta)
            messageLine
            Spacer(minLength: 12)
        }
    }

    /// 账户条：左账户切换 chip / 中可用资金 / 右交易时段指示
    private var accountBar: some View {
        HStack(spacing: 8) {
            accountMenu {
                HStack(spacing: 4) {
                    Text(store.accountName(id: store.selectedAccountID))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(Color(.secondaryLabel))
                }
                .contentShape(Rectangle())
            }

            Spacer(minLength: 8)

            Text("可用 \(qpAmountText(store.summary(accountID: store.queryAccountID).cash))")
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)

            Spacer(minLength: 8)

            sessionIndicator
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    /// 交易时段指示：盘中红点 + 每秒刷新的连续竞价时钟；非盘中灰点 + 待报提示
    private var sessionIndicator: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            let open = rules.isTradingSession(at: context.date)
            HStack(spacing: 4) {
                Circle()
                    .fill(open ? Color(.systemRed) : Color(.secondaryLabel))
                    .frame(width: 6, height: 6)
                Text(open ? "连续竞价 · \(SimFormat.time(context.date))" : "非交易时段 · 委托将待报")
                    .font(.system(size: 10.5))
                    .foregroundColor(open ? Color(.systemRed) : Color(.secondaryLabel))
                    .lineLimit(1)
            }
        }
    }

    /// 行情头：名称 + 代码 + 最新价 + 涨跌幅（按涨跌色）
    private func quoteHeader(meta: MetaItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(meta.name)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color.primary)
                .lineLimit(1)
            Text(meta.code)
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(rowCache.numberFor(meta.id, .latestPrice).map { SimFormat.price($0) } ?? "—")
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(changeColor(meta.id))
            Text(rowCache.textFor(meta.id, .changePct))
                .font(.system(size: 11))
                .foregroundColor(changeColor(meta.id))
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    /// 该股持仓内联块（仅本账户持有该股时显示）
    private func positionBlock(position: SimPosition) -> some View {
        let snap = store.snapshot(for: position)
        return VStack(spacing: 0) {
            HStack {
                Text("本账户该股持仓")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
                Spacer(minLength: 8)
                Text("成本 \(SimFormat.price(position.costPrice))")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color(.secondarySystemBackground))

            HStack {
                Text("持仓 \(SimFormat.shares(position.qty)) 股 · 可用 \(SimFormat.shares(position.availableQty)) 股")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(SimFormat.signed(snap.profit))（\(SimFormat.pct(snap.profitPct))）")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(profitColor(snap.profit))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(.separator), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// 「全部账户汇总」时不可下单的提示（替代下单卡区域）
    private var allAccountsHint: some View {
        Text("全部账户汇总不可下单，请先在上方选择具体账户")
            .font(.system(size: 12))
            .foregroundColor(Color(.secondaryLabel))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
    }

    /// 快捷动作行：全仓买入 / 一键撤单 (N) / 一键清仓
    private func quickActionRow(meta: MetaItem) -> some View {
        HStack(spacing: 8) {
            actionButton("全仓买入", color: Color(.systemRed)) { performFullBuy(meta: meta) }
            actionButton("一键撤单 (\(activeOrderCount))", color: Color.primary) { performCancelAll() }
            actionButton("一键清仓", color: Color(.systemGreen), compact: true) { showCloseAllConfirm = true }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - 方案 A：列表页态（无标的）

    private var listContext: some View {
        VStack(spacing: 0) {
            accountSummaryArea
            quickEntries
            messageLine
            watchlistSection
            pendingOrdersSection
            Spacer(minLength: 12)
        }
    }

    /// 账户摘要区：左「账户名 + 总资产」卡片（可切换账户）/ 右「当日盈亏 + 可用」两栏
    private var accountSummaryArea: some View {
        let summary = store.summary(accountID: store.queryAccountID)
        return HStack(spacing: 10) {
            accountMenu {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(store.accountName(id: store.selectedAccountID))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color.primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(Color(.secondaryLabel))
                    }
                    Text("总资产 \(qpAmountText(summary.totalAssets))")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color(.systemBackground)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(.separator), lineWidth: 1))
                .contentShape(Rectangle())
            }

            HStack(spacing: 0) {
                VStack(spacing: 2) {
                    Text("当日盈亏")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(.secondaryLabel))
                    Text(SimFormat.signed0(summary.dayProfit))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(profitColor(summary.dayProfit))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 2) {
                    Text("可用")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(.secondaryLabel))
                    Text(qpAmountText(summary.cash))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// 四个快捷入口（无标的上文时给出引导提示）
    private var quickEntries: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            entryButton(icon: "bolt.fill", title: "闪电买入", color: Color(.systemRed)) {
                showMessage("未选择标的：请在下方自选列表点「买」或「卖」", isError: true)
            }
            entryButton(icon: "bolt.fill", title: "闪电卖出", color: Color(.systemGreen)) {
                showMessage("未选择标的：请在下方自选列表点「买」或「卖」", isError: true)
            }
            entryButton(icon: "clock", title: "一键撤单", color: Color.primary, badge: activeOrderCount) {
                performCancelAll()
            }
            entryButton(icon: "wallet.pass", title: "资金 / 转账", color: Color.blue) {
                showMessage("资金管理请到「模拟」Tab", isError: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// 自选迷你列表（最多 6 行，行内「买 / 卖」直接进下单卡）
    private var watchlistSection: some View {
        let metas = Array(watchlistMetas.prefix(6))
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("自选 · 点行内按钮直接下单")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(.secondaryLabel))
                Spacer(minLength: 8)
                Button {
                    showMessage("搜索请到自选 Tab", isError: false)
                } label: {
                    Text("搜索代码 / 名称")
                        .font(.system(size: 11))
                        .foregroundColor(Color.blue)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(height: 26)

            if metas.isEmpty {
                Text("自选为空，请到「自选」Tab 添加标的")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
            } else {
                ForEach(metas) { meta in
                    watchlistRow(meta: meta)
                }
            }
        }
        .padding(.top, 8)
    }

    private func watchlistRow(meta: MetaItem) -> some View {
        HStack(spacing: 6) {
            Text(meta.name)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color.primary)
                .lineLimit(1)
                .frame(width: 74, alignment: .leading)
            Text(meta.code)
                .font(.system(size: 10.5))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
            Text(rowCache.numberFor(meta.id, .latestPrice).map { SimFormat.price($0) } ?? "—")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(changeColor(meta.id))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            opButton("买", color: Color.blue) { pick(meta, .buy) }
            opButton("卖", color: Color(.systemGreen)) { pick(meta, .sell) }
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }

    /// 在途委托块（最多 2 行，行内直达撤单）
    private var pendingOrdersSection: some View {
        let orders = Array(store.activeOrders(accountID: store.queryAccountID).prefix(2))
        return VStack(spacing: 0) {
            HStack {
                Text("在途委托")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(.secondaryLabel))
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .frame(height: 26)

            if orders.isEmpty {
                Text("暂无在途委托")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
            } else {
                ForEach(orders) { order in
                    pendingOrderRow(order: order)
                }
            }
        }
        .padding(.top, 8)
    }

    private func pendingOrderRow(order: SimOrder) -> some View {
        HStack(spacing: 6) {
            Text(order.direction.title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(Color.white)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(order.direction.isBuy ? Color(.systemRed) : Color(.systemGreen)))
            Text(order.name)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color.primary)
                .lineLimit(1)
            Text(order.status.title)
                .font(.system(size: 10.5))
                .foregroundColor(Color(.secondaryLabel))
            Spacer(minLength: 6)
            Button {
                store.cancelOrder(id: order.id)
            } label: {
                Text("撤单")
                    .font(.system(size: 11))
                    .foregroundColor(Color.blue)
                    .frame(width: 40, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }

    // MARK: - 方案 A：原地切换后的下单卡（从自选带入标的）

    @ViewBuilder
    private func pickedTicketContext(meta: MetaItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    pickedMeta = nil
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("返回")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(Color.blue)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("从自选带入标的")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)

            quoteHeader(meta: meta)

            if let accountID = concreteAccountID {
                TradeTicketView(style: .panel,
                                accountID: accountID,
                                metaID: meta.id,
                                code: meta.code,
                                name: meta.name,
                                initialDirection: pickedDirection,
                                initialPriceType: .limit,
                                initialQty: 100,
                                onSubmit: { _ in pickedMeta = nil })
                    .id("quickPanel.picked.\(meta.id).\(pickedDirection.rawValue)")
            } else {
                allAccountsHint
            }
            Spacer(minLength: 12)
        }
    }

    // MARK: - 共享子块

    /// 账户切换菜单（「全部账户汇总」+ 各有效账户）
    private func accountMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            Button { store.selectedAccountID = SimStore.allAccountID } label: {
                Text("全部账户汇总")
            }
            ForEach(store.activeAccounts) { account in
                Button { store.selectedAccountID = account.id } label: {
                    Text(account.name)
                }
            }
        } label: {
            label()
        }
    }

    /// 快捷入口按钮（等宽卡片，可选红色角标）
    private func entryButton(icon: String, title: String, color: Color,
                             badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundColor(color)
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color.white)
                            .padding(.horizontal, 4)
                            .frame(height: 13)
                            .background(Capsule().fill(Color(.systemRed)))
                            .offset(x: 10, y: -6)
                    }
                }
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(.tertiarySystemBackground)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 快捷动作行按钮（等宽、高 34、圆角 7）
    private func actionButton(_ title: String, color: Color, compact: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: compact ? 11.5 : 12, weight: .semibold))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(.tertiarySystemBackground)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 自选行内「买 / 卖」小按钮（1pt 描边 + 圆角 6）
    private func opButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(color)
                .frame(width: 32, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 动作结果反馈行（成功绿 / 失败红）
    @ViewBuilder
    private var messageLine: some View {
        if let message = actionMessage {
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(actionMessageIsError ? Color(.systemRed) : Color(.systemGreen))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 6)
        }
    }

    private func changeColor(_ metaID: Int) -> Color {
        rowCache.colorFor(metaID, .changePct)
    }

    /// 盈亏正负着色（涨红跌绿）
    private func profitColor(_ value: Double) -> Color {
        value < 0 ? Color(.systemGreen) : Color(.systemRed)
    }

    // MARK: - 动作

    /// 自选行内「买 / 卖」：带入标的与方向，面板内容原地切到下单卡
    private func pick(_ meta: MetaItem, _ direction: SimOrderDirection) {
        pickedDirection = direction
        pickedMeta = meta
    }

    /// 全仓买入：按可用资金与最新价算整手数量，直接下单（限价 = 最新价）
    private func performFullBuy(meta: MetaItem) {
        guard let accountID = concreteAccountID, let account = store.account(id: accountID) else {
            showMessage("请先在上方选择具体账户", isError: true)
            return
        }
        guard let last = SimQuoteCenter.lastPrice(metaID: meta.id), last > 0 else {
            showMessage(SimOrderRejection.noQuote.message, isError: true)
            return
        }
        let qty = rules.affordableQty(cash: account.cash, price: last)
        guard qty > 0 else {
            showMessage("可用资金不足，买不满 \(rules.lotSize) 股", isError: true)
            return
        }
        let draft = SimOrderDraft(accountID: accountID, metaID: meta.id,
                                  code: meta.code, name: meta.name,
                                  direction: .buy, priceType: .limit,
                                  price: last, qty: qty)
        switch store.submit(draft) {
        case .success(let order):
            showMessage("全仓买入 \(SimFormat.shares(order.qty)) 股 · \(order.status.title)", isError: false)
        case .failure(let rejection):
            showMessage(rejection.message, isError: true)
        }
    }

    /// 一键撤单：按当前账户口径（全部汇总时撤全部）
    private func performCancelAll() {
        let count = store.cancelAll(accountID: store.queryAccountID)
        showMessage(count > 0 ? "已撤单 \(count) 笔" : "暂无在途委托", isError: false)
    }

    /// 一键清仓（已二次确认）：按可卖数量生成市价卖出委托
    private func performCloseAll() {
        guard let meta = detailRouter.item, let accountID = concreteAccountID else {
            showMessage("请先在上方选择具体账户", isError: true)
            return
        }
        let count = store.closeAll(accountID: accountID, metaID: meta.id)
        showMessage(count > 0 ? "已一键清仓 \(meta.name)" : "无可卖数量", isError: count == 0)
    }

    /// 展示动作反馈并在 3 秒后自动清空（令牌防止旧计时清掉新消息）
    private func showMessage(_ text: String, isError: Bool) {
        actionMessage = text
        actionMessageIsError = isError
        messageToken += 1
        let token = messageToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard token == messageToken else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                actionMessage = nil
                actionMessageIsError = false
            }
        }
    }
}

// MARK: - 占位视图（方案 B / C 已在 QuickPanelLayoutsBC.swift 实现，本占位保留备用）

struct QuickPanelPlaceholderView: View {
    let styleTitle: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(styleTitle)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Color.primary)
            Text("该布局正在开发中，阶段二上线")
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
            Button {
                withAnimation(.easeOut(duration: 0.15)) { onClose() }
            } label: {
                Text("完成")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.blue)
                    .frame(width: 140, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemBackground)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - 金额压缩（面板内的大额统一按「万」展示）

/// 金额文案：≥ 1 万时压缩成两位小数的「万」，否则退回千分位整数
/// （方案 A / B / C 共用，故为文件外可见）
func qpAmountText(_ value: Double) -> String {
    if abs(value) >= 10_000 {
        return String(format: "%.2f万", value / 10_000)
    }
    return SimFormat.amount0(value)
}

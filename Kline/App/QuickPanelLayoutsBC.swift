//
//  QuickPanelLayoutsBC.swift
//  Kline
//
//  快捷面板方案 B（分页式面板）与方案 C（闪电下单条）的真实实现，以及两者共用的
//  文件内私有子块（账户切换菜单 / 账户 chip / 交易时段指示 / 行情头 / 方向胶囊 /
//  描边小按钮 / 居中提示行）。容器 FloatingAccessoryPanel 按
//  TradingLayoutStore.shared.panelLayout 分发到本文件（B 高度系数 0.60、C 0.35 在容器侧设置），
//  面板只收到 onClose，取数与交互全部在本文件内完成。
//
//  方案 A 见 QuickPanelLayouts.swift：其 helper 是 QuickPanelAView 的实例方法，跨类型不可直接调用，
//  故本文件把 B / C 真正共用的部分提炼成独立的私有 struct 与私有自由函数，避免两份重复实现。
//  金额压缩文案复用 QuickPanelLayouts.swift 的 qpAmountText（已放宽为文件外可见）。
//
//  配色：涨红跌绿；买入 Color(.systemRed)、卖出 Color(.systemGreen)；
//  背景一律语义色（systemBackground / secondarySystemBackground / tertiarySystemBackground /
//  separator），支持深色模式。iOS 15 兼容：不使用 iOS 16+ API（onChange 为单参数闭包）。
//

import SwiftUI
import Foundation

// MARK: - 方案 B / C 共享子块

/// 账户切换菜单（与方案 A 同款交互）：「全部账户汇总」+ 各有效账户
private struct QuickAccountMenu<Label: View>: View {
    @ObservedObject private var store = SimStore.shared

    private let label: Label

    init(@ViewBuilder label: () -> Label) {
        self.label = label()
    }

    var body: some View {
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
            label
        }
    }
}

/// 账户 chip：当前账户名 + 下拉箭头（点开切换账户）
private struct QuickAccountChip: View {
    @ObservedObject private var store = SimStore.shared

    var body: some View {
        QuickAccountMenu {
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
    }
}

/// 交易时段指示：盘中红点 + 每秒刷新的连续竞价时钟；非盘中灰点 + 待报提示
private struct QuickSessionIndicator: View {
    private let rules = SimTradingRules.default

    var body: some View {
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
}

/// 行情头：名称 + 代码 + 最新价 + 涨跌幅（按涨跌色）；字号可调（B 紧凑态 / C 大字号）
private struct QuickQuoteHeader: View {
    let meta: MetaItem
    var nameSize: CGFloat = 14
    var priceSize: CGFloat = 19
    var horizontalPadding: CGFloat = 16
    var height: CGFloat = 56

    @ObservedObject private var rowCache = MarketRowCache.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(meta.name)
                .font(.system(size: nameSize, weight: .bold))
                .foregroundColor(Color.primary)
                .lineLimit(1)
            Text(meta.code)
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(rowCache.numberFor(meta.id, .latestPrice).map { SimFormat.price($0) } ?? "—")
                .font(.system(size: priceSize, weight: .bold))
                .foregroundColor(rowCache.colorFor(meta.id, .changePct))
            Text(rowCache.textFor(meta.id, .changePct))
                .font(.system(size: 11))
                .foregroundColor(rowCache.colorFor(meta.id, .changePct))
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: height)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }
}

/// 方向小胶囊（买红 / 卖绿）
private struct QuickDirectionTag: View {
    let direction: SimOrderDirection

    var body: some View {
        Text(direction.title)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(Color.white)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(direction.isBuy ? Color(.systemRed) : Color(.systemGreen)))
    }
}

/// 1pt 描边小按钮（「卖」/「撤单」/「买」等行内操作）
private struct QuickOutlineButton: View {
    let title: String
    var color: Color = .blue
    var width: CGFloat = 32
    var height: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(color)
                .frame(width: width, height: height)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 居中灰字提示（空数据 / 不可下单提示）
private struct QuickHintLine: View {
    let text: String
    var topPadding: CGFloat = 24

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Color(.secondaryLabel))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, topPadding)
            .padding(.bottom, 12)
    }
}

/// 盈亏正负着色（涨红跌绿）
private func qpProfitColor(_ value: Double) -> Color {
    value < 0 ? Color(.systemGreen) : Color(.systemRed)
}

/// 标的元信息：优先取行情元信息，缺失时用持仓自带的代码 / 名称兜底（避免行情未就绪时丢标的）
@MainActor
private func qpMetaItem(metaID: Int, code: String, name: String) -> MetaItem {
    SimQuoteCenter.meta(metaID: metaID)
        ?? MetaItem(id: metaID, file: "", code: code, name: name,
                    type: "", firstDate: nil, lastDate: nil)
}

// MARK: - 方案 B：分页式面板

/// 方案 B：账户条 +「交易 / 持仓 / 委托」三分段（带角标）+ 分段内容区。
/// 交易页复用 TradeTicketView(.panel)；持仓页行内「卖」带入标的与可卖数量后切回交易页。
struct QuickPanelBView: View {
    let onClose: () -> Void

    // MARK: 数据源（均为单例，只在 body / onAppear 等主线程上下文访问）

    @ObservedObject private var store = SimStore.shared
    @ObservedObject private var detailRouter = DetailRouter.shared
    @ObservedObject private var rowCache = MarketRowCache.shared
    @ObservedObject private var dbm = DatabaseManager.shared

    // MARK: 交互状态

    /// 分段
    private enum Segment: String, CaseIterable, Identifiable {
        case trade, position, order

        var id: String { rawValue }

        var title: String {
            switch self {
            case .trade: return "交易"
            case .position: return "持仓"
            case .order: return "委托"
            }
        }
    }

    @State private var segment: Segment = .trade
    /// 面板内选中的标的（持仓页「卖」带入；详情页态未选中时以 DetailRouter 的标的为准）
    @State private var pickedMeta: MetaItem?
    /// 带入下单卡的初始方向与数量（TradeTicketView 内部是 @State，靠 .id 强制重建才能生效）
    @State private var pendingDirection: SimOrderDirection = .buy
    @State private var pendingQty: Int = 100

    private var rules: SimTradingRules { SimTradingRules.default }

    var body: some View {
        VStack(spacing: 0) {
            accountBar
            segmentBar
            switch segment {
            case .trade: tradeSection
            case .position: positionSection
            case .order: orderSection
            }
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear(perform: handleAppear)
    }

    private func handleAppear() {
        // 注册持仓标的行情预取（幂等，内部会做 T+1 日切）
        store.prepareQuotes()
        // 交易页标的 + 持仓页标的的行情预取，避免现价长期为空（全部汇总时只取前若干条）
        var metas: [MetaItem] = []
        if let meta = tradeMeta { metas.append(meta) }
        metas.append(contentsOf: positions.prefix(12).map {
            qpMetaItem(metaID: $0.metaID, code: $0.code, name: $0.name)
        })
        if !metas.isEmpty { _ = rowCache.rows(for: metas) }
    }

    // MARK: - 派生数据

    /// 可下单的具体账户 id（「全部账户汇总」或无效账户时为 nil）
    private var concreteAccountID: UUID? {
        guard let id = store.selectedAccountID, id != SimStore.allAccountID,
              store.account(id: id) != nil else { return nil }
        return id
    }

    /// 当前查询口径（全部汇总时为聚合）下的持仓
    private var positions: [SimPosition] {
        store.positions(accountID: store.queryAccountID)
    }

    /// 当前查询口径下的在途委托
    private var activeOrders: [SimOrder] {
        store.activeOrders(accountID: store.queryAccountID)
    }

    /// 交易页默认标的：该账户第一个持仓，无持仓则取元信息列表首条
    private var defaultMeta: MetaItem? {
        if let position = store.positions(accountID: concreteAccountID).first {
            return qpMetaItem(metaID: position.metaID, code: position.code, name: position.name)
        }
        return dbm.metaList.first
    }

    /// 交易页当前标的：面板内选中的标的优先（持仓页「卖」的显式选择），
    /// 其次详情页态标的，最后兜底默认标的
    private var tradeMeta: MetaItem? {
        pickedMeta ?? detailRouter.item ?? defaultMeta
    }

    /// 是否在用兜底标的（此时显示引导灰字）
    private var isFallbackMeta: Bool {
        pickedMeta == nil && detailRouter.item == nil
    }

    // MARK: - 账户条 / 分段

    /// 账户条：左账户切换 chip / 中可用资金 / 右交易时段指示
    private var accountBar: some View {
        HStack(spacing: 8) {
            QuickAccountChip()

            Spacer(minLength: 8)

            Text("可用 \(qpAmountText(store.summary(accountID: store.queryAccountID).cash))")
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)

            Spacer(minLength: 8)

            QuickSessionIndicator()
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    /// 三分段：选中项 systemBackground 底 + 圆角 6 + 轻阴影，未选中文字灰；右侧红色小胶囊角标
    private var segmentBar: some View {
        HStack(spacing: 6) {
            segmentButton(.trade, badge: 0)
            segmentButton(.position, badge: positions.count)
            segmentButton(.order, badge: activeOrders.count)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func segmentButton(_ seg: Segment, badge: Int) -> some View {
        let selected = segment == seg
        return Button {
            segment = seg
        } label: {
            HStack(spacing: 4) {
                Text(seg.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? Color.primary : Color(.secondaryLabel))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.white)
                        .padding(.horizontal, 4)
                        .frame(height: 13)
                        .background(Capsule().fill(Color(.systemRed)))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color(.systemBackground) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color(.separator) : Color.clear, lineWidth: 1))
            .shadow(color: selected ? Color.black.opacity(0.06) : Color.clear,
                    radius: 2, x: 0, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分段：交易

    @ViewBuilder
    private var tradeSection: some View {
        if let meta = tradeMeta {
            if isFallbackMeta {
                Text("标的：\(meta.name) · 点下方「持仓」页的「卖」可带入")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: 26)
            }

            QuickQuoteHeader(meta: meta)

            if let accountID = concreteAccountID {
                TradeTicketView(style: .panel,
                                accountID: accountID,
                                metaID: meta.id,
                                code: meta.code,
                                name: meta.name,
                                initialDirection: pendingDirection,
                                initialPriceType: .limit,
                                initialQty: pendingQty,
                                onSubmit: { _ in })
                    // 方向 / 数量是组件内部 @State：仅改入参不会重置，必须换 id 强制重建
                    .id("quickPanelB.ticket.\(meta.id)-\(pendingDirection.rawValue)-\(pendingQty)")
            } else {
                QuickHintLine(text: "全部账户汇总不可下单，请先在账户条选择具体账户")
            }
        } else {
            QuickHintLine(text: "暂无可交易标的，请先到「自选」Tab 添加标的")
        }
    }

    // MARK: - 分段：持仓

    @ViewBuilder
    private var positionSection: some View {
        let list = positions
        if list.isEmpty {
            QuickHintLine(text: "暂无持仓")
        } else {
            positionHeaderRow
            ForEach(list) { position in
                positionRow(position: position)
            }
        }
    }

    /// 持仓表头（列宽与数据行一致）
    private var positionHeaderRow: some View {
        HStack(spacing: 8) {
            Text("名称 / 代码").frame(width: 88, alignment: .leading)
            Text("持仓").frame(width: 64, alignment: .trailing)
            Text("成本 / 现价").frame(width: 80, alignment: .trailing)
            Text("盈亏").frame(maxWidth: .infinity, alignment: .trailing)
            Text("操作").frame(width: 32, alignment: .trailing)
        }
        .font(.system(size: 10.5))
        .foregroundColor(Color(.secondaryLabel))
        .padding(.horizontal, 16)
        .frame(height: 24)
        .background(Color(.secondarySystemBackground))
    }

    private func positionRow(position: SimPosition) -> some View {
        let snap = store.snapshot(for: position)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(position.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color.primary)
                    .lineLimit(1)
                Text(position.code)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(.secondaryLabel))
                    .lineLimit(1)
            }
            .frame(width: 88, alignment: .leading)

            Text(SimFormat.shares(position.qty))
                .font(.system(size: 12))
                .foregroundColor(Color.primary)
                .lineLimit(1)
                .frame(width: 64, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 1) {
                Text("成本 \(SimFormat.price(position.costPrice))")
                Text("现价 \(SimFormat.price(snap.lastPrice))")
            }
            .font(.system(size: 10.5))
            .foregroundColor(Color(.secondaryLabel))
            .lineLimit(1)
            .frame(width: 80, alignment: .trailing)

            Text(SimFormat.signed(snap.profit))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(qpProfitColor(snap.profit))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .trailing)

            QuickOutlineButton(title: "卖", color: Color(.systemGreen)) {
                sellFromPosition(position)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5).padding(.leading, 16)
        }
    }

    /// 持仓页「卖」：带入该持仓标的与可卖数量（至少 1 手且为 1 手整数倍），切到交易页
    private func sellFromPosition(_ position: SimPosition) {
        let lot = max(rules.lotSize, 1)
        pickedMeta = qpMetaItem(metaID: position.metaID, code: position.code, name: position.name)
        pendingDirection = .sell
        pendingQty = max(lot, rules.sellableQty(position: position) / lot * lot)
        segment = .trade
    }

    // MARK: - 分段：委托

    @ViewBuilder
    private var orderSection: some View {
        let list = activeOrders
        if list.isEmpty {
            QuickHintLine(text: "暂无在途委托")
        } else {
            ForEach(list) { order in
                orderRow(order: order)
            }

            Button {
                _ = store.cancelAll(accountID: store.queryAccountID)
            } label: {
                Text("全部撤单")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(.systemGreen))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGreen).opacity(0.08)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
    }

    private func orderRow(order: SimOrder) -> some View {
        HStack(spacing: 8) {
            QuickDirectionTag(direction: order.direction)

            Text(order.name)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color.primary)
                .lineLimit(1)

            Text(orderDetailText(order))
                .font(.system(size: 10.5))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)

            Spacer(minLength: 6)

            QuickOutlineButton(title: "撤单", color: Color.blue, width: 40) {
                store.cancelOrder(id: order.id)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5).padding(.leading, 16)
        }
    }

    /// 委托明细：「市价 500 · 部成300」/「203.00 × 100 · 已报」
    private func orderDetailText(_ order: SimOrder) -> String {
        switch order.priceType {
        case .market:
            let filled = order.filledQty > 0 ? " · 部成\(SimFormat.shares(order.filledQty))" : ""
            return "市价 \(SimFormat.shares(order.qty))\(filled)"
        case .limit:
            let price = order.price.map { SimFormat.price($0) } ?? "—"
            return "\(price) × \(SimFormat.shares(order.qty)) · \(order.status.title)"
        }
    }
}

// MARK: - 方案 C：闪电下单条

/// 方案 C：账户 chip 行 + 标的行情头 + 闪电下单条（TradeTicketView .bolt，默认市价），
/// 可「展开」切换为完整下单卡（.panel，市价）；无标的上下文时改为自选迷你列表带入标的。
struct QuickPanelCView: View {
    let onClose: () -> Void

    // MARK: 数据源（均为单例，只在 body / onAppear 等主线程上下文访问）

    @ObservedObject private var store = SimStore.shared
    @ObservedObject private var detailRouter = DetailRouter.shared
    @ObservedObject private var rowCache = MarketRowCache.shared
    @ObservedObject private var fav = FavoritesStore.shared
    @ObservedObject private var dbm = DatabaseManager.shared

    // MARK: 交互状态

    /// 自选迷你列表点选的标的（详情页态为 nil 时才使用）
    @State private var pickedMeta: MetaItem?
    /// 自选迷你列表点选的方向（展开为完整下单卡时作为初始方向）
    @State private var pickedDirection: SimOrderDirection = .buy
    /// 闪电条是否展开为完整下单卡
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            if let meta = contextMeta {
                if pickedMeta != nil && detailRouter.item == nil {
                    backToWatchlistRow
                }
                accountChipRow
                QuickQuoteHeader(meta: meta, nameSize: 16, priceSize: 22)

                if let accountID = concreteAccountID {
                    if isExpanded {
                        collapseRow
                        TradeTicketView(style: .panel,
                                        accountID: accountID,
                                        metaID: meta.id,
                                        code: meta.code,
                                        name: meta.name,
                                        initialDirection: pickedDirection,
                                        initialPriceType: .market,
                                        initialQty: 100,
                                        onSubmit: { _ in })
                            .id("quickPanelC.panel.\(meta.id)-\(pickedDirection.rawValue)")
                    } else {
                        TradeTicketView(style: .bolt,
                                        accountID: accountID,
                                        metaID: meta.id,
                                        code: meta.code,
                                        name: meta.name,
                                        initialDirection: .buy,
                                        initialPriceType: .market,
                                        initialQty: 100,
                                        onExpand: { isExpanded = true },
                                        onSubmit: { _ in })
                            .id("quickPanelC.bolt.\(meta.id)")
                    }
                } else {
                    QuickHintLine(text: "全部账户汇总不可下单，请先选择具体账户")
                }
            } else {
                QuickHintLine(text: "闪电下单需要先选择标的", topPadding: 14)
                watchlistMiniList
            }

            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear(perform: handleAppear)
    }

    private func handleAppear() {
        // 注册行情预取（幂等，内部会做 T+1 日切）
        store.prepareQuotes()
        if let meta = contextMeta { _ = rowCache.row(for: meta) }
        let metas = Array(watchlistMetas.prefix(5))
        if !metas.isEmpty { _ = rowCache.rows(for: metas) }
    }

    // MARK: - 派生数据

    /// 可下单的具体账户 id（「全部账户汇总」或无效账户时为 nil）
    private var concreteAccountID: UUID? {
        guard let id = store.selectedAccountID, id != SimStore.allAccountID,
              store.account(id: id) != nil else { return nil }
        return id
    }

    /// 当前标的：详情页标的优先，其次自选迷你列表带入的标的
    private var contextMeta: MetaItem? {
        detailRouter.item ?? pickedMeta
    }

    /// 自选标的池（写法同 FavoritesView.prefetchAllGroups）
    private var watchlistMetas: [MetaItem] {
        let ids = Set(fav.allGroup.manualMetaIDs)
        return dbm.metaList.filter { ids.contains($0.id) }
    }

    // MARK: - 账户 chip 行 / 展开与收起

    /// 账户 chip 行：左账户切换 chip / 右「展开」入口（展开态由下方「收起」行收回）
    private var accountChipRow: some View {
        HStack(spacing: 8) {
            QuickAccountChip()

            Spacer(minLength: 8)

            if !isExpanded {
                Button {
                    isExpanded = true
                } label: {
                    Text("展开")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.blue)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    /// 展开态的「收起」行（点回闪电条；容器高度不变，内容区已在 ScrollView 内可滚动）
    private var collapseRow: some View {
        HStack(spacing: 8) {
            Button {
                isExpanded = false
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                    Text("收起")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(Color.blue)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Text("完整下单卡 · 默认市价")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    /// 「返回自选」行（从自选迷你列表带入标的后可退回列表）
    private var backToWatchlistRow: some View {
        HStack(spacing: 8) {
            Button {
                pickedMeta = nil
                isExpanded = false
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("返回自选")
                        .font(.system(size: 12))
                }
                .foregroundColor(Color.blue)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }

    // MARK: - 无标的上下文：自选迷你列表

    /// 自选迷你列表（最多 5 行，行内「买 / 卖」带入标的）
    private var watchlistMiniList: some View {
        let metas = Array(watchlistMetas.prefix(5))
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("自选 · 点行内按钮带入标的")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(.secondaryLabel))
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .frame(height: 24)

            if metas.isEmpty {
                QuickHintLine(text: "自选为空，请到「自选」Tab 添加标的", topPadding: 8)
            } else {
                ForEach(metas) { meta in
                    watchlistMiniRow(meta: meta)
                }
            }
        }
        .padding(.top, 4)
    }

    private func watchlistMiniRow(meta: MetaItem) -> some View {
        HStack(spacing: 8) {
            Text(meta.name)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color.primary)
                .lineLimit(1)
                .frame(width: 80, alignment: .leading)
            Text(meta.code)
                .font(.system(size: 10.5))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
                .frame(width: 86, alignment: .leading)
            Text(rowCache.numberFor(meta.id, .latestPrice).map { SimFormat.price($0) } ?? "—")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(rowCache.colorFor(meta.id, .changePct))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            QuickOutlineButton(title: "买", color: Color(.systemRed)) {
                pickFromWatchlist(meta, .buy)
            }
            QuickOutlineButton(title: "卖", color: Color(.systemGreen)) {
                pickFromWatchlist(meta, .sell)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    /// 自选行内「买 / 卖」：带入标的与方向，切到闪电下单条
    private func pickFromWatchlist(_ meta: MetaItem, _ direction: SimOrderDirection) {
        pickedDirection = direction
        pickedMeta = meta
        isExpanded = false
    }
}

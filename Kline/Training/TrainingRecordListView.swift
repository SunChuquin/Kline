//
//  TrainingRecordListView.swift
//  Kline
//
//  「K 线单人训练」记录管理页（全屏二级页）：会话列表 + 单会话交易明细。
//  顶部 44pt 导航栏（‹ 返回 / 训练记录 / 清空）+ 分隔线 + 会话列表（名称代码 / 起止日期·交易笔数·状态 / 创建时间 / 进入·删除）
//  + 空态；点行右侧 chevron 进入「交易明细」页（本文件内 TrainingTradeDetailView，状态切换 + 淡入淡出）。
//  数据源：`TrainingStore.shared.sessions`（已按 createdAt 倒序，本页不再二次排序）；
//  约定：iOS 15 兼容（不用 List / NavigationStack / @Observable）；配色一律语义色（正红负绿）；
//  行高固定，命中区 ≥ 44×44pt；删除一律自绘按钮 + confirmationDialog 二次确认。
//

import SwiftUI

struct TrainingRecordListView: View {
    /// 关闭回调（由呈现方置 nil）
    let onClose: () -> Void

    @ObservedObject private var store = TrainingStore.shared
    /// 当前查看的会话（nil = 会话列表；非 nil = 交易明细）
    @State private var detailSession: TrainSessionRecord? = nil
    /// 待删除的单条会话（非 nil 触发二次确认）
    @State private var deleteTarget: TrainSessionRecord? = nil
    /// 「清空全部」二次确认
    @State private var showClearConfirm = false

    /// 创建时间格式：yyyy-MM-dd HH:mm
    private static let createdFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // 显式 init：本视图含 private 存储属性（与同目录 AlertRecordView 同惯例）
    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            if let session = detailSession {
                TrainingTradeDetailView(session: session) {
                    withAnimation(.easeInOut(duration: 0.18)) { detailSession = nil }
                }
                .transition(.opacity)
            } else {
                sessionsPage
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear { store.refresh() }
        .confirmationDialog("删除这条训练记录？", isPresented: deleteConfirmBinding,
                            titleVisibility: .visible, presenting: deleteTarget) { session in
            Button("删除", role: .destructive) { store.deleteSession(id: session.id) }
            Button("取消", role: .cancel) { }
        }
        .confirmationDialog("清空全部训练记录？", isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button("清空全部", role: .destructive) { store.deleteAll() }
            Button("取消", role: .cancel) { }
        }
    }

    /// 「删除单条」二次确认的显隐桥接（目标置 nil 即关闭）
    private var deleteConfirmBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } })
    }

    // MARK: - 会话列表页

    private var sessionsPage: some View {
        VStack(spacing: 0) {
            listNavBar
            if store.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
    }

    private var listNavBar: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 15))
                }
                .foregroundColor(Color.blue)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("trainingRecord.back")

            Spacer(minLength: 8)

            // 清空：列表为空时置灰（避免无反应点击）
            Button(action: { showClearConfirm = true }) {
                Text("清空")
                    .font(.system(size: 15))
                    .foregroundColor(Color(.systemRed))
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.sessions.isEmpty)
            .opacity(store.sessions.isEmpty ? 0.4 : 1)
            .accessibilityIdentifier("trainingRecord.clearAll")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .overlay {
            Text("训练记录")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.primary)
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // 直接用 store 的倒序派生（不再本页二次排序）
                ForEach(Array(store.sessions.enumerated()), id: \.element.id) { pair in
                    sessionRow(pair.element, index: pair.offset)
                    Divider().padding(.leading, 12)
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// 单条会话：名称代码 / 起止·笔数·状态 / 创建时间 + 进入·删除（行高固定 78）
    private func sessionRow(_ session: TrainSessionRecord, index: Int) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(session.name)
                        .font(.system(size: 15))
                        .foregroundColor(Color.primary)
                        .lineLimit(1)
                    Text(session.code)
                        .font(.system(size: 12))
                        .foregroundColor(Color(.secondaryLabel))
                        .lineLimit(1)
                }
                Text(subline(session))
                    .font(.system(size: 12))
                    .foregroundColor(Color(.secondaryLabel))
                    .lineLimit(1)
                Text(Self.createdFormatter.string(from: session.createdAt))
                    .font(.system(size: 11))
                    .foregroundColor(Color(.tertiaryLabel))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            detailButton(session, index: index)
            deleteButton(session, index: index)
        }
        .padding(.leading, 12)
        .frame(height: 78)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 副行：起止日期（未结束显示「进行中」）· 交易笔数 · 状态
    private func subline(_ session: TrainSessionRecord) -> String {
        let endText = session.endDate == nil ? "进行中" : session.endDateText
        return "起始 \(session.startDateText) ~ \(endText) · 交易 \(session.tradeCount) 笔 · \(session.status.title)"
    }

    /// 进入交易明细（命中区 44×44）
    private func detailButton(_ session: TrainSessionRecord, index: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { detailSession = session }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 15))
                .foregroundColor(Color(.tertiaryLabel))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("trainingRecord.detail.\(index)")
    }

    /// 删除单条（命中区 44×44）
    private func deleteButton(_ session: TrainSessionRecord, index: Int) -> some View {
        Button {
            deleteTarget = session
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 15))
                .foregroundColor(Color(.secondaryLabel))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("trainingRecord.delete.\(index)")
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 34))
                .foregroundColor(Color(.tertiaryLabel))
            Text("暂无训练记录")
                .font(.system(size: 13))
                .foregroundColor(Color(.secondaryLabel))
            Text("在 K 线图页发起「单人训练」，创建会话后训练记录会显示在这里")
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 交易明细页

/// 单会话交易明细（本文件内实现）：顶部 44pt 导航栏 + 会话摘要行 + 分段（成交 / 条件单 / 预警记录）。
private struct TrainingTradeDetailView: View {
    let session: TrainSessionRecord
    let onBack: () -> Void

    @State private var trades: [TrainTradeRecord] = []
    @State private var conditions: [TrainCondRecord] = []
    @State private var alerts: [TrainAlertRecord] = []
    @State private var tab: DetailTab = .trades

    private enum DetailTab: String, CaseIterable, Identifiable {
        case trades, conditions, alerts

        var id: String { rawValue }
        var title: String {
            switch self {
            case .trades:     return "成交"
            case .conditions: return "条件单"
            case .alerts:     return "预警记录"
            }
        }
    }

    /// 列宽（表头与各行列宽一致，横向滚动时保持对齐）
    private enum Col {
        static let seq: CGFloat = 44
        static let dir: CGFloat = 52
        static let mark: CGFloat = 44
        static let date: CGFloat = 92
        static let price: CGFloat = 84
        static let qty: CGFloat = 64
        static let amount: CGFloat = 96
        static let fee: CGFloat = 72
        static let pnl: CGFloat = 88
        static let trigger: CGFloat = 132
        static let note: CGFloat = 140
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            summaryRow
            segmentBar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear { loadAll() }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .trades:
            if trades.isEmpty { emptyHint("暂无交易明细") } else { tradeTable }
        case .conditions:
            if conditions.isEmpty { emptyHint("本会话暂无条件单") } else { conditionList }
        case .alerts:
            if alerts.isEmpty { emptyHint("本会话暂无预警记录") } else { alertList }
        }
    }

    private var segmentBar: some View {
        TradeSegmentedRow(options: DetailTab.allCases.map { item in
            TradeSegOption(id: item.rawValue, title: segTitle(item), selected: item == tab)
        }, height: 30) { id in
            guard let next = DetailTab(rawValue: id), next != tab else { return }
            withAnimation(.easeInOut(duration: 0.15)) { tab = next }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func segTitle(_ item: DetailTab) -> String {
        switch item {
        case .trades:     return "成交 \(trades.count)"
        case .conditions: return "条件单 \(conditions.count)"
        case .alerts:     return "预警 \(alerts.count)"
        }
    }


    // MARK: 顶部栏

    private var navBar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 15))
                }
                .foregroundColor(Color.blue)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("trainingRecord.detailBack")

            Spacer(minLength: 8)

            // 右侧显示标的名称
            Text(session.name)
                .font(.system(size: 13))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .overlay {
            Text("交易明细")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.primary)
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    // MARK: 会话摘要行

    private var summaryRow: some View {
        Text("\(session.name) \(session.code) · 起始 \(session.startDateText) ~ \(session.endDateText) · 共 \(session.tradeCount) 笔")
            .font(.system(size: 12))
            .foregroundColor(Color(.secondaryLabel))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground))
    }

    // MARK: 成交表（横向 ScrollView 承载表头 + 列）

    private var tradeTable: some View {
        ScrollView(.vertical) {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    headerRow
                    ForEach(trades) { trade in
                        tradeRow(trade)
                        Divider().padding(.leading, 8)
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 4) {
            headerCell("序号", width: Col.seq)
            headerCell("方向", width: Col.dir)
            headerCell("标记", width: Col.mark)
            headerCell("成交日期", width: Col.date)
            headerCell("成交价", width: Col.price, alignment: .trailing)
            headerCell("数量", width: Col.qty, alignment: .trailing)
            headerCell("成交额", width: Col.amount, alignment: .trailing)
            headerCell("手续费", width: Col.fee, alignment: .trailing)
            headerCell("盈亏", width: Col.pnl, alignment: .trailing)
            headerCell("触发来源", width: Col.trigger, alignment: .leading)
            headerCell("备注", width: Col.note, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(Color(.secondarySystemBackground))
    }

    /// 单笔成交行（行高固定 44）
    private func tradeRow(_ trade: TrainTradeRecord) -> some View {
        HStack(spacing: 4) {
            cell("\(trade.seq)", width: Col.seq, color: Color(.secondaryLabel), mono: true)
            cell(trade.direction.title, width: Col.dir,
                 color: trade.direction.isBuy ? Color(.systemRed) : Color(.systemGreen),
                 weight: .semibold)
            cell(trade.mark.rawValue, width: Col.mark, color: markColor(trade.mark), weight: .heavy)
            cell(trade.tradeDateText, width: Col.date, color: Color(.secondaryLabel), mono: true)
            cell(String(format: "%.2f", trade.price), width: Col.price, alignment: .trailing, mono: true)
            cell("\(trade.qty)", width: Col.qty, alignment: .trailing, mono: true)
            cell(String(format: "%.2f", trade.amount), width: Col.amount, alignment: .trailing, mono: true)
            cell(String(format: "%.2f", trade.fee), width: Col.fee, alignment: .trailing,
                 color: Color(.secondaryLabel), mono: true)
            cell(pnlText(trade.pnl), width: Col.pnl, alignment: .trailing,
                 color: pnlColor(trade.pnl), mono: true)
            cell(triggerText(trade), width: Col.trigger, alignment: .leading,
                 color: trade.trigger == .cond ? Color.blue : Color(.secondaryLabel))
            cell(trade.note, width: Col.note, alignment: .leading, color: Color(.secondaryLabel))
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }

    /// 触发来源文案：手动 / 条件单·类型
    private func triggerText(_ trade: TrainTradeRecord) -> String {
        guard trade.trigger == .cond else { return trade.trigger.title }
        guard let kind = trade.condKind, !kind.isEmpty else { return trade.trigger.title }
        return "\(trade.trigger.title)·\(kind)"
    }

    private func markColor(_ mark: TrainTradeMark) -> Color {
        switch mark {
        case .buy:      return Color(.systemRed)
        case .sell:     return Color(.systemGreen)
        case .dayTrade: return Color.blue
        }
    }

    // MARK: 单元格

    private func headerCell(_ text: String, width: CGFloat,
                            alignment: Alignment = .center) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(Color(.secondaryLabel))
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    private func cell(_ text: String, width: CGFloat, alignment: Alignment = .center,
                      color: Color = Color.primary, weight: Font.Weight = .regular,
                      mono: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: weight, design: mono ? .monospaced : .default))
            .foregroundColor(color)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    // MARK: 盈亏格式与着色（nil → 「—」；正红负绿）

    private func pnlText(_ pnl: Double?) -> String {
        guard let pnl = pnl else { return "—" }
        return String(format: "%+.2f", pnl)
    }

    private func pnlColor(_ pnl: Double?) -> Color {
        guard let pnl = pnl else { return Color(.secondaryLabel) }
        if pnl > 0 { return Color(.systemRed) }
        if pnl < 0 { return Color(.systemGreen) }
        return Color(.secondaryLabel)
    }

    private func emptyHint(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 30))
                .foregroundColor(Color(.tertiaryLabel))
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(Color(.secondaryLabel))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 条件单 / 预警记录列表（只读）

    private var conditionList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(conditions) { record in
                    let order = record.order
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            SimCondKindChip(kind: order.kind)
                            Text(SimCondRule.conditionSummary(order))
                                .font(.system(size: 12.5))
                                .foregroundColor(Color.primary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 6)
                            if order.directive.isAlertOnly { SimCondAlertBadge() }
                            SimCondStatusTag(status: order.status)
                        }
                        Text("创建训练日 \(TrainSessionRecord.dateText(record.createdDate))"
                             + " · \(SimCondRule.validitySummary(order))")
                            .font(.system(size: 11))
                            .foregroundColor(Color(.secondaryLabel))
                        if !order.runtime.lastMessage.isEmpty {
                            Text(order.runtime.lastMessage)
                                .font(.system(size: 11))
                                .foregroundColor(Color(.secondaryLabel))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private var alertList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(alerts) { alert in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: "bell.badge")
                                .font(.system(size: 12))
                                .foregroundColor(Color.blue)
                            Text("训练日 \(alert.tradeDateText)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color.primary)
                            Spacer(minLength: 6)
                            Text(SimFormat.price(alert.price))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color.primary)
                        }
                        Text(alert.message)
                            .font(.system(size: 12.5))
                            .foregroundColor(Color(.secondaryLabel))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    // MARK: 行为

    private func loadAll() {
        trades = TrainingStore.shared.trades(sessionID: session.id)
        conditions = TrainingStore.shared.conditions(sessionID: session.id)
        alerts = TrainingStore.shared.alerts(sessionID: session.id)
    }
}

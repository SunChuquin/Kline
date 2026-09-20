//
//  SimCondListView.swift
//  Kline
//
//  条件单管理页（独立全屏二级页）：44pt 导航栏（关闭 / 条件单 / ＋新建）+ 三段概览条
//  + 三段分段筛选 + 条件单卡片列表（条件摘要 / 指令与有效期 / 多触发进度 / 原因）
//  + 52pt 底部常驻条（评估口径提示 + 立即检查）。
//  新建 / 编辑 / 详情由页内唯一的 .fullScreenCover 分发呈现，选择标的走内层底部条的
//  confirmationDialog（同一视图不叠多个 presentation modifier）；「立即检查」结果用页内轻量 toast 就地提示。
//  约定：iOS 15 兼容（不用 Table / Chart / NavigationStack / @Observable），
//  背景一律语义色（支持深色模式），所有可点击元素命中区 ≥ 44×44pt。
//

import SwiftUI

// MARK: - 编辑器呈现请求

/// 条件单编辑器的呈现请求（每次新建都换新 UUID，保证同一标的可重复呈现）
struct SimCondEditorRequest: Identifiable {
    let id: UUID
    let accountID: UUID
    let metaID: Int
    let code: String
    let name: String
    var initialKind: SimCondKind
    var initialDirection: SimOrderDirection
    var initialQty: Int
    /// 带入的当前价 / 预填触发价
    var initialPrice: Double?
    /// 非 nil = 编辑既有条件单
    var editing: SimCondOrder?

    init(accountID: UUID, metaID: Int, code: String, name: String,
         initialKind: SimCondKind = .price,
         initialDirection: SimOrderDirection = .sell,
         initialQty: Int = 100,
         initialPrice: Double? = nil,
         editing: SimCondOrder? = nil) {
        self.id = UUID()
        self.accountID = accountID
        self.metaID = metaID
        self.code = code
        self.name = name
        self.initialKind = initialKind
        self.initialDirection = initialDirection
        self.initialQty = initialQty
        self.initialPrice = initialPrice
        self.editing = editing
    }

    /// 由既有条件单构造「编辑」请求
    init(editing order: SimCondOrder) {
        self.init(accountID: order.accountID,
                  metaID: order.metaID,
                  code: order.code,
                  name: order.name,
                  initialKind: order.kind,
                  initialDirection: order.directive.direction,
                  initialQty: order.directive.qty,
                  initialPrice: order.params.triggerPrice ?? order.params.batchFirstPrice,
                  editing: order)
    }
}

// MARK: - 单一呈现目标

/// 管理页的单一呈现目标（同一视图只挂一个 fullScreenCover，避免多重 presentation 冲突）
enum SimCondPresentation: Identifiable {
    case listPicker                     // 选择标的（由内层底部条的 confirmationDialog 呈现）
    case editor(SimCondEditorRequest)
    case detail(SimCondOrder)

    var id: String {
        switch self {
        case .listPicker:        return "picker"
        case .editor(let req):   return "editor-\(req.id.uuidString)"
        case .detail(let order): return "detail-\(order.id.uuidString)"
        }
    }
}

// MARK: - 管理页

/// 条件单管理页（独立全屏二级页）
struct SimCondListView: View {
    /// nil 或 SimStore.allAccountID 表示「全部账户汇总」
    let accountID: UUID?
    /// 关闭回调（由呈现方 dismiss）
    let onClose: () -> Void
    /// 可选：外部带入的初始分段（默认 .monitoring）
    var initialSegment: SimCondSegment

    @ObservedObject private var store = SimStore.shared

    @State private var segment: SimCondSegment
    @State private var toastText: String? = nil
    /// 单一呈现目标：编辑器 / 详情走 fullScreenCover，选择标的走底部条上的 confirmationDialog
    @State private var presentation: SimCondPresentation? = nil

    init(accountID: UUID?, onClose: @escaping () -> Void,
         initialSegment: SimCondSegment = .monitoring) {
        self.accountID = accountID
        self.onClose = onClose
        self.initialSegment = initialSegment
        _segment = State(initialValue: initialSegment)
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            SimCondOverviewStrip(monitoring: counts.monitoring,
                                 triggered: counts.triggered,
                                 invalid: counts.invalid)
            segmentBar
            listContent
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .overlay(alignment: .bottom) { toastView }
        .fullScreenCover(item: coverBinding) { item in
            switch item {
            case .listPicker:
                // 选择标的由内层 confirmationDialog 呈现，不走 fullScreenCover
                EmptyView()
            case .editor(let req):
                SimCondEditorView(accountID: req.accountID, metaID: req.metaID, code: req.code, name: req.name,
                                  initialKind: req.initialKind, initialDirection: req.initialDirection,
                                  initialQty: req.initialQty, initialPrice: req.initialPrice,
                                  editing: req.editing) { presentation = nil }
            case .detail(let order):
                SimCondDetailView(order: order) { presentation = nil }
            }
        }
    }

    // MARK: 数据

    private var counts: (monitoring: Int, triggered: Int, invalid: Int) {
        store.condCounts(accountID: accountID)
    }

    private var rows: [SimCondOrder] {
        store.condOrders(accountID: accountID, segment: segment)
    }

    /// 新建条件单的标的来源（优先已有持仓；全部账户汇总时按持仓所属账户建单）
    private var candidatePositions: [SimPosition] {
        store.positions(accountID: accountID).filter { $0.qty > 0 }
    }

    // MARK: 导航栏

    private var navBar: some View {
        HStack(spacing: 0) {
            Button(action: onClose) {
                Text("关闭")
                    .font(.system(size: 15))
                    .foregroundColor(Color.blue)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Button(action: startCreate) {
                Text("＋ 新建")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.blue)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .overlay {
            Text("条件单")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.primary)
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    // MARK: 分段控件

    private var segmentBar: some View {
        TradeSegmentedRow(options: SimCondSegment.allCases.map { item in
            TradeSegOption(id: item.rawValue, title: item.title, tint: nil, selected: item == segment)
        }, height: 32) { id in
            guard let next = SimCondSegment(rawValue: id), next != segment else { return }
            withAnimation(.easeInOut(duration: 0.15)) { segment = next }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: 列表 / 空态

    @ViewBuilder
    private var listContent: some View {
        if rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { order in
                        condRow(order)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 34))
                .foregroundColor(Color(.tertiaryLabel))
            Text(emptyText)
                .font(.system(size: 13))
                .foregroundColor(Color(.secondaryLabel))
            Button(action: startCreate) {
                Text("新建条件单")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.blue)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 44, minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyText: String {
        switch segment {
        case .monitoring: return "暂无监控中的条件单"
        case .triggered:  return "暂无已触发的条件单"
        case .invalid:    return "暂无已失效的条件单"
        }
    }

    // MARK: 行卡片

    private func condRow(_ order: SimCondOrder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(order.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color.primary)
                    .lineLimit(1)
                Text(order.code)
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
                    .lineLimit(1)
                Spacer(minLength: 6)
                SimCondStatusTag(status: order.status)
                inlineButton("编辑", tint: .blue) { openEditor(order) }
                if order.status == .monitoring {
                    inlineButton("撤销", tint: Color(.secondaryLabel)) { cancel(order) }
                }
            }

            HStack(spacing: 6) {
                SimCondKindChip(kind: order.kind)
                Text(SimCondRule.conditionSummary(order))
                    .font(.system(size: 13))
                    .foregroundColor(Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            Text("\(SimCondRule.directiveSummary(order)) · \(SimCondRule.validitySummary(order))")
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if order.kind.repeatable {
                SimCondProgressBar(done: progressDone(order),
                                   total: progressTotal(order),
                                   triggered: order.triggeredCount,
                                   unit: order.kind == .grid ? "档" : "批")
            }

            if !order.runtime.lastMessage.isEmpty, order.status != .monitoring {
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
        .contentShape(Rectangle())
        .onTapGesture { presentation = .detail(order) }
    }

    /// 行内小按钮（SimInlineButton 本体高 22，这里补足 44×44 命中区）
    private func inlineButton(_ title: String, tint: Color = .blue,
                             action: @escaping () -> Void) -> some View {
        SimInlineButton(title: title, tint: tint, action: action)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    private func progressDone(_ order: SimCondOrder) -> Int {
        order.kind == .grid ? (order.runtime.gridLevel ?? 0) : order.runtime.batchDone
    }

    private func progressTotal(_ order: SimCondOrder) -> Int {
        order.kind == .grid ? SimCondRule.gridLevelCount(order: order) : (order.params.batchCount ?? 0)
    }

    // MARK: 底部常驻条

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text("行情刷新与手动检查时评估，非实时盯盘")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: manualCheck) {
                Text("立即检查")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Color.blue)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue, lineWidth: 1))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
        // 选择标的挂在内层底部条上：与最外层 VStack 的 fullScreenCover 不同宿主，互不影响
        .confirmationDialog("选择标的", isPresented: pickerBinding, titleVisibility: .visible) {
            ForEach(candidatePositions) { position in
                Button("\(position.name) \(position.code)") { presentCreate(with: position) }
            }
            Button("取消", role: .cancel) { presentation = nil }
        }
    }

    /// 「选择标的」弹窗的显隐绑定（由单一呈现状态驱动，不额外持有布尔状态）
    private var pickerBinding: Binding<Bool> {
        Binding<Bool>(get: {
            if case .some(.listPicker) = presentation { return true }
            return false
        }, set: { shown in
            // 只在仍处于 listPicker 时清空：避免弹窗自动 dismiss 覆盖掉按钮动作刚设置的 editor
            if !shown, case .some(.listPicker) = presentation { presentation = nil }
        })
    }

    /// 全屏覆盖层的内容绑定：`.listPicker` 不参与覆盖层呈现（它由内层 confirmationDialog 呈现），
    /// 这样单一状态既能驱动弹窗，又不会让覆盖层弹出空白页
    private var coverBinding: Binding<SimCondPresentation?> {
        Binding<SimCondPresentation?>(get: {
            if case .some(.listPicker) = presentation { return nil }
            return presentation
        }, set: { presentation = $0 })
    }

    // MARK: 轻提示

    @ViewBuilder
    private var toastView: some View {
        if let text = toastText {
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(Color(.systemBackground))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.label).opacity(0.92)))
                .padding(.horizontal, 24)
                .padding(.bottom, 64)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// 轻提示：1.6 秒后自动淡出（背景 / 文字用 label 与 systemBackground 反色，深浅色都可读）
    private func showToast(_ text: String) {
        withAnimation(.easeInOut(duration: 0.15)) { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastText == text {
                withAnimation(.easeInOut(duration: 0.15)) { toastText = nil }
            }
        }
    }

    // MARK: 行为

    /// 立即检查：就地提示本轮结算结果（列表随 store 变化自动刷新）
    private func manualCheck() {
        let result = store.sweepConditions(trigger: .manual)
        showToast(result.message)
    }

    private func cancel(_ order: SimCondOrder) {
        store.cancelCondOrder(id: order.id)
        showToast("已撤销")
    }

    private func openEditor(_ order: SimCondOrder) {
        presentation = .editor(SimCondEditorRequest(editing: order))
    }

    /// 新建：以持仓为标的来源（全部账户汇总时按持仓所属账户建单）
    private func startCreate() {
        let list = candidatePositions
        guard !list.isEmpty else {
            showToast("当前账户无持仓，请先建仓或从持仓页创建条件单")
            return
        }
        presentation = .listPicker
    }

    private func presentCreate(with position: SimPosition) {
        presentation = .editor(SimCondEditorRequest(accountID: position.accountID,
                                                    metaID: position.metaID,
                                                    code: position.code,
                                                    name: position.name))
    }
}
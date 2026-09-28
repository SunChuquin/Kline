//
//  TrainingCondListView.swift
//  Kline
//
//  「K 线单人训练」条件单 / 预警记录管理页（训练态专用）。
//  数据全部来自训练库（train_cond / train_alert），与模拟交易条件单（sim.json）完全隔离：
//  触发判定用训练日收盘价，结算时机 = 推进一根 K 线 / 新建条件单 / 手动检查。
//  新建 / 编辑复用模拟交易的 SimCondEditorView，通过 `TrainingCondBackend` 注入训练取数与落库。
//  设计对齐 SimCondListView（44pt 导航栏 + 分段 + 卡片列表 + 底部常驻条 + 页内单一 fullScreenCover）。
//

import SwiftUI
import Combine

// MARK: - 呈现路由器

/// 训练条件单浮层路由器：面板内入口只置位它，实际浮层由 `ContentView` 根层挂载
/// （要盖住底部导航栏，页面内 overlay 盖不住底栏，与训练设置窗同因）。
final class TrainingCondRouter: ObservableObject {
    static let shared = TrainingCondRouter()
    @Published var isPresented = false
    private init() {}
}

// MARK: - 编辑器呈现请求

/// 训练条件单编辑器请求（每次新建换新 id，保证可重复呈现）
struct TrainCondEditorRequest: Identifiable {
    let id = UUID()
    let metaID: Int
    let code: String
    let name: String
    /// 非 nil = 编辑既有训练条件单
    var editing: SimCondOrder?
}

// MARK: - 管理页

struct TrainingCondListView: View {
    let onClose: () -> Void

    @ObservedObject private var training = TrainingSessionController.shared

    @State private var segment: Segment = .conditions
    @State private var editorRequest: TrainCondEditorRequest?

    enum Segment: String, CaseIterable, Identifiable {
        case conditions
        case alerts

        var id: String { rawValue }
        var title: String { self == .conditions ? "条件单" : "预警记录" }
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            segmentBar
            listContent
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear {
            training.reloadConditions()
            training.reloadAlerts()
        }
        .fullScreenCover(item: $editorRequest) { request in
            SimCondEditorView(accountID: TrainingSessionController.trainingAccountID,
                              metaID: request.metaID,
                              code: request.code,
                              name: request.name,
                              initialDirection: .sell,
                              initialQty: 100,
                              editing: request.editing,
                              trainingBackend: training.condEditorBackend) {
                editorRequest = nil
            }
        }
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
                    .foregroundColor(canCreate ? Color.blue : Color(.tertiaryLabel))
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canCreate)
            .accessibilityIdentifier("trainCond.create")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .overlay {
            Text("训练条件单")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.primary)
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    private var canCreate: Bool { training.meta != nil }

    // MARK: 分段

    private var segmentBar: some View {
        TradeSegmentedRow(options: Segment.allCases.map { item in
            TradeSegOption(id: item.rawValue, title: segTitle(item), selected: item == segment)
        }, height: 32) { id in
            guard let next = Segment(rawValue: id), next != segment else { return }
            withAnimation(.easeInOut(duration: 0.15)) { segment = next }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func segTitle(_ item: Segment) -> String {
        item == .conditions ? "条件单 \(training.conditions.count)"
                            : "预警记录 \(training.alerts.count)"
    }

    // MARK: 列表

    @ViewBuilder
    private var listContent: some View {
        switch segment {
        case .conditions:
            if training.conditions.isEmpty {
                emptyState(icon: "square.stack.3d.up", text: "暂无训练条件单")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(training.conditions) { record in
                            condRow(record)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        case .alerts:
            if training.alerts.isEmpty {
                emptyState(icon: "bell.slash", text: "暂无训练预警记录")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(training.alerts) { alert in
                            alertRow(alert)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundColor(Color(.tertiaryLabel))
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(Color(.secondaryLabel))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 条件单行

    private func condRow(_ record: TrainCondRecord) -> some View {
        let order = record.order
        return VStack(alignment: .leading, spacing: 6) {
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
                if order.directive.isAlertOnly { SimCondAlertBadge() }
                SimCondStatusTag(status: order.status)
                inlineButton("删除", tint: Color(.secondaryLabel)) { delete(order) }
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

            Text(directiveLine(order))
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if order.kind.repeatable {
                SimCondProgressBar(done: progressDone(order), total: progressTotal(order),
                                   triggered: order.triggeredCount,
                                   unit: order.kind == .grid ? "档" : "批")
            }

            HStack(spacing: 6) {
                Text("创建训练日 \(TrainSessionRecord.dateText(record.createdDate))")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.tertiaryLabel))
                Spacer(minLength: 6)
                if !order.runtime.lastMessage.isEmpty {
                    Text(order.runtime.lastMessage)
                        .font(.system(size: 11))
                        .foregroundColor(Color(.secondaryLabel))
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        .contentShape(Rectangle())
        .onTapGesture { openEditor(order) }
    }

    private func directiveLine(_ order: SimCondOrder) -> String {
        let validity = SimCondRule.validitySummary(order)
        if order.directive.isAlertOnly {
            return "触发后只记录预警（不下单） · \(validity)"
        }
        return "\(SimCondRule.directiveSummary(order)) · \(validity)"
    }

    private func progressDone(_ order: SimCondOrder) -> Int {
        order.kind == .grid ? (order.runtime.gridLevel ?? 0) : order.runtime.batchDone
    }

    private func progressTotal(_ order: SimCondOrder) -> Int {
        order.kind == .grid ? SimCondRule.gridLevelCount(order: order) : (order.params.batchCount ?? 0)
    }

    private func inlineButton(_ title: String, tint: Color = .blue,
                              action: @escaping () -> Void) -> some View {
        SimInlineButton(title: title, tint: tint, action: action)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    // MARK: 预警行

    private func alertRow(_ alert: TrainAlertRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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

    // MARK: 底部常驻条

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text("按训练日收盘价结算 · 推进 K 线时自动检查")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                training.sweepConditions(reason: "MANUAL")
            } label: {
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
            .accessibilityIdentifier("trainCond.check")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    // MARK: 行为

    private func startCreate() {
        guard let meta = training.meta else { return }
        editorRequest = TrainCondEditorRequest(metaID: meta.id, code: meta.code, name: meta.name)
    }

    private func openEditor(_ order: SimCondOrder) {
        editorRequest = TrainCondEditorRequest(metaID: order.metaID, code: order.code,
                                               name: order.name, editing: order)
    }

    private func delete(_ order: SimCondOrder) {
        training.deleteCondition(id: order.id.uuidString)
    }
}

// MARK: - 挂载修饰符

extension View {
    /// 挂载训练条件单浮层（由 `ContentView` 根层承载，可盖住底部导航栏）
    func trainingCondSheet(isPresented: Binding<Bool>) -> some View {
        modifier(TrainingCondSheetModifier(isPresented: isPresented))
    }
}

private struct TrainingCondSheetModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                TrainingCondListView(onClose: { isPresented = false })
                    .transition(.opacity)
                    .zIndex(1900)
            }
        }
    }
}

//
//  StrategyGenConfirmView.swift
//  Kline
//
//  策略「生成条件单」确认页：按账户分组预览草稿 + 跳过明细 + 超限提示，确认后一次性批量写入。
//
//  Created by 孙楚昆 on 2026/9/20.
//

import SwiftUI

// MARK: - 账户分组

/// 生成确认页的账户分组（草稿按绑定账户归拢；id 为账户 UUID，可直接喂 ForEach）
private struct StrategyDraftGroup: Identifiable {
    let id: UUID
    let name: String
    let items: [StrategyCondDraft]
}

/// 生成条件单确认页（策略详情页内的全屏 overlay 子页，不用 sheet / fullScreenCover）
///
/// 进入时立刻按勾选标的算出草稿（`StrategyCondGenerator.generate`，纯计算不写盘）；
/// 点「确认生成」调用 `SimStore.upsertCondOrders` 批量接口 —— 整轮只落盘一次。
struct StrategyGenConfirmView: View {
    /// 被执行的策略文档（TRADE 段提供方向 / 数量 / 报价方式 / 有效期）
    var doc: FormulaDoc
    /// 勾选的标的（来自跑选股命中清单）
    var metas: [MetaItem]
    var onClose: () -> Void
    /// 完成回传写入条数（写入 0 条视为失败，就地红字提示）
    var onDone: (Int) -> Void

    @ObservedObject private var store = SimStore.shared

    /// 生成结果（在 onAppear 里算一次，避免 body 重算时反复生成）
    @State private var outcome: StrategyGenOutcome? = nil
    /// 是否同时生成入场单（仅 TRADE 配了方向时可见，默认关闭）
    @State private var includeEntry = false
    /// 跳过明细是否展开（默认折叠）
    @State private var showSkips = false
    /// 写入失败的就地提示
    @State private var errorText: String? = nil

    // 显式 init：本视图含 private 存储属性，合成 memberwise init 会是 private
    init(doc: FormulaDoc, metas: [MetaItem],
         onClose: @escaping () -> Void, onDone: @escaping (Int) -> Void) {
        self.doc = doc
        self.metas = metas
        self.onClose = onClose
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let outcome = outcome {
                        content(outcome)
                    } else {
                        Text("正在生成…")
                            .font(.system(size: 13))
                            .foregroundColor(Color(.secondaryLabel))
                    }
                }
                .padding(16)
            }

            confirmBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        // 内容贴物理屏幕底边（全 App 统一贴底为 0）
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear { recompute() }
        .onChange(of: includeEntry) { _ in recompute() }
    }

    // MARK: - 页头

    private var header: some View {
        HStack {
            Button {
                onClose()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    Text("返回").font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.gray.opacity(0.12)).cornerRadius(8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)

            Spacer()

            Text("生成条件单")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            Button {
                confirm()
            } label: {
                Text("确认生成（\(draftCount) 条）")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(draftCount == 0 ? Color(.tertiaryLabel) : Color.blue)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(draftCount == 0)
            .padding(.trailing, 16)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(_ outcome: StrategyGenOutcome) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if outcome.truncatedByLimit {
                Text("本次已达生成上限（单次 200 条 / 单账户监控 1000 条），超出部分未生成")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            overviewCard(outcome)

            if doc.trade.direction != nil {
                entryToggle
            }

            draftGroups(outcome)

            if !outcome.skips.isEmpty {
                skipCard(outcome.skips)
            }
        }
    }

    /// 概览行：写入 / 跳过条数 + 目标账户名
    private func overviewCard(_ outcome: StrategyGenOutcome) -> some View {
        card("概览") {
            Text("将写入 \(outcome.drafts.count) 条条件单 · 跳过 \(outcome.skips.count) 条")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text("目标账户：\(targetAccountText)")
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 入场单开关（仅 TRADE 段配了方向时可见，默认关闭）
    private var entryToggle: some View {
        card("入场单") {
            Toggle(isOn: $includeEntry) {
                Text("同时生成入场单（PRICE ≥ 最新价）")
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(SwitchToggleStyle())
            .frame(minHeight: 44)

            Text("命中清单本身就是今日已命中，入场单会按 TRADE 段的报价方式在盘中触发")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 按账户分组的草稿列表
    @ViewBuilder
    private func draftGroups(_ outcome: StrategyGenOutcome) -> some View {
        if outcome.drafts.isEmpty {
            card("将生成的条件单") {
                Text("没有可生成的条件单，请看下方跳过原因")
                    .font(.system(size: 13))
                    .foregroundColor(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ForEach(draftGroups(outcome.drafts)) { group in
                card(group.name) {
                    ForEach(group.items) { draft in
                        draftRow(draft)
                    }
                }
            }
        }
    }

    private func draftRow(_ draft: StrategyCondDraft) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(draft.name) \(draft.code)")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
            Text("\(draft.kind.title) · \(draft.summary)")
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 44, alignment: .leading)
    }

    /// 跳过明细（默认折叠，逐行「title —— reason」）
    private func skipCard(_ skips: [StrategyGenSkip]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showSkips.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("跳过 \(skips.count) 条")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.orange)
                    Image(systemName: showSkips ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.orange)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showSkips {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(skips) { skip in
                        Text("\(skip.title) —— \(skip.reason)")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }
        }
    }

    // MARK: - 底部固定条

    private var confirmBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorText = errorText {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                confirm()
            } label: {
                Text("确认生成")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(draftCount == 0 ? Color.gray : Color.blue))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(draftCount == 0)

            Text("条件单在行情刷新与手动检查时评估，非实时盯盘；与回测的逐 bar 判定口径不同")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    // MARK: - 通用卡片

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
    }

    // MARK: - 派生数据

    private var draftCount: Int { outcome?.drafts.count ?? 0 }

    /// 目标账户名（按 TRADE 段绑定顺序，失效账户标注）
    private var targetAccountText: String {
        let names = doc.trade.accountIDs.map { id in
            store.account(id: id)?.name ?? "已失效账户"
        }
        return names.isEmpty ? "未绑定账户" : names.joined(separator: "、")
    }

    /// 草稿按账户分组（保持 TRADE 段绑定顺序）
    private func draftGroups(_ drafts: [StrategyCondDraft]) -> [StrategyDraftGroup] {
        var order: [UUID] = []
        var map: [UUID: [StrategyCondDraft]] = [:]
        for draft in drafts {
            if map[draft.accountID] == nil {
                order.append(draft.accountID)
                map[draft.accountID] = []
            }
            map[draft.accountID]?.append(draft)
        }
        return order.map { id in
            StrategyDraftGroup(id: id,
                               name: store.account(id: id)?.name ?? "已失效账户",
                               items: map[id] ?? [])
        }
    }

    // MARK: - 行为

    /// 重算草稿（进入页面 / 切换入场单开关时），纯计算不写盘
    private func recompute() {
        outcome = StrategyCondGenerator.generate(doc: doc,
                                                 metas: metas,
                                                 includeEntry: includeEntry,
                                                 accountIDs: doc.trade.accountIDs)
        errorText = nil
    }

    /// 确认生成：批量写入（一次落盘），写 0 条视为失败
    private func confirm() {
        guard let outcome = outcome, !outcome.drafts.isEmpty else { return }
        let written = store.upsertCondOrders(outcome.drafts.map { $0.order() })
        if written > 0 {
            onDone(written)
        } else {
            errorText = "写入失败，请稍后重试"
        }
    }
}
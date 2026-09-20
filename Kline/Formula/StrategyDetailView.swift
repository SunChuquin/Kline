//
//  StrategyDetailView.swift
//  Kline
//
//  交易策略详情页：选股条件 / 交易指令与绑定账户 / 规则清单 + 执行侧动作入口（本阶段占位）。
//
//  Created by 孙楚昆 on 2026/9/20.
//

import SwiftUI

/// 交易策略详情页（全屏 overlay 子页）
///
/// 只读展示一份策略文档的定义：选股条件摘要、交易指令与绑定账户、逐条规则触发语义。
/// 执行侧（跑选股 / 生成条件单 / 回测）留待下一阶段接入，本页先给出禁用的占位入口与口径说明。
struct StrategyDetailView: View {
    /// 展示的策略文档（由公式管理页传入快照）
    var doc: FormulaDoc
    var onClose: () -> Void
    /// 点右上「编辑」：由呈现方关闭详情并打开策略编辑器
    var onEdit: () -> Void

    /// 模拟账户表（把绑定的 UUID 解析成账户名，只读，不写入任何模拟数据）
    @ObservedObject private var sim = SimStore.shared
    /// 公式库（解析 PICKREF 指向的选股公式名）
    @ObservedObject private var library = FormulaLibraryStore.shared

    // 显式 init：本视图含 private 存储属性，合成 memberwise init 会是 private
    init(doc: FormulaDoc, onClose: @escaping () -> Void, onEdit: @escaping () -> Void) {
        self.doc = doc
        self.onClose = onClose
        self.onEdit = onEdit
    }

    // MARK: - 页面

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    pickCard
                    tradeCard
                    rulesCard
                    actionsSection
                    Color.clear.frame(height: 8)
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        // 内容贴物理屏幕底边（全 App 统一贴底为 0）
        .ignoresSafeArea(.container, edges: .bottom)
    }

    /// 页头：‹ 返回 / 「策略详情」/ 编辑（视觉令牌沿用 FormulaEditorView / SimCondListView）
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

            Text("策略详情")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            Button {
                onEdit()
            } label: {
                Text("编辑")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.gray.opacity(0.12)).cornerRadius(8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - 选股条件卡

    private var pickCard: some View {
        card("选股条件") {
            Text(StrategyPreview.pickSummary(doc: doc,
                                             pickerName: library.pickerName(id: doc.pickRef)))
                .font(.system(size: 14))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 交易指令与绑定账户卡

    private var tradeCard: some View {
        card("交易指令与绑定账户") {
            if isTradeConfigured {
                Text(StrategyPreview.tradeSummary(doc: doc))
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !doc.trade.accountIDs.isEmpty {
                    Text(boundAccountText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if missingAccountCount > 0 {
                    Text("\(missingAccountCount) 个账户已失效")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("尚未配置交易指令与绑定账户，请点右上角编辑")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 规则清单卡

    private var rulesCard: some View {
        let parsed = StrategyRuleParser.parse(lines: doc.rules)
        return card("交易规则") {
            if parsed.rules.isEmpty && parsed.errors.isEmpty {
                Text("还没有交易规则")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(parsed.rules.enumerated()), id: \.offset) { index, call in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(StrategyPreview.triggerText(call))
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
                ForEach(Array(parsed.errors.enumerated()), id: \.offset) { _, error in
                    Text("✗ \(error)")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 动作区（阶段一占位，下一阶段替换为真实实现）

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("执行")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)

            HStack(spacing: 10) {
                actionButton("跑选股")
                actionButton("生成条件单")
                actionButton("回测")
            }

            Text("生成条件单与历史回测将在下一阶段接入")
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 占位动作按钮：统一灰态禁用（下一阶段在 actionsSection 内替换为真实入口）
    private func actionButton(_ title: String) -> some View {
        Button {
            // 阶段一占位：本页只读展示，不做任何写操作
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(true)
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

    /// 是否已配置交易指令或绑定账户（未配置时给橙字引导）
    private var isTradeConfigured: Bool {
        !doc.trade.isEmpty || !doc.trade.accountIDs.isEmpty
    }

    /// 绑定的账户（按 accountIDs 顺序解析；找不到的为失效，不计入）
    private var boundAccounts: [SimAccount] {
        doc.trade.accountIDs.compactMap { id in sim.accounts.first { $0.id == id } }
    }

    /// 绑定了但已不存在的账户数
    private var missingAccountCount: Int {
        doc.trade.accountIDs.filter { id in !sim.accounts.contains { $0.id == id } }.count
    }

    /// 绑定账户文案：前 3 个账户名，多于 3 个补「+N」
    private var boundAccountText: String {
        let names = boundAccounts.map { $0.name }
        var text = "绑定账户：" + names.prefix(3).joined(separator: "、")
        if names.count > 3 { text += " +\(names.count - 3)" }
        return text
    }
}
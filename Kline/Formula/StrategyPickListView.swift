//
//  StrategyPickListView.swift
//  Kline
//
//  策略「跑选股」命中清单页：池分段（全市场 / 自选）+ 两段式进度 + 命中勾选（默认全选）+ 交给生成条件单。
//
//  Created by 孙楚昆 on 2026/9/20.
//

import SwiftUI

/// 跑选股命中清单页（策略详情页内的全屏 overlay 子页，不用 sheet / fullScreenCover）
///
/// 由 `StrategyDetailView` 以 `.overlay` + `zIndex(2000)` 承载；
/// 点右上「生成条件单」把勾选的标的（MetaItem）回传给宿主，由宿主打开生成确认页。
struct StrategyPickListView: View {
    /// 被跑的策略文档（取 PICKREF / 内嵌 PICK 文本）
    var doc: FormulaDoc
    var onClose: () -> Void
    /// 勾选标的交给「生成条件单」
    var onGenerate: ([MetaItem]) -> Void

    /// 执行器（全局单例，进度与命中都由它驱动）
    @ObservedObject private var runner = StrategyPickRunner.shared
    /// 标的信息表（把命中的 metaID 还原成 MetaItem 后回传）
    @ObservedObject private var db = DatabaseManager.shared

    @State private var pool: StrategyPickPool = .market
    @State private var selected: Set<Int> = []

    // 显式 init：本视图含 private 存储属性，合成 memberwise init 会是 private
    init(doc: FormulaDoc, onClose: @escaping () -> Void, onGenerate: @escaping ([MetaItem]) -> Void) {
        self.doc = doc
        self.onClose = onClose
        self.onGenerate = onGenerate
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            toolBar
            progressArea

            listContent

            bottomNotice
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        // 内容贴物理屏幕底边（全 App 统一贴底为 0）
        .ignoresSafeArea(.container, edges: .bottom)
        // 结果变化：默认全选（用户已手动改过勾选则不打扰）
        .onChange(of: runner.hits) { newValue in
            if newValue.isEmpty {
                if !selected.isEmpty { selected = [] }
            } else if selected.isEmpty {
                selected = Set(newValue.map { $0.metaID })
            }
        }
        // 再次进入本页（命中已存在、hits 不再变化）时同样默认全选
        .onAppear {
            if selected.isEmpty, !runner.hits.isEmpty {
                selected = Set(runner.hits.map { $0.metaID })
            }
        }
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

            Text("跑选股")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            Button {
                generate()
            } label: {
                Text("生成条件单")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(selected.isEmpty ? Color(.tertiaryLabel) : Color.blue)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
            .padding(.trailing, 16)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - 候选池 + 全选

    private var toolBar: some View {
        HStack(spacing: 10) {
            TradeSegmentedRow(options: StrategyPickPool.allCases.map { item in
                TradeSegOption(id: item.rawValue, title: item.title, tint: nil, selected: item == pool)
            }, height: 32) { id in
                guard let next = StrategyPickPool(rawValue: id), next != pool else { return }
                pool = next
            }
            .disabled(runner.isRunning)

            Button {
                toggleAll()
            } label: {
                Text(isAllSelected ? "取消全选" : "全选")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(runner.hits.isEmpty ? Color(.tertiaryLabel) : Color.blue)
                    .frame(minWidth: 68, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(runner.hits.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - 进度区

    @ViewBuilder
    private var progressArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch runner.phase {
            case .idle:
                HStack(spacing: 8) {
                    Text("点击开始跑选股")
                        .font(.system(size: 12))
                        .foregroundColor(Color(.secondaryLabel))
                    Spacer(minLength: 8)
                    inlineAction("开始跑选股") { start() }
                }

            case .preparing(let done, let total):
                Text("准备行情数据 \(done)/\(total)")
                    .font(.system(size: 12))
                    .foregroundColor(Color(.secondaryLabel))
                progressTrack(ratio: ratio(done, total))
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    inlineAction("取消") { runner.cancel() }
                }

            case .running(let done, let total):
                Text("已扫描 \(done)/\(total)")
                    .font(.system(size: 12))
                    .foregroundColor(Color(.secondaryLabel))
                progressTrack(ratio: ratio(done, total))
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    inlineAction("取消") { runner.cancel() }
                }

            case .finished:
                HStack(spacing: 8) {
                    Text("命中 \(runner.hits.count) 只")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer(minLength: 8)
                    inlineAction("重新跑选股") { start() }
                }

            case .cancelled:
                HStack(spacing: 8) {
                    Text("已取消")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.orange)
                    Spacer(minLength: 8)
                    inlineAction("重新跑选股") { start() }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// 手写 3pt 细条进度（不用 SimCondProgressBar：它的文案是条件单档位口径）
    private func progressTrack(ratio: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.secondaryLabel).opacity(0.2))
                Capsule()
                    .fill(Color.blue)
                    .frame(width: geo.size.width * CGFloat(min(max(ratio, 0), 1)))
            }
        }
        .frame(height: 3)
    }

    /// 行内小动作（蓝字 12.5pt，补足 44pt 命中区）
    private func inlineAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
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

    // MARK: - 清单 / 空态

    @ViewBuilder
    private var listContent: some View {
        if runner.hits.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(runner.hits) { hit in
                        hitRow(hit)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34))
                .foregroundColor(Color(.tertiaryLabel))
            Text(emptyText)
                .font(.system(size: 13))
                .foregroundColor(Color(.secondaryLabel))
            if runner.phase == .finished {
                Text("命中 = 选股公式最后一条输出线的最新值 > 0")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.tertiaryLabel))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyText: String {
        switch runner.phase {
        case .idle:      return "点击开始跑选股"
        case .preparing: return "正在准备行情数据…"
        case .running:   return "正在扫描…"
        case .finished:  return "当前没有命中的标的"
        case .cancelled: return "已取消"
        }
    }

    private func hitRow(_ hit: StrategyPickHit) -> some View {
        let isOn = selected.contains(hit.metaID)
        return Button {
            toggle(hit.metaID)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isOn ? Color.blue : Color(.tertiaryLabel))

                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(hit.code)
                        .font(.system(size: 11))
                        .foregroundColor(Color(.secondaryLabel))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(hit.lastPrice.map { SimFormat.price($0) } ?? "—")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(hit.lastPrice == nil ? Color(.secondaryLabel) : Color.primary)
                        .lineLimit(1)
                    Text(hit.changePct.map { SimFormat.pct($0) } ?? "—")
                        .font(.system(size: 11))
                        .foregroundColor(changeColor(hit.changePct))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部说明

    private var bottomNotice: some View {
        Text("命中基于本地日线库最后一根，非实时盘中")
            .font(.system(size: 11))
            .foregroundColor(Color(.secondaryLabel))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Color(.systemBackground))
            .overlay(alignment: .top) {
                Rectangle().fill(Color(.separator)).frame(height: 0.5)
            }
    }

    // MARK: - 派生数据

    private var isAllSelected: Bool {
        !runner.hits.isEmpty && selected.count == runner.hits.count
    }

    private func ratio(_ done: Int, _ total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(done) / Double(total)
    }

    /// 涨红跌绿（与模拟页盈亏配色一致）
    private func changeColor(_ pct: Double?) -> Color {
        guard let pct = pct else { return Color(.secondaryLabel) }
        return pct < 0 ? Color(.systemGreen) : Color(.systemRed)
    }

    // MARK: - 行为

    private func start() {
        runner.start(doc: doc, pool: pool)
    }

    private func toggle(_ metaID: Int) {
        if selected.contains(metaID) {
            selected.remove(metaID)
        } else {
            selected.insert(metaID)
        }
    }

    private func toggleAll() {
        if isAllSelected {
            selected = []
        } else {
            selected = Set(runner.hits.map { $0.metaID })
        }
    }

    /// 把勾选的命中还原成 MetaItem 交给宿主（保持命中清单顺序）
    private func generate() {
        var lookup: [Int: MetaItem] = [:]
        for meta in db.metaList { lookup[meta.id] = meta }
        let metas = runner.hits.filter { selected.contains($0.metaID) }.compactMap { lookup[$0.metaID] }
        guard !metas.isEmpty else { return }
        onGenerate(metas)
    }
}
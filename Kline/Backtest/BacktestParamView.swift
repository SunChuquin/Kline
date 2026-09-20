//
//  BacktestParamView.swift
//  Kline
//
//  回测参数页：区间 / 初始资金 / 候选池 / 成交口径 / 入场信号，确认后交给回测执行器。
//
//  Created by 孙楚昆 on 2026/9/20.
//

import SwiftUI

/// 历史回测参数页（策略详情页内的全屏 overlay 子页，不用 sheet / fullScreenCover）
///
/// 只负责收集参数并回传，不持有回测结果；「开始回测」后由宿主关闭本页并启动执行器。
struct BacktestParamView: View {
    /// 被回测的策略文档（TRADE 段提供初始资金默认值与提示）
    var doc: FormulaDoc
    var onClose: () -> Void
    var onRun: (BacktestParams) -> Void

    /// 回测执行器：仅用于「运行中」把「开始回测」置灰
    @ObservedObject private var backtest = StrategyBacktestRunner.shared

    /// 回测区间（交易日）
    @State private var days: Int = 250
    /// 初始资金输入文本（字符串态，提交时再解析）
    @State private var capitalText: String
    /// 候选池
    @State private var pool: StrategyPickPool = .market
    /// 是否按信号次日开盘成交
    @State private var executeNextOpen: Bool = true
    /// 是否把选股命中当作买入信号
    @State private var includeEntry: Bool = true

    /// 区间可选项（交易日）
    private let dayOptions: [Int] = [60, 120, 250, 500]
    /// 初始资金快捷档
    private let capitalChips: [(title: String, value: Double)] = [
        ("10 万", 100000), ("50 万", 500000), ("100 万", 1000000)
    ]

    // 显式 init：本视图含 private 存储属性，合成 memberwise init 会是 private；
    // 初始资金默认取绑定账户的初始资金，取不到用 10 万。
    init(doc: FormulaDoc, onClose: @escaping () -> Void, onRun: @escaping (BacktestParams) -> Void) {
        self.doc = doc
        self.onClose = onClose
        self.onRun = onRun
        let fallback = doc.trade.accountIDs
            .compactMap { id in SimStore.shared.accounts.first { $0.id == id } }
            .first?.initialCapital ?? 100000
        _capitalText = State(initialValue: Self.plainNumber(fallback))
    }

    // MARK: - 页面

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if doc.trade.isEmpty { tradeWarning }
                    paramsCard
                    Color.clear.frame(height: 8)
                }
                .padding(16)
            }

            noticeBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        // 内容贴物理屏幕底边（全 App 统一贴底为 0）
        .ignoresSafeArea(.container, edges: .bottom)
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

            Text("历史回测")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            Button {
                run()
            } label: {
                Text("开始回测")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(backtest.isRunning ? Color(.tertiaryLabel) : Color.blue)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(backtest.isRunning)
            .padding(.trailing, 16)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - 未配置交易指令提示（不阻断回测）

    private var tradeWarning: some View {
        Text("建议先在编辑里配置交易指令（方向 / 数量）")
            .font(.system(size: 12))
            .foregroundColor(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 参数卡片

    private var paramsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("回测参数")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            VStack(spacing: 0) {
                row("回测区间") { daysSegmented }
                divider
                row("初始资金") {
                    HStack(spacing: 4) {
                        TextField("100000", text: $capitalText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 120)
                        Text("元")
                            .font(.system(size: 13))
                            .foregroundColor(Color(.secondaryLabel))
                    }
                }
                capitalChipsRow
                divider
                row("候选池") { poolSegmented }
                divider
                toggleBlock(title: "信号次日开盘成交",
                            isOn: $executeNextOpen,
                            note: "关闭则按信号当日收盘价成交；开启更贴近实盘，避免用当日收盘决定当日成交的前视偏差")
                divider
                toggleBlock(title: "把选股命中当作买入信号",
                            isOn: $includeEntry,
                            note: "关闭则只回测已有持仓上的规则（本策略无持仓来源时结果会为空）")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
    }

    /// 一行「左标签 + 右控件」（行高 ≥44pt）
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
            Spacer(minLength: 8)
            content()
        }
        .frame(minHeight: 44)
    }

    private var divider: some View {
        Rectangle().fill(Color(.separator)).frame(height: 0.5)
    }

    /// 区间分段（60 / 120 / 250 / 500 交易日）
    private var daysSegmented: some View {
        TradeSegmentedRow(options: dayOptions.map { d in
            TradeSegOption(id: String(d), title: "\(d)", tint: nil, selected: d == days)
        }, height: 32) { id in
            guard let next = Int(id), next != days else { return }
            days = next
        }
        .frame(width: 220)
    }

    /// 候选池分段（全市场 / 自选）
    private var poolSegmented: some View {
        TradeSegmentedRow(options: StrategyPickPool.allCases.map { item in
            TradeSegOption(id: item.rawValue, title: item.title, tint: nil, selected: item == pool)
        }, height: 32) { id in
            guard let next = StrategyPickPool(rawValue: id), next != pool else { return }
            pool = next
        }
        .frame(width: 160)
    }

    /// 初始资金快捷档（10 万 / 50 万 / 100 万）
    private var capitalChipsRow: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(capitalChips.indices, id: \.self) { index in
                let chip = capitalChips[index]
                Button {
                    capitalText = Self.plainNumber(chip.value)
                } label: {
                    Text(chip.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color.blue)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.systemBackground)))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 44)
    }

    /// 开关块：开关标题 13pt + 说明 11pt 灰
    private func toggleBlock(title: String, isOn: Binding<Bool>, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isOn) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(SwitchToggleStyle())
            .frame(minHeight: 44)

            Text(note)
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 底部口径说明（固定展示）

    private var noticeBar: some View {
        Text("回测基于本地日线库；不还原盘中路径，回落卖出按 bar 内先高后低假设；条件单实盘只吃行情快照，触发必然晚于回测")
            .font(.system(size: 11))
            .foregroundColor(Color(.secondaryLabel))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
            .overlay(alignment: .top) {
                Rectangle().fill(Color(.separator)).frame(height: 0.5)
            }
    }

    // MARK: - 行为

    /// 组装参数并回传给宿主（区间 / 初始资金 / 候选池 / 成交口径 / 入场信号；周期固定日线）
    private func run() {
        let parsed = Double(capitalText.trimmingCharacters(in: .whitespaces)) ?? 0
        var params = BacktestParams()
        params.days = days
        params.initialCapital = parsed > 0 ? parsed : 100000
        params.pool = pool
        params.executeNextOpen = executeNextOpen
        params.includeEntry = includeEntry
        onRun(params)
    }

    /// 金额的最短可回读表示（整数不带小数），供输入框与快捷档使用
    private static func plainNumber(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(v)
    }
}
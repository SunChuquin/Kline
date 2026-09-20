//
//  BacktestResultView.swift
//  Kline
//
//  回测结果页：指标卡 + 净值曲线 + 逐笔交易明细 + 提示与跳过明细。
//
//  Created by 孙楚昆 on 2026/9/20.
//

import SwiftUI

/// 历史回测结果页（策略详情页内的全屏 overlay 子页，不用 sheet / fullScreenCover）
///
/// 纯展示，不持有运行状态；「重跑」由宿主（策略详情页）负责，本页只提供关闭。
struct BacktestResultView: View {
    var result: BacktestResult
    var onClose: () -> Void

    /// 明细默认展示条数
    private let defaultTradeLimit = 50
    /// 是否展开全部明细
    @State private var showAllTrades = false
    /// 跳过明细是否展开（默认折叠）
    @State private var showSkips = false

    // 显式 init：本视图含 private 存储属性，合成 memberwise init 会是 private
    init(result: BacktestResult, onClose: @escaping () -> Void) {
        self.result = result
        self.onClose = onClose
    }

    // MARK: - 页面

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statsCard
                    chartCard
                    if result.trades.isEmpty {
                        emptyCard
                    } else {
                        tradesCard
                    }
                    noticeCard
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

            Text("回测结果")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            // 占位：与左侧「返回」等宽，保证标题居中
            Color.clear.frame(width: 66, height: 44)
                .padding(.trailing, 16)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - 指标卡

    private var statsCard: some View {
        card("指标") {
            // 首行：初始资金 → 期末净值 · 平仓笔数
            Text("初始资金 \(SimFormat.amount0(result.stats.initialCapital)) → 期末净值 \(SimFormat.amount0(result.stats.finalEquity)) · 平仓 \(result.stats.roundTrips) 笔")
                .font(.system(size: 12))
                .foregroundColor(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                metricCell("总收益", pctText(result.stats.totalReturn),
                           color: changeColor(result.stats.totalReturn))
                metricCell("年化", pctText(result.stats.annualized),
                           color: changeColor(result.stats.annualized))
                metricCell("最大回撤", pctText(-abs(result.stats.maxDrawdown)),
                           color: Color(.systemGreen))
                metricCell("胜率", pctText(result.stats.winRate), color: Color.primary)
                metricCell("盈亏比", String(format: "%.2f", result.stats.profitFactor),
                           color: Color.primary)
                metricCell("成交 / 平均持仓",
                           "\(result.stats.tradeCount) 笔 · \(String(format: "%.1f", result.stats.avgHoldDays)) 天",
                           color: Color.primary)
            }
        }
    }

    /// 指标格：标题 11pt 灰 + 数值 16pt bold
    private func metricCell(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabel))
                .lineLimit(1)
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemBackground)))
    }

    // MARK: - 净值曲线卡

    private var chartCard: some View {
        card("净值曲线") {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text("区间 \(dateText(firstDate)) ~ \(dateText(lastDate))")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabel))
                    .lineLimit(1)
            }

            NetValueChartView(points: result.equity,
                              maxDrawdownRange: result.maxDrawdownRange,
                              baseline: result.stats.initialCapital)
                .padding(.top, 4)
                .padding(.bottom, 4)
        }
    }

    // MARK: - 交易明细卡

    private var tradesCard: some View {
        let limit = showAllTrades ? result.trades.count : min(defaultTradeLimit, result.trades.count)
        let rows = Array(result.trades.prefix(limit))
        return card("交易明细") {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    tradeHeaderRow
                    Rectangle().fill(Color(.separator)).frame(height: 0.5)
                    ForEach(rows) { trade in
                        tradeRow(trade)
                        Rectangle().fill(Color(.separator)).frame(height: 0.5)
                    }
                }
            }

            if result.trades.count > defaultTradeLimit && !showAllTrades {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showAllTrades = true }
                } label: {
                    Text("展开全部（共 \(result.trades.count) 条）")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color.blue)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 明细列宽（合计超出屏宽时整表横向滚动）
    private let colDate: CGFloat = 84
    private let colName: CGFloat = 116
    private let colDir: CGFloat = 40
    private let colRule: CGFloat = 68
    private let colQty: CGFloat = 54
    private let colPrice: CGFloat = 62
    private let colAmount: CGFloat = 84
    private let colPnL: CGFloat = 78

    private var tradeHeaderRow: some View {
        HStack(spacing: 6) {
            tableCell("日期", width: colDate, color: Color(.secondaryLabel), size: 11)
            tableCell("标的", width: colName, color: Color(.secondaryLabel), size: 11)
            tableCell("方向", width: colDir, color: Color(.secondaryLabel), size: 11, alignment: .center)
            tableCell("规则", width: colRule, color: Color(.secondaryLabel), size: 11, alignment: .center)
            tableCell("数量", width: colQty, color: Color(.secondaryLabel), size: 11, alignment: .trailing)
            tableCell("成交价", width: colPrice, color: Color(.secondaryLabel), size: 11, alignment: .trailing)
            tableCell("金额", width: colAmount, color: Color(.secondaryLabel), size: 11, alignment: .trailing)
            tableCell("盈亏", width: colPnL, color: Color(.secondaryLabel), size: 11, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    private func tradeRow(_ trade: BacktestTrade) -> some View {
        HStack(spacing: 6) {
            tableCell(dateText(trade.date), width: colDate, color: Color(.secondaryLabel), size: 12)
            tableCell("\(trade.name) \(trade.code)", width: colName, color: Color.primary, size: 12)
            tableCell(trade.direction.title, width: colDir, color: dirColor(trade.direction),
                      size: 12, alignment: .center)
            tableCell(trade.ruleKind?.title ?? "—", width: colRule, color: Color(.secondaryLabel),
                      size: 12, alignment: .center)
            tableCell(SimFormat.shares(trade.qty), width: colQty, color: Color.primary,
                      size: 12, alignment: .trailing)
            tableCell(SimFormat.price(trade.price), width: colPrice, color: Color.primary,
                      size: 12, alignment: .trailing)
            tableCell(SimFormat.amount(trade.amount), width: colAmount, color: Color.primary,
                      size: 12, alignment: .trailing)
            pnlCell(trade)
        }
        .padding(.vertical, 8)
    }

    /// 盈亏列：已平仓带符号着色（盈利红 / 亏损绿），未平仓入场笔显示「持仓中」
    @ViewBuilder
    private func pnlCell(_ trade: BacktestTrade) -> some View {
        if let pnl = trade.realizedPnL {
            tableCell(SimFormat.signed(pnl), width: colPnL, color: changeColor(pnl),
                      size: 12, alignment: .trailing)
        } else {
            tableCell(trade.direction.isBuy ? "持仓中" : "—", width: colPnL,
                      color: Color(.secondaryLabel), size: 12, alignment: .trailing)
        }
    }

    private func tableCell(_ text: String, width: CGFloat, color: Color, size: CGFloat,
                           alignment: Alignment = .leading) -> some View {
        Text(text)
            .font(.system(size: size))
            .foregroundColor(color)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    // MARK: - 空态卡

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Text("本次区间内没有产生任何成交")
                .font(.system(size: 13))
                .foregroundColor(Color(.secondaryLabel))
            Text("请检查候选池 / 回测区间 / 入场信号开关")
                .font(.system(size: 11))
                .foregroundColor(Color(.tertiaryLabel))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - 提示卡

    private var noticeCard: some View {
        card("提示") {
            Text("扫描 \(result.scannedCount) 只 · 命中 \(result.hitCount) 只")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)

            ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning)
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !result.skipped.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showSkips.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text("跳过 \(result.skipped.count) 条")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(Color(.secondaryLabel))
                        Image(systemName: showSkips ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(.secondaryLabel))
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showSkips {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(result.skipped.enumerated()), id: \.offset) { _, item in
                            Text(item)
                                .font(.system(size: 12))
                                .foregroundColor(Color(.secondaryLabel))
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

    // MARK: - 派生数据 / 格式

    private var firstDate: Int { result.equity.first?.date ?? 0 }
    private var lastDate: Int { result.equity.last?.date ?? 0 }

    /// 比例 → 带符号百分比文案（执行器输出的比率为小数，此处 ×100）
    private func pctText(_ ratio: Double) -> String {
        SimFormat.pct(ratio * 100)
    }

    /// A 股语义：盈利红 / 亏损绿（与模拟交易配色一致）
    private func changeColor(_ v: Double) -> Color {
        if v < 0 { return Color(.systemGreen) }
        if v > 0 { return Color(.systemRed) }
        return Color.primary
    }

    private func dirColor(_ dir: SimOrderDirection) -> Color {
        dir.isBuy ? Color(.systemRed) : Color(.systemGreen)
    }

    /// Int(YYYYMMDD) → "YYYY-MM-DD"（非法值原样返回）
    private func dateText(_ v: Int) -> String {
        guard v > 0 else { return "—" }
        let text = String(v)
        guard text.count == 8 else { return text }
        let y = text.prefix(4)
        let m = text.dropFirst(4).prefix(2)
        let d = text.suffix(2)
        return "\(y)-\(m)-\(d)"
    }
}
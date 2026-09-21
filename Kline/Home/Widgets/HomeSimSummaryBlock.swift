//
//  HomeSimSummaryBlock.swift
//  Kline
//
//  模拟账户汇总：总资产 / 当日盈亏 / 持仓占比 + 持仓 Top N，整块可点切模拟页。
//

import SwiftUI

// MARK: - 模拟账户汇总

/// 模拟账户汇总（全部账户）：总资产 / 当日盈亏（金额 + 百分比）/ 持仓占比 + 持仓 Top N。
/// 金额与百分比格式化复用 SimFormat（与模拟页 SimSummaryBand 同口径）；
/// 整块可点 → 切模拟页（由容器把 `onTap` 接到 `onSelectTab(3)`）。
struct HomeSimSummaryBlock: View {
    @ObservedObject var model: HomePageModel
    let compact: Bool
    let onTap: () -> Void

    /// 直接观察行缓存：持仓现价 / 盈亏随 bars 到位刷新
    @ObservedObject private var rowCache = MarketRowCache.shared

    var body: some View {
        let summary = model.simSummary
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            // 总资产（大字）
            VStack(alignment: .leading, spacing: 2) {
                Text("总资产")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(SimFormat.amount0(summary.totalAssets))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }

            // 当日盈亏 + 持仓占比
            HStack(alignment: .top, spacing: 14) {
                metric(label: "当日盈亏", value: SimFormat.signed0(summary.dayProfit),
                       extra: SimFormat.pct(summary.dayProfitPct * 100),
                       color: homeProfitColor(summary.dayProfit))
                metric(label: "持仓占比", value: SimFormat.pct(summary.positionPct * 100),
                       extra: nil, color: .primary)
            }

            // 持仓 Top N（行高与自选块一致）
            if model.simTopPositions.isEmpty {
                Text("暂无持仓")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: compact ? 44 : 48, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.simTopPositions) { p in
                        positionRow(p)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    /// 指标项：标签 + 数值（+ 可选百分比）
    private func metric(label: String, value: String, extra: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(color)
                    .lineLimit(1)
                if let extraText = extra {
                    Text(extraText)
                        .font(.system(size: 11))
                        .foregroundColor(color)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 持仓行：名称 + 代码 / 现价 / 盈亏（金额 + 百分比，着色）
    private func positionRow(_ p: SimPosition) -> some View {
        let snap = model.simSnapshot(for: p)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(p.code)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(SimFormat.price(snap.lastPrice))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            VStack(alignment: .trailing, spacing: 2) {
                Text(SimFormat.signed(snap.profit))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(homeProfitColor(snap.profit))
                    .lineLimit(1)
                Text(SimFormat.pct(snap.profitPct * 100))
                    .font(.system(size: 11))
                    .foregroundColor(homeProfitColor(snap.profitPct))
                    .lineLimit(1)
            }
        }
        .frame(height: compact ? 40 : 48)
        // 紧凑行 40pt：外层上下各补 2pt，命中区补足（整块本身可点，此处仅保证行高一致）
        .padding(.vertical, compact ? 2 : 0)
    }
}
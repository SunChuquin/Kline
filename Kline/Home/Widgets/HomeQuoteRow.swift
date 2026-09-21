//
//  HomeQuoteRow.swift
//  Kline
//
//  行情行：名称 + 代码 / 现价 / 涨跌幅胶囊（可选迷你走势），自选块与涨幅榜列表共用。
//

import SwiftUI

// MARK: - 行情行（自选块 / 涨幅榜列表共用）

/// 行情行：名称 + 代码 / 现价 / 涨跌幅胶囊（可选迷你走势）。
/// 行高固定（常规 48 / 紧凑 40），点整行打开该标的 K 线详情。
struct HomeQuoteRow: View {
    let row: MarketRow
    /// 点击上下文（详情页副图左右滑动切换用）
    let context: [MarketRow]
    let compact: Bool
    let showsSparkline: Bool
    let onOpen: (MetaItem, [MetaItem]) -> Void

    var body: some View {
        let meta = row.meta
        let pct = row.number(.changePct)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.name)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(meta.displayCode)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(row.text(.latestPrice))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(homeQuoteTint(pct))
                .lineLimit(1)

            Text(row.text(.changePct))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(homePillColor(pct))
                .cornerRadius(6)

            if showsSparkline {
                MarketSparkline(closes: Array(row.recentCloses.suffix(20)), up: (pct ?? 0) >= 0)
                    .frame(width: 60, height: 24)
            }
        }
        .frame(height: compact ? 40 : 48)
        // 紧凑行 40pt：行外层上下各补 2pt（透明），命中区补足到 ≥ 44pt，视觉高度不变
        .padding(.vertical, compact ? 2 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen(meta, context.map { $0.meta })
        }
    }
}
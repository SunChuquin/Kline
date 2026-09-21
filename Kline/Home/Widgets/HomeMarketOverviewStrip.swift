//
//  HomeMarketOverviewStrip.swift
//  Kline
//
//  大盘概览条：横向指数项 + 沪深主板涨跌家数。
//

import SwiftUI

// MARK: - 大盘概览条

/// 大盘概览条：横向 4 项指数（名称 / 现价 / 涨跌幅，涨红跌绿）+ 沪深主板涨跌家数。
/// 点指数项 → 打开该指数 K 线详情；`breadth == nil` 时显示「加载中」，不伪造数值。
struct HomeMarketOverviewStrip: View {
    /// 指数行（HomePageModel.indexQuotes）
    let rows: [MarketRow]
    /// 沪深主板涨跌家数（nil = 尚无有效聚合）
    let breadth: HomeBreadth?
    let compact: Bool

    /// 直接观察行缓存：bars 陆续到位时本块自行刷新
    @ObservedObject private var rowCache = MarketRowCache.shared

    /// 指数区固定高度（≥ 44pt 命中区）：加载态与就绪态一致，bars 到位时不抖动
    private var indexAreaHeight: CGFloat { compact ? 50 : 52 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            if rows.isEmpty {
                Text("指数加载中")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: indexAreaHeight, alignment: .leading)
            } else {
                HStack(spacing: 0) {
                    ForEach(rows) { row in
                        indexCell(row)
                    }
                }
            }
            breadthLine
        }
    }

    /// 单个指数：名称 / 现价 / 涨跌幅，点开该指数 K 线详情
    private func indexCell(_ row: MarketRow) -> some View {
        let meta = row.meta
        let pct = row.number(.changePct)
        return VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            Text(meta.name)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(row.text(.latestPrice))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(homeQuoteTint(pct))
                .lineLimit(1)
            Text(row.text(.changePct))
                .font(.system(size: 12))
                .foregroundColor(homeQuoteTint(pct))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: indexAreaHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            DetailRouter.shared.open(meta, in: rows.map { $0.meta })
        }
    }

    /// 涨跌家数：涨 N · 平 N · 跌 N / 涨停 N / 跌停 N（涨红、跌绿、平用次要色）
    @ViewBuilder
    private var breadthLine: some View {
        if let b = breadth {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("涨 \(b.up)").foregroundColor(.red)
                    Text("·").foregroundColor(.secondary)
                    Text("平 \(b.flat)").foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                    Text("跌 \(b.down)").foregroundColor(.green)
                }
                .font(.system(size: 12))

                HStack(spacing: 6) {
                    Text("涨停 \(b.limitUp)").foregroundColor(.red)
                    Text("/").foregroundColor(.secondary)
                    Text("跌停 \(b.limitDown)").foregroundColor(.green)
                }
                .font(.system(size: 12))
            }
        } else {
            Text("加载中")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        }
    }
}
//
//  HomeMarketOverviewStrip.swift
//  Kline
//
//  大盘概览条：横向指数项 + 沪深主板涨跌家数。
//

import SwiftUI

// MARK: - 大盘概览条

/// 大盘概览条：横向 4 项指数（名称 / 现价 / 涨跌幅，涨红跌绿）+ 沪深主板涨跌家数。
/// 点指数项 → 打开该指数 K 线详情；
/// 数据库就绪后仍无对应数据时显示「暂无指数数据」/「暂无涨跌数据」，
/// 加载中才显示「指数加载中」/「加载中」，不伪造数值。
///
/// 竖屏垂直堆栈规则（2026-10-20）：页面可用宽 < 600（统一宽度判定，
/// 如 414pt）下指数行从 4 项等宽 HStack（每项仅 ~95pt，名称/价格/涨跌幅三行挤在窄列）
/// 改为 **VStack 每指数一行全宽**（名称左 / 现价+涨跌幅右，行高 44 可点）；
/// 横屏 / iPad（≥600）保持 4 项等宽横排原样。判定来自宿主注入的实测宽，
/// 配置驱动（JSON）与硬编码两条渲染路径共用本组件，一处改两路全生效。
struct HomeMarketOverviewStrip: View {
    /// 指数行（HomePageModel.indexQuotes）
    let rows: [MarketRow]
    /// 沪深主板涨跌家数（nil = 尚无有效聚合）
    let breadth: HomeBreadth?
    let compact: Bool

    /// 统一紧凑判定：宿主注入的实测可用宽 < 600 → 指数行垂直堆叠；
    /// 未注入时回退 sizeClass（Preview / 独立宿主仍可用）
    @CompactWidthValue private var isCompactWidth

    /// 生效的紧凑视觉：配置值或竖屏（统一宽度判定覆盖，与 HomeFavoritesBlock 同口径）
    private var effectiveCompact: Bool { compact || isCompactWidth }

    /// 直接观察行缓存：bars 陆续到位时本块自行刷新
    @ObservedObject private var rowCache = MarketRowCache.shared
    /// 数据库加载态：区分「还在加载」与「加载完但没有该类数据」，避免永远显示「加载中」
    @ObservedObject private var db = DatabaseManager.shared

    /// 指数区固定高度（≥ 44pt 命中区）：加载态与就绪态一致，bars 到位时不抖动
    private var indexAreaHeight: CGFloat { effectiveCompact ? 50 : 52 }

    var body: some View {
        VStack(alignment: .leading, spacing: effectiveCompact ? 8 : 10) {
            if rows.isEmpty {
                Text(db.isLoaded ? "暂无指数数据" : "指数加载中")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: indexAreaHeight, alignment: .leading)
            } else if isCompactWidth {
                // 竖屏：垂直堆叠——每指数一行全宽（名称左 / 现价+涨跌幅右）
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        stackedRow(row)
                    }
                }
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

    /// 竖屏指数行：名称左 / 现价（大）+ 涨跌幅（胶囊）右，整行 44pt 命中区可点
    private func stackedRow(_ row: MarketRow) -> some View {
        let meta = row.meta
        let pct = row.number(.changePct)
        return HStack(spacing: 10) {
            Text(meta.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(row.text(.latestPrice))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(homeQuoteTint(pct))
                .lineLimit(1)
            Text(row.text(.changePct))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(homePillColor(pct))
                .cornerRadius(6)
                .lineLimit(1)
        }
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            DetailRouter.shared.open(meta, in: rows.map { $0.meta })
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

    /// 库内是否存在沪深主板标的：用于区分「主板数据还没算出来」与「库内本来就没有主板数据」。
    /// 只在 breadth 为 nil 时参与文案，正常有数据后不再走这条分支。
    private var hasMainBoardMetas: Bool {
        db.metaList.contains { $0.type == "沪深主板" }
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
            Text(db.isLoaded && !hasMainBoardMetas ? "暂无涨跌数据" : "加载中")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        }
    }
}
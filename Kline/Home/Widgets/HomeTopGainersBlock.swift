//
//  HomeTopGainersBlock.swift
//  Kline
//
//  涨幅榜 Top5：列表行 / 横滑 chips 两种呈现，口径同一份数据。
//

import SwiftUI

// MARK: - 涨幅榜

/// 涨幅榜 Top5：两种呈现（列表行 / 横滑 chips），口径同一份数据（HomePageModel.topGainers）。
/// 点任一项打开该标的 K 线详情；`rows` 为空且 `!isReady` 时显示「数据加载中」，
/// 数据库已加载且库内无沪深主板标的时显示「暂无数据」。
struct HomeTopGainersBlock: View {
    /// 呈现方式：列表行 / 横滑 chips
    enum Style {
        case list
        case chips
    }

    let rows: [MarketRow]
    let style: Style
    let compact: Bool
    let isReady: Bool
    let onOpen: (MetaItem, [MetaItem]) -> Void

    /// 竖屏垂直堆栈规则（2026-10-20）：竖屏（统一宽度判定 < 600）视觉一律紧凑
    /// （与 HomeFavoritesBlock 同口径，配置写死的 compact 参数被宽度判定覆盖）
    @CompactWidthValue private var isCompactWidth
    private var effectiveCompact: Bool { compact || isCompactWidth }

    /// 直接观察行缓存：bars 陆续到位时本块自行刷新
    @ObservedObject private var rowCache = MarketRowCache.shared
    /// 数据库加载态：区分「还在加载」与「库内没有沪深主板标的」，避免永远显示「数据加载中」
    @ObservedObject private var db = DatabaseManager.shared

    /// 库内是否存在沪深主板标的（无主板标的时加载完应显示「暂无数据」而不是一直加载）
    private var hasMainBoardMetas: Bool {
        db.metaList.contains { $0.type == "沪深主板" }
    }

    var body: some View {
        if rows.isEmpty {
            Text(isReady || (db.isLoaded && !hasMainBoardMetas) ? "暂无数据" : "数据加载中")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: effectiveCompact ? 44 : 48, alignment: .leading)
        } else {
            switch style {
            case .list:
                listBody
            case .chips:
                chipsBody
            }
        }
    }

    /// 列表行呈现（与自选块同款行，无走势图）
    private var listBody: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HomeQuoteRow(row: row, context: rows, compact: effectiveCompact,
                             showsSparkline: false, onOpen: onOpen)
            }
        }
    }

    /// 横滑 chips 呈现（每 chip 宽 150 / 高 72）
    private var chipsBody: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(rows) { row in
                    chip(row)
                }
            }
        }
    }

    private func chip(_ row: MarketRow) -> some View {
        let meta = row.meta
        let pct = row.number(.changePct)
        return VStack(alignment: .leading, spacing: 4) {
            Text(meta.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
            Text(row.text(.latestPrice))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(homeQuoteTint(pct))
                .lineLimit(1)
            Text(row.text(.changePct))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(homePillColor(pct))
                .cornerRadius(6)
        }
        .padding(.horizontal, 10)
        .frame(width: 150, height: 72, alignment: .leading)
        .background(Color(.systemBackground))
        .cornerRadius(10)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen(meta, rows.map { $0.meta })
        }
    }
}
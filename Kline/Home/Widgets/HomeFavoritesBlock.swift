//
//  HomeFavoritesBlock.swift
//  Kline
//
//  我的自选块：行情行列表 / 空态整块可点切自选页。
//

import SwiftUI

// MARK: - 我的自选

/// 我的自选：每行 = 名称 + 代码 / 现价 / 涨跌幅胶囊（可选迷你走势）；点行打开 K 线详情。
/// 空态整块可点 → 切自选页（由容器把 `onEmptyTap` 接到 `onSelectTab(1)`）。
struct HomeFavoritesBlock: View {
    let rows: [MarketRow]
    let compact: Bool
    let showsSparkline: Bool
    let onOpen: (MetaItem, [MetaItem]) -> Void
    let onEmptyTap: () -> Void

    /// 直接观察行缓存：bars 陆续到位时本块自行刷新
    @ObservedObject private var rowCache = MarketRowCache.shared

    var body: some View {
        if rows.isEmpty {
            Text("暂无自选，去自选页添加")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: compact ? 44 : 48, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onEmptyTap() }
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HomeQuoteRow(row: row, context: rows, compact: compact,
                                 showsSparkline: showsSparkline, onOpen: onOpen)
                }
            }
        }
    }
}
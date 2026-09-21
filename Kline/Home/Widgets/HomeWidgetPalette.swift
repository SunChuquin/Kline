//
//  HomeWidgetPalette.swift
//  Kline
//
//  首页控件共享配色助手（涨红跌绿，平盘 / 无值用语义灰），跨控件文件使用。
//

import SwiftUI

// MARK: - 文件内配色助手（涨红跌绿，平盘 / 无值用语义灰）

/// 涨跌数字着色：涨红 / 跌绿 / 平盘或无值用主色
func homeQuoteTint(_ pct: Double?) -> Color {
    guard let p = pct else { return .primary }
    if p > 0 { return .red }
    if p < 0 { return .green }
    return .primary
}

/// 涨跌幅胶囊底色：平盘 / 无值用系统灰（避免暗示方向）
func homePillColor(_ pct: Double?) -> Color {
    guard let p = pct else { return Color(.systemGray) }
    if p > 0 { return .red }
    if p < 0 { return .green }
    return Color(.systemGray)
}

/// 盈亏配色（涨红跌绿）：与模拟模块 simProfitColor 同口径（后者为文件内私有，故此处重写）
func homeProfitColor(_ v: Double) -> Color {
    v < 0 ? Color(.systemGreen) : Color(.systemRed)
}
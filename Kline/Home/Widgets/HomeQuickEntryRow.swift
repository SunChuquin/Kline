//
//  HomeQuickEntryRow.swift
//  Kline
//
//  首页横滑快捷入口行：一行可左右拖动的入口卡片，三档共用。
//

import SwiftUI

// MARK: - 横滑快捷入口行（三档共用）

/// 首页横滑快捷入口行：一行可左右拖动的入口卡片。
/// 8 项 chip 合计宽度 > 1024pt（iPad mini 5 横屏），横屏下天然需要左右拖动 ——
/// 这是本次变更的核心诉求（首屏不再被宫格/列表占满），chip 的 minWidth 不要调小到能一屏放下。
/// - `kinds`：按顺序展示的入口；缺省（调用方不传）= 全量 8 项；显式空数组 = 零高度（用户清空配置）
struct HomeQuickEntryRow: View {
    var kinds: [HomeEntryKind] = HomeEntryKind.allCases
    let onTap: (HomeEntryKind) -> Void

    var body: some View {
        if kinds.isEmpty {
            // 显式清空：零高度占位，不保留任何竖向前缀间距
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(kinds) { kind in
                        HomeQuickEntryChip(kind: kind, action: { onTap(kind) })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }
}
//
//  HomeQuickEntryRow.swift
//  Kline
//
//  首页横滑快捷入口行：一行可左右拖动的入口卡片，三档共用。
//

import SwiftUI

// MARK: - 横滑快捷入口行（三档共用）

/// 首页横滑快捷入口行：一行可左右拖动的入口卡片。
/// 6 项 chip 合计约 1100pt > 1024pt（iPad mini 4 横屏），横屏下天然需要左右拖动 ——
/// 这是本次变更的核心诉求（首屏不再被宫格/列表占满），chip 的 minWidth 不要调小到能一屏放下。
struct HomeQuickEntryRow: View {
    let onTap: (HomeEntryKind) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(HomeEntryKind.allCases) { kind in
                    HomeQuickEntryChip(kind: kind, action: { onTap(kind) })
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}
//
//  HomeQuickEntryChip.swift
//  Kline
//
//  快捷入口卡片：图标 + 标题 + 一行说明，整卡可点。
//

import SwiftUI

/// 快捷入口卡片：图标 22pt + 标题 13pt + 一行说明 11pt。
/// 固定最小宽 168 / 最小高 68（命中区 ≥ 44pt）；点击整卡生效。
struct HomeQuickEntryChip: View {
    let kind: HomeEntryKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: kind.icon)
                    .font(.system(size: 22))
                    .foregroundColor(kind.tint)
                Text(kind.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Text(kind.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(minWidth: 168, minHeight: 68, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.entry.\(kind.rawValue)")
    }
}
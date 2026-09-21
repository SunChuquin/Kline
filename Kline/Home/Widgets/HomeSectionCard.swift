//
//  HomeSectionCard.swift
//  Kline
//
//  内容区块容器：小标题 + 内容，浅灰卡片。
//

import SwiftUI

// MARK: - 区块容器

/// 内容区块容器：小标题 + 内容，浅灰卡片。
/// 内边距紧凑 10 / 常规 12；块间距（12）由各档布局视图控制。
struct HomeSectionCard<Content: View>: View {
    let title: String
    /// 紧凑档：内边距更小（C 档通栏、D 档小卡）
    var compact: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            content
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}
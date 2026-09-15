//
//  MockData.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/7/1.
//

import SwiftUI

// MARK: - 通用横向滚动卡片组件
struct HorizontalScrollCard: View {
    let data: HorizontalCardData
    var onItemTap: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题栏
            HStack {
                Text(data.title)
                    .font(.headline)
                    .fontWeight(.bold)
                Spacer()

                if let time = data.updateTime {
                    Text(time)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                } else if data.showMore {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16))
                        .foregroundColor(.gray)
                }
            }

            // 横向滚动内容
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(data.items) { item in
                        Button(action: {
                            onItemTap?(item.title)
                        }) {
                            HorizontalCardItemView(item: item)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
    }
}

// MARK: - 单个卡片项视图
struct HorizontalCardItemView: View {
    let item: HorizontalCardItem

    var body: some View {
        if let icon = item.icon {
            // 图标类型
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: item.showBackground ? 28 : 24))
                    .foregroundColor(item.color)
                    .frame(width: item.showBackground ? 56 : nil, height: item.showBackground ? 56 : nil)
                    .background(item.showBackground ? Color(.systemGray5) : Color.clear)
                    .cornerRadius(item.showBackground ? 12 : 0)
                Text(item.title)
                    .font(.system(size: 12))
            }
        } else {
            // 文字类型（如行业数据）
            VStack(spacing: 8) {
                Text(item.title)
                    .font(.system(size: 14))
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(item.color)
                }
            }
            .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
            .background(Color(.systemGray5))
            .cornerRadius(8)
        }
    }
}
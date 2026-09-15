//
//  ListCard.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/7/1.
//

import SwiftUI

// MARK: - 通用列表卡片组件
struct ListCard: View {
    let data: ListCardData
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
                    Text("更多")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
            }

            // 列表内容
            VStack(spacing: 12) {
                ForEach(data.items) { item in
                    Button(action: {
                        onItemTap?(item.title)
                    }) {
                        HStack(spacing: 12) {
                            // 排名（可选）
                            if let rank = item.rank {
                                Text(String(rank))
                                    .font(.system(size: 14))
                                    .fontWeight(.bold)
                                    .foregroundColor(rank <= 3 ? .red : .gray)
                                    .frame(width: 24, alignment: .center)
                            }

                            // 标题
                            Text(item.title)
                                .font(.system(size: 14))
                                .lineLimit(1)

                            Spacer()

                            // 徽章（可选）
                            if let badge = item.badge {
                                Text(badge)
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                                    .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                                    .background(item.badgeColor)
                                    .cornerRadius(4)
                            }
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
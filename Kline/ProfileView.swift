//
//  ProfileView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/23.
//


import SwiftUI

struct ProfileView: View {
    @Binding var isPresented: Bool
    @State private var selectedItemTitle: String?
    @State private var isDetailPresented = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            HStack {
                // 返回按钮
                Button(action: {
                    isPresented = false
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24))
                }
                .padding(.leading, 16)

                // 标题
                Text("测试页面")
                    .font(.title)
                    .fontWeight(.bold)

                Spacer()
            }
            .background(Color(.systemBackground))
            .frame(height: 56)
            .padding(.top, -5)

            // 分隔线
            Divider()

            // 主内容区域
            VStack(spacing: 16) {
                // 上面部分：固定的热门行业卡片
                HorizontalScrollCard(data: industryData) { title in
                    selectedItemTitle = title
                    isDetailPresented = true
                }

                // 下面部分：左右分栏，可独立滑动
                HStack(spacing: 16) {
                    // 左侧部分
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 16) {
                            // 应用推荐卡片
                            HorizontalScrollCard(data: appRecommendData) { title in
                                selectedItemTitle = title
                                isDetailPresented = true
                            }

                            // 今日热点卡片
                            ListCard(data: hotNewsData) { title in
                                selectedItemTitle = title
                                isDetailPresented = true
                            }

                            // 市场动态卡片
                            HorizontalScrollCard(data: leftExtraData) { title in
                                selectedItemTitle = title
                                isDetailPresented = true
                            }

                            // 财经要闻卡片
                            ListCard(data: moreHotNewsData) { title in
                                selectedItemTitle = title
                                isDetailPresented = true
                            }

                            // 额外的占位卡片
                            Rectangle()
                                .fill(Color(.systemGray5))
                                .frame(height: 150)
                                .cornerRadius(12)
                        }
                        .padding(.trailing, 8)
                    }
                    .frame(maxWidth: .infinity)

                    // 右侧部分
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 16) {
                            // 数据中心卡片
                            HorizontalScrollCard(data: dataCenterData) { title in
                                selectedItemTitle = title
                                isDetailPresented = true
                            }

                            // 工具中心卡片
                            HorizontalScrollCard(data: rightExtraData) { title in
                                selectedItemTitle = title
                                isDetailPresented = true
                            }

                            // 更多热点新闻
                            ListCard(data: moreHotNewsData) { title in
                                selectedItemTitle = title
                                isDetailPresented = true
                            }

                            // 应用推荐（重复用于测试）
                            HorizontalScrollCard(data: appRecommendData) { title in
                                selectedItemTitle = title
                                isDetailPresented = true
                            }

                            // 额外的占位卡片
                            Rectangle()
                                .fill(Color(.systemGray4))
                                .frame(height: 200)
                                .cornerRadius(12)

                            // 另一个占位卡片
                            Rectangle()
                                .fill(Color(.systemGray5))
                                .frame(height: 180)
                                .cornerRadius(12)
                        }
                        .padding(.leading, 8)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
        .overlay(
            Group {
                if isDetailPresented, let title = selectedItemTitle {
                    DetailPage(isPresented: $isDetailPresented, title: title)
                        .transition(.opacity)
                }
            }
        )
    }
}

#Preview {
    ProfileView(isPresented: .constant(true))
}
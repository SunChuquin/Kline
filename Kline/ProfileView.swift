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

            // 主内容区域 - 可上下滑动
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    // 应用推荐卡片（使用通用组件）
                    HorizontalScrollCard(data: appRecommendData) { title in
                        selectedItemTitle = title
                        isDetailPresented = true
                    }

                    // 今日热点卡片（使用通用组件）
                    ListCard(data: hotNewsData) { title in
                        selectedItemTitle = title
                        isDetailPresented = true
                    }

                    // 热门行业卡片（使用通用组件）
                    HorizontalScrollCard(data: industryData) { title in
                        selectedItemTitle = title
                        isDetailPresented = true
                    }

                    // 数据中心卡片（使用通用组件）
                    HorizontalScrollCard(data: dataCenterData) { title in
                        selectedItemTitle = title
                        isDetailPresented = true
                    }
                }
                .padding(16)
            }
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
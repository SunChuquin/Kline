//
//  HomeView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/23.
//

import SwiftUI

struct HomeView: View {
    @Binding var isSearching: Bool
    @Binding var isProfilePresented: Bool
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 顶部控件栏 - 参考通达信手机版样式
            if isSearching {
                // 搜索模式：返回按钮 + 搜索框
                HStack {
                    Button(action: {
                        isSearching = false
                        searchText = ""
                        searchFocused = false
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 24))
                    }
                    .padding(.leading, 16)

                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                        TextField("搜索", text: $searchText)
                            .textFieldStyle(.plain)
                            .focused($searchFocused)
                    }
                    .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .background(Color(.systemGray5))
                    .cornerRadius(8)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(.systemBackground))
                .frame(minHeight: 56)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        searchFocused = true
                    }
                }
            } else {
                // 正常模式：左侧软件图标和名称 + 右侧用户入口按钮
                HStack {
                    // 软件图标和名称
                    HStack(spacing: 6) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 24))
                            .foregroundColor(.red)
                        Text("Kline")
                            .font(.system(size: 18))
                            .fontWeight(.bold)
                    }
                    .padding(.leading, 16)

                    Spacer()

                    // 用户入口按钮
                    Button(action: {
                        isProfilePresented = true
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.blue)
                            Text("登录")
                                .font(.system(size: 16))
                        }
                        .padding(EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2))
                        .background(Color(.systemGray5))
                        .cornerRadius(20)
                    }
                    .padding(.trailing, 16)
                }
                .background(Color(.systemBackground))
                .frame(minHeight: 56)
            }

            Divider()

            // 主内容区域
            if isSearching {
                // 搜索页面
                SearchPageView(searchText: $searchText)
                    .frame(maxHeight: .infinity)
            } else {
                // 首页内容
                VStack {
                    Text("首页")
                        .font(.title)
                    Text("欢迎来到首页")
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

#Preview {
    HomeView(isSearching: .constant(false), isProfilePresented: .constant(false))
}
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
                .frame(height: 56) // 与底部菜单栏高度一致
                .padding(.top, 0)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        searchFocused = true
                    }
                }
            } else {
                // 正常模式：仅显示人物图标按钮
                HStack {
                    Button(action: {
                        isProfilePresented = true
                    }) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.blue)
                    }
                    .padding(.leading, 16)

                    Spacer()
                }
                .background(Color(.systemBackground))
                .frame(height: 56) // 与底部菜单栏高度一致
                .padding(.top, 0)
            }

            // 分隔线
            Divider()

            // 主内容区域
            if isSearching {
                // 搜索页面
                SearchPageView(searchText: $searchText)
                    .frame(maxHeight: .infinity)
            } else {
                // 主页内容
                VStack {
                    Text("主页")
                        .font(.title)
                    Text("欢迎来到主页")
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

#Preview {
    HomeView(isSearching: .constant(false), isProfilePresented: .constant(false))
}
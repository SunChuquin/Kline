//
//  HomeSearchModeView.swift
//  Kline
//
//  首页搜索模式：返回按钮 + 自动聚焦搜索框 + 搜索结果页。
//

import SwiftUI

// MARK: - 搜索模式（三档共用，等价搬入改造前 HomeView 的搜索态）

/// 首页搜索模式：返回按钮 + 搜索框（自动聚焦）+ 搜索结果页。
/// 与改造前逐项一致：`.focused` 延时 0.05s 自动聚焦；点返回清空 `searchText` 并置 `isSearching = false`。
/// `@FocusState` 由本视图自己持有，容器只传两个绑定。
struct HomeSearchModeView: View {
    @Binding var searchText: String
    @Binding var isSearching: Bool
    @FocusState private var searchFocused: Bool

    init(searchText: Binding<String>, isSearching: Binding<Bool>) {
        _searchText = searchText
        _isSearching = isSearching
        _searchFocused = FocusState()
    }

    var body: some View {
        VStack(spacing: 0) {
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

            Divider()

            SearchPageView(searchText: $searchText)
                .frame(maxHeight: .infinity)
        }
    }
}
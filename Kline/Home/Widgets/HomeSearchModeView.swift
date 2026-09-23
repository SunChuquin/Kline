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
            // 顺序要紧：先撑满宽度、再定 56 高，最后铺底 ——
            // `.background` 若写在 `.frame(minHeight:)` 之前，背景只覆盖内容自然高度（约 40pt），
            // 被 56pt 框居中后上下各留约 8pt 透明带
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 56)
            .background(Color(.systemBackground))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    searchFocused = true
                }
            }

            Divider()

            SearchPageView(searchText: $searchText)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 整页铺底：本视图既作为首页搜索态、也作为行情页搜索浮层（MarketSheets overlay）呈现，
        // 无底色时行情表会从搜索区透出、点击还会穿透到背后的行情行上
        .background(Color(.systemBackground))
    }
}
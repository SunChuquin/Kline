//
//  MarketView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/23.
//

import SwiftUI

/// 行情页顶部 Tab 分类（对应 tdx_parser.py 生成的 meta.type 三个取值）
enum MarketTab: String, CaseIterable, Identifiable {
    case mainBoard = "沪深主板"
    case index = "沪深京指数"
    case extIndex = "扩展指数"
    var id: String { rawValue }
}

struct MarketView: View {
    @ObservedObject private var databaseManager = DatabaseManager.shared
    @State private var searchText = ""
    @State private var searchResults: [MetaItem] = []
    @FocusState private var isSearchFocused: Bool
    @State private var selectedTab: MarketTab = .mainBoard

    /// 当前 Tab 对应的 meta.type 值
    private var currentType: String {
        switch selectedTab {
        case .mainBoard: return "沪深主板"
        case .index: return "沪深京指数"
        case .extIndex: return "扩展行情指数"
        }
    }

    /// 当前 Tab 下的全部标的
    private var tabItems: [MetaItem] {
        databaseManager.metaList.filter { $0.type == currentType }
    }

    private var filteredItems: [MetaItem] {
        if searchText.isEmpty {
            return tabItems
        } else {
            // 搜索结果为全库匹配，再按当前 Tab 类型过滤
            return searchResults.filter { $0.type == currentType }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if databaseManager.isLoaded {
                if filteredItems.isEmpty {
                    emptyStateView(message: searchText.isEmpty ? "暂无标的" : "没有找到相关股票")
                } else {
                    stockListView
                }
            } else {
                loadingView
            }
        }
        .onChange(of: searchText) { newValue in
            if !newValue.isEmpty {
                databaseManager.searchMetaAsync(keyword: newValue) { results in
                    searchResults = results
                }
            } else {
                searchResults = []
            }
        }
    }

    private var headerView: some View {
        HStack(spacing: 8) {
            // 左侧 Tab 子标签
            HStack(spacing: 4) {
                ForEach(MarketTab.allCases) { tab in
                    Button(action: { selectedTab = tab }) {
                        Text(tab.rawValue)
                            .font(.system(size: 14, weight: selectedTab == tab ? .bold : .regular))
                            .foregroundColor(selectedTab == tab ? .blue : .secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .overlay(alignment: .bottom) {
                                if selectedTab == tab {
                                    Rectangle()
                                        .fill(Color.blue)
                                        .frame(height: 2)
                                        .padding(.horizontal, 9)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            // 右侧搜索栏
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                    .font(.system(size: 13))

                TextField("搜索", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(EdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 9))
            .background(Color(.systemGray5))
            .cornerRadius(10)
            .frame(maxWidth: 160)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private var stockListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredItems) { item in
                    stockRowView(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // 进入详情前先收起键盘，避免键盘残留到新页面
                            isSearchFocused = false
                            DetailRouter.shared.open(item, in: filteredItems)
                        }

                    Divider()
                        .padding(.leading, 80)
                }
            }
            .padding(.vertical, 4)
        }
        .refreshable {
            databaseManager.loadMetaList()
        }
    }

    private func stockRowView(item: MetaItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 16, weight: .medium))

                Text(item.code)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(item.type)
                    .font(.system(size: 12))
                    .foregroundColor(.blue)

                if let lastDate = item.lastDate {
                    Text(String(lastDate))
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("加载中...")
                .foregroundColor(.gray)
        }
        .frame(maxHeight: .infinity)
    }

    private func emptyStateView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.gray)

            Text(message)
                .foregroundColor(.gray)
        }
        .frame(maxHeight: .infinity)
    }
}

#Preview {
    MarketView()
}
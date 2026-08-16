//
//  MarketView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/23.
//

import SwiftUI

struct MarketView: View {
    @ObservedObject private var databaseManager = DatabaseManager.shared
    @State private var searchText = ""
    @State private var searchResults: [MetaItem] = []
    @FocusState private var isSearchFocused: Bool

    private var filteredItems: [MetaItem] {
        if searchText.isEmpty {
            return databaseManager.metaList
        } else {
            return searchResults
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if databaseManager.isLoaded {
                if filteredItems.isEmpty && !searchText.isEmpty {
                    emptyStateView(message: "没有找到相关股票")
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
        HStack(spacing: 12) {
            Text("行情")
                .font(.system(size: 18))
                .fontWeight(.bold)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                    .font(.system(size: 14))

                TextField("搜索股票", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            .background(Color(.systemGray5))
            .cornerRadius(10)
            .frame(maxWidth: 280)
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
                            DetailRouter.shared.item = item
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
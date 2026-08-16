//
//  SearchPageView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/24.
//

import SwiftUI

struct SearchPageView: View {
    @Binding var searchText: String
    @ObservedObject private var databaseManager = DatabaseManager.shared
    @State private var searchResults: [MetaItem] = []

    var body: some View {
        VStack(spacing: 0) {
            if !searchText.isEmpty {
                searchResultsView
            } else {
                defaultView
            }
        }
        .onChange(of: searchText) { newValue in
            if !newValue.isEmpty {
                performSearch()
            } else {
                searchResults = []
            }
        }
    }

    private var defaultView: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("热门搜索")
                    .font(.headline)
                    .padding(.leading, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(["贵州茅台", "比亚迪", "宁德时代", "东方财富", "药明康德"], id: \.self) { item in
                            Button(action: {
                                searchText = item
                            }) {
                                Text(item)
                                    .padding(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .background(Color(.systemGray5))
                                    .cornerRadius(20)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("股票类型")
                        .font(.headline)
                }
                .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(["沪深主板", "沪深京指数", "扩展行情指数"], id: \.self) { type in
                            Button(action: {
                                searchText = type
                            }) {
                                Text(type)
                                    .padding(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .background(Color(.systemGray5))
                                    .cornerRadius(20)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            Spacer()
        }
    }

    private var searchResultsView: some View {
        ScrollView {
            VStack(spacing: 0) {
                if searchResults.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                            .padding()
                        Text("搜索中...")
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 50)
                } else {
                    ForEach(searchResults) { item in
                        Button(action: {
                            DetailRouter.shared.item = item
                        }) {
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

                        Divider()
                            .padding(.leading, 80)
                    }
                }
            }
        }
    }

    private func performSearch() {
        databaseManager.searchMetaAsync(keyword: searchText) { results in
            searchResults = results
        }
    }
}

#Preview {
    SearchPageView(searchText: .constant(""))
}
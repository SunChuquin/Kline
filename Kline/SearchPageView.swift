//
//  SearchPageView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/24.
//

import SwiftUI

struct SearchPageView: View {
    @Binding var searchText: String

    var body: some View {
        VStack(spacing: 16) {
            // 热门搜索
            VStack(alignment: .leading, spacing: 8) {
                Text("热门搜索")
                    .font(.headline)
                    .padding(.leading, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(["贵州茅台", "比亚迪", "宁德时代", "东方财富", "药明康德"], id: \.self) { item in
                            Text(item)
                                .padding(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .background(Color(.systemGray5))
                                .cornerRadius(20)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // 搜索历史
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("搜索历史")
                        .font(.headline)
                    Spacer()
                    Button("清空") {
                        // 清空历史记录
                    }
                    .foregroundColor(.gray)
                }
                .padding(.horizontal, 16)

                if !searchText.isEmpty {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundColor(.gray)
                        Text(searchText)
                    }
                    .padding(.horizontal, 16)
                }
            }

            Spacer()
        }
    }
}

#Preview {
    SearchPageView(searchText: .constant(""))
}

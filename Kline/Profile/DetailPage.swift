//
//  DetailPage.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/7/1.
//

import SwiftUI

struct DetailPage: View {
    @Binding var isPresented: Bool
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            HStack {
                Button(action: {
                    isPresented = false
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24))
                }
                .padding(.leading, 16)

                Text(title)
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
            VStack(spacing: 24) {
                Image(systemName: "info.circle")
                    .font(.system(size: 64))
                    .foregroundColor(.blue)

                Text(title)
                    .font(.title)
                    .fontWeight(.bold)

                Text("这是「\(title)」的详情页面。你可以在这里展示更多相关内容。")
                    .font(.body)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color(.systemBackground))
    }
}

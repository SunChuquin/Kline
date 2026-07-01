//
//  MarketView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/23.
//

import SwiftUI

struct MarketView: View {
    var body: some View {
        VStack(spacing: 0) {
            // 顶部菜单栏
            HStack {
                Spacer()
            }
            .background(Color(.systemBackground))
            .frame(height: 56)
            .padding(.top, -5)

            // 分隔线
            Divider()

            // 主内容区域
            VStack {
                Text("行情")
                    .font(.title)
                Text("查看实时行情数据")
            }
            .frame(maxHeight: .infinity)
        }
    }
}

#Preview {
    MarketView()
}
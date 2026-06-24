//
//  ProfileDetailView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/24.
//

import SwiftUI

struct ProfileDetailView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏 - 参考搜索页面样式
            HStack {
                // 返回按钮
                Button(action: {
                    isPresented = false
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24))
                }
                .padding(.leading, 16)

                // 标题
                Text("个人中心")
                    .font(.title)
                    .fontWeight(.bold)

                Spacer()
            }
            .background(Color(.systemBackground))
            .padding(.top, 16)

            // 分隔线
            Divider()

            // 主内容区域
            VStack(spacing: 24) {
                // 用户头像
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 100))
                    .foregroundColor(.blue)

                // 用户名称
                Text("用户名")
                    .font(.title)
                    .fontWeight(.bold)

                // 用户ID
                Text("ID: 123456")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color(.systemBackground))
        .ignoresSafeArea()
    }
}

#Preview {
    ProfileDetailView(isPresented: .constant(true))
}
//
//  HomeHeaderBar.swift
//  Kline
//
//  首页标题栏：软件图标 + 名称 + 右侧用户入口胶囊，三档共用。
//

import SwiftUI

// MARK: - 顶部标题栏（等价搬入改造前 HomeView 非搜索态的标题栏）

/// 首页标题栏：左侧软件图标 + 名称，右侧「登录」用户入口胶囊。三档共用。
/// 外观、间距、配色与改造前逐项一致；用户入口点击由容器注入的 `onProfile` 承担。
/// 无障碍标识 `home.page` 挂在软件名 Text 上：三档都渲染本标题栏，
/// Text 在无障碍树里是 staticText，`app.staticTexts["home.page"]` 稳定命中
/// （挂在各档内容根容器上的标识在 SwiftUI 里未必暴露成元素）。
struct HomeHeaderBar: View {
    let onProfile: () -> Void

    var body: some View {
        HStack {
            // 软件图标和名称
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 24))
                    .foregroundColor(.red)
                Text("Kline")
                    .font(.system(size: 18))
                    .fontWeight(.bold)
                    .accessibilityIdentifier("home.page")
            }
            .padding(.leading, 16)

            Spacer()

            // 用户入口按钮
            Button(action: onProfile) {
                HStack(spacing: 5) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.blue)
                    Text("登录")
                        .font(.system(size: 16))
                }
                .padding(EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2))
                .background(Color(.systemGray5))
                .cornerRadius(20)
            }
            .padding(.trailing, 16)
        }
        .background(Color(.systemBackground))
        .frame(minHeight: 56)
    }
}
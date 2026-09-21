//
//  HomeLayoutAView.swift
//  Kline
//
//  首页 A 档布局（现有首页，保留）：改造前 HomeView 非搜索态 body 的等价搬运。
//  由共享骨架组合而成：标题栏 HomeHeaderBar + 分隔线 + 居中占位。
//  呈现、间距、颜色、命中区、无障碍标识（home.welcome）与改造前完全一致（A 档行为零变化）。
//

import SwiftUI

struct HomeLayoutAView: View {
    /// 右侧用户入口点击（由容器注入：打开个人中心）
    let onProfile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 顶部控件栏 - 参考通达信手机版样式
            HomeHeaderBar(onProfile: onProfile)

            Divider()

            // 首页内容
            VStack {
                Text("首页")
                    .font(.title)
                Text("欢迎来到首页")
                    .accessibilityIdentifier("home.welcome")
            }
            .frame(maxHeight: .infinity)
        }
        // 四档内容根统一标识（UI 用例据此判定首页已显示）
        .accessibilityIdentifier("home.page")
    }
}

#Preview {
    HomeLayoutAView(onProfile: {})
}
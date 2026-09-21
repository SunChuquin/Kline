//
//  HomeLayoutAView.swift
//  Kline
//
//  首页 A 档布局（现有首页，保留）：改造前 HomeView 非搜索态 body 的等价搬运。
//  由共享骨架组合而成：标题栏 HomeHeaderBar + 分隔线 + 居中占位。
//  居中占位已抽成独立控件 Widgets/HomePlaceholderBlock.swift；
//  呈现、间距、颜色、命中区、无障碍标识（home.welcome）与改造前完全一致（A 档行为零变化）；
//  布局无关的 home.page 标识由共享标题栏的软件名 Text 承担，不在本档内容根上重复挂。
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
            HomePlaceholderBlock()
        }
    }
}

#Preview {
    HomeLayoutAView(onProfile: {})
}
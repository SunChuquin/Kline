//
//  HomeView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/23.
//  2026/09/21 改为按布局偏好分发的容器（A/B/C/D），共享骨架见 HomePageKit.swift
//

import SwiftUI

// MARK: - 主页面（按布局偏好分发的容器）

/// 首页容器：搜索态统一走 `HomeSearchModeView`（四档共用）；
/// 非搜索态按 `PageLayoutStore.homeLayout` 分发到四档布局 ——
/// 本阶段 B/C/D 三档先临时回落到 A 档视图，下一阶段替换为各档真身。
/// 页面状态只有搜索态两个绑定（`isSearching` / `isProfilePresented`）与搜索词，容器层不持业务数据。
struct HomeView: View {
    @Binding var isSearching: Bool
    @Binding var isProfilePresented: Bool
    @State private var searchText = ""
    @ObservedObject private var layoutStore = PageLayoutStore.shared
    /// 公式管理中心全屏浮层开合（经 homeOverlays 挂在容器层，四档共用）
    @State private var showFormulaCenter = false

    var body: some View {
        VStack(spacing: 0) {
            if isSearching {
                // 搜索模式：返回按钮 + 搜索框（自动聚焦）+ 搜索结果页
                HomeSearchModeView(searchText: $searchText, isSearching: $isSearching)
            } else {
                // 按布局偏好分发四档
                switch layoutStore.homeLayout {
                case .a:
                    HomeLayoutAView(onProfile: { isProfilePresented = true })
                case .b:
                    // 下一阶段替换为 HomeLayoutBView（宫格快捷入口，默认档）
                    HomeLayoutAView(onProfile: { isProfilePresented = true })
                case .c:
                    // 下一阶段替换为 HomeLayoutCView（分区列表入口）
                    HomeLayoutAView(onProfile: { isProfilePresented = true })
                case .d:
                    // 下一阶段替换为 HomeLayoutDView（卡片工作台）
                    HomeLayoutAView(onProfile: { isProfilePresented = true })
                }
            }
        }
        .homeOverlays(showFormulaCenter: $showFormulaCenter)
    }
}

#Preview {
    HomeView(isSearching: .constant(false), isProfilePresented: .constant(false))
}
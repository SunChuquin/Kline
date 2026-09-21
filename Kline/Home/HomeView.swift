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
/// 非搜索态按 `PageLayoutStore.homeLayout` 分发到四档布局。
/// 入口动作（切底部 Tab / 进入搜索 / 打开个人中心 / 打开公式管理）全部由容器注入的闭包承担，
/// 各档入口控件只回调、不持状态；页面状态只有搜索态、搜索词与公式浮层开关。
struct HomeView: View {
    @Binding var isSearching: Bool
    @Binding var isProfilePresented: Bool
    @Binding var selectedTab: Int
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
                    HomeLayoutAView(onProfile: onProfile)
                case .b:
                    HomeLayoutBView(onSelectTab: onSelectTab, onSearch: onSearch,
                                    onProfile: onProfile, onFormula: onFormula)
                case .c:
                    HomeLayoutCView(onSelectTab: onSelectTab, onSearch: onSearch,
                                    onProfile: onProfile, onFormula: onFormula)
                case .d:
                    HomeLayoutDView(onSelectTab: onSelectTab, onSearch: onSearch,
                                    onProfile: onProfile, onFormula: onFormula)
                }
            }
        }
        .homeOverlays(showFormulaCenter: $showFormulaCenter)
    }

    // MARK: - 入口动作（四档共用；索引与 ContentView.menuItems 一致：自选 1 / 行情 2 / 模拟 3）

    private func onSelectTab(_ index: Int) {
        selectedTab = index
    }

    private func onSearch() {
        isSearching = true
    }

    private func onProfile() {
        isProfilePresented = true
    }

    private func onFormula() {
        showFormulaCenter = true
    }
}

#Preview {
    HomeView(isSearching: .constant(false), isProfilePresented: .constant(false), selectedTab: .constant(0))
}
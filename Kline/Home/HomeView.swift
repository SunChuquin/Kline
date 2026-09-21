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
/// 非搜索态按 `PageLayoutStore.homeLayout` 分发到四档布局（A 档为改造前实现，B/C/D 为「横滑入口行 + 内容区」）。
/// 入口动作（切底部 Tab / 进入搜索 / 公式管理中心分段 / 条件单 / 个人中心）全部由容器注入的闭包承担，
/// 各档入口控件只回调、不持状态；数据由 `HomePageModel` 统一持有并下发给三档与内容区。
struct HomeView: View {
    @Binding var isSearching: Bool
    @Binding var isProfilePresented: Bool
    @Binding var selectedTab: Int
    @State private var searchText = ""
    @ObservedObject private var layoutStore = PageLayoutStore.shared
    /// 首页共享数据模型（B/C/D 三档与内容区共用）
    @StateObject private var model = HomePageModel()
    /// 浮层单一呈现目标（公式管理中心 / 条件单管理页）
    @State private var overlayTarget: HomeOverlayTarget? = nil

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
                    HomeLayoutBView(model: model, onSelectTab: onSelectTab, onSearch: onSearch,
                                    onOpenFormula: onOpenFormula, onOpenCondOrder: onOpenCondOrder,
                                    onProfile: onProfile)
                case .c:
                    HomeLayoutCView(model: model, onSelectTab: onSelectTab, onSearch: onSearch,
                                    onOpenFormula: onOpenFormula, onOpenCondOrder: onOpenCondOrder,
                                    onProfile: onProfile)
                case .d:
                    HomeLayoutDView(model: model, onSelectTab: onSelectTab, onSearch: onSearch,
                                    onOpenFormula: onOpenFormula, onOpenCondOrder: onOpenCondOrder,
                                    onProfile: onProfile)
                }
            }
        }
        .homeOverlays(target: $overlayTarget)
    }

    // MARK: - 入口动作（三档共用；索引与 ContentView.menuItems 一致：自选 1 / 行情 2 / 模拟 3）

    private func onSelectTab(_ index: Int) {
        selectedTab = index
    }

    private func onSearch() {
        isSearching = true
    }

    private func onOpenFormula(_ kind: FormulaKind) {
        overlayTarget = .formula(kind)
    }

    private func onOpenCondOrder() {
        overlayTarget = .condOrder
    }

    private func onProfile() {
        isProfilePresented = true
    }
}

#Preview {
    HomeView(isSearching: .constant(false), isProfilePresented: .constant(false), selectedTab: .constant(0))
}
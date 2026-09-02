//
//  ContentView.swift
//  line
//
//  Created by 孙楚昆 on 2026/6/12.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var isSearching = false
    @State private var isProfilePresented = false
    @State private var isTestPresented = false
    @State private var lastHomeTapTime: Date?
    @State private var lastSimulateTapTime: Date?
    @ObservedObject private var detailRouter = DetailRouter.shared
    private let doubleTapInterval: TimeInterval = 0.3

    // 菜单按钮配置 - 参考通达信手机版风格
    let menuItems = [
        (icon: "house", title: "首页"),
        (icon: "folder", title: "自选"),
        (icon: "chart.bar", title: "行情"),
        (icon: "gamecontroller", title: "模拟"),
        (icon: "flask", title: "测试"),
        (icon: "eyedropper", title: "测试2")
    ]

    private var detailItem: MetaItem? { detailRouter.item }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    // 上半部分：主内容区域，根据选中的菜单切换视图
                    mainContentView
                        .frame(maxHeight: .infinity)

                    // 下半部分：底部导航栏
                    VStack(spacing: 0) {
                        // 顶部分隔线（使用负offset往上挪）
                        Color(.separator)
                            .frame(height: 1)
                            .offset(y: -2)
                        // 菜单按钮
                        HStack {
                            ForEach(0..<menuItems.count, id: \.self) { index in
                                Button(action: {
                                    handleTabTap(index: index)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: menuItems[index].icon)
                                            .font(.system(size: 20))
                                        Text(menuItems[index].title)
                                            .font(.system(size: 16))
                                    }
                                    .foregroundColor(selectedTab == index ? .accentColor : Color(.secondaryLabel))
                                    .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                    .background(Color(.systemBackground))
                    .padding(.bottom, geometry.safeAreaInsets.bottom)
                }

                // 全屏 K 线详情（覆盖整个屏幕，含底部栏）
                if let item = detailItem {
                    KlineDetailView(item: item) {
                        DetailRouter.shared.item = nil
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }
            }
        }
        .overlay(
            // 全屏覆盖层
            Group {
                if isProfilePresented {
                    ProfileDetailView(isPresented: $isProfilePresented)
                        .transition(.opacity)
                }
                if isTestPresented {
                    ProfileView(isPresented: $isTestPresented)
                        .transition(.opacity)
                }
            }
        )
    }

    // MARK: - 处理菜单按钮点击
    private func handleTabTap(index: Int) {
        if index == 0 && selectedTab == 0 {
            // 点击的是主页按钮，且当前已经在主页
            let now = Date()
            let currentLastTime = lastHomeTapTime
            if let lastTime = currentLastTime, now.timeIntervalSince(lastTime) < doubleTapInterval {
                // 双击：打开搜索页面
                isSearching = true
                lastHomeTapTime = nil
            } else {
                // 第一次点击
                lastHomeTapTime = now
                // 延迟清除记录
                DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapInterval) {
                    if self.lastHomeTapTime == now {
                        self.lastHomeTapTime = nil
                    }
                }
            }
        } else if index == 3 && selectedTab == 3 {
            // 点击的是模拟按钮，且当前已经在模拟页面
            let now = Date()
            let currentLastTime = lastSimulateTapTime
            if let lastTime = currentLastTime, now.timeIntervalSince(lastTime) < doubleTapInterval {
                // 双击：打开测试页面
                isTestPresented = true
                lastSimulateTapTime = nil
            } else {
                // 第一次点击
                lastSimulateTapTime = now
                // 延迟清除记录
                DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapInterval) {
                    if self.lastSimulateTapTime == now {
                        self.lastSimulateTapTime = nil
                    }
                }
            }
        } else {
            // 点击其他按钮
            selectedTab = index
            lastHomeTapTime = nil
            lastSimulateTapTime = nil
        }
    }

    // MARK: - 主内容视图切换
    @ViewBuilder
    private var mainContentView: some View {
        switch selectedTab {
        case 0:
            HomeView(isSearching: $isSearching, isProfilePresented: $isProfilePresented)
        case 1:
            FavoritesView()
        case 2:
            MarketView()
        case 3:
            SimulationView()
        case 4:
            MarketTestView()
        case 5:
            MarketTest2View()
        default:
            HomeView(isSearching: $isSearching, isProfilePresented: $isProfilePresented)
        }
    }
}

#Preview {
    ContentView()
}
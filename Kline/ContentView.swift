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
    @State private var lastHomeTapTime: Date?
    private let doubleTapInterval: TimeInterval = 0.3

    // 菜单按钮配置 - 参考通达信手机版风格
    let menuItems = [
        (icon: "house", title: "主页"),
        (icon: "chart.bar", title: "行情"),
        (icon: "folder", title: "自选"),
        (icon: "gamecontroller", title: "模拟"),
        (icon: "wrench", title: "测试")
    ]

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // 上半部分：主内容区域，根据选中的菜单切换视图
                mainContentView
                    .frame(maxHeight: .infinity)

                // 下半部分：底部导航栏 - 仅在竖屏时显示
                if geometry.size.height > geometry.size.width {
                    HStack {
                        ForEach(0..<menuItems.count, id: \.self) { index in
                            Button(action: {
                                handleTabTap(index: index)
                            }) {
                                VStack(spacing: 4) {
                                    Image(systemName: menuItems[index].icon)
                                        .font(.system(size: 24))
                                    Text(menuItems[index].title)
                                        .font(.system(size: 11))
                                }
                                .foregroundColor(selectedTab == index ? .accentColor : Color(.secondaryLabel))
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .background(Color(.systemBackground))
                    .border(Color(.separator))
                    .padding(.bottom, geometry.safeAreaInsets.bottom)
                }
            }
        }
        .overlay(
            // 全屏覆盖层 - 用户信息页面
            Group {
                if isProfilePresented {
                    ProfileDetailView(isPresented: $isProfilePresented)
                        .transition(.slide)
                }
            }
            .ignoresSafeArea()
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
        } else {
            // 点击其他按钮或从其他页面切换到主页
            selectedTab = index
            lastHomeTapTime = nil
        }
    }

    // MARK: - 主内容视图切换
    @ViewBuilder
    private var mainContentView: some View {
        switch selectedTab {
        case 0:
            HomeView(isSearching: $isSearching, isProfilePresented: $isProfilePresented)
        case 1:
            MarketView()
        case 2:
            FavoritesView()
        case 3:
            SimulationView()
        case 4:
            ProfileView()
        default:
            HomeView(isSearching: $isSearching, isProfilePresented: $isProfilePresented)
        }
    }
}

#Preview {
    ContentView()
}
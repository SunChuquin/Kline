//
//  ContentView.swift
//  line
//
//  Created by 孙楚昆 on 2026/6/12.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 5
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

    // 底部菜单对应的 UITest 定位标识（与 KlineUITests 冒烟用例约定一致）
    private let tabIDs = ["tab.home", "tab.favorites", "tab.market", "tab.simulation", "tab.test", "tab.test2"]

    private var detailItem: MetaItem? { detailRouter.item }

    var body: some View {
        ZStack {
            // 主内容区 + 底部导航栏：VStack 自主控制布局（不用 safeAreaInset——
            // 实测其槽位内容上的 ignoresSafeArea 不生效，背景无法铺满屏幕底部区域）。
            // VStack 整体 ignoresSafeArea(edges:.bottom) 使底栏背景直达物理屏幕底边；
            // mainContentView 高度自动扣除底栏，结构上不可能遮挡。
            // 导航栏不保留 home indicator 安全区垫高（用户要求所有机型与 mini4 形态一致、
            // 均一行高度贴底，系统指示条绘制在按钮行上层）
            VStack(spacing: 0) {
                mainContentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomMenuBar
            }
            .ignoresSafeArea(edges: .bottom)

            // 全屏 K 线详情（覆盖整个屏幕，含底部栏）
            if let item = detailItem {
                KlineDetailView(item: item) {
                    DetailRouter.shared.item = nil
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .onAppear {
            // App 启动即实例化行情行缓存，触发行情数值预热（无需等行情页首次打开）
            _ = MarketRowCache.shared
            MarketRowCache.shared.prewarmMarketData()
        }
        .onReceive(DatabaseManager.shared.$isLoaded) { loaded in
            // 数据库就绪即预热（直接透传就绪标志，不依赖内部再读 db.isLoaded）
            MarketRowCache.shared.prewarmMarketData(isLoaded: loaded)
        }
        // 全局禁用键盘避让：键盘弹出/缩小/收起全程不参与本页布局，
        // 导航栏与页面位置恒定；搜索栏均锚定在页面顶部无需腾空间；
        // 需要避让的公式编辑器走 fullScreenCover 独立呈现图层，不受此全局设置影响
        .ignoresSafeArea(.keyboard)
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

    // MARK: - 底部导航栏（VStack 底部固定段）
    // 高度 = 分隔线1pt + 按钮行（约25pt），所有机型一致、按钮行直接贴物理屏幕底边。
    // 不做 home indicator 安全区垫高（用户要求与 mini4 形态统一，指示条绘制在按钮上层）；
    // 背景由外层 VStack 的 ignoresSafeArea(edges:.bottom) 铺到物理屏幕底边
    private var bottomMenuBar: some View {
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
                    .accessibilityIdentifier(tabIDs[index])
                }
            }
        }
        .background(Color(.systemBackground))
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
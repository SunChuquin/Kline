//
//  ProfileDetailView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/24.
//

import SwiftUI

struct ProfileDetailView: View {
    @Binding var isPresented: Bool
    /// 主题选择弹窗开合（弹窗本身在页面容器层呈现，避免被 ScrollView 裁剪）
    @State private var showThemePanel = false
    /// 快捷面板布局选择弹窗开合
    @State private var showPanelLayoutPanel = false
    /// 模拟页布局选择弹窗开合
    @State private var showSimulationLayoutPanel = false
    @ObservedObject private var themeStore = KlineThemeStore.shared
    @ObservedObject private var layoutStore = TradingLayoutStore.shared

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
            .frame(height: 56)
            .padding(.top, -5)

            // 分隔线
            Divider()

            // 主内容区域 - ScrollView 支持滚动
            ScrollView {
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

                    // Kline 显示主题（日间 / 夜间 / 跟随系统）：点右侧下拉弹出选择面板
                    KlineThemeSettingRow(isOpen: $showThemePanel)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)

                    // 快捷面板布局（A / B / C 三套方案）：点右侧下拉弹出选择面板
                    QuickPanelLayoutSettingRow(isOpen: $showPanelLayoutPanel)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)

                    // 模拟页布局（A / B / C 三套方案）：点右侧下拉弹出选择面板
                    SimulationLayoutSettingRow(isOpen: $showSimulationLayoutPanel)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)

                    // 本地更新面板（TrollStore 版可扫描 Downloads/*.ipa 并共享到 TrollStore）
                    LocalUpdateView()
                }
                .padding()
            }
        }
        // 内容延伸到物理屏幕底边 + 背景铺满（否则 2018 等机型底部 20pt 露出下层导航栏）
        .background(Color(.systemBackground).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        // 容器层浮层：居中显示主题选择弹窗（与行情表设置的字段筛选弹窗同做法，
        // 放在页面根而非行内，避免被 ScrollView 裁剪）
        .overlay {
            if showThemePanel {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) { showThemePanel = false }
                        }
                    KlineThemeOptionsPanel(theme: $themeStore.theme,
                                           onClose: { showThemePanel = false })
                }
                .transition(.opacity)
                .zIndex(1000)
            }
            if showPanelLayoutPanel {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) { showPanelLayoutPanel = false }
                        }
                    TradingLayoutOptionsPanel(options: QuickPanelLayoutStyle.allCases,
                                              selection: $layoutStore.panelLayout,
                                              titleFor: { $0.title },
                                              onClose: { showPanelLayoutPanel = false })
                }
                .transition(.opacity)
                .zIndex(1000)
            }
            if showSimulationLayoutPanel {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) { showSimulationLayoutPanel = false }
                        }
                    TradingLayoutOptionsPanel(options: SimulationLayoutStyle.allCases,
                                              selection: $layoutStore.simulationLayout,
                                              titleFor: { $0.title },
                                              onClose: { showSimulationLayoutPanel = false })
                }
                .transition(.opacity)
                .zIndex(1000)
            }
        }
        // 三个下拉面板互斥：任一打开时关掉其余两个（iOS 15 的 onChange 为单参数闭包）
        .onChange(of: showThemePanel) { newValue in
            if newValue { showPanelLayoutPanel = false; showSimulationLayoutPanel = false }
        }
        .onChange(of: showPanelLayoutPanel) { newValue in
            if newValue { showThemePanel = false; showSimulationLayoutPanel = false }
        }
        .onChange(of: showSimulationLayoutPanel) { newValue in
            if newValue { showThemePanel = false; showPanelLayoutPanel = false }
        }
    }
}

#Preview {
    ProfileDetailView(isPresented: .constant(true))
}
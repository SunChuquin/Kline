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
    /// 公式管理中心页（全屏 overlay）开合
    @State private var showFormulaCenter = false
    /// Python 引擎实验室（Phase-0 调试页；引擎不进 IPA，按需下载加载，不点不动作）
    @State private var showPythonLab = false
    /// 联机同步（局域网设备间同步，全屏 overlay）
    @State private var showLANSync = false
    /// Web UI 试点（P0 混合架构桥接骨架，全屏 overlay）
    @State private var showWebPilot = false
    @ObservedObject private var themeStore = KlineThemeStore.shared

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

                    // P2-7：五组布局设置行与布局编辑器入口随 JSON 布局系统退役
                    // （四 Tab 已 Web 化，快捷面板/模拟页布局在训练态原生面板内仍按既有偏好生效）

                    // 公式管理（技术指标 / 选股指标 / 交易策略 三类公式分域入口）
                    FormulaCenterSettingRow { showFormulaCenter = true }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)

                    // 本地更新（P2-6c-1：提取为全屏 Web 页；原生内嵌卡片组 LocalUpdateView 保留可回退）
                    Button(action: { WebPageBridge.shared.open("localUpdate") }) {
                        HStack(spacing: 10) {
                            Text("本地更新")
                                .font(.system(size: 16))
                                .foregroundColor(Color.primary)
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                        .padding(16)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .accessibilityIdentifier("profile.localUpdate.entry")

                    // 联机同步（局域网设备间同步：自选/模拟交易/布局/指标/增量库/主库）
                    // P2-6c-1：迁 Web 全屏页（showLANSync 原生分支保留可回退）
                    Button(action: { WebPageBridge.shared.open("lanSync") }) {
                        HStack(spacing: 10) {
                            Text("联机同步")
                                .font(.system(size: 16))
                                .foregroundColor(Color.primary)
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                        .padding(16)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .accessibilityIdentifier("profile.lansync.entry")

                    // Python 引擎实验室（低调调试入口；引擎不进 IPA，按需下载加载）
                    // P2-6c-1：迁 Web 全屏页（showPythonLab 原生分支保留可回退）
                    Button(action: { WebPageBridge.shared.open("pythonLab") }) {
                        HStack(spacing: 10) {
                            Text("Python 引擎实验室")
                                .font(.system(size: 16))
                                .foregroundColor(Color.primary)
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                        .padding(16)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    // Web UI 试点（P0 混合架构桥接骨架：Vue3 只读快照页 + 桥接探针，
                    // 详见 .trae/documents/Kline-混合架构改造方案.md）
                    Button(action: { showWebPilot = true }) {
                        HStack(spacing: 10) {
                            Text("Web 试点（P0）")
                                .font(.system(size: 16))
                                .foregroundColor(Color.primary)
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                        .padding(16)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .accessibilityIdentifier("profile.webpilot.entry")
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
            // 公式管理中心：全屏页面（铺满，无遮罩），关闭走页内「返回」
            if showFormulaCenter {
                ZStack {
                    FormulaCenterView(initialKind: .tech, onClose: { showFormulaCenter = false })
                }
                .transition(.opacity)
                .zIndex(1000)
            }
            // Python 引擎实验室：全屏页面（铺满，无遮罩），关闭走页内「返回」
            if showPythonLab {
                ZStack { PythonEngineLabView(onClose: { showPythonLab = false }) }
                    .transition(.opacity)
                    .zIndex(1000)
            }
            // 联机同步：全屏页面（铺满，无遮罩），关闭走页内「返回」
            if showLANSync {
                ZStack { LANSyncView(onClose: { showLANSync = false }) }
                    .transition(.opacity)
                    .zIndex(1000)
            }
            // Web UI 试点：全屏页面（铺满，无遮罩），关闭走页内「返回」。
            // 全屏页打开时下方行不可点、天然互斥，故不加入 onChange 互斥链
            if showWebPilot {
                ZStack { WebHostView(onClose: { showWebPilot = false }) }
                    .transition(.opacity)
                    .zIndex(1000)
            }
        }
        // 浮层互斥：任一打开时关掉其余（iOS 15 的 onChange 为单参数闭包）。
        // P2-7：布局浮层随 JSON 布局系统退役，仅剩主题 / 公式中心两项互斥
        .onChange(of: showThemePanel) { newValue in
            if newValue { showFormulaCenter = false }
        }
        .onChange(of: showFormulaCenter) { newValue in
            if newValue { showThemePanel = false }
        }
    }
}

#Preview {
    ProfileDetailView(isPresented: .constant(true))
}
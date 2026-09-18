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
    @ObservedObject private var themeStore = KlineThemeStore.shared
    /// 数据源（数据库 tdx.db / 行情文件 bin）切换
    @ObservedObject private var dataSource = DataSourceProvider.shared
    @ObservedObject private var dbm = DatabaseManager.shared
    @State private var showDataSourcePanel = false
    @State private var dataSourceNotice: String?

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

                    // 数据源（数据库 tdx.db / 行情文件 bin）：运行时切换，无需重启
                    dataSourceRow
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
        // 数据源选择弹窗与切换提示
        .alert("数据源", isPresented: Binding(
            get: { dataSourceNotice != nil },
            set: { if !$0 { dataSourceNotice = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(dataSourceNotice ?? "")
        }
        // 容器层浮层：居中显示主题选择弹窗与数据源选择弹窗（与行情表设置的字段
        // 筛选弹窗同做法，放在页面根而非行内，避免被 ScrollView 裁剪）。
        // 数据源用自定义浮层而非系统 confirmationDialog：本页挂在 ContentView 的
        // overlay 层、且目标机为 iPad，系统 action sheet 常因无附着锚点不弹出，
        // 而自定义浮层（主题弹窗同款）已在个人中心验证稳定可用。
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
            if showDataSourcePanel {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) { showDataSourcePanel = false }
                        }
                    KlineDataSourceOptionsPanel(mode: dataSource.mode) { newMode in
                        switchDataSource(to: newMode)
                        withAnimation(.easeOut(duration: 0.15)) { showDataSourcePanel = false }
                    }
                }
                .transition(.opacity)
                .zIndex(1000)
            }
        }
    }

    /// 数据源设置行：点整行弹出选择面板
    private var dataSourceRow: some View {
        HStack {
            Text("行情数据源")
                .font(.body)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(dataSource.mode.displayName)
                    .font(.subheadline)
                    .foregroundColor(.blue)
                Text("已加载 \(dbm.metaList.count) 只标的")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Image(systemName: "chevron.down")
                .font(.footnote)
                .foregroundColor(.gray)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { showDataSourcePanel = true }
        }
    }

    private func switchDataSource(to mode: DataSourceMode) {
        dataSource.setMode(mode)
        dataSourceNotice = "已切换为「\(mode.displayName)」，列表将按新数据源刷新"
    }
}

// MARK: - 数据源选择浮层（样式对齐 KlineThemeOptionsPanel / FilterOptionsPanel）

/// 数据源选择浮层面板：列出「数据库」与「行情文件(bin)」两种模式，点击即切换。
/// 用自定义浮层替代系统 confirmationDialog，避免 iPad + overlay 嵌套下系统
/// action sheet 不弹出的问题。
struct KlineDataSourceOptionsPanel: View {
    let mode: DataSourceMode
    let onSelect: (DataSourceMode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(DataSourceMode.allCases) { item in
                    let on = mode == item
                    Button {
                        onSelect(item)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.displayName)
                                    .font(.system(size: 15))
                                    .foregroundColor(.primary)
                                Text(item == .bin
                                     ? "读取 Documents/tdx_data/*.bin 行情文件"
                                     : "读取 SQLite 数据库 tdx.db")
                                    .font(.system(size: 11))
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            if on {
                                Image(systemName: "checkmark").foregroundColor(.blue)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }

            Button {
                onSelect(mode)
            } label: {
                Text("完成")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 240)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }
}

extension DataSourceMode: Identifiable { var id: String { rawValue } }

#Preview {
    ProfileDetailView(isPresented: .constant(true))
}
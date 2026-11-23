//
//  ProfileDetailView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/24.
//
//  个人中心 = 桌面级双栏设置面板：
//    Header  ：返回 + 标题
//    Sidebar ：左侧分类导航（账户 / 主题外观 / 页面布局 / 公式与策略 / 数据与同步 / 调试工具）
//    Content ：右侧当前分类的设置内容，独立滚动
//    Footer  ：即时生效提示 + 当前构建号
//  左导航只切换右侧内容，不重建整个页面；所有原有功能入口与浮层逻辑保持不变。
//

import SwiftUI

struct ProfileDetailView: View {
    @Binding var isPresented: Bool

    // MARK: - 左侧分类导航

    /// 个人中心的分类分域（顺序即左导航展示顺序）
    private enum Category: String, CaseIterable, Identifiable {
        case account
        case appearance
        case layout
        case formula
        case sync
        case debug

        var id: String { rawValue }

        var title: String {
            switch self {
            case .account:    return "账户"
            case .appearance: return "主题外观"
            case .layout:     return "页面布局"
            case .formula:    return "公式与策略"
            case .sync:       return "数据与同步"
            case .debug:      return "调试工具"
            }
        }

        /// 右侧内容区标题下的一句话说明
        var subtitle: String {
            switch self {
            case .account:    return "账户信息与当前构建"
            case .appearance: return "日间 / 夜间 / 跟随系统"
            case .layout:     return "首页、自选、行情、模拟与快捷面板的布局方案"
            case .formula:    return "技术指标、选股指标与交易策略"
            case .sync:       return "本地服务、版本更新与局域网联机同步"
            case .debug:      return "引擎实验室与行情卡片样张"
            }
        }

        var icon: String {
            switch self {
            case .account:    return "person.crop.circle"
            case .appearance: return "circle.lefthalf.filled"
            case .layout:     return "rectangle.split.3x1"
            case .formula:    return "function"
            case .sync:       return "arrow.triangle.2.circlepath"
            case .debug:      return "hammer"
            }
        }
    }

    /// 当前选中的分类
    @State private var selectedCategory: Category = .account

    /// 主题选择弹窗开合（弹窗本身在页面容器层呈现，避免被 ScrollView 裁剪）
    @State private var showThemePanel = false
    /// 快捷面板布局选择弹窗开合
    @State private var showPanelLayoutPanel = false
    /// 模拟页布局选择弹窗开合
    @State private var showSimulationLayoutPanel = false
    /// 自选页布局选择弹窗开合
    @State private var showFavoritesLayoutPanel = false
    /// 行情页布局选择弹窗开合
    @State private var showMarketLayoutPanel = false
    /// 首页布局选择弹窗开合
    @State private var showHomeLayoutPanel = false
    /// 公式管理中心页（全屏 overlay）开合
    @State private var showFormulaCenter = false
    /// 布局编辑器（全屏 overlay）开合
    @State private var showLayoutEditor = false
    /// Python 引擎实验室（Phase-0 调试页；引擎不进 IPA，按需下载加载，不点不动作）
    @State private var showPythonLab = false
    /// 行情指数卡片样张（临时视觉验收页；接入真实数据后移除）
    @State private var showIndexCardGallery = false
    /// 联机同步（局域网设备间同步，全屏 overlay）
    @State private var showLANSync = false
    @ObservedObject private var themeStore = KlineThemeStore.shared
    @ObservedObject private var tradingLayoutStore = TradingLayoutStore.shared
    @ObservedObject private var pageLayoutStore = PageLayoutStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            // 双栏主体：左侧分类导航固定宽，右侧内容独立滚动
            GeometryReader { geo in
                HStack(spacing: 0) {
                    sidebar(width: sidebarWidth(for: geo.size.width))
                    Divider()
                    content
                }
            }

            Divider()
            footer
        }
        // 内容延伸到物理屏幕底边 + 背景铺满（否则 2018 等机型底部 20pt 露出下层导航栏）
        .background(AppColors.pageBackground.ignoresSafeArea())
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
                    LayoutOptionsPanel(options: QuickPanelLayoutStyle.allCases,
                                              selection: $tradingLayoutStore.panelLayout,
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
                    LayoutOptionsPanel(options: SimulationLayoutStyle.allCases,
                                              selection: $tradingLayoutStore.simulationLayout,
                                              titleFor: { $0.title },
                                              onClose: { showSimulationLayoutPanel = false })
                }
                .transition(.opacity)
                .zIndex(1000)
            }
            if showFavoritesLayoutPanel {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) { showFavoritesLayoutPanel = false }
                        }
                    LayoutOptionsPanel(options: FavoritesLayoutStyle.allCases,
                                              selection: $pageLayoutStore.favoritesLayout,
                                              titleFor: { $0.title },
                                              onClose: { showFavoritesLayoutPanel = false })
                }
                .transition(.opacity)
                .zIndex(1000)
            }
            if showMarketLayoutPanel {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) { showMarketLayoutPanel = false }
                        }
                    LayoutOptionsPanel(options: MarketLayoutStyle.allCases,
                                              selection: $pageLayoutStore.marketLayout,
                                              titleFor: { $0.title },
                                              onClose: { showMarketLayoutPanel = false })
                }
                .transition(.opacity)
                .zIndex(1000)
            }
            if showHomeLayoutPanel {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) { showHomeLayoutPanel = false }
                        }
                    LayoutOptionsPanel(options: HomeLayoutStyle.allCases,
                                              selection: $pageLayoutStore.homeLayout,
                                              titleFor: { $0.title },
                                              onClose: { showHomeLayoutPanel = false })
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
            // 布局编辑器：全屏页面（铺满，无遮罩），关闭走页内「返回」
            if showLayoutEditor {
                ZStack { PageLayoutEditorView(onClose: { showLayoutEditor = false }) }
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
            // 行情卡片样张：临时视觉验收页（模拟数据）
            if showIndexCardGallery {
                ZStack { MarketIndexCardGalleryView(onClose: { showIndexCardGallery = false }) }
                    .transition(.opacity)
                    .zIndex(1000)
            }
        }
        // 浮层互斥：任一打开时关掉其余（iOS 15 的 onChange 为单参数闭包）
        .onChange(of: showThemePanel) { newValue in
            if newValue { showPanelLayoutPanel = false; showSimulationLayoutPanel = false; showFavoritesLayoutPanel = false; showMarketLayoutPanel = false; showHomeLayoutPanel = false; showFormulaCenter = false; showLayoutEditor = false }
        }
        .onChange(of: showPanelLayoutPanel) { newValue in
            if newValue { showThemePanel = false; showSimulationLayoutPanel = false; showFavoritesLayoutPanel = false; showMarketLayoutPanel = false; showHomeLayoutPanel = false; showFormulaCenter = false; showLayoutEditor = false }
        }
        .onChange(of: showSimulationLayoutPanel) { newValue in
            if newValue { showThemePanel = false; showPanelLayoutPanel = false; showFavoritesLayoutPanel = false; showMarketLayoutPanel = false; showHomeLayoutPanel = false; showFormulaCenter = false; showLayoutEditor = false }
        }
        .onChange(of: showFavoritesLayoutPanel) { newValue in
            if newValue { showThemePanel = false; showPanelLayoutPanel = false; showSimulationLayoutPanel = false; showMarketLayoutPanel = false; showHomeLayoutPanel = false; showFormulaCenter = false; showLayoutEditor = false }
        }
        .onChange(of: showMarketLayoutPanel) { newValue in
            if newValue { showThemePanel = false; showPanelLayoutPanel = false; showSimulationLayoutPanel = false; showFavoritesLayoutPanel = false; showHomeLayoutPanel = false; showFormulaCenter = false; showLayoutEditor = false }
        }
        .onChange(of: showHomeLayoutPanel) { newValue in
            if newValue { showThemePanel = false; showPanelLayoutPanel = false; showSimulationLayoutPanel = false; showFavoritesLayoutPanel = false; showMarketLayoutPanel = false; showFormulaCenter = false; showLayoutEditor = false }
        }
        .onChange(of: showFormulaCenter) { newValue in
            if newValue { showThemePanel = false; showPanelLayoutPanel = false; showSimulationLayoutPanel = false; showFavoritesLayoutPanel = false; showMarketLayoutPanel = false; showHomeLayoutPanel = false; showLayoutEditor = false }
        }
        .onChange(of: showLayoutEditor) { newValue in
            if newValue { showThemePanel = false; showPanelLayoutPanel = false; showSimulationLayoutPanel = false; showFavoritesLayoutPanel = false; showMarketLayoutPanel = false; showHomeLayoutPanel = false; showFormulaCenter = false }
        }
    }

    // MARK: - 顶部栏

    private var header: some View {
        HStack(spacing: 4) {
            // 返回按钮：保持原有「关闭个人中心」行为
            Button(action: {
                isPresented = false
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")
            .accessibilityIdentifier("profile.close")

            VStack(alignment: .leading, spacing: 1) {
                Text("个人中心")
                    .font(.system(size: 20, weight: .bold))
                Text("设置")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.trailing, 16)
        .frame(height: 56)
        .background(AppColors.pageBackground)
    }

    // MARK: - 左侧分类导航

    /// 侧栏宽度：随可用宽自适应（iPhone 竖屏 132pt，iPad 约 200~240pt）
    private func sidebarWidth(for totalWidth: CGFloat) -> CGFloat {
        min(240, max(132, totalWidth * 0.26))
    }

    private func sidebar(width: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(Category.allCases) { category in
                    sidebarItem(category)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .frame(width: width)
        .background(AppColors.sidebarBackground)
    }

    /// 单个分类项：图标 + 名称，选中态用主题色文字 + 淡色圆角底
    private func sidebarItem(_ category: Category) -> some View {
        let selected = selectedCategory == category
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { selectedCategory = category }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22)
                Text(category.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .foregroundColor(selected ? AppColors.accent : AppColors.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? AppColors.selectedBackground : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.category.\(category.rawValue)")
    }

    // MARK: - 右侧内容

    private var content: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                // 分类标题 + 说明（对齐桌面设置面板的内容区标题）
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedCategory.title)
                        .font(.system(size: 22, weight: .bold))
                    Text(selectedCategory.subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                categoryContent
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.pageBackground)
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch selectedCategory {
        case .account:    accountSection
        case .appearance: appearanceSection
        case .layout:     layoutSection
        case .formula:    formulaSection
        case .sync:       syncSection
        case .debug:      debugSection
        }
    }

    // MARK: - 分类内容

    /// 账户：头像 / 用户名 / ID（保留原占位信息）
    private var accountSection: some View {
        settingsCard("账户信息") {
            VStack(spacing: 10) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 84))
                    .foregroundColor(AppColors.accent)
                Text("用户名")
                    .font(.system(size: 20, weight: .semibold))
                Text("ID: 123456")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    /// 主题外观：Kline 显示主题
    private var appearanceSection: some View {
        settingsCard("显示") {
            settingRow { KlineThemeSettingRow(isOpen: $showThemePanel) }
        }
    }

    /// 页面布局：五套布局方案 + 布局编辑器
    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsCard("布局方案") {
                settingRow { QuickPanelLayoutSettingRow(isOpen: $showPanelLayoutPanel) }
                insetDivider
                settingRow { SimulationLayoutSettingRow(isOpen: $showSimulationLayoutPanel) }
                insetDivider
                settingRow { FavoritesLayoutSettingRow(isOpen: $showFavoritesLayoutPanel) }
                insetDivider
                settingRow { MarketLayoutSettingRow(isOpen: $showMarketLayoutPanel) }
                insetDivider
                settingRow { HomeLayoutSettingRow(isOpen: $showHomeLayoutPanel) }
            }

            settingsCard("自定义") {
                settingRow { LayoutEditorSettingRow { showLayoutEditor = true } }
            }
        }
    }

    /// 公式与策略：公式管理中心入口
    private var formulaSection: some View {
        settingsCard("公式") {
            settingRow { FormulaCenterSettingRow { showFormulaCenter = true } }
        }
    }

    /// 数据与同步：本地更新 / 清单标的自动更新 / 补缺口（LocalUpdateView 原样保留）+ 联机同步
    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            LocalUpdateView()

            settingsCard("局域网") {
                linkRow("联机同步", identifier: "profile.lansync.entry") { showLANSync = true }
            }
        }
    }

    /// 调试工具：Python 引擎实验室 + 行情卡片样张（临时）
    private var debugSection: some View {
        settingsCard("调试入口") {
            linkRow("Python 引擎实验室") { showPythonLab = true }
            insetDivider
            linkRow("行情卡片样张（临时）", identifier: "profile.indexCardGallery.entry") {
                // 与原实现一致：打开样张前先关掉其它浮层
                showThemePanel = false
                showPanelLayoutPanel = false
                showSimulationLayoutPanel = false
                showFavoritesLayoutPanel = false
                showMarketLayoutPanel = false
                showHomeLayoutPanel = false
                showFormulaCenter = false
                showLayoutEditor = false
                showPythonLab = false
                showLANSync = false
                showIndexCardGallery = true
            }
        }
    }

    // MARK: - 底部状态栏

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 12))
            Text("主题与布局修改即时生效")
                .font(.system(size: 12))
            Spacer(minLength: 12)
            if let build = GitHubUpdateService.currentBuildNumber {
                Text("构建 #\(build)")
                    .font(.system(size: 12, design: .monospaced))
            }
        }
        .foregroundColor(AppColors.textSecondary)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(AppColors.sidebarBackground)
    }

    // MARK: - 通用行与卡片

    /// 内容卡片：13pt semibold 灰标题 + secondarySystemBackground 圆角 12 容器
    /// （与「本地更新」卡片组同规格）
    private func settingsCard<Content: View>(_ title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppColors.textSecondary)
            VStack(spacing: 0) {
                content()
            }
            .background(AppColors.cardBackground)
            .cornerRadius(12)
        }
    }

    /// 设置行容器：左右 16pt、最小行高 48pt（保留各设置行原有的点击区域）
    private func settingRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
    }

    /// 卡片内分隔线（左侧缩进 16pt，不画到卡片圆角边缘）
    private var insetDivider: some View {
        Divider().padding(.leading, 16)
    }

    /// 整行可点的跳转行（标题 + 右侧 chevron，命中区 48pt）
    /// 标识直接打在 Button 上，保证 UI 测试能按 buttons[...] 命中
    @ViewBuilder
    private func linkRow(_ title: String, identifier: String? = nil,
                         action: @escaping () -> Void) -> some View {
        let row = Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(AppColors.textPrimary)
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppColors.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if let identifier = identifier {
            row.accessibilityIdentifier(identifier)
        } else {
            row
        }
    }
}

#Preview {
    ProfileDetailView(isPresented: .constant(true))
}

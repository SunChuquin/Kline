//
//  ContentView.swift
//  line
//
//  Created by 孙楚昆 on 2026/6/12.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 2
    @State private var isSearching = false
    @State private var isProfilePresented = false
    @State private var isTestPresented = false
    /// 悬浮按钮点开的快捷面板是否呈现
    @State private var isAccessoryPanelPresented = false
    @State private var lastHomeTapTime: Date?
    @State private var lastSimulateTapTime: Date?
    /// 底部导航栏实测高度：两个悬浮按钮的下边界要避开它。
    /// 不避开时按钮能被拖到物理屏幕底边、与 Tab 的命中区重叠 ——
    /// 想点「首页 / 模拟」切换时容易误触到按钮（它比 Tab 更靠上、命中区 56/128.8pt 也更大）
    @State private var bottomBarHeight: CGFloat = 0
    @ObservedObject private var detailRouter = DetailRouter.shared
    /// 「K 线单人训练」运行控制器：`meta` 非 nil 即训练态，根层呈现全屏训练 K 线页
    @ObservedObject private var trainer = TrainingSessionController.shared
    /// 训练设置窗（自绘居中浮层，要盖住底部导航栏，故由根层承载）
    @ObservedObject private var trainingSetupRouter = TrainingSetupRouter.shared
    /// 训练条件单 / 预警记录页（训练态浮层，同样盖住底部导航栏）
    @ObservedObject private var trainingCondRouter = TrainingCondRouter.shared
    /// 全屏布局编辑器（首页/个人中心入口都置位它，见 PageLayoutEditorView.swift）
    @ObservedObject private var layoutEditorRouter = HomeLayoutEditorRouter.shared
    @ObservedObject private var accessoryCoordinator = FloatingAccessoryCoordinator.shared
    /// 全 App 显示主题（个人中心可切换：日间 / 夜间 / 跟随系统）
    @ObservedObject private var themeStore = KlineThemeStore.shared
    private let doubleTapInterval: TimeInterval = 0.3

    // 菜单按钮配置 - 参考通达信手机版风格
    let menuItems = [
        (icon: "house", title: "首页"),
        (icon: "folder", title: "自选"),
        (icon: "chart.bar", title: "行情"),
        (icon: "gamecontroller", title: "模拟")
    ]

    // 底部菜单对应的 UITest 定位标识（与 KlineUITests 冒烟用例约定一致）
    private let tabIDs = ["tab.home", "tab.favorites", "tab.market", "tab.simulation"]

    private var detailItem: MetaItem? { detailRouter.item }

    /// 两个悬浮按钮当前是否应显示：详情页打开 + 自己的面板没开 + K 线详情页无弹窗
    /// + K 线详情页首屏已加载完成（加载中不显示，避免页面还在转圈时按钮先露面）。
    /// 联动多图光标自动移动另有 hidesDuringCursorAutoMove() modifier 处理，不在此聚合
    private var isButtonVisible: Bool {
        !isAccessoryPanelPresented && !trainingCondRouter.isPresented
            && !accessoryCoordinator.isDetailViewPopupActive
            && accessoryCoordinator.isDetailViewLoaded
    }

    var body: some View {
        ZStack {
            // 主内容区 + 底部导航栏：VStack 自主控制布局（不用 safeAreaInset——
            // 实测其槽位内容上的 ignoresSafeArea 不生效，背景无法铺满屏幕底部区域）。
            // VStack 整体 ignoresSafeArea(edges:.bottom) 使底栏背景直达物理屏幕底边；
            // mainContentView 高度自动扣除底栏，结构上不可能遮挡。
            // 导航栏不保留 home indicator 安全区垫高（用户要求所有机型与 mini4 形态一致、
            // 均一行高度贴底，系统指示条绘制在按钮行上层）
            VStack(spacing: 0) {
                // 防御（窄屏适配）：页面固有最小宽可能超过物理屏宽（实测行情 ~512pt、
                // 模拟 ~1022pt，而 iPhone 11 竖屏仅 414pt），固有宽一旦向外传播会把
                // 本 VStack 连同根 ZStack 整体撑宽，居中后整屏左移，底部 Tab 栏
                // （maxWidth .infinity 四等分按钮）随之越出物理屏幕（实测 tab.home x=-49）。
                // 处理：包一层 GeometryReader + 固定 frame 钳制——GeometryReader 只向外
                // 报告提议尺寸、不透传子视图固有宽，页面溢出被隔离在页面内部；外层固定
                // frame 钉成可用区域的精确尺寸，内层保留 maxWidth/maxHeight infinity
                // 维持原有「撑满可用区域」语义。GeometryReader 默认 topLeading 对齐，
                // 但内容与 geo 同尺寸、不产生位移；底部 ignoresSafeArea 行为不变。
                GeometryReader { geo in
                    mainContentView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(width: geo.size.width, height: geo.size.height)
                        // 紧凑宽度单一事实来源：把根层实测可用宽注入环境，
                        // 首页/模拟/布局编辑器预览内的 AdaptiveStack 与 widget 共用
                        .environment(\.klineAvailableWidth, geo.size.width)
                }

                bottomMenuBar
                    // 实测底栏高度（含 1pt 分隔线）供悬浮按钮避让；底栏高度由内容决定，
                    // 上报值只写入 @State、不参与布局，故不会引起布局循环
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: BottomBarHeightKey.self, value: g.size.height)
                        }
                    )
            }
            .ignoresSafeArea(edges: .bottom)

            // 全屏 K 线详情（覆盖整个屏幕，含底部栏）
            if let item = detailItem {
                KlineDetailView(item: item) {
                    DetailRouter.shared.item = nil
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

            // 全屏布局编辑器（覆盖整个屏幕，含底部栏）：
            // 挂在根 ZStack 而非首页内部——首页在 VStack 里只占底栏以上的区域，
            // 页面内 overlay 永远盖不住底部导航栏（用户要求编辑器全屏）。
            // 防御（窄屏适配）：编辑器固有宽实测 ~459pt，超过 iPhone 11 竖屏 414pt，
            // 作为根 ZStack 直接子视图同样会撑宽根容器、拖歪 Tab 栏几何；与
            // mainContentView 一样包 GeometryReader + 固定 frame 钳制，只向外报告
            // 提议尺寸。编辑器内部自带 ignoresSafeArea（背景 + 底部边缘），
            // 全屏覆盖能力不受此钳制影响。
            if layoutEditorRouter.isPresented {
                GeometryReader { geo in
                    PageLayoutEditorView(page: layoutEditorRouter.page) {
                        layoutEditorRouter.isPresented = false
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(width: geo.size.width, height: geo.size.height)
                    // 编辑器盖在根 ZStack 上、不在 mainContentView 子树内，
                    // 需单独注入实测宽：编辑器的全屏预览（PageLayoutRenderer）据此竖排
                    .environment(\.klineAvailableWidth, geo.size.width)
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

            // 全屏训练 K 线页（覆盖整个屏幕，含底部栏）：压在同层最后，保证在最上层；
            // trainer.close() 会置 meta = nil，页面随之消失
            if let meta = trainer.meta {
                KlineDetailView(item: meta, isTraining: true, onClose: { trainer.close() })
                    .transition(.opacity)
            }
        }
        .onAppear {
            // App 启动即实例化行情行缓存，触发行情数值预热（无需等行情页首次打开）
            _ = MarketRowCache.shared
            MarketRowCache.shared.prewarmMarketData()
            // 混合架构：Web 侧请求切 Tab（nav.switchTab）→ 原生 selectedTab；
            // @State 投影跨 struct 拷贝共享存储，闭包写 selectedTab 即生效
            WebMessageRouter.shared.switchTabHandler = { index in
                guard selectedTab != index else { return }
                selectedTab = index
            }
        }
        // Tab 切换 → 推 nav.tab 事件（Web 侧切路由；keep-alive 页面不重建）
        .onChange(of: selectedTab) { newValue in
            WebMessageRouter.shared.pushEvent("nav.tab", payload: ["index": newValue])
        }
        .onReceive(DatabaseManager.shared.$isLoaded) { loaded in
            // 数据库就绪即预热（直接透传就绪标志，不依赖内部再读 db.isLoaded）
            MarketRowCache.shared.prewarmMarketData(isLoaded: loaded)
        }
        // 底栏高度实测值回填（0 是首帧的占位值，不覆盖）
        .onPreferenceChange(BottomBarHeightKey.self) { h in
            if h > 0 { bottomBarHeight = h }
        }
        // 训练激活即清掉普通详情页，避免两个全屏页叠加
        .onChange(of: trainer.meta) { newValue in
            if newValue != nil { DetailRouter.shared.item = nil }
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
        // 悬浮按钮（仿辅助触控，两个）与快捷面板：**只在 K 线详情页打开时显示**。
        // K 线详情页是根视图的全屏 overlay（detailItem != nil），自选/行情列表页不再显示按钮。
        // KlineDetailView 内任何弹窗（设置/搜索/编辑器/confirmationDialog/钻取）都会通过 coordinator
        // 的 isDetailViewPopupActive 推送出来，此处统一隐藏按钮；弹窗全部关闭后自动恢复。
        // 首屏加载期间同样不显示（isDetailViewLoaded 由 KlineDetailView 加载完成后锁存推送），
        // 避免页面还在转圈 / 白屏时按钮先出现。
        // 联动多图光标自动移动期间同样自动隐藏（hidesDuringCursorAutoMove）
        .overlay(
            Group {
                if detailItem != nil || trainer.meta != nil {
                    FloatingAccessoryButton(action: {
                        withAnimation(.easeOut(duration: 0.2)) { isAccessoryPanelPresented = true }
                    }, bottomClearance: bottomBarHeight)
                        .opacity(isButtonVisible ? 1 : 0)
                        .allowsHitTesting(isButtonVisible)
                        // 联动多图模式下光标自动移动（贴边自动滚动、抬手后仍继续）期间整体隐藏，
                        // 让出正在滚动的图表；停止后自动恢复
                        .hidesDuringCursorAutoMove()
                        // 新按钮（转圈驱动光标）：点击 B' 让被驱动那一格的窗口朝更新方向平移一根（内部走协调对象命令，
                        // 不需要外层注入 action）；面板呈现期间同样隐藏，否则它会压在面板的全屏遮罩之上
                        FloatingAccessoryWheel(bottomClearance: bottomBarHeight)
                            .opacity(isButtonVisible ? 1 : 0)
                            .allowsHitTesting(isButtonVisible)
                            .hidesDuringCursorAutoMove()
                }
                if isAccessoryPanelPresented {
                    // P2-6a：非训练态快捷面板迁 Web（sheet.open("quick") → 常驻浮层 WebView）；
                    // 训练态保留原生面板（训练闭环属 P2-6c Training 批次）
                    if TrainingSessionController.shared.isActive {
                        FloatingAccessoryPanel {
                            withAnimation(.easeOut(duration: 0.2)) { isAccessoryPanelPresented = false }
                        }
                        .transition(.opacity)
                    } else {
                        Color.clear
                            .onAppear {
                                SheetBridge.shared.closeHandler = { _ in
                                    withAnimation(.easeOut(duration: 0.2)) { isAccessoryPanelPresented = false }
                                }
                                SheetBridge.shared.sync("quick", active: true)
                            }
                    }
                }
                // P2-6a：弹层浮层宿主根层常驻（从 KlineDetailView 迁入——快捷面板全 App 可见；
                // 设置/搜索/指标面板同 Host 复用浮层 WebView；置于 overlay 链尾盖过详情页与悬浮球）
                SheetWebOverlayHost()
            }
        )
        // 异形屏横屏适配（全 App 唯一一处）：仅刘海侧保留安全区 inset，
        // 另一侧贴紧物理屏幕边缘。行情/自选表格、K线页、底部导航栏、各覆盖层
        // 全部继承此根布局安全区；页面内禁止重复叠加（二次外扩会越过物理边缘）。
        .notchSideOnlySafeArea()
        // 隐藏系统状态栏：Info.plist 已用 UIStatusBarHidden +
        // UIViewControllerBasedStatusBarAppearance=false 做 app 级配置（主手段，全机型/全版本一致），
        // 这里在根视图再叠一层 SwiftUI 声明，防止某代系统上 app 级配置被宿主控制器覆盖
        .statusBarHidden(true)
        // 主题：nil = 跟随系统；.light/.dark = 强制该外观。挂在根视图上，
        // 主内容区、底部栏、K 线全屏页、个人中心等所有覆盖层一并实时跟随
        .preferredColorScheme(themeStore.theme.colorScheme)
        // 训练设置窗浮层（居中卡片 + 遮罩）：挂在根层最上方，可盖住底部导航栏
        .trainingSetupSheet(isPresented: $trainingSetupRouter.isPresented)
        // 训练条件单 / 预警记录页（训练态浮层）：挂在最上层，盖住底部导航栏
        .trainingCondSheet(isPresented: $trainingCondRouter.isPresented)
    }

    // MARK: - 底部导航栏（VStack 底部固定段）
    // 高度 = 分隔线1pt + 按钮行（上图下字，图标20 + 文字11，约46pt），
    // 所有机型一致、按钮行直接贴物理屏幕底边。
    // 不做 home indicator 安全区垫高（用户要求与 mini4 形态统一，指示条绘制在按钮上层）；
    // 背景由外层 VStack 的 ignoresSafeArea(edges:.bottom) 铺到物理屏幕底边
    private var bottomMenuBar: some View {
        VStack(spacing: 0) {
            // 顶部分隔线（使用负offset往上挪）
            Color(.separator)
                .frame(height: 1)
                .offset(y: -2)
            // 菜单按钮（上图下字：图标在上、文字在下）
            HStack {
                ForEach(0..<menuItems.count, id: \.self) { index in
                    Button(action: {
                        handleTabTap(index: index)
                    }) {
                        VStack(spacing: 2) {
                            Image(systemName: menuItems[index].icon)
                                .font(.system(size: 20))
                            Text(menuItems[index].title)
                                .font(.system(size: 11))
                        }
                        .foregroundColor(selectedTab == index ? .accentColor : Color(.secondaryLabel))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
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
    // 混合架构 P2：Tab 内容逐页换 Web（原生实现类保留，回退 = 改回一行分支）。
    // 已换：0 首页（P2-3）/ 1 自选（P2-1）/ 2 行情（P2-2）/ 3 模拟（P2-4）。
    @ViewBuilder
    private var mainContentView: some View {
        switch selectedTab {
        case 0:
            if WebUIFiles.isBundleReady {
                // P2-3：首页 Web 化（原生浮层由 HomeWebShellView overlay 挂载）
                HomeWebShellView()
            } else {
                // Web UI 未构建 → 回退原生首页
                HomeView(isSearching: $isSearching, isProfilePresented: $isProfilePresented, selectedTab: $selectedTab)
            }
        case 1:
            if WebUIFiles.isBundleReady {
                WebTabHostView(route: "favorites")
            } else {
                // Web UI 未构建（bundle 根 WebUI/index.html 缺失）→ 回退原生自选页。
                // 正常发布会先 npm run build；本机构建可随时再 build 一次即自动切回 Web 化。
                FavoritesView()
            }
        case 2:
            if WebUIFiles.isBundleReady {
                // P2-2：行情页 Web 化（原生浮层由 MarketWebShellView overlay 挂载）
                MarketWebShellView()
            } else {
                // Web UI 未构建（bundle 根 WebUI/index.html 缺失）→ 回退原生行情页。
                MarketView()
            }
        case 3:
            if WebUIFiles.isBundleReady {
                // P2-4：模拟页 Web 化（原生浮层由 SimWebShellView 挂载：下单页/条件单/策略公式/训练记录）
                SimWebShellView()
            } else {
                // Web UI 未构建 → 回退原生模拟页
                SimulationView()
            }
        default:
            HomeView(isSearching: $isSearching, isProfilePresented: $isProfilePresented, selectedTab: $selectedTab)
        }
    }
}

// MARK: - 底部导航栏高度上报

/// 回传底部导航栏实际渲染高度（悬浮按钮据此避开 Tab 命中区）
struct BottomBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    ContentView()
}
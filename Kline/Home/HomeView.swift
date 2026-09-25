//
//  HomeView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/23.
//  2026/09/21 改为按布局偏好分发的容器（A/B/C/D），共享骨架见 HomePageKit.swift
//  非搜索态改为「JSON 配置优先」：配置可用则按档位节点树渲染，
//  配置不可用（或该档位缺失且无 default）时回落 A/B/C/D 硬编码布局视图；
//  内置默认配置在 HomeLayoutDefaults.swift，首启种入沙盒 Documents/Layouts/home.json。
//

import SwiftUI

// MARK: - 主页面（JSON 配置优先分发的容器）

/// 首页容器：搜索态统一走 `HomeSearchModeView`（四档共用）；
/// 非搜索态「JSON 配置优先」——按 `PageLayoutStore.homeLayout` 取 `PageLayoutConfigStore` 中该档位的节点树渲染，
/// 配置不可用时回落 A/B/C/D 硬编码布局视图（保底）。
/// 入口动作（切底部 Tab / 进入搜索 / 公式管理中心分段 / 条件单 / 个人中心）全部由容器注入的闭包承担，
/// 各档入口控件只回调、不持状态；数据由 `HomePageModel` 统一持有并下发给各档与内容区。
struct HomeView: View {
    @Binding var isSearching: Bool
    @Binding var isProfilePresented: Bool
    @Binding var selectedTab: Int
    @State private var searchText = ""
    @ObservedObject private var layoutStore = PageLayoutStore.shared
    /// 页面 JSON 布局配置仓库（已解码好的结果，body 内不做解码 / 遍历）
    @ObservedObject private var layoutConfig = PageLayoutConfigStore.shared
    /// 首页共享数据模型（B/C/D 三档与内容区共用）
    @StateObject private var model = HomePageModel()
    /// 浮层单一呈现目标（公式管理中心 / 条件单管理页）
    @State private var overlayTarget: HomeOverlayTarget? = nil

    var body: some View {
        VStack(spacing: 0) {
            if isSearching {
                // 搜索模式：返回按钮 + 搜索框（自动聚焦）+ 搜索结果页
                HomeSearchModeView(searchText: $searchText, isSearching: $isSearching)
            } else if let root = configRoot() {
                // JSON 配置优先：按当前档位的节点树渲染
                PageLayoutRenderer(registry: HomeWidgetRegistry.shared.registry,
                                   context: makeContext())
                    .view(for: root)
            } else {
                // 配置不可用 → 回落硬编码布局视图（保底）
                switch layoutStore.homeLayout {
                case .a:
                    HomeLayoutAView(onProfile: onProfile)
                case .b:
                    HomeLayoutBView(model: model, onSelectTab: onSelectTab, onSearch: onSearch,
                                    onOpenFormula: onOpenFormula, onOpenCondOrder: onOpenCondOrder,
                                    onOpenAlertRecords: onOpenAlertRecords,
                                    onOpenLayoutEditor: onOpenLayoutEditor,
                                    onProfile: onProfile)
                case .c:
                    HomeLayoutCView(model: model, onSelectTab: onSelectTab, onSearch: onSearch,
                                    onOpenFormula: onOpenFormula, onOpenCondOrder: onOpenCondOrder,
                                    onOpenAlertRecords: onOpenAlertRecords,
                                    onOpenLayoutEditor: onOpenLayoutEditor,
                                    onProfile: onProfile)
                case .d:
                    HomeLayoutDView(model: model, onSelectTab: onSelectTab, onSearch: onSearch,
                                    onOpenFormula: onOpenFormula, onOpenCondOrder: onOpenCondOrder,
                                    onOpenAlertRecords: onOpenAlertRecords,
                                    onOpenLayoutEditor: onOpenLayoutEditor,
                                    onProfile: onProfile)
                }
            }
        }
        .homeOverlays(target: $overlayTarget)
        .onAppear {
            // 注册内置默认（幂等）后按需重载：沙盒 Documents/Layouts/home.json 变化即时生效
            PageLayoutConfigStore.shared.registerBuiltInDefaults(page: "home",
                                                                 json: homeLayoutDefaultsJSON)
            PageLayoutConfigStore.shared.reloadIfChanged(page: "home")
        }
    }

    // MARK: - JSON 配置驱动

    /// 当前档位在 JSON 配置里对应的节点树根；
    /// 配置不可用 / 档位缺失（且配置里没有 default 兜底）时返回 nil，交给硬编码布局视图
    private func configRoot() -> PageLayoutNode? {
        layoutConfig.layout(id: layoutStore.homeLayout.rawValue,
                            for: PageLayoutConfigStore.homePage)?.root
    }

    /// 构建配置渲染上下文（数据模型 + 容器注入的入口闭包）
    private func makeContext() -> HomeLayoutContext {
        HomeLayoutContext(model: model, onProfile: onProfile,
                          onEntry: perform, onSelectTab: onSelectTab)
    }

    // MARK: - 入口动作（三档共用；索引与 ContentView.menuItems 一致：自选 1 / 行情 2 / 模拟 3）

    /// 快捷入口动作映射（与各档布局视图的 perform(_:) 逐项一致）
    private func perform(_ kind: HomeEntryKind) {
        switch kind {
        case .search: onSearch()
        case .tech, .picker, .strategy:
            if let fk = kind.formulaKind { onOpenFormula(fk) }
        case .condOrder: onOpenCondOrder()
        case .profile: onProfile()
        case .alertRecords: onOpenAlertRecords()
        case .layoutEditor: onOpenLayoutEditor()
        }
    }

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

    private func onOpenAlertRecords() {
        overlayTarget = .alertRecords
    }

    private func onOpenLayoutEditor() {
        // 编辑器要盖住底部导航栏 → 走根层路由呈现（页面内 overlay 盖不住底栏）
        HomeLayoutEditorRouter.shared.isPresented = true
    }

    private func onProfile() {
        isProfilePresented = true
    }
}

#Preview {
    HomeView(isSearching: .constant(false), isProfilePresented: .constant(false), selectedTab: .constant(0))
}
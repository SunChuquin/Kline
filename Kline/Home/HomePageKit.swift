//
//  HomePageKit.swift
//  Kline
//
//  首页共享骨架：入口清单 HomeEntryKind、横滑快捷入口行（HomeQuickEntryRow + HomeQuickEntryChip）、
//  标题栏 HomeHeaderBar、搜索模式视图 HomeSearchModeView，以及单一目标浮层 homeOverlays(...)。
//  设计要点：
//  - 入口文案 / 图标 / 语义色统一由 HomeEntryKind 提供，三档共用同一份清单，各档只做组合；
//  - 入口与底部导航栏重复的三项（自选 / 行情 / 模拟）已按用户反馈剔除，只留首页独有的入口；
//  - 入口控件只接收闭包（onTap / onProfile），不持任何状态、不发命令，
//    状态与跳转（搜索 / 公式分段 / 条件单 / 个人中心）统一由容器 HomeView 注入；
//  - 颜色全部走语义色（Color(.systemBackground) / Color(.secondarySystemBackground) / .primary / .secondary），
//    深色模式自动适配；可点击元素命中区均 ≥ 44pt，且高度固定（点击与切档不抖动）。
//

import SwiftUI

// MARK: - 入口清单（三档共用同一份数据）

/// 首页入口类型：名称 / 说明 / 图标 / 语义色 / 公式分段。
/// 只收首页独有入口（自选 / 行情 / 模拟与底部导航栏重复，已剔除）。
enum HomeEntryKind: String, CaseIterable, Identifiable {
    case search
    case tech
    case picker
    case strategy
    case condOrder
    case profile

    var id: String { rawValue }

    /// 入口名称
    var title: String {
        switch self {
        case .search: return "搜索标的"
        case .tech: return "技术指标"
        case .picker: return "选股指标"
        case .strategy: return "交易策略"
        case .condOrder: return "条件单"
        case .profile: return "个人中心"
        }
    }

    /// 入口说明（横滑 chip 的副标题）
    var subtitle: String {
        switch self {
        case .search: return "按名称 / 代码检索"
        case .tech: return "主图叠加与副图指标"
        case .picker: return "全市场跑选股"
        case .strategy: return "策略与历史回测"
        case .condOrder: return "监控与触发下单"
        case .profile: return "主题与页面布局"
        }
    }

    /// SF Symbol 图标名
    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .tech: return "function"
        case .picker: return "line.3.horizontal.decrease.circle"
        case .strategy: return "chart.xyaxis.line"
        case .condOrder: return "bell.badge"
        case .profile: return "person.circle"
        }
    }

    /// 语义色（自适应深浅色，不写死具体色值）
    var tint: Color {
        switch self {
        case .search: return .blue
        case .tech: return .purple
        case .picker: return .orange
        case .strategy: return .teal
        case .condOrder: return .red
        case .profile: return .blue
        }
    }

    /// 公式类入口对应的公式管理中心分段（非公式入口为 nil）
    var formulaKind: FormulaKind? {
        switch self {
        case .tech: return .tech
        case .picker: return .picker
        case .strategy: return .strategy
        case .search, .condOrder, .profile: return nil
        }
    }
}

// MARK: - 横滑快捷入口行（三档共用）

/// 首页横滑快捷入口行：一行可左右拖动的入口卡片。
/// 6 项 chip 合计约 1100pt > 1024pt（iPad mini 4 横屏），横屏下天然需要左右拖动 ——
/// 这是本次变更的核心诉求（首屏不再被宫格/列表占满），chip 的 minWidth 不要调小到能一屏放下。
struct HomeQuickEntryRow: View {
    let onTap: (HomeEntryKind) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(HomeEntryKind.allCases) { kind in
                    HomeQuickEntryChip(kind: kind, action: { onTap(kind) })
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

/// 快捷入口卡片：图标 22pt + 标题 13pt + 一行说明 11pt。
/// 固定最小宽 168 / 最小高 68（命中区 ≥ 44pt）；点击整卡生效。
struct HomeQuickEntryChip: View {
    let kind: HomeEntryKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: kind.icon)
                    .font(.system(size: 22))
                    .foregroundColor(kind.tint)
                Text(kind.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Text(kind.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(minWidth: 168, minHeight: 68, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.entry.\(kind.rawValue)")
    }
}

// MARK: - 顶部标题栏（等价搬入改造前 HomeView 非搜索态的标题栏）

/// 首页标题栏：左侧软件图标 + 名称，右侧「登录」用户入口胶囊。三档共用。
/// 外观、间距、配色与改造前逐项一致；用户入口点击由容器注入的 `onProfile` 承担。
/// 无障碍标识 `home.page` 挂在软件名 Text 上：三档都渲染本标题栏，
/// Text 在无障碍树里是 staticText，`app.staticTexts["home.page"]` 稳定命中
/// （挂在各档内容根容器上的标识在 SwiftUI 里未必暴露成元素）。
struct HomeHeaderBar: View {
    let onProfile: () -> Void

    var body: some View {
        HStack {
            // 软件图标和名称
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 24))
                    .foregroundColor(.red)
                Text("Kline")
                    .font(.system(size: 18))
                    .fontWeight(.bold)
                    .accessibilityIdentifier("home.page")
            }
            .padding(.leading, 16)

            Spacer()

            // 用户入口按钮
            Button(action: onProfile) {
                HStack(spacing: 5) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.blue)
                    Text("登录")
                        .font(.system(size: 16))
                }
                .padding(EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2))
                .background(Color(.systemGray5))
                .cornerRadius(20)
            }
            .padding(.trailing, 16)
        }
        .background(Color(.systemBackground))
        .frame(minHeight: 56)
    }
}

// MARK: - 搜索模式（三档共用，等价搬入改造前 HomeView 的搜索态）

/// 首页搜索模式：返回按钮 + 搜索框（自动聚焦）+ 搜索结果页。
/// 与改造前逐项一致：`.focused` 延时 0.05s 自动聚焦；点返回清空 `searchText` 并置 `isSearching = false`。
/// `@FocusState` 由本视图自己持有，容器只传两个绑定。
struct HomeSearchModeView: View {
    @Binding var searchText: String
    @Binding var isSearching: Bool
    @FocusState private var searchFocused: Bool

    init(searchText: Binding<String>, isSearching: Binding<Bool>) {
        _searchText = searchText
        _isSearching = isSearching
        _searchFocused = FocusState()
    }

    var body: some View {
        VStack(spacing: 0) {
            // 搜索模式：返回按钮 + 搜索框
            HStack {
                Button(action: {
                    isSearching = false
                    searchText = ""
                    searchFocused = false
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24))
                }
                .padding(.leading, 16)

                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("搜索", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                }
                .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .background(Color(.systemGray5))
                .cornerRadius(8)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.systemBackground))
            .frame(minHeight: 56)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    searchFocused = true
                }
            }

            Divider()

            SearchPageView(searchText: $searchText)
                .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - 浮层（单一呈现目标，三档共用）

/// 首页浮层的单一呈现目标：公式管理中心（按分段）/ 条件单管理页。
/// 用单一 target 枚举而非多个 Bool：类型上保证同时只呈现一个，切换时自然替换。
enum HomeOverlayTarget: Identifiable, Equatable {
    case formula(FormulaKind)
    case condOrder

    var id: String {
        switch self {
        case .formula(let kind): return "formula.\(kind.rawValue)"
        case .condOrder: return "condOrder"
        }
    }
}

/// 首页浮层容器：公式管理中心 / 条件单管理页都是全屏页面（铺满，无遮罩），关闭走页内「返回」。
/// 与个人中心同做法：挂在页面根视图上，避免被列表 ScrollView 裁剪。
struct HomeOverlays: ViewModifier {
    @Binding var target: HomeOverlayTarget?

    func body(content: Content) -> some View {
        content
            .overlay {
                if let t = target {
                    ZStack {
                        switch t {
                        case .formula(let kind):
                            // `.id`：切分段（技术 / 选股 / 策略）时重建页面，让初始分段真正生效
                            FormulaCenterView(initialKind: kind, onClose: { target = nil })
                                .id(t.id)
                        case .condOrder:
                            SimCondListView(accountID: nil, onClose: { target = nil })
                        }
                    }
                    .transition(.opacity)
                    .zIndex(1000)
                }
            }
    }
}

extension View {
    /// 挂载首页浮层（公式管理中心 / 条件单管理页；三档共用）
    func homeOverlays(target: Binding<HomeOverlayTarget?>) -> some View {
        modifier(HomeOverlays(target: target))
    }
}

#Preview {
    VStack(spacing: 0) {
        HomeHeaderBar(onProfile: {})
        Divider()
        HomeQuickEntryRow(onTap: { _ in })
        Spacer()
    }
}
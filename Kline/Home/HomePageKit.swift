//
//  HomePageKit.swift
//  Kline
//
//  首页共享骨架：入口清单模型 HomeEntryKind 与跨布局共享的子视图
//  （标题栏 HomeHeaderBar / 搜索条 HomeSearchBar / 宫格磁贴 HomeEntryTile /
//   列表行 HomeEntryRow / 卡片 HomeEntryCard / 搜索模式视图 HomeSearchModeView），
//  以及公式管理全屏浮层 homeOverlays(...)。
//  设计要点：
//  - 入口文案 / 图标 / 语义色统一由 HomeEntryKind 提供，四档共用同一份清单，各档只做组合；
//  - 入口控件只接收闭包（action / onTap / onProfile），不持任何状态、不发命令，
//    状态与跳转统一由容器 HomeView 注入（写法与 FavoritesPageKit / MarketPageKit 同惯例）；
//  - 颜色全部走语义色（Color(.systemBackground) / Color(.systemGray5) / .primary / .secondary），
//    深色模式自动适配；可点击元素命中区均 ≥ 44pt，且高度固定（点击与切档不抖动）。
//

import SwiftUI

// MARK: - 入口清单（四档共用同一份数据）

/// 首页入口类型：名称 / 说明 / 图标 / 语义色。
/// B 档取 title + icon；C 档取 title + subtitle + icon；D 档取 title + subtitle + icon。
enum HomeEntryKind: String, CaseIterable, Identifiable {
    case search
    case favorites
    case market
    case simulation
    case formula
    case profile

    var id: String { rawValue }

    /// 入口名称
    var title: String {
        switch self {
        case .search: return "搜索标的"
        case .favorites: return "自选"
        case .market: return "行情"
        case .simulation: return "模拟交易"
        case .formula: return "公式管理"
        case .profile: return "个人中心"
        }
    }

    /// 入口说明（C 档列表行副标题 / D 档卡片说明）
    var subtitle: String {
        switch self {
        case .search: return "按名称 / 代码检索标的"
        case .favorites: return "分组自选与公式选股结果"
        case .market: return "沪深主板 / ETF 指数行情表"
        case .simulation: return "账户、持仓、委托与条件单"
        case .formula: return "技术指标 / 选股指标 / 交易策略"
        case .profile: return "主题、页面布局与本地更新"
        }
    }

    /// SF Symbol 图标名
    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .favorites: return "folder"
        case .market: return "chart.bar"
        case .simulation: return "gamecontroller"
        case .formula: return "function"
        case .profile: return "person.circle"
        }
    }

    /// 语义色（自适应深浅色，不写死具体色值）
    var tint: Color {
        switch self {
        case .search: return .blue
        case .favorites: return .orange
        case .market: return .red
        case .simulation: return .green
        case .formula: return .purple
        case .profile: return .blue
        }
    }
}

// MARK: - 顶部标题栏（等价搬入改造前 HomeView 非搜索态的标题栏）

/// 首页标题栏：左侧软件图标 + 名称，右侧「登录」用户入口胶囊。四档共用。
/// 外观、间距、配色与改造前逐项一致；用户入口点击由容器注入的 `onProfile` 承担。
/// 无障碍标识 `home.page` 挂在软件名 Text 上：四档都渲染本标题栏，
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

// MARK: - 只读搜索条（B 档顶部，点击进入搜索模式）

/// 只读样式的搜索条：外观同搜索模式的搜索框（灰色放大镜 + 「搜索」灰字 + 灰底圆角条），
/// 本身不接受输入，整条可点（命中区高 44pt）→ 由容器把 `isSearching` 置真进入搜索模式。
struct HomeSearchBar: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                Text("搜索")
                    .foregroundColor(.gray)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Color(.systemGray5))
            .cornerRadius(8)
            // 外观 36pt 高，命中区补到 44pt（补的空间在上下，视觉不变）
            .frame(height: 44)
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 宫格磁贴（B 档）

/// 宫格入口磁贴：图标 28 + 名称 13，格高固定 88pt（≥ 44pt 命中区），整格可点。
struct HomeEntryTile: View {
    let kind: HomeEntryKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: kind.icon)
                    .font(.system(size: 28))
                    .foregroundColor(kind.tint)
                Text(kind.title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.entry.\(kind.rawValue)")
    }
}

// MARK: - 列表入口行（C 档）

/// 分区列表入口行：左侧 28pt 图标方块 + 标题 16 + 说明 12 + 右侧 chevron，行高固定 56pt，整行可点。
struct HomeEntryRow: View {
    let kind: HomeEntryKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: kind.icon)
                    .font(.system(size: 15))
                    .foregroundColor(kind.tint)
                    .frame(width: 28, height: 28)
                    .background(Color(.systemGray6))
                    .cornerRadius(7)

                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                    Text(kind.subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.entry.\(kind.rawValue)")
    }
}

// MARK: - 入口卡片（D 档）

/// 卡片入口：大卡 / 中卡 / 小卡共用一份实现，只参数化高度与排版（不做三份重复实现）。
/// - Parameters:
///   - height: 卡片高度（D 档：大卡 / 中卡 104、小卡 64 等，由布局视图传入）
///   - big: true → 标题 16 semibold + 说明 12（大卡）；false → 标题 15 semibold + 说明 11.5（中卡）
///   - showsChevron: 小卡右侧显示 chevron（无说明行的横向卡）
struct HomeEntryCard: View {
    let kind: HomeEntryKind
    let height: CGFloat
    var big: Bool = false
    var showsChevron: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: big ? 8 : 6) {
                HStack(spacing: 8) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 22))
                        .foregroundColor(kind.tint)
                    Text(kind.title)
                        .font(.system(size: big ? 16 : 15, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if showsChevron {
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
                Text(kind.subtitle)
                    .font(.system(size: big ? 12 : 11.5))
                    .foregroundColor(.secondary)
                    .lineLimit(big ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                if !showsChevron {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.entry.\(kind.rawValue)")
    }
}

// MARK: - 搜索模式（四档共用，等价搬入改造前 HomeView 的搜索态）

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

// MARK: - 浮层（公式管理中心，四档共用）

/// 首页浮层：公式管理中心全屏页面（铺满，无遮罩），关闭走页内「返回」。
/// 与个人中心同做法：挂在页面根视图上，避免被列表 ScrollView 裁剪。
struct HomeOverlays: ViewModifier {
    @Binding var showFormulaCenter: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if showFormulaCenter {
                    ZStack {
                        FormulaCenterView(initialKind: .tech, onClose: { showFormulaCenter = false })
                    }
                    .transition(.opacity)
                    .zIndex(1000)
                }
            }
    }
}

extension View {
    /// 挂载首页浮层（公式管理中心；四档共用）
    func homeOverlays(showFormulaCenter: Binding<Bool>) -> some View {
        modifier(HomeOverlays(showFormulaCenter: showFormulaCenter))
    }
}

#Preview {
    VStack(spacing: 0) {
        HomeHeaderBar(onProfile: {})
        Divider()
        HomeSearchBar(onTap: {})
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    HomeEntryTile(kind: .search, action: {})
                    HomeEntryTile(kind: .favorites, action: {})
                }
                HomeEntryRow(kind: .market, action: {})
                HomeEntryCard(kind: .simulation, height: 104, big: true, action: {})
                HomeEntryCard(kind: .profile, height: 64, showsChevron: true, action: {})
            }
            .padding()
        }
    }
}
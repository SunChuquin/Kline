//
//  MarketLayoutBView.swift
//  Kline
//
//  行情页 B 档布局（分类侧栏 + 表格）：
//  regular（≥600，iPad / iPhone 横屏）：左侧 200pt 常驻分类侧栏（一级分区标题 + 二级条目 +
//  数量角标），右侧工作区（当前分类名 + 数量 + 工具条 + 共享表格主体），形态与交互不变。
//  紧凑宽（<600，iPhone 竖屏 414）：侧栏 + 工作区固有宽 ~512 超出屏宽（侧栏条目被挤到
//  x=-49、工作区「搜索」按钮 +37pt 出屏），侧栏收纳为工作区标题位的「分类」抽屉
//  （SidebarDrawer，与自选 B 完全同款交互），工作区占满整页、工具条全按钮回到屏内；
//  分类行复用侧栏同一份行视图，切分类路径一条不丢。
//  分类状态与 A 档共用（topMenu / selectedTab / pickerSeg / favSeg），切换布局不丢分类。
//

import SwiftUI

/// 抽屉选项的 Hashable 补齐（SidebarDrawer 的 Selection 约束）：MarketTopMenuItem 定义在
/// MarketPageKit.swift（本任务不动该文件），以「field + key」判定身份——badge 只是数量角标
/// （随行情数变化），不参与相等，否则选中高亮会被角标变化击穿
extension MarketTopMenuItem: Hashable {
    static func == (lhs: MarketTopMenuItem, rhs: MarketTopMenuItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct MarketLayoutBView: View {
    @ObservedObject var model: MarketPageModel
    /// 数据库加载态（与 A 档一致：未加载完显示「加载中」，加载完按有无标的显示空态或表格）
    @ObservedObject private var databaseManager = DatabaseManager.shared

    /// 页面可用宽度：由顶层 WidthReader 上报。0 表示尚未上报——此时按 regular（侧栏常驻）
    /// 形态渲染，保证 iPad 首帧与既有 UITest 场景完全一致（与自选 B 同一范式）
    @State private var availableWidth: CGFloat = 0

    /// 紧凑宽度形态（可用宽 < 600，iPhone 竖屏 414 命中）：侧栏折叠为抽屉，工作区占满整页
    private var isCompact: Bool {
        availableWidth > 0 && availableWidth < CompactWidth.threshold
    }

    /// 紧凑态分类抽屉开关（工作区标题位「分类」入口按钮 toggle）
    @State private var categoryDrawerActive = false

    var body: some View {
        // 顶层测宽（WidthReader 只允许在页面顶层包裹，见其文档）
        WidthReader(onChange: { availableWidth = $0 }) {
            Group {
                if isCompact {
                    compactBody
                } else {
                    HStack(spacing: 0) {
                        MarketCategorySidebar(model: model)
                            .frame(width: MarketCategorySidebar.width)
                        Divider()
                        VStack(spacing: 0) {
                            workspaceBar
                            Divider()
                            content
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .onChange(of: isCompact) { compact in
                // 旋转跨过 600 阈值（竖屏 ↔ 横屏）：抽屉随紧凑态消失，
                // 复位开关避免转回窄屏时抽屉残留展开
                if !compact { categoryDrawerActive = false }
            }
        }
    }

    // MARK: - 紧凑态主体（<600：侧栏收纳为抽屉）

    /// 紧凑态：无侧栏，工作区占满整页；分类收纳进抽屉。
    /// 抽屉 overlay 挂在表格内容区（工具条下方）：面板从工具条下缘下拉展开，
    /// 锚点按钮不被遮罩盖住、保持可点（再点一次即收起）
    private var compactBody: some View {
        VStack(spacing: 0) {
            workspaceBar
            Divider()
            content
                .overlay {
                    // 抽屉仅展开态挂树：收起态条件移除——容器级与元素级 accessibilityHidden
                    // 对本组件的直接子 Button 均不生效（真机探针实测），条件渲染是唯一
                    // 确定的移除手段；滑动/淡入转场补回抽屉原本的滑入感
                    if categoryDrawerActive {
                        categoryDrawer
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: categoryDrawerActive)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    /// 工具条（regular / 紧凑共用一份数据与工具按钮，标题位按形态切换）
    private var workspaceBar: some View {
        MarketWorkspaceBar(model: model, isCompact: isCompact, drawerActive: $categoryDrawerActive)
    }

    /// 分类抽屉（紧凑态）：行复用常驻侧栏同一份行视图（图标 + 名称 + 数量角标 + 选中蓝底）；
    /// 行本身是 Button（Button 优先于抽屉外层 onTapGesture），点行即「切分类 + 收抽屉」，
    /// 不会误触外层手势造成二次收起
    private var categoryDrawer: some View {
        let options = drawerOptions
        return SidebarDrawer(
            isPresented: $categoryDrawerActive,
            title: "分类",
            options: options,
            selection: currentDrawerSelection ?? options[0],
            onSelect: { model.setSidebarSelection($0) },
            rowContent: { item, active in
                Button {
                    model.setSidebarSelection(item)
                    categoryDrawerActive = false
                } label: {
                    MarketCategoryRow(item: item, selected: active)
                }
                .buttonStyle(.plain)
            }
        )
    }

    /// 抽屉选项：三个一级分区下的全部二级条目按序平铺（条目图标本身区分分区；
    /// 侧栏的一级分区标题行是分区语义而非分类，抽屉内不重复占行）
    private var drawerOptions: [MarketTopMenuItem] {
        TopField.allCases.flatMap { model.topMenuItems(for: $0) }
    }

    /// 当前选中的条目（与侧栏同一判定：一级 + 对应二级状态都命中）
    private var currentDrawerSelection: MarketTopMenuItem? {
        for field in TopField.allCases {
            for item in model.topMenuItems(for: field) where isSelected(item) {
                return item
            }
        }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        if databaseManager.isLoaded {
            if model.tabItems.isEmpty {
                MarketEmptyStateView(icon: "magnifyingglass", message: "暂无标的")
            } else {
                MarketTableBody(model: model)
            }
        } else {
            VStack(spacing: 16) {
                ProgressView()
                Text("加载中...").foregroundColor(.gray)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// 选中判定：一级 + 对应的二级状态都命中
    private func isSelected(_ item: MarketTopMenuItem) -> Bool {
        guard model.topMenu == item.field else { return false }
        switch item.field {
        case .market: return model.selectedTab.rawValue == item.key
        case .picker: return model.pickerSeg.rawValue == item.key
        case .fav: return model.favSeg.rawValue == item.key
        }
    }
}

// MARK: - 左侧分类侧栏

/// 分类侧栏：按一级分区（市场 / 选股 / 自选）列出全部二级条目，
/// 条目不折叠、点击即切（一级分区标题行复用无障碍标识 `market.topMenu.<一级名>`）。
struct MarketCategorySidebar: View {
    @ObservedObject var model: MarketPageModel

    /// 侧栏宽度（容器据此写入 model.tableWidthInset 修正表格横向滚动上限）
    static let width: CGFloat = 200

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(TopField.allCases) { field in
                    sectionHeader(field)
                    ForEach(model.topMenuItems(for: field)) { item in
                        itemRow(item)
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .background(Color(.secondarySystemBackground))
    }

    /// 一级分区标题行：小字灰色，非「条目」语义；保留 `market.topMenu.<一级名>` 标识，
    /// 点击等同切换一级分类（既有 UITest 仍可定位到「市场」）。
    private func sectionHeader(_ field: TopField) -> some View {
        Button {
            model.tapTopMenu(field)
        } label: {
            HStack(spacing: 0) {
                Text(field.rawValue)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("market.topMenu.\(field.rawValue)")
    }

    /// 二级条目行：按钮（图标 + 名称 + 数量角标，选中蓝底），点击切分类
    private func itemRow(_ item: MarketTopMenuItem) -> some View {
        Button {
            model.setSidebarSelection(item)
        } label: {
            MarketCategoryRow(item: item, selected: isSelected(item))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    /// 选中判定：一级 + 对应的二级状态都命中
    private func isSelected(_ item: MarketTopMenuItem) -> Bool {
        guard model.topMenu == item.field else { return false }
        switch item.field {
        case .market: return model.selectedTab.rawValue == item.key
        case .picker: return model.pickerSeg.rawValue == item.key
        case .fav: return model.favSeg.rawValue == item.key
        }
    }
}

/// 二级条目行视图（纯视觉）：图标 + 名称 + 数量角标（无数据源显示「-」），选中项蓝底高亮。
/// 常驻侧栏与紧凑抽屉共用同一份；点击由各自宿主挂（侧栏 Button 直切，抽屉行切完收抽屉）
private struct MarketCategoryRow: View {
    let item: MarketTopMenuItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.icon(for: item))
                .font(.system(size: 14))
                .foregroundColor(selected ? .blue : .secondary)
                .frame(width: 24)
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(selected ? .blue : .primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(item.badge ?? "-")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.blue.opacity(0.12) : Color.clear)
        .cornerRadius(9)
    }

    /// 条目图标（按二级分类区分）
    static func icon(for item: MarketTopMenuItem) -> String {
        switch item.field {
        case .market:
            return item.key == MarketTab.mainBoard.rawValue ? "chart.bar.xaxis" : "chart.line.uptrend.xyaxis"
        case .picker:
            if item.key == PickerField.trend.rawValue { return "arrow.up.right" }
            if item.key == PickerField.oscillation.rawValue { return "waveform" }
            if item.key == PickerField.reversal.rawValue { return "arrow.uturn.backward" }
            return "flame"
        case .fav:
            return item.key == FavField.holdings.rawValue ? "briefcase" : "square.stack.3d.up"
        }
    }
}

// MARK: - 右侧工作区工具条

/// 工作区工具条：当前二级分类名 + 数量（当前展示行数）+ 表头设置 / 边线调整 / 搜索（选股额外给公式）。
/// 紧凑态：标题位换成「分类」抽屉入口（图标 + 当前分类名 + 下拉箭头），点击开合抽屉
private struct MarketWorkspaceBar: View {
    @ObservedObject var model: MarketPageModel
    var isCompact: Bool = false
    /// 紧凑态分类抽屉开关（标题位入口按钮 toggle）
    @Binding var drawerActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isCompact {
                categoryDrawerAnchor
            } else {
                Text(model.currentCategoryTitle)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
            }
            Text("\(model.displayRows.count) 只")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            MarketToolBar(model: model)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color(.systemBackground))
    }

    /// 紧凑态「分类」抽屉入口（锚点）：侧栏图标 + 当前分类名 + 下拉箭头，点击开合抽屉。
    /// 无障碍标识沿用一级菜单 `market.topMenu.<当前一级名>`——紧凑态侧栏分区标题随侧栏
    /// 收进抽屉，标识移驻入口（与自选 B 把 favorites.title 移驻分组入口同一处理）：
    /// 点「市场」即展开分类抽屉，语义与 A 档「点一级菜单展开二级」一致，UITest 锚点不丢
    private var categoryDrawerAnchor: some View {
        Button {
            drawerActive.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(model.currentCategoryTitle)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("market.topMenu.\(model.topMenu.rawValue)")
        // 低布局优先级：空间不足时优先压缩分类名（截断显示），右侧工具按钮保持完整可点
        .layoutPriority(-1)
    }
}

#Preview {
    MarketLayoutBView(model: MarketPageModel())
}

//
//  FavoritesLayoutBView.swift
//  Kline
//
//  自选页 B 档布局：分组侧栏 + 表格工作区。
//  regular（≥600，iPad / iPhone 横屏）：左侧 216pt 常驻分组侧栏（一行直达切换分组 /
//  公式分组行内刷新 / 底部新建与管理）+ 右侧工作区 = 分组标题 + 工具条 + 共享表格主体，
//  形态与交互完全不变。
//  紧凑宽（<600，iPhone 竖屏 414pt）：常驻侧栏让整页固有宽 ~475 超出屏宽，收纳为
//  header「分组」抽屉入口（SidebarDrawer，用户选定交互），工作区占满整页；
//  分组行 / 底部新建管理入口与侧栏共用同一份组件，切换 / 刷新 / 新建 / 管理路径不丢。
//  与 A/C/D 同源：同一份 FavoritesPageModel 与 FavoritesTableBody，
//  切布局不丢失当前分组、排序、筛选（都挂在 model / 共享 Store 上）。
//

import SwiftUI

struct FavoritesLayoutBView: View {
    @ObservedObject var model: FavoritesPageModel

    /// 页面可用宽度：由顶层 WidthReader 上报。0 表示尚未上报——
    /// 此时按 regular（侧栏常驻）形态渲染，保证 iPad 首帧与既有 UITest 场景完全一致
    @State private var availableWidth: CGFloat = 0

    /// 紧凑宽度形态（可用宽 < 600）：侧栏折叠为抽屉入口，工作区占满整页
    private var isCompact: Bool {
        availableWidth > 0 && availableWidth < CompactWidth.threshold
    }

    /// 紧凑态分组抽屉开关（header「分组」入口按钮 toggle）
    @State private var groupDrawerActive = false

    var body: some View {
        // 顶层测宽（WidthReader 只允许在页面顶层包裹，见其文档）
        WidthReader(onChange: { availableWidth = $0 }) {
            Group {
                if isCompact {
                    compactBody
                } else {
                    HStack(spacing: 0) {
                        FavoritesGroupSidebar(model: model)
                        // 侧栏与工作区之间的 1pt 分隔线
                        Rectangle()
                            .fill(Color(.separator))
                            .frame(width: 1)
                        workspace
                    }
                }
            }
            .onChange(of: isCompact) { compact in
                // 旋转跨过 600 阈值（竖屏 ↔ 横屏）：抽屉随紧凑态消失，
                // 复位开关避免转回窄屏时抽屉残留展开
                if !compact { groupDrawerActive = false }
            }
        }
    }

    // MARK: - 紧凑态主体（<600：侧栏收纳为抽屉）

    /// 紧凑态：无侧栏，工作区占满整页；分组收纳进 header 抽屉。
    /// 抽屉 overlay 挂在表格内容区（header 下方）：面板从 header 下缘下拉展开，
    /// 锚点按钮不被遮罩盖住、保持可点（再点一次即收起）
    private var compactBody: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()
            FavoritesTableBody(model: model)
                .overlay {
                    groupDrawer
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    /// 分组抽屉（紧凑态）：行与底部入口照搬常驻侧栏（FavoritesGroupRow /
    /// FavoritesGroupFooterButtons 与侧栏共用同一份结构），分组切换 / 公式组行内
    /// 刷新 / 新建 / 管理四条路径一条不丢
    private var groupDrawer: some View {
        SidebarDrawer(
            isPresented: $groupDrawerActive,
            title: "分组",
            options: model.tabs,
            selection: model.currentGroup,
            onSelect: { g in
                if model.fav.selectedGroupID != g.id { model.fav.selectedGroupID = g.id }
            },
            rowContent: { g, active in
                FavoritesGroupRow(model: model, group: g, active: active)
            },
            footer: {
                FavoritesGroupFooterButtons(model: model)
            }
        )
    }

    // MARK: - 右侧工作区

    private var workspace: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()
            // 加载态 / 空态 / （吸顶表头 + 列表）由共享表格主体负责
            FavoritesTableBody(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    /// 一行标题（当前分组名 + N 只）+ 工具条（表头设置 / 编辑 / 公式分组刷新选股）。
    /// 紧凑态：标题位换成「分组」抽屉入口（图标 + 当前分组名 + 下拉箭头），搜索 / 表头
    /// 设置收成纯图标按钮、间距与内边距收紧——侧栏收纳后工作区 414pt，
    /// 以「全部按钮可见可点、不出屏」为准，风格不大改
    private var workspaceHeader: some View {
        HStack(spacing: isCompact ? 6 : 10) {
            if isCompact {
                groupDrawerAnchor
            } else {
                Text(model.currentGroup.name)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
            }
            Text("\(model.currentItems.count) 只")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize()
            Spacer(minLength: isCompact ? 4 : 8)
            // 刷新监控标的列表（全局刷新按钮）
            refreshButton
            if isCompact {
                // 紧凑态搜索收成纯图标（与 C 档顶栏同款），省下的宽度保住「全部按钮不出屏」
                iconToolButton("magnifyingglass") {
                    model.homeSearchActive = true
                }
            } else {
                // 搜索按钮
                toolButton("搜索", icon: "magnifyingglass") {
                    model.homeSearchActive = true
                }
            }
            if model.currentGroup.kind == .formula {
                formulaRefreshButton(group: model.currentGroup)
            }
            if isCompact {
                iconToolButton("slider.horizontal.3") {
                    model.showColumnPanel = true
                }
            } else {
                toolButton("表头设置", icon: "slider.horizontal.3") {
                    model.showColumnPanel = true
                }
            }
            // 编辑态开关：与 A/C/D 档同一按钮（文案「编辑」→「完成」，退出时清空多选）
            FavoritesEditToggleButton(model: model)
        }
        .padding(.horizontal, isCompact ? 12 : 16)
        .frame(height: 46)
        .background(Color(.systemBackground))
    }

    /// 紧凑态「分组」抽屉入口（锚点）：侧栏图标 + 当前分组名 + 下拉箭头。
    /// 分组名加粗并承载 favorites.title 无障碍标识（紧凑态侧栏标题消失，标识移到这里；
    /// 探针用例按 staticTexts 查询，故用 onTapGesture 而非 Button——Button 会把
    /// 内部 Text 合并成按钮元素导致查询落空）
    private var groupDrawerAnchor: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text(model.currentGroup.name)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
                .accessibilityIdentifier("favorites.title")
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
        }
        // 低布局优先级：空间不足时优先压缩分组名（截断显示），右侧工具按钮保持完整可点
        .layoutPriority(-1)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { groupDrawerActive.toggle() }
    }

    /// 刷新按钮
    private var refreshButton: some View {
        Button {
            WatchlistSyncManager.shared.sync(reason: "手动")
        } label: {
            HStack(spacing: 5) {
                if let p = model.refreshProgress {
                    // 显示进度：图标 + 进度文字
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.blue)
                    Text("\(p.done)/\(p.total)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.blue)
                } else if watchlistSync.isRunning {
                    // 显示加载中：图标 + 加载文字
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.blue)
                    Text("刷新中...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.blue)
                } else {
                    // 正常状态：图标 + 刷新文字
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.blue)
                    Text("刷新")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.blue)
                }
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color(.systemGray6))
            .cornerRadius(7)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(!watchlistTappable)
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// 清单标的自动更新状态（用于刷新按钮控制）
    @ObservedObject private var watchlistSync = WatchlistSyncManager.shared

    /// 刷新按钮可点条件：已启用且当前不在执行中
    private var watchlistTappable: Bool {
        syncConfig.enabled && !watchlistSync.isRunning
    }

    /// 同步配置（用于判断是否启用）
    @ObservedObject private var syncConfig = TdxSyncConfig.shared

    /// 工具条胶囊按钮（文字 + 图标）：外观 28pt，命中区纵向补到 44pt
    private func toolButton(_ title: String, icon: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(active ? .white : .blue)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(active ? Color.blue : Color(.systemGray6))
            .cornerRadius(7)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 紧凑态纯图标工具按钮（44×44 命中区，与 C 档顶栏图标按钮同款）：
    /// 文字标签收起只留图标，宽度紧张时省给分组名
    private func iconToolButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16))
                .foregroundColor(.blue)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 公式分组的「刷新选股」：刷新中显示 done/total 进度
    /// （fixedSize：紧凑态进度文案变宽时按钮整体外扩，不被容器压扁截断）
    @ViewBuilder
    private func formulaRefreshButton(group: FavoritesGroup) -> some View {
        Button {
            model.refreshFormulaGroup(id: group.id)
        } label: {
            Group {
                if let p = model.refreshProgress, p.groupID == group.id {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.7)
                        Text("\(p.done)/\(p.total)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(Color(.systemGray6))
                    .cornerRadius(7)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                        Text("刷新选股").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.blue)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(Color(.systemGray6))
                    .cornerRadius(7)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: - 分组行 / 底部入口（常驻侧栏与紧凑抽屉共用）

/// 分组行：图标 + 名称 + 公式组行尾刷新（刷新中显示进度）+ 数量。
/// 纯视觉行（不带点击手势）：常驻侧栏与紧凑抽屉各自挂点击——侧栏直切分组，
/// 抽屉经 SidebarDrawer 统一「收起后回调」，两边样式与交互保持同一份
private struct FavoritesGroupRow: View {
    @ObservedObject var model: FavoritesPageModel
    let group: FavoritesGroup
    /// 是否当前选中分组（选中态蓝字 + 浅蓝底）
    let active: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: iconName)
                .font(.system(size: 13))
                .foregroundColor(active ? .blue : .secondary)
                .frame(width: 24, height: 24)
            Text(group.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if group.kind == .formula {
                formulaRefreshButton
            }
            Text("\(model.countOfGroup(group))")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(active ? .blue : .secondary)
        }
        .foregroundColor(active ? .blue : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(active ? Color.blue.opacity(0.12) : Color.clear))
    }

    /// 分组图标：「全部」用托盘，自定义组用文件夹，公式组用函数符
    private var iconName: String {
        if group.id == model.fav.allGroup.id { return "tray.full.fill" }
        return group.kind == .manual ? "folder.fill" : "function"
    }

    /// 公式分组行尾刷新按钮：刷新中显示 done/total，其余时间显示刷新图标
    /// （Button 优先于抽屉外层 onTapGesture：行内刷新不会误触选中 / 收起）
    private var formulaRefreshButton: some View {
        Button {
            model.refreshFormulaGroup(id: group.id)
        } label: {
            Group {
                if let p = model.refreshProgress, p.groupID == group.id {
                    Text("\(p.done)/\(p.total)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(.blue)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 底部固定入口（常驻侧栏与紧凑抽屉共用）：新建分组 / 管理分组
private struct FavoritesGroupFooterButtons: View {
    @ObservedObject var model: FavoritesPageModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                footerButton("新建分组", icon: "plus") { model.showAddSheet = true }
                footerButton("管理分组", icon: "slider.horizontal.3") { model.showManageSheet = true }
            }
            .padding(8)
            .background(Color(.secondarySystemBackground))
        }
    }

    private func footerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.blue)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.separator), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 分组侧栏（B 档 regular 形态）

/// 常驻分组侧栏：顶部「自选」标题 + 「分组」小标题，分组行整行可点切换，
/// 公式分组行尾带刷新按钮（刷新中显示进度），底部固定「新建分组 / 管理分组」。
/// 行与底部入口和紧凑抽屉共用同一份组件（FavoritesGroupRow / FavoritesGroupFooterButtons），
/// 保证两种形态交互一致
struct FavoritesGroupSidebar: View {
    @ObservedObject var model: FavoritesPageModel

    /// 侧栏宽度（容器据此写入 model.tableWidthInset 修正表格横向滚动上限；
    /// 紧凑宽下侧栏折叠为抽屉，容器写入 0）
    static let width: CGFloat = 216

    var body: some View {
        VStack(spacing: 0) {
            // 侧栏标题：页标题「自选」自带无障碍标识（B 档不用 FavoritesToolbar，标识在这里提供）
            HStack(spacing: 8) {
                Text("自选")
                    .font(.system(size: 18, weight: .bold))
                    .accessibilityIdentifier("favorites.title")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            Text("分组")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 5)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.tabs) { g in
                        FavoritesGroupRow(model: model, group: g, active: g.id == model.currentGroup.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if model.fav.selectedGroupID != g.id { model.fav.selectedGroupID = g.id }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            FavoritesGroupFooterButtons(model: model)
        }
        .frame(width: Self.width)
        .background(Color(.secondarySystemBackground))
    }
}

#Preview {
    FavoritesLayoutBView(model: FavoritesPageModel())
}

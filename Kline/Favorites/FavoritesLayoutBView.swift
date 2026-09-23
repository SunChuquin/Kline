//
//  FavoritesLayoutBView.swift
//  Kline
//
//  自选页 B 档布局：分组侧栏 + 表格工作区。
//  左侧 216pt 常驻分组侧栏（一行直达切换分组 / 公式分组行内刷新 / 底部新建与管理），
//  右侧工作区 = 分组标题 + 工具条 + 共享表格主体（能力与 A 档一致）。
//  与 A/C/D 同源：同一份 FavoritesPageModel 与 FavoritesTableBody，
//  切布局不丢失当前分组、排序、筛选（都挂在 model / 共享 Store 上）。
//

import SwiftUI

struct FavoritesLayoutBView: View {
    @ObservedObject var model: FavoritesPageModel

    var body: some View {
        HStack(spacing: 0) {
            FavoritesGroupSidebar(model: model)
            // 侧栏与工作区之间的 1pt 分隔线
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1)
            workspace
        }
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

    /// 一行标题（当前分组名 + N 只）+ 工具条（表头设置 / 编辑 / 公式分组刷新选股）
    private var workspaceHeader: some View {
        HStack(spacing: 10) {
            Text(model.currentGroup.name)
                .font(.system(size: 16, weight: .bold))
                .lineLimit(1)
            Text("\(model.currentItems.count) 只")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer(minLength: 8)
            // 刷新监控标的列表（全局刷新按钮）
            refreshButton
            // 搜索按钮
            toolButton("搜索", icon: "magnifyingglass") {
                model.homeSearchActive = true
            }
            if model.currentGroup.kind == .formula {
                formulaRefreshButton(group: model.currentGroup)
            }
            toolButton("表头设置", icon: "slider.horizontal.3") {
                model.showColumnPanel = true
            }
            // 编辑态开关：与 A/C/D 档同一按钮（文案「编辑」→「完成」，退出时清空多选）
            FavoritesEditToggleButton(model: model)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Color(.systemBackground))
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

    /// 公式分组的「刷新选股」：刷新中显示 done/total 进度
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
    }
}

// MARK: - 分组侧栏（B 档）

/// 常驻分组侧栏：顶部「自选」标题 + 「分组」小标题，分组行整行可点切换，
/// 公式分组行尾带刷新按钮（刷新中显示进度），底部固定「新建分组 / 管理分组」。
struct FavoritesGroupSidebar: View {
    @ObservedObject var model: FavoritesPageModel

    /// 侧栏宽度（容器据此写入 model.tableWidthInset 修正表格横向滚动上限）
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
                        groupRow(g)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Divider()
            footerButtons
        }
        .frame(width: Self.width)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: 分组行

    private func groupRow(_ g: FavoritesGroup) -> some View {
        let active = g.id == model.currentGroup.id
        return HStack(spacing: 9) {
            Image(systemName: iconName(g))
                .font(.system(size: 13))
                .foregroundColor(active ? .blue : .secondary)
                .frame(width: 24, height: 24)
            Text(g.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if g.kind == .formula {
                formulaRowRefreshButton(g)
            }
            Text("\(model.countOfGroup(g))")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(active ? .blue : .secondary)
        }
        .foregroundColor(active ? .blue : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(active ? Color.blue.opacity(0.12) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if model.fav.selectedGroupID != g.id { model.fav.selectedGroupID = g.id }
        }
    }

    /// 分组图标：「全部」用托盘，自定义组用文件夹，公式组用函数符
    private func iconName(_ g: FavoritesGroup) -> String {
        if g.id == model.fav.allGroup.id { return "tray.full.fill" }
        return g.kind == .manual ? "folder.fill" : "function"
    }

    /// 公式分组行尾刷新按钮：刷新中显示 done/total，其余时间显示刷新图标
    private func formulaRowRefreshButton(_ g: FavoritesGroup) -> some View {
        Button {
            model.refreshFormulaGroup(id: g.id)
        } label: {
            Group {
                if let p = model.refreshProgress, p.groupID == g.id {
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

    // MARK: 底部固定按钮

    private var footerButtons: some View {
        HStack(spacing: 6) {
            footerButton("新建分组", icon: "plus") { model.showAddSheet = true }
            footerButton("管理分组", icon: "slider.horizontal.3") { model.showManageSheet = true }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
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

#Preview {
    FavoritesLayoutBView(model: FavoritesPageModel())
}
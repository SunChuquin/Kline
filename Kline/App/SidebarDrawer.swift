//
//  SidebarDrawer.swift
//  Kline
//
//  通用侧栏抽屉组件：窄屏（紧凑宽 <600）下把「常驻侧栏」收纳为下拉抽屉（用户选定交互）。
//  为什么自绘而不用系统 .sheet：sheet 是模态呈现层（盖 tab 栏、自带转场与手势），
//  侧栏收纳只需要页面内容区的轻量下拉——遮罩范围、锚点位置由调用方 overlay 挂载点决定，
//  各页面既有导航语义（底部 tab 栏 / 返回手势）完全不变。
//  首个使用方：自选 B（分组侧栏）；行情 B（分类侧栏）、模拟 A（账户侧栏）复用同一组件与交互。
//
//  形态：半透明遮罩（点击关闭）+ 圆角面板（可选小标题 + 可滚动选项列表 + 可选底部操作区），
//  面板停靠侧缘（默认左缘滑出，与常驻侧栏同侧）、锚定顶部，easeInOut 0.2s 滑入/滑出；
//  点选任一选项自动收起。iOS 15 兼容：.animation(_:value:) 为 15+ API，
//  不使用 iOS 17 才有的双参 onChange 重载。
//

import SwiftUI
import UIKit

// MARK: - 面板停靠侧

/// 面板停靠侧：leading 从左缘滑出（侧栏类页面默认形态，与常驻侧栏位置一致）
enum SidebarDrawerEdge {
    case leading
    case trailing
}

// MARK: - 侧栏抽屉

/// 通用侧栏抽屉（数据驱动的下拉选择面板）。
/// - `Selection: Hashable`：选项值（模型结构体 / 枚举 / 标量皆可），同时驱动 ForEach 渲染与选中判定
/// - `rowContent`：行视图闭包（入参 = 选项值 + 是否选中）；行内可自带次级按钮（如公式分组
///   行内刷新），Button 优先于本组件外层 onTapGesture，不会误触「选中并收起」
/// - `footer`：面板底部操作区（如「新建分组 / 管理分组」），默认空
/// - 用法：调用方自备锚定按钮（图标 + 当前选中名）toggle `isPresented`；本组件以 overlay
///   挂在页面内容区，遮罩范围 = 该内容区（挂在 header 下方时，面板即从 header 下缘
///   下拉展开，锚点按钮不被遮罩盖住、再点一次即收起）
struct SidebarDrawer<Selection: Hashable, RowContent: View, Footer: View>: View {
    /// 抽屉开关（true = 展开）；点遮罩 / 选中选项后组件内部置 false
    @Binding var isPresented: Bool
    /// 面板小标题（如「分组」，沿用侧栏小标题样式）；nil = 不渲染标题行
    var title: String? = nil
    /// 选项列表
    let options: [Selection]
    /// 当前选中项（行高亮判定）
    let selection: Selection
    /// 选中回调：点行触发（组件已先行收起抽屉再回调）
    let onSelect: (Selection) -> Void
    /// 行视图：(选项, 是否选中) → 行
    let rowContent: (Selection, _ isActive: Bool) -> RowContent
    /// 面板停靠侧：默认 leading（左缘滑出，与常驻侧栏同侧）
    var edge: SidebarDrawerEdge = .leading
    /// 面板底部操作区（默认空）
    let footer: () -> Footer

    init(isPresented: Binding<Bool>,
         title: String? = nil,
         options: [Selection],
         selection: Selection,
         onSelect: @escaping (Selection) -> Void,
         @ViewBuilder rowContent: @escaping (Selection, _ isActive: Bool) -> RowContent,
         edge: SidebarDrawerEdge = .leading,
         @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self._isPresented = isPresented
        self.title = title
        self.options = options
        self.selection = selection
        self.onSelect = onSelect
        self.rowContent = rowContent
        self.edge = edge
        self.footer = footer
    }

    /// 面板最大宽 ~280：既放得下「图标 + 名称 + 数量」行，又不会在 414pt 窄屏盖过
    /// 工作区；极窄屏（如滑 Over 320）再收窄，两侧各留 16pt 边距
    private var panelWidth: CGFloat {
        min(280, UIScreen.main.bounds.width - 32)
    }

    /// 面板最大高：70% 屏高，行多时面板内滚动、不遮满整页
    private var maxPanelHeight: CGFloat {
        UIScreen.main.bounds.height * 0.7
    }

    var body: some View {
        ZStack(alignment: edge == .leading ? .topLeading : .topTrailing) {
            // 遮罩：拦截内容区误触，点击关闭（浓度与 FavoritesOverlayCard 同款 0.25 黑）
            Color.black.opacity(0.25)
                .opacity(isPresented ? 1 : 0)
                .onTapGesture { isPresented = false }
            panel
                .opacity(isPresented ? 1 : 0)
                // 滑入方向：从停靠侧滑入（收起时滑回停靠侧外）
                .offset(x: isPresented ? 0 : hiddenSlideX)
        }
        // 收起时整体退出命中测试：淡出残影不挡底层内容交互
        .allowsHitTesting(isPresented)
        .animation(.easeInOut(duration: 0.2), value: isPresented)
    }

    /// 收起态的横向滑出量（藏到停靠侧外）
    private var hiddenSlideX: CGFloat {
        edge == .leading ? -(panelWidth + 32) : panelWidth + 32
    }

    // MARK: 面板

    /// 面板本体：可选小标题 + 滚动选项列表 + 底部操作区
    private var panel: some View {
        VStack(spacing: 0) {
            if let title = title {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 5)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(options, id: \.self) { option in
                        let isActive = option == selection
                        rowContent(option, isActive)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // 先收起再回调：选中即关抽屉（下拉选择的常见预期）
                                isPresented = false
                                onSelect(option)
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 3)
                .padding(.bottom, 8)
            }
            footer()
        }
        // 定宽（侧栏语义的稳定列宽）+ 高度封顶（内容少时贴合、多时面板内滚动）
        .frame(width: panelWidth)
        .frame(maxHeight: maxPanelHeight)
        .background(Color(.systemBackground))
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.18), radius: 16, y: 4)
        // 停靠侧与顶部各留 8pt：面板从锚点下方浮出，不贴边
        .padding(.top, 8)
        .padding(edge == .leading ? .leading : .trailing, 8)
    }
}

// MARK: - 预览（演示：分组抽屉基本形态）

/// 演示页：模拟「header 锚点按钮 + 内容区抽屉」的标准挂法
private struct SidebarDrawerDemoPage: View {
    @State private var isPresented = false
    @State private var selection = "全部"
    private let groups: [(name: String, count: Int)] = [
        ("全部", 36), ("科技龙头", 12), ("医药生物", 8), ("消费白马", 6),
        ("新能源车", 5), ("红利低波", 4), ("公式·放量突破", 9), ("公式·低位金叉", 7)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 模拟页面 header：锚点按钮（图标 + 当前选中名 + 下拉箭头）
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(selection).font(.system(size: 15, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { isPresented.toggle() }
                Spacer()
                Text("演示页面").font(.system(size: 12)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            Divider()
            // 模拟页面内容区：抽屉 overlay 挂这里 → 面板从 header 下缘下拉展开
            Color(.secondarySystemBackground)
                .overlay {
                    Text("页面内容").foregroundColor(.secondary)
                }
                .overlay {
                    SidebarDrawer(
                        isPresented: $isPresented,
                        title: "分组",
                        options: groups.map(\.name),
                        selection: selection,
                        onSelect: { selection = $0 },
                        rowContent: { name, active in
                            HStack(spacing: 9) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(active ? .blue : .secondary)
                                    .frame(width: 24, height: 24)
                                Text(name).font(.system(size: 13, weight: .semibold))
                                Spacer(minLength: 4)
                                Text("\(groups.first(where: { $0.name == name })?.count ?? 0)")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundColor(active ? .blue : .secondary)
                            }
                            .foregroundColor(active ? .blue : Color.primary)
                            .padding(.horizontal, 10)
                            .frame(height: 44)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 9)
                                .fill(active ? Color.blue.opacity(0.12) : Color.clear))
                        },
                        footer: {
                            HStack(spacing: 6) {
                                Text("新建分组").font(.system(size: 12)).foregroundColor(.blue)
                                    .frame(maxWidth: .infinity)
                                Text("管理分组").font(.system(size: 12)).foregroundColor(.blue)
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(8)
                            .background(Color(.secondarySystemBackground))
                        }
                    )
                }
        }
    }
}

#Preview("侧栏抽屉（左缘滑出下拉面板）") {
    SidebarDrawerDemoPage()
}

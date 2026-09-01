//
//  KlineDetailView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/8/5.
//

import SwiftUI
import Combine
import UIKit

/// 顶部第一行工具栏高度（供可拖分隔线覆盖层的起始偏移对齐）
struct TopBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 双联动分界线：独立持有拖动状态。
/// 拖动中只更新本视图自身的 @State（只重画这条分隔线，实时跟随手指），
/// 不触碰左右 K 线图宽度，因此不影响图表手势、也不会因拖动反复重渲染重型图表；
/// 松手才通过 onCommit 把最终比例一次性写回 config（图表随之调整）。
struct DualSplitDivider: View {
    /// 左右总宽
    let totalWidth: CGFloat
    /// 当前已提交的该分隔线位置（手势开始基准）
    let committed: Double
    /// 该分隔线允许的最小/最大位置（由相邻分隔线约束，避免越界翻转）
    let minLimit: Double
    let maxLimit: Double
    /// 松手回调：把最终位置写回持久状态
    let onCommit: (Double) -> Void

    /// 分界线宽度
    private let handleWidth: CGFloat = 14
    /// 拖动中实时显示的位置（持久提交前的临时值）；非拖动时保持 committed
    @State private var dragRatio: Double?

    var body: some View {
        let shownRatio = dragRatio ?? committed
        GeometryReader { geo in
            Rectangle()
                .fill(Color.gray.opacity(0.35))
                .overlay(
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundColor(.gray.opacity(0.7))
                )
                .frame(width: handleWidth)
                .position(x: totalWidth * CGFloat(shownRatio), y: geo.size.height / 2)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let usable = max(totalWidth - handleWidth, 1.0)
                            let delta = Double(value.translation.width / usable)
                            dragRatio = clamp(committed + delta, minLimit, maxLimit)
                        }
                        .onEnded { value in
                            let usable = max(totalWidth - handleWidth, 1.0)
                            let delta = Double(value.translation.width / usable)
                            onCommit(clamp(committed + delta, minLimit, maxLimit))
                            dragRatio = nil
                        }
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
}

/// 全局详情页路由：在根视图以全屏 overlay 呈现 K 线详情，避免 fullScreenCover 偶发白屏
final class DetailRouter: ObservableObject {
    static let shared = DetailRouter()
    @Published var item: MetaItem? = nil
    /// 打开详情时的候选标的列表与当前位置（用于第二副图左右滑动切换标的）
    @Published var navItems: [MetaItem] = []
    @Published var navIndex: Int = 0

    /// 从列表打开：记录候选列表与当前位置，便于第二副图左右滑动切换标的
    func open(_ item: MetaItem, in list: [MetaItem]) {
        navItems = list
        navIndex = list.firstIndex(where: { $0.id == item.id }) ?? 0
        self.item = item
    }

    /// 切换标的：dir = -1 上一个 / +1 下一个；越界返回 nil（不切换）
    func neighbor(_ dir: Int) -> MetaItem? {
        let i = navIndex + dir
        guard i >= 0, i < navItems.count else { return nil }
        navIndex = i
        let next = navItems[i]
        item = next
        return next
    }

    /// 查询某方向是否可切换（-1 上一个 / +1 下一个），用于副图滑动提示
    func canSwitch(_ dir: Int) -> Bool {
        let i = navIndex + dir
        return i >= 0 && i < navItems.count
    }
}

/// 双视图联动同步对象：左右两个 K 线图（左日线/右周线）通过它按日期（YYYYMMDD 整数）同步十字光标
final class DualLinkSync: ObservableObject {
    @Published var cursorDate: Int? = nil
    /// 最近一次 cursorDate 是否由「右侧视图用户直接操作」产生。
    /// 左视图据此决定是否把联动K线居中显示；左视图自身拖动产生的回声不算
    var lastCursorFromRightUser = false
}

/// 信息栏「主图指标名称按钮」桥接：图表把按钮标题（如"日线: MA"）与点击行为
/// （打开主图指标选择面板）同步给外层，外层在信息栏最左侧渲染按钮，
/// 无需了解图表内部状态即可保证两处显示与交互一致
final class MainLegendPortal: ObservableObject {
    /// 按钮标题；图表未就绪/加载中时为空串
    @Published var title: String = ""
    /// 点击行为（打开主图指标选择面板）；由图表同步注入
    var onTap: (() -> Void)? = nil
}

struct KlineDetailView: View {
    @ObservedObject private var databaseManager = DatabaseManager.shared
    @ObservedObject private var detailRouter = DetailRouter.shared

    /// 当前展示的标的（第二副图左右滑动时可在候选列表中切换）
    @State private var item: MetaItem
    var onClose: () -> Void
    @State private var showSettings = false
    /// 自定义指标公式编辑器是否打开（由 K 线图内部触发，此处负责隐藏顶部栏实现真全屏）
    @State private var showCustomEditor = false
    /// 系统指标公式编辑器是否打开（同样需隐藏顶部栏实现真全屏）
    @State private var showSystemEditor = false
    @ObservedObject private var config = ChartConfigStore.shared
    @ObservedObject private var linkedStore = LinkedViewStore.shared
    @State private var dailySeries: ChartSeries? = nil
    @State private var weeklySeries: ChartSeries? = nil
    @State private var monthlySeries: ChartSeries? = nil
    @State private var quarterlySeries: ChartSeries? = nil
    @State private var yearlySeries: ChartSeries? = nil
    @State private var isLoading = true
    /// 📌 固定光标模式开关（高亮表示已开启）
    @State private var pinEnabled = false
    /// 图表当前是否已有任意十字光标（控制 📌 按钮是否可开启）
    @State private var chartHasCursor = false
    /// 单视图 / 双联动模式：双联动时左右对半分，左日线、右周线，十字光标按日期联动
    @State private var dualLink = false
    /// 「边」边线调节模式：开启后才显示可拖动的 DualSplitDivider 分界线，且禁止十字光标
    @State private var edgeAdjust = false
    /// 重置当前标的联动视图配置的确认弹窗
    @State private var showResetLinkedConfirm = false
    /// 双视图联动同步（日线/周线图共享）
    @State private var linkSync = DualLinkSync()
    /// 顶部第一行工具栏实测高度（用于信息栏起始位置对齐可拖覆盖层）
    @State private var measuredTopBarHeight: CGFloat = 0
    /// 单视图：信息栏最左侧主图指标按钮的桥接（图表同步标题/点击行为）
    @StateObject private var mainLegendPortal = MainLegendPortal()
    /// 联动：各视图信息栏格子的按钮桥接（按视图 index 取用；最多支持 4 视图）
    @State private var tilePortals: [MainLegendPortal] = (0..<4).map { _ in MainLegendPortal() }

    init(item: MetaItem, onClose: @escaping () -> Void) {
        self._item = State(initialValue: item)
        self.onClose = onClose
    }

    private var currentSeries: ChartSeries? {
        switch config.selectedPeriod {
        case .daily: return dailySeries
        case .weekly: return weeklySeries
        case .monthly: return monthlySeries
        case .quarterly: return quarterlySeries
        case .yearly: return yearlySeries
        }
    }

    /// 当前标的的联动视图数量（用于设置页下拉勾选；无记录时默认 2 视图）。
    /// 传 nameHint：首次初始化/修复旧数据时，把主标的 name/code/type 同步写入 2 个默认视图
    private var linkedViewCount: LinkedViewCount {
        let hint = (name: item.name, code: item.code, type: item.type)
        return LinkedViewCount(rawValue: linkedStore.configs(for: item.id, nameHint: hint).count) ?? .two
    }

    /// 当前标的的联动视图配置（用于信息栏列出各视图代码+周期）
    private var linkedViews: [LinkedViewConfig] {
        let hint = (name: item.name, code: item.code, type: item.type)
        return linkedStore.configs(for: item.id, nameHint: hint)
    }

    /// 信息栏顶部相对整页顶部的偏移 = 顶部2留白 + 工具栏行实测高 + 分隔线0.5
    private var infoBarTopOffset: CGFloat {
        (measuredTopBarHeight > 0 ? measuredTopBarHeight : 34) + 2 + 0.5
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    // 自定义/系统指标公式编辑器（真全屏）打开时隐藏顶部栏
                    if !showCustomEditor && !showSystemEditor {
                        // 顶部留白压缩为小固定值，减少状态栏区域的空白
                        Color.clear
                            .frame(height: 2)

                        // 第一行：工具栏
                        toolbarRow
                        // 工具栏与信息栏之间的分界线
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 0.5)
                        // 第二行：信息栏（传整屏宽度，避免内嵌 GeometryReader 导致的高度/溢出问题）
                        infoBarRow(width: geometry.size.width)
                    }

                    // 图表区域：始终占满剩余空间，内部显示加载/空/图表
                    chartArea
                }
                .frame(maxHeight: .infinity)
                .background(Color.white.ignoresSafeArea())

                // 「边」开启时：可拖分隔线覆盖层从信息栏顶部开始
                // （工具栏已独立，故固定偏移 = 顶部2留白 + 工具栏行实测高 + 分隔线0.5）
                if dualLink && edgeAdjust {
                    // 顺序很关键：必须先把覆盖层裁到「信息栏顶→屏幕底」的高度，再 offset 下移。
                    // 若先 offset 再 frame，offset 不改变布局尺寸，frame 的默认居中对齐会把
                    // 整屏高的内容在裁小后的容器里重新居中，实际起点变成 offset/2
                    // （真机曾表现为分隔线从工具栏中间开始画）
                    linkedDividerOverlay(width: geometry.size.width,
                                         height: max(0, geometry.size.height - infoBarTopOffset))
                        .offset(y: infoBarTopOffset)
                }
            }
            .overlay {
                if showSettings {
                    settingsOverlay(geometry: geometry)
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .onPreferenceChange(TopBarHeightPreferenceKey.self) { h in
                if h > 0 { measuredTopBarHeight = h }
            }
        }
        .onAppear {
            if databaseManager.isLoaded {
                loadData()
            } else {
                // 数据库还没就绪，等就绪后再查
                isLoading = true
            }
        }
        .onChange(of: databaseManager.isLoaded) { loaded in
            if loaded && isLoading {
                loadData()
            }
        }
    }

    /// 整页（信息栏+主图）可拖分隔线覆盖层：每条分隔线独立实时拖拽。
    /// 高度由调用方传入（已裁掉顶部工具栏区域），本视图只负责在给定区域内排布分隔线
    private func linkedDividerOverlay(width: CGFloat, height: CGFloat) -> some View {
        let totalWidth = width
        let views = linkedViews
        let count = views.count
        let dividers = config.dualDividers(for: count)
        let bounds = [0.0] + dividers + [1.0]
        return ZStack(alignment: .topLeading) {
            ForEach(dividers.indices, id: \.self) { i in
                DualSplitDivider(totalWidth: totalWidth,
                                 committed: dividers[i],
                                 minLimit: i == 0 ? 0.12 : (bounds[i] + 0.06),
                                 maxLimit: i == dividers.count - 1 ? 0.88 : (bounds[i + 2] - 0.06),
                                 onCommit: { newPos in
                                     updateDivider(at: i, count: count, to: newPos)
                                 })
            }
        }
        .frame(width: totalWidth, height: height)
    }

    /// 顶部第一行：工具栏（返回 + 功能按钮）
    /// 联动时整体 + 内部所有按钮高度压缩到 22pt（与信息栏一致），单视图保持原 34pt 尺寸
    private var toolbarRow: some View {
        let compact = dualLink               // 联动：压缩到 22pt，和信息栏等高
        let btnH:    CGFloat = compact ? 22 : 28
        let vPad:    CGFloat = compact ? 0  : 3
        let hPad:    CGFloat = compact ? 6  : 8
        let gap:     CGFloat = compact ? 4  : 6
        let textSize:CGFloat = compact ? 10 : 12
        let iconSize:CGFloat = compact ? 12 : 15
        let backSize:CGFloat = compact ? 24 : 30
        let smallW:  CGFloat = compact ? 24 : 28   // 多/空
        let normW:   CGFloat = compact ? 26 : 32   // 边、📌、联、⚙
        let corner:  CGFloat = compact ? 4  : 6

        return HStack(spacing: gap) {
            // 返回
            Button(action: {
                onClose()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: compact ? 13 : 16, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: backSize, height: btnH)
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(corner)
            }

            Spacer()

            // 📌 / 边：无十字光标时显示「边」按钮（开启边线调节并禁止光标）；有光标时显示 📌 固定光标
            if dualLink && !chartHasCursor {
                Button(action: {
                    edgeAdjust.toggle()
                }) {
                    Text("边")
                        .font(.system(size: textSize, weight: .bold))
                        .foregroundColor(edgeAdjust ? .blue : .gray)
                        .frame(width: normW, height: btnH)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(edgeAdjust ? "关闭边线调节" : "开启边线调节")
            } else {
                Button(action: {
                    if pinEnabled {
                        pinEnabled = false
                    } else if chartHasCursor {
                        pinEnabled = true
                    }
                }) {
                    Image(systemName: pinEnabled ? "pin.fill" : "pin")
                        .font(.system(size: iconSize))
                        .foregroundColor(pinEnabled ? .blue : .gray)
                        .frame(width: normW, height: btnH)
                        .contentShape(Rectangle())
                }
                .disabled(!pinEnabled && !chartHasCursor)
            }

            // 单视图 / 双联动
            Button(action: {
                let wasOn = dualLink
                withAnimation { dualLink.toggle() }
                if wasOn {
                    edgeAdjust = false
                    pinEnabled = false
                }
            }) {
                Text("联")
                    .font(.system(size: textSize, weight: .bold))
                    .foregroundColor(dualLink ? .blue : .gray)
                    .frame(width: normW, height: btnH)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(dualLink ? "切换为单视图" : "切换为双联动")

            // 多/空 全局镜像
            Button(action: {
                config.mainMirrored.toggle()
            }) {
                Text(config.mainMirrored ? "空" : "多")
                    .font(.system(size: textSize, weight: .bold))
                    .foregroundColor(config.mainMirrored ? .blue : .gray)
                    .frame(width: smallW, height: btnH)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(config.mainMirrored ? "关闭空头镜像" : "开启空头镜像")

            // K线设置
            Button(action: {
                withAnimation { showSettings = true }
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: iconSize))
                    .foregroundColor(.gray)
                    .frame(width: normW, height: btnH)
                    .contentShape(Rectangle())
            }
        }
        .padding(.leading, hPad)
        .padding(.trailing, hPad)
        .padding(.vertical, vPad)
        .background(Color.white)
        // 测量工具栏行高度（供 infoBarTopOffset 对齐）
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TopBarHeightPreferenceKey.self,
                                       value: proxy.size.height)
            }
        )
    }

    /// 顶部第二行：信息栏（联动各视图标的代码+周期 / 单图：名称代码类型）
    /// width：整屏宽度（由最外层 GeometryReader 传入，避免在此函数内嵌 GeometryReader 导致布局溢出/错位）
    private func infoBarRow(width: CGFloat) -> some View {
        Group {
            if dualLink {
                // 联动：HStack(spacing:0) 按顺序排布各视图格子，每格宽度 = (right - left) 比例 × 整屏宽
                // 格子间竖线通过 overlay 在 exact x 位置绘制，与主图 dualSplitPositions 严格对齐
                infoLinkedRow(width: width)
                    .frame(height: 22)
            } else {
                HStack(spacing: 6) {
                    // 主图指标名称按钮（从图表内指标栏挪到信息栏最左侧）
                    IndicatorNameButton(title: mainLegendPortal.title,
                                        onTap: { mainLegendPortal.onTap?() })
                    Text(item.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.black)
                        .lineLimit(1)
                    Text(item.displayCode)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                    Spacer()
                    Text(item.type)
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            }
        }
        .frame(width: width, height: dualLink ? 22 : nil, alignment: .leading)
        .background(Color.white)
        .overlay(
            // 信息栏与主图之间的分界线
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    /// 联动信息栏：按视图数分格（与主图分隔线位置对齐，2/3/4视图均跟随 dualSplitPositions）
    private func infoLinkedRow(width: CGFloat) -> some View {
        let views = linkedViews
        let count = max(views.count, 1)
        let dividers = config.dualDividers(for: count)
        let bounds = [0.0] + dividers + [1.0]
        return HStack(spacing: 0) {
            ForEach(views.indices, id: \.self) { i in
                let cellW = (bounds[i + 1] - bounds[i]) * Double(width)
                LinkedInfoCell(portal: tilePortal(at: i),
                               name: views[i].name,
                               code: views[i].displayCode)
                    .frame(width: CGFloat(cellW), height: 22, alignment: .leading)
            }
        }
        .frame(width: width, height: 22, alignment: .leading)
        // 格子间竖线：在 overlay 里按 bounds 比例精确定位 x，与主图分隔线一致
        .overlay(alignment: .topLeading) {
            if count >= 2 {
                ForEach(1..<count, id: \.self) { i in
                    let x = CGFloat(bounds[i]) * width
                    Rectangle()
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: 1, height: 22)
                        .position(x: x, y: 11)
                }
            }
        }
        .clipped()
    }

    /// 联动第 index 个视图的信息栏按钮桥接（越界兜底取最后一个，避免偶发崩溃）
    private func tilePortal(at index: Int) -> MainLegendPortal {
        tilePortals[min(max(index, 0), tilePortals.count - 1)]
    }

    private var chartArea: some View {
        ZStack {
            Color.white

            Group {
                if isLoading {
                    loadingView
                } else if dualLink {
                    dualLinkArea()
                } else if currentSeries == nil {
                    emptyDataView
                } else if let s = currentSeries {
                    chartView(series: s, period: config.selectedPeriod, linked: false,
                              mainLegendPortal: mainLegendPortal)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 双联动：左日线、右周线，十字光标按日期联动。
    /// 左右各用独立的副图模型（isolatedSubs），避免共享副图模型被不同数据长度的曲线互相覆盖。
    /// 中间分界线可分条按住拖动，调整对应两视图的宽度；占比持久记忆（config.dualSplitPositions）。
    /// 分界线是独立子视图，拖动时只重画分隔线本身（实时跟随、不重渲染左右图表，也不干扰图表手势），
    /// 松手才一次性把最终比例写入 config，图表随之调整。
    /// 双联动：按 LinkedViewStore 的配置横向排布 2/3/4 个视图（每个视图独立标的+周期）。
    /// 视图之间以细分界线分隔；副图一切周期、副图二切标的（由 LinkedKlineTile 内部接管）。
    /// 2 个视图时「边」开启可拖动分界线调节左视图占比（保持既有功能）；3/4 视图等宽排列、仅显示划分界线。
    private func dualLinkArea() -> some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let hint = (name: item.name, code: item.code, type: item.type)
            let views = linkedStore.configs(for: item.id, nameHint: hint)
            let count = views.count
            // 各分隔线位置（归一化）；2视图=[x]，3=[x1,x2]，4=[x1,x2,x3]
            let dividers = config.dualDividers(for: count)
            // 各视图左边界 = [0, d0, d1, ..., 1]
            let bounds = [0.0] + dividers + [1.0]
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(views.enumerated()), id: \.element.index) { i, v in
                        let left = CGFloat(bounds[i]) * totalWidth
                        let right = CGFloat(bounds[i + 1]) * totalWidth
                        tile(v)
                            .frame(width: right - left, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 视图之间的竖直分隔线（样式一致）
                ForEach(dividers.indices, id: \.self) { i in
                    Rectangle()
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: 1, height: geo.size.height)
                        .position(x: totalWidth * CGFloat(dividers[i]), y: geo.size.height / 2)
                        .allowsHitTesting(false)
                }
                // 注：可拖分隔线覆盖层由全局 linkedDividerOverlay 提供（横贯信息栏+主图）
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 更新某视图数下第 i 条分隔线的位置，并写回持久化
    private func updateDivider(at index: Int, count: Int, to newPos: Double) {
        var dividers = config.dualDividers(for: count)
        guard index < dividers.count else { return }
        // 用相邻分隔线约束，避免越界翻转
        let lo = index == 0 ? 0.0 : (dividers[index - 1] + 0.02)
        let hi = index == dividers.count - 1 ? 1.0 : (dividers[index + 1] - 0.02)
        dividers[index] = min(hi, max(lo, newPos))
        config.dualSplitPositions = dividers
    }

    /// 单个联动视图块
    @ViewBuilder
    private func tile(_ v: LinkedViewConfig) -> some View {
        LinkedKlineTile(view: v,
                        ownerMetaID: item.id,
                        linkAutoCenter: v.index == 0,
                        suppressCrosshair: edgeAdjust,
                        mainLegendPortal: tilePortal(at: v.index),
                        showCustomEditor: $showCustomEditor,
                        showSystemEditor: $showSystemEditor,
                        onCursorChange: { has in
                            chartHasCursor = has
                        })
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .gray))
            Text("正在加载行情数据...")
                .font(.system(size: 13))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    /// 设置面板：底部 3/4 高度，点击顶部 1/4 区域关闭
    private func settingsOverlay(geometry: GeometryProxy) -> some View {
        ZStack(alignment: .bottom) {
            // 顶部非面板区域，点击关闭
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation { showSettings = false }
                }

            // 底部设置面板
            VStack(spacing: 0) {
                HStack {
                    Text("K线设置")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.black)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // 0. 行情周期（日线/周线）
                        settingsSectionTitle("行情周期")
                        Menu {
                            ForEach(KlinePeriod.allCases) { period in
                                Button {
                                    DebugLogger.shared.log("设置面板切换周期: \(period.rawValue)")
                                    withAnimation { config.selectedPeriod = period }
                                } label: {
                                    if config.selectedPeriod == period {
                                        Label(period.rawValue, systemImage: "checkmark")
                                    } else {
                                        Text(period.rawValue)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(config.selectedPeriod.rawValue)
                                    .font(.system(size: 15))
                                    .foregroundColor(.black)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.gray.opacity(0.12))
                            .cornerRadius(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)

                        // 联动视图数量（2/3/4）
                        settingsSectionTitle("联动视图数量")
                        Menu {
                            ForEach(LinkedViewCount.allCases) { count in
                                Button {
                                    let hint = (name: item.name, code: item.code, type: item.type)
                                    LinkedViewStore.shared.setViewCount(count, for: item.id, nameHint: hint)
                                } label: {
                                    if linkedViewCount == count {
                                        Label(count.label, systemImage: "checkmark")
                                    } else {
                                        Text(count.label)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(linkedViewCount.label)
                                    .font(.system(size: 15))
                                    .foregroundColor(.black)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.gray.opacity(0.12))
                            .cornerRadius(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)

                        // 重置当前标的联动视图配置（需确认）
                        Button(action: {
                            showResetLinkedConfirm = true
                        }) {
                            HStack {
                                Text("重置当前标的联动视图配置")
                                    .font(.system(size: 15))
                                    .foregroundColor(.red)
                                Spacer()
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 13))
                                    .foregroundColor(.red)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .confirmationDialog("重置当前标的的联动视图配置？", isPresented: $showResetLinkedConfirm,
                                            titleVisibility: .visible) {
                            Button("重置", role: .destructive) {
                                let hint = (name: item.name, code: item.code, type: item.type)
                                LinkedViewStore.shared.reset(for: item.id, nameHint: hint)
                            }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("将恢复为默认 2 个视图（左日线、右周线），且各视图标的/周期会被重置。")
                        }
                        .padding(.vertical, 2)

                        // 1. K线类型（下拉选项，压缩占位）
                        settingsSectionTitle("K线类型")
                        Menu {
                            ForEach(ChartStyle.allCases) { style in
                                Button {
                                    withAnimation { config.chartStyle = style }
                                } label: {
                                    if config.chartStyle == style {
                                        Label(style.rawValue, systemImage: "checkmark")
                                    } else {
                                        Text(style.rawValue)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(config.chartStyle.rawValue)
                                    .font(.system(size: 15))
                                    .foregroundColor(.black)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.gray.opacity(0.12))
                            .cornerRadius(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)

                        // 2. 区间统计
                        settingsSectionTitle("区间统计")
                        toggleRow(title: "显示区间统计", isOn: $config.displaySettings.showRangeStats) {
                            Text("在图表右上角显示可见区间的涨跌幅、高低、量额统计")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }

                        // 3. 图层显示
                        settingsSectionTitle("图层显示")
                        toggleRow(title: "跳空缺口", isOn: $config.displaySettings.showGap) {
                            Text("在 K 线之间标出跳空缺口区域")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        toggleRow(title: "缺口回补后消失", isOn: $config.displaySettings.gapDisappearAfterFill) {
                            Text("开启时缺口被回补后整体隐藏；关闭时仅截止到回补位置、保留形成到截止区域")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        toggleRow(title: "最新价线", isOn: $config.displaySettings.showLatestPriceLine) {
                            Text("在最新收盘价位置绘制虚线")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        toggleRow(title: "指标不挤压K线", isOn: $config.displaySettings.indicatorNotSqueezeKline) {
                            Text("开启时主图价格范围仅按K线计算，指标线超出部分被裁剪；关闭后指标线会撑大价格范围")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        toggleRow(title: "裸K", isOn: $config.showBareK) {
                            Text("开启后只显示K线、隐藏主图指标")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                    }
                }

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: geometry.size.height * 0.75)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func settingsSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.gray)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    private func toggleRow(title: String, isOn: Binding<Bool>, @ViewBuilder subtitle: () -> some View) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: isOn.animation()) {
                    Text(title)
                        .font(.system(size: 15))
                        .foregroundColor(.black)
                }
                .tint(.blue)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                subtitle()
                    .padding(.horizontal, 16)
            }
            .padding(.vertical, 2)
            Divider().padding(.leading, 16)
        }
    }

    private func chartView(series: ChartSeries, period: KlinePeriod, linked: Bool, isolated: Bool = false,
                           linkAutoCenter: Bool = false, suppressCrosshair: Bool = false,
                           mainLegendPortal: MainLegendPortal? = nil) -> some View {
        KlineChartView(series: series, chartStyle: $config.chartStyle, displaySettings: $config.displaySettings,
                       showCustomEditor: $showCustomEditor, showSystemEditor: $showSystemEditor, metaId: item.id, period: period,
                       isolatedSubs: isolated, linkAutoCenter: linkAutoCenter,
                       onPeriodSwitch: linked ? { _ in } : { newPeriod in
                           // 切换周期后图表重建，固定光标随之失效，重置 pin
                           DebugLogger.shared.log("图表滑动切换周期: \(newPeriod.rawValue)")
                           pinEnabled = false
                           withAnimation { config.selectedPeriod = newPeriod }
                       },
                       onPeriodPrefetched: { finished in
                           // 当前周期已全部算完：后台继续预计算其它未计算周期（不切换可见周期）
                           prefetchOtherPeriods(excluding: finished)
                       },
                       onSwitchItem: { dir in
                           // 第二副图左右滑动切换标的：dir = -1 上一个 / +1 下一个
                           if let next = detailRouter.neighbor(dir) {
                               pinEnabled = false
                               item = next
                               loadData()
                           }
                       },
                       canSwitchItem: { dir in
                           detailRouter.canSwitch(dir)
                       },
                       pinEnabled: $pinEnabled,
                       onHasCursorChange: { has in
                           chartHasCursor = has
                       },
                       suppressCrosshair: suppressCrosshair,
                       mainLegendPortal: mainLegendPortal,
                       linkSync: linked ? linkSync : nil)
            .id(series.sorted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDataView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundColor(.gray)

            Text("暂无K线数据")
                .foregroundColor(.gray)

            Text("\(item.name) (\(item.code))")
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
        .frame(maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .background(Color.white)
    }

    private func loadData() {
        // 数据库未就绪时先不查询，等待 isLoaded 触发
        guard databaseManager.isLoaded else {
            isLoading = true
            return
        }
        isLoading = true
        // 图表将重建，先清空信息栏按钮标题，避免短暂显示旧周期指标
        mainLegendPortal.title = ""

        // 后台串行加载并预计算指标（全量历史），避免阻塞主线程。
        // 月/季/年线表可能不存在，不存在时对应查询返回空、series 为 nil，仅加载日/周线
        DispatchQueue.global(qos: .userInitiated).async {
            let daily = databaseManager.fetchDailyData(metaId: item.id)
            let weekly = databaseManager.fetchWeeklyData(metaId: item.id)
            let monthly = databaseManager.fetchMonthlyData(metaId: item.id)
            let quarterly = databaseManager.fetchquarterlyData(metaId: item.id)
            let yearly = databaseManager.fetchYearlyData(metaId: item.id)

            DispatchQueue.main.async {
                self.dailySeries = daily.isEmpty ? nil : ChartSeries(data: daily)
                self.weeklySeries = weekly.isEmpty ? nil : ChartSeries(data: weekly)
                self.monthlySeries = monthly.isEmpty ? nil : ChartSeries(data: monthly)
                self.quarterlySeries = quarterly.isEmpty ? nil : ChartSeries(data: quarterly)
                self.yearlySeries = yearly.isEmpty ? nil : ChartSeries(data: yearly)
                self.isLoading = false
            }
        }
    }

    /// 当前周期已全部算完后，在后台继续预计算其它未计算周期：
    /// 结果写入 ChartCacheStore，用户切到该周期时由 K 线图直接从缓存恢复，无需等待。
    /// 只处理已加载出数据、且尚未标记预计算完成的周期；不切换可见周期。
    /// 注意：当前正在显示的周期由可见 K 线图自己分块预计算，后台只补「不可见」的周期，
    /// 避免后台提前把可见周期标记为完成、与可见视图的进行中计算产生竞态
    private func prefetchOtherPeriods(excluding finished: KlinePeriod) {
        let metaId = item.id
        let visible = config.selectedPeriod
        for period in KlinePeriod.allCases where period != finished && period != visible {
            let data: [KlineItem]?
            switch period {
            case .daily: data = dailySeries?.sorted
            case .weekly: data = weeklySeries?.sorted
            case .monthly: data = monthlySeries?.sorted
            case .quarterly: data = quarterlySeries?.sorted
            case .yearly: data = yearlySeries?.sorted
            }
            guard let data, !data.isEmpty else { continue }
            // 是否已预计算、配置是否已过期，由 KlineChartView.prefetchOtherPeriod 内部判断
            KlineChartView.prefetchOtherPeriod(metaId: metaId, period: period, data: data)
        }
    }
}

/// 联动信息栏单个格子：主图指标名称按钮（最左侧）+ 标的名称 + 标的代码。
/// 独立观察 portal，指标标题变化时只刷新本格子，不影响其它视图。
/// layoutPriority: name > code > 按钮（优先级数字越大布局越优先保留完整宽度）；
/// 按钮文字过长时自动截断，不影响 name 与 code。
private struct LinkedInfoCell: View {
    @ObservedObject var portal: MainLegendPortal
    let name: String
    let code: String

    var body: some View {
        HStack(spacing: 4) {
            IndicatorNameButton(title: portal.title,
                                onTap: { portal.onTap?() })
                .lineLimit(1)
                .layoutPriority(0)
            Text(name)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.black)
                .lineLimit(1)
                .layoutPriority(2)
            Text(code)
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.leading, 4)
    }
}

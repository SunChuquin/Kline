//
//  KlineDetailView.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/8/5.
//

import SwiftUI
import Combine
import UIKit

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

    /// 当前标的的联动视图数量（用于设置页下拉勾选；无记录时默认 2 视图）
    private var linkedViewCount: LinkedViewCount {
        LinkedViewCount(rawValue: LinkedViewStore.shared.configs(for: item.id).count) ?? .two
    }

    /// 当前标的的联动视图配置（用于信息栏列出各视图代码+周期）
    private var linkedViews: [LinkedViewConfig] {
        LinkedViewStore.shared.configs(for: item.id)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // 自定义/系统指标公式编辑器（真全屏）打开时隐藏顶部栏
                if !showCustomEditor && !showSystemEditor {
                    // 顶部留白压缩为小固定值，减少状态栏区域的空白
                    Color.clear
                        .frame(height: 2)

                    topBar
                }

                // 图表区域：始终占满剩余空间，内部显示加载/空/图表
                chartArea
            }
            .frame(maxHeight: .infinity)
            .background(Color.white.ignoresSafeArea())
            .overlay {
                if showSettings {
                    settingsOverlay(geometry: geometry)
                        .transition(.opacity)
                        .zIndex(10)
                }
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

    /// 顶部两行：第一行工具栏（返回 + 功能按钮），第二行信息栏（标的名称/代码/类型）
    private var topBar: some View {
        VStack(spacing: 0) {
            // ---- 第一行：工具栏 ----
            HStack(spacing: 6) {
                // 返回
                Button(action: {
                    onClose()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 30, height: 28)
                        .background(Color.gray.opacity(0.12))
                        .cornerRadius(6)
                }

                Spacer()

                // 📌 / 边：无十字光标时显示「边」按钮（开启边线调节并禁止光标）；有光标时显示 📌 固定光标（现有逻辑）
                if dualLink && !chartHasCursor {
                    // 「边」：默认关闭不高亮；点击开启高亮，开启后出现可拖动分界线，且禁止十字光标
                    Button(action: {
                        edgeAdjust.toggle()
                    }) {
                        Text("边")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(edgeAdjust ? .blue : .gray)
                            .frame(width: 32, height: 28)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(edgeAdjust ? "关闭边线调节" : "开启边线调节")
                } else {
                    // 📌 固定光标：关闭时只允许单光标；有光标时才能开启，开启后固定第一个光标并可点击产生第二个
                    Button(action: {
                        if pinEnabled {
                            pinEnabled = false
                        } else if chartHasCursor {
                            pinEnabled = true
                        }
                    }) {
                        Image(systemName: pinEnabled ? "pin.fill" : "pin")
                            .font(.system(size: 15))
                            .foregroundColor(pinEnabled ? .blue : .gray)
                            .frame(width: 32, height: 28)
                            .contentShape(Rectangle())
                    }
                    .disabled(!pinEnabled && !chartHasCursor)
                }

                // 单视图 / 双联动：双联动时左右对半分（左日线/右周线），十字光标联动
                Button(action: {
                    let wasOn = dualLink
                    withAnimation { dualLink.toggle() }
                    // 退出双联动时关闭边线调节，避免残留不可拖动/禁光标状态
                    if wasOn {
                        edgeAdjust = false
                        pinEnabled = false
                    }
                }) {
                    Text("联")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(dualLink ? .blue : .gray)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(dualLink ? "切换为单视图" : "切换为双联动")

                // 多/空 全局镜像：开启后主图与所有副图数值取负镜像（空头）
                Button(action: {
                    config.mainMirrored.toggle()
                }) {
                    Text(config.mainMirrored ? "空" : "多")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(config.mainMirrored ? .blue : .gray)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(config.mainMirrored ? "关闭空头镜像" : "开启空头镜像")

                // K线设置
                Button(action: {
                    withAnimation { showSettings = true }
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundColor(.gray)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.vertical, 3)

            // 工具栏与信息栏之间的分界线
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 0.5)

            // ---- 第二行：信息栏（联动各视图标的代码+周期 / 单图：名称代码类型） ----
            if dualLink {
                // 联动：按视图数量分格，每格显示对应视图的(代码+周期)，格子间用竖线分隔，
                // 分隔位置与主图视图边界对齐（2视图用可调占比，3/4视图等分）
                GeometryReader { geo in
                    infoLinkedRow(width: geo.size.width)
                }
                .frame(height: 22)
            } else {
                HStack(spacing: 6) {
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
        let count = views.count
        // 各视图左边界与主图一致：2视图用已占比，3/4视图同理
        let dividers = config.dualDividers(for: count)
        let bounds = [0.0] + dividers + [1.0]
        return ZStack(alignment: .topLeading) {
            // 各视图的标的信息（位于各自格子中央）
            ForEach(views.indices, id: \.self) { i in
                let left = CGFloat(bounds[i]) * width
                let right = CGFloat(bounds[i + 1]) * width
                infoPill(code: views[i].displayCode, period: views[i].period.rawValue)
                    .frame(width: right - left, alignment: .center)
            }
            // 视图之间的竖直分隔线（样式与主图一致）
            ForEach(1..<count, id: \.self) { i in
                let x = CGFloat(bounds[i]) * width
                Rectangle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 1)
                    .position(x: x, y: 11)
            }
        }
        .frame(width: width, height: 22)
    }

    /// 信息栏单个标的标签：代码 + 周期
    private func infoPill(code: String, period: String) -> some View {
        HStack(spacing: 3) {
            Text(code)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.blue)
            Text(period)
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
        .lineLimit(1)
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
                    chartView(series: s, period: config.selectedPeriod, linked: false)
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
            let views = linkedStore.configs(for: item.id)
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
                // 「边」开启时：可拖动分隔线覆盖层（每条独立可拖）
                if edgeAdjust {
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
                                    LinkedViewStore.shared.setViewCount(count, for: item.id)
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
                                LinkedViewStore.shared.reset(for: item.id)
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
                           linkAutoCenter: Bool = false, suppressCrosshair: Bool = false) -> some View {
        KlineChartView(series: series, chartStyle: $config.chartStyle, displaySettings: $config.displaySettings,
                       showCustomEditor: $showCustomEditor, showSystemEditor: $showSystemEditor, metaId: item.id, period: period,
                       isolatedSubs: isolated, linkAutoCenter: linkAutoCenter,
                       onPeriodSwitch: linked ? { _ in } : { newPeriod in
                           // 切换周期后图表重建，固定光标随之失效，重置 pin
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

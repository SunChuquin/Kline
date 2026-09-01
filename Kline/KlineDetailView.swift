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
            let posY = geo.size.height / 2
            Rectangle()
                .fill(Color.gray.opacity(0.35))
                .overlay(
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundColor(.gray.opacity(0.7))
                )
                // 关键顺序：先固定手柄条 14pt 宽（高填满父）
                .frame(width: handleWidth, height: geo.size.height)
                // 命中区 = 这个 14pt × fullHeight 的手柄条本身（精确、不越界）
                .contentShape(Rectangle())
                // 手势绑定在手柄条上：每条分隔线只响应自己手柄区域的拖动
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
                // 最后再定位：把上面那块 14pt 手柄条（带着它自己的手势）平移到对应 x
                .position(x: totalWidth * CGFloat(shownRatio), y: posY)
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
/// 无需了解图表内部状态即可保证两处显示与交互一致。
///
/// hideInChart 控制图内是否隐藏该按钮：
///   - true：联动 tile 场景，按钮在信息栏格子里显示，图表内部不重复渲染；
///   - false：单图场景，按钮保持在图表主图指标栏左侧，信息栏不重复显示。
final class MainLegendPortal: ObservableObject {
    /// 按钮标题；图表未就绪/加载中时为空串
    @Published var title: String = ""
    /// 点击行为（打开主图指标选择面板）；由图表同步注入
    var onTap: (() -> Void)? = nil
    /// true=按钮在信息栏显示、图内跳过；false=按钮在图内指标栏显示、信息栏跳过
    let hideInChart: Bool
    init(hideInChart: Bool) { self.hideInChart = hideInChart }
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
    /// 📌 固定光标模式开关（高亮表示已开启）。联动状态下固定光标完全禁用（只允许单光标）
    @State private var pinEnabled = false
    /// 图表当前是否已有任意十字光标（单视图下控制 📌 按钮可用性）
    @State private var chartHasCursor = false
    /// 单视图 / 双联动模式：双联动时多视图并排，可按日期同步光标
    @State private var dualLink = false
    /// 联动模式下的「光标联动开关」：关闭(灰)→ 各视图光标独立；开启(蓝)→ 任一视图的光标
    /// 按日期同步到所有视图；切换时自动清除屏幕上所有十字光标。
    @State private var cursorLinkEnabled = false
    /// 广播清所有视图的十字光标：token 变化时每个 KlineChartView 在 onChange 内清空自身光标
    @State private var cursorClearToken = UUID()
    /// 「边」边线调节模式：开启后才显示可拖动的 DualSplitDivider 分界线，且禁止十字光标
    @State private var edgeAdjust = false
    /// 重置当前标的联动视图配置的确认弹窗
    @State private var showResetLinkedConfirm = false
    // 设置面板内的三个统一选择器（confirmationDialog 风格，全部从底部弹出）
    @State private var showPeriodPicker = false
    @State private var showViewCountPicker = false
    @State private var showChartStylePicker = false
    /// 从联动信息栏钻取到单图：nil=正常模式（单图 or 联动）；非 nil=正在显示某格子的钻取单图
    @State private var drillIn: (metaID: Int, period: KlinePeriod, name: String, code: String, type: String)? = nil
    /// 钻取前联动页面的用户状态快照：cursorLinkEnabled/edgeAdjust/pinEnabled，返回联动时恢复
    @State private var drillInSnapshot: (cursorLinkEnabled: Bool, edgeAdjust: Bool, pinEnabled: Bool)? = nil
    /// 钻取模式下的 chartSeries（因为钻取 metaID/周期 可能与主 item 不一致，单独加载）
    @State private var drillInSeries: ChartSeries? = nil
    /// 钻取加载中：进入时显示 loading 态，避免空白
    @State private var drillInLoading = false
    /// 双视图联动同步（日线/周线图共享）
    @State private var linkSync = DualLinkSync()
    /// 顶部第一行工具栏实测高度（用于信息栏起始位置对齐可拖覆盖层）
    @State private var measuredTopBarHeight: CGFloat = 0
    /// 单视图：hideInChart=false → 按钮保持在图表主图指标栏，信息栏不重复显示
    @StateObject private var mainLegendPortal = MainLegendPortal(hideInChart: false)
    /// 联动：hideInChart=true → 各 tile 图内跳过按钮，按钮统一显示在信息栏每格左侧
    @State private var tilePortals: [MainLegendPortal] = (0..<4).map { _ in MainLegendPortal(hideInChart: true) }

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

    // MARK: 钻取单图：effective* 覆盖计算属性

    /// 真正用于所有显示判断的"是否联动"：钻取模式下即使 dualLink=true，也强制单图布局
    private var effectiveDual: Bool { dualLink && drillIn == nil }
    private var effectiveName: String { drillIn?.name ?? item.name }
    private var effectiveCode: String { drillIn?.code ?? item.displayCode }
    private var effectiveType: String { drillIn?.type ?? item.type }
    private var effectiveMetaID: Int { drillIn?.metaID ?? item.id }
    private var effectivePeriod: KlinePeriod { drillIn?.period ?? config.selectedPeriod }
    /// 当前实际要显示的 series：钻取时用 drillInSeries，否则仍用 currentSeries
    private var effectiveSeries: ChartSeries? { drillIn != nil ? drillInSeries : currentSeries }

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

                        // 第一行：工具栏（单图：含返回+名称+代码+功能按钮；联动：仅返回+功能按钮）
                        toolbarRow
                        // 工具栏与下方（信息栏或图表）之间的分界线
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 0.5)
                        // 第二行：信息栏仅联动（非钻取）时显示；单图/钻取信息已并入工具栏行，此处省略
                        if effectiveDual {
                            infoBarRow(width: geometry.size.width)
                        }
                    }

                    // 图表区域：始终占满剩余空间，内部显示加载/空/图表
                    chartArea
                }
                .frame(maxHeight: .infinity)
                .background(Color.white.ignoresSafeArea())

                // 「边」开启时：可拖分隔线覆盖层从信息栏顶部开始
                // （工具栏已独立，故固定偏移 = 顶部2留白 + 工具栏行实测高 + 分隔线0.5）
                if effectiveDual && edgeAdjust {
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
            if loaded {
                if isLoading { loadData() }
                if drillInLoading, let d = drillIn {
                    startDrillIn(metaID: d.metaID, period: d.period,
                                 name: d.name, code: d.code, type: d.type)
                }
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
        let compact = effectiveDual          // 联动（非钻取）：压缩到 22pt，和信息栏等高
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
            // 返回按钮三级语义：
            //   1. 联动状态（effectiveDual）= 先退联动，回到主标的单图
            //   2. 钻取单图（drillIn != nil）= 清 drillIn，恢复联动页面快照
            //   3. 普通单图 = 关闭详情页
            Button(action: {
                if effectiveDual {
                    // 1. 联动状态：先清理联动态，再退 dualLink
                    cursorLinkEnabled = false
                    edgeAdjust = false
                    pinEnabled = false
                    linkSync.cursorDate = nil
                    withAnimation { dualLink = false }
                } else if drillIn != nil {
                    // 2. 钻取单图 → 恢复联动页面（dualLink 本身未被清，仍是 true）
                    drillIn = nil
                    drillInSeries = nil
                    drillInLoading = false
                    cursorClearToken = UUID()
                    // 恢复快照：用户之前在联动页面打开的 cursorLinkEnabled / edgeAdjust / pinEnabled
                    if let snap = drillInSnapshot {
                        cursorLinkEnabled = snap.cursorLinkEnabled
                        edgeAdjust = snap.edgeAdjust
                        pinEnabled = snap.pinEnabled
                    }
                    drillInSnapshot = nil
                } else {
                    // 3. 普通单图：关闭页面
                    onClose()
                }
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: compact ? 13 : 16, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: backSize, height: btnH)
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(corner)
            }

            // 单图（普通单图 or 钻取单图）：在返回按钮右侧直接显示「标的名称 + 标的代码」，替代原先的独立信息栏
            if !compact {
                Text(effectiveName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.black)
                    .lineLimit(1)
                Text(effectiveCode)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }

            Spacer()

            // 「边」/📌 按钮：
            //   联动状态：永远显示「边」（不出图钉），限制每个视图最多一个十字光标；
            //   单图状态（包括钻取单图）：始终显示📌，无光标时灰、不可点；有任意光标后可点→钉住第一个光标。
            if effectiveDual {
                // 联动：永远显示「边」
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
                // 单图（含钻取）：始终显示📌按钮
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

            // 「联」字按钮：
            //   普通单图（drillIn == nil）→ 进入联动模式
            //   钻取单图 → 禁用（此按钮不存在于钻取，因为 !effectiveDual 下仍为普通"进入联动"但意义上不应该操作，
            //     实际上钻取时 drillIn != nil，按当前需求：此按钮保持原样点击行为（进入联动会清理 drillIn 语义未定），
            //     简单起见，钻取单图时此按钮点进入联动=直接退出钻取+进入联动，我们先保持与单图一致即可；
            //   联动 → 切换光标联动开关 cursorLinkEnabled；
            Button(action: {
                if !effectiveDual {
                    // 单图（含钻取） → 进入联动；若是钻取先清钻取状态+快照
                    if drillIn != nil {
                        drillIn = nil
                        drillInSeries = nil
                        drillInLoading = false
                        drillInSnapshot = nil
                    }
                    cursorLinkEnabled = false
                    pinEnabled = false
                    withAnimation { dualLink = true }
                } else {
                    // 联动 → 切换光标联动开/关
                    cursorLinkEnabled.toggle()
                    cursorClearToken = UUID()
                    linkSync.cursorDate = nil
                }
            }) {
                Text("联")
                    .font(.system(size: textSize, weight: .bold))
                    .foregroundColor(effectiveDual ? (cursorLinkEnabled ? .blue : .gray) : .gray)
                    .frame(width: normW, height: btnH)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(
                !effectiveDual ? "进入联动模式"
                               : (cursorLinkEnabled ? "关闭光标联动（清除所有光标）" : "开启光标联动（所有视图按日期同步）"))

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
                // 单图：主图指标名称按钮保持在图表主图指标栏左侧，此处不重复显示
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
                               code: views[i].displayCode,
                               onDrillIn: {
                    startDrillIn(metaID: views[i].metaID,
                                 period: views[i].period,
                                 name: views[i].name,
                                 code: views[i].displayCode,
                                 type: views[i].type)
                })
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
                if drillInLoading || (drillIn != nil && drillInSeries == nil && !isLoading) {
                    // 钻取加载中：显示转圈（避免钻取到空白时看起来卡住）
                    loadingView
                } else if isLoading {
                    loadingView
                } else if effectiveDual {
                    dualLinkArea()
                } else if effectiveSeries == nil {
                    emptyDataView
                } else if let s = effectiveSeries {
                    // metaID：钻取时 = drillIn.metaID（避免主图缓存被错误复用）；普通单图 = item.id
                    // period：钻取时 = drillIn.period；普通单图 = config.selectedPeriod
                    chartView(series: s,
                              period: effectivePeriod,
                              linked: false,
                              metaID: effectiveMetaID,
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
                        // 所有 tile 共享同一个 cursorLinkEnabled / cursorClearToken / linkSync：
                        // 外层「联」字按钮统一控制光标联动开关、统一广播清光标
                        cursorLinkEnabled: cursorLinkEnabled,
                        cursorClearToken: cursorClearToken,
                        mainLegendPortal: tilePortal(at: v.index),
                        sharedLinkSync: linkSync,
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
    /// 布局：iOS 设置 App 风格 —— section 标题 + 浅灰圆角分组卡片；所有下拉统一改为整行可点 → confirmationDialog 底部弹出
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
                settingsHeader(title: "K线设置") {
                    withAnimation { showSettings = false }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // 1. 通用分组：行情周期 + 联动视图数量
                        stSectionTitle("通用")
                        stGroupedCard {
                            stSelectionRow(title: "行情周期",
                                           value: config.selectedPeriod.rawValue) {
                                showPeriodPicker = true
                            }
                            stDivider()
                            stSelectionRow(title: "联动视图数量",
                                           value: linkedViewCount.label) {
                                showViewCountPicker = true
                            }
                        }

                        // 1b. 重置分组：单独的红色分组
                        stGroupedCard {
                            stDestructiveRow(title: "重置当前标的联动视图配置") {
                                showResetLinkedConfirm = true
                            }
                        }
                        .confirmationDialog("重置当前标的的联动视图配置？",
                                            isPresented: $showResetLinkedConfirm,
                                            titleVisibility: .visible) {
                            Button("重置", role: .destructive) {
                                let hint = (name: item.name, code: item.code, type: item.type)
                                LinkedViewStore.shared.reset(for: item.id, nameHint: hint)
                            }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("将恢复为默认 2 个视图（左日线、右周线），且各视图标的/周期会被重置。")
                        }

                        // 2. 显示分组：K线类型 + 图层显示开关
                        stSectionTitle("显示")
                        stGroupedCard {
                            stSelectionRow(title: "K线类型",
                                           value: config.chartStyle.rawValue) {
                                showChartStylePicker = true
                            }
                            stDivider()
                            stToggleRow(title: "跳空缺口",
                                        subtitle: "在 K 线之间标出跳空缺口区域",
                                        isOn: $config.displaySettings.showGap)
                            stDivider()
                            stToggleRow(title: "缺口回补后消失",
                                        subtitle: "开启时缺口被回补后整体隐藏；关闭时仅截止，保留形成区",
                                        isOn: $config.displaySettings.gapDisappearAfterFill)
                            stDivider()
                            stToggleRow(title: "最新价线",
                                        subtitle: "在最新收盘价位置绘制水平虚线",
                                        isOn: $config.displaySettings.showLatestPriceLine)
                            stDivider()
                            stToggleRow(title: "指标不挤压K线",
                                        subtitle: "主图价格范围仅按 K 线计算；关闭后指标线会撑大范围",
                                        isOn: $config.displaySettings.indicatorNotSqueezeKline)
                            stDivider()
                            stToggleRow(title: "裸 K",
                                        subtitle: "开启后只显示 K 线、隐藏全部主图指标",
                                        isOn: $config.showBareK)
                        }

                        Color.clear.frame(height: 16)
                    }
                }
                // 统一 3 个 confirmationDialog 选择器（全部从底部弹出，带当前选中项 checkmark）
                .confirmationDialog("选择行情周期", isPresented: $showPeriodPicker,
                                    titleVisibility: .visible) {
                    ForEach(KlinePeriod.allCases) { period in
                        Button(period.rawValue) {
                            DebugLogger.shared.log("设置面板切换周期: \(period.rawValue)")
                            withAnimation { config.selectedPeriod = period }
                        }
                    }
                    Button("取消", role: .cancel) {}
                }
                .confirmationDialog("选择联动视图数量", isPresented: $showViewCountPicker,
                                    titleVisibility: .visible) {
                    ForEach(LinkedViewCount.allCases) { count in
                        Button(count.label) {
                            let hint = (name: item.name, code: item.code, type: item.type)
                            LinkedViewStore.shared.setViewCount(count, for: item.id, nameHint: hint)
                        }
                    }
                    Button("取消", role: .cancel) {}
                }
                .confirmationDialog("选择 K 线类型", isPresented: $showChartStylePicker,
                                    titleVisibility: .visible) {
                    ForEach(ChartStyle.allCases) { style in
                        Button(style.rawValue) {
                            withAnimation { config.chartStyle = style }
                        }
                    }
                    Button("取消", role: .cancel) {}
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: geometry.size.height * 0.75)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 设置面板构建块（统一尺寸 / 内边距 / 圆角）

    /// 面板标题栏（左大标题 + 右关闭「完成」）
    private func settingsHeader(title: String, onClose: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.black)
                Spacer()
                Button(action: onClose) {
                    Text("完成")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider()
        }
    }

    /// 分组标题（iOS 设置样式：左对齐、小号灰字）
    private func stSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Color.gray.opacity(0.85))
            .padding(.horizontal, 32)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }

    /// 分组卡片：统一浅灰底 + 大圆角，内容垂直排列
    private func stGroupedCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(Color(red: 0.95, green: 0.95, blue: 0.97))
        .cornerRadius(10)
        .padding(.horizontal, 16)
    }

    /// 分组卡片内部的分隔线：从左侧 16 开始，避免左边被裁掉半像素
    private func stDivider() -> some View {
        Divider().padding(.leading, 16)
    }

    /// 下拉选择行：左标签 + 右选中值 + 右箭头，整行可点（统一 44 高）
    private func stSelectionRow(title: String, value: String, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(.black)
                Spacer(minLength: 12)
                Text(value)
                    .font(.system(size: 15))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .layoutPriority(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.gray.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 开关行：左两行（主标题 + 说明小字） + 右 Toggle
    private func stToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(.black)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn.animation())
                .labelsHidden()
                .tint(.blue)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 危险操作行：居中红体（重置）
    private func stDestructiveRow(title: String, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack {
                Spacer()
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .medium))
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                Spacer()
            }
            .foregroundColor(.red)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chartView(series: ChartSeries, period: KlinePeriod, linked: Bool, isolated: Bool = false,
                           linkAutoCenter: Bool = false, suppressCrosshair: Bool = false,
                           metaID: Int? = nil,   // nil = 用默认 item.id；钻取时传目标 metaID
                           mainLegendPortal: MainLegendPortal? = nil) -> some View {
        KlineChartView(series: series, chartStyle: $config.chartStyle, displaySettings: $config.displaySettings,
                       showCustomEditor: $showCustomEditor, showSystemEditor: $showSystemEditor,
                       metaId: metaID ?? item.id, period: period,
                       isolatedSubs: isolated, linkAutoCenter: linkAutoCenter,
                       // 单视图：cursorLinkEnabled 无意义，传 false（不传也有默认值）；
                       // 联动：此处 helper 仅单图分支在使用 → 传 false；tile 分支自己传 cursorLinkEnabled
                       cursorLinkEnabled: linked && cursorLinkEnabled,
                       cursorClearToken: cursorClearToken,
                       // 单图：保留"额"字段显示；联动 tile 分支传入 true 隐藏
                       hideQuoteTurnover: false,
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

    /// 钻取单图：为任意 (metaID, period) 后台查询 K 线，结果写入 drillInSeries；
    /// 若 DB 未就绪则立即返回（isLoaded 变化后会由上层 retry 触发）。
    private func startDrillIn(metaID: Int, period: KlinePeriod,
                              name: String, code: String, type: String) {
        // 1. 立即设置钻取状态：触发 effectiveDual=false，整页立刻切到单图布局（工具栏显示该标的信息）
        //    先 snapshot 再清，保证 snapshot 记录的是进入前的真实联动状态
        drillInSnapshot = (cursorLinkEnabled: cursorLinkEnabled,
                           edgeAdjust: edgeAdjust,
                           pinEnabled: pinEnabled)
        drillIn = (metaID, period, name, code, type)
        drillInLoading = true
        drillInSeries = nil
        // 2. 清联动残留状态（光标、边调、禁止的 pin）；dualLink 本身保留（用于返回联动时恢复）
        edgeAdjust = false
        pinEnabled = false
        linkSync.cursorDate = nil
        cursorClearToken = UUID()

        guard databaseManager.isLoaded else { return }   // DB 就绪后 onChange 会重试
        DispatchQueue.global(qos: .userInitiated).async {
            let data: [KlineItem]
            switch period {
            case .daily:   data = self.databaseManager.fetchDailyData(metaId: metaID)
            case .weekly:  data = self.databaseManager.fetchWeeklyData(metaId: metaID)
            case .monthly: data = self.databaseManager.fetchMonthlyData(metaId: metaID)
            case .quarterly: data = self.databaseManager.fetchquarterlyData(metaId: metaID)
            case .yearly:  data = self.databaseManager.fetchYearlyData(metaId: metaID)
            }
            DispatchQueue.main.async {
                self.drillInSeries = data.isEmpty ? nil : ChartSeries(data: data)
                self.drillInLoading = false
            }
        }
    }
}

/// 联动信息栏单个格子：主图指标名称按钮（最左侧）+ 标的名称 + 标的代码 + 最右"钻取单图"按钮。
/// 独立观察 portal，指标标题变化只刷新本格子，不影响其它视图。
/// layoutPriority: 按钮（不截断，保持完整显示）> 名称（允许缩小）> 代码（允许缩小）；
/// name/code 加 minimumScaleFactor：宽度不足时先缩小字号，最后万不得已才尾部截断，
/// 按钮不缩放不截断、标题"日线"多长都完整显示。
/// onDrillIn 非 nil 时在最右侧显示 22×22 chevron.right 灰色按钮：点击进入该格子的单图模式。
private struct LinkedInfoCell: View {
    @ObservedObject var portal: MainLegendPortal
    let name: String
    let code: String
    /// 点击最右侧 chevron 按钮时触发；nil 时不显示钻取按钮
    var onDrillIn: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            IndicatorNameButton(title: portal.title,
                                onTap: { portal.onTap?() })
                .layoutPriority(2)
            Text(name)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .layoutPriority(1)
            Text(code)
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .layoutPriority(0.5)
            Spacer(minLength: 6)
            if let onDrillIn {
                Button(action: onDrillIn) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.gray.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }
}

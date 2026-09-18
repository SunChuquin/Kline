//
//  ChartLegendKit.swift
//  Kline
//
//  图例与信息行域：主/副图指标栏、图例条目、门户同步、量额格式化、
//  时间轴刻度、指标覆盖进度条、轴上行情数据行。从 KlineChartView.swift 拆分（方法平移）。
//

import SwiftUI
import UIKit

extension KlineChartView {

    func legendValue(_ arr: [Double]) -> Double? {
        if let idx = legendCursorIndex, idx >= 0, idx < arr.count, !arr[idx].isNaN { return arr[idx] }
        let start = min(endIndex, arr.count - 1)
        guard start >= 0 else { return nil }
        // 从最近K线（endIndex）往回取「最近」的有限值：未全量计算时曲线只覆盖可见窗口附近，
        // 覆盖区间起点的指标可能尚未收敛（值为 0/NaN）。若从 endIndex-250 递增取「最早」有限值，
        // 会命中覆盖起点的 0，导致图例误显示 0；应从 endIndex 递减取最近的有效值（图例应为当前值）。
        for i in stride(from: start, through: max(0, start - 250), by: -1) {
            let v = arr[i]
            if v.isFinite { return v }
        }
        return nil
    }
    func legendValueFor(_ line: IndicatorLine) -> Double? { legendValue(line.values) }

// MARK: - 图例行 / 指标栏 / 时间轴 / 行情行

    func subLegendRow(model m: SubChartModel, height: CGFloat) -> some View {
        return ZStack {
            HStack(spacing: 8) {
                IndicatorNameButton(title: m.titleName, onTap: {
                    editorUI.editingSlot = (m === subTop) ? .top : (m === subBottom ? .bottom : .third)
                    editorUI.showMainSheet = false
                    withAnimation { editorUI.showSubSheet = !editorUI.showSubSheet }
                })
                // 数值内容区：多图(联动 tile)可单指横向拖动查看完整数据；单图保持原始紧凑布局
                if isLinkedTile {
                    InfoPannerCenter(ownerIndex: selfIndex, onDragStateChange: { dirty in if dirty { self.onInfoRowPanned?(true) } }) {
                        let isVolAmo = (m.kind == "VOL" || m.kind == "AMO")
                        let legendSlot = m === subTop ? 0 : (m === subBottom ? 1 : 2)
                        HStack(spacing: 8) {
                            ForEach(Array(m.curves.enumerated()), id: \.offset) { lineOffset, line in
                                legendItem(line, mirrored: config.mainMirrored,
                                           formatter: isVolAmo ? { formatVolume($0) } : nil,
                                           valueOverride: legendFollowsSecondCursor
                                               ? nil
                                               : subVolAmoOverride(m, lineOffset: lineOffset) ?? asOfSubOverride(slot: legendSlot, lineIndex: lineOffset))
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    // VOL/AMO 的数值按转换单位显示（万/亿/万亿），其余指标按默认格式；
                    // 联动复盘：VOL/AMO 柱线读合成累加量/额，其余指标行读 as-of 重算值；同图 MA 均量线走 as-of
                    let isVolAmo = (m.kind == "VOL" || m.kind == "AMO")
                    let legendSlot = m === subTop ? 0 : (m === subBottom ? 1 : 2)
                    ForEach(Array(m.curves.enumerated()), id: \.offset) { lineOffset, line in
                        legendItem(line, mirrored: config.mainMirrored,
                                   formatter: isVolAmo ? { formatVolume($0) } : nil,
                                   valueOverride: legendFollowsSecondCursor
                                       ? nil
                                       : subVolAmoOverride(m, lineOffset: lineOffset) ?? asOfSubOverride(slot: legendSlot, lineIndex: lineOffset))
                    }
                    Spacer()
                }
                // 副图1：最右侧「回到最新」按钮（右指带尾单箭头）。
                // 屏幕最右 K 线不是最后一根时高亮可点；点击直接加载最新 K 线（屏幕显示 100 根）。
                if m === subTop {
                    let atLatest = endIndex >= sortedData.count - 1
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            visibleCount = 100
                            endOffset = 0
                        }
                    } label: {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(atLatest ? Color.gray.opacity(0.35) : Color.blue)
                            .frame(width: 22, height: 22, alignment: .center)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(atLatest)
                }
                // 副图2：最右侧 🔍 搜索按钮（联动态显示；点击由外层接管覆盖式搜索栏）
                if m === subBottom && showSubTwoSearchButton {
                    Button {
                        onSubTwoSearch?()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 22, alignment: .center)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                // 副图3：最右侧「裸」按钮 —— 主图裸K开关（单图/联动均可显示）。
                // 仅切换渲染层隐藏主图指标，不触发主图重算、不清除 mainCurves 缓存（切回立即显示）。
                // 高亮样式与顶部导航栏「多/空」一致：开启=蓝，关闭=灰。
                if m === subThird {
                    Button {
                        bareFromSub.toggle()
                    } label: {
                        Text("裸")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(bareFromSub ? Color.blue : Color.gray)
                            .frame(width: 22, height: 22, alignment: .center)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(Color(.systemBackground))
        }
        .frame(height: height)
    }

    // MARK: - 主图指标栏

    /// 副图 VOL/AMO 的合成量/额覆盖值：仅 stick 柱线（VOL/AMO 本体）取合成累加量/额，其余返回 nil。
    /// （多图联动复盘时使用；单图 linkReplayState 为 nil 自然返回 nil，行为与原内联逻辑一致）
    func subVolAmoOverride(_ m: SubChartModel, lineOffset: Int) -> Double? {
        guard m.kind == "VOL" || m.kind == "AMO" else { return nil }
        guard lineOffset < m.curves.count else { return nil }
        let line = m.curves[lineOffset]
        guard line.style == .stick,
              let r = linkReplayState, let s = r.synthetic,
              r.idx == renderCursorIndex else { return nil }
        return m.kind == "AMO" ? s.turnover : s.volume
    }

    func mainLegendRow(height: CGFloat) -> some View {
        ZStack {
            HStack(spacing: 8) {
                // 若提供 portal 且 hideInChart=true（联动 tile 场景）：按钮挪到外层信息栏格子左侧，
                // 图内不重复渲染；若 portal 未提供或 hideInChart=false（单图）：按钮保持在图内指标栏
                let shouldHideButtonInChart = (mainLegendPortal?.hideInChart ?? false)
                if !shouldHideButtonInChart {
                    IndicatorNameButton(title: mainLegendTitle, onTap: {
                        editorUI.showSubSheet = false
                        withAnimation { editorUI.showMainSheet = !editorUI.showMainSheet }
                    })
                }
                if isBareK { legendText("裸K") }
                if !isBareK {
                    if isLinkedTile {
                        // 多图(联动 tile)：指标数值区可单指横向拖动查看完整数据；
                        // fixedSize 使文本按完整单行自然宽呈现，不压缩/换行/省略，超宽靠拖动查看
                        InfoPannerCenter(ownerIndex: selfIndex, onDragStateChange: { dirty in if dirty { self.onInfoRowPanned?(true) } }) {
                            HStack(spacing: 8) {
                                ForEach(Array(computation.mainCurves.enumerated()), id: \.offset) { li, line in
                                    // 联动复盘：合成点指标读数用 as-of 重算值（镜像取负仍由 legendItem 处理）；
                                    // 本地第二光标存在时数值栏跟随第二光标读真实值，必须关闭 as-of 覆盖
                                    legendItem(line, mirrored: config.mainMirrored,
                                               valueOverride: legendFollowsSecondCursor ? nil : asOfMainOverride(li))
                                }
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    } else {
                        // 单图：保持原始紧凑布局（数值区随内容自适应排列，末尾 Spacer 把右侧按钮推向右端）
                        ForEach(Array(computation.mainCurves.enumerated()), id: \.offset) { li, line in
                            legendItem(line, mirrored: config.mainMirrored,
                                       valueOverride: legendFollowsSecondCursor ? nil : asOfMainOverride(li))
                        }
                        Spacer()
                    }
                }
                // 主图放大开关：进入后主图全屏裸K、显示全部 K 线；放大期间若双指缩放导致 K 线数变少，
                // 再次点击只重新全显（保持放大）；仅当全部 K 线都在屏幕内时才退出放大并恢复最新 100 根。
                // 存在两个十字光标时（无论放大还是非放大），点击不切换放大状态，只定位到两个光标之间的 K 线
                if !hideMainZoomButton {
                    Button {
                    let hasTwoCursors = pinnedIndex != nil && renderCursorIndex != nil && pinnedIndex != renderCursorIndex
                    if hasTwoCursors {
                        // 存在两个十字光标：不切换放大/取消放大状态，
                        // 只让屏幕显示两个光标之间的 K 线（A前10 + A与B之间 + B + B后10）
                        withAnimation(.easeInOut(duration: 0.25)) {
                            applyExitWindowFromCursors()
                        }
                    } else if mainFullscreen {
                        if count < maxVisibleCount {
                            // 放大模式下双指缩放后非全显：重新让所有 K 线进入屏幕，保持放大
                            withAnimation(.easeInOut(duration: 0.25)) {
                                visibleCount = CGFloat(maxVisibleCount)
                                endOffset = 0
                            }
                        } else {
                            // 所有 K 线都在屏幕内：退出放大，按十字光标位置设定可见窗口
                            withAnimation(.easeInOut(duration: 0.25)) {
                                mainFullscreen = false
                                applyExitWindowFromCursors()
                            }
                        }
                    } else {
                        // 进入放大：主图全屏裸K，所有 K 线进入屏幕
                        withAnimation(.easeInOut(duration: 0.25)) {
                            mainFullscreen = true
                            visibleCount = CGFloat(maxVisibleCount)
                            endOffset = 0
                        }
                    }
                    // 放大状态下双指缩放时，DragGesture 可能被 MagnificationGesture 抢占而 onEnded 未触发，
                    // 导致 drag.isDragging 残留 true 拦截后续指标重算；这里强制重置并 force 重算，
                    // 保证退出放大后主图和副图指标立即恢复计算
                    drag.isDragging = false
                    drag.needsRefreshAfterDrag = false
                    // 放大模式主图裸K、副图隐藏，无需预计算；退出放大后恢复预计算
                    if mainFullscreen {
                        computation.prefetchToken = nil
                    } else {
                        startPrefetch()
                    }
                    refreshCurves(force: true)
                } label: {
                    // 图标语义：存在两个十字光标时显示"放大镜"（点击只定位到两光标之间的 K 线，
                    // 不切换放大状态）；否则未放大或放大中需重新全显时显示"指向外"（点击进入放大/重新全显），
                    // 全部 K 线已全显可关闭时显示"指向内"（点击退出放大）
                    let hasTwoCursors = pinnedIndex != nil && renderCursorIndex != nil && pinnedIndex != renderCursorIndex
                    let needShowAll = mainFullscreen && count < maxVisibleCount
                    Image(systemName: hasTwoCursors ? "magnifyingglass"
                        : (needShowAll ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(hasTwoCursors ? .blue : (mainFullscreen ? .blue : .gray))
                        .frame(width: 22, height: 22, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel((pinnedIndex != nil && renderCursorIndex != nil && pinnedIndex != renderCursorIndex)
                    ? "显示两个光标之间的K线"
                    : (mainFullscreen ? (count < maxVisibleCount ? "重新显示全部 K 线" : "退出主图放大") : "放大主图"))
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(Color(.systemBackground))
        }
        .frame(height: height)
    }

    /// 主图指标名称按钮：固定显示当前时间周期，如"日线: MA"、"周线: 裸K"
    var mainLegendTitle: String {
        if isBareK { return "\(period.rawValue): 裸K" }
        let store = SystemIndicatorStore.shared
        var parts: [String] = []
        for def in store.mainIndicatorDefs(period: self.period) where config.mainIndicators(for: self.period).contains(def.id) {
            parts.append(def.name)
        }
        if let a = activeCustomIndicator { parts.append(a.name) }
        if parts.isEmpty { return "\(period.rawValue): 裸K" }
        return "\(period.rawValue): \(parts.joined(separator: "/"))"
    }

    /// 把主图指标按钮的标题/点击行为同步给外层信息栏（提供 portal 时）。
    /// - 单图：portal.hideInChart == false（按钮渲染在图内主图指标栏）→ 完整标题 "日线: MA/CMK"
    /// - 联动：portal.hideInChart == true（按钮渲染在信息栏格子里）→ 只显示周期 "日线"
    func syncMainLegendPortal() {
        guard let portal = mainLegendPortal else { return }
        portal.title = portal.hideInChart ? period.rawValue : mainLegendTitle
        portal.onTap = {
            self.editorUI.showSubSheet = false
            withAnimation { self.editorUI.showMainSheet = !self.editorUI.showMainSheet }
        }
    }

    /// 副图坐标数值格式化
    func subFormatter(for kind: String) -> (Double) -> String {
        // VOL/AMO 按转换单位显示（万/亿/万亿）；其余均为 .tdx 公式输出，统一按量级自适应精度
        guard kind != "VOL", kind != "AMO" else { return { formatVolume($0) } }
        return { v in
            let av = abs(v)
            if av >= 1000 { return String(format: "%.0f", v) }
            if av >= 1 { return String(format: "%.2f", v) }
            return String(format: "%.3f", v)
        }
    }

    func legendItem(_ line: IndicatorLine, format: String = "%.2f", mirrored: Bool = false, formatter: ((Double) -> String)? = nil,
                            valueOverride: Double? = nil) -> some View {
        // NOTEXT_ 前缀的输出线：不显示名称也不显示数值（仅保留线条）
        if line.hideValue { return AnyView(EmptyView()) }
        let name = legendName(line)
        let color = line.color
        // 联动复盘：VOL/AMO 合成量/额由外部显式覆盖，优先于曲线数组读数
        if let value = valueOverride ?? legendValueFor(line), !value.isNaN {
            if value == 0 {
                klineDebug("[KlineDebug] ⚠️图例值=0 \(name) endIdx=\(endIndex) sel=\(String(describing: selectedIndex)) valuesCount=\(line.values.count) nan=\(line.values.filter{$0.isNaN}.count)")
            }
            let v = mirrored ? -value : value
            let valueText = formatter?(v) ?? String(format: format, v)
            return AnyView(Text("\(name):\(valueText)")
                .font(.system(size: 12))
                .foregroundColor(color))
        } else {
            return AnyView(Text(name)
                .font(.system(size: 11))
                .foregroundColor(color))
        }
    }

    /// 均线类指标名称直接显示参数数值（MA5/EMA5 → 5），用于主图 MA/EMA、VOL/AMO/CR 的量均线；其余指标保留原名
    func legendName(_ line: IndicatorLine) -> String {
        let n = line.name
        for prefix in ["EMA", "MA"] {
            if n.hasPrefix(prefix) {
                let rest = n.dropFirst(prefix.count)
                if Int(rest) != nil { return String(rest) }
            }
        }
        return n
    }

    func legendText(_ text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(Color.gray).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11)).foregroundColor(.gray)
        }
    }

    func formatVolume(_ v: Double) -> String {
        if v >= 1000000000000 { return String(format: "%.2f万亿", v / 1000000000000) }
        else if v >= 100000000 { return String(format: "%.2f亿", v / 100000000) }
        else if v >= 10000 { return String(format: "%.2f万", v / 10000) }
        else { return String(format: "%.0f", v) }
    }

    /// 主图竖轴顶部标签的垂直位置：单行时保持原轴顶对齐；两行（第二个光标）时整体下移，让标签完全落在主图内、顶部不外溢

    func timeAxis(width: CGFloat, candleSpacing: CGFloat, height: CGFloat) -> some View {
        let left = sortedData[startIndex].formattedDateWithWeekday
        let right = sortedData[endIndex].formattedDateWithWeekday
        return ZStack {
            // 指标覆盖进度条：直观显示已计算的历史范围（背景层，文字在上层不受影响）
            if showCoverageBar {
                coverageProgressBar(width: width, height: height)
            }
            HStack(spacing: 0) {
                Text(left).font(.system(size: 11)).foregroundColor(.gray)
                if !isLinkedTile {
                    Text("   周期数\(count)个").font(.system(size: 11)).foregroundColor(.gray)
                }
                Spacer()
            }
            .padding(.leading, 12)   // 起始文字朝中间偏移 4pt
            Text(right).font(.system(size: 11)).foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 4)   // 截止文字朝中间偏移 4pt
            // 联动多图：时间轴中间只显示周期数字，居中显示（单图保持「周期数xxx个」样式）
            if isLinkedTile {
                Text("\(count)").font(.system(size: 11)).foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            // 📌 开启且第一个固定光标存在时：固定光标的行情数据覆盖显示在时间轴上（第二个光标出现后依然持续显示）
            if let pinnedIndex, pinnedIndex >= startIndex, pinnedIndex <= endIndex {
                let item = sortedData[pinnedIndex]
                let prev = prevClose(of: pinnedIndex)
                let changePct = prev > 0 ? (item.close - prev) / prev * 100 : 0
                // 时间轴行情覆盖：多图可单指横向拖动查看完整数据；单图保持原始紧凑布局
                let overlayContent = HStack(spacing: 6) {
                    axisKV("开", String(format: "%.2f", item.open), .primary)
                    axisKV("收", String(format: "%.2f", item.close), item.isUp ? upColor : downColor)
                    axisKV("高", String(format: "%.2f", item.high), upColor)
                    axisKV("低", String(format: "%.2f", item.low), downColor)
                    axisKV("涨", String(format: "%+.2f%%", changePct), changePct >= 0 ? upColor : downColor)
                    if !hideQuoteTurnover {
                        axisKV("额", item.formattedTurnover, .primary)
                    }
                }
                Group {
                    if isLinkedTile {
                        // fixedSize：覆盖内容按完整单行自然宽呈现，不压缩/省略，超宽靠拖动查看
                        InfoPannerCenter(ownerIndex: selfIndex, onDragStateChange: { dirty in if dirty { self.onInfoRowPanned?(true) } }) {
                            overlayContent.fixedSize(horizontal: true, vertical: false)
                        }
                    } else {
                        overlayContent
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color(.systemBackground).opacity(0.95))
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(width: width, height: height)
        .background(Color(.systemBackground))
    }

    /// 是否显示指标覆盖进度条：后台正确计算尚未覆盖全部历史（非放大模式），算完（bgCoverageEnd 到末尾）后消失
    var showCoverageBar: Bool {
        !mainFullscreen && !sortedData.isEmpty && computation.bgCoverageEnd < sortedData.count - 1
    }

    /// 时间轴栏中间的指标覆盖进度条：高亮段表示后台已正确计算的覆盖范围 [0...bgCoverageEnd]
    /// 占全部数据的比例（横向代表 旧→新），从数据开头（最左）向右逐块推进，直观显示当前标的
    /// 已"精确计算"了多少历史；与普通从左往右推动的进度条不同，它反映的是真实计算覆盖范围
    func coverageProgressBar(width: CGFloat, height: CGFloat) -> some View {
        let total = CGFloat(max(1, sortedData.count))
        let endRatio = CGFloat(min(computation.bgCoverageEnd, sortedData.count - 1) + 1) / total
        let barWidth = min(width * 0.72, 340)
        let barHeight: CGFloat = 4
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.gray.opacity(0.18))
            Capsule()
                .fill(Color.blue)
                .frame(width: max(0, barWidth * endRatio), height: barHeight)
        }
        .frame(width: barWidth, height: barHeight)
        .position(x: width / 2, y: height / 2)
        .animation(.easeInOut(duration: 0.15), value: computation.bgCoverageEnd)
    }

    /// 时间轴上方新增的行情数据行：十字光标出现时显示光标所在K线 开/收/高/低/涨/额（涨为百分比），
    /// 无光标时显示当前屏幕最右边那根K线的行情数据（固定光标的行情数据改由时间轴覆盖显示）
    func axisQuoteRow(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            // 光标出现时取光标所在K线，否则取屏幕最右边那根K线
            // （联动复盘/范围框视图里本地「第二个十字光标」存在时取第二光标所指K线）
            let quoteIndex = legendCursorIndex ?? endIndex
            if quoteIndex >= startIndex, quoteIndex <= endIndex, quoteIndex >= 0, quoteIndex < sortedData.count {
                // 第二光标一律读真实K线；联动复盘光标索引处才读合成K线（开收高低/量额随合成变化）
                let item = legendFollowsSecondCursor ? sortedData[quoteIndex] : cursorDisplayItem(at: quoteIndex)
                let prev = prevClose(of: quoteIndex)
                let changePct = prev > 0 ? (item.close - prev) / prev * 100 : 0
                // 空头镜像：开/收/高/低取负显示；涨跌幅取负后数值不变（分子分母同号）
                let o = mir(item.open), c = mir(item.close), h = mir(item.high), l = mir(item.low)
                let isUpMirror = mainMirrored ? !item.isUp : item.isUp
                // 行情数据行：多图可单指横向拖动查看完整数据；单图保持原始紧凑布局
                let quoteRowContent = HStack(spacing: 6) {
                    axisKV("开", String(format: "%.2f", o), .primary)
                    axisKV("收", String(format: "%.2f", c), isUpMirror ? upColor : downColor)
                    axisKV("高", String(format: "%.2f", h), upColor)
                    axisKV("低", String(format: "%.2f", l), downColor)
                    axisKV("涨", String(format: "%+.2f%%", changePct), changePct >= 0 ? upColor : downColor)
                    if !hideQuoteTurnover {
                        axisKV("额", item.formattedTurnover, .primary)
                    }
                }
                Group {
                    if isLinkedTile {
                        // fixedSize：行情内容按完整单行自然宽呈现，不压缩/省略，超宽靠拖动查看
                        InfoPannerCenter(ownerIndex: selfIndex, onDragStateChange: { dirty in if dirty { self.onInfoRowPanned?(true) } }) {
                            quoteRowContent.fixedSize(horizontal: true, vertical: false)
                        }
                    } else {
                        quoteRowContent
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(width: width, height: height)
        .background(Color(.systemBackground))
    }

    /// 时间轴上紧凑的"标题:值"单元（标题灰色小字、值带色）
    func axisKV(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundColor(.gray)
            Text(value).font(.system(size: 11)).foregroundColor(color)
        }
    }

/// 光标所在K线的前一根收盘价（涨幅基准）

    func prevClose(of index: Int) -> Double {
        guard index > 0, index < sortedData.count else { return index < sortedData.count ? sortedData[index].close : 0 }
        return sortedData[index - 1].close
    }

}

// MARK: - 信息行可横向拖动查看组件

/// 测量信息行内容实际宽度的 PreferenceKey。
private struct InfoPannerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 信息行复位通知：重置按钮点击时广播（userInfo["idx"]=视图 index），
/// 对应视图的被拖动信息行内容恢复默认左对齐；不带 idx 时所有视图复位
extension Notification.Name {
    static let klineInfoRowReset = Notification.Name("klineInfoRowResetLeft")
}

/// 信息行 / 行情行 / 时间轴覆盖中「可单指横向拖动」的内容承载区（多图联动 tile 使用）：
/// - 内容默认靠左对齐；不论是否超宽，都能向左/向右拖动内容、松手停留
/// - 超宽：向左拖出右侧被藏部分；未超宽：向右拖出剩余白；两侧带小段 overscroll 保证手感应有
/// - 本组件只包裹数值内容本身；左侧名称按钮、右侧操作按钮作为兄弟节点放在组件外部，拖动与点击互不干扰
private struct InfoPannerCenter<Content: View>: View {
    @ViewBuilder let content: Content

    /// 本信息行所属视图下标（对应重置按钮的视图 index；仅当收到相同 index 的复位通知时复位）
    private var ownerIndex: Int = 0
    /// 拖动状态变化回调（传给外层用于重置按钮高亮判定，传参=是否有非零偏移）
    private var onDragStateChange: ((Bool) -> Void)?

    /// 已提交的最终停留偏移（向左为负）；拖动中以 offset + 实时位移 叠加显示
    @State private var committedOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @GestureState private var dragTranslation: CGFloat = 0

    init(ownerIndex: Int = 0,
         onDragStateChange: ((Bool) -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.ownerIndex = ownerIndex
        self.onDragStateChange = onDragStateChange
        self.content = content()
    }

    private func clamp01(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }

    var body: some View {
        GeometryReader { geo in
            let avail = max(1, geo.size.width)
            // 不论是否超宽，拖动都向左右双侧开放，保证「左右都能拖」：
            // - 未超宽：向右拖出剩余白/向左拖小段 overscroll
            // - 超宽：向左拖出右侧被藏部分/向右拖小段回弹
            // overscroll 保证未超宽/超宽两侧都始终有可拖行程
            let diff = contentWidth - avail
            let overscroll: CGFloat = 24
            let lo = min(0, diff) - overscroll
            let hi = max(0, -diff) + overscroll
            let shownOffset = clamp01(committedOffset + dragTranslation, lo, hi)
            ZStack(alignment: .leading) {
                content
                    .background(GeometryReader { g in
                        Color.clear.preference(key: InfoPannerWidthKey.self, value: g.size.width)
                    })
                    .offset(x: shownOffset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            // 用 simultaneousGesture（不独占）：外层整图 chartDragGesture 是 minimumDistance:0、
            // 触摸即 active，普通 .gesture 会被其抢先而无法激活（多图拖动无反应）、highPriorityGesture
            // 则独占触摸影响其它手势。simultaneousGesture 让内层拖动与外层共存——外层在信息行区域本就
            // 是 no-op，互不干扰，也不影响面板区的 K 线平移/光标等手势。
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                    .updating($dragTranslation) { value, state, _ in
                        state = value.translation.width
                    }
                    .onEnded { value in
                        committedOffset = clamp01(committedOffset + value.translation.width, lo, hi)
                    }
            )
        }
        .onPreferenceChange(InfoPannerWidthKey.self) { contentWidth = $0 }
        .onChange(of: committedOffset) { value in
            // 内容被拖动/复位时上报是否有非零偏移，供外层驱动重置按钮高亮
            onDragStateChange?(value != 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .klineInfoRowReset)) { note in
            // 重置按钮点击：恢复被拖动内容到默认左对齐（按视图 index 匹配）
            guard let noteIndex = note.userInfo?["idx"] as? Int, noteIndex == ownerIndex else { return }
            committedOffset = 0
        }
    }
}

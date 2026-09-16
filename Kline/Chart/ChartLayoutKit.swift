//
//  ChartLayoutKit.swift
//  Kline
//
//  图表构建层：主图/副图面板的 ZStack 组装（Canvas + 坐标标签 + 光标线 + 覆盖层）。
//  从 KlineChartView.swift 拆分（方法平移）。
//

import SwiftUI

extension KlineChartView {

    func mainChart(width: CGFloat, candleSpacing: CGFloat, height: CGFloat,
                           secondCursorIndex: Int? = nil) -> some View {
        ZStack(alignment: .topLeading) {
            Color(.systemBackground)
            mainCanvas(width: width, candleSpacing: candleSpacing, height: height)
                .offset(x: panOffset)
            // 主图价格坐标：网格线仍为5条，数值只显示顶底两个（中间三个不显示）；
            // 已启用的主图 .tdx 指标全部声明 COORD=0（且无激活自定义主图指标）时不显示
            PriceLabelsAxis(width: width, height: height, axisColor: axisTextColor,
                            labels: (mainCoordHidden ? [] : [0, 1]).map { r in
                                AxisLabel(ratio: r, text: String(format: "%.2f",
                                    priceRange.upperBound - (priceRange.upperBound - priceRange.lowerBound) * Double(r)))
                            })
                .equatable()
            // 最新价：只保留虚线（在 Canvas 中绘制），不显示数值，避免与虚线重叠
            // 可交互光标（pin 开启时即第二个光标）与固定光标的竖线/标签都绘制
            mainCursorVLine(index: renderCursorIndex, compare: pinnedIndex, width: width, candleSpacing: candleSpacing, height: height)
            mainCursorVLine(index: pinnedIndex, compare: nil, width: width, candleSpacing: candleSpacing, height: height)
            // 联动小周期范围框视图的本地「第二个十字光标」：蓝色、只保留顶部日期标签（纯装饰，不参与命中测试）
            mainCursorVLine(index: secondCursorIndex, compare: nil, width: width, candleSpacing: candleSpacing, height: height,
                            secondary: true)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .clipped()
    }

    /// 主图顶底价格坐标是否隐藏：已启用的主图 .tdx 指标全部声明 COORD=0
    /// （且无激活的自定义主图指标）时隐藏；任一指标未声明 COORD 或值非 0 则显示
    var mainCoordHidden: Bool {
        let enabled = config.mainIndicators(for: period)
        let mains = SystemIndicatorStore.shared.mainIndicatorDefs(period: period)
            .filter { enabled.contains($0.id) }
        guard !mains.isEmpty, activeCustomIndicator == nil else { return false }
        return mains.allSatisfy { $0.hideCoord }
    }

    /// 主图单个光标的竖线 + 顶部日期标签 + 底部涨幅标签（可交互光标与固定光标共用；
    /// compare 非 nil 表示这是第二个光标，顶部/底部标签追加与第一个固定光标的对比统计；
    /// 标签始终跟随各自竖线居中显示，不做互相避让）。
    /// secondary=true：联动小周期范围框视图里的纯本地「第二个十字光标」——蓝色竖线、
    /// 只保留顶部日期标签（无底部距今标签，无对比统计）。
    @ViewBuilder

    func mainCanvas(width: CGFloat, candleSpacing: CGFloat, height: CGFloat) -> some View {
        // 注意：K线空实心/类型直接读取 config.chartStyle —— config 已被 @ObservedObject 观察，
        // 这样「K线设置-显示组-类型」修改（含启动时从 UserDefaults 恢复）都会立即驱动主图重绘实心/空心，
        // 不依赖外部传入的 @Binding 中间层传播。
        // 联动复盘：全局 idx → 可见切片本地索引；合成K线镜像取负与 mirroredSlice 同构。
        let replay = linkReplayState
        let localCount = max(0, endIndex - startIndex + 1)
        let syntheticBar: SyntheticBar? = {
            guard let r = replay, let s = r.synthetic,
                  r.idx >= startIndex, r.idx <= endIndex else { return nil }
            let item: KlineItem
            if mainMirrored {
                item = KlineItem(date: s.date, open: -s.open, high: -s.high, low: -s.low,
                                 close: -s.close, volume: s.volume, turnover: s.turnover)
            } else {
                item = s
            }
            return SyntheticBar(index: r.idx - startIndex, item: item)
        }()
        let dimFromLocal: Int? = replay.flatMap { r in
            let d = r.dimFrom - startIndex
            return (d >= 0 && d < localCount) ? d : nil
        }
        // 主图曲线可见切片：合成索引处用 as-of 重算值单点替换（历史段/未来段数组值不动）
        func mainCurveValues(_ line: IndicatorLine, lineIndex: Int) -> [Double] {
            var values = mirroredSliceArr(line.values)
            if let r = replay, r.synthetic != nil,
               r.idx >= startIndex, r.idx <= endIndex,
               let v = asOfModel.main[lineIndex] {
                let local = r.idx - startIndex
                if local >= 0, local < values.count { values[local] = mainMirrored ? -v : v }
            }
            return values
        }
        return MainChartCanvas(slice: mainMirrored ? mirroredSlice : slice, chartStyle: config.chartStyle, candleSpacing: candleSpacing, height: height,
                        priceMin: priceRange.lowerBound, priceMax: priceRange.upperBound,
                        curves: isBareK ? [] : computation.mainCurves.enumerated().map { li, line in
                            CanvasCurve(color: line.color, values: mainCurveValues(line, lineIndex: li),
                                        style: line.style, lineWidth: line.lineWidth, barColor: line.barColor,
                                        markerColors: sliceColors(line.markerColors))
                        },
                        upColor: upColor, downColor: downColor, gridColor: gridColor,
                        showGap: displaySettings.showGap, showLatestPriceLine: displaySettings.showLatestPriceLine,
                        gapDisappearAfterFill: displaySettings.gapDisappearAfterFill,
                        gaps: mainMirrored ? mirroredGaps : computation.gaps, sliceStart: startIndex,
                        latest: mirroredLatest,
                        syntheticBar: syntheticBar, dimFromIndex: dimFromLocal)
            .equatable()
    }

    // MARK: - 副图

    func subChart(model m: SubChartModel, width: CGFloat, candleSpacing: CGFloat,
                          height: CGFloat, slot: SubSlot, secondCursorIndex: Int? = nil) -> some View {
        let range = subRange(m)
        let subFmt: (Double) -> String = subFormatter(for: m.kind)
        // 顶底坐标值：VOL/AMO 最低值恒为 0，底部"0"无需显示；
        // .tdx 声明 COORD=0 的指标不显示坐标值；其他指标保留顶底两个值
        let labelRatios: [CGFloat]
        if m.kind == "VOL" || m.kind == "AMO" {
            labelRatios = [0]
        } else if !m.isCustom,
                  SystemIndicatorStore.shared.defs(for: self.period)[m.kind]?.hideCoord == true {
            labelRatios = []
        } else {
            labelRatios = [0, 1]
        }
        // 联动复盘：未来淡化本地索引 + VOL/AMO 合成柱（镜像时与副图曲线同规则取负）
        let replay = linkReplayState
        let localCount = max(0, endIndex - startIndex + 1)
        let dimLocal: Int? = replay.flatMap { r in
            let d = r.dimFrom - startIndex
            return (d >= 0 && d < localCount) ? d : nil
        }
        // 槽位下标（0/1/2，as-of 结果索引）；注意勿与函数参数 slot: SubSlot 同名
        let subSlotIndex = m === subTop ? 0 : (m === subBottom ? 1 : 2)
        let synthStick: SyntheticStick? = {
            guard let r = replay, let s = r.synthetic,
                  r.idx >= startIndex, r.idx <= endIndex,
                  m.kind == "VOL" || m.kind == "AMO" else { return nil }
            let v = m.kind == "AMO" ? s.turnover : s.volume
            return SyntheticStick(index: r.idx - startIndex,
                                  value: config.mainMirrored ? -v : v,
                                  isUp: s.isUp)
        }()
        // 副图曲线可见切片：合成索引处用 as-of 重算值单点替换（VOL/AMO 均量线等同样适用）
        func subCurveValues(_ line: IndicatorLine, lineIndex: Int) -> [Double] {
            var values = subMirroredSliceArr(line.values)
            if let r = replay, r.synthetic != nil,
               r.idx >= startIndex, r.idx <= endIndex,
               let v = asOfModel.subs[subSlotIndex][lineIndex] {
                let local = r.idx - startIndex
                if local >= 0, local < values.count { values[local] = config.mainMirrored ? -v : v }
            }
            return values
        }
        return ZStack(alignment: .topLeading) {
            Color(.systemBackground)
            SubChartCanvas(slice: slice, candleSpacing: candleSpacing, height: height,
                           curves: m.curves.enumerated().map { li, line in
                               CanvasCurve(color: line.color, values: subCurveValues(line, lineIndex: li),
                                           style: line.style, lineWidth: line.lineWidth, barColor: line.barColor)
                           },
                           rangeMin: range.min, rangeMax: range.max,
                           upColor: upColor, downColor: downColor, gridColor: gridColor,
                           dimFromIndex: dimLocal, syntheticStick: synthStick)
                .equatable()
                .offset(x: panOffset)
            // 顶底坐标值（是否显示由上方 labelRatios 决定）
            PriceLabelsAxis(width: width, height: height, axisColor: axisTextColor,
                            labels: labelRatios.map { r in
                                AxisLabel(ratio: r, text: subFmt(range.max - (range.max - range.min) * Double(r)))
                            })
                .equatable()

            // 可交互光标（pin 开启时即第二个光标）与固定光标的副图竖线都绘制
            SubCursorVLine(startIndex: startIndex, endIndex: endIndex, index: renderCursorIndex, compare: pinnedIndex,
                           candleSpacing: candleSpacing, height: height)
                .equatable()
            SubCursorVLine(startIndex: startIndex, endIndex: endIndex, index: pinnedIndex, compare: nil,
                           candleSpacing: candleSpacing, height: height)
                .equatable()
            // 联动小周期范围框视图的本地「第二个十字光标」副图竖线（蓝色，纯装饰不参与命中测试）
            SubCursorVLine(startIndex: startIndex, endIndex: endIndex, index: secondCursorIndex, compare: nil,
                           candleSpacing: candleSpacing, height: height, secondary: true)
                .equatable()
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .clipped()
        .overlay {
            // 副图3 不挂滑动反馈层（面板手势整体禁用，预留给虚拟按钮）；副图1/2 保留左右滑动切换
            if slot != .third {
                // 副图一（上方副图）方向已调转：左=小级别/上一标的，右=大级别/下一标的；副图二保持原方向
                SwipeOverlay(slot: slot, fb: swipeFeedback,
                             canL: slot == .top ? canSwitchPeriod(-1) : (canSwitchItem?(1) ?? false),
                             canR: slot == .top ? canSwitchPeriod(1) : (canSwitchItem?(-1) ?? false),
                             width: width, height: height)
                    .equatable()
            }
        }
    }


    // MARK: - 十字光标辅助


}

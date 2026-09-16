//
//  ChartCursorKit.swift
//  Kline
//
//  十字光标域：读数文本、光标覆盖层（横线/标签/涨幅）、主图光标竖线、双光标区间统计、
//  价格与像素互算、标签几何与横线避让区间。从 KlineChartView.swift 拆分（方法平移）。
//

import SwiftUI
import UIKit

extension KlineChartView {

// MARK: - 标签几何辅助

    func labelTextWidth(_ text: String, fontSize: CGFloat, bold: Bool = true) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        return w + 8
    }

    /// 十字光标竖线标签的横向定位：标签中心跟随竖线，只有标签真正会超出屏幕时才对齐贴边
    func crosshairLabelAlignment(x: CGFloat, labelWidth: CGFloat, width: CGFloat) -> (Alignment, CGFloat) {
        if x - labelWidth / 2 < 0 { return (.leading, 0) }        // 左边缘贴屏幕最左侧
        if x + labelWidth / 2 > width { return (.trailing, 0) }    // 右边缘贴屏幕最右侧
        return (.center, x - width / 2)                            // 跟随竖线
    }

// MARK: - 十字光标读数与覆盖层

    func crosshairValueText(at y: CGFloat, mainTop: CGFloat, mainBottom: CGFloat, mainHeight: CGFloat,
                                    s1Top: CGFloat, s1Bottom: CGFloat, s1Height: CGFloat,
                                    s2Top: CGFloat, s2Bottom: CGFloat, s2Height: CGFloat,
                                    s3Top: CGFloat, s3Bottom: CGFloat, s3Height: CGFloat) -> String {
        if y >= mainTop && y <= mainBottom {
            let ratio = Double((y - mainTop) / mainHeight)
            let v = priceRange.upperBound - (priceRange.upperBound - priceRange.lowerBound) * ratio
            return String(format: "%.2f", v)
        }
        if y >= s1Top && y <= s1Bottom {
            let r = subRange(subTop)
            let ratio = Double((y - s1Top) / s1Height)
            let v = r.max - (r.max - r.min) * ratio
            return subFormatter(for: subTop.kind)(v)
        }
        if y >= s2Top && y <= s2Bottom {
            let r = subRange(subBottom)
            let ratio = Double((y - s2Top) / s2Height)
            let v = r.max - (r.max - r.min) * ratio
            return subFormatter(for: subBottom.kind)(v)
        }
        if y >= s3Top && y <= s3Bottom {
            let r = subRange(subThird)
            let ratio = Double((y - s3Top) / s3Height)
            let v = r.max - (r.max - r.min) * ratio
            return subFormatter(for: subThird.kind)(v)
        }
        return ""
    }

    /// 单个十字光标在整图上的绘制：横线 + 左侧数值标签 + 主图横轴右侧涨幅标签
    /// （可交互光标与固定光标共用；只有光标 y 落在任一图表面板内才绘制；
    /// fixedPrice 非 nil 表示固定光标的主图横轴价格已固定，数值与横线位置都按该价格）
    @ViewBuilder
    func cursorOverlay(index: Int?, y: CGFloat?, compare: Int?, fixedPrice: Double?, width: CGFloat, height: CGFloat,
                               candleSpacing: CGFloat,
                               mainTop: CGFloat, mainBottom: CGFloat, mainHeight: CGFloat,
                               s1Top: CGFloat, s1Bottom: CGFloat, s1Height: CGFloat,
                               s2Top: CGFloat, s2Bottom: CGFloat, s2Height: CGFloat,
                               s3Top: CGFloat, s3Bottom: CGFloat, s3Height: CGFloat) -> some View {
        if let index, let y,
           isInPanel(y, mainTop, mainBottom) || isInPanel(y, s1Top, s1Bottom) || isInPanel(y, s2Top, s2Bottom) || isInPanel(y, s3Top, s3Bottom) {
            let cy = min(max(y, 0), height)
            // 固定光标主图横轴价格超出当前可见价格范围时，横线不显示（与竖轴移出屏幕的行为一致），
            // 直到价格范围重新覆盖该价格才恢复显示
            if fixedPrice.map({ $0 >= priceRange.lowerBound && $0 <= priceRange.upperBound }) ?? true {
                // 第二个光标且位于主图区域时：左侧标签第二行追加 第一个光标横轴价格→第二个光标横轴价格 的涨幅
                let priceChange = (compare != nil && isInPanel(y, mainTop, mainBottom))
                    ? secondCursorPriceChange(y: y, pinnedY: pinnedY, pinnedPrice: pinnedPrice, mainTop: mainTop, mainBottom: mainBottom, mainHeight: mainHeight)
                    : nil
                let valueText: String = {
                    if let fp = fixedPrice {
                        // 固定光标的主图横轴价格已固定：数值保持不变
                        return String(format: "%.2f", fp)
                    }
                    return crosshairValueText(at: y, mainTop: mainTop, mainBottom: mainBottom, mainHeight: mainHeight,
                                              s1Top: s1Top, s1Bottom: s1Bottom, s1Height: s1Height,
                                              s2Top: s2Top, s2Bottom: s2Bottom, s2Height: s2Height,
                                              s3Top: s3Top, s3Bottom: s3Bottom, s3Height: s3Height)
                }()
                // 第二个光标比固定光标多出的横轴价格涨幅 → 第二行；固定光标无第二行
                let secondLineText = (fixedPrice == nil) ? (priceChange.map { String(format: "%+.2f%%", $0) } ?? "") : ""
                // 第二个光标时：左侧标签整体背景红涨绿跌（按横轴价格涨幅）、横线蓝色（同📌高亮色）；固定光标保持天蓝/黑色
                let bgColor = priceChange.map { $0 >= 0 ? upColor : downColor } ?? Color(red: 0.35, green: 0.75, blue: 1.0)
                // 横线若与该光标（或对方光标）竖线的顶部日期标签/底部涨幅标签重叠，则在该区间断开不画在标签上
                // 对方光标：两个光标共用一个横线层，需同时让开两个光标的竖线标签
                let otherIndex: Int? = (index == renderCursorIndex) ? pinnedIndex : renderCursorIndex
                let otherCompare: Int? = (index == renderCursorIndex) ? nil : pinnedIndex
                let lineGap = crosshairLineGap(index: index, compare: compare, otherIndex: otherIndex, otherCompare: otherCompare,
                                               cy: cy, candleSpacing: candleSpacing, width: width,
                                               mainTop: mainTop, mainHeight: mainHeight)
                CrosshairLineOverlay(width: width, height: height, y: cy, valueText: valueText,
                                     secondLine: secondLineText.isEmpty ? nil : secondLineText,
                                     gapRanges: lineGap,
                                     bgColor: bgColor,
                                     lineColor: compare != nil ? Color.blue : Color(.label).opacity(0.45))
                    .equatable()
                // 主图横线右边：光标K线收盘 → 屏幕最后那根K线收盘 的涨幅；
                // 光标停在屏幕最右边一根K线（index == endIndex）时不显示（涨幅恒为0无意义）。
                // 联动「历史时点复盘」态（本视图周期严格大于来源周期）同样不显示：屏幕末根属于
                // 光标之后的「未来淡化区」（站在光标时点尚未发生），"从光标到窗口右侧"的涨幅在复盘语义下不成立
                if linkReplayState?.idx != index,
                   isInPanel(y, mainTop, mainBottom),
                   index >= startIndex, index < endIndex, endIndex >= 0, endIndex < sortedData.count {
                    // 联动复盘：涨幅基准为合成K线收盘；屏幕末根是真实K线（"从当时到窗口右侧"）
                    let cursorItem = cursorDisplayItem(at: index)
                    let screenLast = sortedData[endIndex]
                    if cursorItem.close > 0, screenLast.close > 0 {
                        let pct = (screenLast.close - cursorItem.close) / cursorItem.close * 100
                        let periodCount = max(0, endIndex - index)
                        // 第二个光标时：第二行显示 两光标间K线周期个数（第二光标比固定光标多出的内容）
                        let secondPeriod = compare.flatMap { pinnedRangeStats(index, $0) }.map { $0.periodCount }
                        // 使用整宽右对齐容器，让标签右边缘精确贴合屏幕最右侧
                        VStack(spacing: 1) {
                            Text(String(format: "%+.2f%%  %d", pct, periodCount))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.top, 1)
                            if let sp = secondPeriod {
                                Text(String(format: "%d", sp))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.bottom, 1)
                            }
                        }
                        .background(pct >= 0 ? upColor : downColor)
                        .frame(width: width, alignment: .trailing)
                        .position(x: width / 2, y: cy)
                    }
                }
            }
        }
    }

// MARK: - 主图光标竖线 / 双光标统计 / 价格反算

    @ViewBuilder
    func mainCursorVLine(index: Int?, compare: Int?, width: CGFloat, candleSpacing: CGFloat, height: CGFloat,
                                 secondary: Bool = false) -> some View {
        if let index, index >= startIndex, index <= endIndex {
            // 联动复盘：可交互光标在合成索引时，距今涨幅等读数用合成K线（日期与真实K线一致）
            let item = cursorDisplayItem(at: index)
            let xPosition = (CGFloat(index - startIndex) + 0.5) * candleSpacing
            // 主图竖线：从顶部日期标签背景下沿开始画到底部（竖线完全从背景底下开始，顶部无露出）；第二个光标蓝色、固定光标黑色
            let topCut = clampedAxisY(0, in: height) + 8
            let lineHeight = max(0, height - topCut)
            Rectangle().fill((compare != nil || secondary) ? Color.blue : Color(.label).opacity(0.45)).frame(width: 1.0, height: lineHeight)
                .position(x: xPosition, y: topCut + lineHeight / 2)
            // 顶部日期+星期标签：位于主图顶部坐标值那一行、跟随竖线位置，样式与横轴数值一致（天蓝色背景、白字加粗）；
            // 第二个光标时第二行显示 两光标间振幅 / 最大回撤 / 最大上涨 / 涨幅；宽度按最宽一行（第二行）贴边判定
            let compareStats = compare.flatMap { pinnedRangeStats(index, $0) }
            let dateText = item.formattedDateWithWeekday
            let dateSecondLine = compareStats.map { String(format: "%.2f%%  %+.2f%%  %+.2f%%  %+.2f%%", $0.amplitude, $0.drawdown, $0.rally, $0.change) }
            let dateW = dateSecondLine.map { labelTextWidth($0, fontSize: 10) } ?? labelTextWidth(dateText, fontSize: 10)
            let (dateAlign, dateOffset) = crosshairLabelAlignment(x: xPosition, labelWidth: dateW, width: width)
            VStack(spacing: 1) {
                Text(dateText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.top, 1)
                if let c = compareStats {
                    HStack(spacing: 3) {
                        Text(String(format: "%.2f%%", c.amplitude))
                            .foregroundColor(.white)
                        Text(String(format: "%+.2f%%", c.drawdown))
                            .foregroundColor(downColor)
                        Text(String(format: "%+.2f%%", c.rally))
                            .foregroundColor(upColor)
                        Text(String(format: "%+.2f%%", c.change))
                            .foregroundColor(c.change >= 0 ? upColor : downColor)
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.bottom, 1)
                }
            }
            .background(Color(red: 0.35, green: 0.75, blue: 1.0))
            .frame(width: width, alignment: dateAlign)
            .offset(x: dateOffset)
            // 两行标签更高，中心点整体下移使其完全落在主图内，避免顶部被裁剪
            .position(x: width / 2, y: cursorTopLabelY(hasSecondLine: compareStats != nil, height: height))
            // 主图竖线下方（底部）：距今涨幅（光标K线收盘 → 整个数据集最后一根K线收盘）+ 距今周期数，白字、背景红涨绿跌；
            // 第二个光标时第二行显示 两光标间成交量之和 与 成交额之和；宽度按最宽一行（第二行）贴边判定。
            // 联动「历史时点复盘」态（本视图周期严格大于来源周期）不显示：数据末根属于光标之后的
            // 「未来淡化区」（站在光标时点尚未发生），"距今涨幅/周期数"在复盘语义下不成立。
            // 联动范围框视图的本地第二光标（secondary）按需求只有顶部/左侧两个标签，底部同样不绘制。
            if !secondary, linkReplayState?.idx != index, let last = sortedData.last, last.close > 0 {
                let pct = (last.close - item.close) / item.close * 100
                let periodCount = max(0, (sortedData.count - 1) - index)
                let pctSecondLine = compareStats.map { String(format: "%@  %@", formatVolume($0.volSum), formatAmount($0.amoSum)) }
                let pctW = pctSecondLine.map { labelTextWidth($0, fontSize: 10) } ?? labelTextWidth(String(format: "%+.2f%%  %d", pct, periodCount), fontSize: 10)
                let (pctAlign, pctOffset) = crosshairLabelAlignment(x: xPosition, labelWidth: pctW, width: width)
                VStack(spacing: 1) {
                    Text(String(format: "%+.2f%%  %d", pct, periodCount))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.top, 1)
                    if let line2 = pctSecondLine {
                        Text(line2)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 1)
                    }
                }
                .background(pct >= 0 ? upColor : downColor)
                .frame(width: width, alignment: pctAlign)
                .offset(x: pctOffset)
                // 两行标签更高，中心点整体上移使其完全落在主图内，避免底部被裁剪
                .position(x: width / 2, y: cursorBottomLabelY(hasSecondLine: pctSecondLine != nil, height: height))
            }
        }
    }

    /// 第二个光标相对第一个固定光标的区间统计（区间为两光标之间；基准为固定光标的收盘价）
    /// change=两光标间涨幅、amplitude=振幅(区间最高-最低相对基准)、drawdown=最大回撤(相对基准,通常负)、
    /// rally=最大上涨(相对基准,通常正)、volSum=成交量之和、amoSum=成交额之和、periodCount=两光标间K线周期个数
    func pinnedRangeStats(_ second: Int, _ pinned: Int) -> (change: Double, amplitude: Double, drawdown: Double, rally: Double, volSum: Double, amoSum: Double, periodCount: Int)? {
        let s = min(second, pinned)
        let e = max(second, pinned)
        guard s >= 0, e < sortedData.count, s <= e else { return nil }
        let baseClose = sortedData[pinned].close
        guard baseClose > 0 else { return nil }
        let slice = sortedData[s...e]
        let high = slice.map(\.high).max() ?? 0
        let low = slice.map(\.low).min() ?? 0
        let change = (sortedData[second].close - baseClose) / baseClose * 100
        let amplitude = (high - low) / baseClose * 100
        let drawdown = (low - baseClose) / baseClose * 100
        let rally = (high - baseClose) / baseClose * 100
        let volSum = slice.reduce(0.0) { $0 + $1.volume }
        let amoSum = slice.reduce(0.0) { $0 + $1.turnover }
        return (change, amplitude, drawdown, rally, volSum, amoSum, e - s)
    }

    /// 成交额格式化（万亿/亿/万）
    func formatAmount(_ v: Double) -> String {
        if v >= 1000000000000 { return String(format: "%.2f万亿", v / 1000000000000) }
        else if v >= 100000000 { return String(format: "%.2f亿", v / 100000000) }
        else if v >= 10000 { return String(format: "%.2f万", v / 10000) }
        else { return String(format: "%.0f", v) }
    }

    /// 根据光标横线 y 反算主图横轴价格（仅主图区域有效）
    func priceAtY(_ y: CGFloat, mainTop: CGFloat, mainBottom: CGFloat, mainHeight: CGFloat) -> Double? {
        guard y >= mainTop, y <= mainBottom else { return nil }
        let ratio = Double((y - mainTop) / mainHeight)
        return priceRange.upperBound - (priceRange.upperBound - priceRange.lowerBound) * ratio
    }

    /// 主图价格 → 横线 y（用当前价格范围反算，限制在主图区域内）：用于固定光标横轴价格不随可见窗口变化
    func priceToY(_ price: Double, mainTop: CGFloat, mainBottom: CGFloat, mainHeight: CGFloat) -> CGFloat {
        let denom = max(1e-9, priceRange.upperBound - priceRange.lowerBound)
        let ratio = (priceRange.upperBound - price) / denom
        return min(max(mainTop + CGFloat(ratio) * mainHeight, mainTop), mainBottom)
    }

    /// 第二个光标相对第一个固定光标的横轴价格涨幅（基于第二个光标横线所在位置的价格 与 第一个固定光标横轴的固定价格；
    /// 第一个光标固定后平移/缩放会改变价格范围，必须用固定价格 pinnedPrice 作基准，否则用其像素反算会得到错误涨幅）
    func secondCursorPriceChange(y: CGFloat, pinnedY: CGFloat?, pinnedPrice: Double?,
                                         mainTop: CGFloat, mainBottom: CGFloat, mainHeight: CGFloat) -> Double? {
        // 第一个光标的横轴价格：优先用固定价格；未固定（不在主图区域）时退化为按像素反算（通常为 nil）
        let p1: Double?
        if let pp = pinnedPrice, pp > 0 {
            p1 = pp
        } else {
            guard let pinnedY else { return nil }
            p1 = priceAtY(pinnedY, mainTop: mainTop, mainBottom: mainBottom, mainHeight: mainHeight)
        }
        guard let p1,
              let p2 = priceAtY(y, mainTop: mainTop, mainBottom: mainBottom, mainHeight: mainHeight),
              p1 > 0 else { return nil }
        return (p2 - p1) / p1 * 100
    }

// MARK: - 光标标签 Y 定位与横线避让区间

    func cursorTopLabelY(hasSecondLine: Bool, height: CGFloat) -> CGFloat {
        let half: CGFloat = hasSecondLine ? 15 : 8
        return min(max(half, 8), max(half, height - half))
    }

    /// 主图竖轴底部标签的垂直位置：单行时保持原底部对齐；两行（第二个光标）时整体上移，让标签完全落在主图内、底部不外溢
    func cursorBottomLabelY(hasSecondLine: Bool, height: CGFloat) -> CGFloat {
        let half: CGFloat = hasSecondLine ? 15 : 9
        return min(max(height - half, half), max(half, height - 8))
    }

    /// 标签居中对齐后的实际中心 x（由 crosshairLabelAlignment 的对齐结果换算成中心坐标）
    func labelCenter(_ align: Alignment, offset: CGFloat, labelWidth: CGFloat, width: CGFloat) -> CGFloat {
        switch align {
        case .leading: return labelWidth / 2
        case .trailing: return width - labelWidth / 2
        default: return width / 2 + offset
        }
    }

    /// 计算单个光标竖线标签（顶部日期/底部涨幅）与横线重叠时，横线需要让开的横向区间；
    /// 不重叠时返回 nil（横线完整绘制）。横线坐标 cy 为整图坐标，标签按 mainTop 换算。
    func cursorLabelGap(index: Int, compare: Int?, cy: CGFloat,
                                candleSpacing: CGFloat, width: CGFloat,
                                mainTop: CGFloat, mainHeight: CGFloat) -> ClosedRange<CGFloat>? {
        guard index >= startIndex, index <= endIndex else { return nil }
        let xPos = (CGFloat(index - startIndex) + 0.5) * candleSpacing
        let stats = compare.flatMap { pinnedRangeStats(index, $0) }
        // 顶部日期标签：与该光标竖线顶部标签同尺寸同位置，重叠时在标签横向区间断开横线
        let dateText = sortedData[index].formattedDateWithWeekday
        let dateLine2 = stats.map { String(format: "%.2f%%  %+.2f%%  %+.2f%%  %+.2f%%", $0.amplitude, $0.drawdown, $0.rally, $0.change) }
        let dateW = dateLine2.map { labelTextWidth($0, fontSize: 10) } ?? labelTextWidth(dateText, fontSize: 10)
        let dateHalf: CGFloat = stats != nil ? 15 : 8
        let dateCenterY = mainTop + cursorTopLabelY(hasSecondLine: stats != nil, height: mainHeight)
        if cy >= dateCenterY - dateHalf && cy <= dateCenterY + dateHalf {
            let (a, o) = crosshairLabelAlignment(x: xPos, labelWidth: dateW, width: width)
            let c = labelCenter(a, offset: o, labelWidth: dateW, width: width)
            return (c - dateW / 2)...(c + dateW / 2)
        }
        // 底部涨幅标签：同理（联动复盘时收盘价取合成K线）
        let displayClose = cursorDisplayItem(at: index).close
        if let last = sortedData.last, last.close > 0, displayClose > 0 {
            let pct = (last.close - displayClose) / displayClose * 100
            let periodCount = max(0, (sortedData.count - 1) - index)
            let pctLine2 = stats.map { String(format: "%@  %@", formatVolume($0.volSum), formatAmount($0.amoSum)) }
            let pctW = pctLine2.map { labelTextWidth($0, fontSize: 10) } ?? labelTextWidth(String(format: "%+.2f%%  %d", pct, periodCount), fontSize: 10)
            let pctHalf: CGFloat = pctLine2 != nil ? 15 : 9
            let pctCenterY = mainTop + cursorBottomLabelY(hasSecondLine: pctLine2 != nil, height: mainHeight)
            if cy >= pctCenterY - pctHalf && cy <= pctCenterY + pctHalf {
                let (a, o) = crosshairLabelAlignment(x: xPos, labelWidth: pctW, width: width)
                let c = labelCenter(a, offset: o, labelWidth: pctW, width: width)
                return (c - pctW / 2)...(c + pctW / 2)
            }
        }
        return nil
    }

    /// 横线需要让开的横向区间数组：收集当前光标自己的竖线标签 + 对方光标的竖线标签中与横线重叠的全部区间；
    /// 两个光标的日期标签都在主图顶部、涨幅标签都在底部，横线到达时可能同时穿过多个标签，需全部断开。
    func crosshairLineGap(index: Int?, compare: Int?, otherIndex: Int?, otherCompare: Int?,
                                  cy: CGFloat, candleSpacing: CGFloat, width: CGFloat,
                                  mainTop: CGFloat, mainHeight: CGFloat) -> [ClosedRange<CGFloat>] {
        var gaps: [ClosedRange<CGFloat>] = []
        if let index, let gap = cursorLabelGap(index: index, compare: compare, cy: cy,
                                               candleSpacing: candleSpacing, width: width,
                                               mainTop: mainTop, mainHeight: mainHeight) {
            gaps.append(gap)
        }
        if let otherIndex, let gap = cursorLabelGap(index: otherIndex, compare: otherCompare, cy: cy,
                                                    candleSpacing: candleSpacing, width: width,
                                                    mainTop: mainTop, mainHeight: mainHeight) {
            gaps.append(gap)
        }
        return gaps
    }

}

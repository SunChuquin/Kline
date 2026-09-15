//
//  ChartOverlayKit.swift
//  Kline
//
//  图表覆盖层的纯渲染叶子组件（props 驱动 + Equatable）：
//  光标横线标签、副图光标竖线、副图滑动切换反馈。
//  从 KlineChartView.swift / ChartGestureSupport.swift 的构建方法 struct 化而来，
//  全部组件不持有任何状态、不访问视图成员，配合调用点 .equatable() 跳过无效重绘。
//

import SwiftUI

/// 判断 y 是否落在 [top, bottom] 面板区间内（覆盖层/手势共用的几何判定）
func isInPanel(_ y: CGFloat, _ top: CGFloat, _ bottom: CGFloat) -> Bool { y >= top && y <= bottom }

// MARK: - 十字光标横线 + 数值标签

/// 十字光标横线 + 背景数值标签（横线从数值背景的最左边开始画起，贯穿全宽）
/// secondLine 非 nil 时，第二行显示光标对比多出的内容（如两光标间涨幅）；
/// gapRanges 非 nil 时，横线在这些横向区间断开（不画在竖线顶部日期标签/底部涨幅标签上）
struct CrosshairLineOverlay: View, Equatable {
    let width: CGFloat
    let height: CGFloat
    let y: CGFloat
    let valueText: String
    var secondLine: String? = nil
    var gapRanges: [ClosedRange<CGFloat>]? = nil
    var bgColor: Color = Color(red: 0.35, green: 0.75, blue: 1.0)
    var lineColor: Color = Color.black.opacity(0.45)

    /// 先算出横线需要绘制的非标签区间（合并重叠的标签区间后，取其余部分；无标签时整条）
    private var nonLabelSegments: [ClosedRange<CGFloat>] {
        guard let gaps = gapRanges, !gaps.isEmpty else { return [0...width] }
        var merged: [ClosedRange<CGFloat>] = []
        for g in gaps.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let g0 = min(max(0, g.lowerBound), width)
            let g1 = min(max(0, g.upperBound), width)
            guard g1 > g0 else { continue }
            if let last = merged.last, g0 <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, g1)
            } else {
                merged.append(g0...g1)
            }
        }
        var result: [ClosedRange<CGFloat>] = []
        var x: CGFloat = 0
        for g in merged {
            if g.lowerBound > x { result.append(x...g.lowerBound) }
            x = max(x, g.upperBound)
        }
        if x < width { result.append(x...width) }
        return result
    }

    var body: some View {
        let segments = nonLabelSegments
        ZStack(alignment: .topLeading) {
            // 横轴虚线：从数值背景的最左边（x=0）开始画起；按区间逐段绘制，跳过所有标签区间
            ForEach(segments, id: \.lowerBound) { seg in
                Rectangle().fill(lineColor)
                    .frame(width: max(0, seg.upperBound - seg.lowerBound), height: 1.0)
                    .position(x: (seg.lowerBound + seg.upperBound) / 2, y: y)
            }
            if let secondLine {
                // 两行：第一行价格/数值，第二行光标对比信息
                VStack(spacing: 1) {
                    Text(valueText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.top, 1)
                    Text(secondLine)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 1)
                }
                .background(bgColor)
                .offset(y: y - 15)
            } else {
                // 光标数值：背景矩形（高=字体高度、宽=内容宽度），白字加粗，比主图坐标数值大一号
                Text(valueText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .background(bgColor)
                    .offset(y: y - 6)
            }
        }
    }
}

// MARK: - 副图光标竖线

/// 副图单个光标的竖线（可交互光标与固定光标共用；第二个光标蓝色、固定光标黑色；
/// secondary=联动范围框视图的本地第二光标，同样蓝色）
struct SubCursorVLine: View, Equatable {
    let startIndex: Int
    let endIndex: Int
    let index: Int?
    let compare: Int?
    let candleSpacing: CGFloat
    let height: CGFloat
    var secondary: Bool = false

    var body: some View {
        if let index, index >= startIndex, index <= endIndex {
            let xPosition = (CGFloat(index - startIndex) + 0.5) * candleSpacing
            Rectangle().fill((compare != nil || secondary) ? Color.blue : Color.black.opacity(0.45))
                .frame(width: 1.0, height: height)
                .position(x: xPosition, y: height / 2)
        }
    }
}

// MARK: - 副图滑动切换反馈

/// 副图左右滑动切换反馈：拖动时才显示方向箭头 + 滑轨/滑块/阈值动画。
/// 仅副图1/2 挂载（调用点保证）；副图三面板手势整体禁用（虚拟按钮预留区），不会进入本组件，
/// 此处 `slot != .third` 为双保险。滑动状态与两个方向的可用性由调用点计算传入（保持本组件纯渲染）。
struct SwipeOverlay: View, Equatable {
    let slot: SubSlot
    let fb: SwipeFeedback?
    let canL: Bool
    let canR: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        if slot != .third {
            let isDragging = fb?.slot == slot && (fb?.offset ?? 0).magnitude > 1
            let off = isDragging ? (fb?.offset ?? 0) : 0
            let threshold: CGFloat = 70
            ZStack {
            // 方向箭头提示：仅拖动中显示（滑动条出现前不显示），可切换方向高亮，边界方向灰显
            if isDragging {
                HStack {
                    SwipeDirectionArrow(system: "chevron.left", can: canL,
                                        active: off < 0)
                    Spacer()
                    SwipeDirectionArrow(system: "chevron.right", can: canR,
                                        active: off > 0)
                }
                .padding(.horizontal, 8)
            }

            // 拖动中的滑轨动画
            if isDragging {
                let dir: CGFloat = off > 0 ? 1 : -1
                let reachable = off > 0 ? canR : canL
                let dist = min(abs(off), threshold)
                let cx = width / 2
                let ready = abs(off) > threshold
                let color: Color = reachable ? (ready ? Color.green : Color.white.opacity(0.9)) : Color.red
                // 轨道（从中心向拖动方向延伸）
                Capsule()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: dist, height: 6)
                    .position(x: cx + dir * dist / 2, y: height / 2)
                // 阈值刻度线
                if reachable {
                    Rectangle()
                        .fill(Color.white.opacity(0.7))
                        .frame(width: 1.5, height: 12)
                        .position(x: cx + dir * threshold, y: height / 2)
                }
                // 滑块
                Circle()
                    .fill(color)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1))
                    .shadow(radius: 1)
                    .position(x: cx + dir * dist, y: height / 2)
                // 状态文字：超过阈值提示松手切换，未到阈值提示继续拖动，不可切换方向提示边界
                let text = reachable ? (ready ? "松开切换" : "继续拖动") : "无法切换"
                let textColor: Color = (reachable && !ready) ? Color.black : Color.white
                Text(text)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(textColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(color)
                    .cornerRadius(3)
                    .position(x: cx + dir * dist, y: height / 2 - 16)
            }
            }
            .allowsHitTesting(false)
        }
    }
}

/// 副图滑动方向提示箭头
struct SwipeDirectionArrow: View, Equatable {
    let system: String
    let can: Bool
    let active: Bool

    var body: some View {
        Image(systemName: can ? system : (system + ".circle"))
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(can ? (active ? Color.white : Color.black.opacity(0.35)) : Color.gray.opacity(0.25))
            .frame(width: 22, height: 22)
            .background(can ? Color.black.opacity(active ? 0.5 : 0.08) : Color.clear)
            .clipShape(Circle())
    }
}

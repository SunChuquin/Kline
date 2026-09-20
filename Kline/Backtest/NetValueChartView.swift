//
//  NetValueChartView.swift
//  Kline
//
//  回测净值曲线手绘视图：等距 x + 归一化 y 的折线 / 渐变填充，叠加最大回撤区间高亮与初始资金基线。
//
//  Created by 孙楚昆 on 2026/9/20.
//

import SwiftUI

/// 净值曲线（iOS 15 无 Swift Charts，用 GeometryReader + Path 手绘）
///
/// 入参全为 `Equatable` 值类型，避免父视图重绘时频繁重算路径。
/// `baseline` 为初始资金基线（默认 nil 时退化为首点净值）。
struct NetValueChartView: View {
    var points: [BacktestEquityPoint]
    var maxDrawdownRange: ClosedRange<Int>?
    var height: CGFloat = 160
    /// 初始资金水平基线（取不到时用首点净值兜底）
    var baseline: Double? = nil

    var body: some View {
        Group {
            if points.isEmpty {
                placeholder
            } else {
                chart
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 空态

    private var placeholder: some View {
        Text("暂无净值数据")
            .font(.system(size: 12))
            .foregroundColor(Color(.secondaryLabel))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 曲线

    private var chart: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let n = points.count
            let values = points.map { $0.equity }
            let base = baseline ?? values.first ?? 0

            // 归一化取值范围（把基线一并纳入，避免基线画到框外）
            let minV = min(values.min() ?? base, base)
            let maxV = max(values.max() ?? base, base)
            let span = maxV - minV

            let px: (Int) -> CGFloat = { i in
                n <= 1 ? 0 : CGFloat(i) / CGFloat(n - 1) * w
            }
            let py: (Double) -> CGFloat = { v in
                span <= 0 ? h / 2 : h - CGFloat((v - minV) / span) * h
            }

            ZStack(alignment: .topLeading) {
                // 最大回撤区间：半透明红块（engine 输出的就是 equity 下标区间，直接映射到 x）
                if let range = maxDrawdownRange, !points.isEmpty {
                    let i0 = min(max(range.lowerBound, 0), points.count - 1)
                    let i1 = min(max(range.upperBound, 0), points.count - 1)
                    if i1 >= i0 {
                        let x0 = px(i0)
                        let x1 = px(i1)
                        Rectangle()
                            .fill(Color.red.opacity(0.12))
                            .frame(width: max(x1 - x0, 2), height: h)
                            .offset(x: x0)
                    }
                }

                // 折线下方渐变填充
                fillPath(n: n, w: w, h: h, px: px, py: py, values: values)
                    .fill(LinearGradient(colors: [Color.blue.opacity(0.18), Color.blue.opacity(0.0)],
                                         startPoint: .top, endPoint: .bottom))

                // 折线
                linePath(n: n, px: px, py: py, values: values)
                    .stroke(Color.blue, lineWidth: 1.5)

                // 初始资金基线（水平虚线）
                Path { p in
                    let y = py(base)
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: w, y: y))
                }
                .stroke(Color.gray.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        // 顶部标注最大值、底部标注最小值（放在对侧角落，避免压住曲线）
        .overlay(alignment: .topLeading) { axisLabel(maxLabel, alignment: .leading) }
        .overlay(alignment: .bottomTrailing) { axisLabel(minLabel, alignment: .trailing) }
    }

    // MARK: - 路径

    private func linePath(n: Int, px: (Int) -> CGFloat, py: (Double) -> CGFloat,
                          values: [Double]) -> Path {
        Path { p in
            guard n > 0 else { return }
            p.move(to: CGPoint(x: px(0), y: py(values[0])))
            for i in 1..<max(n, 1) {
                p.addLine(to: CGPoint(x: px(i), y: py(values[i])))
            }
        }
    }

    private func fillPath(n: Int, w: CGFloat, h: CGFloat,
                          px: (Int) -> CGFloat, py: (Double) -> CGFloat,
                          values: [Double]) -> Path {
        Path { p in
            guard n > 0 else { return }
            p.move(to: CGPoint(x: px(0), y: py(values[0])))
            for i in 1..<max(n, 1) {
                p.addLine(to: CGPoint(x: px(i), y: py(values[i])))
            }
            p.addLine(to: CGPoint(x: px(n - 1), y: h))
            p.addLine(to: CGPoint(x: px(0), y: h))
            p.closeSubpath()
        }
    }

    // MARK: - 标注

    private func axisLabel(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Color(.secondaryLabel))
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var maxLabel: String {
        guard let v = points.map({ $0.equity }).max() else { return "" }
        return "最高 " + SimFormat.amount0(v)
    }

    private var minLabel: String {
        guard let v = points.map({ $0.equity }).min() else { return "" }
        return "最低 " + SimFormat.amount0(v)
    }
}
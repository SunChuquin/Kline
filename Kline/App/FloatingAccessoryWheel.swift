//
//  FloatingAccessoryWheel.swift
//  Kline
//
//  第二个悬浮按钮（下称「新按钮」）：三圆结构 A'/B'/C'。A' 与 B' 同心、仅 1pt 内描边，
//  两者之间的环 Z' 保持透明；C' 是环内的一枚实心点，位置由角度参数决定。
//  本阶段只落地外壳、几何与落位（点击 / 拖动 / 转圈手势与 K 线光标联动在后续阶段接入）。
//  共用的几何 / 描边常量、落位计算与持久化见 FloatingAccessoryShared.swift。
//

import Foundation
import SwiftUI

/// 新按钮（转圈驱动 K 线光标的那个）
/// - 几何：A' = B' + 2 × 环 Z'，B' = 旧按钮 A × 1.3，环 Z' 宽 = 旧按钮 D 直径，C' = 环宽 − 1；
///   全部由 FloatingAccessoryMetrics 派生（派生式与自洽性校验见该处注释）
/// - 外观：A' / B' 仅用语义色 label 描边，环 Z' 透明，C' 用同一语义色实心（+1pt 外描边走满环宽）
/// - 命中区：A' 围出的圆盘（即 B' 盘 ∪ 环 Z' 环带）
/// - 落位：默认落在旧按钮的对侧；启动 / 尺寸变化时若两按钮同侧，强制移回旧按钮的对侧
struct FloatingAccessoryWheel: View {

    /// C' 当前角度（度）：-90° 为 12 点方向；后续阶段由环上转圈手势驱动（顺时针对应光标右移）
    @State private var angleDegrees: Double = -90

    /// 已落位的中心点；nil 表示尚未初始化（onAppear 时按持久化值或默认落位解析）
    @State private var center: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let bounds = FloatingAccessoryPlacement.bounds(in: geo.size, diameter: FloatingAccessoryMetrics.wheelOuterDiameter)
            let base = FloatingAccessoryPlacement.clamped(center ?? resolvedCenter(in: geo.size, bounds: bounds), in: bounds)
            disc
                // 命中形状按规格取「A' 圆盘」：A'/B' 都只是 1pt 描边，若用默认命中区域
                // 可点到的只有描边那一圈细线；规格里「大圆 A' 本身不接收任何手势」按
                // 「A' 的描边没有独立行为」理解 —— A' 只提供轮廓与命中范围，
                // 真正的可交互区域仍是它围出的整个圆盘（盘内细分见后续阶段的手势判定）
                .contentShape(Circle())
                .position(base)
                .onAppear {
                    center = FloatingAccessoryPlacement.clamped(center ?? resolvedCenter(in: geo.size, bounds: bounds), in: bounds)
                }
                // 尺寸变化（旋转 / 分屏 / 多任务）后把已落位点夹回可视范围，避免停在屏幕外
                .onChange(of: geo.size) { _ in
                    let b = FloatingAccessoryPlacement.bounds(in: geo.size, diameter: FloatingAccessoryMetrics.wheelOuterDiameter)
                    center = FloatingAccessoryPlacement.clamped(center ?? resolvedCenter(in: geo.size, bounds: b), in: b)
                }
                .accessibilityIdentifier("accessory2.button")
        }
    }

    /// A' / B' 两个同心圆 + 环内的 C'
    private var disc: some View {
        let outer = FloatingAccessoryMetrics.wheelOuterDiameter
        let inner = FloatingAccessoryMetrics.wheelInnerDiameter
        let stroke = FloatingAccessoryMetrics.ringStroke
        let strokeWidth = FloatingAccessoryMetrics.ringStrokeWidth
        return ZStack {
            // A' 与 B' 都无填充、只用语义色内描边；两者之间的环 Z' 因此天然透明
            Circle()
                .strokeBorder(stroke, lineWidth: strokeWidth)
                .frame(width: outer, height: outer)
            Circle()
                .strokeBorder(stroke, lineWidth: strokeWidth)
                .frame(width: inner, height: inner)
            dot
        }
        .frame(width: outer, height: outer)
    }

    /// 环 Z' 内的实心点 C'
    /// - 环 Z' 不能照搬旧按钮最外环 Z 的「纯黑填充」：浅色模式下 C' 也是 Color(.label)（=黑），
    ///   同色会让 C' 完全不可见，故 Z' 保持透明，只靠 A'/B' 两道描边勾出环带
    /// - C' 本体直径 27，另加 1pt 外描边（.stroke 骑在圆周上、向外扩 0.5/侧）后视觉直径 28 = 环 Z' 宽，
    ///   这正是「C' 与环内外边界各余 0.5」的来源
    private var dot: some View {
        let radians = CGFloat(angleDegrees) * .pi / 180
        return Circle()
            .fill(FloatingAccessoryMetrics.ringStroke)
            .frame(width: FloatingAccessoryMetrics.wheelDotDiameter, height: FloatingAccessoryMetrics.wheelDotDiameter)
            .overlay(Circle().stroke(FloatingAccessoryMetrics.ringStroke,
                                     lineWidth: FloatingAccessoryMetrics.wheelDotStrokeWidth))
            // 圆心走在环的中径上：右下为正 x / 正 y，故 -90° 落在 12 点方向
            .offset(x: FloatingAccessoryMetrics.wheelDotTrackRadius * cos(radians),
                    y: FloatingAccessoryMetrics.wheelDotTrackRadius * sin(radians))
    }

    /// 落位解析：新按钮始终落在旧按钮所在侧的**对侧**
    /// - 旧按钮从未被拖动过 → 它按默认落位停在右侧，故新按钮落在左侧
    /// - 旧按钮已持久化 → 取其当前侧的对侧
    /// - 自身已保存的落位若恰在目标侧则沿用（只做夹取），否则强制移到目标侧边缘：
    ///   这就是「启动时发现两按钮同侧则矫正」的实现（矫正结果不写回 UserDefaults，
    ///   下次启动按同样规则重算，不污染新按钮的既有落位）
    private func resolvedCenter(in size: CGSize, bounds: FloatingAccessoryPlacement.Bounds) -> CGPoint {
        let oldSide: FloatingAccessoryPlacement.Side
        if let oldCenter = FloatingAccessoryStore.savedCenter(for: .primary) {
            oldSide = FloatingAccessoryPlacement.side(of: oldCenter, in: size)
        } else {
            oldSide = .right
        }
        let desiredSide = oldSide.opposite
        if let saved = FloatingAccessoryStore.savedCenter(for: .secondary),
           FloatingAccessoryPlacement.side(of: saved, in: size) == desiredSide {
            return FloatingAccessoryPlacement.clamped(saved, in: bounds)
        }
        return FloatingAccessoryPlacement.edgeCenter(on: desiredSide, in: size, bounds: bounds)
    }
}
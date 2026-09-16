//
//  ChartInertiaSupport.swift
//  Kline
//
//  K线主图横向惯性滑动：CADisplayLink 驱动的**固定匀速直线**动画。
//  规则刻意简单，只有两种结果：
//  - 不惯性：抬手速度低于阈值（慢速拖动），立即对齐停止；
//  - 惯性：一旦触发，行为完全固定——沿抬手方向以「一屏/秒」匀速滑行，
//    2 秒走 2 个屏幕的K线数，到点直接停在对齐的K线位置；
//    与甩手力度、缩放级别均无关。途中撞到数据边界就立即停（无过冲、无回弹）。
//
//  惯性中的平移推进与拖动手势 pan 分支同构（panOffset 亚像素累计、满一根K线
//  间距进位 endOffset），因此每帧画面与手指拖动无差异，不会出现卡顿或跳跃。
//

import SwiftUI
import UIKit
import QuartzCore

/// 横向惯性滑动动画器：CADisplayLink 每帧按固定匀速推进固定时长。
///
/// 位移 s(t) = v·t（v 为带符号常量速度，右正左负），t ∈ [0, fixedDuration]。
/// 每帧位移按绝对时间 s(t) - s(t-帧) 计算，不依赖固定帧率，掉帧不产生漂移。
final class ChartMomentumAnimator: NSObject {
    /// 触发惯性的最低抬手速度（px/s）：低于该值不惯性，抬手直接对齐停止
    static let minVelocity: CGFloat = 10
    /// 惯性固定时长（s）
    static let fixedDuration: Double = 2.0
    /// 惯性固定滑行距离（屏幕数）
    static let travelScreens: CGFloat = 2

    /// 带符号匀速（px/s，右正左负），start() 前赋值
    var velocity: CGFloat = 0
    /// 每帧推进：把位移增量应用到图表平移。返回 false = 撞到数据边界，立即结束
    var onAdvance: ((CGFloat) -> Bool)?
    /// 结束收尾（自然到点 / 触边立即停，对齐 + 重算/预取）
    var onFinish: (() -> Void)?

    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var lastPosition: CGFloat = 0
    private var finished = false

    /// 启动动画（主线程调用）。时间基准立即生效，第一帧 link 回调即有位移，无起步空档
    func start() {
        guard !finished, velocity != 0 else { return }
        startTime = CACurrentMediaTime()
        lastPosition = 0
        let l = CADisplayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// 终止动画（幂等）。CADisplayLink 持有 target，必须 invalidate 才能释放。
    func cancel() {
        finished = true
        link?.invalidate()
        link = nil
    }

    deinit { link?.invalidate() }

    @objc private func step(_ l: CADisplayLink) {
        guard !finished else { return }
        let now = l.timestamp
        let t = min(now - startTime, Self.fixedDuration)
        let target = velocity * CGFloat(t)
        let dx = target - lastPosition
        lastPosition = target
        var hitBoundary = false
        if dx != 0 { hitBoundary = !(onAdvance?(dx) ?? true) }
        if t >= Self.fixedDuration || hitBoundary {
            cancel()
            onFinish?()
        }
    }
}

// MARK: - KlineChartView 惯性滑动接口

extension KlineChartView {

    /// 抬手启动横向惯性滑动。返回是否启动（false = 速度不足/前方无K线空间等，调用方走原对齐路径）。
    ///
    /// 一旦触发行为固定：速度 = ±1 屏宽/秒（即 2 秒走 2 屏K线），与甩手力度、缩放级别无关；
    /// 为保证停在整数根K线上，速度会按抬手时的亚像素残差做不可察觉的等比修正；
    /// 途中 endOffset 到数据边界则立即停，无过冲、无回弹。
    @discardableResult
    func startPanInertia(velocity velocityIn: CGFloat, width: CGFloat, candleSpacing: CGFloat) -> Bool {
        cancelPanInertia()
        guard !menuIsOpen else { return false }
        guard abs(velocityIn) >= ChartMomentumAnimator.minVelocity, candleSpacing > 0, !sortedData.isEmpty else { return false }

        let sp = candleSpacing
        let maxEndOffset = max(0, sortedData.count - count)
        let sgn: CGFloat = velocityIn >= 0 ? 1 : -1
        // 沿运动方向还剩多少根K线可走；连一根都没有则不惯性（调用方立即对齐）
        let candlesAhead = sgn > 0 ? (maxEndOffset - endOffset) : endOffset
        guard candlesAhead >= 1 else { return false }

        // 期望位移：2 屏宽 − 抬手亚像素残差（沿运动方向折算），使 2 秒终点恰为整数根K线对齐点。
        // 速度 = 位移 / 2 秒 ≈ 1 屏宽/秒（残差修正 ≤ 半根间距，肉眼不可察）。
        let residueAlong = sgn > 0 ? panOffset : -panOffset
        let travel = ChartMomentumAnimator.travelScreens * width - residueAlong
        guard travel > 0 else { return false }
        let v = sgn * travel / CGFloat(ChartMomentumAnimator.fixedDuration)

        let animator = ChartMomentumAnimator()
        animator.velocity = v
        animator.onAdvance = { [self] dx in
            // 触边帧把本帧位移截到「恰好到边界对齐点」，停得干脆且残差清零无可视跳变
            let room: CGFloat = sgn > 0
                ? CGFloat(maxEndOffset - endOffset) * sp - panOffset
                : CGFloat(endOffset) * sp + panOffset
            if abs(dx) >= room {
                if room > 0 {
                    panOffset += sgn * room
                    let shift = Int((panOffset / sp).rounded())
                    if shift != 0 {
                        endOffset = clamp(endOffset + shift, 0, maxEndOffset)
                        panOffset -= CGFloat(shift) * sp
                    }
                }
                return false
            }
            // 与拖动手势 pan 分支完全相同的亚像素累计进位平移
            panOffset += dx
            let shift = Int((panOffset / sp).rounded())
            guard shift != 0 else { return true }
            let newOffset = clamp(endOffset + shift, 0, maxEndOffset)
            let applied = newOffset - endOffset
            endOffset = newOffset
            panOffset -= CGFloat(applied) * sp
            // applied != shift = endOffset 已到数据边界：惯性立即结束，无过冲无回弹
            return applied == shift
        }
        animator.onFinish = { [self] in
            drag.momentum = nil
            // 直接停在对齐位置（自然到点时残差理论为 0；触边帧兜底清零，跳变 ≤ 本帧位移）
            if panOffset != 0 { panOffset = 0 }
            refreshCurves()
            startPrefetch()
        }
        drag.momentum = animator
        animator.start()
        return true
    }

    /// 终止进行中的惯性滑动并立即对齐（panOffset 归零，跳变 ≤ 半根K线间距，与拖动结束行为一致）。
    /// 未在惯性中时为空操作。
    func cancelPanInertia() {
        guard drag.momentum != nil else { return }
        drag.momentum?.cancel()
        drag.momentum = nil
        panOffset = 0
    }
}

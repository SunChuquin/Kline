//
//  ChartInertiaSupport.swift
//  Kline
//
//  K线主图横向惯性滑动：抬手速度采样 → CADisplayLink 驱动的两段式动量动画。
//  观感对齐行情页表格（原生 ScrollView）快速滑动抬手后的惯性运动：
//  - 保持抬手前的滑动方向；
//  - 以预设区间内的初速开始（幅值取自用户抬手速度并封顶，力度越大滑得越远）；
//  - 匀速滑行预设倒计时后进入减速段；
//  - 减速段速度单调衰减到 0，平滑停止在最近K线对齐的目标位置（数据边界则过冲回弹对齐）。
//
//  惯性中的平移推进与拖动手势 pan 分支完全同构（panOffset 亚像素累计、满一根K线
//  间距进位 endOffset），因此每帧画面与手指拖动无差异，不会出现卡顿或跳跃。
//

import SwiftUI
import UIKit
import QuartzCore

/// 横向惯性滑动动画器：CADisplayLink 每帧按位移曲线推进。
///
/// 位移曲线（v0 = 抬手速度，右为正）：
/// - 匀速阶段 [0, T1]：s(t) = v0·t；
/// - 减速阶段 [T1, T1+T2]：v(u) = v0·(1-u)²（u 为阶段进度），s = v0·T1 + v0·T2·(1-(1-u)³)/3。
///   交界处速度连续（同为 v0），结束时速度为 0，全程 C1 连续 → 无速度突变/跳跃。
/// 每帧位移按绝对时间 s(t) - s(t-帧) 计算，不依赖固定帧率，掉帧不产生漂移。
final class ChartMomentumAnimator: NSObject {
    /// 触发惯性的最低抬手速度（px/s）：低于该值视为慢速拖动，抬手直接对齐停止
    static let minVelocity: CGFloat = 350
    /// 初速上限（px/s）：极快甩动封顶，保证「力度 → 滑行距离」合理关联
    static let maxVelocity: CGFloat = 3500
    /// 匀速滑行时长（s）：预设的惯性运动倒计时
    static let uniformDuration: Double = 0.25
    /// 减速时长（s）
    static let decelDuration: Double = 0.45

    /// 抬手速度（px/s，右正左负），start() 前赋值
    var velocity: CGFloat = 0
    /// 每帧推进：把位移增量应用到图表平移。返回 false = 撞到数据边界，立即结束
    var onAdvance: ((CGFloat) -> Bool)?
    /// 自然减速结束后的收尾（对齐残差 + 重算/预取）
    var onNaturalEnd: (() -> Void)?
    /// 撞数据边界后的收尾（过冲回弹 + 重算/预取）
    var onBoundaryEnd: (() -> Void)?

    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var lastTime: CFTimeInterval = 0
    private var lastPosition: CGFloat = 0
    private var finished = false

    /// 位移曲线：先匀速 T1，再按 v(t)=v0·(1-u)² 减速 T2（速度连续、平滑停止）
    private func displacement(at t: Double) -> CGFloat {
        let v = velocity
        guard v != 0 else { return 0 }
        if t <= 0 { return 0 }
        if t <= Self.uniformDuration { return v * CGFloat(t) }
        let u = min(1.0, (t - Self.uniformDuration) / Self.decelDuration)
        let decay = (1 - u) * (1 - u) * (1 - u)   // (1-u)³
        return v * (CGFloat(Self.uniformDuration) + CGFloat(Self.decelDuration * (1 - decay) / 3))
    }

    /// 启动动画（主线程调用）
    func start() {
        guard !finished, velocity != 0 else { return }
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
        if lastTime == 0 { lastTime = now; startTime = now; return }
        lastTime = now
        let total = Self.uniformDuration + Self.decelDuration
        let t = min(now - startTime, total)
        let target = displacement(at: t)
        let dx = target - lastPosition
        lastPosition = target
        var hitBoundary = false
        if dx != 0 { hitBoundary = !(onAdvance?(dx) ?? true) }
        if t >= total || hitBoundary {
            cancel()
            if hitBoundary { onBoundaryEnd?() } else { onNaturalEnd?() }
        }
    }
}

// MARK: - KlineChartView 惯性滑动接口

extension KlineChartView {

    /// 抬手启动横向惯性滑动。返回是否启动（false = 速度不足/菜单打开等，调用方走原对齐路径）。
    ///
    /// - 速度方向保持抬手前方向，幅值取抬手实测速度并按预设 [min, max] 封顶；
    /// - 推进复用拖动手势的亚像素累计进位平移（panOffset 累计满一根K线间距进位 endOffset）；
    /// - 撞数据边界（endOffset 到钳制值）→ 过冲回弹收尾；自然减速到 0 → 最近K线对齐收尾。
    @discardableResult
    func startPanInertia(velocity: CGFloat, width: CGFloat, candleSpacing: CGFloat) -> Bool {
        cancelPanInertia()
        guard !menuIsOpen else { return false }
        let vMax = ChartMomentumAnimator.maxVelocity
        let v = clamp(velocity, -vMax, vMax)
        guard abs(v) >= ChartMomentumAnimator.minVelocity, candleSpacing > 0, !sortedData.isEmpty else { return false }

        let animator = ChartMomentumAnimator()
        animator.velocity = v
        animator.onAdvance = { [self] dx in
            // 与拖动手势 pan 分支完全相同的亚像素累计进位平移
            panOffset += dx
            let maxOver = width / 10   // 与拖动一致：数据边界最多滑出屏幕宽度 1/10 的空白
            panOffset = clamp(panOffset, -maxOver, maxOver)
            let shift = Int((panOffset / candleSpacing).rounded())
            guard shift != 0 else { return true }
            let maxEndOffset = max(0, sortedData.count - count)
            let newOffset = clamp(endOffset + shift, 0, maxEndOffset)
            let applied = newOffset - endOffset
            endOffset = newOffset
            panOffset -= CGFloat(applied) * candleSpacing
            // applied != shift = endOffset 已到数据边界：惯性立即转入回弹收尾
            return applied == shift
        }
        animator.onNaturalEnd = { [self] in
            drag.momentum = nil
            // 平滑停在目标位置：残差进位到最近K线（进位本身视觉零移动），
            // 余下 ≤ 半根间距的亚像素残差缓动归零
            let shift = Int((panOffset / candleSpacing).rounded())
            if shift != 0 {
                let maxEndOffset = max(0, sortedData.count - count)
                let newOffset = clamp(endOffset + shift, 0, maxEndOffset)
                let applied = newOffset - endOffset
                endOffset = newOffset
                panOffset -= CGFloat(applied) * candleSpacing
            }
            if panOffset != 0 {
                withAnimation(.easeOut(duration: 0.15)) { panOffset = 0 }
            }
            refreshCurves()
            startPrefetch()
        }
        animator.onBoundaryEnd = { [self] in
            drag.momentum = nil
            // 数据边界：onAdvance 已把过冲钳制在 ≤ 1/10 屏空白内，缓动回弹对齐（类似原生滚动触边）
            withAnimation(.easeOut(duration: 0.25)) { panOffset = 0 }
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

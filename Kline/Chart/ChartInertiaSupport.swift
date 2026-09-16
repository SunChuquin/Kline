//
//  ChartInertiaSupport.swift
//  Kline
//
//  K线主图横向惯性滑动：抬手速度采样 → CADisplayLink 驱动的指数衰减动量动画。
//  观感对齐原生 UIScrollView 抬手后的惯性运动：
//  - 初速取自手指最后 ~0.07s 的瞬时末速度（短窗口最小二乘），保持抬手前方向；
//  - 速度按 v(t)=v0·e^(−t/τ) 指数衰减（无匀速段、无加速度拐点），力度越大滑得越远、越久；
//  - 启动前预测全程滑行距离，把终点吸附到整数根K线：曲线停稳的位置就是对齐位置，
//    不存在停稳后再挪一下的二次收尾；
//  - 滑到数据边界后进入 rubber-band 阻尼（越拉越重，硬钳制只兜底），衰减结束再用
//    spring 轻微回弹对齐（带一点原生式过冲）。
//
//  惯性中的平移推进与拖动手势 pan 分支同构（panOffset 亚像素累计、满一根K线
//  间距进位 endOffset），因此每帧画面与手指拖动无差异，不会出现卡顿或跳跃。
//

import SwiftUI
import UIKit
import QuartzCore

/// 横向惯性滑动动画器：CADisplayLink 每帧按位移曲线推进。
///
/// 指数衰减模型（v0 = 抬手速度，右为正，τ = 时间常数）：
/// - v(t) = v0·e^(−t/τ)；
/// - s(t) = k·v0·τ·(1−e^(−t/τ))，k 为终点吸附用的距离微调系数（≈1）；
/// - 速度降到 stopVelocity 即结束：T = τ·ln(|v0|/vStop)，总距离 S = τ·(|v0|−vStop)。
/// 距离/时长都与初速成正比，全程速度、加速度连续（无匀速→减速拐点）。
/// 每帧位移按绝对时间 s(t) - s(t-帧) 计算，不依赖固定帧率，掉帧不产生漂移。
final class ChartMomentumAnimator: NSObject {
    /// 触发惯性的最低抬手速度（px/s）：低于该值视为慢速拖动，抬手直接对齐停止
    static let minVelocity: CGFloat = 350
    /// 初速上限（px/s）：极快甩动封顶，保证「力度 → 滑行距离」合理关联
    static let maxVelocity: CGFloat = 3500
    /// 衰减时间常数 τ（s）：越大滑得越远（原生滚动约 0.25~0.4）
    static let timeConstant: Double = 0.3
    /// 结束速度（px/s）：瞬时速度低于此值即停（此时每帧位移已不可察觉）
    static let stopVelocity: CGFloat = 30
    /// 边界回弹 spring 参数（近似原生 UIScrollView 触边回弹，带轻微过冲）
    static let bounceResponse: Double = 0.3
    static let bounceDamping: Double = 0.82
    /// 触边过冲小于该幅度（px）时直接对齐，不起 spring（避免微幅抖动）
    static let bounceMinStretch: CGFloat = 1.5

    /// 抬手速度（px/s，右正左负），start() 前赋值
    var velocity: CGFloat = 0
    /// 终点吸附距离系数：实际位移曲线 = k × 自然衰减曲线（k≈1），start() 前赋值
    var displacementScale: CGFloat = 1
    /// 每帧推进：把位移增量应用到图表平移
    var onAdvance: ((CGFloat) -> Void)?
    /// 衰减结束后的收尾（边界回弹 / 重算 / 预取，由调用方按是否触边区分处理）
    var onFinish: (() -> Void)?

    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var lastPosition: CGFloat = 0
    private var totalDuration: Double = 0
    private var finished = false

    /// 自然衰减总时长：T = τ·ln(|v0|/vStop)
    private func duration(for v: CGFloat) -> Double {
        Self.timeConstant * log(Double(abs(v) / Self.stopVelocity))
    }

    /// 位移曲线：s(t) = k·v0·τ·(1−e^(−t/τ))
    private func displacement(at t: Double) -> CGFloat {
        let v = velocity
        guard v != 0, t > 0 else { return 0 }
        let decay = 1.0 - exp(-t / Self.timeConstant)
        return displacementScale * v * CGFloat(Self.timeConstant) * CGFloat(decay)
    }

    /// 启动动画（主线程调用）。时间基准立即生效，第一帧 link 回调即有位移，无起步空档
    func start() {
        guard !finished, velocity != 0 else { return }
        totalDuration = duration(for: velocity)
        guard totalDuration > 0, totalDuration.isFinite else { return }
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
        let t = min(now - startTime, totalDuration)
        let target = displacement(at: t)
        let dx = target - lastPosition
        lastPosition = target
        if dx != 0 { onAdvance?(dx) }
        if t >= totalDuration {
            cancel()
            onFinish?()
        }
    }
}

// MARK: - KlineChartView 惯性滑动接口

extension KlineChartView {

    /// 抬手启动横向惯性滑动。返回是否启动（false = 速度不足/无滑行空间等，调用方走原对齐路径）。
    ///
    /// - 速度方向保持抬手前方向，幅值取抬手实测末速度并按预设 [min, max] 封顶；
    /// - 预测指数衰减全程距离：不会触边时把距离吸附为整数根K线（k 微调），曲线终点即
    ///   对齐点，停稳后零二次动画；会触边时 k=1，自由段走完后转 rubber-band 阻尼，
    ///   结束再 spring 回弹；
    /// - 推进复用拖动手势的亚像素累计进位平移（panOffset 累计满一根K线间距进位 endOffset）。
    @discardableResult
    func startPanInertia(velocity: CGFloat, width: CGFloat, candleSpacing: CGFloat) -> Bool {
        cancelPanInertia()
        guard !menuIsOpen else { return false }
        let vMax = ChartMomentumAnimator.maxVelocity
        let v = clamp(velocity, -vMax, vMax)
        guard abs(v) >= ChartMomentumAnimator.minVelocity, candleSpacing > 0, !sortedData.isEmpty else { return false }

        let sp = candleSpacing
        let maxEndOffset = max(0, sortedData.count - count)
        let maxOver = width / 10   // 与拖动一致：数据边界最多滑出屏幕宽度 1/10 的空白
        let sgn: CGFloat = v >= 0 ? 1 : -1
        // rubber-band：y = r·x/(x+r)，导数随越界深入单调趋零（越拉越重），渐近线 r = maxOver
        let rubberRate = maxOver
        // 自然衰减全程距离 S = τ·(|v0|−vStop)
        let freeDistance = ChartMomentumAnimator.timeConstant * Double(abs(v) - ChartMomentumAnimator.stopVelocity)
        guard freeDistance > 0 else { return false }

        /// 当前位置沿 sgn 方向到「边界整数K线对齐点」的自由空间（px，可为负）
        func roomToEdge() -> CGFloat {
            if sgn > 0 {
                return CGFloat(maxEndOffset - endOffset) * sp - panOffset
            } else {
                return CGFloat(endOffset) * sp + panOffset
            }
        }

        let initialRoom = roomToEdge()
        let willReachEdge = CGFloat(freeDistance) > initialRoom
        // 终点吸附：自然结束场景把总距离圆整为整数根K线，且不超过剩余空间
        var scale: CGFloat = 1
        if !willReachEdge {
            let maxSteps = max(0, Int((initialRoom / sp).rounded(.down)))
            let steps = min(max(0, Int((CGFloat(freeDistance) / sp).rounded())), maxSteps)
            guard steps > 0 else { return false }
            scale = CGFloat(steps) * sp / CGFloat(freeDistance)
        }

        // 触边段状态：reachedEdge=已进入 rubber-band；overIn=原始越界输入累计；
        // maxStretch=实际产生过的最大拉伸（决定结束时要不要 spring 回弹）
        var reachedEdge = false
        var overIn: CGFloat = 0
        var maxStretch: CGFloat = 0

        /// 自由段推进：与拖动手势 pan 分支完全相同的亚像素累计进位平移
        func applyFree(_ d: CGFloat) {
            panOffset += d
            panOffset = clamp(panOffset, -maxOver, maxOver)
            let shift = Int((panOffset / sp).rounded())
            guard shift != 0 else { return }
            let newOffset = clamp(endOffset + shift, 0, maxEndOffset)
            let applied = newOffset - endOffset
            endOffset = newOffset
            panOffset -= CGFloat(applied) * sp
        }

        /// 越界段推进：把本帧原始增量 x 经 rubber-band 压缩后加到 panOffset（endOffset 已在边界）
        func applyRubber(_ x: CGFloat) {
            overIn += x
            let y = rubberRate * overIn / (overIn + rubberRate)
            maxStretch = max(maxStretch, y)
            panOffset = clamp(sgn * y, -maxOver, maxOver)
        }

        let animator = ChartMomentumAnimator()
        animator.velocity = v
        animator.displacementScale = scale
        animator.onAdvance = { [self] dx in
            if !reachedEdge {
                let room = roomToEdge()
                if abs(dx) <= room + 0.001 {
                    // 整帧都在自由空间
                    applyFree(dx)
                } else {
                    // 本帧跨边界：自由段精确走到 panOffset=0 的边界对齐点，剩余进入阻尼
                    let freePart = sgn * max(0, room)
                    if freePart != 0 { applyFree(freePart) }
                    reachedEdge = true
                    overIn = 0
                    // 抬手时若已有同向亚像素残差越过对齐点（room<0），把它折算成 rubber 输入初值，
                    // 视觉位置不跳变
                    if room < 0 {
                        let y0 = min(abs(panOffset), rubberRate * 0.9)
                        if y0 > 0 {
                            overIn = rubberRate * y0 / (rubberRate - y0)
                            maxStretch = y0
                        }
                    }
                    applyRubber(max(0, abs(dx) - max(0, room)))
                }
            } else {
                applyRubber(abs(dx))
            }
        }
        animator.onFinish = { [self] in
            drag.momentum = nil
            if reachedEdge {
                // 数据边界：spring 回弹对齐（轻微过冲，近似原生触边手感）；拉伸过小则直接对齐
                if maxStretch >= ChartMomentumAnimator.bounceMinStretch {
                    withAnimation(.spring(response: ChartMomentumAnimator.bounceResponse,
                                          dampingFraction: ChartMomentumAnimator.bounceDamping)) {
                        panOffset = 0
                    }
                } else {
                    panOffset = 0
                }
            } else {
                // 自然衰减：曲线终点已吸附在整数根K线，panOffset 理论上恰为 0，兜底清浮点残差，
                // 不需要任何二次对齐动画
                if abs(panOffset) > 0.01 { panOffset = 0 }
            }
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

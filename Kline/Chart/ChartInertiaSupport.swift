//
//  ChartInertiaSupport.swift
//  Kline
//
//  K线主图横向惯性滑动：CADisplayLink 驱动的**固定匀速直线**动画。
//  触发判定（见 DragState.releaseDirection）需同时满足四个条件：
//  ①抬手前没停住（≤0.2s）；②净滑动≥屏宽10%；③末段方向与主滑动同向；
//  ④末段速度未较峰值明显衰减（≥25%）。任一不满足即不惯性、立即对齐停止。
//  - 惯性：四条件满足——沿滑动主方向以「一屏/秒」匀速滑行，
//    2 秒走 2 个屏幕的K线数，到点直接停在对齐的K线位置；
//    与甩手力度、缩放级别均无关。途中撞到数据边界就立即停（无过冲、无回弹）。
//
//  惯性中的平移推进与拖动手势 pan 分支同构（panOffset 亚像素累计、满一根K线
//  间距进位 endOffset），因此每帧画面与手指拖动无差异，不会出现卡顿或跳跃。
//
//  另含「光标贴边自动拖动」：光标被推到主图可视边缘最后一根后，复用同一动画器
//  （duration = nil 无限）以「每秒一根K线」持续滚动可见窗口。**抬手不停**，直到该光标
//  被现有任何方式清除、手指反向退回主图内侧一半、或滚到数据边界自然停住
//  （见 startEdgeAutoScroll / stopEdgeAutoScroll）。
//

import SwiftUI
import UIKit
import QuartzCore

/// 横向惯性滑动动画器：CADisplayLink 每帧按固定匀速推进固定时长。
///
/// 位移 s(t) = v·t（v 为带符号常量速度，右正左负），t ∈ [0, fixedDuration]。
/// 每帧位移按绝对时间 s(t) - s(t-帧) 计算，不依赖固定帧率，掉帧不产生漂移。
final class ChartMomentumAnimator: NSObject {
    /// 惯性固定时长（s）
    static let fixedDuration: Double = 2.0
    /// 惯性固定滑行距离（屏幕数）
    static let travelScreens: CGFloat = 2
    /// 光标贴边「按住持续滚动」速度（K线根数/秒）：按住手指不动时的匀速滚动速度。
    /// 1 = 每秒推进一根K线（与惯性「1 屏/秒」相比慢得多，按住期间可逐步定位）。
    static let edgeAutoScrollCandlesPerSecond: CGFloat = 1

    /// 带符号匀速（px/s，右正左负），start() 前赋值
    var velocity: CGFloat = 0
    /// 本次动画时长（s）：默认 = fixedDuration（抬手甩动惯性）；
    /// nil = 无限（光标贴边「按住持续滚动」用，只能由 cancel() 或触边结束）
    var duration: Double? = ChartMomentumAnimator.fixedDuration
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
        // duration == nil：无限动画，位移随时间线性增长，直到 cancel() 或触边
        let elapsed = l.timestamp - startTime
        let t = duration.map { min(elapsed, $0) } ?? elapsed
        let target = velocity * CGFloat(t)
        let dx = target - lastPosition
        lastPosition = target
        var hitBoundary = false
        if dx != 0 { hitBoundary = !(onAdvance?(dx) ?? true) }
        if hitBoundary || (duration.map { t >= $0 } ?? false) {
            cancel()
            onFinish?()
        }
    }
}

// MARK: - KlineChartView 惯性滑动接口

extension KlineChartView {

    /// 抬手启动横向惯性滑动。返回是否启动（false = 非甩动抬手/前方无K线空间等，调用方走原对齐路径）。
    ///
    /// - Parameter direction: 惯性方向 +1（右）/ −1（左），0 = 不惯性（由 DragState.releaseDirection 给出）。
    /// 一旦触发行为固定：速度 = ±1 屏宽/秒（即 2 秒走 2 屏K线），与甩手力度、缩放级别无关；
    /// 为保证停在整数根K线上，速度会按抬手时的亚像素残差做不可察觉的等比修正；
    /// 途中 endOffset 到数据边界则立即停，无过冲、无回弹。
    @discardableResult
    func startPanInertia(direction dirIn: CGFloat, width: CGFloat, candleSpacing: CGFloat, source: String = "单指") -> Bool {
        cancelPanInertia()
        // dirIn == 0 = 停住再抬手/非平移手势：不惯性（原因已由 releaseDirection 记录）
        guard dirIn != 0 else { return false }
        if menuIsOpen {
            DebugLogger.shared.log("[惯性启动] 未启动 原因=菜单打开 (\(source))")
            return false
        }
        if candleSpacing <= 0 {
            DebugLogger.shared.log("[惯性启动] 未启动 原因=candleSpacing<=0 (\(source))")
            return false
        }
        if sortedData.isEmpty {
            DebugLogger.shared.log("[惯性启动] 未启动 原因=无数据 (\(source))")
            return false
        }

        let sp = candleSpacing
        let maxEndOffset = max(0, sortedData.count - count)
        let sgn: CGFloat = dirIn > 0 ? 1 : -1
        // 沿运动方向还剩多少根K线可走；连一根都没有则不惯性（调用方立即对齐）
        let candlesAhead = sgn > 0 ? (maxEndOffset - endOffset) : endOffset
        if candlesAhead < 1 {
            DebugLogger.shared.log("[惯性启动] 未启动 原因=前方无K线空间 方向=\(sgn > 0 ? "右(更早)" : "左(更新)") endOffset=\(endOffset) maxOffset=\(maxEndOffset) (\(source))")
            return false
        }

        // 期望位移：2 屏宽 − 抬手亚像素残差（沿运动方向折算），使 2 秒终点恰为整数根K线对齐点。
        // 速度 = 位移 / 2 秒 ≈ 1 屏宽/秒（残差修正 ≤ 半根间距，肉眼不可察）。
        let residueAlong = sgn > 0 ? panOffset : -panOffset
        let travel = ChartMomentumAnimator.travelScreens * width - residueAlong
        if travel <= 0 {
            DebugLogger.shared.log("[惯性启动] 未启动 原因=travel<=0 travel=\(String(format: "%.1f", travel)) panOffset=\(String(format: "%.1f", panOffset)) (\(source))")
            return false
        }
        let v = sgn * travel / CGFloat(ChartMomentumAnimator.fixedDuration)
        DebugLogger.shared.log("[惯性启动] ✅启动 方向=\(sgn > 0 ? "右" : "左") 固定v=\(String(format: "%.0f", Double(abs(v))))px/s travel=\(String(format: "%.0f", travel))px 前方\(candlesAhead)根 endOffset=\(endOffset)/\(maxEndOffset) (\(source))")

        var stoppedByBoundary = false
        let animator = ChartMomentumAnimator()
        animator.velocity = v
        animator.onAdvance = { [self] dx in
            // 触边帧把本帧位移截到「恰好到边界对齐点」，停得干脆且残差清零无可视跳变
            let room: CGFloat = sgn > 0
                ? CGFloat(maxEndOffset - endOffset) * sp - panOffset
                : CGFloat(endOffset) * sp + panOffset
            if abs(dx) >= room {
                stoppedByBoundary = true
                DebugLogger.shared.log("[惯性启动] 触边立即停 room=\(String(format: "%.1f", room)) dx=\(String(format: "%.1f", dx)) endOffset=\(endOffset)/\(maxEndOffset)")
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
            if applied != shift {
                stoppedByBoundary = true
                DebugLogger.shared.log("[惯性启动] 进位触边停 endOffset=\(endOffset)/\(maxEndOffset)")
            }
            return applied == shift
        }
        animator.onFinish = { [self] in
            drag.momentum = nil
            DebugLogger.shared.log("[惯性启动] 结束 方式=\(stoppedByBoundary ? "触边即停" : "2秒到点") endOffset=\(endOffset)/\(maxEndOffset) panOffset残差=\(String(format: "%.2f", panOffset))")
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
        DebugLogger.shared.log("[惯性启动] 惯性被新手势/双指打断，立即终止")
        drag.momentum?.cancel()
        drag.momentum = nil
        panOffset = 0
    }

    // MARK: - 光标贴边「按住持续滚动」

    /// 光标贴边自动拖动：手指把光标推到主图可视边缘最后一根后仍朝同方向推、且停在主图外侧一半区域
    /// （越过主图中线）期间，可见窗口按固定速度（每秒一根K线）**持续滚动**，与手指是否还在移动无关。
    /// **抬手不停**：手指抬起后继续滚动，直到该光标被现有任何方式清除（selectedIndex 归 nil）、
    /// 手指反向退回主图内侧一半、或滚到数据边界自然停住。
    ///
    /// - Parameter direction: 手指推动方向 +1（光标贴右缘、查看更新数据）/ −1（贴左缘、查看更早数据）。
    /// 与抬手的甩动惯性不同：无固定时长，只能被 stopEdgeAutoScroll() 或数据边界终止。
    @discardableResult
    func startEdgeAutoScroll(direction dirIn: CGFloat, candleSpacing: CGFloat) -> Bool {
        guard dirIn != 0, candleSpacing > 0, !menuIsOpen, !sortedData.isEmpty else { return false }
        // 同方向已在滚：沿用当前动画器，触摸事件密集时不重建 display link
        if drag.edgeAutoScrollDir == dirIn, drag.edgeAutoScroller != nil { return true }
        stopEdgeAutoScroll()
        let maxEndOffset = max(0, sortedData.count - count)
        // 手指方向 → 平移方向取反：手指朝右推时窗口必须向「更新」方向滚动（endOffset 减小），
        // 光标才能继续朝右走、始终贴住右缘（左推同理）
        let sgn: CGFloat = dirIn > 0 ? -1 : 1
        let candlesAhead = sgn > 0 ? (maxEndOffset - endOffset) : endOffset
        guard candlesAhead >= 1 else { return false }
        let v = sgn * candleSpacing * ChartMomentumAnimator.edgeAutoScrollCandlesPerSecond
        let animator = ChartMomentumAnimator()
        animator.duration = nil   // 无限：按住期间一直滚
        animator.velocity = v
        animator.onAdvance = { [self] dx in
            // 与拖动手势 pan 分支完全相同的亚像素累计进位平移
            panOffset += dx
            let shift = Int((panOffset / candleSpacing).rounded())
            guard shift != 0 else { return true }
            let newOffset = clamp(endOffset + shift, 0, maxEndOffset)
            let applied = newOffset - endOffset
            endOffset = newOffset
            panOffset -= CGFloat(applied) * candleSpacing
            // 光标随窗口一起走，始终保持「光标是该主图可视边缘最后一根」
            selectedIndex = dirIn > 0 ? min(sortedData.count - 1, endIndex) : max(0, startIndex)
            // applied != shift = 已到数据边界：立即停（无过冲）
            return applied == shift
        }
        animator.onFinish = { [self] in
            // 数据边界自然停：清状态并做一次收尾（对齐 + 指标重算 + 恢复预取）。
            // 抬手路径不在这里——抬手后自动滚动仍在继续，收尾只能放在真正停下的这一刻
            drag.edgeAutoScroller = nil
            drag.edgeAutoScrollDir = 0
            drag.cursorDragging = false
            panOffset = 0
            DebugLogger.shared.log("[贴边自动滚动] 结束 方式=触边即停 endOffset=\(endOffset)/\(maxEndOffset)")
            refreshCurves()
            startPrefetch()
        }
        drag.edgeAutoScrollDir = dirIn
        drag.edgeAutoScroller = animator
        // 自动滚动期间保持「本地光标模式」（与手指拖动同态）：横线仍停在手指最后位置、
        // 光标按 selectedIndex 渲染，且每次光标推进都会对外发布联动光标
        drag.cursorDragging = true
        DebugLogger.shared.log("[贴边自动滚动] ✅启动 方向=\(dirIn > 0 ? "贴右缘(看更新)" : "贴左缘(看更早)") v=\(String(format: "%.0f", Double(abs(v))))px/s 前方\(candlesAhead)根 endOffset=\(endOffset)/\(maxEndOffset)")
        animator.start()
        return true
    }

    /// 终止「光标贴边自动滚动」（幂等）：该光标被现有任何方式清除、手指反向退回主图内侧一半、
    /// 双指接管、其他视图接管来源、视图销毁 / 数据刷新时调用
    func stopEdgeAutoScroll() {
        guard drag.edgeAutoScrollDir != 0 || drag.edgeAutoScroller != nil else { return }
        drag.edgeAutoScrollDir = 0
        drag.edgeAutoScroller?.cancel()   // cancel 不触发 onFinish，状态上面已手动清
        drag.edgeAutoScroller = nil
        // 自动滚动期间 cursorDragging 恒为 true（见 startEdgeAutoScroll）；停时必须复位，
        // 否则后续轻点会被 onEnded 的 cursorDragging 分支吞掉，光标再也点不掉
        drag.cursorDragging = false
        panOffset = 0
    }
}

//
//  ChartGestureSupport.swift
//  Kline
//
//  图表手势基础设施：拖动状态、双指手势 UIKit 桥接。
//  从 KlineChartView.swift 拆分而来（与联动复盘无关的通用手势组件）；
//  KlineChartView 的手势处理逻辑仍在其原文件。
//  副图滑动切换反馈的纯渲染组件（SwipeOverlay/SwipeDirectionArrow）在 ChartOverlayKit.swift。
//

import SwiftUI
import UIKit

/// 无光标时的拖动模式：水平=平移，垂直=缩放
enum DragMode {
    case none, pan, zoom
}

/// 拖动手势过程变量容器：改用 class 引用存储，避免手势 onChanged 频繁写入 @State 触发整页重绘导致缓慢拖动卡顿
final class DragState {
    var lastTouchX: CGFloat = 0
    var lastPanWidth: CGFloat = 0
    var lastPanHeight: CGFloat = 0
    var dragMode: DragMode = .none
    var cursorDragging: Bool = false
    var isDragging = false
    var needsRefreshAfterDrag = false
    /// 双指手势进行中：平移/缩放由双指手势统一处理，单指手势应跳过，避免重复平移/误触发
    var twoFingerActive = false
    /// 联动非来源小周期（范围框）视图中：正在拖动纯本地「第二个十字光标」
    var secondCursorDragging = false
    /// 惯性判定不做速度采样，只看「抬手前手指有没有停住」：
    /// 最后一次平移 onChanged 的时间戳；0 = 本次手势尚未发生平移
    var lastPanMoveTime: CFTimeInterval = 0
    /// 最后一次水平增量（带符号，右正左负）：仅用于决定惯性方向
    var lastPanDeltaX: CGFloat = 0
    /// 双指质心累计横向位移（轨迹 totalX 用，双指开始时清零）
    var twoFingerTravelX: CGFloat = 0
    /// 平移轨迹：(处理时刻, 相对手势起点累计水平位移)。用于末段/峰值速度比较
    var panTrail: [(t: CFTimeInterval, x: CGFloat)] = []
    /// 进行中的横向惯性滑动动画器（nil = 无）
    var momentum: ChartMomentumAnimator? = nil
    /// 调试用：本次手势是否已记录起点日志（onEnded 复位）
    var beginLogged = false

    // MARK: 惯性判定参数（四个条件同时满足才惯性）

    /// 条件①：抬手前允许的最大停顿（s）。最后移动 → 抬手 ≤ 该值才可能是甩动
    static let flingIdleLimit: CFTimeInterval = 0.2
    /// 条件②：最小滑动距离（屏宽占比）。净位移 < 屏宽10% 视为微调，不惯性
    static let minTravelRatio: CGFloat = 0.10
    /// 速度比较窗口（s）：末段/峰值速度都按 ~0.2s 的 Δx/Δt 计算。
    /// 真机事件间隔 70~90ms，0.2s 窗口稳定覆盖 2~3 个事件，且天然合并 1~2ms
    /// 的背靠背批量投递事件（那种事件单帧算速度会爆出上百倍伪速度）
    static let velocityWindow: CFTimeInterval = 0.2
    /// 窗口配对允许的 dt 范围（s）
    static let windowDtMin: CFTimeInterval = 0.12
    static let windowDtMax: CFTimeInterval = 0.30
    /// 条件④：末段速度 ≥ 峰值速度 × 该比例。真甩动实测末段约为峰值 50%+；
    /// 滑到位置停住（含停后微漂/回位）末段 ≈0 或反向，实测 ≤4%
    static let minTailPeakRatio: CGFloat = 0.25

    /// 开始一段新的平移（单指模式切换为 .pan / 双指开始）：清空抬手意图状态
    func resetPanIntent() {
        lastPanMoveTime = 0
        lastPanDeltaX = 0
        twoFingerTravelX = 0
        panTrail.removeAll(keepingCapacity: true)
    }

    /// 记录一次平移推进。
    /// - Parameters:
    ///   - deltaX: 本帧水平增量（方向、停顿计时用）
    ///   - totalX: 相对手势起点累计水平位移（单指传 translation.width；双指传质心累计）
    /// deltaX=0（双指纯缩放）不刷新移动时间、不记轨迹，避免「捏住停顿」被误判成持续移动。
    func markPanMove(deltaX: CGFloat, totalX: CGFloat) {
        guard deltaX != 0 else { return }
        let now = CACurrentMediaTime()
        panTrail.append((now, totalX))
        if panTrail.count > 32 { panTrail.removeFirst() }
        lastPanMoveTime = now
        lastPanDeltaX = deltaX
    }

    /// 取轨迹点 upTo 与「时间上最接近 velocityWindow 前」的较早点之间的窗口速度。
    /// 配对 dt 限定 [windowDtMin, windowDtMax]：跨 2~3 个真机事件，排除背靠背批处理。
    /// 找不到合格配对（手势极短）时退化为与紧邻前点的速度；dt 过小返回 nil。
    private func windowVelocity(upTo i: Int) -> CGFloat? {
        guard i >= 1, i < panTrail.count else { return nil }
        let ti = panTrail[i].t
        var bestJ = -1
        var bestDiff = Double.greatestFiniteMagnitude
        for j in 0..<i {
            let dt = ti - panTrail[j].t
            if dt < Self.windowDtMin || dt > Self.windowDtMax { continue }
            let diff = abs(dt - Self.velocityWindow)
            if diff < bestDiff { bestDiff = diff; bestJ = j }
        }
        let j = bestJ >= 0 ? bestJ : i - 1
        let dt = ti - panTrail[j].t
        guard dt > 0.005 else { return nil }
        return (panTrail[i].x - panTrail[j].x) / CGFloat(dt)
    }

    /// 抬手意图判定：返回惯性方向（+1 右 / −1 左），0 = 不惯性。
    /// 四个条件同时满足才惯性：
    /// ① 抬手前没停住（idle ≤ flingIdleLimit）；
    /// ② 本次净滑动 ≥ 屏宽 minTravelRatio（排除微调/抖动）；
    /// ③ 末段速度与滑动主方向同号（停住后手指反向回位直接否决）；
    /// ④ 末段速度 ≥ 峰值速度 × minTailPeakRatio（末段明显衰减=滑到位置停住，否决）。
    /// - Parameter width: 图表点区宽度（距离条件②用）
    @discardableResult
    func releaseDirection(isPanGesture: Bool, width: CGFloat, source: String) -> CGFloat {
        guard isPanGesture else { return 0 }
        guard lastPanMoveTime > 0, panTrail.count >= 2 else {
            DebugLogger.shared.log("[惯性判定] 不惯性 原因=本次无有效平移记录 (\(source))")
            return 0
        }
        let idle = CACurrentMediaTime() - lastPanMoveTime
        // 条件①：停顿
        if idle > Self.flingIdleLimit {
            DebugLogger.shared.log("[惯性判定] 不惯性 原因=停住\(String(format: "%.0f", idle * 1000))ms后抬手（>\(Int(Self.flingIdleLimit * 1000))ms） (\(source))")
            return 0
        }
        let netX = panTrail.last!.x - panTrail[0].x
        // 条件②：滑动距离
        if abs(netX) < Self.minTravelRatio * width {
            DebugLogger.shared.log("[惯性判定] 不惯性 原因=滑动距离不足 |\(String(format: "%.0f", netX))| < \(String(format: "%.0f", Self.minTravelRatio * width))px（屏宽\(Int(Self.minTravelRatio * 100))%） (\(source))")
            return 0
        }
        let dir: CGFloat = netX >= 0 ? 1 : -1
        // 末段速度与峰值速度
        guard let vTail = windowVelocity(upTo: panTrail.count - 1) else {
            DebugLogger.shared.log("[惯性判定] 不惯性 原因=末段速度不可算（手势过短） (\(source))")
            return 0
        }
        var vPeak: CGFloat = 0
        for i in 1..<panTrail.count {
            guard let v = windowVelocity(upTo: i) else { continue }
            // 只统计与主滑动方向同号的速度
            if (v >= 0) == (dir >= 0), abs(v) > abs(vPeak) { vPeak = v }
        }
        // 条件③：末段方向必须与主滑动一致（停住后反向微漂/回位 → 否决）
        if (vTail >= 0) != (dir >= 0) {
            DebugLogger.shared.log("[惯性判定] 不惯性 原因=末段反向回位 vTail=\(String(format: "%.0f", vTail)) 主方向=\(dir > 0 ? "右" : "左") (\(source))")
            return 0
        }
        // 条件④：末段速度相对峰值不能明显衰减
        let ratio = abs(vPeak) > 0 ? abs(vTail) / abs(vPeak) : 0
        if ratio < Self.minTailPeakRatio {
            DebugLogger.shared.log("[惯性判定] 不惯性 原因=末段明显减速 vTail=\(String(format: "%.0f", vTail)) vPeak=\(String(format: "%.0f", vPeak)) 比例\(String(format: "%.0f%%", ratio * 100)) < \(Int(Self.minTailPeakRatio * 100))% (\(source))")
            return 0
        }
        DebugLogger.shared.log("[惯性判定] ✅甩动 idle=\(String(format: "%.0f", idle * 1000))ms 净位移=\(String(format: "%.0f", netX)) vTail=\(String(format: "%.0f", vTail)) vPeak=\(String(format: "%.0f", vPeak)) 比例\(String(format: "%.0f%%", ratio * 100)) 方向=\(dir > 0 ? "右" : "左") (\(source))")
        return dir
    }
}

// MARK: - 双指手势（UIKit）

/// 双指手势层：一个只覆盖「单个图表面板区域」的 UIKit 视图，挂 UIPinchGestureRecognizer。
/// SwiftUI 的 MagnificationGesture 只在「捏合（距离变化）」时激活、DragGesture 多指时不可靠，
/// 无法在双指固定距离平移时拿到整体横向位移；UIPinchGestureRecognizer 原生跟踪双指质心
/// （location(in:)）与缩放（scale），固定距离平移时质心移动也会持续触发。
/// 该视图按面板分片放置（主图/各副图各一块），不覆盖 legend 行的按钮；
/// 面板上的单指触摸沿 UIKit 响应链同时派发给祖先上的 SwiftUI 手势（chartDragGesture），
/// 因此单指平移/缩放/光标/副图切换不受影响。
struct TwoFingerGestureHook: UIViewRepresentable {
    let onBegin: (CGFloat) -> Void       // 手势起始：双指质心 x
    let onChange: (CGFloat, CGFloat) -> Void // 手势中：缩放 scale、质心横向位移增量 dx
    let onEnd: () -> Void

    func makeUIView(context: Context) -> TwoFingerHookView {
        let v = TwoFingerHookView()
        v.onBegin = onBegin
        v.onChange = onChange
        v.onEnd = onEnd
        return v
    }
    func updateUIView(_ uiView: TwoFingerHookView, context: Context) {
        uiView.onBegin = onBegin
        uiView.onChange = onChange
        uiView.onEnd = onEnd
    }
}

final class TwoFingerHookView: UIView, UIGestureRecognizerDelegate {
    var onBegin: ((CGFloat) -> Void)?
    var onChange: ((CGFloat, CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var lastCentroidX: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        let p = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        p.delegate = self
        addGestureRecognizer(p)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        let c = g.location(in: self)
        switch g.state {
        case .began:
            lastCentroidX = c.x
            onBegin?(c.x)
        case .changed:
            let dx = c.x - lastCentroidX
            lastCentroidX = c.x
            onChange?(g.scale, dx)
        case .ended, .cancelled, .failed:
            lastCentroidX = 0
            onEnd?()
        default:
            break
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// 副图左右滑动切换的拖动反馈动画状态
struct SwipeFeedback: Equatable {
    let slot: SubSlot
    var offset: CGFloat      // 当前横向位移（右正左负）
    let canLeft: Bool        // 左滑方向是否可切换
    let canRight: Bool       // 右滑方向是否可切换
}


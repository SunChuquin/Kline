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
    /// 调试用：上一次 markPanMove 的处理时刻（打事件间隔时间线）
    var lastMarkT: CFTimeInterval = 0
    /// 进行中的横向惯性滑动动画器（nil = 无）
    var momentum: ChartMomentumAnimator? = nil
    /// 调试用：本次手势是否已记录起点日志（onEnded 复位）
    var beginLogged = false

    /// 抬手前允许的最大停顿（s）：最后一次移动 → 抬手 ≤ 该值 = 甩动抬手 → 惯性；
    /// 超过 = 滑到位置停住再抬手 → 不惯性。
    /// 真机拖动事件正常间隔约 70~90ms，取 0.2s 与连续移动拉开余量；主动停住看盘
    /// 一般 ≥0.3s，两类动作据此可靠区分。
    static let flingIdleLimit: CFTimeInterval = 0.2

    /// 开始一段新的平移（单指模式切换为 .pan / 双指开始）：清空抬手意图状态
    func resetPanIntent() {
        lastPanMoveTime = 0
        lastPanDeltaX = 0
        lastMarkT = 0
    }

    /// 记录一次平移推进（单指 pan 的 delta / 双指质心横向增量同源调用）。
    /// deltaX=0（双指纯缩放）不刷新移动时间，避免「捏住停顿」被误判成持续移动。
    func markPanMove(deltaX: CGFloat) {
        guard deltaX != 0 else {
            DebugLogger.shared.log("[惯性轨迹]   dx=0（本帧无水平增量，不刷新停顿计时）")
            return
        }
        let now = CACurrentMediaTime()
        let gapMs = lastMarkT > 0 ? (now - lastMarkT) * 1000 : -1
        DebugLogger.shared.log("[惯性轨迹] 距上一事件\(gapMs < 0 ? "—" : String(format: "%.0fms", gapMs)) dx=\(String(format: "%.1f", deltaX))")
        lastMarkT = now
        lastPanMoveTime = now
        lastPanDeltaX = deltaX
    }

    /// 抬手意图判定：返回惯性方向（+1 右 / −1 左），0 = 不惯性。
    /// 不看滑动速度、不看事件频率，只看「最后一次移动距抬手多久」：
    /// 甩动直接抬手（≤flingIdleLimit）→ 惯性；停住再抬手 → 立即对齐停止。
    /// - Parameter isPanGesture: 单指传 dragMode == .pan；双指平移传 true
    /// - Parameter source: 日志来源标记（单指/双指）
    @discardableResult
    func releaseDirection(isPanGesture: Bool, source: String) -> CGFloat {
        guard isPanGesture else { return 0 }
        guard lastPanMoveTime > 0 else {
            DebugLogger.shared.log("[惯性判定] 不惯性 原因=本次无平移记录 (\(source))")
            return 0
        }
        let idle = CACurrentMediaTime() - lastPanMoveTime
        if idle > Self.flingIdleLimit {
            DebugLogger.shared.log("[惯性判定] 不惯性 原因=停住\(String(format: "%.0f", idle * 1000))ms后抬手（>\(Int(Self.flingIdleLimit * 1000))ms） (\(source))")
            return 0
        }
        let dir: CGFloat = lastPanDeltaX >= 0 ? 1 : -1
        DebugLogger.shared.log("[惯性判定] 甩动抬手 idle=\(String(format: "%.0f", idle * 1000))ms 方向=\(dir > 0 ? "右" : "左") (\(source))")
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


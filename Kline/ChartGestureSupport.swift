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


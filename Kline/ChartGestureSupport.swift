//
//  ChartGestureSupport.swift
//  Kline
//
//  图表手势基础设施：拖动状态、双指手势 UIKit 桥接、副图滑动切换反馈。
//  从 KlineChartView.swift 拆分而来（与联动复盘无关的通用手势组件）；
//  KlineChartView 的手势处理逻辑仍在其原文件。
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

// MARK: - 副图滑动切换反馈 UI（KlineChartView 实例方法，从 KlineChartView.swift 拆分）

extension KlineChartView {

    /// 副图左右滑动切换反馈：拖动时才显示方向箭头 + 滑轨/滑块/阈值动画。
    /// 仅副图1/2 调用挂载；副图三面板手势整体禁用（虚拟按钮预留区），不会进入本函数，
    /// 此处 `slot != .third` 为双保险。
    @ViewBuilder
    func swipeOverlay(slot: SubSlot, width: CGFloat, height: CGFloat) -> some View {
        if slot != .third {
            let fb = swipeFeedback
            let isDragging = fb?.slot == slot && (fb?.offset ?? 0).magnitude > 1
            let off = isDragging ? (fb?.offset ?? 0) : 0
            // 副图一（上方副图）方向已调转：左=小级别/上一标的，右=大级别/下一标的；副图二保持原方向
            let canL = slot == .top ? canSwitchPeriod(-1) : (canSwitchItem?(1) ?? false)
            let canR = slot == .top ? canSwitchPeriod(1) : (canSwitchItem?(-1) ?? false)
            let threshold: CGFloat = 70
            ZStack {
            // 方向箭头提示：仅拖动中显示（滑动条出现前不显示），可切换方向高亮，边界方向灰显
            if isDragging {
                HStack {
                    swipeDirectionArrow(system: "chevron.left", can: canL,
                                        active: off < 0)
                    Spacer()
                    swipeDirectionArrow(system: "chevron.right", can: canR,
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

    /// 副图滑动方向提示箭头
    func swipeDirectionArrow(system: String, can: Bool, active: Bool) -> some View {
        Image(systemName: can ? system : (system + ".circle"))
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(can ? (active ? Color.white : Color.black.opacity(0.35)) : Color.gray.opacity(0.25))
            .frame(width: 22, height: 22)
            .background(can ? Color.black.opacity(active ? 0.5 : 0.08) : Color.clear)
            .clipShape(Circle())
    }
}

//
//  FloatingAccessoryWheel.swift
//  Kline
//
//  第二个悬浮按钮（下称「新按钮」）：三圆结构 A'/B'/C'。A' 与 B' 同心、仅 1pt 内描边，
//  两者之间的环 Z' 保持透明；C' 是环内的一枚实心点，跟随转圈角度停在环上。
//  触摸状态机：落点在 B' 圆内 = 摁住/拖动整个按钮（与旧按钮同构，松手吸附 + 落位持久化）；
//  落点在环 Z' 上 = 转圈（落点即接管），角度按里程表累积。
//  共用的几何 / 描边常量、落位计算与持久化见 FloatingAccessoryShared.swift。
//

import Foundation
import SwiftUI

/// 新按钮（转圈驱动 K 线光标的那个）
/// - 几何：A' = B' + 2 × 环 Z'，B' = 旧按钮 A × 1.3，环 Z' 宽 = 旧按钮 D 直径，C' = 环宽 − 1；
///   全部由 FloatingAccessoryMetrics 派生（派生式与自洽性校验见该处注释）
/// - 外观：A' / B' 仅用语义色 label 描边，环 Z' 透明，C' 用同一语义色实心（+1pt 外描边走满环宽）
/// - 状态：摁住 / 拖动 / 转圈中整体 +15% 并降到 50% 透明度；抬手后 3 秒未触碰降到 25%
///   且 C' 隐藏（计时令牌自增防泄漏）
/// - 手势分区：落点半径 ≤ B' 半径 → 整钮模式（点击只做果冻回弹、拖动吸附到更近一侧并持久化）；
///   落点半径 > B' 半径（即环 Z'）→ 转圈模式，C' 跳到落点角度后随手指滑动
/// - 命中区：A' 围出的圆盘（即 B' 盘 ∪ 环 Z' 环带）
/// - 落位：默认落在旧按钮的对侧；启动 / 尺寸变化时若两按钮同侧，强制移回旧按钮的对侧
struct FloatingAccessoryWheel: View {

    /// 本次触摸的模式：首次 onChanged 按落点半径定下，整个手势期间不再改变
    private enum TouchMode {
        /// 落点在 B' 圆内：摁住 / 拖动整个按钮
        case whole
        /// 落点在环 Z' 上：转圈
        case ring
    }

    /// 手指到圆心距离小于该值时冻结角度：规避 atan2 在圆心附近的奇点抖动
    private let ringAngleDeadZoneRadius: CGFloat = 8
    /// 转圈 → K 线推进：一圈 360° = 20 根，即 18° = 1 根
    private let degreesPerCandle: Double = 18

    /// 已落位的中心点；nil 表示尚未初始化（onAppear 时按持久化值或默认落位解析）
    @State private var center: CGPoint?
    /// 本次手势的实时位移：与已落位的 center 叠加显示（用 @State 而非 @GestureState，
    /// 便于在 onEnded 的同一个动画事务里把它与吸附目标一起归零，吸附过程从松手点平滑过渡）
    @State private var dragDelta: CGSize = .zero
    /// 手指是否仍按在按钮上（摁住 / 拖动 / 转圈中）：控制 15% 放大与 50% 透明度
    @State private var isPressing = false
    /// 是否已进入「3 秒未触碰」的低透明度状态（该状态下 C' 隐藏）
    @State private var isDimmed = false
    /// 点击时的果冻缩放（与 isPressing 的放大叠乘）
    @State private var jellyScale: CGFloat = 1
    /// 闲置淡出计时令牌：每次触碰自增使在途的淡出作废
    @State private var idleFadeToken = 0
    /// 本次手势的模式；nil = 尚未定模式（抬手、视图消失时一并清零）
    @State private var touchMode: TouchMode?
    /// 转圈里程表（度，无界）：只由 wrap 后的角度增量累加，抬手不清零；第 4 阶段据它派生 K 线推进量
    @State private var odometer: Double = 0
    /// 上一次角度回调的原始 atan2 结果（度），用于算 wrap 增量
    @State private var lastRawAngle: Double = 0
    /// C' 的显示角偏移（度）：初始 -90° = 12 点方向；环上落点接管时重置为「落点角 − 里程表」，
    /// 使 C' 立即跳到手指角度而里程表自身保持连续 —— 若改成直接给里程表赋值，
    /// 接管瞬间会被当成转过一大圈（第 4 阶段据此推进 K 线时会凭空走进一段）
    @State private var displayAngleOffset: Double = -90
    /// 已发布的 K 线推进根数（按里程表取整得到）：与里程表的取整值比较，差值非 0 才发命令
    @State private var deliveredCandles = 0

    /// C' 的显示角（度）= 里程表 + 显示偏移（cos / sin 本身周期，无需再对 360 取模）
    private var displayAngleDegrees: Double { odometer + displayAngleOffset }

    /// 整体透明度：摁住 / 拖动 / 转圈中 50%；3 秒未触碰后 25%；其余（含触碰后 3 秒内）100%
    private var overallOpacity: Double {
        if isPressing { return 0.5 }
        return isDimmed ? 0.25 : 1.0
    }

    var body: some View {
        GeometryReader { geo in
            let bounds = FloatingAccessoryPlacement.bounds(in: geo.size, diameter: FloatingAccessoryMetrics.wheelOuterDiameter)
            let base = FloatingAccessoryPlacement.clamped(center ?? resolvedCenter(in: geo.size, bounds: bounds), in: bounds)
            let shown = FloatingAccessoryPlacement.clamped(CGPoint(x: base.x + dragDelta.width, y: base.y + dragDelta.height), in: bounds)
            disc
                // 摁住 / 拖动 / 转圈放大 15%，叠加点击时的果冻缩放
                .scaleEffect((isPressing ? FloatingAccessoryMetrics.pressScaleFactor : 1) * jellyScale)
                // 与旧按钮同理：A' / B' 描边与 C' 相互重叠，.opacity 默认逐层施加会做多次半透明
                // 混合（内层反而更深）；先 compositingGroup 合成一张图再整体乘透明度
                .compositingGroup()
                .opacity(overallOpacity)
                // 命中形状按规格取「A' 圆盘」：A'/B' 都只是 1pt 描边，若用默认命中区域
                // 可点到的只有描边那一圈细线；规格里「大圆 A' 本身不接收任何手势」按
                // 「A' 的描边没有独立行为」理解 —— A' 只提供轮廓与命中范围，
                // 真正的可交互区域仍是它围出的整个圆盘（盘内分区见 resolveTouchMode）
                .contentShape(Circle())
                // 手势挂在 disc 自身、且位于 .position 之前：此时 .local 就是 disc 自己的
                // 128.8×128.8 坐标系（圆心 = (64.4, 64.4)），落点半径与 atan2 都按这个口径算
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            // 模式只在本手势的第一次回调里定下，之后整个手势沿用
                            let mode = touchMode ?? beginTouch(at: value.startLocation)
                            if mode == .whole {
                                dragDelta = value.translation
                            } else {
                                updateRingAngle(to: value.location)
                            }
                        }
                        .onEnded { value in
                            withAnimation(.easeOut(duration: 0.15)) { isPressing = false }
                            let wasWhole = touchMode == .whole
                            touchMode = nil
                            FloatingAccessoryCoordinator.shared.setRotating(false)
                            FloatingAccessoryCoordinator.shared.endGesture(.secondary)
                            if wasWhole {
                                let t = value.translation
                                let moved = max(abs(t.width), abs(t.height)) > FloatingAccessoryMetrics.tapSlop
                                if !moved {
                                    // 点击：先复位位移、果冻弹一下；新按钮没有面板，不回调任何 action
                                    dragDelta = .zero
                                    playJelly()
                                } else {
                                    let raw = FloatingAccessoryPlacement.clamped(CGPoint(x: base.x + t.width, y: base.y + t.height), in: bounds)
                                    // 吸附到更近的一侧边缘（纵向保持）；两按钮同侧互斥属后续阶段，这里只做单钮吸附
                                    let left = bounds.x.lowerBound
                                    let right = bounds.x.upperBound
                                    let target = CGPoint(x: (raw.x - left <= right - raw.x) ? left : right, y: raw.y)
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        center = target
                                        dragDelta = .zero
                                    }
                                    FloatingAccessoryStore.save(target, for: .secondary)
                                }
                            }
                            // 任何触碰后抬手：保持 100% 透明度 3 秒，再降到 25%
                            scheduleIdleFade()
                        }
                )
                .position(shown)
                .onAppear {
                    center = FloatingAccessoryPlacement.clamped(center ?? resolvedCenter(in: geo.size, bounds: bounds), in: bounds)
                    // 初始 100% 起算：3 秒未触碰即降到 25%
                    scheduleIdleFade()
                }
                .onDisappear {
                    idleFadeToken += 1
                    // 手势被打断时不会有 onEnded，模式必须在这里清零，否则下次触摸会沿用上一次的模式
                    touchMode = nil
                    // 转圈标记与手势占用者同样要复位，避免视图消失后残留「正在转圈」状态
                    FloatingAccessoryCoordinator.shared.setRotating(false)
                    FloatingAccessoryCoordinator.shared.endGesture(.secondary)
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
        let radians = CGFloat(displayAngleDegrees) * .pi / 180
        return Circle()
            .fill(FloatingAccessoryMetrics.ringStroke)
            .frame(width: FloatingAccessoryMetrics.wheelDotDiameter, height: FloatingAccessoryMetrics.wheelDotDiameter)
            .overlay(Circle().stroke(FloatingAccessoryMetrics.ringStroke,
                                     lineWidth: FloatingAccessoryMetrics.wheelDotStrokeWidth))
            // 圆心走在环的中径上：右下为正 x / 正 y，故 -90° 落在 12 点方向
            .offset(x: FloatingAccessoryMetrics.wheelDotTrackRadius * cos(radians),
                    y: FloatingAccessoryMetrics.wheelDotTrackRadius * sin(radians))
            // 闲置态 C' 隐藏（A' / B' 与环 Z' 仍按 25% 显示）
            .opacity(isDimmed ? 0 : 1)
    }

    // MARK: - 触摸状态机

    /// 本次手势的第一次回调：定模式（并记入 touchMode）、进入摁住态（取消在途淡出）；
    /// 转圈模式额外做「落点即接管」。返回本次手势的模式
    private func beginTouch(at startLocation: CGPoint) -> TouchMode {
        cancelIdleFade()
        withAnimation(.easeOut(duration: 0.12)) { isPressing = true }
        FloatingAccessoryCoordinator.shared.beginGesture(.secondary)
        let mode = resolveTouchMode(at: startLocation)
        touchMode = mode
        guard mode == .ring else { return mode }
        FloatingAccessoryCoordinator.shared.setRotating(true)
        // 落点即接管：C' 立即跳到落点角度（改显示偏移而非里程表，理由见 displayAngleOffset）
        let raw = rawAngleDegrees(at: startLocation)
        displayAngleOffset = raw - odometer
        lastRawAngle = raw
        return mode
    }

    /// 落点半径 → 本次触摸模式：B' 圆内 = 整钮，环 Z' 上 = 转圈
    private func resolveTouchMode(at location: CGPoint) -> TouchMode {
        let (dx, dy) = deltaFromCenter(location)
        let distance = (dx * dx + dy * dy).squareRoot()
        return distance <= Double(FloatingAccessoryMetrics.wheelInnerDiameter / 2) ? .whole : .ring
    }

    /// 转圈：用里程表累积 wrap 后的角度增量（跨 0°/360° 不会跳变）
    private func updateRingAngle(to location: CGPoint) {
        let (dx, dy) = deltaFromCenter(location)
        // 奇点保护：手指贴近圆心时 atan2 抖动剧烈 —— 冻结角度，且不更新 lastRawAngle，
        // 这样手指从圆心附近回到环上后，增量仍从冻结前的角度连续续算
        guard (dx * dx + dy * dy).squareRoot() >= Double(ringAngleDeadZoneRadius) else { return }
        let raw = atan2(dy, dx) * 180 / .pi
        odometer += FloatingAccessoryAngle.wrap(raw - lastRawAngle)
        lastRawAngle = raw
        publishCursorAdvance()
    }

    /// 里程表 → K 线推进：18° = 1 根，把里程表取整得到「应到的根数」，
    /// 与已发布根数比较，差值非 0 才发命令（里程表保留小数部分 = 亚像素累计，不清零、不取模）。
    /// 取整用向零取整，逆时针（负角度）同样只差出整数根数
    private func publishCursorAdvance() {
        let want = Int((odometer / degreesPerCandle).rounded(.towardZero))
        let delta = want - deliveredCandles
        guard delta != 0 else { return }
        deliveredCandles = want
        FloatingAccessoryCoordinator.shared.advanceCursor(by: delta)
    }

    /// 落点相对 disc 圆心的位移（disc 自身坐标系里圆心为 (64.4, 64.4)）；转成 Double 便于算半径与角度
    private func deltaFromCenter(_ p: CGPoint) -> (dx: Double, dy: Double) {
        let radius = FloatingAccessoryMetrics.wheelOuterDiameter / 2
        return (Double(p.x - radius), Double(p.y - radius))
    }

    /// 落点的原始角度（度）：屏幕坐标 y 向下为正，故 atan2 递增 = 视觉顺时针；-90° = 12 点方向
    private func rawAngleDegrees(at location: CGPoint) -> Double {
        let (dx, dy) = deltaFromCenter(location)
        return atan2(dy, dx) * 180 / .pi
    }

    /// 开始 / 重排闲置淡出：3 秒内再被触碰则本次作废
    private func scheduleIdleFade() {
        idleFadeToken += 1
        let token = idleFadeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + FloatingAccessoryMetrics.idleFadeDelay) {
            guard token == idleFadeToken else { return }
            withAnimation(.easeOut(duration: 0.45)) { isDimmed = true }
        }
    }

    /// 触碰即取消在途淡出并回到 100%（任何触碰后抬手也要保持 3 秒 100%）；C' 随之恢复可见
    private func cancelIdleFade() {
        idleFadeToken += 1
        if isDimmed { withAnimation(.easeOut(duration: 0.15)) { isDimmed = false } }
    }

    /// 果冻弹一下（参数与旧按钮一致）：先快速压缩，再用低阻尼 spring 回弹过冲；
    /// 新按钮没有面板，故不收 completion（旧按钮的 completion 只为延后面板弹出）
    private func playJelly() {
        withAnimation(.easeOut(duration: 0.08)) { jellyScale = 0.82 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.34)) { jellyScale = 1 }
        }
    }

    // MARK: - 落位

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
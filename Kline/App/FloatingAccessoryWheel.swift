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
import Combine

/// 新按钮（转圈驱动 K 线光标的那个）
/// - 几何：A' = B' + 2 × 环 Z'，B' = 旧按钮 A × 1.3，环 Z' 宽 = 旧按钮 D 直径，C' = 环宽 − 1；
///   全部由 FloatingAccessoryMetrics 派生（派生式与自洽性校验见该处注释）
/// - 外观：A' / B' 仅用语义色 label 描边，环 Z' 透明，C' 用同一语义色实心（+1pt 外描边走满环宽）
/// - 状态：摁住 / 拖动 / 转圈中整体 +15% 并降到 50% 透明度；抬手后 0.5 秒未触碰降到 25%
///   且 C' 隐藏（计时令牌自增防泄漏）
/// - 手势分区：落点半径 ≤ B' 半径 → 整钮模式（点击=把被驱动那一格朝更新方向平移一根，并在其最右侧可见 K 线上放光标；
///   拖动吸附到更近一侧并持久化）；
///   落点半径 > B' 半径（即环 Z'）→ 转圈模式，C' 跳到落点角度后随手指滑动
/// - 命中区：A' 围出的圆盘（即 B' 盘 ∪ 环 Z' 环带）
/// - 落位：默认落在旧按钮的对侧；启动 / 尺寸变化时若两按钮同侧，强制移回旧按钮的对侧
struct FloatingAccessoryWheel: View {

    /// 底部需避让的高度（「自选 / 行情」页的底部导航栏实测高度）。
    /// 不避让时按钮能被拖到物理屏幕底边、与 Tab 的命中区重叠，想切首页/模拟页时会误触到它
    var bottomClearance: CGFloat = 0

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
    /// 容器尺寸缓存：吸附请求在几何闭包外用 `.onReceive` 处理，需要据此自行算出目标边缘 x
    @State private var containerSize: CGSize = .zero

    /// C' 的显示角（度）= 里程表 + 显示偏移（cos / sin 本身周期，无需再对 360 取模）
    private var displayAngleDegrees: Double { odometer + displayAngleOffset }

    /// 是否临时呈现「旧按钮拖动状态」的外观：B' 被操作（点击 / 摁着 / 拖着）时置 true，
    /// 静止 3 秒（与闲置淡出同一时刻）或自己被外部强制闲置时还原为新按钮自身的稳定态
    @State private var showsOldLook = false

    /// 整体透明度：摁住 / 拖动 / 转圈中 50%；3 秒未触碰后 25%；其余（含触碰后 3 秒内）100%
    private var overallOpacity: Double {
        if isPressing { return 0.5 }
        return isDimmed ? 0.25 : 1.0
    }

    var body: some View {
        GeometryReader { geo in
            let bounds = FloatingAccessoryPlacement.bounds(in: geo.size, diameter: FloatingAccessoryMetrics.wheelOuterDiameter,
                                                          bottomClearance: bottomClearance)
            let base = FloatingAccessoryPlacement.clamped(center ?? resolvedCenter(in: geo.size, bounds: bounds), in: bounds)
            let shown = FloatingAccessoryPlacement.clamped(CGPoint(x: base.x + dragDelta.width, y: base.y + dragDelta.height), in: bounds)
            // B' 被操作（点击 / 摁着 / 拖着）期间，整个按钮临时呈现「旧按钮拖动状态」的外观；
            // 环上转圈与稳定态都用新按钮自身的三圆图形。
            // 外层 frame 恒取 A' 直径：命中区始终是 A' 圆盘、不随外观切换而缩小；
            // 56pt 的旧按钮图形居中在同一个盘心，故圆心与落点判定口径不变
            ZStack {
                if showsOldLook {
                    FloatingAccessoryRings()
                } else {
                    disc
                }
            }
            .frame(width: FloatingAccessoryMetrics.wheelOuterDiameter,
                   height: FloatingAccessoryMetrics.wheelOuterDiameter)
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
                .position(shown)
                // ⚠️ 手势必须挂在 .position **之后**（与旧按钮完全同构）：此时它的 .local 是 GeometryReader
                // 的容器坐标系，**不受 scaleEffect 影响**，手指位移 1:1 映射，拖动才跟手。
                // 若挂在 .position 之前（即落在 scaleEffect 内部），.local 会变成被 1.15 倍缩放过的 disc
                // 坐标系：上报的 translation 被缩小 1.15 倍，按钮永远追不上手指（越拖越落后）；
                // 且按下瞬间缩放 1.0→1.15 的动画期间映射还在变，会额外「发飘」。
                // 代价：坐标是容器系，落点半径与 atan2 的圆心须用 shown，不能再用 disc 的 (64.4, 64.4)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            // 模式只在本手势的第一次回调里定下，之后整个手势沿用
                            let mode = touchMode ?? beginTouch(at: value.startLocation, center: shown)
                            if mode == .whole {
                                dragDelta = value.translation
                                // 同侧互斥每帧判定（廉价读字典，不发布）：中心越过屏幕中线时请求另一按钮反向吸附
                                let dragged = FloatingAccessoryPlacement.clamped(CGPoint(x: base.x + value.translation.width,
                                                                                        y: base.y + value.translation.height),
                                                                               in: bounds)
                                FloatingAccessoryCoordinator.shared.reportDrag(owner: .secondary,
                                                                               side: FloatingAccessoryPlacement.side(of: dragged, in: geo.size))
                            } else {
                                updateRingAngle(to: value.location, center: shown)
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
                                    // 点击：果冻弹一下 + 把整个「点击语义」交给主格执行（见 applyAccessoryWindowNudge）：
                                    // 主格先按自身状态决定是否需要清除屏幕上全部视图的光标（若它已是驱动来源、
                                    // 光标也已在最右侧，就不清），再把窗口朝「更新」方向平移 1 根，
                                    // 最后把光标放在平移后的最右侧可见 K 线上。果冻只是反馈，不延后动作
                                    dragDelta = .zero
                                    playJelly()
                                    FloatingAccessoryCoordinator.shared.nudgeWindow(by: 1)
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
                                    // 抬手后的最终侧上报：协调对象据此继续保证两侧互斥
                                    FloatingAccessoryCoordinator.shared.reportSide(.secondary,
                                                                                   FloatingAccessoryPlacement.side(of: target, in: geo.size))
                                }
                            }
                            // 任何触碰后抬手：保持 100% 透明度 3 秒，再降到 25%
                            scheduleIdleFade()
                        }
                )
                .onAppear {
                    containerSize = geo.size
                    let resolved = FloatingAccessoryPlacement.clamped(center ?? resolvedCenter(in: geo.size, bounds: bounds), in: bounds)
                    center = resolved
                    reportSide(of: resolved, in: geo.size)
                    // 初始 100% 起算：3 秒未触碰即降到 25%
                    scheduleIdleFade()
                }
                .onDisappear {
                    idleFadeToken += 1
                    // 手势被打断时不会有 onEnded，模式必须在这里清零，否则下次触摸会沿用上一次的模式
                    touchMode = nil
                    // 转圈标记与手势占用者同样要复位，避免视图消失后残留「正在转圈」状态 / 让对方永久闲置
                    FloatingAccessoryCoordinator.shared.setRotating(false)
                    FloatingAccessoryCoordinator.shared.endGesture(.secondary)
                }
                // 尺寸变化（旋转 / 分屏 / 多任务）后把已落位点夹回可视范围，避免停在屏幕外
                .onChange(of: geo.size) { newSize in
                    containerSize = newSize
                    let b = FloatingAccessoryPlacement.bounds(in: geo.size, diameter: FloatingAccessoryMetrics.wheelOuterDiameter,
                                                         bottomClearance: bottomClearance)
                    let resolved = FloatingAccessoryPlacement.clamped(center ?? resolvedCenter(in: geo.size, bounds: b), in: b)
                    center = resolved
                    reportSide(of: resolved, in: newSize)
                }
                // 另一按钮拖过屏幕中线 → 本按钮立即反向吸附（实时、不等抬手；与对方跟手拖动并行）。
                // dropFirst：@Published 订阅时会重放当前值，那只是「建立订阅那一刻的旧请求」，须丢掉
                .onReceive(FloatingAccessoryCoordinator.shared.$snapRequest.dropFirst()) { req in
                    handleSnapRequest(req)
                }
                // 任一方进入手势（含本按钮环上转圈）→ 本按钮强制闲置；手势结束不自动恢复
                .onReceive(FloatingAccessoryCoordinator.shared.$activeOwner) { owner in
                    guard let owner, owner != .secondary else { return }
                    // 例外：本按钮此刻正摁着转圈 → 不执行强制闲置。
                    // 双手同时操作时（一手摁着 C' 转圈、一手拖旧按钮），旧按钮的 beginGesture 会把
                    // activeOwner 抢成 .primary 并广播过来；若在此淡出，C' 会被 opacity 0 藏掉，
                    // 而转圈走的是另一条路径、照常推进 K 线 —— 于是「转得动却看不见转了多少」，
                    // 操作反馈完全丢失。转圈是本按钮的**主动操作**，其可见性优先于耦合规则的被动淡出
                    guard touchMode != .ring else { return }
                    forceIdle()
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
    private func beginTouch(at startLocation: CGPoint, center: CGPoint) -> TouchMode {
        cancelIdleFade()
        withAnimation(.easeOut(duration: 0.12)) { isPressing = true }
        FloatingAccessoryCoordinator.shared.beginGesture(.secondary)
        let mode = resolveTouchMode(at: startLocation, center: center)
        touchMode = mode
        // 只有 B'（整钮模式）触发临时旧外观；环上转圈保留新按钮自身外观 ——
        // 否则 C' 不可见、转圈时看不到任何反馈
        showsOldLook = (mode == .whole)
        guard mode == .ring else { return mode }
        FloatingAccessoryCoordinator.shared.setRotating(true)
        // 落点即接管：C' 立即跳到落点角度（改显示偏移而非里程表，理由见 displayAngleOffset）
        let raw = rawAngleDegrees(at: startLocation, center: center)
        displayAngleOffset = raw - odometer
        lastRawAngle = raw
        return mode
    }

    /// 落点半径 → 本次触摸模式：B' 圆内 = 整钮，环 Z' 上 = 转圈
    private func resolveTouchMode(at location: CGPoint, center: CGPoint) -> TouchMode {
        let (dx, dy) = deltaFromCenter(location, center: center)
        let distance = (dx * dx + dy * dy).squareRoot()
        return distance <= Double(FloatingAccessoryMetrics.wheelInnerDiameter / 2) ? .whole : .ring
    }

    /// 转圈：用里程表累积 wrap 后的角度增量（跨 0°/360° 不会跳变）
    private func updateRingAngle(to location: CGPoint, center: CGPoint) {
        let (dx, dy) = deltaFromCenter(location, center: center)
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

    /// 落点相对圆心（容器坐标系传入的 center，即 shown）的位移；转成 Double 便于算半径与角度。
    /// 手势挂在 .position 之后，坐标是容器系，故圆心必须由调用点传入而不是写死 disc 的半宽
    private func deltaFromCenter(_ p: CGPoint, center: CGPoint) -> (dx: Double, dy: Double) {
        (Double(p.x - center.x), Double(p.y - center.y))
    }

    /// 落点的原始角度（度）：屏幕坐标 y 向下为正，故 atan2 递增 = 视觉顺时针；-90° = 12 点方向
    private func rawAngleDegrees(at location: CGPoint, center: CGPoint) -> Double {
        let (dx, dy) = deltaFromCenter(location, center: center)
        return atan2(dy, dx) * 180 / .pi
    }

    /// 开始 / 重排闲置淡出：短延时内再被触碰则本次作废。
    /// 延时用新按钮自己的 wheelIdleFadeDelay（0.5 秒，比旧按钮的 3 秒短得多）
    private func scheduleIdleFade() {
        idleFadeToken += 1
        let token = idleFadeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + FloatingAccessoryMetrics.wheelIdleFadeDelay) {
            guard token == idleFadeToken else { return }
            // 静止到点：与淡出同一时刻把外观还原为新按钮自身的稳定态
            withAnimation(.easeOut(duration: 0.45)) {
                isDimmed = true
                showsOldLook = false
            }
        }
    }

    /// 触碰即取消在途淡出并回到 100%（任何触碰后抬手也要保持 3 秒 100%）；C' 随之恢复可见
    private func cancelIdleFade() {
        idleFadeToken += 1
        if isDimmed { withAnimation(.easeOut(duration: 0.15)) { isDimmed = false } }
    }

    /// 被另一方的手势强制闲置：立即进入 25% 稳定态（C' 随之隐藏），并作废所有在途淡出计时
    /// （否则刚被触碰、自己那 3 秒计时还在途时会按自己的节奏淡出，与「立即强制闲置」时序不一致）。
    /// 这里不安排任何恢复：解锁只由本按钮下一次被触碰完成（onChanged → cancelIdleFade）
    private func forceIdle() {
        idleFadeToken += 1
        // 令牌自增会作废 scheduleIdleFade 里那个「3 秒后还原旧外观」的计时，所以这里必须一并还原：
        // 否则被对方手势强制闲置时，临时旧外观会永久留在屏幕上（再也等不到还原）
        showsOldLook = false
        if !isDimmed { withAnimation(.easeOut(duration: 0.45)) { isDimmed = true } }
    }

    /// 上报某点所在侧（协调对象据此做同侧互斥判定；不发布，可安全随时调用）。
    /// 显式传入点与尺寸，避免依赖「刚写完 @State 立刻读回」的时序
    private func reportSide(of point: CGPoint, in size: CGSize) {
        guard size.width > 0 else { return }
        FloatingAccessoryCoordinator.shared.reportSide(.secondary,
                                                       FloatingAccessoryPlacement.side(of: point, in: size))
    }

    /// 收到吸附请求（另一按钮拖过了屏幕中线）：立即吸附到目标侧边缘、纵向保持；
    /// 与对方的跟手拖动各自动画、并行不串行；落位写入自己的槽位
    private func handleSnapRequest(_ req: FloatingAccessorySnapRequest?) {
        guard let req, req.owner == .secondary, containerSize.width > 0 else { return }
        let bounds = FloatingAccessoryPlacement.bounds(in: containerSize, diameter: FloatingAccessoryMetrics.wheelOuterDiameter,
                                                       bottomClearance: bottomClearance)
        let cur = FloatingAccessoryPlacement.clamped(center ?? resolvedCenter(in: containerSize, bounds: bounds), in: bounds)
        let target = CGPoint(x: req.side == .left ? bounds.x.lowerBound : bounds.x.upperBound, y: cur.y)
        withAnimation(.easeOut(duration: 0.2)) { center = target }
        FloatingAccessoryStore.save(target, for: .secondary)
    }

    /// 果冻弹一下（参数与旧按钮一致）：先快速压缩，再用低阻尼 spring 回弹过冲。
    /// 不收 completion：点击的动作（窗口平移一根）是立即执行的，没有需要延后的东西
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
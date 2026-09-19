//
//  FloatingAccessory.swift
//  Kline
//
//  自选 / 行情页的常驻悬浮按钮（仿 iOS 辅助触控）：可拖动、松手吸附到最近左右边缘、
//  位置持久化；单击弹出底部面板（样式对齐「指标选择面板」），面板出现时按钮暂时隐藏。
//  几何 / 描边常量、落位计算、落位持久化见 FloatingAccessoryShared.swift（与新按钮共用）。
//

import SwiftUI
import Combine

// MARK: - 悬浮按钮

/// 常驻悬浮按钮（仿 iOS 辅助触控）
/// - 外观：四层同心圆（A>B>C>D）叠加，形成 Z（A–B）/ X（B–C）/ Q（C–D）/ W（D 内）四个环带；
///   A 直径为 D 的两倍、Z 环宽 = X 环宽 + Q 环宽，各圈用语义色 label 描边（两种主题都不糊边）；
///   Z 纯黑填满，X / Q / W 依次比上一层淡 50%
/// - 状态：摁住/拖动中四圈直径 +15%、整体透明度 50%；抬手恢复直径、并保持 100% 透明度 3 秒后降到 25%；点击时果冻弹一下
/// - 拖动：跟手移动，松手动画吸附到最近的左 / 右边缘（纵向位置保持），并写入 UserDefaults
/// - 点击：位移小于阈值才视为点击（拖完抬手不会误弹面板）
/// - 命中区：圆形按钮本身 56pt（≥ 项目规范的 44pt），用 contentShape(Circle()) 限定为圆形
struct FloatingAccessoryButton: View {
    let action: () -> Void

    @State private var center: CGPoint?
    /// 本次手势的实时位移：与已落位的 center 叠加显示（用 @State 而非 @GestureState，
    /// 便于在 onEnded 的同一个动画事务里把它与吸附目标一起归零，吸附过程从松手点平滑过渡）
    @State private var dragDelta: CGSize = .zero
    /// 手指是否仍按在按钮上（摁住 / 拖动中）：控制 15% 放大与 50% 透明度
    @State private var isPressing = false
    /// 是否已进入「3 秒未触碰」的低透明度状态
    @State private var isDimmed = false
    /// 点击时的果冻缩放（与 isPressing 的放大叠乘）
    @State private var jellyScale: CGFloat = 1
    /// 闲置淡出计时令牌：每次触碰自增使在途的淡出作废（比持有 DispatchWorkItem 更简单可靠）
    @State private var idleFadeToken = 0
    /// 容器尺寸缓存：吸附请求在几何闭包外用 `.onReceive` 处理，需要据此自行算出目标边缘 x
    @State private var containerSize: CGSize = .zero

    /// 整体透明度：摁住/拖动中 50%；3 秒未触碰后 25%；其余（含触碰后 3 秒内）100%
    private var overallOpacity: Double {
        if isPressing { return 0.5 }
        return isDimmed ? 0.25 : 1.0
    }

    /// 四层同心圆：面积自外向内递减，靠后绘制的内圈覆盖外圈即自然形成 Z / X / Q / W 四个环带；
    /// 每圈用语义色 label 描边（浓度自外向内按 50% 递减，strokeBorder 内描边、不影响直径与环宽）
    private var rings: some View {
        // 局部简写：几何与描边常量统一由 FloatingAccessoryMetrics 提供（与新按钮共用）
        let ratios = FloatingAccessoryMetrics.radiusRatios
        let colors = FloatingAccessoryMetrics.bandColors
        let opacities = FloatingAccessoryMetrics.ringStrokeOpacities
        let stroke = FloatingAccessoryMetrics.ringStroke
        let strokeWidth = FloatingAccessoryMetrics.ringStrokeWidth
        return ZStack {
            ForEach(Array(ratios.enumerated()), id: \.offset) { i, ratio in
                let d = FloatingAccessoryMetrics.baseDiameter * ratio
                Circle()
                    .fill(colors[min(i, colors.count - 1)])
                    .overlay(Circle().strokeBorder(stroke.opacity(opacities[min(i, opacities.count - 1)]),
                                                   lineWidth: strokeWidth))
                    .frame(width: d, height: d)
            }
        }
        .frame(width: FloatingAccessoryMetrics.baseDiameter, height: FloatingAccessoryMetrics.baseDiameter)
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

    /// 触碰即取消在途淡出并回到 100%（任何触碰后抬手也要保持 3 秒 100%）
    private func cancelIdleFade() {
        idleFadeToken += 1
        if isDimmed { withAnimation(.easeOut(duration: 0.15)) { isDimmed = false } }
    }

    /// 被另一方的手势强制闲置：立即进入 25% 稳定态，并作废所有在途淡出计时
    /// （否则刚被触碰、自己那 3 秒计时还在途时会按自己的节奏淡出，与「立即强制闲置」时序不一致）。
    /// 这里不安排任何恢复：解锁只由本按钮下一次被触碰完成（onChanged → cancelIdleFade）
    private func forceIdle() {
        idleFadeToken += 1
        if !isDimmed { withAnimation(.easeOut(duration: 0.45)) { isDimmed = true } }
    }

    /// 上报某点所在侧（协调对象据此做同侧互斥判定；不发布，可安全随时调用）。
    /// 显式传入点与尺寸，避免依赖「刚写完 @State 立刻读回」的时序
    private func reportSide(of point: CGPoint, in size: CGSize) {
        guard size.width > 0 else { return }
        FloatingAccessoryCoordinator.shared.reportSide(.primary,
                                                       FloatingAccessoryPlacement.side(of: point, in: size))
    }

    /// 收到吸附请求（另一按钮拖过了屏幕中线）：立即吸附到目标侧边缘、纵向保持；
    /// 与对方的跟手拖动各自动画、并行不串行；落位写入自己的槽位
    private func handleSnapRequest(_ req: FloatingAccessorySnapRequest?) {
        guard let req, req.owner == .primary, containerSize.width > 0 else { return }
        let bounds = FloatingAccessoryPlacement.bounds(in: containerSize, diameter: FloatingAccessoryMetrics.baseDiameter)
        let cur = FloatingAccessoryPlacement.clamped(center ?? defaultCenter(in: containerSize, bounds: bounds), in: bounds)
        let target = CGPoint(x: req.side == .left ? bounds.x.lowerBound : bounds.x.upperBound, y: cur.y)
        withAnimation(.easeOut(duration: 0.2)) { center = target }
        FloatingAccessoryStore.save(target, for: .primary)
    }

    /// 果冻弹一下：先快速压缩，再用低阻尼 spring 回弹过冲；
    /// `completion` 延后到弹性反馈可见之后再执行（否则面板一弹出按钮就隐藏，看不到果冻）
    private func playJelly(completion: @escaping () -> Void) {
        withAnimation(.easeOut(duration: 0.08)) { jellyScale = 0.82 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.34)) { jellyScale = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: completion)
    }

    var body: some View {
        GeometryReader { geo in
            let bounds = FloatingAccessoryPlacement.bounds(in: geo.size, diameter: FloatingAccessoryMetrics.baseDiameter)
            let base = FloatingAccessoryPlacement.clamped(center ?? defaultCenter(in: geo.size, bounds: bounds), in: bounds)
            let shown = FloatingAccessoryPlacement.clamped(CGPoint(x: base.x + dragDelta.width, y: base.y + dragDelta.height), in: bounds)
            rings
            // 摁住/拖动放大 15%（整体缩放，四圈直径同步 +15%），叠加点击时的果冻缩放
            .scaleEffect((isPressing ? FloatingAccessoryMetrics.pressScaleFactor : 1) * jellyScale)
            // ⚠️ 必须先 compositingGroup 再 opacity：四层圆是相互重叠的子视图，
            // SwiftUI 的 .opacity 默认逐层施加、不做离屏合成，于是 Z/X/Q/W 分别被叠加
            // 1/2/3/4 次半透明混合，α<1 时内圈反而比外圈更深（α=1 时因填充不透明而看不出）。
            // compositingGroup 把四圈先合成为一张图，再整体乘透明度，
            // 保证 50% / 25% 两态的深浅顺序与 100% 态完全一致
            .compositingGroup()
            .opacity(overallOpacity)
            .contentShape(Circle())
            .position(shown)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if !isPressing {
                            cancelIdleFade()
                            withAnimation(.easeOut(duration: 0.12)) { isPressing = true }
                            FloatingAccessoryCoordinator.shared.beginGesture(.primary)
                        }
                        dragDelta = value.translation
                        // 同侧互斥每帧判定（廉价读字典，不发布）：中心越过屏幕中线时请求另一按钮反向吸附
                        let dragged = FloatingAccessoryPlacement.clamped(CGPoint(x: base.x + value.translation.width,
                                                                                y: base.y + value.translation.height),
                                                                       in: bounds)
                        FloatingAccessoryCoordinator.shared.reportDrag(owner: .primary,
                                                                       side: FloatingAccessoryPlacement.side(of: dragged, in: geo.size))
                    }
                    .onEnded { value in
                        withAnimation(.easeOut(duration: 0.15)) { isPressing = false }
                        FloatingAccessoryCoordinator.shared.endGesture(.primary)
                        let t = value.translation
                        let moved = max(abs(t.width), abs(t.height)) > FloatingAccessoryMetrics.tapSlop
                        if !moved {
                            // 点击：先复位位移、果冻弹一下，再触发动作（不再吸附，避免按钮被拖动后停在偏移处）
                            dragDelta = .zero
                            playJelly(completion: action)
                        } else {
                            let raw = FloatingAccessoryPlacement.clamped(CGPoint(x: base.x + t.width, y: base.y + t.height), in: bounds)
                            // 吸附到更近的一侧边缘（纵向保持）
                            let left = bounds.x.lowerBound
                            let right = bounds.x.upperBound
                            let target = CGPoint(x: (raw.x - left <= right - raw.x) ? left : right, y: raw.y)
                            withAnimation(.easeOut(duration: 0.2)) {
                                center = target
                                dragDelta = .zero
                            }
                            FloatingAccessoryStore.save(target, for: .primary)
                            // 抬手后的最终侧上报：协调对象据此继续保证两侧互斥
                            FloatingAccessoryCoordinator.shared.reportSide(.primary,
                                                                           FloatingAccessoryPlacement.side(of: target, in: geo.size))
                        }
                        // 任何触碰后抬手：保持 100% 透明度 3 秒，再降到 25%
                        scheduleIdleFade()
                    }
            )
            .onAppear {
                containerSize = geo.size
                let resolved = FloatingAccessoryPlacement.clamped(center ?? defaultCenter(in: geo.size, bounds: bounds), in: bounds)
                center = resolved
                reportSide(of: resolved, in: geo.size)
                // 初始 100% 起算：3 秒未触碰即降到 25%
                scheduleIdleFade()
            }
            .onDisappear {
                idleFadeToken += 1
                // 手势被打断时不会有 onEnded：占用者必须复位，否则另一方会被永久强制闲置
                FloatingAccessoryCoordinator.shared.endGesture(.primary)
            }
            // 尺寸变化（旋转 / 分屏 / 多任务）后把已落位点夹回可视范围，避免停在屏幕外
            .onChange(of: geo.size) { newSize in
                containerSize = newSize
                let b = FloatingAccessoryPlacement.bounds(in: geo.size, diameter: FloatingAccessoryMetrics.baseDiameter)
                let resolved = FloatingAccessoryPlacement.clamped(center ?? defaultCenter(in: geo.size, bounds: b), in: b)
                center = resolved
                reportSide(of: resolved, in: newSize)
            }
            // 另一按钮拖过屏幕中线 → 本按钮立即反向吸附（实时、不等抬手；与对方跟手拖动并行）。
            // dropFirst：@Published 订阅时会重放当前值，那只是「建立订阅那一刻的旧请求」，须丢掉
            .onReceive(FloatingAccessoryCoordinator.shared.$snapRequest.dropFirst()) { req in
                handleSnapRequest(req)
            }
            // 任一方进入手势（含新按钮环上转圈）→ 本按钮强制闲置；手势结束不自动恢复
            .onReceive(FloatingAccessoryCoordinator.shared.$activeOwner) { owner in
                guard let owner, owner != .primary else { return }
                forceIdle()
            }
            .accessibilityIdentifier("accessory.button")
        }
    }

    /// 默认落位：右侧贴边、纵向约 40% 高度（首次启动时用；之后以用户拖动后的落位为准）
    private func defaultCenter(in size: CGSize, bounds: FloatingAccessoryPlacement.Bounds) -> CGPoint {
        if let saved = FloatingAccessoryStore.savedCenter(for: .primary) { return saved }
        return FloatingAccessoryPlacement.edgeCenter(on: .right, in: size, bounds: bounds)
    }
}

// MARK: - 底部面板

/// 悬浮按钮点开的底部面板：样式对齐「指标选择面板」——35% 黑色遮罩（点击关闭）、
/// 贴底面板（只圆顶部两角，底边直达物理屏幕底边）、头部标题 + 关闭按钮。
/// 内容区暂空，仅放头部控件，待确认悬浮按钮手感后再填充。
struct FloatingAccessoryPanel: View {
    /// 面板高度占屏幕高度比例（内容为空时的临时高度，填充内容后再调整）
    var heightFraction: CGFloat = 0.5
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { onClose() } }
                VStack(spacing: 0) {
                    // 头部：标题 + 关闭（字号/间距对齐 sheetHeader）
                    HStack {
                        Text("快捷面板")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.primary)
                        Spacer()
                        Button("关闭") { withAnimation(.easeOut(duration: 0.15)) { onClose() } }
                            .font(.system(size: 14))
                            .foregroundColor(.blue)
                            .accessibilityIdentifier("accessory.close")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    Divider()
                    // 内容区：暂空
                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width, height: min(geo.size.height * heightFraction, 660))
                .background(Color(.systemBackground))
                // 只圆顶部两角：底边贴紧物理屏幕底边后，底部若保留圆角，两角会露出深色遮罩
                .clipShape(TopRoundedCornerRect(radius: 16))
                // ⚠️ 固定高度面板直接加 .ignoresSafeArea 无效：容器内默认居中放置，
                // 面板只下移半个 inset、底部仍留灰缝（露出遮罩）。必须用贪婪 frame(alignment:.bottom)
                // 把面板钉在容器底边（与 bottomSheet 同一处理）
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
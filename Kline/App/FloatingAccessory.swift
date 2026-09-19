//
//  FloatingAccessory.swift
//  Kline
//
//  自选 / 行情页的常驻悬浮按钮（仿 iOS 辅助触控）：可拖动、松手吸附到最近左右边缘、
//  位置持久化；单击弹出底部面板（样式对齐「指标选择面板」），面板出现时按钮暂时隐藏。
//

import SwiftUI

// MARK: - 位置持久化

/// 悬浮按钮落位持久化（沿用项目 kline.* key 惯例，与 ChartConfigStore / KlineThemeStore 一致）
private enum FloatingAccessoryStore {
    private static let xKey = "kline.accessory.centerX"
    private static let yKey = "kline.accessory.centerY"

    /// 已保存的中心点；从未拖动过返回 nil（调用点用默认落位）
    static var savedCenter: CGPoint? {
        let d = UserDefaults.standard
        guard d.object(forKey: xKey) != nil, d.object(forKey: yKey) != nil else { return nil }
        return CGPoint(x: d.double(forKey: xKey), y: d.double(forKey: yKey))
    }

    static func save(_ p: CGPoint) {
        let d = UserDefaults.standard
        d.set(Double(p.x), forKey: xKey)
        d.set(Double(p.y), forKey: yKey)
    }
}

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

    /// 按钮直径（= 最外圈 A 的直径，同时也是命中区直径）
    private let diameter: CGFloat = 56
    /// 贴边（吸附后 / 默认落位）与屏幕边缘的间距
    private let edgeInset: CGFloat = 8
    /// 判定为「点击」的最大位移；超过即视为拖动
    private let tapSlop: CGFloat = 6

    /// 四层同心圆的半径（相对最外圈 A 的比例）：A=1、B=0.75、C=0.625、D=0.5
    /// 即直径 56 / 42 / 35 / 28（半径 28 / 21 / 17.5 / 14）
    /// 推导：① A 是 D 的两倍（A_r = 2·D_r → D_r = 14）；② Z 环宽 = X 环宽 + Q 环宽，
    /// 即 (A_r − B_r) = (B_r − C_r) + (C_r − D_r) = B_r − D_r → B_r = (A_r + D_r)/2 = 21（B 由②唯一确定）。
    /// C 未被②约束到，取「X 与 Q 等宽」补齐 → C_r = (B_r + D_r)/2 = 17.5，
    /// 于是环宽 Z=7、X=3.5、Q=3.5（X+Q=7=Z ✓）。若想让 X≠Q，只改本数组里 C 的取值即可
    private let radiusRatios: [CGFloat] = [1, 0.75, 0.625, 0.5]
    /// 四层的填充色（自外向内）：Z 纯黑填满，X / Q / W 依次比上一层「淡 50%」（向白色混合 50%）
    /// 若想改成「黑色透明度逐层减半（1 / 0.5 / 0.25 / 0.125）」，改这一个数组即可
    private let bandColors: [Color] = [
        Color(white: 0),      // Z：黑
        Color(white: 0.5),    // X：比 Z 淡 50%
        Color(white: 0.75),   // Q：比 X 淡 50%
        Color(white: 0.875)   // W：比 Q 淡 50%
    ]
    /// 四圈的描边色：用语义色 label（浅色模式=黑、深色模式=白），保证两种主题下
    /// 每圈边界都清晰（深色模式下最外圈纯黑会与深色背景糊在一起，白描边正是用来勾出轮廓的）
    private let ringStroke: Color = Color(.label)
    /// 描边宽度：1pt（strokeBorder 内描边，不改变各圈直径与环宽）
    private let ringStrokeWidth: CGFloat = 1
    /// 摁住 / 拖动时四圈直径的放大比例（+15%），抬手即恢复
    private let pressScaleFactor: CGFloat = 1.15
    /// 未被触碰多久后整体降到 25% 透明度
    private let idleFadeDelay: TimeInterval = 3

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

    /// 整体透明度：摁住/拖动中 50%；3 秒未触碰后 25%；其余（含触碰后 3 秒内）100%
    private var overallOpacity: Double {
        if isPressing { return 0.5 }
        return isDimmed ? 0.25 : 1.0
    }

    /// 四层同心圆：面积自外向内递减，靠后绘制的内圈覆盖外圈即自然形成 Z / X / Q / W 四个环带；
    /// 每圈用语义色 label 描边（strokeBorder 内描边，不影响直径与环宽）
    private var rings: some View {
        ZStack {
            ForEach(Array(radiusRatios.enumerated()), id: \.offset) { i, ratio in
                let d = diameter * ratio
                Circle()
                    .fill(bandColors[min(i, bandColors.count - 1)])
                    .overlay(Circle().strokeBorder(ringStroke, lineWidth: ringStrokeWidth))
                    .frame(width: d, height: d)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// 开始 / 重排闲置淡出：3 秒内再被触碰则本次作废
    private func scheduleIdleFade() {
        idleFadeToken += 1
        let token = idleFadeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + idleFadeDelay) {
            guard token == idleFadeToken else { return }
            withAnimation(.easeOut(duration: 0.45)) { isDimmed = true }
        }
    }

    /// 触碰即取消在途淡出并回到 100%（任何触碰后抬手也要保持 3 秒 100%）
    private func cancelIdleFade() {
        idleFadeToken += 1
        if isDimmed { withAnimation(.easeOut(duration: 0.15)) { isDimmed = false } }
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
            let bounds = centerBounds(in: geo.size)
            let base = clamped(center ?? defaultCenter(in: geo.size, bounds: bounds), bounds: bounds)
            let shown = clamped(CGPoint(x: base.x + dragDelta.width, y: base.y + dragDelta.height), bounds: bounds)
            rings
            // 摁住/拖动放大 15%（整体缩放，四圈直径同步 +15%），叠加点击时的果冻缩放
            .scaleEffect((isPressing ? pressScaleFactor : 1) * jellyScale)
            .shadow(color: Color.black.opacity(0.25), radius: 8, y: 3)
            .opacity(overallOpacity)
            .contentShape(Circle())
            .position(shown)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if !isPressing {
                            cancelIdleFade()
                            withAnimation(.easeOut(duration: 0.12)) { isPressing = true }
                        }
                        dragDelta = value.translation
                    }
                    .onEnded { value in
                        withAnimation(.easeOut(duration: 0.15)) { isPressing = false }
                        let t = value.translation
                        let moved = max(abs(t.width), abs(t.height)) > tapSlop
                        if !moved {
                            // 点击：先复位位移、果冻弹一下，再触发动作（不再吸附，避免按钮被拖动后停在偏移处）
                            dragDelta = .zero
                            playJelly(completion: action)
                        } else {
                            let raw = clamped(CGPoint(x: base.x + t.width, y: base.y + t.height), bounds: bounds)
                            // 吸附到更近的一侧边缘（纵向保持）
                            let left = bounds.x.lowerBound
                            let right = bounds.x.upperBound
                            let target = CGPoint(x: (raw.x - left <= right - raw.x) ? left : right, y: raw.y)
                            withAnimation(.easeOut(duration: 0.2)) {
                                center = target
                                dragDelta = .zero
                            }
                            FloatingAccessoryStore.save(target)
                        }
                        // 任何触碰后抬手：保持 100% 透明度 3 秒，再降到 25%
                        scheduleIdleFade()
                    }
            )
            .onAppear {
                center = clamped(center ?? defaultCenter(in: geo.size, bounds: bounds), bounds: bounds)
                // 初始 100% 起算：3 秒未触碰即降到 25%
                scheduleIdleFade()
            }
            .onDisappear { idleFadeToken += 1 }
            // 尺寸变化（旋转 / 分屏 / 多任务）后把已落位点夹回可视范围，避免停在屏幕外
            .onChange(of: geo.size) { _ in
                let b = centerBounds(in: geo.size)
                center = clamped(center ?? defaultCenter(in: geo.size, bounds: b), bounds: b)
            }
            .accessibilityIdentifier("accessory.button")
        }
    }

    /// 中心点的合法范围：四周留 edgeInset（上下另留 4pt），保证圆钮整体始终在屏内
    private func centerBounds(in size: CGSize) -> (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) {
        let half = diameter / 2
        let minX = half + edgeInset
        let maxX = max(minX, size.width - half - edgeInset)
        let minY = half + 4
        let maxY = max(minY, size.height - half - 4)
        return (minX...maxX, minY...maxY)
    }

    private func clamped(_ p: CGPoint, bounds: (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>)) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.x.lowerBound), bounds.x.upperBound),
                y: min(max(p.y, bounds.y.lowerBound), bounds.y.upperBound))
    }

    /// 默认落位：右侧贴边、纵向约 40% 高度（首次启动时用；之后以用户拖动后的落位为准）
    private func defaultCenter(in size: CGSize, bounds: (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>)) -> CGPoint {
        if let saved = FloatingAccessoryStore.savedCenter { return saved }
        return CGPoint(x: bounds.x.upperBound, y: size.height * 0.4)
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
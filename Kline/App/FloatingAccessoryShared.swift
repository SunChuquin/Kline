//
//  FloatingAccessoryShared.swift
//  Kline
//
//  两个悬浮按钮（旧按钮 FloatingAccessoryButton / 新按钮 FloatingAccessoryWheel）
//  共用的原语：几何与描边常量、落位计算、落位持久化。
//  抽出前后旧按钮的可见行为完全一致（纯行为中性重构）。
//

import SwiftUI

// MARK: - 几何 / 样式常量

/// 悬浮按钮的几何与样式常量。所有尺寸都由「旧按钮最外圈 A 的直径」派生，便于单点调整
enum FloatingAccessoryMetrics {

    // MARK: 基准

    /// 旧按钮最外圈 A 的直径，同时也是旧按钮的命中区直径。全部悬浮按钮几何的基准值
    static let baseDiameter: CGFloat = 56

    // MARK: 两按钮共用

    /// 描边色：语义色 label（浅色模式=黑、深色模式=白），深浅两主题下都能勾出轮廓
    static let ringStroke: Color = Color(.label)
    /// 描边宽度：1pt（strokeBorder 内描边，不改变各圈直径与环宽）
    static let ringStrokeWidth: CGFloat = 1
    /// 贴边（吸附后 / 默认落位）与屏幕左右边缘的间距
    static let edgeInset: CGFloat = 8
    /// 与屏幕上下的间距（比左右略小）
    static let verticalInset: CGFloat = 4
    /// 默认落位的纵向位置占屏高比例
    static let defaultVerticalFraction: CGFloat = 0.4
    /// 判定为「点击」的最大位移；超过即视为拖动
    static let tapSlop: CGFloat = 6
    /// 摁住 / 拖动时直径的放大比例（+15%），抬手即恢复
    static let pressScaleFactor: CGFloat = 1.15
    /// 未被触碰多久后整体降到 25% 透明度（**旧按钮**；新按钮见 wheelIdleFadeDelay）
    static let idleFadeDelay: TimeInterval = 3
    /// 新按钮的闲置淡出延时：比旧按钮短得多（0.5 秒）。
    /// 它同时也是「临时旧外观」的还原时刻 —— 两者共用同一条计时，见 scheduleIdleFade
    static let wheelIdleFadeDelay: TimeInterval = 0.5

    // MARK: 旧按钮四层同心圆 A / B / C / D

    /// 四层同心圆的半径（相对最外圈 A 的比例）：A=1、B=0.75、C=0.625、D=0.5
    /// 即直径 56 / 42 / 35 / 28（半径 28 / 21 / 17.5 / 14）
    /// 推导：① A 是 D 的两倍（A_r = 2·D_r → D_r = 14）；② Z 环宽 = X 环宽 + Q 环宽，
    /// 即 (A_r − B_r) = (B_r − C_r) + (C_r − D_r) = B_r − D_r → B_r = (A_r + D_r)/2 = 21（B 由②唯一确定）。
    /// C 未被②约束到，取「X 与 Q 等宽」补齐 → C_r = (B_r + D_r)/2 = 17.5，
    /// 于是环宽 Z=7、X=3.5、Q=3.5（X+Q=7=Z ✓）。若想让 X≠Q，只改本数组里 C 的取值即可
    static let radiusRatios: [CGFloat] = [1, 0.75, 0.625, 0.5]
    /// 四层的填充色（自外向内）：Z 纯黑填满，X / Q / W 依次比上一层「淡 50%」（向白色混合 50%）
    /// 若想改成「黑色透明度逐层减半（1 / 0.5 / 0.25 / 0.125）」，改这一个数组即可
    static let bandColors: [Color] = [
        Color(white: 0),      // Z：黑
        Color(white: 0.5),    // X：比 Z 淡 50%
        Color(white: 0.75),   // Q：比 X 淡 50%
        Color(white: 0.875)   // W：比 Q 淡 50%
    ]
    /// 四圈描边的浓度（自外向内）：与填充色同样按「每层淡 50%」递减 —— Z 1、X 0.5、Q 0.25、W 0.125
    static let ringStrokeOpacities: [Double] = [1, 0.5, 0.25, 0.125]

    // MARK: 新按钮三圆 A' / B' / C'（环 Z'）

    /// B' 直径 = 旧按钮 A 直径 × 1.3
    static let wheelInnerDiameter: CGFloat = baseDiameter * 1.3
    /// 环 Z' 宽度 = 旧按钮 A 直径 ÷ 2（等于旧按钮 D 的直径 28）
    static let wheelRingWidth: CGFloat = baseDiameter / 2
    /// C' 的外描边宽度：使视觉直径由 27 长到 28（= 环 Z' 宽），即「C' 与环内外各余 0.5」的来源
    static let wheelDotStrokeWidth: CGFloat = 1
    /// C' 直径 = 环 Z' 宽 − 外描边宽度（那 1pt 被 C' 的外描边占用，见上一条）
    static let wheelDotDiameter: CGFloat = wheelRingWidth - wheelDotStrokeWidth
    /// A' 直径 = B' + 2 × 环 Z'（72.8 + 56）
    static let wheelOuterDiameter: CGFloat = wheelInnerDiameter + 2 * wheelRingWidth
    /// C' 圆心的轨迹半径 = (A'半径 + B'半径) ÷ 2
    /// 校验：该值恰好等于环 Z' 的中径（内边界 B'半径 36.4、外边界 A'半径 64.4 的中点 50.4）；
    /// C' 最内点 = 50.4 − 13.5 = 36.9（距环内边界 36.4 余 0.5）、最外点 = 50.4 + 13.5 = 63.9
    /// （距环外边界 64.4 余 0.5）—— 即 C' 几乎撑满整条环，内外各余 0.5
    static let wheelDotTrackRadius: CGFloat = (wheelOuterDiameter / 2 + wheelInnerDiameter / 2) / 2
}

// MARK: - 角度

/// 角度工具（新按钮环上转圈用）
enum FloatingAccessoryAngle {
    /// 把角度差折算到 (-180, 180]：超过半圈时做 ±360 修正。
    /// 用于里程表增量，避免 359° → 0° 被当成 −359° 的反向跳变
    static func wrap(_ delta: Double) -> Double {
        var d = delta.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }
}

// MARK: - 旧按钮的四层同心圆图形（可复用）

/// 旧按钮的图形本体：四层同心圆 A/B/C/D 叠加成 Z（A–B）/ X（B–C）/ Q（C–D）/ W（D 内）四个环带，
/// Z 纯黑填满、X / Q / W 依次比上一层淡 50%，每圈用语义色描边（浓度自外向内按 50% 递减）。
/// 抽成可复用视图的原因：新按钮在「B' 被操作」期间要整体换成旧按钮的外观，
/// 直接复用这一份图形，不再复制粘贴四环绘制代码。
/// `diameter` 只等比缩放几何；描边宽度恒为 `ringStrokeWidth`（与旧按钮一致，不随直径放大）
struct FloatingAccessoryRings: View {
    var diameter: CGFloat = FloatingAccessoryMetrics.baseDiameter

    private let ratios = FloatingAccessoryMetrics.radiusRatios
    private let colors = FloatingAccessoryMetrics.bandColors
    private let opacities = FloatingAccessoryMetrics.ringStrokeOpacities
    private let stroke = FloatingAccessoryMetrics.ringStroke
    private let strokeWidth = FloatingAccessoryMetrics.ringStrokeWidth

    var body: some View {
        ZStack {
            ForEach(Array(ratios.enumerated()), id: \.offset) { i, ratio in
                let d = diameter * ratio
                Circle()
                    .fill(colors[min(i, colors.count - 1)])
                    .overlay(Circle().strokeBorder(stroke.opacity(opacities[min(i, opacities.count - 1)]),
                                                   lineWidth: strokeWidth))
                    .frame(width: d, height: d)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - 「光标自动移动时隐藏悬浮按钮」共用修饰符

/// 联动多图模式下光标自动移动（贴边自动滚动、抬手后继续）期间，把整个悬浮按钮隐藏并关闭命中，
/// 自动移动结束后恢复。两个按钮**各自订阅、各自隐藏** —— 不把协调对象挂到 `ContentView` 上观察，
/// 免得高频命令发布（转圈的每根推进、每次点击）引起根视图整树重算
private struct AccessoryAutoMoveHider: ViewModifier {
    @State private var isAutoMoving = false

    func body(content: Content) -> some View {
        content
            .opacity(isAutoMoving ? 0 : 1)
            .allowsHitTesting(!isAutoMoving)
            // 订阅 @Published 时会立即重放当前值，正好把初始状态对齐
            .onReceive(FloatingAccessoryCoordinator.shared.$isCursorAutoMoving) { on in
                withAnimation(.easeOut(duration: 0.2)) { isAutoMoving = on }
            }
    }
}

extension View {
    /// 联动多图模式下光标自动移动时隐藏本视图（见 AccessoryAutoMoveHider）
    func hidesDuringCursorAutoMove() -> some View { modifier(AccessoryAutoMoveHider()) }
}

// MARK: - 落位计算

/// 悬浮按钮的落位计算：中心点合法范围、夹取、贴指定侧落位、判定落在哪一侧
enum FloatingAccessoryPlacement {

    /// 中心点的合法范围（保证整个圆钮在屏内）
    struct Bounds {
        let x: ClosedRange<CGFloat>
        let y: ClosedRange<CGFloat>
    }

    enum Side {
        case left, right

        /// 对侧
        var opposite: Side { self == .left ? .right : .left }
    }

    /// 中心点的合法范围：四周留 edgeInset，上下另留 verticalInset。
    /// 这两道边距都是**静止态**的口径，另外还要按直径预留「摁住放大 15%」向外扩出的那一圈：
    /// 放大由 scaleEffect 施加，不改变布局 frame，落位范围若只按静止半径算，
    /// 贴边（尤其贴角，水平与垂直同时贴）时放大后就会溢出屏幕两侧。
    /// 预留方式是**相加**而非取大：这样放大后剩余的天空恰等于静止时的边距（左右 8 / 上下 4），
    /// 既不会溢出，也仍看得见空隙
    static func bounds(in size: CGSize, diameter: CGFloat) -> Bounds {
        let half = diameter / 2
        let grow = half * (FloatingAccessoryMetrics.pressScaleFactor - 1)
        let minX = half + FloatingAccessoryMetrics.edgeInset + grow
        let maxX = max(minX, size.width - half - FloatingAccessoryMetrics.edgeInset - grow)
        let minY = half + FloatingAccessoryMetrics.verticalInset + grow
        let maxY = max(minY, size.height - half - FloatingAccessoryMetrics.verticalInset - grow)
        return Bounds(x: minX...maxX, y: minY...maxY)
    }

    /// 把中心点夹回合法范围
    static func clamped(_ p: CGPoint, in bounds: Bounds) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.x.lowerBound), bounds.x.upperBound),
                y: min(max(p.y, bounds.y.lowerBound), bounds.y.upperBound))
    }

    /// 贴指定侧边缘、纵向按 verticalFraction 的落位点
    static func edgeCenter(on side: Side,
                           in size: CGSize,
                           bounds: Bounds,
                           verticalFraction: CGFloat = FloatingAccessoryMetrics.defaultVerticalFraction) -> CGPoint {
        CGPoint(x: side == .left ? bounds.x.lowerBound : bounds.x.upperBound,
                y: size.height * verticalFraction)
    }

    /// 判定一个中心点落在哪一侧。左右合法范围关于 size.width/2 对称，
    /// 故与旧按钮吸附时「比较到两侧贴边点的距离」的口径完全等价
    static func side(of center: CGPoint, in size: CGSize) -> Side {
        center.x <= size.width / 2 ? .left : .right
    }
}

// MARK: - 落位持久化

/// 悬浮按钮的持久化槽位：每个槽位一组独立 key（沿用项目 kline.* key 惯例，与 ChartConfigStore / KlineThemeStore 一致）
enum FloatingAccessorySlot {
    /// 旧按钮
    case primary
    /// 新按钮
    case secondary

    /// key 前缀。primary 的 key 不能变，否则用户已有落位丢失
    var keyPrefix: String {
        switch self {
        case .primary: return "kline.accessory"
        case .secondary: return "kline.accessory2"
        }
    }
}

/// 悬浮按钮落位持久化
enum FloatingAccessoryStore {

    /// 已保存的中心点；从未拖动过返回 nil（调用点用默认落位）
    static func savedCenter(for slot: FloatingAccessorySlot) -> CGPoint? {
        let d = UserDefaults.standard
        let xKey = slot.keyPrefix + ".centerX"
        let yKey = slot.keyPrefix + ".centerY"
        guard d.object(forKey: xKey) != nil, d.object(forKey: yKey) != nil else { return nil }
        return CGPoint(x: d.double(forKey: xKey), y: d.double(forKey: yKey))
    }

    static func save(_ p: CGPoint, for slot: FloatingAccessorySlot) {
        let d = UserDefaults.standard
        d.set(Double(p.x), forKey: slot.keyPrefix + ".centerX")
        d.set(Double(p.y), forKey: slot.keyPrefix + ".centerY")
    }
}
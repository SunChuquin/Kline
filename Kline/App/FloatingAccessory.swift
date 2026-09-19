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
/// - 拖动：跟手移动，松手动画吸附到最近的左 / 右边缘（纵向位置保持），并写入 UserDefaults
/// - 点击：位移小于阈值才视为点击（拖完抬手不会误弹面板）
/// - 命中区：圆形按钮本身 56pt（≥ 项目规范的 44pt），用 contentShape(Circle()) 限定为圆形
struct FloatingAccessoryButton: View {
    let action: () -> Void

    /// 按钮直径（同时即命中区直径）
    private let diameter: CGFloat = 56
    /// 贴边（吸附后 / 默认落位）与屏幕边缘的间距
    private let edgeInset: CGFloat = 8
    /// 判定为「点击」的最大位移；超过即视为拖动
    private let tapSlop: CGFloat = 6

    @State private var center: CGPoint?
    /// 本次手势的实时位移：与已落位的 center 叠加显示（用 @State 而非 @GestureState，
    /// 便于在 onEnded 的同一个动画事务里把它与吸附目标一起归零，吸附过程从松手点平滑过渡）
    @State private var dragDelta: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let bounds = centerBounds(in: geo.size)
            let base = clamped(center ?? defaultCenter(in: geo.size, bounds: bounds), bounds: bounds)
            let shown = clamped(CGPoint(x: base.x + dragDelta.width, y: base.y + dragDelta.height), bounds: bounds)
            ZStack {
                Circle().fill(Color.black.opacity(0.55))
                // 深色底 + 白色描边：浅色/深色模式都可辨识（辅助触控本身即恒定的深色半透明圆钮）
                Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: Color.black.opacity(0.25), radius: 8, y: 3)
            .contentShape(Circle())
            .position(shown)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        dragDelta = value.translation
                    }
                    .onEnded { value in
                        let t = value.translation
                        let moved = max(abs(t.width), abs(t.height)) > tapSlop
                        guard moved else {
                            // 点击：先复位位移再触发，避免按钮随手指微移后停在偏移处
                            dragDelta = .zero
                            action()
                            return
                        }
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
            )
            .onAppear { center = clamped(center ?? defaultCenter(in: geo.size, bounds: bounds), bounds: bounds) }
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
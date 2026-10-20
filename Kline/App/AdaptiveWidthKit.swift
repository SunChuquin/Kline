//
//  AdaptiveWidthKit.swift
//  Kline
//
//  窄屏（紧凑宽度）适配基建：CompactWidth 阈值判定 + WidthReader 可用宽度测量。
//  背景：App 按 iPad mini 5（1024×768）调校，iPhone 竖屏（如 iPhone 11 的 414pt）
//  上多个页面固有最小宽超过屏宽，页面需按「可用宽度」切换紧凑布局。
//  只放宽度判定/测量相关的轻量基建，勿在此堆积具体页面的适配逻辑。
//

import SwiftUI

// MARK: - 紧凑宽度阈值

/// 紧凑宽度阈值：页面可用宽度 < 600 视为紧凑（窄屏）形态。
/// 取值依据（真机实测可用宽度）：
/// - iPhone 11 竖屏 414pt → 命中紧凑（需要窄屏适配）
/// - iPhone 11 横屏 848pt → 不命中（沿用宽屏布局）
/// - iPad mini 5 横屏 1024pt → 不命中（App 的原始调校目标机型）
/// 600 恰好把「iPhone 竖屏（普遍 ≤ 430pt）」与「iPhone 横屏及以上」一刀切开；
/// 各页面统一用 `availableWidth < CompactWidth.threshold` 判定，勿各自另拍阈值。
enum CompactWidth {
    static let threshold: CGFloat = 600
}

// MARK: - 可用宽度测量

/// 轻量可用宽度测量封装：把父容器提议给本层的可用宽度经 `onChange` 回调上报给
/// 调用方的 `@State`，调用方再与 `CompactWidth.threshold` 比较即可切换紧凑布局。
/// ⚠️ WidthReader 会占满提议空间（GeometryReader 特性），**只用于页面顶层包裹**，
/// 勿嵌在会被它撑开、或其贪婪尺寸会挤歪兄弟视图的位置。
/// iOS 15 兼容：使用 onChange(of:perform:) 单参回调（iOS 14+ 可用），
/// 勿用 iOS 17 才有的双参 onChange(of:initial:) 重载。
struct WidthReader<Content: View>: View {
    /// 可用宽度上报回调：首帧 onAppear 触发一次，宽度变化时 onChange 跟随触发
    let onChange: (CGFloat) -> Void
    /// 被包裹的页面内容
    private let content: () -> Content

    init(onChange: @escaping (CGFloat) -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.onChange = onChange
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            content()
                .onAppear { onChange(geo.size.width) }
                .onChange(of: geo.size.width) { onChange($0) }
        }
    }
}

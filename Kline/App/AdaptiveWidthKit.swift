//
//  AdaptiveWidthKit.swift
//  Kline
//
//  窄屏（紧凑宽度）适配基建：CompactWidth 阈值判定 + WidthReader 可用宽度测量
//  + AdaptiveStack 自适应堆栈。
//  背景：App 按 iPad mini 5（1024×768）调校，iPhone 竖屏（如 iPhone 11 的 414pt）
//  上多个页面固有最小宽超过屏宽，页面需按「可用宽度」切换紧凑布局。
//  只放宽度判定/测量/通用堆栈相关的轻量基建，勿在此堆积具体页面的适配逻辑。
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

// MARK: - 自适应堆栈（竖屏垂直 / 宽屏水平）

/// 自适应堆栈：紧凑宽（手机竖屏）→ VStack 垂直堆叠；宽屏（横屏/iPad）→ HStack 水平堆叠。
/// 用户通用规则（2026-10-20 验收反馈）：**任何水平堆栈，在手机竖屏状态下都应该自动
/// 使用垂直堆栈代替，切到横屏时再恢复为水平堆栈**——窄屏下换行/压缩/横滚都是次优解，
/// 直接竖排最直观（竖屏设备本身就是纵向阅读流）。旋转时宽度阈值两侧自动切换形态。
///
/// isCompact 由调用方传入（页面通常已有 WidthReader 上报的宽度，
/// 与 `CompactWidth.threshold` 比较即可），组件自身不做宽度测量——
/// 内嵌 GeometryReader 会贪婪占位，不适合放进各种行布局。
///
/// 两种形态的对齐与间距独立配置（默认：VStack 左对齐符合纵向阅读习惯；
/// HStack 垂直居中与普通 HStack 一致）。子视图书写顺序不变，仅容器切换。
///
/// 适用范围：「内容型水平行」（指标行 / 信息行 / 标题+按钮行等可能挤压的行）。
/// 不适用于有自身设计语义的布局：底部 tab 栏、表格行、图表内部指标栏等
/// （这些行有固定的横向设计，竖排会破坏语义）。
struct AdaptiveStack<Content: View>: View {
    /// 紧凑形态判定（true = VStack / false = HStack），由调用方按宽度传入
    let isCompact: Bool
    /// HStack 形态的垂直对齐（默认 .center，与普通 HStack 一致）
    var hAlignment: VerticalAlignment = .center
    /// VStack 形态的水平对齐（默认 .leading，纵向阅读习惯）
    var vAlignment: HorizontalAlignment = .leading
    /// HStack 形态的子项间距
    var hSpacing: CGFloat = 8
    /// VStack 形态的子项间距
    var vSpacing: CGFloat = 8
    /// 子视图（书写顺序即布局顺序，两种形态一致）
    @ViewBuilder let content: Content

    var body: some View {
        if isCompact {
            VStack(alignment: vAlignment, spacing: vSpacing) { content }
        } else {
            HStack(alignment: hAlignment, spacing: hSpacing) { content }
        }
    }
}

#Preview("AdaptiveStack：竖屏垂直 / 宽屏水平") {
    VStack(spacing: 24) {
        // 竖屏形态（紧凑）：垂直堆叠
        AdaptiveStack(isCompact: true) {
            Text("总资产 259,204").font(.system(size: 13, weight: .semibold))
            Text("可用资金 100,000").font(.system(size: 13)).foregroundColor(.secondary)
            Text("持仓市值 159,204").font(.system(size: 13)).foregroundColor(.secondary)
        }
        .frame(width: 320, alignment: .leading)
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .border(Color.gray.opacity(0.4))

        // 宽屏形态（常规）：水平堆叠
        AdaptiveStack(isCompact: false, hSpacing: 24) {
            Text("总资产 259,204").font(.system(size: 13, weight: .semibold))
            Text("可用资金 100,000").font(.system(size: 13)).foregroundColor(.secondary)
            Text("持仓市值 159,204").font(.system(size: 13)).foregroundColor(.secondary)
        }
        .frame(width: 640, alignment: .leading)
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .border(Color.gray.opacity(0.4))
    }
    .padding()
}

//
//  AdaptiveWidthKit.swift
//  Kline
//
//  窄屏（紧凑宽度）适配基建：CompactWidth 阈值判定 + WidthReader 可用宽度测量
//  + klineAvailableWidth 环境注入 + AdaptiveStack 自适应堆栈。
//  背景：App 按 iPad mini 5（1024×768）调校，iPhone 竖屏（如 iPhone 11 的 414pt）
//  上多个页面固有最小宽超过屏宽，页面需按「可用宽度」切换紧凑布局。
//  只放宽度判定/测量/通用堆栈相关的轻量基建，勿在此堆积具体页面的适配逻辑。
//
//  单一事实来源（2026-10-20 收口）：紧凑与否只由「最近一层容器实测可用宽度 < 600」
//  决定。根容器 / WidthReader 把实测宽写入 `\.klineAvailableWidth` 环境；
//  AdaptiveStack、各 widget、配置渲染器统一读它（未注入时才回退 sizeClass）。
//  新增水平行请直接用 AdaptiveStack，勿再各写 sizeClass 分支。
//

import SwiftUI

// MARK: - 紧凑宽度阈值

/// 紧凑宽度阈值：页面可用宽度 < 600 视为紧凑（窄屏）形态。
/// 取值依据（真机实测可用宽度）：
/// - iPhone 11 竖屏 414pt → 命中紧凑（需要窄屏适配）
/// - iPhone 11 横屏 848pt → 不命中（沿用宽屏布局）
/// - iPad mini 5 横屏 1024pt → 不命中（App 的原始调校目标机型）
/// 600 恰好把「iPhone 竖屏（普遍 ≤ 430pt）」与「iPhone 横屏及以上」一刀切开；
/// 各页面统一用 `CompactWidth.isCompact(availableWidth)` 判定，勿各自另拍阈值。
enum CompactWidth {
    static let threshold: CGFloat = 600

    /// 唯一紧凑判定入口：0 = 尚未测量（不算紧凑，由调用方决定回退）。
    static func isCompact(_ width: CGFloat) -> Bool {
        width > 0 && width < threshold
    }
}

// MARK: - 可用宽度环境（单一事实来源）

/// 最近一层容器实测的可用宽度；0 = 尚未注入（如 Preview / 单元测试宿主）。
private struct KlineAvailableWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// 页面可用宽度（pt）。由根容器 GeometryReader 或页面顶层 WidthReader 注入。
    var klineAvailableWidth: CGFloat {
        get { self[KlineAvailableWidthKey.self] }
        set { self[KlineAvailableWidthKey.self] = newValue }
    }
}

/// 统一的紧凑宽度读取：优先用宿主注入的实测宽度（< 600）；
/// 宿主未注入时回退 `horizontalSizeClass`（保证 Preview / 独立承载仍可用）。
/// 用法：`@CompactWidthValue private var isCompactWidth`
@propertyWrapper
struct CompactWidthValue: DynamicProperty {
    @Environment(\.klineAvailableWidth) private var availableWidth
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// 环境属性为 private，显式给出 internal 空 init（否则隐式 init 被降级为 private）
    init() {}

    var wrappedValue: Bool {
        if availableWidth > 0 { return CompactWidth.isCompact(availableWidth) }
        return horizontalSizeClass == .compact
    }
}

// MARK: - 可用宽度测量

/// 轻量可用宽度测量封装：把父容器提议给本层的可用宽度经 `onChange` 回调上报给
/// 调用方的 `@State`，同时向下注入 `klineAvailableWidth` 环境（页面内组件共用）。
/// 调用方仍可用 `CompactWidth.isCompact(availableWidth)` 做页面级分支。
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
                // 同一份实测宽向下注入：页面内所有 AdaptiveStack / widget 共用该判定，
                // 不再各自读 sizeClass，避免 iPad 分屏 / 旋转时两套信号打架
                .environment(\.klineAvailableWidth, geo.size.width)
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
/// isCompact 不再由调用方手算：默认读宿主注入的 `klineAvailableWidth`
/// （与 `CompactWidth.threshold` 比较），未注入时回退 sizeClass——
/// 这样配置渲染器、模拟页、硬编码首页布局共用同一个判定入口。
/// 特殊场景（如页面内已知局部宽）可用 `isCompact:` 显式覆盖。
///
/// 两种形态的对齐与间距独立配置（默认：VStack 左对齐符合纵向阅读习惯；
/// HStack 垂直居中与普通 HStack 一致）。子视图书写顺序不变，仅容器切换。
///
/// 适用范围：「内容型水平行」（指标行 / 信息行 / 标题+按钮行等可能挤压的行）。
/// 不适用于有自身设计语义的布局：底部 tab 栏、表格行、图表内部指标栏等
/// （这些行有固定的横向设计，竖排会破坏语义）。
struct AdaptiveStack<Content: View>: View {
    /// 显式覆盖（nil = 按环境可用宽度自动判定；主要用于局部容器 / Preview）
    var isCompact: Bool? = nil
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

    @Environment(\.klineAvailableWidth) private var availableWidth
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// 显式 init：环境属性是 private，memberwise init 会被降级为 private，
    /// 故这里手写 internal init 供各页面调用。
    init(isCompact: Bool? = nil,
         hAlignment: VerticalAlignment = .center,
         vAlignment: HorizontalAlignment = .leading,
         hSpacing: CGFloat = 8,
         vSpacing: CGFloat = 8,
         @ViewBuilder content: () -> Content) {
        self.isCompact = isCompact
        self.hAlignment = hAlignment
        self.vAlignment = vAlignment
        self.hSpacing = hSpacing
        self.vSpacing = vSpacing
        self.content = content()
    }

    /// 统一判定：显式覆盖 > 宿主注入的实测宽 > sizeClass 回退
    private var resolvedIsCompact: Bool {
        if let isCompact { return isCompact }
        if availableWidth > 0 { return CompactWidth.isCompact(availableWidth) }
        return horizontalSizeClass == .compact
    }

    var body: some View {
        if resolvedIsCompact {
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

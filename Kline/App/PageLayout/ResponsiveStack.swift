//
//  ResponsiveStack.swift
//  Kline
//
//  布局引擎 - 响应式堆栈：按父容器可用宽度自动决定横排 / 竖排（类似 CSS flex-wrap）。
//
//  三种排列方向：
//  · auto        可用宽度 ≥ 断点 → 横向；否则纵向（默认 600pt，可在编辑器调整）
//  · horizontal  始终横向（配合空间不足处理：wrap 换行 / scroll 横向滚动 / compress 压缩）
//  · vertical    始终纵向
//
//  宽度来源（单一事实来源，与 AdaptiveStack 同口径）：
//  优先读宿主注入的 `klineAvailableWidth`（页面实测可用宽）；未注入时（Preview 等）
//  回退本层 GeometryReader 实测宽度。**不按设备型号判断**——iPad 分屏 / iPhone 横屏
//  这类场景天然由实测宽度覆盖。
//

import SwiftUI

// MARK: - 换行子项包装（WrappingHStack 需要 Identifiable）

private struct ResponsiveItemIndex: Identifiable {
    let id: Int
}

// MARK: - 响应式堆栈

struct ResponsiveStack: View {
    /// 已构建好的子视图
    let items: [AnyView]
    /// auto / horizontal / vertical；nil = 跟随节点类型（旧行为）
    var direction: String?
    /// 节点类型默认轴（hstack → 横向；vstack → 纵向）
    var legacyAxis: Axis
    /// auto 断点宽度（pt）
    var breakpoint: CGFloat = 600
    /// 横向空间不足时的处理：wrap / scroll / compress
    var overflow: String = "compress"
    var spacing: CGFloat = 8
    /// 横向形态的垂直对齐
    var hAlignment: VerticalAlignment = .center
    /// 纵向形态的水平对齐
    var vAlignment: HorizontalAlignment = .leading

    @Environment(\.klineAvailableWidth) private var availableWidth
    /// 宿主未注入宽度时的本层实测宽度
    @State private var measuredWidth: CGFloat = 0

    private var effectiveWidth: CGFloat {
        availableWidth > 0 ? availableWidth : measuredWidth
    }

    /// 解析后的排列方向
    private var isHorizontal: Bool {
        switch direction {
        case "horizontal":
            return true
        case "vertical":
            return false
        case "auto":
            // 宽度未知时按节点默认轴（不误判为窄屏）
            guard effectiveWidth > 0 else { return legacyAxis == .horizontal }
            return effectiveWidth >= breakpoint
        default:
            return legacyAxis == .horizontal
        }
    }

    var body: some View {
        Group {
            if isHorizontal {
                horizontalContent
            } else {
                VStack(alignment: vAlignment, spacing: spacing) {
                    ForEach(items.indices, id: \.self) { index in
                        items[index]
                    }
                }
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { measuredWidth = geo.size.width }
                    .onChange(of: geo.size.width) { measuredWidth = $0 }
            }
        )
    }

    @ViewBuilder
    private var horizontalContent: some View {
        switch overflow {
        case "wrap":
            // 自动换行：子项按理想尺寸横排，超出可用宽换行
            WrappingHStack(items: items.indices.map { ResponsiveItemIndex(id: $0) },
                           horizontalSpacing: spacing,
                           rowSpacing: spacing,
                           alignment: .leading) { item in
                items[item.id]
            }
        case "scroll":
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: hAlignment, spacing: spacing) {
                    ForEach(items.indices, id: \.self) { index in
                        items[index]
                    }
                }
            }
        default:
            // compress：交给 HStack 自行压缩 / 截断
            HStack(alignment: hAlignment, spacing: spacing) {
                ForEach(items.indices, id: \.self) { index in
                    items[index]
                }
            }
        }
    }
}

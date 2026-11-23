//
//  FlexRow.swift
//  Kline
//
//  布局引擎 - 水平 Flex 行：支持 Hug / Fill / Flex / Fixed 四种子组件宽度模式。
//
//  为什么不用纯 SwiftUI 原始布局：
//  · `.frame(maxWidth: .infinity)` 只能做「等比分配」，无法表达权重与固定宽度混排；
//  · `.layoutPriority` 只影响空间紧张时的压缩顺序，不是按权重切分剩余空间。
//  因此这里用「实测容器宽度 + 实测 hug 子项固有宽度 → 计算每个弹性子项宽度」的方式，
//  再用 `.frame(width:)` 精确落位（iOS 15 兼容，不使用 iOS 16 的 Layout 协议）。
//
//  算法（与 CSS Flexbox 的简化版一致）：
//  1. 固定宽度 = widthValue；hug 宽度 = 子项固有宽度（实测）；
//  2. 剩余 = 容器宽 − 固定和 − hug 和 − 间距总和；
//  3. 弹性子项按权重切分剩余：fill 权重记 1，flex 权重取 flexWeight；
//  4. 结果再按 sizeMinWidth / sizeMaxWidth 钳制。
//

import SwiftUI

// MARK: - 子项规格

/// 一个子组件的尺寸规格（来自 JSON 节点的 widthMode 等字段）
struct FlexItemSpec: Equatable {
    enum Mode: String {
        case hug   // 内容自适应
        case fill  // 填充剩余空间
        case flex  // 按权重分配
        case fixed // 固定宽度
    }

    /// nil = 旧行为（hug）
    var mode: Mode?
    var fixedWidth: Double?
    var weight: Double
    var minWidth: Double?
    var maxWidth: Double?

    init(mode: Mode?, fixedWidth: Double?, weight: Double,
         minWidth: Double?, maxWidth: Double?) {
        self.mode = mode
        self.fixedWidth = fixedWidth
        self.weight = weight
        self.minWidth = minWidth
        self.maxWidth = maxWidth
    }

    /// 解析节点字段（未知 / nil → hug）
    init(widthMode: String?, fixedWidth: Double?, weight: Double?,
         minWidth: Double?, maxWidth: Double?) {
        self.init(mode: widthMode.flatMap { Mode(rawValue: $0) },
                  fixedWidth: fixedWidth,
                  weight: max(weight ?? 1, 0.01),
                  minWidth: minWidth,
                  maxWidth: maxWidth)
    }
}

// MARK: - 固有宽度上报

private struct FlexHugWidthKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Flex 行

/// 水平 Flex 行：按子项规格计算宽度并落位。
struct FlexRow: View {
    /// 已构建好的子视图（与 specs 一一对应）
    let items: [AnyView]
    let specs: [FlexItemSpec]
    var spacing: CGFloat = 8
    var alignment: VerticalAlignment = .center

    @State private var containerWidth: CGFloat = 0
    @State private var hugWidths: [Int: CGFloat] = [:]

    var body: some View {
        HStack(alignment: alignment, spacing: spacing) {
            ForEach(items.indices, id: \.self) { index in
                cell(index)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { containerWidth = $0 }
            }
        )
        .onPreferenceChange(FlexHugWidthKey.self) { hugWidths = $0 }
    }

    @ViewBuilder
    private func cell(_ index: Int) -> some View {
        let spec = specs[index]
        switch spec.mode ?? .hug {
        case .hug:
            items[index]
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: FlexHugWidthKey.self,
                                               value: [index: geo.size.width])
                    }
                )
        case .fixed:
            items[index].frame(width: CGFloat(spec.fixedWidth ?? 100))
        case .fill, .flex:
            if let width = computedWidth(index) {
                items[index].frame(width: width)
            } else {
                // 尚未测得容器宽度：先按自然尺寸渲染，测量完成后落位
                items[index]
            }
        }
    }

    /// 计算某个弹性子项的最终宽度；容器宽度未知时返回 nil
    private func computedWidth(_ index: Int) -> CGFloat? {
        guard containerWidth > 0 else { return nil }

        var hugTotal: CGFloat = 0
        var fixedTotal: CGFloat = 0
        var flexible: [(index: Int, weight: Double)] = []

        for i in items.indices {
            let spec = specs[i]
            switch spec.mode ?? .hug {
            case .hug:
                hugTotal += hugWidths[i] ?? 0
            case .fixed:
                fixedTotal += CGFloat(spec.fixedWidth ?? 100)
            case .fill:
                flexible.append((i, 1))
            case .flex:
                flexible.append((i, max(spec.weight, 0.01)))
            }
        }

        let spacingTotal = spacing * CGFloat(max(items.count - 1, 0))
        let free = max(containerWidth - hugTotal - fixedTotal - spacingTotal, 0)
        let totalWeight = flexible.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0,
              let weight = flexible.first(where: { $0.index == index })?.weight else {
            return nil
        }

        let spec = specs[index]
        var width = free * CGFloat(weight) / CGFloat(totalWeight)
        if let minWidth = spec.minWidth { width = max(width, CGFloat(minWidth)) }
        if let maxWidth = spec.maxWidth { width = min(width, CGFloat(maxWidth)) }
        return max(width, 0)
    }
}

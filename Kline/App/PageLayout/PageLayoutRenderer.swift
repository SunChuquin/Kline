//
//  PageLayoutRenderer.swift
//  Kline
//
//  通用 JSON 布局引擎 - 节点树渲染器（与具体页面无关）。
//  按 PageLayoutNode 的 type 生成 AnyView，容器语义与现有 SwiftUI 写法逐项对齐：
//  vstack / hstack / zstack / scroll / card / frame / widget / divider / spacer。
//  widget 节点通过 PageWidgetRegistry 解析控件名；未注册控件渲染可诊断占位（不崩溃、不静默空白）。
//

import Foundation
import SwiftUI

/// 按节点树渲染页面（与具体页面无关）
struct PageLayoutRenderer<Context> {
    let registry: PageWidgetRegistry<Context>
    let context: Context

    // MARK: - 顶层分发

    func view(for node: PageLayoutNode) -> AnyView {
        let children = node.children ?? []
        switch node.type {
        case "vstack":
            return AnyView(
                VStack(alignment: horizontalAlignment(node.alignment),
                       spacing: CGFloat(node.spacing ?? 8)) {
                    childViews(children)
                }
            )
        case "hstack":
            // 竖屏垂直堆栈规则（2026-10-20）：配置里的 hstack 在 iPhone 竖屏
            // （horizontalSizeClass == .compact）下自动渲染为 VStack（leading 对齐，
            // 间距沿用 spacing），横屏 / iPad（regular）保持 HStack 原样——
            // 与硬编码布局视图（HomeLayoutB/DView 等）的 sizeClass 分支同口径，
            // 配置驱动与硬编码两条渲染路径行为一致。
            // 注意：横向 scroll 的内层 HStack（横滑语义，如快捷入口行）不走此分支。
            return AnyView(
                AdaptiveHStackContainer(alignment: verticalAlignment(node.alignment),
                                        spacing: CGFloat(node.spacing ?? 8)) {
                    childViews(children)
                }
            )
        case "zstack":
            return AnyView(
                ZStack {
                    childViews(children)
                }
            )
        case "scroll":
            return AnyView(scrollView(for: node))
        case "card":
            return AnyView(cardView(for: node))
        case "frame":
            return AnyView(frameView(for: node))
        case "widget":
            return widgetView(for: node)
        case "divider":
            return AnyView(Divider())
        case "spacer":
            return AnyView(Spacer())
        default:
            // 白名单已在解码期拦截未知 type，这里仅为 switch 完备性兜底
            return AnyView(EmptyView())
        }
    }

    // MARK: - 容器节点

    /// scroll：外层 ScrollView，内层容器承载 padding 与 spacing
    private func scrollView(for node: PageLayoutNode) -> some View {
        let isHorizontal = (node.axis == "horizontal")
        let children = node.children ?? []
        let insets = node.padding?.edgeInsets ?? EdgeInsets()
        return ScrollView(isHorizontal ? .horizontal : .vertical,
                          showsIndicators: node.showsIndicators ?? false) {
            innerScrollContainer(horizontal: isHorizontal,
                                 spacing: CGFloat(node.spacing ?? 8),
                                 children: children)
                .padding(insets)
        }
    }

    @ViewBuilder
    private func innerScrollContainer(horizontal: Bool, spacing: CGFloat,
                                      children: [PageLayoutNode]) -> some View {
        if horizontal {
            HStack(spacing: spacing) {
                childViews(children)
            }
        } else {
            VStack(alignment: .center, spacing: spacing) {
                childViews(children)
            }
        }
    }

    /// card：小标题 + 内容的浅灰卡片容器（本文件与页面无关，自带一份等价实现）
    private func cardView(for node: PageLayoutNode) -> some View {
        let isCompact = node.compact ?? false
        return VStack(alignment: .leading, spacing: isCompact ? 8 : 10) {
            if let title = node.title {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            if let child = node.child {
                view(for: child)
            }
        }
        .padding(isCompact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    /// frame：对 child 施加宽高约束（maxWidth 缺失时不约束）
    private func frameView(for node: PageLayoutNode) -> some View {
        let content = node.child.map { view(for: $0) } ?? AnyView(EmptyView())
        return content.frame(
            minWidth: nil,
            idealWidth: nil,
            maxWidth: maxWidthValue(node.maxWidth),
            minHeight: node.minHeight.map { CGFloat($0) },
            idealHeight: nil,
            maxHeight: nil,
            alignment: frameAlignment(node.alignment)
        )
    }

    // MARK: - 控件节点

    private func widgetView(for node: PageLayoutNode) -> AnyView {
        let name = node.name ?? ""
        if let builder = registry.builder(for: name) {
            return builder(context, node.params ?? WidgetParams())
        }
        return unregisteredPlaceholder(name: name)
    }

    /// 未注册控件的可诊断占位（含控件名）
    private func unregisteredPlaceholder(name: String) -> AnyView {
        let label = name.isEmpty ? "未注册控件：（空名）" : "未注册控件：\(name)"
        return AnyView(
            VStack {
                Image(systemName: "questionmark.square.dashed")
                Text(label)
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)
        )
    }

    // MARK: - 子节点

    @ViewBuilder
    private func childViews(_ nodes: [PageLayoutNode]) -> some View {
        ForEach(nodes.indices, id: \.self) { index in
            self.view(for: nodes[index])
        }
    }

    // MARK: - 取值 / 映射

    private func maxWidthValue(_ width: PageLayoutWidth?) -> CGFloat? {
        guard let width = width else { return nil }
        switch width {
        case .infinity: return CGFloat.infinity
        case .points(let value): return CGFloat(value)
        }
    }

    /// VStack 的水平对齐
    private func horizontalAlignment(_ raw: String?) -> HorizontalAlignment {
        switch raw {
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }

    /// HStack 的垂直对齐
    private func verticalAlignment(_ raw: String?) -> VerticalAlignment {
        switch raw {
        case "top": return .top
        case "bottom": return .bottom
        case "firstTextBaseline": return .firstTextBaseline
        case "lastTextBaseline": return .lastTextBaseline
        default: return .center
        }
    }

    /// frame 的 2D 对齐
    private func frameAlignment(_ raw: String?) -> Alignment {
        switch raw {
        case "top": return .top
        case "bottom": return .bottom
        case "leading": return .leading
        case "trailing": return .trailing
        case "topLeading": return .topLeading
        case "topTrailing": return .topTrailing
        case "bottomLeading": return .bottomLeading
        case "bottomTrailing": return .bottomTrailing
        default: return .center
        }
    }
}

// MARK: - hstack 节点的竖屏自适应容器

/// 配置 hstack 节点的渲染容器：iPhone 竖屏（compact）→ VStack（leading 对齐），
/// 横屏 / iPad（regular）→ HStack（原对齐）。sizeClass 由系统随旋转自动切换。
/// PageLayoutRenderer 是纯函数结构体（非 View），读不了 @Environment，
/// 故用本 View 承载自适应逻辑。
private struct AdaptiveHStackContainer<Content: View>: View {
    /// HStack 形态的垂直对齐（来自节点 alignment，默认 center）
    let alignment: VerticalAlignment
    /// 两种形态共用的子项间距（来自节点 spacing，默认 8）
    let spacing: CGFloat
    @ViewBuilder let content: Content

    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        if hSizeClass == .compact {
            VStack(alignment: .leading, spacing: spacing) { content }
        } else {
            HStack(alignment: alignment, spacing: spacing) { content }
        }
    }
}
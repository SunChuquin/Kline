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
            // 响应式：direction / overflow 已配置时按可用宽度决定横竖与溢出策略
            if node.direction != nil || node.overflow != nil {
                return AnyView(
                    ResponsiveStack(items: children.map { view(for: $0) },
                                    direction: node.direction,
                                    legacyAxis: .vertical,
                                    breakpoint: CGFloat(node.breakpoint ?? 600),
                                    overflow: node.overflow ?? "compress",
                                    spacing: CGFloat(node.spacing ?? 8),
                                    hAlignment: .center,
                                    vAlignment: horizontalAlignment(node.alignment))
                )
            }
            return AnyView(
                VStack(alignment: horizontalAlignment(node.alignment),
                       spacing: CGFloat(node.spacing ?? 8)) {
                    childViews(children)
                }
            )
        case "hstack":
            // Flex 模式优先（2026-11-23）：子节点配置了 widthMode（hug/fill/flex/fixed）时，
            // 改走 FlexRow 精确计算宽度（固定/hug/权重混排）。
            // 未配置时保持旧行为（AdaptiveStack：竖屏自动竖排）。
            if children.contains(where: { $0.widthMode != nil }) {
                return AnyView(
                    FlexRow(items: children.map { view(for: $0) },
                            specs: children.map {
                                FlexItemSpec(widthMode: $0.widthMode,
                                             fixedWidth: $0.widthValue,
                                             weight: $0.flexWeight,
                                             minWidth: $0.sizeMinWidth,
                                             maxWidth: $0.sizeMaxWidth)
                            },
                            spacing: CGFloat(node.spacing ?? 8),
                            alignment: verticalAlignment(node.alignment))
                )
            }
            // 响应式：direction / overflow 已配置时按可用宽度决定横竖与溢出策略
            // （Flex 宽度模式与响应式互斥：配置了 widthMode 时走上面的 FlexRow）
            if node.direction != nil || node.overflow != nil {
                return AnyView(
                    ResponsiveStack(items: children.map { view(for: $0) },
                                    direction: node.direction,
                                    legacyAxis: .horizontal,
                                    breakpoint: CGFloat(node.breakpoint ?? 600),
                                    overflow: node.overflow ?? "compress",
                                    spacing: CGFloat(node.spacing ?? 8),
                                    hAlignment: verticalAlignment(node.alignment),
                                    vAlignment: .leading)
                )
            }
            // 竖屏垂直堆栈规则（2026-10-20 收口）：配置里的 hstack 统一走
            // AdaptiveStack，按宿主注入的实测可用宽（< 600）自动切换 VStack / HStack。
            // 与模拟页、首页硬编码布局共用同一判定入口，不再单独读 sizeClass。
            // 注意：横向 scroll 的内层 HStack（横滑语义，如快捷入口行）不走此分支。
            return AnyView(
                AdaptiveStack(hAlignment: verticalAlignment(node.alignment),
                              vAlignment: .leading,
                              hSpacing: CGFloat(node.spacing ?? 8),
                              vSpacing: CGFloat(node.spacing ?? 8)) {
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
                    .foregroundColor(AppColors.textSecondary)
            }
            if let child = node.child {
                view(for: child)
            }
        }
        .padding(isCompact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.cardBackground)
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
            .background(AppColors.cardBackground)
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

//
//  LayoutNodeTreeList.swift
//  Kline
//
//  布局编辑器 - 左侧节点树列表。
//  按 `editor.flattenedRows` 平铺（缩进体现层级）、容器可折叠、点击选中、
//  `.onMove` 同级拖动重排（跨级由模型拒绝并给提示）；
//  底部工具条提供「排序 / 完成」开关（iOS 15 下 `.onMove` 仅在编辑态可拖）、
//  「上移 / 下移」精确重排、「添加节点」/「添加控件」两个 Menu。
//
//  行身份用节点 uuid（编辑期身份）；行高固定 44（命中区 ≥ 44pt）。
//

import SwiftUI

struct LayoutNodeTreeList: View {
    @ObservedObject var editor: PageLayoutEditorModel

    /// 列表编辑态：非编辑态下 `.onMove` 不接受拖动（由工具条「排序」开关控制）
    @State private var editMode: EditMode = .inactive

    /// 「添加节点」菜单的固定顺序
    private static let nodeTypes = [
        "vstack", "hstack", "zstack", "scroll", "card", "frame", "widget", "divider", "spacer"
    ]

    var body: some View {
        VStack(spacing: 0) {
            List {
                // 行身份由 LayoutTreeRow.id（节点 uuid）提供：不能对元组取 key path
                ForEach(editor.flattenedRows) { row in
                    nodeRow(row.node, depth: row.depth)
                }
                .onMove { from, to in
                    editor.move(fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 44)
            .environment(\.editMode, $editMode)

            Divider()
            toolBar
        }
        .background(Color(.systemBackground))
    }

    // MARK: - 行

    private func nodeRow(_ node: PageLayoutNode, depth: Int) -> some View {
        let isSelected = (editor.selectedUUID == node.uuid)
        let isContainer = (node.containerKey != nil)
        let summary = secondarySummary(node)

        return HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)

            if isContainer {
                Button {
                    editor.toggleCollapse(node)
                } label: {
                    Image(systemName: editor.collapsed.contains(node.uuid) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(primaryTitle(node))
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? .blue : .primary)
                    .lineLimit(1)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(height: 44)
        .background(isSelected ? Color.blue.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { editor.select(node) }
        // UI 测试锚点：控件节点按控件名（默认布局中每种控件唯一），其余按节点类型
        .accessibilityIdentifier(node.type == "widget"
                                 ? "layout.tree.widget.\(node.name ?? "")"
                                 : "layout.tree.\(node.type)")
    }

    // MARK: - 底部工具条

    private var toolBar: some View {
        // 五个控件在 320pt 宽的树面板里会挤到截断，故横向可滚（不裁文案）
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 排序开关：iOS 15 下 List 的 .onMove 只在编辑态生效，不切到编辑态就长按拖不动
                Button {
                    withAnimation { editMode = (editMode == .active ? .inactive : .active) }
                } label: {
                    toolbarLabel(editMode == .active ? "完成" : "排序",
                                 systemImage: editMode == .active ? "checkmark" : "arrow.up.arrow.down")
                }
                .buttonStyle(.plain)

                // 上移 / 下移：不方便拖动时的精确同级重排
                Button {
                    editor.moveSelectedUp()
                } label: {
                    iconButtonLabel("arrow.up")
                }
                .buttonStyle(.plain)
                .disabled(!editor.canMoveSelected)

                Button {
                    editor.moveSelectedDown()
                } label: {
                    iconButtonLabel("arrow.down")
                }
                .buttonStyle(.plain)
                .disabled(!editor.canMoveSelected)

                Menu {
                    ForEach(Self.nodeTypes, id: \.self) { type in
                        Button(HomeWidgetEditorSchema.nodeTypeTitles[type] ?? type) {
                            editor.insertNode(type: type)
                        }
                    }
                } label: {
                    toolbarLabel("添加节点")
                }

                Menu {
                    ForEach(HomeWidgetEditorSchema.all, id: \.name) { descriptor in
                        Button(descriptor.title) {
                            editor.insertWidget(name: descriptor.name)
                        }
                    }
                } label: {
                    toolbarLabel("添加控件")
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .background(Color(.systemBackground))
    }

    private func toolbarLabel(_ title: String, systemImage: String = "plus") -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
            Text(title).font(.system(size: 13))
        }
        .foregroundColor(.blue)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.12))
        .cornerRadius(8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    /// 图标按钮（44×44 命中区）；禁用态走 secondary 色
    private func iconButtonLabel(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(editor.canMoveSelected ? .blue : .secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    // MARK: - 文案

    private func primaryTitle(_ node: PageLayoutNode) -> String {
        if node.type == "widget" {
            return HomeWidgetEditorSchema.descriptor(for: node.name ?? "")?.title ?? "控件"
        }
        return HomeWidgetEditorSchema.nodeTypeTitles[node.type] ?? node.type
    }

    /// 副标题摘要（无内容则返回空串）
    private func secondarySummary(_ node: PageLayoutNode) -> String {
        switch node.type {
        case "card":
            return node.title ?? ""
        case "widget":
            return node.name ?? ""
        case "scroll":
            let axis = (node.axis == "horizontal") ? "水平" : "垂直"
            return "\(axis) · 间距 \(Int(node.spacing ?? 8))"
        case "vstack", "hstack", "zstack":
            return "间距 \(Int(node.spacing ?? 8))"
        case "frame":
            var parts: [String] = []
            if case .infinity? = node.maxWidth { parts.append("无限宽") }
            if let minHeight = node.minHeight { parts.append("最小高 \(Int(minHeight))") }
            return parts.joined(separator: " · ")
        default:
            return ""
        }
    }
}
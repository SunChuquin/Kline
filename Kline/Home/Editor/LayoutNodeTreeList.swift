//
//  LayoutNodeTreeList.swift
//  Kline
//
//  布局编辑器 - 左侧节点树列表。
//  按 `editor.flattenedRows` 平铺（缩进体现层级）、容器可折叠、点击选中。
//
//  拖拽是**一次手势内部按落点分区自动判定意图**，不需要先切模式：
//    · 容器行（vstack/hstack/zstack/scroll/card/frame）：上边缘 12pt = 插到该行之前、
//      下边缘 12pt = 插到该行之后、中间 20pt = 拖入该容器（跨级装配）
//    · 叶子行（widget/divider/spacer）：上半区 = 插到该行之前、下半区 = 插到该行之后
//  反馈：插入意图 = 行顶/底 2pt 蓝线；拖入意图 = 整行蓝底 + 蓝框；
//  非法（自身子孙 / 跨级插到不同父 / 定位失败）= 整行红底 + 红框，松手后状态栏说明原因。
//  底部工具条另有「上移 / 下移」精确重排、「添加节点」/「添加控件」两个 Menu。
//
//  行身份用节点 uuid（编辑期身份）；行高固定 44（命中区 ≥ 44pt）。
//
//  ⚠️ 为什么不用 `List` + `.onMove`（实测结论，2026-09-25）：
//  `List` 由集合视图承载，会吞掉「由它自身行发起」的拖拽会话——`.onDrag` 有回调，
//  但行内 / List 层 / 外层容器的 `.onDrop` 全部零回调（三轮探针日志均 0 命中，
//  换 `ScrollView + LazyVStack` 后同一次拖拽立刻有 `validateDrop` / `dropUpdated`）。
//  即「保留 List.onMove」与「跨级拖入」在 iOS 26 不可兼得，故容器改为普通滚动视图。
//

import SwiftUI
import UniformTypeIdentifiers

struct LayoutNodeTreeList: View {
    @ObservedObject var editor: PageLayoutEditorModel

    /// 当前拖拽会话（承载拖拽源节点，供落点合法性判定）
    @State private var dragSession = LayoutDragSession()
    /// 当前落点行（高亮用）
    @State private var dropTargetUUID: UUID?
    /// 当前落点的解析结果（拖入 / 前插 / 后插 / 非法）
    @State private var dropResolution: LayoutDropResolution?

    /// 「添加节点」菜单的固定顺序
    private static let nodeTypes = [
        "vstack", "hstack", "zstack", "scroll", "card", "frame", "widget", "divider", "spacer"
    ]

    /// 行高（落点半区判定也用同一数值；同文件的行落点代理需要读，故 fileprivate）
    fileprivate static let rowHeight: CGFloat = 44

    var body: some View {
        let rows = editor.flattenedRows
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        nodeRow(row.node, depth: row.depth, rows: rows)
                    }
                }
            }
            // UI 测试锚点：测试读它拿树列表的**真实可视区** rect。
            // 必要性：LazyVStack 会把被视口裁掉的行也报进无障碍树，且 `isHittable` 对
            // 裁剪行不判假，测试据此算出的落点会落到可视区外的其它控件上（曾打到工具栏按钮）。
            .accessibilityIdentifier("layoutEditor.treeList")

            Divider()
            toolBar
        }
        .background(Color(.systemBackground))
    }

    // MARK: - 行

    private func nodeRow(_ node: PageLayoutNode, depth: Int, rows: [LayoutTreeRow]) -> some View {
        let isSelected = (editor.selectedUUID == node.uuid)
        let isContainer = (node.containerKey != nil)
        let summary = secondarySummary(node)
        let isDropTarget = (dropTargetUUID == node.uuid)
        // 只有当前落点行才显示落点反馈
        let drop: LayoutDropResolution? = isDropTarget ? dropResolution : nil
        let isRoot = (editor.layoutRoot?.uuid == node.uuid)
        let isRejected = drop?.rejection != nil
        let accent: Color = isRejected ? .red : .accentColor

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
        .frame(height: Self.rowHeight)
        .background(
            ZStack {
                if isSelected { Color.blue.opacity(0.12) }
                // 拖入 / 非法 = 整行底色；前插 / 后插只画边缘线（下面 overlay）
                if drop == .into { Color.accentColor.opacity(0.2) }
                if isRejected { Color.red.opacity(0.2) }
            }
        )
        .overlay(alignment: .top) {
            if drop == .insertBefore { Self.insertionLine }
        }
        .overlay(alignment: .bottom) {
            if drop == .insertAfter { Self.insertionLine }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent, lineWidth: 2)
                .opacity(drop == .into || isRejected ? 1 : 0)
                .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
        .onTapGesture { editor.select(node) }
        .modifier(NodeRowDragModifier(isDragSource: !isRoot,
                                      node: node,
                                      rows: rows,
                                      session: dragSession,
                                      editor: editor,
                                      dropTargetUUID: $dropTargetUUID,
                                      dropResolution: $dropResolution))
        // UI 测试锚点：控件节点按控件名（默认布局中每种控件唯一），其余按节点类型
        .accessibilityIdentifier(node.type == "widget"
                                 ? "layout.tree.widget.\(node.name ?? "")"
                                 : "layout.tree.\(node.type)")
    }

    /// 插入意图的边缘指示线（2pt，与行等宽）
    private static var insertionLine: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
            .allowsHitTesting(false)
    }

    // MARK: - 底部工具条

    private var toolBar: some View {
        // 五个控件在 320pt 宽的树面板里会挤到截断，故横向可滚（不裁文案）
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
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

/// 当前拖拽会话：承载拖拽源节点，供落点合法性判定（前插 / 后插需要知道源是否与目标同父）。
/// 用「不发布变化」的引用类型而非 `@State`：`.onDrag` 闭包里写 `@State` 会触发重渲染，
/// 有打断正在进行的拖拽会话的风险（`List` 吞掉自身拖拽会话的同类问题）。
final class LayoutDragSession {
    var sourceUUID: UUID?
}

/// 落点解析结果：悬停反馈与松手动作共用同一套判定
private enum LayoutDropResolution: Equatable {
    /// 拖入该容器（容器行的中间区）
    case into
    /// 插到该行之前
    case insertBefore
    /// 插到该行之后
    case insertAfter
    /// 不允许（红色高亮，松手后由模型写说明）
    case reject(PageLayoutEditorModel.DropRejection)

    var rejection: PageLayoutEditorModel.DropRejection? {
        if case .reject(let reason) = self { return reason }
        return nil
    }
}

/// 行拖拽：非根行可作拖拽源（根节点只能作为落点容器）
private struct NodeRowDragModifier: ViewModifier {
    /// 是否可作拖拽源（根节点不可拖）
    let isDragSource: Bool
    let node: PageLayoutNode
    /// 拖拽开始时的扁平行快照（模型是 @MainActor，非隔离的代理里不能读模型）
    let rows: [LayoutTreeRow]
    let session: LayoutDragSession
    let editor: PageLayoutEditorModel
    @Binding var dropTargetUUID: UUID?
    @Binding var dropResolution: LayoutDropResolution?

    @ViewBuilder
    func body(content: Content) -> some View {
        let drop = content.onDrop(of: [.text], delegate: dropDelegate)
        if isDragSource {
            drop.onDrag {
                session.sourceUUID = node.uuid // 不发布变化 → 不触发重渲染
                // payload 只带节点身份（uuid 串），不传整棵树
                return NSItemProvider(object: node.uuid.uuidString as NSString)
            }
        } else {
            drop
        }
    }

    private var dropDelegate: NodeDropDelegate {
        NodeDropDelegate(target: node,
                         rows: rows,
                         session: session,
                         editor: editor,
                         dropTargetUUID: $dropTargetUUID,
                         dropResolution: $dropResolution)
    }
}

/// 行落点代理：按落点在行内的位置 + 目标行是否为容器自动判定意图。
/// · 容器行：上 / 下边缘区 = 同级前插 / 后插；中间区 = 拖入该容器
/// · 叶子行：上半区 = 前插、下半区 = 后插（叶子没有子槽位，中间没有「拖入」语义）
/// 一律返回 `.move`（不用系统 `.forbidden`）：系统对 `.forbidden` 的落点不交付
/// `performDrop`，那样松手就没法解释为什么没反应；非法落点用红色高亮兜住视觉，
/// 并在松手后由代理按解析结果写 banner。
private struct NodeDropDelegate: DropDelegate {
    /// 容器行上下边缘区高度（行高 44：上 12 / 中 20 / 下 12）
    private static let edgeZone: CGFloat = 12

    let target: PageLayoutNode
    let rows: [LayoutTreeRow]
    let session: LayoutDragSession
    let editor: PageLayoutEditorModel
    @Binding var dropTargetUUID: UUID?
    @Binding var dropResolution: LayoutDropResolution?

    /// 是否为本应用树内拖拽（payload 是 uuid 字符串）
    private func acceptsPayload(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    private func rowIndex(of uuid: UUID) -> Int? {
        rows.firstIndex { $0.node.uuid == uuid }
    }

    /// 某行节点的父节点（扁平行里最近一个深度更小的先行行）；根行返回 nil
    private func parentNode(ofIndex index: Int) -> PageLayoutNode? {
        let depth = rows[index].depth
        guard depth > 0 else { return nil }
        for j in stride(from: index - 1, through: 0, by: -1) where rows[j].depth < depth {
            return rows[j].node
        }
        return nil
    }

    /// 落点解析（悬停与松手共用）
    private func resolution(forY y: CGFloat) -> LayoutDropResolution {
        guard let sourceUUID = session.sourceUUID,
              let sourceIndex = rowIndex(of: sourceUUID),
              sourceIndex > 0 else {
            return .reject(.targetMissing)
        }
        // 拖到自己所在行 = 无操作（`.insertBefore` 在模型里等价于原地不动）
        guard sourceUUID != target.uuid else { return .insertBefore }

        if target.containerKey != nil {
            if y < Self.edgeZone { return siblingInsertion(.insertBefore) }
            if y > LayoutNodeTreeList.rowHeight - Self.edgeZone { return siblingInsertion(.insertAfter) }
            // 中间区 = 拖入该容器；自环防护：**目标落在被拖节点子树内（含自身）** → 成环，判红。
            // 方向必须与模型 `validateDrop` 一致（拖拽源子树里找目标），写反会「放行成环、误拒上移」。
            if let sourceNode = rows.first(where: { $0.node.uuid == sourceUUID })?.node,
               sourceNode.firstNode(uuid: target.uuid) != nil {
                return .reject(.intoSelfOrDescendant)
            }
            return .into
        }
        // 叶子行：上半区前插 / 下半区后插
        return siblingInsertion(y < LayoutNodeTreeList.rowHeight / 2 ? .insertBefore : .insertAfter)
    }

    /// 同级插入合法性：目标行必须有父容器（根行没有），且与被拖节点同父
    private func siblingInsertion(_ intent: LayoutDropResolution) -> LayoutDropResolution {
        guard let targetIndex = rowIndex(of: target.uuid),
              let targetParent = parentNode(ofIndex: targetIndex),
              let sourceUUID = session.sourceUUID,
              let sourceIndex = rowIndex(of: sourceUUID),
              targetParent.uuid == parentNode(ofIndex: sourceIndex)?.uuid else {
            return .reject(.crossLevel)
        }
        return intent
    }

    func validateDrop(info: DropInfo) -> Bool {
        acceptsPayload(info)
    }

    func dropEntered(info: DropInfo) {
        dropTargetUUID = target.uuid
        dropResolution = resolution(forY: info.location.y)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard acceptsPayload(info) else { return DropProposal(operation: .forbidden) }
        dropTargetUUID = target.uuid
        dropResolution = resolution(forY: info.location.y)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        guard dropTargetUUID == target.uuid else { return }
        dropTargetUUID = nil
        dropResolution = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let outcome = resolution(forY: info.location.y)
        dropTargetUUID = nil
        dropResolution = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        // 异步取回 payload（uuid 串）后回主线程落到模型：模型是 @MainActor
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString, let uuid = UUID(uuidString: text as String) else { return }
            Task { @MainActor in
                switch outcome {
                case .into:
                    editor.moveInto(uuid, container: target.uuid)
                case .insertBefore:
                    editor.move(uuid, beforeSibling: target.uuid)
                case .insertAfter:
                    editor.move(uuid, afterSibling: target.uuid)
                case .reject(let reason):
                    editor.reportDropRejected(reason)
                }
            }
        }
        return true
    }
}

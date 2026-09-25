//
//  LayoutNodeInspector.swift
//  Kline
//
//  布局编辑器 - 右侧检查器：按选中节点的 type 生成字段表单。
//  所有取值绑定都经过 PageLayoutEditorModel 的 setter（不直接绑定 class 属性，
//  否则就地改动不会触发重绘）；行高固定 44 + Divider 分隔。
//  底部固定「删除本节点」（根节点禁用并说明）。
//

import SwiftUI

struct LayoutNodeInspector: View {
    @ObservedObject var editor: PageLayoutEditorModel

    var body: some View {
        Group {
            if let node = editor.selectedNode {
                inspector(for: node)
            } else {
                VStack {
                    Spacer()
                    Text("在左侧选择节点开始编辑")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - 主体

    private func inspector(for node: PageLayoutNode) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow(node)
                    Divider()
                    switch node.type {
                    case "vstack", "hstack", "zstack":
                        stackFields(node)
                    case "scroll":
                        scrollFields(node)
                    case "card":
                        cardFields(node)
                    case "frame":
                        frameFields(node)
                    case "widget":
                        widgetFields(node, scrollProxy: proxy)
                    default:
                        noFieldsRow("该节点无可调字段")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { deleteBar }
            .background(Color(.systemBackground))
        }
    }

    private func headerRow(_ node: PageLayoutNode) -> some View {
        HStack(spacing: 12) {
            Text(primaryTitle(node))
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 12)
            Text(String(node.uuid.uuidString.prefix(8)))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
    }

    // MARK: - 容器字段

    @ViewBuilder
    private func stackFields(_ node: PageLayoutNode) -> some View {
        row("间距") { doubleStepper({ node.spacing ?? 0 }, range: 0...64, step: 2) { editor.setSpacing($0, on: node) } }
        if node.type != "zstack" {
            row("对齐") {
                Menu {
                    ForEach(alignmentOptions(node.type), id: \.self) { option in
                        Button(alignmentTitle(option)) { editor.setAlignment(option, on: node) }
                    }
                } label: {
                    menuLabel(alignmentTitle(node.alignment ?? "center"))
                }
            }
        }
    }

    @ViewBuilder
    private func scrollFields(_ node: PageLayoutNode) -> some View {
        row("方向") {
            Menu {
                ForEach(["vertical", "horizontal"], id: \.self) { option in
                    Button(axisTitle(option)) { editor.setAxis(option, on: node) }
                }
            } label: {
                menuLabel(axisTitle(node.axis ?? "vertical"))
            }
        }
        row("间距") { doubleStepper({ node.spacing ?? 0 }, range: 0...64, step: 2) { editor.setSpacing($0, on: node) } }
        paddingRow(node, "顶部内边距", "top")
        paddingRow(node, "左侧内边距", "leading")
        paddingRow(node, "底部内边距", "bottom")
        paddingRow(node, "右侧内边距", "trailing")
        row("显示滚动条") {
            Toggle("", isOn: Binding(get: { node.showsIndicators ?? false },
                                     set: { editor.setShowsIndicators($0, on: node) }))
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func cardFields(_ node: PageLayoutNode) -> some View {
        row("标题") {
            TextField("卡片标题", text: Binding(get: { node.title ?? "" },
                                              set: { editor.setNodeTitle($0, on: node) }))
                .font(.system(size: 15))
                .multilineTextAlignment(.trailing)
                .disableAutocorrection(true)
        }
        row("紧凑") {
            Toggle("", isOn: Binding(get: { node.compact ?? false },
                                     set: { editor.setCompact($0, on: node) }))
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func frameFields(_ node: PageLayoutNode) -> some View {
        row("无限宽（infinity）") {
            Toggle("", isOn: Binding(get: { isInfinityWidth(node.maxWidth) },
                                     set: { editor.setMaxWidthInfinity($0, on: node) }))
                .labelsHidden()
        }
        row("对齐") {
            Menu {
                ForEach(Self.frameAlignments, id: \.self) { option in
                    Button(alignmentTitle(option)) { editor.setAlignment(option, on: node) }
                }
            } label: {
                menuLabel(alignmentTitle(node.alignment ?? "center"))
            }
        }
        row("最小高度") {
            doubleStepper({ node.minHeight ?? 0 }, range: 0...400, step: 4) { editor.setMinHeight($0, on: node) }
        }
    }

    // MARK: - 控件字段

    @ViewBuilder
    private func widgetFields(_ node: PageLayoutNode, scrollProxy: ScrollViewProxy) -> some View {
        row("控件") {
            Menu {
                ForEach(HomeWidgetEditorSchema.all, id: \.name) { descriptor in
                    Button(descriptor.title) { editor.setWidgetName(descriptor.name, on: node) }
                }
            } label: {
                menuLabel(HomeWidgetEditorSchema.descriptor(for: node.name ?? "")?.title ?? (node.name ?? "未选择"))
            }
        }

        if let descriptor = HomeWidgetEditorSchema.descriptor(for: node.name ?? ""), !descriptor.params.isEmpty {
            ForEach(descriptor.params, id: \.key) { param in
                paramRow(param, node: node, scrollProxy: scrollProxy)
            }
        } else {
            noFieldsRow("该控件无可调参数")
        }
    }

    @ViewBuilder
    private func paramRow(_ param: WidgetParamDescriptor, node: PageLayoutNode, scrollProxy: ScrollViewProxy) -> some View {
        switch param.kind {
        case .toggle(let defaultValue):
            row(param.title) {
                Toggle("", isOn: Binding(get: { node.params?.bool(param.key, default: defaultValue) ?? defaultValue },
                                         set: { editor.setBool(param.key, $0, on: node) }))
                    .labelsHidden()
            }

        case .stepper(let defaultValue, let range, let note):
            row(param.title) {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("\(node.params?.int(param.key, default: defaultValue) ?? defaultValue)")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                        Stepper("", value: Binding(get: { node.params?.int(param.key, default: defaultValue) ?? defaultValue },
                                                   set: { editor.setInt(param.key, $0, on: node) }),
                                in: range, step: 1)
                            .labelsHidden()
                    }
                    if let note = note {
                        Text(note).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
            }

        case .options(let options, let defaultValue):
            row(param.title) {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button(option) { editor.setString(param.key, option, on: node) }
                    }
                } label: {
                    menuLabel(node.params?.string(param.key, default: defaultValue) ?? defaultValue)
                }
            }

        case .orderedList(let source, let maxCount, let note):
            OrderedListParamRow(editor: editor, param: param, node: node,
                                source: source, maxCount: maxCount, note: note,
                                scrollProxy: scrollProxy)

        case .dynamicOptions(let source, let note):
            DynamicOptionsParamRow(editor: editor, param: param, node: node,
                                   source: source, note: note)

        case .text(let placeholder, let note):
            row(param.title) {
                VStack(alignment: .trailing, spacing: 2) {
                    TextField(placeholder, text: Binding(
                        get: { node.params?.string(param.key, default: "") ?? "" },
                        set: { editor.setString(param.key, $0, on: node) }))
                        .font(.system(size: 15))
                        .multilineTextAlignment(.trailing)
                        .disableAutocorrection(true)
                    if let note = note {
                        Text(note).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
            }

        case .textList(let placeholder, let note):
            TextListParamRow(editor: editor, param: param, node: node,
                             placeholder: placeholder, note: note)
        }
    }

    // MARK: - 底部删除

    private var deleteBar: some View {
        VStack(spacing: 4) {
            if !editor.canRemoveSelected {
                Text("根节点不可删除")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Button {
                editor.removeSelected()
            } label: {
                Text("删除本节点")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(editor.canRemoveSelected ? .red : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!editor.canRemoveSelected)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }

    // MARK: - 通用行

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 15))
                Spacer(minLength: 12)
                content()
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            Divider()
        }
    }

    private func noFieldsRow(_ text: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            Divider()
        }
    }

    private func paddingRow(_ node: PageLayoutNode, _ title: String, _ key: String) -> some View {
        row(title) {
            doubleStepper({ paddingValue(node, key) }, range: 0...64, step: 1) {
                editor.setPaddingEdge(key, $0, on: node)
            }
        }
    }

    /// 数值 + 步进器（Double 显示整数）；`get` 每次现取，避免连点步进器时读到旧快照
    private func doubleStepper(_ get: @escaping () -> Double, range: ClosedRange<Double>, step: Double,
                               set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text("\(Int(get()))")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .frame(minWidth: 28, alignment: .trailing)
            Stepper("", value: Binding(get: get, set: set), in: range, step: step)
                .labelsHidden()
        }
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 15)).foregroundColor(.blue)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    // MARK: - 取值 / 文案

    private static let frameAlignments = [
        "top", "center", "bottom", "leading", "trailing",
        "topLeading", "topTrailing", "bottomLeading", "bottomTrailing"
    ]

    private func alignmentOptions(_ type: String) -> [String] {
        if type == "hstack" {
            return ["top", "center", "bottom", "firstTextBaseline", "lastTextBaseline"]
        }
        return ["leading", "center", "trailing"]
    }

    private func alignmentTitle(_ raw: String) -> String {
        switch raw {
        case "top": return "顶部"
        case "bottom": return "底部"
        case "leading": return "左对齐"
        case "trailing": return "右对齐"
        case "center": return "居中"
        case "firstTextBaseline": return "首行基线"
        case "lastTextBaseline": return "末行基线"
        case "topLeading": return "左上"
        case "topTrailing": return "右上"
        case "bottomLeading": return "左下"
        case "bottomTrailing": return "右下"
        default: return raw
        }
    }

    private func axisTitle(_ raw: String) -> String {
        raw == "horizontal" ? "水平" : "垂直"
    }

    private func paddingValue(_ node: PageLayoutNode, _ key: String) -> Double {
        guard let padding = node.padding else { return 0 }
        switch key {
        case "top": return padding.top
        case "leading": return padding.leading
        case "bottom": return padding.bottom
        default: return padding.trailing
        }
    }

    private func isInfinityWidth(_ width: PageLayoutWidth?) -> Bool {
        if case .infinity? = width { return true }
        return false
    }

    private func primaryTitle(_ node: PageLayoutNode) -> String {
        if node.type == "widget" {
            return HomeWidgetEditorSchema.descriptor(for: node.name ?? "")?.title ?? "控件"
        }
        return HomeWidgetEditorSchema.nodeTypeTitles[node.type] ?? node.type
    }
}

// MARK: - 动态单选参数行

/// 动态单选：候选运行时解析（分组 / 账户等）；键缺失 = 首项（默认项）
private struct DynamicOptionsParamRow: View {
    @ObservedObject var editor: PageLayoutEditorModel
    let param: WidgetParamDescriptor
    let node: PageLayoutNode
    let source: WidgetParamCandidates
    let note: String?

    var body: some View {
        DynamicCandidatesReader(source: source) { candidates in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(param.title).font(.system(size: 15))
                    Spacer(minLength: 12)
                    Menu {
                        ForEach(candidates) { candidate in
                            Button {
                                // 首项 = 缺省项（全部 / 全部账户）：选择它即删除该键，保持「缺省 = 键缺失」
                                if candidate.id == candidates.first?.id {
                                    editor.removeParam(param.key, on: node)
                                } else {
                                    editor.setString(param.key, candidate.id, on: node)
                                }
                            } label: {
                                if isEffective(candidate.id, candidates: candidates) {
                                    Label(candidate.title, systemImage: "checkmark")
                                } else {
                                    Text(candidate.title)
                                }
                            }
                            .accessibilityIdentifier("layout.param.\(param.key).option.\(candidate.id)")
                        }
                    } label: {
                        InspectorMenuLabel(title: currentTitle(candidates))
                    }
                    .accessibilityIdentifier("layout.param.\(param.key).menu")
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 44)

                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
                Divider()
            }
        }
    }

    /// 当前生效的候选 id：键缺失（或已失效）→ 首项（默认项）
    private func effectiveID(_ candidates: [ParamCandidate]) -> String? {
        let stored = node.params?.string(param.key, default: "")
        if let stored, !stored.isEmpty, candidates.contains(where: { $0.id == stored }) {
            return stored
        }
        return candidates.first?.id
    }

    private func isEffective(_ id: String, candidates: [ParamCandidate]) -> Bool {
        effectiveID(candidates) == id
    }

    private func currentTitle(_ candidates: [ParamCandidate]) -> String {
        guard let id = effectiveID(candidates) else { return "—" }
        return candidates.first(where: { $0.id == id })?.title ?? "—"
    }
}

// MARK: - 有序多选参数行

/// 有序多选：可展开区域内维护「已选（排序/删除）+ 可添加」；
/// 键缺失 = 默认（全部候选）；显式空数组 = 清空（与缺省语义不同，模型层保留空数组）
private struct OrderedListParamRow: View {
    @ObservedObject var editor: PageLayoutEditorModel
    let param: WidgetParamDescriptor
    let node: PageLayoutNode
    let source: WidgetParamCandidates
    let maxCount: Int?
    let note: String?
    let scrollProxy: ScrollViewProxy

    @State private var expanded = false

    /// 已选区锚点：展开后自动滚动到该位置，避免长列表初始行落在检查器可视区之外
    private var topAnchor: String { "orderedListTop.\(param.key)" }

    private var selectedIDs: [String]? { node.params?.strings(param.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                let willExpand = !expanded
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                if willExpand {
                    // 展开动画 + 候选异步加载后再定位，确保首行可见可点
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            scrollProxy.scrollTo(topAnchor, anchor: .top)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(param.title)
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                    Spacer(minLength: 8)
                    Text(summaryText)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("layout.param.\(param.key)")

            Divider()

            if expanded {
                DynamicCandidatesReader(source: source) { candidates in
                    expandedContent(candidates)
                }
            }
        }
    }

    @ViewBuilder
    private func expandedContent(_ candidates: [ParamCandidate]) -> some View {
        if let note {
            sectionNote(note)
        }

        // 生效序列：键缺失时展示默认序列（所见即所得）；首次移除 / 排序时自动落地为自定义序列
        let effective = selectedIDs ?? WidgetParamCandidateProvider.defaultOrder(for: source)

        if selectedIDs == nil {
            infoLine("当前为默认：\(WidgetParamCandidateProvider.defaultTitle(source))。直接移除或排序即开始自定义。")
        } else if effective.isEmpty {
            // indices 源规格约定：空选 / 全失效回落默认前 4（HomePageModel.indexRows）
            infoLine(source == .indices
                     ? "未选择任何项目：将显示默认前 4 只指数"
                     : "未选择任何项目：该控件将不显示内容")
        }
        sectionHeader("已选 · \(effective.count)\(maxCount.map { "/\($0)" } ?? "")")
            .id(topAnchor)
        ForEach(Array(effective.enumerated()), id: \.element) { index, id in
            selectedRow(id: id, index: index, total: effective.count, candidates: candidates)
        }

        sectionHeader("可添加")
        let addable = candidates.filter { !effective.contains($0.id) }
        let atMax = maxCount.map { effective.count >= $0 } ?? false
        if addable.isEmpty {
            infoLine("已全部添加")
        } else {
            ForEach(addable) { candidate in
                candidateRow(candidate, disabled: atMax)
            }
            if atMax {
                infoLine("已达上限\(maxCount.map { "（\($0) 项）" } ?? "")，先移除再添加")
            }
        }

        if selectedIDs != nil {
            Button {
                editor.removeParam(param.key, on: node)
            } label: {
                Text("恢复默认")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("layout.param.\(param.key).reset")
            Divider()
        }
    }

    private func selectedRow(id: String, index: Int, total: Int, candidates: [ParamCandidate]) -> some View {
        let candidate = candidates.first(where: { $0.id == id })
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: candidate?.iconName ?? "questionmark.circle")
                    .font(.system(size: 14))
                    .foregroundColor(candidate == nil ? .secondary : .blue)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate?.title ?? "失效项")
                        .font(.system(size: 14))
                        .foregroundColor(candidate == nil ? .secondary : .primary)
                    if let subtitle = candidate?.subtitle {
                        Text(subtitle).font(.system(size: 10)).foregroundColor(.secondary)
                    } else if candidate == nil {
                        Text(id).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    step(index: index, up: true)
                } label: {
                    Image(systemName: "chevron.up").font(.system(size: 13))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .accessibilityIdentifier("layout.param.\(param.key).selected.\(id).up")
                Button {
                    step(index: index, up: false)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 13))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(index >= total - 1)
                .accessibilityIdentifier("layout.param.\(param.key).selected.\(id).down")
                Button {
                    removeID(id)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.red)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("layout.param.\(param.key).selected.\(id).remove")
            }
            .padding(.leading, 20)
            .padding(.trailing, 4)
            .frame(minHeight: 44)
            Divider().padding(.leading, 20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("layout.param.\(param.key).selected.\(id)")
    }

    private func candidateRow(_ candidate: ParamCandidate, disabled: Bool) -> some View {
        VStack(spacing: 0) {
            Button {
                editor.listAppend(param.key, id: candidate.id, maxCount: maxCount, on: node)
            } label: {
                HStack(spacing: 10) {
                    if let icon = candidate.iconName {
                        Image(systemName: icon).font(.system(size: 14)).foregroundColor(.blue).frame(width: 22)
                    } else {
                        Image(systemName: "plus.circle").font(.system(size: 14)).foregroundColor(.blue).frame(width: 22)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(candidate.title).font(.system(size: 14))
                        if let subtitle = candidate.subtitle {
                            Text(subtitle).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "plus.circle")
                        .font(.system(size: 15))
                        .foregroundColor(disabled ? .secondary : .blue)
                }
                .padding(.leading, 20)
                .padding(.trailing, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            // 锚点挂 Button（测试按 .buttons 查询并校验 isEnabled），不挂外层 VStack
            .accessibilityIdentifier("layout.param.\(param.key).candidate.\(candidate.id)")
            Divider().padding(.leading, 20)
        }
    }

    private func step(index: Int, up: Bool) {
        // 与 Array.move(fromOffsets:toOffset:) 同口径：向下移动目标下标 = index + 2
        let target = up ? index - 1 : index + 2
        if selectedIDs != nil {
            editor.listMove(param.key,
                            fromOffsets: IndexSet(integer: index),
                            toOffset: target,
                            on: node)
            return
        }
        // 缺省态首次排序：先把默认序列落地为自定义值，再应用同口径移动
        var seeded = WidgetParamCandidateProvider.defaultOrder(for: source)
        guard index >= 0, index < seeded.count else { return }
        let element = seeded.remove(at: index)
        let destination = target > index ? target - 1 : target
        seeded.insert(element, at: max(0, min(destination, seeded.count)))
        editor.setStrings(param.key, seeded, on: node)
    }

    /// 删除已选项：缺省态先把默认序列落地（删除动作本身即「开始自定义」）
    private func removeID(_ id: String) {
        if selectedIDs != nil {
            editor.listRemove(param.key, id: id, on: node)
        } else {
            let seeded = WidgetParamCandidateProvider.defaultOrder(for: source).filter { $0 != id }
            editor.setStrings(param.key, seeded, on: node)
        }
    }

    private var summaryText: String {
        guard let selectedIDs else { return "默认" }
        if selectedIDs.isEmpty { return "空" }
        return "\(selectedIDs.count) 项\(maxCount.map { "/\($0)" } ?? "")"
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
    }

    private func sectionNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }

    private func infoLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }
}

// MARK: - 自由文本列表参数行

/// 自由文本列表参数行：每行一条、可增可删；写入 JSON 的 `[String]`。
/// 与「有序多选」的区别：候选项不是预置 id，而是用户直接输入的文本（通用控件用）。
private struct TextListParamRow: View {
    @ObservedObject var editor: PageLayoutEditorModel
    let param: WidgetParamDescriptor
    let node: PageLayoutNode
    let placeholder: String
    let note: String?

    /// 当前条目；键缺失视为空列表（与 `WidgetParams.strings(_:)` 的 nil 语义一致）
    private var items: [String] { node.params?.strings(param.key) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if items.isEmpty {
                Text("暂无条目，点「添加一条」新增")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(items.indices, id: \.self) { index in
                    itemRow(index)
                }
            }
            if let note = note {
                Text(note).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        Divider()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(param.title)
                .font(.system(size: 15))
            Spacer(minLength: 12)
            Button {
                var list = items
                list.append("")
                editor.setStrings(param.key, list, on: node)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle").font(.system(size: 13))
                    Text("添加一条").font(.system(size: 13))
                }
                .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
        }
    }

    /// 单条：序号 + 文本输入 + 删除。下标越界时（并发删改）按空串回落，不崩
    private func itemRow(_ index: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 18, alignment: .trailing)

            TextField(placeholder, text: Binding(
                get: { index < items.count ? items[index] : "" },
                set: { newValue in
                    var list = items
                    guard index < list.count else { return }
                    list[index] = newValue
                    editor.setStrings(param.key, list, on: node)
                }))
                .font(.system(size: 14))
                .disableAutocorrection(true)

            Button {
                var list = items
                guard index < list.count else { return }
                list.remove(at: index)
                editor.setStrings(param.key, list, on: node)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 动态候选读取

/// 订阅候选相关数据单例，候选变化（指数加载 / 分组增删 / 账户增删）时自动刷新
private struct DynamicCandidatesReader<Content: View>: View {
    let source: WidgetParamCandidates
    @ViewBuilder let content: ([ParamCandidate]) -> Content
    @State private var candidates: [ParamCandidate] = []

    var body: some View {
        content(candidates)
            .onAppear(perform: reload)
            .onReceive(DatabaseManager.shared.$metaList) { _ in reload() }
            .onReceive(FavoritesStore.shared.$groups) { _ in reload() }
            .onReceive(SimStore.shared.$accounts) { _ in reload() }
    }

    private func reload() {
        candidates = WidgetParamCandidateProvider.candidates(source)
    }
}

// MARK: - 共享小件

private struct InspectorMenuLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 15)).foregroundColor(.blue)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
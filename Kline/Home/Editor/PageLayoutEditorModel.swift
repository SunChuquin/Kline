//
//  PageLayoutEditorModel.swift
//  Kline
//
//  布局编辑器 - 编辑态模型。
//  持有编辑器全部编辑态：当前档位、草稿配置、选中节点、折叠集合、JSON 原文与错误、
//  状态提示、脏标记，以及树操作（选中 / 同级重排 / 增删节点 / 参数改写 / JSON 双向）。
//
//  关键约定：
//  - 节点树是**引用类型**（PageLayoutNode 为 final class）：就地改字段不触发 @Published，
//    故所有改动方法末尾都必须调 `touchDraft()`（内部 `objectWillChange.send()`），否则预览不刷新。
//  - 脏标记一律用「规范化 JSON 文本比较」（不用 Equatable）：编辑期 uuid 会使重新解码后的树不再相等。
//  - 树规模 < 40 节点，按 uuid 定位的直接遍历成本可忽略。
//

import Foundation
import Combine

// MARK: - 树列表的一行

/// 树列表的一行：节点 + 层级深度（`Identifiable` 让 List/ForEach/onMove 有稳定身份）。
/// 不用元组：Swift 不支持对元组取 key path（`\.node.uuid` 无法编译）。
struct LayoutTreeRow: Identifiable {
    let node: PageLayoutNode
    /// 层级深度（0 = 根）
    let depth: Int

    /// 列表身份 = 编辑期节点身份
    var id: UUID { node.uuid }
}

@MainActor
final class PageLayoutEditorModel: ObservableObject {

    /// 编辑器覆盖的页面（本轮仅首页）
    static let page = "home"

    /// 当前编辑的档位 id（A / B / C / D）
    @Published var styleID: String
    /// 草稿配置（可编辑、未保存）
    @Published var file: PageLayoutFile?
    /// 当前选中节点 uuid
    @Published var selectedUUID: UUID?
    /// 已折叠的容器 uuid 集合
    @Published var collapsed: Set<UUID> = []
    /// JSON 原文页签的文本
    @Published var jsonText: String = ""
    /// JSON 原文解析错误（可读文案）
    @Published var jsonError: String? = nil
    /// 页签：false = 表单，true = JSON 原文
    @Published var showsJSONTab: Bool = false
    /// 状态提示（保存 / 恢复默认 / 操作被拒等）
    @Published var banner: String? = nil

    /// 进入编辑器（或上次保存）时的规范化文本：脏标记基准
    private(set) var savedText: String = ""

    init() {
        styleID = PageLayoutStore.shared.homeLayout.rawValue
    }

    // MARK: - 派生

    /// 当前档位的根节点
    var layoutRoot: PageLayoutNode? {
        file?.layouts[styleID]?.root
    }

    /// 当前档位标题
    var styleTitle: String {
        file?.layouts[styleID]?.title ?? styleID
    }

    /// 是否有未保存改动（规范化文本比较）
    var isDirty: Bool {
        let now = file.flatMap { PageLayoutCodec.canonicalText($0) } ?? ""
        return now != savedText
    }

    /// 扁平化的节点行（应用折叠：折叠的容器不展开其子树）
    var flattenedRows: [LayoutTreeRow] {
        guard let root = layoutRoot else { return [] }
        var result: [LayoutTreeRow] = []
        func walk(_ node: PageLayoutNode, _ depth: Int) {
            result.append(LayoutTreeRow(node: node, depth: depth))
            if collapsed.contains(node.uuid) { return }
            for child in node.childList {
                walk(child, depth + 1)
            }
        }
        walk(root, 0)
        return result
    }

    /// 当前选中节点
    var selectedNode: PageLayoutNode? {
        guard let uuid = selectedUUID else { return nil }
        return layoutRoot?.firstNode(uuid: uuid)
    }

    /// 是否可删除当前选中节点（选中存在，且不是根节点）
    var canRemoveSelected: Bool {
        guard let uuid = selectedUUID, let root = layoutRoot else { return false }
        return uuid != root.uuid && root.firstNode(uuid: uuid) != nil
    }

    /// 就地改动后必须调用：节点是引用类型，就地改字段不触发 @Published，不调它预览不刷新
    func touchDraft() {
        objectWillChange.send()
    }

    // MARK: - 载入 / 保存 / 恢复默认

    /// 从配置仓库取草稿底本（不可用时先种回内置默认再取）
    func loadFromStore() {
        applyStoreFile()
        ensureStyleAvailable()
    }

    /// 同 `loadFromStore`，但不改 `styleID`（恢复默认后调用）
    func reloadFromStoreKeepingStyle() {
        applyStoreFile()
    }

    @discardableResult
    func save() -> Bool {
        guard let file = file else {
            banner = "保存失败，请重试"
            return false
        }
        guard PageLayoutConfigStore.shared.save(file, page: Self.page) else {
            banner = "保存失败，请重试"
            return false
        }
        savedText = PageLayoutCodec.canonicalText(file) ?? savedText
        banner = "已保存"
        return true
    }

    @discardableResult
    func resetToDefault() -> Bool {
        guard PageLayoutConfigStore.shared.resetToBuiltIn(page: Self.page) else {
            banner = "恢复默认失败"
            return false
        }
        reloadFromStoreKeepingStyle()
        banner = "已恢复默认"
        return true
    }

    // MARK: - 树操作：选中 / 折叠

    func select(_ node: PageLayoutNode?) {
        selectedUUID = node?.uuid
    }

    func toggleCollapse(_ node: PageLayoutNode) {
        guard node.containerKey != nil else { return }
        if collapsed.contains(node.uuid) {
            collapsed.remove(node.uuid)
        } else {
            collapsed.insert(node.uuid)
        }
    }

    // MARK: - 树操作：同级重排

    /// 同级重排（仅单元素、仅同级）；跨级或 `.child` 容器给出提示并放弃
    func move(fromOffsets: IndexSet, toOffset: Int) {
        guard fromOffsets.count == 1, let fromIndex = fromOffsets.first else { return }
        let rows = flattenedRows
        guard fromIndex >= 0, fromIndex < rows.count else { return }

        let moving = rows[fromIndex].node
        guard let root = layoutRoot,
              let movingInfo = root.firstParent(of: moving.uuid) else {
            banner = "根节点不可移动"
            return
        }
        // `.child` 容器只有一个子槽位，没有同级可交换
        guard movingInfo.parent.containerKey != .child else {
            banner = "该容器仅容纳一个子节点，不支持重排"
            return
        }

        // 落点：toOffset 落在末行之后 = 追加到父容器末尾；
        // 否则 = 插到该行节点之前（若该节点与移动节点不同父 → 跨级，拒绝）
        let placeAfter: Bool
        let anchor: PageLayoutNode
        if toOffset >= rows.count {
            // 末行之后：以「最后一个与移动节点同父的可见行」（即父容器末子）为锚点，
            // 避免末行是别的容器的子节点时被误判成跨级
            let movingParentUUID = movingInfo.parent.uuid
            guard let lastSameLevel = rows.last(where: {
                root.firstParent(of: $0.node.uuid)?.parent.uuid == movingParentUUID
            }) else {
                banner = "已忽略跨级拖动：仅支持同级重排"
                return
            }
            placeAfter = true
            anchor = lastSameLevel.node
        } else {
            placeAfter = false
            anchor = rows[toOffset].node
        }
        if anchor.uuid == moving.uuid { return }

        // 同级判定：锚点必须与移动节点同父
        guard let anchorInfo = root.firstParent(of: anchor.uuid),
              anchorInfo.parent.uuid == movingInfo.parent.uuid else {
            banner = "已忽略跨级拖动：仅支持同级重排"
            return
        }

        // 锚点在父容器 childList 里的下标（移除前口径）
        let anchorIndex = anchorInfo.index
        guard movingInfo.parent.removeChild(uuid: moving.uuid) else { return }

        var children = movingInfo.parent.children ?? []
        var insertIndex = placeAfter ? children.count : anchorIndex
        if !placeAfter && movingInfo.index < anchorIndex { insertIndex -= 1 }
        insertIndex = max(0, min(insertIndex, children.count))
        children.insert(moving, at: insertIndex)
        movingInfo.parent.children = children

        banner = nil
        touchDraft()
    }

    /// 是否可对选中节点做同级重排：选中存在、不是根节点、父容器是 `.children`（非 `.child`）
    var canMoveSelected: Bool {
        guard let uuid = selectedUUID, let root = layoutRoot, uuid != root.uuid else { return false }
        guard let info = root.firstParent(of: uuid) else { return false }
        return info.parent.containerKey == .children
    }

    /// 与上一个同级兄弟交换位置
    func moveSelectedUp() {
        guard let target = movableSelection() else { return }
        guard target.index > 0 else {
            banner = "已到本层顶部"
            return
        }
        var children = target.parent.children ?? []
        children.swapAt(target.index, target.index - 1)
        target.parent.children = children
        banner = nil
        touchDraft()
    }

    /// 与下一个同级兄弟交换位置
    func moveSelectedDown() {
        guard let target = movableSelection() else { return }
        var children = target.parent.children ?? []
        guard target.index < children.count - 1 else {
            banner = "已到本层底部"
            return
        }
        children.swapAt(target.index, target.index + 1)
        target.parent.children = children
        banner = nil
        touchDraft()
    }

    /// 上移 / 下移共用的前置校验：返回可重排的父容器与选中节点在其中的下标；不可重排则给提示并返回 nil
    private func movableSelection() -> (parent: PageLayoutNode, index: Int)? {
        guard let uuid = selectedUUID, let root = layoutRoot else {
            banner = "请先选择要移动的节点"
            return nil
        }
        guard uuid != root.uuid else {
            banner = "根节点不可移动"
            return nil
        }
        guard let info = root.firstParent(of: uuid) else {
            banner = "无法定位父容器"
            return nil
        }
        guard info.parent.containerKey == .children else {
            banner = "该容器仅容纳一个子节点，不支持重排"
            return nil
        }
        return (info.parent, info.index)
    }

    // MARK: - 树操作：增 / 删

    func insertNode(type: String) {
        guard let node = PageLayoutNode.make(type: type) else {
            banner = "未知节点类型：\(type)"
            return
        }
        insert(node)
    }

    func insertWidget(name: String) {
        guard let node = PageLayoutNode.make(type: "widget") else {
            banner = "无法创建控件节点"
            return
        }
        node.name = name
        insert(node)
    }

    func removeSelected() {
        guard canRemoveSelected, let uuid = selectedUUID, let root = layoutRoot,
              let info = root.firstParent(of: uuid) else {
            banner = "根节点不可删除"
            return
        }
        guard info.parent.removeChild(uuid: uuid) else {
            banner = "根节点不可删除"
            return
        }
        collapsed.remove(uuid)
        selectedUUID = nil
        banner = nil
        touchDraft()
    }

    // MARK: - 参数改写

    func setBool(_ key: String, _ value: Bool, on node: PageLayoutNode) {
        ensureParams(node)
        node.params?.values[key] = .bool(value)
        touchDraft()
    }

    func setInt(_ key: String, _ value: Int, on node: PageLayoutNode) {
        ensureParams(node)
        node.params?.values[key] = .int(value)
        touchDraft()
    }

    func setString(_ key: String, _ value: String, on node: PageLayoutNode) {
        ensureParams(node)
        node.params?.values[key] = .string(value)
        touchDraft()
    }

    /// 换控件名并清空旧 params（避免残留无关键）
    func setWidgetName(_ name: String, on node: PageLayoutNode) {
        node.name = name
        node.params = WidgetParams()
        touchDraft()
    }

    func setNodeTitle(_ title: String, on node: PageLayoutNode) {
        node.title = title
        touchDraft()
    }

    func setSpacing(_ value: Double, on node: PageLayoutNode) {
        node.spacing = value
        touchDraft()
    }

    /// key: "top" / "leading" / "bottom" / "trailing"
    func setPaddingEdge(_ key: String, _ value: Double, on node: PageLayoutNode) {
        if node.padding == nil { node.padding = PageLayoutPadding() }
        switch key {
        case "top": node.padding?.top = value
        case "leading": node.padding?.leading = value
        case "bottom": node.padding?.bottom = value
        case "trailing": node.padding?.trailing = value
        default: break
        }
        touchDraft()
    }

    func setPaddingUniform(_ value: Double, on node: PageLayoutNode) {
        node.padding = PageLayoutPadding(top: value, leading: value, bottom: value, trailing: value)
        touchDraft()
    }

    func setAlignment(_ value: String, on node: PageLayoutNode) {
        node.alignment = value
        touchDraft()
    }

    func setAxis(_ value: String, on node: PageLayoutNode) {
        node.axis = value
        touchDraft()
    }

    func setShowsIndicators(_ value: Bool, on node: PageLayoutNode) {
        node.showsIndicators = value
        touchDraft()
    }

    func setCompact(_ value: Bool, on node: PageLayoutNode) {
        node.compact = value
        touchDraft()
    }

    /// true → maxWidth = .infinity；false → maxWidth = nil（不约束）
    func setMaxWidthInfinity(_ value: Bool, on node: PageLayoutNode) {
        node.maxWidth = value ? .infinity : nil
        touchDraft()
    }

    func setMinHeight(_ value: Double, on node: PageLayoutNode) {
        node.minHeight = value
        touchDraft()
    }

    // MARK: - JSON 页签

    /// 由当前树生成规范化 JSON（与保存到沙盒的文本同口径）
    func generateJSONFromTree() {
        guard let file = file, let text = PageLayoutCodec.canonicalText(file) else { return }
        jsonText = text
        jsonError = nil
    }

    /// 把 JSON 原文应用到草稿：成功替换树并清选中 / 折叠；失败只记错误、草稿不变
    func applyJSONToTree() {
        switch PageLayoutCodec.decodeResult(jsonText) {
        case .success(let newFile):
            file = newFile
            jsonError = nil
            selectedUUID = nil
            collapsed = []
            banner = "已应用到树"
        case .failure(let error):
            jsonError = Self.readable(error)
        }
    }

    // MARK: - 私有

    /// 取草稿底本（不可用时先种回内置默认再取），并重置编辑态
    private func applyStoreFile() {
        var loaded = PageLayoutConfigStore.shared.currentFile(page: Self.page)
        if loaded == nil {
            PageLayoutConfigStore.shared.resetToBuiltIn(page: Self.page)
            loaded = PageLayoutConfigStore.shared.currentFile(page: Self.page)
        }
        file = loaded

        let text = loaded.flatMap { PageLayoutCodec.canonicalText($0) } ?? ""
        savedText = text
        jsonText = text
        jsonError = nil
        selectedUUID = nil
        collapsed = []
        banner = nil
    }

    /// 保证 `styleID` 在配置里有档位可编辑（回退 default → 第一个 key）
    private func ensureStyleAvailable() {
        guard let file = file else { return }
        guard file.layouts[styleID] == nil else { return }
        if let fallback = file.defaultLayoutID, file.layouts[fallback] != nil {
            styleID = fallback
        } else if let first = file.layouts.keys.sorted().first {
            styleID = first
        }
    }

    /// 新节点插入：选中容器 → 追加到末尾；选中非容器 → 插到父容器该节点之后；
    /// 未选中 → 追加到根容器末尾（根不是容器则拒绝）
    private func insert(_ node: PageLayoutNode) {
        guard let root = layoutRoot else {
            banner = "当前档位不可用，无法添加"
            return
        }

        guard let uuid = selectedUUID, let selected = root.firstNode(uuid: uuid) else {
            guard root.containerKey != nil else {
                banner = "根节点不是容器，无法添加"
                return
            }
            let replaced = (root.containerKey == .child && root.child != nil)
            root.appendChild(node)
            select(node)
            banner = replaced ? "该容器仅容纳一个子节点，已替换" : nil
            touchDraft()
            return
        }

        if selected.containerKey != nil {
            let replaced = (selected.containerKey == .child && selected.child != nil)
            selected.appendChild(node)
            select(node)
            banner = replaced ? "该容器仅容纳一个子节点，已替换" : nil
            touchDraft()
            return
        }

        guard let info = root.firstParent(of: selected.uuid) else {
            banner = "无法定位父容器"
            return
        }
        switch info.parent.containerKey {
        case .children:
            var children = info.parent.children ?? []
            let index = max(0, min(info.index + 1, children.count))
            children.insert(node, at: index)
            info.parent.children = children
            select(node)
            banner = nil
            touchDraft()
        case .child:
            let replaced = (info.parent.child != nil)
            info.parent.child = node
            select(node)
            banner = replaced ? "该容器仅容纳一个子节点，已替换" : nil
            touchDraft()
        case nil:
            banner = "无法定位父容器"
        }
    }

    private func ensureParams(_ node: PageLayoutNode) {
        if node.params == nil { node.params = WidgetParams() }
    }

    /// 把编解码错误转成可读文案（DecodingError 尽量给出上下文）
    private static func readable(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .dataCorrupted(let context):
            return "JSON 语法或取值错误：\(context.debugDescription)\(path(context.codingPath))"
        case .keyNotFound(let key, let context):
            return "缺少字段 \"\(key.stringValue)\"\(path(context.codingPath))"
        case .typeMismatch(let type, let context):
            return "字段类型不匹配（应为 \(type)）\(path(context.codingPath))"
        case .valueNotFound(let type, let context):
            return "字段缺值（应为 \(type)）\(path(context.codingPath))"
        @unknown default:
            return decoding.localizedDescription
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "" }
        return "（位置：\(codingPath.map { $0.stringValue }.joined(separator: "."))）"
    }
}
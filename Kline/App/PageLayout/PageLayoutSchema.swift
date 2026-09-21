//
//  PageLayoutSchema.swift
//  Kline
//
//  通用 JSON 布局引擎 - 数据模型（与具体页面无关）。
//  一份页面布局配置文件 PageLayoutFile 描述「页面某档位」的节点树；
//  节点树按 type 递归渲染，未知 type 直接解码失败（不静默忽略，便于发现配置写错）。
//
//  本模型同时承担「渲染输入」与「编辑器草稿」两种角色：
//  所有字段可变（编辑器要改），并携带一个**不参与编解码**的编辑期身份 `uuid`
//  （供 SwiftUI 列表身份与「当前选中节点」使用）；编码时只输出与 `type` 相关的字段，
//  保证落盘配置干净可读、且与解码侧缺省语义往返一致。
//

import Foundation
import SwiftUI

// MARK: - 配置文件

/// 一份页面布局配置文件
struct PageLayoutFile: Codable {
    var schemaVersion: Int
    var page: String
    /// 配置文件里 "default" 字段（Swift 关键字，用 CodingKeys 映射成 defaultLayoutID）
    var defaultLayoutID: String?
    /// 档位 id（"A"/"B"/"C"/"D"）→ 档位定义
    var layouts: [String: PageLayoutDefinition]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case page
        case defaultLayoutID = "default"
        case layouts
    }
}

/// 单个档位定义
struct PageLayoutDefinition: Codable {
    var title: String
    var shortTitle: String
    var root: PageLayoutNode
}

// MARK: - 节点树

/// 节点树的一个节点。
/// 用 `final class` 而非 `struct`：节点树是**递归**结构（`children` / `child` 又是节点），
/// 值类型无法表达自递归（编译报 "has infinite size"），引用类型天然可递归。
/// 全字段 `var`：既是渲染输入，也是编辑器可直接改的草稿；树操作按 `uuid` 定位节点。
final class PageLayoutNode: Codable, Identifiable {
    /// 编辑期身份：用于列表身份与选中态定位，**不参与编解码**
    let uuid: UUID

    var type: String
    var spacing: Double?
    var alignment: String?
    var axis: String?
    var padding: PageLayoutPadding?
    var showsIndicators: Bool?
    var maxWidth: PageLayoutWidth?
    var minHeight: Double?
    var title: String?
    var compact: Bool?
    /// widget 节点的控件名
    var name: String?
    var params: WidgetParams?
    var children: [PageLayoutNode]?
    var child: PageLayoutNode?

    /// Identifiable：以编辑期身份作为列表 id（解码后每次为新值，故不可用于跨解码比较）
    var id: UUID { uuid }

    /// 合法节点类型白名单（未知 type → 解码失败）
    static let allowedTypes: Set<String> = [
        "vstack", "hstack", "zstack", "scroll", "card", "frame", "widget", "divider", "spacer"
    ]

    private enum CodingKeys: String, CodingKey {
        case type, spacing, alignment, axis, padding, showsIndicators
        case maxWidth, minHeight, title, compact, name, params, children, child
    }

    // MARK: 初始化

    /// 完整指定初始化器（所有字段都有默认值）：供节点工厂 `make(type:)` 构造新节点
    init(type: String = "vstack",
         spacing: Double? = nil,
         alignment: String? = nil,
         axis: String? = nil,
         padding: PageLayoutPadding? = nil,
         showsIndicators: Bool? = nil,
         maxWidth: PageLayoutWidth? = nil,
         minHeight: Double? = nil,
         title: String? = nil,
         compact: Bool? = nil,
         name: String? = nil,
         params: WidgetParams? = nil,
         children: [PageLayoutNode]? = nil,
         child: PageLayoutNode? = nil) {
        self.uuid = UUID()
        self.type = type
        self.spacing = spacing
        self.alignment = alignment
        self.axis = axis
        self.padding = padding
        self.showsIndicators = showsIndicators
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.title = title
        self.compact = compact
        self.name = name
        self.params = params
        self.children = children
        self.child = child
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try c.decode(String.self, forKey: .type)
        guard Self.allowedTypes.contains(rawType) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "未知的布局节点 type：\"\(rawType)\""
            )
        }
        uuid = UUID()
        type = rawType
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing)
        alignment = try c.decodeIfPresent(String.self, forKey: .alignment)
        axis = try c.decodeIfPresent(String.self, forKey: .axis)
        padding = try c.decodeIfPresent(PageLayoutPadding.self, forKey: .padding)
        showsIndicators = try c.decodeIfPresent(Bool.self, forKey: .showsIndicators)
        maxWidth = try c.decodeIfPresent(PageLayoutWidth.self, forKey: .maxWidth)
        minHeight = try c.decodeIfPresent(Double.self, forKey: .minHeight)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        compact = try c.decodeIfPresent(Bool.self, forKey: .compact)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        params = try c.decodeIfPresent(WidgetParams.self, forKey: .params)
        children = try c.decodeIfPresent([PageLayoutNode].self, forKey: .children)
        child = try c.decodeIfPresent(PageLayoutNode.self, forKey: .child)
    }

    // MARK: 编码（只输出与 type 相关的字段）

    /// 只输出与 `type` 相关的字段（不相关字段一律不写，而不是写成 null），保持配置干净可读。
    /// 各字段均为「非 nil 才写」，与解码侧 `decodeIfPresent` 缺省语义往返一致。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)

        switch type {
        case "vstack", "hstack", "zstack":
            try c.encodeIfPresent(spacing, forKey: .spacing)
            try c.encodeIfPresent(alignment, forKey: .alignment)
            try c.encodeIfPresent(children, forKey: .children)

        case "scroll":
            try c.encodeIfPresent(axis, forKey: .axis)
            try c.encodeIfPresent(spacing, forKey: .spacing)
            try c.encodeIfPresent(padding, forKey: .padding)
            try c.encodeIfPresent(showsIndicators, forKey: .showsIndicators)
            try c.encodeIfPresent(children, forKey: .children)

        case "card":
            try c.encodeIfPresent(title, forKey: .title)
            try c.encodeIfPresent(compact, forKey: .compact)
            try c.encodeIfPresent(child, forKey: .child)

        case "frame":
            try c.encodeIfPresent(maxWidth, forKey: .maxWidth)
            try c.encodeIfPresent(minHeight, forKey: .minHeight)
            try c.encodeIfPresent(alignment, forKey: .alignment)
            try c.encodeIfPresent(child, forKey: .child)

        case "widget":
            try c.encodeIfPresent(name, forKey: .name)
            // 空参数表省略（不写 "params"）：取值方法对「params 缺失（nil）」与「params 为空表」
            // 行为完全一致（渲染侧 `node.params ?? WidgetParams()` 已把 nil 归一为空表），
            // 故省略空表语义等价，且让配置更干净。
            if let params = params, !params.isEmpty {
                try c.encode(params, forKey: .params)
            }

        default:
            // divider / spacer：无字段，只写 type
            break
        }
    }

    // MARK: - 节点工厂

    /// 按类型构造一个带合理默认值的新节点；白名单外的 type 返回 nil
    static func make(type: String) -> PageLayoutNode? {
        guard allowedTypes.contains(type) else { return nil }
        switch type {
        case "vstack":
            return PageLayoutNode(type: "vstack", spacing: 8, children: [])
        case "hstack":
            return PageLayoutNode(type: "hstack", spacing: 8, alignment: "center", children: [])
        case "zstack":
            return PageLayoutNode(type: "zstack", children: [])
        case "scroll":
            return PageLayoutNode(type: "scroll",
                                  spacing: 8,
                                  axis: "vertical",
                                  padding: PageLayoutPadding(top: 16, leading: 16, bottom: 16, trailing: 16),
                                  showsIndicators: true,
                                  children: [])
        case "card":
            return PageLayoutNode(type: "card", title: "新卡片", compact: false, child: nil)
        case "frame":
            return PageLayoutNode(type: "frame", alignment: "top", maxWidth: .infinity, child: nil)
        case "widget":
            return PageLayoutNode(type: "widget", name: "", params: WidgetParams())
        case "divider":
            return PageLayoutNode(type: "divider")
        case "spacer":
            return PageLayoutNode(type: "spacer")
        default:
            return nil
        }
    }
}

// MARK: - 节点树操作

extension PageLayoutNode {

    /// 容器持有子节点的两种方式
    enum ContainerKey {
        case children
        case child
    }

    /// 本节点是否为容器及其持有子节点的方式；
    /// 非容器（widget / divider / spacer）返回 nil
    var containerKey: ContainerKey? {
        switch type {
        case "vstack", "hstack", "zstack", "scroll": return .children
        case "card", "frame": return .child
        default: return nil
        }
    }

    /// 本节点的全部子节点（统一视图，非容器为空）
    var childList: [PageLayoutNode] {
        switch containerKey {
        case .children: return children ?? []
        case .child: return child.map { [$0] } ?? []
        case nil: return []
        }
    }

    /// 追加一个子节点；仅容器生效。
    /// - `.children`：追加到 `children` 末尾（nil 时先置空数组）
    /// - `.child`：直接赋给 `child`（**已有 child 时会被替换**，仍返回 true，
    ///   由调用方决定是否提示「已有子节点，已替换」）
    /// - 非容器：返回 false 且不改动
    @discardableResult
    func appendChild(_ node: PageLayoutNode) -> Bool {
        switch containerKey {
        case .children:
            if children == nil { children = [] }
            children?.append(node)
            return true
        case .child:
            child = node
            return true
        case nil:
            return false
        }
    }

    /// 按 uuid 移除子节点；仅容器生效。
    /// - `.children`：在 `children` 里按 uuid 移除（含整棵子树）
    /// - `.child`：uuid 匹配则置 nil
    /// - 非容器 / 未匹配：返回 false 且不改动
    @discardableResult
    func removeChild(uuid: UUID) -> Bool {
        switch containerKey {
        case .children:
            guard let list = children,
                  let index = list.firstIndex(where: { $0.uuid == uuid }) else { return false }
            children?.remove(at: index)
            return true
        case .child:
            if let onlyChild = child, onlyChild.uuid == uuid {
                child = nil
                return true
            }
            return false
        case nil:
            return false
        }
    }

    /// 深度优先扁平化（含自身，depth 从 0 起）；编辑器树列表用
    func flattened() -> [(node: PageLayoutNode, depth: Int)] {
        var result: [(node: PageLayoutNode, depth: Int)] = [(self, 0)]
        for node in childList {
            for item in node.flattened() {
                result.append((item.node, item.depth + 1))
            }
        }
        return result
    }

    /// 在本子树内按 uuid 递归查找节点（含自身）
    func firstNode(uuid: UUID) -> PageLayoutNode? {
        if self.uuid == uuid { return self }
        for node in childList {
            if let found = node.firstNode(uuid: uuid) { return found }
        }
        return nil
    }

    /// 在本子树内递归查找 uuid 对应节点的父节点与序号（`.children` 为下标，`.child` 固定为 0）
    func firstParent(of uuid: UUID) -> (parent: PageLayoutNode, index: Int)? {
        if let children = children {
            for (index, node) in children.enumerated() {
                if node.uuid == uuid { return (self, index) }
                if let found = node.firstParent(of: uuid) { return found }
            }
        }
        if let onlyChild = child {
            if onlyChild.uuid == uuid { return (self, 0) }
            if let found = onlyChild.firstParent(of: uuid) { return found }
        }
        return nil
    }
}

/// maxWidth 取值：字符串 "infinity" 或数字
enum PageLayoutWidth: Codable, Equatable {
    case infinity
    case points(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self), text == "infinity" {
            self = .infinity
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .points(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "maxWidth 必须是 \"infinity\" 或数字"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .infinity: try container.encode("infinity")
        case .points(let value): try container.encode(value)
        }
    }
}

/// 四边内边距（缺省 0）
struct PageLayoutPadding: Codable {
    var top: Double
    var leading: Double
    var bottom: Double
    var trailing: Double

    /// 全 0 内边距
    static let zero = PageLayoutPadding()

    private enum CodingKeys: String, CodingKey {
        case top, leading, bottom, trailing
    }

    init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        top = try c.decodeIfPresent(Double.self, forKey: .top) ?? 0
        leading = try c.decodeIfPresent(Double.self, forKey: .leading) ?? 0
        bottom = try c.decodeIfPresent(Double.self, forKey: .bottom) ?? 0
        trailing = try c.decodeIfPresent(Double.self, forKey: .trailing) ?? 0
    }

    /// 只输出非 0 的边（解码侧缺省即 0，往返一致）
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if top != 0 { try c.encode(top, forKey: .top) }
        if leading != 0 { try c.encode(leading, forKey: .leading) }
        if bottom != 0 { try c.encode(bottom, forKey: .bottom) }
        if trailing != 0 { try c.encode(trailing, forKey: .trailing) }
    }

    var edgeInsets: EdgeInsets {
        EdgeInsets(top: CGFloat(top), leading: CGFloat(leading),
                   bottom: CGFloat(bottom), trailing: CGFloat(trailing))
    }
}

// MARK: - 控件参数

/// 控件参数（四型标量 + 带默认值取值方法）
struct WidgetParams: Codable, Equatable {
    /// 参数键值表（internal var：编辑器需要直接写参数）
    var values: [String: WidgetParamValue]

    /// 空参数（未注册 / 未配置 params 时使用）
    init() {
        values = [:]
    }

    init(_ values: [String: WidgetParamValue]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        values = (try? container.decode([String: WidgetParamValue].self)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    /// 是否为空参数表（编码时空表省略，语义等价于「未写 params」）
    var isEmpty: Bool { values.isEmpty }

    /// 取 bool；只接受 .bool（.int 的 0/1 也视为 false/true），缺 key 或类型不符返回默认值
    func bool(_ key: String, default value: Bool) -> Bool {
        guard let v = values[key] else { return value }
        switch v {
        case .bool(let b): return b
        case .int(let i): return i != 0
        default: return value
        }
    }

    /// 取 int；接受 .int 与 .double（取整），缺 key 或类型不符返回默认值
    func int(_ key: String, default value: Int) -> Int {
        guard let v = values[key] else { return value }
        switch v {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return value
        }
    }

    /// 取 double；接受 .double 与 .int，缺 key 或类型不符返回默认值
    func double(_ key: String, default value: Double) -> Double {
        guard let v = values[key] else { return value }
        switch v {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return value
        }
    }

    /// 取 string；只接受 .string，缺 key 或类型不符返回默认值
    func string(_ key: String, default value: String) -> String {
        guard let v = values[key] else { return value }
        switch v {
        case .string(let s): return s
        default: return value
        }
    }
}

/// 控件参数值（四型标量）。
/// 解码顺序固定为 **Int → Double → Bool → String**：Darwin 的 `JSONDecoder` 以 `NSNumber` 兜底，
/// 若先试 `Bool` 会把数字 `0/1` 读成布尔（`"limit": 1` 就取不到值），故数字优先。
/// `Int` 对 `2.5` 会抛「does not fit in Int」而落到 `Double`，对 `true/false` 会抛而落到 `Bool`；
/// 布尔值经 `WidgetParams.bool(_:default:)` 亦可从 `.int(0/1)` 读回，语义不丢。
enum WidgetParamValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) { self = .int(i); return }
        if let d = try? container.decode(Double.self) { self = .double(d); return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "不支持的控件参数类型（仅支持 bool / int / double / string）"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        }
    }
}
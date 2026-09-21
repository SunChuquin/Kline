//
//  PageLayoutSchema.swift
//  Kline
//
//  通用 JSON 布局引擎 - 数据模型（与具体页面无关）。
//  一份页面布局配置文件 PageLayoutFile 描述「页面某档位」的节点树；
//  节点树按 type 递归渲染，未知 type 直接解码失败（不静默忽略，便于发现配置写错）。
//

import Foundation
import SwiftUI

// MARK: - 配置文件

/// 一份页面布局配置文件
struct PageLayoutFile: Decodable {
    let schemaVersion: Int
    let page: String
    /// 配置文件里 "default" 字段（Swift 关键字，用 CodingKeys 映射成 defaultLayoutID）
    let defaultLayoutID: String?
    /// 档位 id（"A"/"B"/"C"/"D"）→ 档位定义
    let layouts: [String: PageLayoutDefinition]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case page
        case defaultLayoutID = "default"
        case layouts
    }
}

/// 单个档位定义
struct PageLayoutDefinition: Decodable {
    let title: String
    let shortTitle: String
    let root: PageLayoutNode
}

// MARK: - 节点树

/// 节点树的一个节点
struct PageLayoutNode: Decodable {
    let type: String
    let spacing: Double?
    let alignment: String?
    let axis: String?
    let padding: PageLayoutPadding?
    let showsIndicators: Bool?
    let maxWidth: PageLayoutWidth?
    let minHeight: Double?
    let title: String?
    let compact: Bool?
    /// widget 节点的控件名
    let name: String?
    let params: WidgetParams?
    let children: [PageLayoutNode]?
    let child: PageLayoutNode?

    /// 合法节点类型白名单（未知 type → 解码失败）
    private static let allowedTypes: Set<String> = [
        "vstack", "hstack", "zstack", "scroll", "card", "frame", "widget", "divider", "spacer"
    ]

    private enum CodingKeys: String, CodingKey {
        case type, spacing, alignment, axis, padding, showsIndicators
        case maxWidth, minHeight, title, compact, name, params, children, child
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
}

/// maxWidth 取值：字符串 "infinity" 或数字
enum PageLayoutWidth: Decodable {
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
}

/// 四边内边距（缺省 0）
struct PageLayoutPadding: Decodable {
    let top: Double
    let leading: Double
    let bottom: Double
    let trailing: Double

    private enum CodingKeys: String, CodingKey {
        case top, leading, bottom, trailing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        top = try c.decodeIfPresent(Double.self, forKey: .top) ?? 0
        leading = try c.decodeIfPresent(Double.self, forKey: .leading) ?? 0
        bottom = try c.decodeIfPresent(Double.self, forKey: .bottom) ?? 0
        trailing = try c.decodeIfPresent(Double.self, forKey: .trailing) ?? 0
    }

    var edgeInsets: EdgeInsets {
        EdgeInsets(top: CGFloat(top), leading: CGFloat(leading),
                   bottom: CGFloat(bottom), trailing: CGFloat(trailing))
    }
}

// MARK: - 控件参数

/// 控件参数（四型标量 + 带默认值取值方法）
struct WidgetParams: Decodable {
    private let values: [String: WidgetParamValue]

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

enum WidgetParamValue: Decodable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let i = try? container.decode(Int.self) { self = .int(i); return }
        if let d = try? container.decode(Double.self) { self = .double(d); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "不支持的控件参数类型（仅支持 bool / int / double / string）"
        )
    }
}
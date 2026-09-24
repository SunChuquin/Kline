//
//  HomeWidgetEditorSchema.swift
//  Kline
//
//  首页控件「可编辑参数」描述表：给布局编辑器提供数据源。
//  与 HomeWidgetRegistry 注册的 7 个控件一一对应，声明每个控件的显示名与可编辑参数
//  （键、标题、类型、默认值、取值范围 / 可选项）。
//  参数键必须与 JSON 里的键、控件读取时用的键完全一致，否则表单改不到实处。
//  本文件只描述数据，不依赖 SwiftUI。
//

import Foundation

/// 单个参数的可编辑描述
struct WidgetParamDescriptor {
    /// 参数键（与 JSON 里的键、控件读取时用的键完全一致）
    let key: String
    /// 表单里的显示名（中文）
    let title: String
    let kind: Kind

    enum Kind {
        /// 开关：JSON 里是 bool
        case toggle(default: Bool)
        /// 整数步进：JSON 里是数字
        case stepper(default: Int, range: ClosedRange<Int>, note: String?)
        /// 单选（静态选项）：JSON 里是字符串
        case options([String], default: String)
        /// 有序多选：JSON 里是 [String]（候选 id 的有序数组）；maxCount 非 nil 时限制选择数量
        case orderedList(source: WidgetParamCandidates, maxCount: Int?, note: String?)
        /// 单选（动态候选，候选运行时从数据层解析）：JSON 里是字符串；缺省（不写键）= 默认项
        case dynamicOptions(source: WidgetParamCandidates, note: String?)
    }
}

/// 有序多选 / 动态单选参数的一个候选项（只含基础类型，不引 SwiftUI）
struct ParamCandidate: Identifiable, Equatable {
    /// 持久化 id（写入 JSON：入口 rawValue / metaID 字符串 / 分组或账户 UUID 字符串）
    let id: String
    let title: String
    /// 副标题（如入口说明、指数代码）
    let subtitle: String?
    /// SF Symbol 名（nil = 不显示图标）
    let iconName: String?

    init(id: String, title: String, subtitle: String? = nil, iconName: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
    }
}

/// 动态候选来源（运行时由 WidgetParamCandidateProvider 解析）
enum WidgetParamCandidates: Equatable {
    /// 首页快捷入口（HomeEntryKind 全量）
    case entries
    /// 沪深京指数（DatabaseManager.metaList）
    case indices
    /// 自选分组（含「全部」虚拟分组）
    case favoritesGroups
    /// 模拟账户（含「全部账户」）
    case simAccounts
}

/// 一个控件的可编辑描述（与 HomeWidgetRegistry 注册的控件一一对应）
struct WidgetDescriptor {
    /// 控件名（JSON 里的 widget.name）
    let name: String
    /// 表单里的显示名（中文）
    let title: String
    let params: [WidgetParamDescriptor]
}

enum HomeWidgetEditorSchema {
    /// 全部控件（顺序与 HomeWidgetRegistry 的注册顺序一致）
    static let all: [WidgetDescriptor] = [
        // home.header：无参数
        WidgetDescriptor(name: "home.header",
                         title: "标题栏",
                         params: []),

        // home.quickEntryRow：entries（入口项有序集合；缺省 = 全部入口）
        WidgetDescriptor(name: "home.quickEntryRow",
                         title: "快捷入口行",
                         params: [
                            WidgetParamDescriptor(key: "entries",
                                                  title: "入口项",
                                                  kind: .orderedList(source: .entries,
                                                                     maxCount: nil,
                                                                     note: "缺省 = 全部入口，可清空"))
                         ]),

        // home.placeholder：无参数
        WidgetDescriptor(name: "home.placeholder",
                         title: "占位块",
                         params: []),

        // home.marketOverview：indices（沪深京指数，上限 4）/ compact
        WidgetDescriptor(name: "home.marketOverview",
                         title: "大盘概览",
                         params: [
                            WidgetParamDescriptor(key: "indices",
                                                  title: "展示指数",
                                                  kind: .orderedList(source: .indices,
                                                                     maxCount: 4,
                                                                     note: "缺省 = 默认前 4 只，最多选 4 只")),
                            WidgetParamDescriptor(key: "compact",
                                                  title: "紧凑",
                                                  kind: .toggle(default: false))
                         ]),

        // home.favorites：group（自选分组）/ compact / showsSparkline / limit
        WidgetDescriptor(name: "home.favorites",
                         title: "我的自选",
                         params: [
                            WidgetParamDescriptor(key: "group",
                                                  title: "自选分组",
                                                  kind: .dynamicOptions(source: .favoritesGroups,
                                                                        note: "缺省 = 全部分组")),
                            WidgetParamDescriptor(key: "compact",
                                                  title: "紧凑",
                                                  kind: .toggle(default: false)),
                            WidgetParamDescriptor(key: "showsSparkline",
                                                  title: "显示迷你走势",
                                                  kind: .toggle(default: false)),
                            WidgetParamDescriptor(key: "limit",
                                                  title: "显示条数",
                                                  kind: .stepper(default: 0,
                                                                 range: 0...20,
                                                                 note: "0 = 默认前 5"))
                         ]),

        // home.simSummary：account（模拟账户）/ compact
        WidgetDescriptor(name: "home.simSummary",
                         title: "模拟账户汇总",
                         params: [
                            WidgetParamDescriptor(key: "account",
                                                  title: "统计账户",
                                                  kind: .dynamicOptions(source: .simAccounts,
                                                                        note: "缺省 = 全部账户汇总")),
                            WidgetParamDescriptor(key: "compact",
                                                  title: "紧凑",
                                                  kind: .toggle(default: false))
                         ]),

        // home.topGainers：board（市场板块）/ style / compact
        WidgetDescriptor(name: "home.topGainers",
                         title: "涨幅榜",
                         params: [
                            WidgetParamDescriptor(key: "board",
                                                  title: "市场板块",
                                                  kind: .options(["mainBoard", "etfIndex"], default: "mainBoard")),
                            WidgetParamDescriptor(key: "style",
                                                  title: "呈现方式",
                                                  kind: .options(["list", "chips"], default: "list")),
                            WidgetParamDescriptor(key: "compact",
                                                  title: "紧凑",
                                                  kind: .toggle(default: false))
                         ])
    ]

    /// 按控件名取描述；未登记返回 nil
    static func descriptor(for name: String) -> WidgetDescriptor? {
        all.first { $0.name == name }
    }

    /// 9 种布局节点类型的中文显示名（供树列表与「添加节点」菜单用）
    static let nodeTypeTitles: [String: String] = [
        "vstack": "垂直堆栈",
        "hstack": "水平堆栈",
        "zstack": "叠放容器",
        "scroll": "滚动区",
        "card": "卡片",
        "frame": "尺寸框",
        "widget": "控件",
        "divider": "分隔线",
        "spacer": "弹性空白"
    ]
}
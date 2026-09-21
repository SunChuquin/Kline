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
        /// 单选：JSON 里是字符串
        case options([String], default: String)
    }
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

        // home.quickEntryRow：无参数
        WidgetDescriptor(name: "home.quickEntryRow",
                         title: "快捷入口行",
                         params: []),

        // home.placeholder：无参数
        WidgetDescriptor(name: "home.placeholder",
                         title: "占位块",
                         params: []),

        // home.marketOverview：compact
        WidgetDescriptor(name: "home.marketOverview",
                         title: "大盘概览",
                         params: [
                            WidgetParamDescriptor(key: "compact",
                                                  title: "紧凑",
                                                  kind: .toggle(default: false))
                         ]),

        // home.favorites：compact / showsSparkline / limit
        WidgetDescriptor(name: "home.favorites",
                         title: "我的自选",
                         params: [
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
                                                                 note: "0 = 全部"))
                         ]),

        // home.simSummary：compact
        WidgetDescriptor(name: "home.simSummary",
                         title: "模拟账户汇总",
                         params: [
                            WidgetParamDescriptor(key: "compact",
                                                  title: "紧凑",
                                                  kind: .toggle(default: false))
                         ]),

        // home.topGainers：style / compact
        WidgetDescriptor(name: "home.topGainers",
                         title: "涨幅榜",
                         params: [
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
//
//  SimWidgetEditorSchema.swift
//  Kline
//
//  模拟页控件「可编辑参数」描述表：给布局编辑器提供数据源。
//  与 SimWidgetRegistry 注册的控件一一对应，声明每个控件的显示名与可编辑参数
//  （键、标题、类型、默认值、取值范围 / 可选项）。
//  末尾另并入页面无关的通用控件描述（CommonLayoutWidgetSchema）。
//  参数键必须与 JSON 里的键、控件读取时用的键完全一致，否则表单改不到实处。
//  本文件只描述数据，不依赖 SwiftUI。
//

import Foundation

enum SimWidgetEditorSchema {
    /// 全部控件（顺序与 SimWidgetRegistry 的注册顺序一致，末尾为页面无关的通用控件；
    /// 该顺序即「添加控件」菜单的展示顺序）
    static let all: [WidgetDescriptor] = [
        WidgetDescriptor(name: SimWidgetName.title,
                         title: "标题文字",
                         params: [
                            WidgetParamDescriptor(key: "text",
                                                  title: "标题文字",
                                                  kind: .text(placeholder: "如：模拟交易（缺省「模拟交易」）",
                                                              note: nil))
                         ]),

        WidgetDescriptor(name: SimWidgetName.topBar,
                         title: "顶部条",
                         params: [
                            WidgetParamDescriptor(key: "title",
                                                  title: "标题",
                                                  kind: .text(placeholder: "如：模拟交易（缺省「模拟交易」）",
                                                              note: nil)),
                            WidgetParamDescriptor(key: "hint",
                                                  title: "提示文案",
                                                  kind: .text(placeholder: "如：点模块卡进入明细（留空不显示）",
                                                              note: "紧凑宽拆两行时显示在标题右侧")),
                            WidgetParamDescriptor(key: "chip",
                                                  title: "显示账户下拉",
                                                  kind: .toggle(default: false)),
                            WidgetParamDescriptor(key: "entries",
                                                  title: "功能入口",
                                                  kind: .orderedList(source: .simTopBarEntries,
                                                                     maxCount: nil,
                                                                     note: "缺省 = 全部入口，可清空"))
                         ]),

        WidgetDescriptor(name: SimWidgetName.assetMetrics,
                         title: "资产指标行（七项）",
                         params: []),

        WidgetDescriptor(name: SimWidgetName.summaryBand,
                         title: "资产总览带（六项 + 净值线）",
                         params: []),

        WidgetDescriptor(name: SimWidgetName.moduleToolbar,
                         title: "模块工具栏",
                         params: [
                            WidgetParamDescriptor(key: "sidebarOffset",
                                                  title: "左侧侧栏宽",
                                                  kind: .stepper(default: 0,
                                                                 range: 0...400,
                                                                 note: "本行左侧被固定侧栏占用的宽；A 方案填 216")),
                            WidgetParamDescriptor(key: "logActions",
                                                  title: "日志工具栏",
                                                  kind: .toggle(default: false)),
                            WidgetParamDescriptor(key: "showsSearch",
                                                  title: "显示搜索框",
                                                  kind: .toggle(default: true))
                         ]),

        WidgetDescriptor(name: SimWidgetName.logFilterBar,
                         title: "日志模块筛选条",
                         params: []),

        WidgetDescriptor(name: SimWidgetName.moduleTable,
                         title: "业务表（五模块）",
                         params: [
                            WidgetParamDescriptor(key: "sidebarOffset",
                                                  title: "左侧侧栏宽",
                                                  kind: .stepper(default: 0,
                                                                 range: 0...400,
                                                                 note: "A 方案填 216；行宽不足时整表包横向滚动"))
                         ]),

        WidgetDescriptor(name: SimWidgetName.bottomActionBar,
                         title: "底部买卖条",
                         params: [
                            WidgetParamDescriptor(key: "hint",
                                                  title: "左侧提示文案",
                                                  kind: .text(placeholder: "留空 = T+1 / 佣金 / 印花税说明",
                                                              note: "紧凑宽自动隐藏"))
                         ]),

        WidgetDescriptor(name: SimWidgetName.accountSidebar,
                         title: "账户侧栏（紧凑收纳抽屉）",
                         params: []),

        WidgetDescriptor(name: SimWidgetName.accountCards,
                         title: "账户卡片行",
                         params: [
                            WidgetParamDescriptor(key: "showsNewCard",
                                                  title: "显示新建卡",
                                                  kind: .toggle(default: true))
                         ]),

        WidgetDescriptor(name: SimWidgetName.moduleGrid,
                         title: "模块宫格",
                         params: [
                            WidgetParamDescriptor(key: "summaryRows",
                                                  title: "摘要行数",
                                                  kind: .stepper(default: 3,
                                                                 range: 1...10,
                                                                 note: "卡内摘要条数"))
                         ]),

        WidgetDescriptor(name: SimWidgetName.pendingCard,
                         title: "在途委托卡",
                         params: [
                            WidgetParamDescriptor(key: "maxRows",
                                                  title: "最大行数",
                                                  kind: .stepper(default: 2,
                                                                 range: 1...10,
                                                                 note: "卡内摘要条数"))
                         ]),

        WidgetDescriptor(name: SimWidgetName.fillsCard,
                         title: "当日成交卡",
                         params: [
                            WidgetParamDescriptor(key: "maxRows",
                                                  title: "最大行数",
                                                  kind: .stepper(default: 3,
                                                                 range: 1...10,
                                                                 note: "卡内摘要条数"))
                         ])
    ]
        // 页面无关的通用控件（横滑卡片 / 列表卡片），由 CommonLayoutWidgets.swift 提供
        + CommonLayoutWidgetSchema.all

    /// 按控件名取描述；未登记返回 nil
    static func descriptor(for name: String) -> WidgetDescriptor? {
        all.first { $0.name == name }
    }
}

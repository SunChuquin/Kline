//
//  WidgetEditorSchemaPage.swift
//  Kline
//
//  布局编辑器「按页面取控件描述」的统一入口：
//  首页 → HomeWidgetEditorSchema（home.* + common.*），
//  模拟 → SimWidgetEditorSchema（sim.* + common.*）。
//  树列表 / 检查器 / 「添加控件」菜单据此渲染；九种通用容器节点的中文名
//  与页面无关，直接沿用 HomeWidgetEditorSchema.nodeTypeTitles。
//

import Foundation

enum PageWidgetEditorSchema {
    /// 某页面全部控件描述（common.* 通用控件已并入各页面描述表末尾）
    static func all(for page: PageLayoutEditorModel.EditorPage) -> [WidgetDescriptor] {
        switch page {
        case .home: return HomeWidgetEditorSchema.all
        case .simulation: return SimWidgetEditorSchema.all
        }
    }

    /// 按控件名取某页面的描述；未登记返回 nil
    static func descriptor(for name: String,
                           page: PageLayoutEditorModel.EditorPage) -> WidgetDescriptor? {
        all(for: page).first { $0.name == name }
    }

    /// 九种布局节点类型的中文显示名（供树列表与「添加节点」菜单用；与页面无关）
    static let nodeTypeTitles = HomeWidgetEditorSchema.nodeTypeTitles
}

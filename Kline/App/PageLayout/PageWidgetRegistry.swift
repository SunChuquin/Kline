//
//  PageWidgetRegistry.swift
//  Kline
//
//  通用 JSON 布局引擎 - 控件注册表（与具体页面无关）。
//  把「控件名」映射到「(Context, WidgetParams) -> AnyView」的视图构建器；
//  各页面模块自行注册自己的控件，引擎本身不认识任何具体控件。
//

import Foundation
import SwiftUI

/// 控件名 → 视图构建器 的注册表（与具体页面无关）
struct PageWidgetRegistry<Context> {
    typealias Builder = (Context, WidgetParams) -> AnyView

    private var builders: [String: Builder] = [:]

    init() {}

    /// 注册控件名对应的构建器（同名覆盖）
    mutating func register(_ name: String, builder: @escaping Builder) {
        builders[name] = builder
    }

    /// 取控件名对应的构建器；未注册返回 nil
    func builder(for name: String) -> Builder? {
        builders[name]
    }
}
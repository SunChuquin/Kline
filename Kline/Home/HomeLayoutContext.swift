//
//  HomeLayoutContext.swift
//  Kline
//
//  首页配置驱动渲染的上下文：数据模型 + 容器注入的闭包。
//  控件只接收数据与闭包，不持状态、不发命令、不直接跳转；
//  状态与跳转（搜索 / 公式分段 / 条件单 / 个人中心 / 切 Tab）统一由容器 HomeView 注入。
//

import Foundation

/// 首页配置驱动渲染的上下文：数据模型 + 容器注入的闭包（控件不持状态、不发命令）
struct HomeLayoutContext {
    let model: HomePageModel
    /// 打开个人中心
    let onProfile: () -> Void
    /// 快捷入口动作（搜索 / 三个公式分段 / 条件单 / 个人中心），与各档现有 perform(_:) 逐项一致
    let onEntry: (HomeEntryKind) -> Void
    /// 切底部 Tab（自选 1 / 行情 2 / 模拟 3）
    let onSelectTab: (Int) -> Void
}
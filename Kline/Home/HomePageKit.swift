//
//  HomePageKit.swift
//  Kline
//
//  首页共享骨架：本文件只保留入口清单与浮层（HomeEntryKind / HomeOverlayTarget / HomeOverlays /
//  homeOverlays(...)）；标题栏、横滑入口行、快捷入口卡片、搜索模式视图等控件已拆到 Widgets/ 下。
//  设计要点：
//  - 入口文案 / 图标 / 语义色统一由 HomeEntryKind 提供，三档共用同一份清单，各档只做组合；
//  - 入口与底部导航栏重复的三项（自选 / 行情 / 模拟）已按用户反馈剔除，只留首页独有的入口；
//  - 入口控件只接收闭包（onTap / onProfile），不持任何状态、不发命令，
//    状态与跳转（搜索 / 公式分段 / 条件单 / 个人中心）统一由容器 HomeView 注入；
//  - 颜色全部走语义色（Color(.systemBackground) / Color(.secondarySystemBackground) / .primary / .secondary），
//    深色模式自动适配；可点击元素命中区均 ≥ 44pt，且高度固定（点击与切档不抖动）。
//

import SwiftUI

// MARK: - 入口清单（三档共用同一份数据）

/// 首页入口类型：名称 / 说明 / 图标 / 语义色 / 公式分段。
/// 只收首页独有入口（自选 / 行情 / 模拟与底部导航栏重复，已剔除）。
enum HomeEntryKind: String, CaseIterable, Identifiable {
    case search
    case tech
    case picker
    case strategy
    case condOrder
    case profile
    /// 触发记录（条件单触发历史，AlertRecordView）
    case alertRecords
    /// 布局编辑器（PageLayoutEditorView）
    case layoutEditor

    var id: String { rawValue }

    /// 入口名称
    var title: String {
        switch self {
        case .search: return "搜索标的"
        case .tech: return "技术指标"
        case .picker: return "选股指标"
        case .strategy: return "交易策略"
        case .condOrder: return "条件单"
        case .profile: return "个人中心"
        case .alertRecords: return "触发记录"
        case .layoutEditor: return "布局编辑"
        }
    }

    /// 入口说明（横滑 chip 的副标题）
    var subtitle: String {
        switch self {
        case .search: return "按名称 / 代码检索"
        case .tech: return "主图叠加与副图指标"
        case .picker: return "全市场跑选股"
        case .strategy: return "策略与历史回测"
        case .condOrder: return "监控与触发下单"
        case .profile: return "主题与页面布局"
        case .alertRecords: return "条件单触发历史"
        case .layoutEditor: return "自定义四档页面布局"
        }
    }

    /// SF Symbol 图标名
    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .tech: return "function"
        case .picker: return "line.3.horizontal.decrease.circle"
        case .strategy: return "chart.xyaxis.line"
        case .condOrder: return "bell.badge"
        case .profile: return "person.circle"
        case .alertRecords: return "clock.arrow.circlepath"
        case .layoutEditor: return "square.grid.3x3"
        }
    }

    /// 语义色（自适应深浅色，不写死具体色值）
    var tint: Color {
        switch self {
        case .search: return .blue
        case .tech: return .purple
        case .picker: return .orange
        case .strategy: return .teal
        case .condOrder: return .red
        case .profile: return .blue
        case .alertRecords: return .pink
        case .layoutEditor: return .indigo
        }
    }

    /// 公式类入口对应的公式管理中心分段（非公式入口为 nil）
    var formulaKind: FormulaKind? {
        switch self {
        case .tech: return .tech
        case .picker: return .picker
        case .strategy: return .strategy
        case .search, .condOrder, .profile, .alertRecords, .layoutEditor: return nil
        }
    }
}

// MARK: - 浮层（单一呈现目标，三档共用）

/// 首页浮层的单一呈现目标：公式管理中心（按分段）/ 条件单管理页。
/// 用单一 target 枚举而非多个 Bool：类型上保证同时只呈现一个，切换时自然替换。
/// 注：布局编辑器不在其中——它要盖住底部导航栏，由 `ContentView` 根层用
/// `HomeLayoutEditorRouter` 呈现（见 PageLayoutEditorView.swift）。
enum HomeOverlayTarget: Identifiable, Equatable {
    case formula(FormulaKind)
    case condOrder
    case alertRecords

    var id: String {
        switch self {
        case .formula(let kind): return "formula.\(kind.rawValue)"
        case .condOrder: return "condOrder"
        case .alertRecords: return "alertRecords"
        }
    }
}

/// 首页浮层容器：公式管理中心 / 条件单管理页都是全屏页面（铺满，无遮罩），关闭走页内「返回」。
/// 与个人中心同做法：挂在页面根视图上，避免被列表 ScrollView 裁剪。
struct HomeOverlays: ViewModifier {
    @Binding var target: HomeOverlayTarget?

    func body(content: Content) -> some View {
        content
            .overlay {
                if let t = target {
                    ZStack {
                        switch t {
                        case .formula(let kind):
                            // `.id`：切分段（技术 / 选股 / 策略）时重建页面，让初始分段真正生效
                            FormulaCenterView(initialKind: kind, onClose: { target = nil })
                                .id(t.id)
                        case .condOrder:
                            SimCondListView(accountID: nil, onClose: { target = nil })
                        case .alertRecords:
                            AlertRecordView(onClose: { target = nil })
                        }
                    }
                    .transition(.opacity)
                    .zIndex(1000)
                }
            }
    }
}

extension View {
    /// 挂载首页浮层（公式管理中心 / 条件单管理页；三档共用）
    func homeOverlays(target: Binding<HomeOverlayTarget?>) -> some View {
        modifier(HomeOverlays(target: target))
    }
}
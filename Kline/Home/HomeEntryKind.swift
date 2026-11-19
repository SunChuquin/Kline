//
//  HomeEntryKind.swift
//  Kline
//
//  首页入口类型与浮层目标（P2-7 从 HomePageKit.swift 拆出；HomeBridge 活引用，
//  原生首页四档布局随 JSON 布局系统退役，入口清单与浮层路由语义保留）。
//

import SwiftUI

enum HomeEntryKind: String, CaseIterable, Identifiable {
    case search
    case tech
    case picker
    case strategy
    case condOrder
    case profile
    /// 触发记录（条件单触发历史，AlertRecordView）
    case alertRecords
    /// 单人训练（TrainingSetupSheet）
    case training
    /// 布局编辑器（PageLayoutEditorView）
    case layoutEditor
    /// 联机同步（局域网设备间同步，LANSyncView）
    case lanSync
    /// Python 引擎实验室（PythonEngineLabView，调试页）
    case pythonLab

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
        case .training: return "单人训练"
        case .layoutEditor: return "布局编辑"
        case .lanSync: return "联机同步"
        case .pythonLab: return "引擎实验室"
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
        case .training: return "逐根复盘历史行情"
        case .layoutEditor: return "自定义四档页面布局"
        case .lanSync: return "局域网设备间同步"
        case .pythonLab: return "Python 引擎下载与调试"
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
        case .training: return "graduationcap"
        case .layoutEditor: return "square.grid.3x3"
        case .lanSync: return "arrow.triangle.2.circlepath.circle"
        case .pythonLab: return "terminal"
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
        case .training: return .green
        case .layoutEditor: return .indigo
        case .lanSync: return .cyan
        case .pythonLab: return .mint
        }
    }

    /// 公式类入口对应的公式管理中心分段（非公式入口为 nil）
    var formulaKind: FormulaKind? {
        switch self {
        case .tech: return .tech
        case .picker: return .picker
        case .strategy: return .strategy
        case .search, .condOrder, .profile, .alertRecords, .training, .layoutEditor,
             .lanSync, .pythonLab: return nil
        }
    }
}

enum HomeOverlayTarget: Identifiable, Equatable {
    case formula(FormulaKind)
    case condOrder
    case alertRecords
    case lanSync
    case pythonLab

    var id: String {
        switch self {
        case .formula(let kind): return "formula.\(kind.rawValue)"
        case .condOrder: return "condOrder"
        case .alertRecords: return "alertRecords"
        case .lanSync: return "lanSync"
        case .pythonLab: return "pythonLab"
        }
    }
}

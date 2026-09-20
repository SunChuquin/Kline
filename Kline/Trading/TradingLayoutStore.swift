//
//  TradingLayoutStore.swift
//  Kline
//
//  交易模块布局偏好：快捷面板（QuickPanelLayoutStyle）与模拟页
//  （SimulationLayoutStyle）各三套布局方案的枚举定义，以及 UserDefaults
//  持久化仓库 TradingLayoutStore（写法与 KlineThemeStore 同惯例）。
//

import Foundation
import Combine

// MARK: - 快捷面板布局方案

/// 快捷面板布局方案
enum QuickPanelLayoutStyle: String, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"
    case c = "C"

    var id: String { rawValue }

    /// 设置面板中的完整方案名
    var title: String {
        switch self {
        case .a: return "A · 上下文自适应交易卡"
        case .b: return "B · 分页式面板"
        case .c: return "C · 闪电下单条"
        }
    }

    /// 下拉触发按钮上的短名
    var shortTitle: String { rawValue }
}

// MARK: - 模拟页布局方案

/// 模拟页布局方案
enum SimulationLayoutStyle: String, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"
    case c = "C"

    var id: String { rawValue }

    /// 设置面板中的完整方案名
    var title: String {
        switch self {
        case .a: return "A · 账户侧栏 + 工作区"
        case .b: return "B · 账户卡片 + 模块宫格"
        case .c: return "C · 券商经典顶栏式"
        }
    }

    /// 下拉触发按钮上的短名
    var shortTitle: String { rawValue }
}

// MARK: - 布局偏好仓库（UserDefaults，与 KlineThemeStore 同惯例）

/// 布局偏好仓库：写入即持久化，@Published 驱动两处界面实时切换
final class TradingLayoutStore: ObservableObject {
    static let shared = TradingLayoutStore()

    private static let panelKey = "kline.quickPanelLayout"
    private static let simulationKey = "kline.simulationLayout"

    /// 快捷面板布局：默认 A
    @Published var panelLayout: QuickPanelLayoutStyle {
        didSet { UserDefaults.standard.set(panelLayout.rawValue, forKey: Self.panelKey) }
    }

    /// 模拟页布局：默认 A
    @Published var simulationLayout: SimulationLayoutStyle {
        didSet { UserDefaults.standard.set(simulationLayout.rawValue, forKey: Self.simulationKey) }
    }

    private init() {
        // 读回本地偏好；rawValue 非法或缺失时回退 .a
        let panelRaw = UserDefaults.standard.string(forKey: Self.panelKey) ?? ""
        panelLayout = QuickPanelLayoutStyle(rawValue: panelRaw) ?? .a

        let simulationRaw = UserDefaults.standard.string(forKey: Self.simulationKey) ?? ""
        simulationLayout = SimulationLayoutStyle(rawValue: simulationRaw) ?? .a
    }
}

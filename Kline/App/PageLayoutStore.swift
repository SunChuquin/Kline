//
//  PageLayoutStore.swift
//  Kline
//
//  页面布局偏好：自选页（FavoritesLayoutStyle）、行情页（MarketLayoutStyle）与
//  首页（HomeLayoutStyle）各四档布局方案的枚举定义，以及 UserDefaults 持久化仓库
//  PageLayoutStore（写法与 KlineThemeStore / TradingLayoutStore 同惯例）。
//  首页默认档为 B（新方案），自选页 / 行情页默认档仍为 A（现有实现）。
//

import Foundation
import Combine

// MARK: - 自选页布局方案

/// 自选页布局方案（A = 现有实现，B/C/D 为重设计方案）
enum FavoritesLayoutStyle: String, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"

    var id: String { rawValue }

    /// 设置面板中的完整方案名
    var title: String {
        switch self {
        case .a: return "A · 经典表格式（现有）"
        case .b: return "B · 分组侧栏 + 表格工作区"
        case .c: return "C · 自选卡片流"
        case .d: return "D · 分组看板 + 紧凑表格"
        }
    }

    /// 下拉触发按钮上的短名
    var shortTitle: String { rawValue }
}

// MARK: - 行情页布局方案

/// 行情页布局方案（A = 现有实现，B/C/D 为重设计方案）
enum MarketLayoutStyle: String, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"

    var id: String { rawValue }

    /// 设置面板中的完整方案名
    var title: String {
        switch self {
        case .a: return "A · 经典表格式（现有）"
        case .b: return "B · 分类侧栏 + 表格"
        case .c: return "C · 磁贴卡片网格"
        case .d: return "D · 概览 + 紧凑表格"
        }
    }

    /// 下拉触发按钮上的短名
    var shortTitle: String { rawValue }
}

// MARK: - 首页布局方案

/// 首页布局方案（B/C/D 三档；A 档「现有首页」已于 2026-09-25 按用户要求删除）
enum HomeLayoutStyle: String, CaseIterable, Identifiable {
    case b = "B"
    case c = "C"
    case d = "D"

    var id: String { rawValue }

    /// 设置面板中的完整方案名
    var title: String {
        switch self {
        case .b: return "B · 横滑入口 + 卡片网格（默认）"
        case .c: return "C · 横滑入口 + 分区列表"
        case .d: return "D · 横滑入口 + 工作台混排"
        }
    }

    /// 下拉触发按钮上的短名
    var shortTitle: String { rawValue }
}

// MARK: - 布局偏好仓库（UserDefaults，与 KlineThemeStore 同惯例）

/// 页面布局偏好仓库：写入即持久化，@Published 驱动三个页面实时切换
final class PageLayoutStore: ObservableObject {
    static let shared = PageLayoutStore()

    private static let favoritesKey = "kline.favoritesLayout"
    private static let marketKey = "kline.marketLayout"
    private static let homeKey = "kline.homeLayout"

    /// 自选页布局：默认 A
    @Published var favoritesLayout: FavoritesLayoutStyle {
        didSet { UserDefaults.standard.set(favoritesLayout.rawValue, forKey: Self.favoritesKey) }
    }

    /// 行情页布局：默认 A
    @Published var marketLayout: MarketLayoutStyle {
        didSet { UserDefaults.standard.set(marketLayout.rawValue, forKey: Self.marketKey) }
    }

    /// 首页布局：默认 B（新方案作为默认，进首页即见内容）
    @Published var homeLayout: HomeLayoutStyle {
        didSet { UserDefaults.standard.set(homeLayout.rawValue, forKey: Self.homeKey) }
    }

    private init() {
        // 读回本地偏好；rawValue 非法或缺失时回退 .a
        let favRaw = UserDefaults.standard.string(forKey: Self.favoritesKey) ?? ""
        favoritesLayout = FavoritesLayoutStyle(rawValue: favRaw) ?? .a

        let mktRaw = UserDefaults.standard.string(forKey: Self.marketKey) ?? ""
        marketLayout = MarketLayoutStyle(rawValue: mktRaw) ?? .a

        // 首页默认 B：rawValue 非法或缺失时回退 .b
        let homeRaw = UserDefaults.standard.string(forKey: Self.homeKey) ?? ""
        homeLayout = HomeLayoutStyle(rawValue: homeRaw) ?? .b
    }
}

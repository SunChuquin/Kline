//
//  AppTheme.swift
//  Kline
//
//  全局金融配色系统（Design Tokens）。
//
//  设计取向：TradingView 的多层次深灰 + Apple Stocks 的精致表面 + Bloomberg 的信息层级；
//  涨跌遵循 A 股「红涨绿跌」，并把「行情涨跌」与「操作状态」拆成两套语义 Token，
//  避免业务颜色互相影响。
//
//  实现方式：每个 Token 都是动态 UIColor 包装的 SwiftUI Color，
//  跟随视图所在的 InterfaceStyle 自动解析 Light / Dark 两套色值。
//  因此页面不需要感知 KlineThemeStore：切换日间/夜间/跟随系统时全 App 实时生效。
//  所有页面只允许引用这里的语义 Token，禁止再硬编码十六进制颜色或系统语义色。
//

import SwiftUI
import UIKit

// MARK: - Hex 构造

extension UIColor {
    /// 0xRRGGBB → UIColor（仅用于 Token 定义；业务页面不要直接调用）
    convenience init(tokenHex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((tokenHex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((tokenHex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(tokenHex & 0xFF) / 255.0,
                  alpha: alpha)
    }
}

// MARK: - 双主题色值解析

/// 同一语义色在 Light / Dark 下的两个十六进制值
enum AppColorPair {
    static func color(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: uiColor(light: light, dark: dark))
    }

    static func uiColor(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(tokenHex: dark)
                : UIColor(tokenHex: light)
        }
    }
}

// MARK: - 语义 Token

/// 全局语义色。业务代码只引用这里的名字，不引用具体色值。
enum AppColors {

    // MARK: 表面（背景 / 容器 / 浮层）

    /// 页面主背景
    static let pageBackground = AppColorPair.color(light: 0xF2F4F7, dark: 0x11151B)
    /// 侧边栏 / 顶栏 / 底栏等导航型表面
    static let sidebarBackground = AppColorPair.color(light: 0xE9EDF2, dark: 0x171C23)
    /// 卡片 / 设置行容器
    static let cardBackground = AppColorPair.color(light: 0xFFFFFF, dark: 0x1C232C)
    /// 卡片悬停 / 次级表面
    static let cardHoverBackground = AppColorPair.color(light: 0xF5F7FA, dark: 0x252E39)
    /// 选中态背景
    static let selectedBackground = AppColorPair.color(light: 0xE2EFFB, dark: 0x1B3045)

    // MARK: 文本

    /// 主文字（价格、标题）
    static let textPrimary = AppColorPair.color(light: 0x1B2533, dark: 0xE8EDF4)
    /// 次级文字（名称、说明）
    static let textSecondary = AppColorPair.color(light: 0x697586, dark: 0x9AA6B5)
    /// 辅助文字（占位、弱提示）
    static let textTertiary = AppColorPair.color(light: 0x929CAB, dark: 0x6F7B89)

    // MARK: 交互与结构

    /// 主强调色（可点击文字、选中图标、链接）
    static let accent = AppColorPair.color(light: 0x2878CC, dark: 0x4B9FFF)
    /// 分割线 / 描边
    static let separator = AppColorPair.color(light: 0xE2E7ED, dark: 0x303945)

    // MARK: 金融语义：行情涨跌（A 股红涨绿跌）

    /// 上涨（红）
    static let marketUp = AppColorPair.color(light: 0xE04141, dark: 0xF05252)
    /// 下跌（绿）
    static let marketDown = AppColorPair.color(light: 0x1F9A5F, dark: 0x26A269)

    // MARK: 金融语义：操作状态（与涨跌解耦，语义独立）

    /// 成功 / 在线 / 已完成
    static let statusSuccess = AppColorPair.color(light: 0x1F9A5F, dark: 0x26A269)
    /// 失败 / 错误 / 离线
    static let statusError = AppColorPair.color(light: 0xE04141, dark: 0xF05252)
    /// 警告 / 进行中 / 待确认
    static let statusWarning = AppColorPair.color(light: 0xC08A2E, dark: 0xD6A64D)
    /// 空闲 / 未检查 / 禁用
    static let statusIdle = AppColorPair.color(light: 0x929CAB, dark: 0x6F7B89)

    // MARK: UIKit 变体（行情行缓存等必须返回 UIColor 的场景）

    static let textPrimaryUI = AppColorPair.uiColor(light: 0x1B2533, dark: 0xE8EDF4)
    static let marketUpUI = AppColorPair.uiColor(light: 0xE04141, dark: 0xF05252)
    static let marketDownUI = AppColorPair.uiColor(light: 0x1F9A5F, dark: 0x26A269)
}

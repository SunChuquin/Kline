//
//  IndicatorStyle.swift
//  Kline
//
//  通达信公式的输出线样式与颜色定义。
//
//  Created by 孙楚昆 on 2026/8/16.
//

import SwiftUI

/// 通达信公式输出线的绘制类型
enum TDXLineStyle: String, CaseIterable {
    case solid    // 实线（默认）
    case dotline  // DOTLINE 虚线
    case pointdot // POINTDOT 小圆点
    case stick    // STICK 柱状线
    case nodraw   // NODRAW 空线条（只显示数值不绘制）

    var displayName: String {
        switch self {
        case .solid: return "实线"
        case .dotline: return "虚线"
        case .pointdot: return "小圆点"
        case .stick: return "柱状线"
        case .nodraw: return "不绘制"
        }
    }
}

/// 通达信公式可用颜色（COLORXXX 选项名 → 颜色）
enum TDXFormulaColor {
    /// 将 "COLORRED" 这类选项名映射为十六进制颜色串（nil 表示使用默认色）
    static func hex(forOption option: String) -> String? {
        switch option.uppercased() {
        case "COLORBLACK": return "000000"
        case "COLORBLUE": return "0050FF"
        case "COLORGREEN": return "00C400"
        case "COLORCYAN": return "00FFFF"
        case "COLORRED": return "FF0000"
        case "COLORMAGENTA": return "FF00FF"
        case "COLORLIBERAL", "COLORORANGE": return "FF7F00"
        case "COLORBROWN": return "8B4513"
        case "COLORLIGRAY": return "C0C0C0"
        case "COLORGRAY": return "808080"
        case "COLORLILUE": return "ADD8E6"
        case "COLORLIGREEN": return "90EE90"
        case "COLORLICYAN": return "E0FFFF"
        case "COLORLIRED": return "FFB4B4"
        case "COLORLIMAGENTA": return "FFC0CB"
        case "COLORYELLOW": return "FFFF00"
        case "COLORWHITE": return "FFFFFF"
        default: return nil
        }
    }

    /// 用户可选择的颜色（含名称与色值），用于编辑器的颜色选择面板
    static let palette: [(String, String)] = [
        ("黑色", "000000"), ("蓝色", "0050FF"), ("绿色", "00C400"), ("青色", "00FFFF"),
        ("红色", "FF0000"), ("洋红", "FF00FF"), ("橙色", "FF7F00"), ("棕色", "8B4513"),
        ("淡灰", "C0C0C0"), ("深灰", "808080"), ("淡蓝", "ADD8E6"), ("淡绿", "90EE90"),
        ("淡青", "E0FFFF"), ("淡红", "FFB4B4"), ("淡洋红", "FFC0CB"), ("黄色", "FFFF00"),
        ("白色", "FFFFFF"),
    ]
}
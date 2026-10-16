//
//  FormulaEngine.swift
//  Kline
//
//  通达信风格公式的 Swift 侧数据模型（2026-10-16 起求值/解析/拆分全部下沉 Python 引擎，
//  见 PyTDXFormulaBridge + Kline/PyScripts/tdx_eval.py；Swift 只剩渲染用的输出模型）。
//
//  Created by 孙楚昆 on 2026/8/16.
//

import Foundation

/// 输出行值全为 NaN 判断（行保留/曲线占位的基础判定，KlineChartView 与 LinkedReplaySupport 共用）
func tdxAllNaN(_ values: [Double]) -> Bool { values.allSatisfy { $0.isNaN } }

struct TDXOutputLine {
    let name: String
    let values: [Double]
    /// 绘制类型（实线/虚线/圆点/柱状/不绘制）
    var style: TDXLineStyle = .solid
    /// 线宽倍数（LINETHICK1..8，默认1=系统线条一倍粗度）
    var lineWidth: Double = 1
    /// 颜色十六进制（COLORXXX 选项），nil 表示使用默认色
    var colorHex: String? = nil
    /// NOTEXT_ 前缀：隐藏该变量在指标栏中的数值，但保留线条
    var hideValue: Bool = false
    /// SAR 红/绿方向（true=红/涨，false=绿/跌），nil 表示不使用
    var markerDirections: [Bool]? = nil
    /// COLORSTICK：红绿柱（按正负红绿着色）
    var colorStick: Bool = false
}

/// 单个输出行的独立求值单元：该行 + 它全部传递依赖的语句（拆分由 Python text_split 完成）。
/// text 为该单元的公式文本，用作主图行缓存的 key（参数变仅影响对应行）。
struct TDXOutputLineUnit {
    let name: String
    /// 该行的公式文本（含参数替换后的值），用于逐行缓存比较——参数变仅影响对应行
    let text: String

    /// Python text_split 结果 → 单元（statements 已下沉，Swift 不再持有 AST）
    init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

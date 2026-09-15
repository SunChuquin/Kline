//
//  ChartTypes.swift
//  Kline
//
//  图表共享类型：显示枚举、指标线/画布曲线模型、副图模型与选择记忆、序列工具、缺口信息。
//  从 KlineChartView.swift 拆分而来（纯类型移动，同 module 内引用不变）。
//

import SwiftUI
import Combine

/// 主图显示类型
enum ChartStyle: String, CaseIterable, Identifiable {
    case bare  = "空心K线"   // 红K空心，绿K实心
    case solid = "实心K线"
    case close = "收盘线"
    case ohlc  = "美国线"
    var id: String { rawValue }
}

/// 公式编辑器针对的目标图表
enum EditorTarget {
    case main, sub
}

/// 副图槽位（第1/第2/第3个副图）
enum SubSlot: Hashable {
    case top, bottom, third
}

/// 指标柱状曲线颜色规则
enum BarColorMode: Equatable {
    case fixed       // 使用曲线自身颜色
    case sign        // 按柱值正负着色（MACD）
    case candle      // 按对应K线涨跌着色（量柱）
}

// MARK: - 通用指标线

// MARK: - 通用指标线

struct IndicatorLine: Equatable {
    let name: String
    var values: [Double]
    let color: Color
    let style: TDXLineStyle
    let lineWidth: Double
    let hideValue: Bool
    var barColor: BarColorMode = .fixed
    /// 逐点着色（SAR 红/绿圆点）；nil 时用 color 统一着色
    var markerColors: [Color]? = nil
}

struct CanvasCurve: Equatable {
    var color: Color
    var values: [Double]
    var style: TDXLineStyle
    var lineWidth: Double
    var barColor: BarColorMode = .fixed
    var markerColors: [Color]? = nil
}

// MARK: - 副图模型

// MARK: - 副图模型

final class SubChartModel: ObservableObject {
    @Published var kind: String = "VOL"
    @Published var activeCustomID: UUID? = nil
    @Published var titleName: String = "VOL"
    @Published var curves: [IndicatorLine] = [] {
        didSet {
            // 诊断：任何把「非空」副图曲线清成空的写操作都打印调用栈，定位变空根因
            if !oldValue.isEmpty && curves.isEmpty {
                klineDebug("[KlineDebug] ⚠️副图清空 \(kind) 旧=\(oldValue.count)->新=0 | 栈:\(Thread.callStackSymbols.prefix(10).joined(separator:" | "))")
            }
        }
    }
    @Published var color: Color = Color(hex: "0050FF")!

    var isCustom: Bool { activeCustomID != nil }
}

/// 单个副图槽位的一次选择记忆（指标类型 + 所属自定义指标 id）
struct SubChartSelection {
    var kind: String
    var customID: UUID?
}

/// 从一次副图选择构建独立实例（仅配置；titleName/color 由 recomputeSub 按指标重算补齐；双联动隔离用）
func subModel(from s: SubChartSelection) -> SubChartModel {
    let m = SubChartModel()
    m.kind = s.kind
    m.activeCustomID = s.customID
    return m
}

/// 仅缓存排序后的 K 线数据；指标一律用静态方法按需(可见配置)计算，不再整表预计算未用指标。
struct ChartSeries {
    let sorted: [KlineItem]

    init(data: [KlineItem]) {
        self.sorted = Array(data.reversed())
    }

    /// 滑动均值：跳过 NaN/无效点，只有窗口内全部为有效值时输出，避免首个 NaN 永久污染滚动和。
    static func ma(values: [Double], period: Int) -> [Double] {
        var result = Array(repeating: Double.nan, count: values.count)
        guard period > 0 else { return result }
        var sum = 0.0
        var valid = 0
        for i in 0..<values.count {
            let v = values[i]
            if v.isFinite { sum += v; valid += 1 }
            let outIdx = i - period
            if outIdx >= 0, values[outIdx].isFinite { sum -= values[outIdx]; valid -= 1 }
            if valid >= period { result[i] = sum / Double(period) }
        }
        return result
    }
}

/// 跳空缺口（预计算一次，绘制时按可见区间过滤）
struct GapInfo: Equatable {
    /// 缺口形成位置（startIdx-1 与 startIdx 两根K线之间）
    let startIdx: Int
    let top: Double
    let bottom: Double
    let isUp: Bool
    /// 回补位置（该索引的K线价格触及缺口区间；nil = 未回补，一直显示）
    let filledIdx: Int?
}

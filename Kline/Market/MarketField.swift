//
//  MarketField.swift
//  Kline
//
//  行情表单字段定义：key/表头/对齐/宽度/颜色/排序方向（行情与自选共用）。从 MarketFieldKit.swift 拆分。
//

import Foundation
import SwiftUI
import UIKit

// MARK: - 字段定义

/// 所有可选行级字段的枚举（通达信「表头」）
enum MarketField: String, CaseIterable, Codable, Identifiable, Hashable {
    case code           // 代码
    case name           // 名称
    case latestPrice    // 现价
    case prevClose      // 昨收
    case change         // 涨跌额
    case changePct      // 涨跌幅 (%)
    case open           // 今开
    case high           // 最高
    case low            // 最低
    case volume         // 成交量
    case turnover       // 成交额
    case amplitude      // 振幅 (%)
    case turnoverRate   // 换手率 (%)  → 没有流通股本数据时显示 "-"
    case pct3d          // 近3日涨幅
    case pct5d          // 近5日涨幅
    case pct10d         // 近10日涨幅
    case pct20d         // 近20日涨幅
    case pct60d         // 近60日涨幅
    case pctYTD         // 年初至今涨幅
    case volRatio       // 量比（当日成交量 / 过去5日均量）
    case ma5            // MA5
    case ma10           // MA10
    case ma20           // MA20
    case ma60           // MA60
    case type           // 板块类型
    case lastDate       // 数据日期

    var id: String { rawValue }

    /// 表头中文字
    var title: String {
        switch self {
        case .code: return "代码"
        case .name: return "名称"
        case .latestPrice: return "现价"
        case .prevClose: return "昨收"
        case .change: return "涨跌额"
        case .changePct: return "涨跌幅"
        case .open: return "今开"
        case .high: return "最高"
        case .low: return "最低"
        case .volume: return "成交量"
        case .turnover: return "成交额"
        case .amplitude: return "振幅"
        case .turnoverRate: return "换手"
        case .pct3d: return "3日%"
        case .pct5d: return "5日%"
        case .pct10d: return "10日%"
        case .pct20d: return "20日%"
        case .pct60d: return "60日%"
        case .pctYTD: return "今年%"
        case .volRatio: return "量比"
        case .ma5: return "MA5"
        case .ma10: return "MA10"
        case .ma20: return "MA20"
        case .ma60: return "MA60"
        case .type: return "板块"
        case .lastDate: return "数据日期"
        }
    }

    /// 默认列宽（pt，用户可配置列顺序，宽度按字段类型估）
    var defaultWidth: CGFloat {
        switch self {
        case .code: return 66
        case .name: return 84
        case .latestPrice, .prevClose, .open, .high, .low,
             .ma5, .ma10, .ma20, .ma60:
            return 70
        case .change: return 60
        case .changePct, .amplitude, .turnoverRate,
             .pct3d, .pct5d, .pct10d, .pct20d, .pct60d, .pctYTD, .volRatio:
            return 62
        case .volume, .turnover: return 78
        case .type: return 70
        case .lastDate: return 78
        }
    }

    /// 文本对齐
    var alignRight: Bool {
        switch self {
        case .code, .name, .type, .lastDate: return false
        default: return true
        }
    }

    /// 数值涨跌着色：true=上涨红色/下跌绿色
    var isTintedByChange: Bool {
        switch self {
        case .latestPrice, .prevClose, .change, .changePct,
             .open, .high, .low,
             .amplitude, .volRatio,
             .pct3d, .pct5d, .pct10d, .pct20d, .pct60d, .pctYTD:
            return true
        default:
            return false
        }
    }

    /// 默认启用的字段（用户首次进入看到的最小集合）
    static let defaultsVisible: [MarketField] = [
        .code, .name, .latestPrice, .changePct, .change,
        .volume, .turnover
    ]

    /// 表头设置面板不支持配置的字段（不作为列显示、不在设置面板出现）
    static let nonConfigurable: Set<MarketField> = [
        .high, .low, .prevClose, .open,
        .turnoverRate, .volRatio,
        .ma5, .ma10, .ma20, .ma60,
        .type, .lastDate,
    ]

    /// 该字段是否可在表头设置中配置（作为列显示/隐藏/排序/筛选）
    var isConfigurable: Bool {
        !Self.nonConfigurable.contains(self)
    }

    /// 仅展示文本（不需要 K 线计算的字段）
    var isMetadataOnly: Bool {
        switch self {
        case .code, .name, .type: return true
        default: return false
        }
    }
}


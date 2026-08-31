//
//  KlineData.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/8/5.
//

import Foundation

struct MetaItem: Identifiable, Hashable {
    let id: Int
    let file: String
    let code: String
    let name: String
    let type: String
    let firstDate: Int?
    let lastDate: Int?

    var displayCode: String {
        return code.replacingOccurrences(of: "SH", with: "").replacingOccurrences(of: "SZ", with: "")
    }

    var formattedFirstDate: String {
        guard let firstDate = firstDate else { return "-" }
        return String(firstDate)
    }

    var formattedLastDate: String {
        guard let lastDate = lastDate else { return "-" }
        return String(lastDate)
    }
}

struct KlineItem: Identifiable, Hashable {
    let id = UUID()
    let date: Int
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
    let turnover: Double

    var isUp: Bool {
        return close >= open
    }

    var changePercent: Double {
        guard open > 0 else { return 0 }
        return (close - open) / open * 100
    }

    var formattedDate: String {
        let dateStr = String(date)
        let year = String(dateStr.prefix(4))
        let month = String(dateStr.dropFirst(4).prefix(2))
        let day = String(dateStr.dropFirst(6))
        return "\(year)-\(month)-\(day)"
    }

    /// 形如 "2026/07/06/一" 的带星期日期
    var formattedDateWithWeekday: String {
        let dateStr = String(date)
        let y = Int(dateStr.prefix(4)) ?? 0
        let m = Int(dateStr.dropFirst(4).prefix(2)) ?? 0
        let d = Int(dateStr.dropFirst(6)) ?? 0
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        if let date = Calendar.current.date(from: comps) {
            let weekday = Calendar.current.component(.weekday, from: date) // 1=周日 ... 7=周六
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            let wd = names[max(0, (weekday - 1) % 7)]
            return String(format: "%04d/%02d/%02d/%@", y, m, d, wd)
        }
        return formattedDate
    }

    var formattedVolume: String {
        if volume >= 100000000 {
            return String(format: "%.2f亿", volume / 100000000)
        } else if volume >= 10000 {
            return String(format: "%.2f万", volume / 10000)
        } else {
            return String(format: "%.0f", volume)
        }
    }

    var formattedTurnover: String {
        if turnover >= 100000000 {
            return String(format: "%.2f亿", turnover / 100000000)
        } else if turnover >= 10000 {
            return String(format: "%.2f万", turnover / 10000)
        } else {
            return String(format: "%.0f", turnover)
        }
    }
}

struct KlineDataGroup: Identifiable {
    let id = UUID()
    let metaItem: MetaItem
    let dailyData: [KlineItem]
    let weeklyData: [KlineItem]
}

enum KlinePeriod: String, CaseIterable, Identifiable, Codable {
    case daily = "日线"
    case weekly = "周线"
    case monthly = "月线"
    case quarterly = "季线"
    case yearly = "年线"

    var id: String { rawValue }

    /// 沙盒指示器目录中的周期文件夹名（与数据库周期表英文名一致）。
    /// 用于「按周期分目录」存储/加载各自独立的指标模板与参数。
    var folderName: String {
        switch self {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .quarterly: return "quarterly"
        case .yearly: return "yearly"
        }
    }
}

/// 图表图层显示设置（由设置面板控制，绑定传入 K 线图）
struct ChartDisplaySettings: Equatable {
    /// 区间统计：在图表中显示可见区间统计面板
    var showRangeStats = false
    /// 图层显示：跳空缺口
    var showGap = false
    /// 图层显示：最新价线
    var showLatestPriceLine = true
    /// 图层显示：指标线不挤压K线（主图价格范围仅按K线计算，指标线不参与范围）
    var indicatorNotSqueezeKline = true
    /// 图层显示：缺口回补后消失（开启时缺口回补截止后整个隐藏；关闭时仅截止、保留形成到截止区域）
    var gapDisappearAfterFill = false
}
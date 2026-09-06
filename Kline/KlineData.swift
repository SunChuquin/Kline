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

    /// 周期粒度等级：数字越大周期越大（日<周<月<季<年）。
    /// 用于联动光标「更大周期源 → 更小周期目标」时，在更小周期视图上用双竖轴框出来源范围。
    var granularityRank: Int {
        switch self {
        case .daily: return 0
        case .weekly: return 1
        case .monthly: return 2
        case .quarterly: return 3
        case .yearly: return 4
        }
    }

    /// 该周期某一根K线（date，YYYYMMDD 整数）覆盖的时间范围。
    /// 返回 (start, end) 也是 YYYYMMDD 整数，含首尾当天：
    /// 日线=当天；周线=周一~周日；月/季/年=对应整月/整季/整年。
    /// 用于联动光标在更小周期视图上用两根竖轴框出来源K线范围内的所有K线。
    static func periodDateRange(_ period: KlinePeriod, date: Int) -> (Int, Int) {
        let (y, m, d) = toYMD(date)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        switch period {
        case .daily:
            return (date, date)
        case .weekly:
            // 周线：显式固定「周一为一周起点」，不依赖用户地区的 firstWeekday 配置。
            cal.firstWeekday = 2
            var comps = DateComponents(); comps.year = y; comps.month = m; comps.day = d
            guard let cur = cal.date(from: comps) else { return (date, date) }
            let wd = cal.component(.weekday, from: cur) // 1=周日 ... 7=周六，周一=2
            let back = (wd - 2 + 7) % 7
            guard let monday = cal.date(byAdding: .day, value: -back, to: cur),
                  let sunday = cal.date(byAdding: .day, value: 6, to: monday) else { return (date, date) }
            return (fromComps(cal.dateComponents([.year, .month, .day], from: monday)),
                    fromComps(cal.dateComponents([.year, .month, .day], from: sunday)))
        case .monthly:
            let start = fromYMD(y, m, 1)
            var ecomps = DateComponents(); ecomps.year = y; ecomps.month = m; ecomps.day = 1
            let days = cal.range(of: .day, in: .month, for: cal.date(from: ecomps) ?? Date()).map { $0.count - 1 } ?? d
            return (start, fromYMD(y, m, days))
        case .quarterly:
            let qm = ((m - 1) / 3) * 3 + 1               // 季度首月
            let start = fromYMD(y, qm, 1)
            let qEnd = qm + 2                             // 季度末月
            let ey = (qEnd > 12) ? y + 1 : y
            let em = (qEnd > 12) ? qEnd - 12 : qEnd
            var ecomps = DateComponents(); ecomps.year = ey; ecomps.month = em; ecomps.day = 1
            let days = cal.range(of: .day, in: .month, for: cal.date(from: ecomps) ?? Date()).map { $0.count - 1 } ?? d
            return (start, fromYMD(ey, em, days))
        case .yearly:
            return (fromYMD(y, 1, 1), fromYMD(y, 12, 31))
        }
    }

    private static func toYMD(_ d: Int) -> (Int, Int, Int) {
        (d / 10000, (d / 100) % 100, d % 100)
    }

    private static func fromYMD(_ y: Int, _ m: Int, _ d: Int) -> Int {
        y * 10000 + m * 100 + d
    }

    private static func fromComps(_ c: DateComponents) -> Int {
        fromYMD(c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

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
struct ChartDisplaySettings: Equatable, Codable {
    /// 图层显示：跳空缺口
    var showGap = false
    /// 图层显示：最新价线
    var showLatestPriceLine = true
    /// 图层显示：指标线不挤压K线（主图价格范围仅按K线计算，指标线不参与范围）
    var indicatorNotSqueezeKline = true
    /// 图层显示：缺口回补后消失（开启时缺口回补截止后整个隐藏；关闭时仅截止、保留形成到截止区域）
    var gapDisappearAfterFill = false
}
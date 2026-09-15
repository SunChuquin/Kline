//
//  MarketFilter.swift
//  Kline
//
//  三级快捷筛选选项与排序规则（字段筛选分段、升降序规则、行数组排序扩展）。
//  从 MarketFieldKit.swift 拆分。
//

// MARK: - 三级快捷筛选

/// 一个可点击的筛选分段：标签 + 是否命中的判断（闭包持有者，按 label 判等）
struct MarketRangeOption: Identifiable, Equatable {
    let label: String
    let matches: (Double) -> Bool
    var id: String { label }
    static func == (l: Self, r: Self) -> Bool { l.label == r.label }
}

extension MarketField {
    /// 该字段可供配置的筛选分段（nil = 无预设，表头设置里不显示筛选下拉）
    var rangeFilterOptions: [MarketRangeOption]? {
        // 不可配置的字段不支持筛选
        guard isConfigurable else { return nil }
        switch self {
        // 价格类（元）：复用「现价」这套分段
        case .latestPrice:
            return Self.priceOptions
        // 涨跌幅（%）
        case .changePct:
            return Self.changePctOptions
        // 涨跌额（元）
        case .change:
            return Self.changeAmountOptions
        // 振幅（%）
        case .amplitude:
            return [
                MarketRangeOption(label: ">10%", matches: { $0 > 10 }),
                MarketRangeOption(label: "10~7", matches: { $0 > 7 && $0 <= 10 }),
                MarketRangeOption(label: "7~5", matches: { $0 > 5 && $0 <= 7 }),
                MarketRangeOption(label: "5~3", matches: { $0 > 3 && $0 <= 5 }),
                MarketRangeOption(label: "3~0", matches: { $0 > 0 && $0 <= 3 }),
            ]
        // 多日涨幅（%）→ 统一用涨幅分档
        case .pct3d, .pct5d, .pct10d, .pct20d, .pct60d, .pctYTD:
            return Self.changePctRangeOptions
        // 成交量 / 成交额（元，按亿/万分档）
        case .volume, .turnover:
            return Self.volumeTurnoverOptions
        // 其他可配置字段（名称/代码）无数值分档
        default:
            return nil
        }
    }

    /// 现价类（元）分段
    static let priceOptions: [MarketRangeOption] = [
        MarketRangeOption(label: ">1000元", matches: { $0 > 1000 }),
        MarketRangeOption(label: "1000~500", matches: { $0 > 500 && $0 <= 1000 }),
        MarketRangeOption(label: "500~100", matches: { $0 > 100 && $0 <= 500 }),
        MarketRangeOption(label: "100~50", matches: { $0 > 50 && $0 <= 100 }),
        MarketRangeOption(label: "50~30", matches: { $0 > 30 && $0 <= 50 }),
        MarketRangeOption(label: "30~20", matches: { $0 > 20 && $0 <= 30 }),
        MarketRangeOption(label: "20~10", matches: { $0 > 10 && $0 <= 20 }),
        MarketRangeOption(label: "10~5", matches: { $0 > 5 && $0 <= 10 }),
        MarketRangeOption(label: "5~2", matches: { $0 > 2 && $0 <= 5 }),
        MarketRangeOption(label: "<2", matches: { $0 <= 2 }),
    ]

    /// 涨跌幅（%）分段
    static let changePctOptions: [MarketRangeOption] = [
        MarketRangeOption(label: "涨停", matches: { $0 >= 9.9 }),
        MarketRangeOption(label: ">7%", matches: { $0 > 7 && $0 < 9.9 }),
        MarketRangeOption(label: "7~5", matches: { $0 >= 5 && $0 <= 7 }),
        MarketRangeOption(label: "5~3", matches: { $0 >= 3 && $0 < 5 }),
        MarketRangeOption(label: "3~0", matches: { $0 > 0 && $0 < 3 }),
        MarketRangeOption(label: "平", matches: { $0 == 0 }),
        MarketRangeOption(label: "0~-3", matches: { $0 > -3 && $0 < 0 }),
        MarketRangeOption(label: "-3~-5", matches: { $0 > -5 && $0 <= -3 }),
        MarketRangeOption(label: "-5~-7", matches: { $0 >= -7 && $0 < -5 }),
        MarketRangeOption(label: "跌停", matches: { $0 <= -9.9 }),
    ]

    /// 涨跌额（元）分段
    static let changeAmountOptions: [MarketRangeOption] = [
        MarketRangeOption(label: ">5元", matches: { $0 > 5 }),
        MarketRangeOption(label: "5~3", matches: { $0 > 3 && $0 <= 5 }),
        MarketRangeOption(label: "3~1", matches: { $0 > 1 && $0 <= 3 }),
        MarketRangeOption(label: "1~-1", matches: { $0 > -1 && $0 <= 1 }),
        MarketRangeOption(label: "-1~-3", matches: { $0 > -3 && $0 <= -1 }),
        MarketRangeOption(label: "-3~-5", matches: { $0 > -5 && $0 <= -3 }),
        MarketRangeOption(label: "<-5元", matches: { $0 <= -5 }),
    ]

    /// 成交量 / 成交额（元，按亿/万分档）分段
    static let volumeTurnoverOptions: [MarketRangeOption] = [
        MarketRangeOption(label: ">1000亿", matches: { $0 > 100_000_000_000 }),
        MarketRangeOption(label: "1000亿~500亿", matches: { $0 > 50_000_000_000 && $0 <= 100_000_000_000 }),
        MarketRangeOption(label: "500亿~100亿", matches: { $0 > 10_000_000_000 && $0 <= 50_000_000_000 }),
        MarketRangeOption(label: "100亿~1亿", matches: { $0 > 100_000_000 && $0 <= 10_000_000_000 }),
        MarketRangeOption(label: "1亿~1万", matches: { $0 > 10_000 && $0 <= 100_000_000 }),
        MarketRangeOption(label: "<1万", matches: { $0 <= 10_000 }),
    ]

    /// 多日涨幅（%）分段
    static let changePctRangeOptions: [MarketRangeOption] = [
        MarketRangeOption(label: ">20%", matches: { $0 > 20 }),
        MarketRangeOption(label: "20~10", matches: { $0 > 10 && $0 <= 20 }),
        MarketRangeOption(label: "10~5", matches: { $0 > 5 && $0 <= 10 }),
        MarketRangeOption(label: "5~0", matches: { $0 > 0 && $0 <= 5 }),
        MarketRangeOption(label: "0~-5", matches: { $0 > -5 && $0 <= 0 }),
        MarketRangeOption(label: "-5~-10", matches: { $0 > -10 && $0 <= -5 }),
        MarketRangeOption(label: "<-10%", matches: { $0 <= -10 }),
    ]
}

// MARK: - 排序键（支持升/降序 + 字段）

enum SortOrder: String, Codable {
    case ascending, descending
    var toggled: SortOrder { self == .ascending ? .descending : .ascending }
    var symbol: String { self == .ascending ? "↑" : "↓" }
}

struct MarketSortRule: Codable, Equatable, Hashable {
    var field: MarketField
    var order: SortOrder
}

// MARK: - 排序：给 [MarketRow] 按规则排序

// MARK: - 排序：给 [MarketRow] 按规则排序

extension Array where Element == MarketRow {
    func sorted(by rule: MarketSortRule?) -> [MarketRow] {
        guard let rule = rule else { return self }
        return sorted { a, b in
            let av = a.number(rule.field) ?? -Double.greatestFiniteMagnitude
            let bv = b.number(rule.field) ?? -Double.greatestFiniteMagnitude
            switch rule.order {
            case .descending: return av > bv
            case .ascending:  return av < bv
            }
        }
    }
}

//
//  SimFormat.swift
//  Kline
//
//  交易模块统一格式化（快捷面板 / 模拟页 / 下单组件共用）：金额千分位、
//  带符号金额与百分比、股数、价格、时间的展示文案。
//  所有格式化器显式固定 en_US_POSIX，保证分隔符恒为 "," 与 "."，
//  不受设备区域设置影响；负号统一用 ASCII "-"。
//

import Foundation

enum SimFormat {

    // MARK: - 格式化器

    private static func makeNumberFormatter(minFraction: Int, maxFraction: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = minFraction
        formatter.maximumFractionDigits = maxFraction
        return formatter
    }

    private static func makeDateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    private static let amountFormatter = makeNumberFormatter(minFraction: 2, maxFraction: 2)
    private static let amount0Formatter = makeNumberFormatter(minFraction: 0, maxFraction: 0)
    private static let sharesFormatter = makeNumberFormatter(minFraction: 0, maxFraction: 0)
    private static let priceFormatter = makeNumberFormatter(minFraction: 2, maxFraction: 2)
    private static let pctFormatter = makeNumberFormatter(minFraction: 2, maxFraction: 2)

    private static let timeFormatter = makeDateFormatter("HH:mm:ss")
    private static let dateTimeFormatter = makeDateFormatter("MM-dd HH:mm")
    private static let shortDateFormatter = makeDateFormatter("MM-dd")

    private static func text(_ value: Double, _ formatter: NumberFormatter) -> String {
        formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - 数值

    /// 金额（两位小数 + 千分位），如 "1,028,446.50"
    static func amount(_ v: Double) -> String {
        text(v, amountFormatter)
    }

    /// 金额（无小数 + 千分位），如 "1,028,447"
    static func amount0(_ v: Double) -> String {
        text(v, amount0Formatter)
    }

    /// 带符号金额，如 "+2,841.00" / "-420.00"
    static func signed(_ v: Double) -> String {
        (v < 0 ? "-" : "+") + text(abs(v), amountFormatter)
    }

    /// 带符号金额（无小数），如 "+2,841" / "-420"
    static func signed0(_ v: Double) -> String {
        (v < 0 ? "-" : "+") + text(abs(v), amount0Formatter)
    }

    /// 带符号百分比，如 "+0.31%" / "-1.18%"
    static func pct(_ v: Double) -> String {
        (v < 0 ? "-" : "+") + text(abs(v), pctFormatter) + "%"
    }

    /// 股数（千分位整数），如 "1,000"
    static func shares(_ v: Int) -> String {
        text(Double(v), sharesFormatter)
    }

    /// 价格（两位小数 + 千分位），如 "1,466.17"
    static func price(_ v: Double) -> String {
        text(v, priceFormatter)
    }

    // MARK: - 日期

    /// 时间，如 "14:52:30"
    static func time(_ d: Date) -> String {
        timeFormatter.string(from: d)
    }

    /// 日期时间，如 "09-19 14:52"
    static func dateTime(_ d: Date) -> String {
        dateTimeFormatter.string(from: d)
    }

    /// 短日期，如 "09-19"
    static func shortDate(_ d: Date) -> String {
        shortDateFormatter.string(from: d)
    }
}

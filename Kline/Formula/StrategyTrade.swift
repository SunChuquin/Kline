//
//  StrategyTrade.swift
//  Kline
//
//  策略交易指令（TRADE: 段）：方向 / 数量或金额 / 报价方式 / 有效期 / 绑定账户，
//  以及规则行内 ORD* 覆盖键的解析与序列化。
//
//  Created by 孙楚昆 on 2026/9/20.
//

import Foundation

// MARK: - 交易指令

/// 策略交易指令（TRADE: 段）：方向 / 数量或金额 / 报价方式 / 有效期 / 绑定账户
/// nonisolated：纯数据，需在后台线程（历史回测引擎）读取
nonisolated struct StrategyTradeSpec: Equatable {
    var direction: SimOrderDirection? = nil     // 只借用 SimModels 的枚举
    var qty: Int? = nil
    var amount: Double? = nil
    var priceType: SimPriceType? = nil
    var offsetTicks: Int? = nil
    var validity: SimCondValidity? = nil
    var expiresAt: Date? = nil                  // 仅 validity == .untilDate
    var accountIDs: [UUID] = []
    /// 全空 = 未配置（旧策略文件）
    var isEmpty: Bool {
        direction == nil && qty == nil && amount == nil && priceType == nil
            && offsetTicks == nil && validity == nil && expiresAt == nil && accountIDs.isEmpty
    }
}

/// 规则行内指令覆盖（ORD* 保留键）
///
/// 用 `ORD` 前缀而不是直接复用规则参数键：`DIR` 已被 `MA_CROSS` 占用（UP/DOWN）、
/// `QTY` 已被 `GRID` 占用，直接复用会与规则参数撞名并污染 `knownKeys` 校验。
/// 优先级：规则行内覆盖 > TRADE 段 > 内置默认。
/// nonisolated：纯数据，需在后台线程装配
nonisolated struct StrategyDirectiveOverride: Equatable {
    var dir: SimOrderDirection? = nil
    var qty: Int? = nil
    var amount: Double? = nil
    var priceType: SimPriceType? = nil
    var offsetTicks: Int? = nil

    var isEmpty: Bool {
        dir == nil && qty == nil && amount == nil && priceType == nil && offsetTicks == nil
    }

    /// 覆盖项的中文摘要（无覆盖返回 nil），如「卖出 300 股」「限价 +2 档」
    var summary: String? {
        if isEmpty { return nil }
        var parts: [String] = []
        let qtyOrAmount: String? = qty.map { "\($0) 股" } ?? amount.map { "\(Self.amountText($0)) 元" }
        if let d = dir {
            parts.append(qtyOrAmount.map { "\(d.title) \($0)" } ?? d.title)
        } else if let qtyOrAmount {
            parts.append(qtyOrAmount)
        }
        if let pt = priceType {
            if pt == .limit, let off = offsetTicks {
                parts.append("限价 \(Self.offsetText(off))")
            } else {
                parts.append("\(pt.title)委托")
            }
        } else if let off = offsetTicks {
            parts.append(Self.offsetText(off))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// 金额文案：整数不带小数，非整数用最短可回读表示
    private static func amountText(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(v)
    }

    /// 偏移档次文案：正数带 "+"，如 "+2 档"
    private static func offsetText(_ n: Int) -> String {
        n >= 0 ? "+\(n) 档" : "\(n) 档"
    }
}

// MARK: - TRADE 段解析器

/// TRADE 段与规则行内 ORD* 覆盖键的解析 / 序列化
/// nonisolated：纯解析，需在后台线程（历史回测引擎）调用
nonisolated enum StrategyTradeParser {

    /// 规则行内的保留指令键（不进 StrategyRuleCatalog.specs，不参与规则参数校验）
    static let reservedKeys: [String] = ["ORDDIR", "ORDQTY", "ORDAMT", "ORDPT", "ORDOFF"]

    /// 是否为保留指令键（大小写不敏感）
    static func isReservedKey(_ key: String) -> Bool {
        reservedKeys.contains(key.trimmingCharacters(in: .whitespaces).uppercased())
    }

    /// 解析 TRADE: 段的各行（入参是已去掉 "TRADE:" 标记行的原始行，未 trim）
    static func parse(lines: [String]) -> (spec: StrategyTradeSpec, errors: [String]) {
        var spec = StrategyTradeSpec()
        var errors: [String] = []

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }          // 空行跳过
            if trimmed.hasPrefix("{") { continue }   // {…} 注释行跳过

            // 全角等号 / 逗号归一化后再解析
            let normalized = normalize(trimmed)
            guard let eq = normalized.firstIndex(of: "=") else {
                errors.append("TRADE 段格式应为 KEY=VALUE（\(trimmed)）")
                continue
            }
            let key = String(normalized[normalized.startIndex..<eq]).trimmingCharacters(in: .whitespaces).uppercased()
            let val = String(normalized[normalized.index(after: eq)...])
                .replacingOccurrences(of: " ", with: "")
                .trimmingCharacters(in: .whitespaces)

            switch key {
            case "DIRECTION":
                if let d = direction(from: val) { spec.direction = d }
                else { errors.append("DIRECTION 只能是 BUY 或 SELL") }
            case "QTY":
                if let n = Int(val) { spec.qty = n }
                else { errors.append("QTY 需要填整数") }
            case "AMOUNT":
                if let v = Double(val) { spec.amount = v }
                else { errors.append("AMOUNT 需要填数字") }
            case "PRICETYPE":
                if let p = priceType(from: val) { spec.priceType = p }
                else { errors.append("PRICETYPE 只能是 MARKET 或 LIMIT") }
            case "OFFSETTICKS":
                if let n = Int(val) { spec.offsetTicks = n }
                else { errors.append("OFFSETTICKS 需要填整数") }
            case "VALIDITY":
                if let v = validity(from: val) { spec.validity = v }
                else { errors.append("VALIDITY 只能是 DAY / LONG / DATE") }
            case "EXPIRES":
                if let d = date(from: val) { spec.expiresAt = d }
                else { errors.append("EXPIRES 日期格式应为 YYYY-MM-DD") }
            case "ACCOUNTS":
                for token in val.components(separatedBy: ",") where !token.isEmpty {
                    if let u = UUID(uuidString: token) {
                        spec.accountIDs.append(u)
                    } else {
                        errors.append("ACCOUNTS 含非法账户 id：\(token)")
                    }
                }
            default:
                errors.append("TRADE 段未识别键 \(key)")
            }
        }
        return (spec, errors)
    }

    /// 序列化 TRADE: 段正文（不含 "TRADE:" 标记行，末尾不带换行）
    /// 只输出非 nil 的键，顺序固定：DIRECTION → QTY → AMOUNT → PRICETYPE → OFFSETTICKS → VALIDITY → EXPIRES → ACCOUNTS
    static func serialize(_ spec: StrategyTradeSpec) -> String {
        var lines: [String] = []
        if let d = spec.direction {
            lines.append("DIRECTION=\(d.rawValue.uppercased())")
        }
        if let q = spec.qty {
            lines.append("QTY=\(q)")
        }
        if let a = spec.amount {
            lines.append("AMOUNT=\(amountText(a))")
        }
        if let p = spec.priceType {
            lines.append("PRICETYPE=\(p.rawValue.uppercased())")
        }
        if let o = spec.offsetTicks {
            lines.append("OFFSETTICKS=\(o)")
        }
        if let v = spec.validity {
            lines.append("VALIDITY=\(validityText(v))")
        }
        if let e = spec.expiresAt {
            lines.append("EXPIRES=\(text(from: e))")
        }
        if !spec.accountIDs.isEmpty {
            lines.append("ACCOUNTS=" + spec.accountIDs.map { $0.uuidString }.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// 从规则行内取指令覆盖（ORD* 保留键）
    static func override(in call: StrategyRuleCall) -> StrategyDirectiveOverride {
        var o = StrategyDirectiveOverride()
        if let v = value(call, "ORDDIR") { o.dir = direction(from: v) }
        if let v = value(call, "ORDQTY") { o.qty = Int(v) }
        if let v = value(call, "ORDAMT") { o.amount = Double(v) }
        if let v = value(call, "ORDPT") { o.priceType = priceType(from: v) }
        if let v = value(call, "ORDOFF") { o.offsetTicks = Int(v) }
        return o
    }

    /// 日期文本 → Date（YYYY-MM-DD）
    static func date(from text: String) -> Date? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return dateFormatter().date(from: t)
    }

    /// Date → 日期文本（YYYY-MM-DD）
    static func text(from date: Date) -> String {
        dateFormatter().string(from: date)
    }

    // MARK: - 取值与格式

    /// 取参数的非空原文
    private static func value(_ call: StrategyRuleCall, _ key: String) -> String? {
        guard let s = call.params[key], !s.isEmpty else { return nil }
        return s
    }

    /// 方向文本解析：容忍 rawValue 大小写差异（buy / BUY）
    private static func direction(from text: String) -> SimOrderDirection? {
        SimOrderDirection(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// 报价方式文本解析：容忍 rawValue 大小写差异（limit / LIMIT）
    private static func priceType(from text: String) -> SimPriceType? {
        SimPriceType(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// 有效期文本解析：DAY → .day、LONG → .longTerm、DATE → .untilDate（同时容忍 rawValue 大小写差异）
    private static func validity(from text: String) -> SimCondValidity? {
        switch text.trimmingCharacters(in: .whitespaces).uppercased() {
        case "DAY":               return .day
        case "LONG", "LONGTERM":  return .longTerm
        case "DATE", "UNTILDATE": return .untilDate
        default:                  return nil
        }
    }

    /// 有效期序列化文本
    private static func validityText(_ v: SimCondValidity) -> String {
        switch v {
        case .day:       return "DAY"
        case .longTerm:  return "LONG"
        case .untilDate: return "DATE"
        }
    }

    /// 金额文案：整数不带小数，非整数用最短可回读表示
    private static func amountText(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(v)
    }

    /// 全角符号归一化（等号 / 逗号 / 冒号）
    private static func normalize(_ s: String) -> String {
        var r = s
        let pairs: [(String, String)] = [("＝", "="), ("，", ","), ("：", ":")]
        for (from, to) in pairs {
            r = r.replacingOccurrences(of: from, with: to)
        }
        return r
    }

    private static func dateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }
}
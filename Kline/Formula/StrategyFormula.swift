//
//  StrategyFormula.swift
//  Kline
//
//  交易策略公式（PICK + RULES）：规则目录、RULES 解析、静态校验与语义预览。
//
//  Created by 孙楚昆 on 2026/9/20.
//

import Foundation

// MARK: - 规则种类

/// 交易策略规则种类：与条件单 `SimCondKind` 一一对应（rawValue 即 RULES 段里的关键字）
///
/// 对应关系（仅命名映射，本文件不引用 SimCondKind / SimStore，也不生成真实条件单）：
/// - `price`     → `SimCondKind.price`     价格条件
/// - `stopLoss`  → `SimCondKind.stopLoss`  止盈止损（OCO）
/// - `trailing`  → `SimCondKind.trailing`  回落卖出 / 反弹买入
/// - `time`      → `SimCondKind.time`      时间条件
/// - `changePct` → `SimCondKind.changePct` 涨跌幅条件
/// - `maCross`   → `SimCondKind.maCross`   均线条件
/// - `grid`      → `SimCondKind.grid`      网格交易
/// - `batch`     → `SimCondKind.batch`     分批建仓 / 分批卖出
enum StrategyRuleKind: String, CaseIterable, Identifiable {
    case price = "PRICE"            // 价格条件          → SimCondKind.price
    case stopLoss = "STOP_LOSS"     // 止盈止损（OCO）    → SimCondKind.stopLoss
    case trailing = "TRAILING"      // 回落卖出 / 反弹买入 → SimCondKind.trailing
    case time = "TIME"              // 时间条件          → SimCondKind.time
    case changePct = "CHANGE_PCT"   // 涨跌幅条件        → SimCondKind.changePct
    case maCross = "MA_CROSS"       // 均线条件          → SimCondKind.maCross
    case grid = "GRID"              // 网格交易          → SimCondKind.grid
    case batch = "BATCH"            // 分批建仓 / 卖出    → SimCondKind.batch

    var id: String { rawValue }

    /// 规则中文名（编辑器下拉与校验文案使用）
    var title: String {
        switch self {
        case .price:     return "价格条件"
        case .stopLoss:  return "止盈止损"
        case .trailing:  return "回落卖出"
        case .time:      return "时间条件"
        case .changePct: return "涨跌幅"
        case .maCross:   return "均线条件"
        case .grid:      return "网格交易"
        case .batch:     return "分批建仓"
        }
    }

    /// 对应条件单的中文名（用于编辑器与预览里说明映射关系）
    var conditionOrderTitle: String {
        switch self {
        case .price:     return "价格条件"
        case .stopLoss:  return "止盈止损（OCO）"
        case .trailing:  return "回落卖出 / 反弹买入"
        case .time:      return "时间条件"
        case .changePct: return "涨跌幅条件"
        case .maCross:   return "均线条件"
        case .grid:      return "网格交易"
        case .batch:     return "分批建仓 / 分批卖出"
        }
    }
}

// MARK: - 参数规格

/// 参数值类型（供编辑器动态渲染输入控件）
enum StrategyParamType {
    case number      // 普通数值（价格、数量）
    case percent     // 百分比数值（不带 % 号输入）
    case integer     // 整数
    case text        // 文本（如日期 YYYY-MM-DD、时刻 HH:MM）
    case option      // 枚举（取值见 options，编辑器用分段/下拉）
}

/// 单个参数的规格
struct StrategyParamSpec {
    var key: String            // 参数键，如 "PROFIT"
    var title: String          // 中文标签，如 "止盈"
    var type: StrategyParamType
    var isOptional: Bool
    var placeholder: String
    var options: [String] = [] // type == .option 时的可选值（如 ["COST", "LAST"]）；其他类型为空数组
    var unit: String = ""      // 单位文案（如 "%"、"元"、"股"）；无单位传 ""
}

/// 规则目录：类型 → 参数规格清单（编辑器按此动态渲染，校验也按此判定）
///
/// 参数键与 `SimCondParams` 字段的映射关系（只做命名映射，不引用该类型）：
/// - `PRICE`     ：`OP`→ 触发方向（true 对应 ">="，false 对应 "<="，即 `compareUp`）、`VALUE`→ `triggerPrice`
/// - `STOP_LOSS` ：`MODE`→ `baseMode`（PCT→.percent、PRICE→.price）、`BASE`→ 基准价取值语义（COST 成本价 / LAST 最新价，
///                 对应 `basePrice`）、`PROFIT`→ `takeProfitPrice`、`LOSS`→ `stopLossPrice`
/// - `TRAILING`  ：`PCT`→ `trailPct`、`FLOOR`→ `floorPrice`（配合 `floorEnabled`）
/// - `TIME`      ：`DATE` + `AT` → `fireDate`
/// - `CHANGE_PCT`：`PCT`→ `changeThreshold`（正=涨、负=跌）、`OP`→ 触发方向（>= / <=）
/// - `MA_CROSS`  ：`PERIOD`→ `maPeriod`、`DIR`→ `maAbove`（UP→true 上穿、DOWN→false 下破）
/// - `GRID`      ：`BASE`→ `gridBase`、`LOW`→ `gridLower`、`HIGH`→ `gridUpper`、`STEP`→ `gridStepPct`、
///                 `QTY`→ `gridQtyPerLevel`、`MULT`→ `gridMultiplier`
/// - `BATCH`     ：`TOTAL`→ `batchTotalQty`、`COUNT`→ `batchCount`、`FIRST`→ `batchFirstPrice`、`GAP`→ `batchStepPct`
enum StrategyRuleCatalog {

    /// 某类型的参数规格清单（顺序即序列化顺序）
    static func specs(for kind: StrategyRuleKind) -> [StrategyParamSpec] {
        switch kind {
        case .price:
            return [
                StrategyParamSpec(key: "OP", title: "比较方向", type: .option, isOptional: false,
                                  placeholder: ">=", options: [">=", "<="], unit: ""),
                StrategyParamSpec(key: "VALUE", title: "触发价", type: .number, isOptional: false,
                                  placeholder: "1480.00", unit: "元")
            ]
        case .stopLoss:
            // PROFIT / LOSS 在 MODE=PCT 时按百分比填写（.percent），MODE=PRICE 时按价格填写（.number）
            return [
                StrategyParamSpec(key: "BASE", title: "基准", type: .option, isOptional: true,
                                  placeholder: "COST", options: ["COST", "LAST"], unit: ""),
                StrategyParamSpec(key: "MODE", title: "基准方式", type: .option, isOptional: true,
                                  placeholder: "PCT", options: ["PCT", "PRICE"], unit: ""),
                StrategyParamSpec(key: "PROFIT", title: "止盈", type: .percent, isOptional: true,
                                  placeholder: "10", options: [], unit: "%"),
                StrategyParamSpec(key: "LOSS", title: "止损", type: .percent, isOptional: true,
                                  placeholder: "5", options: [], unit: "%")
            ]
        case .trailing:
            return [
                StrategyParamSpec(key: "PCT", title: "回落幅度", type: .percent, isOptional: false,
                                  placeholder: "3", options: [], unit: "%"),
                StrategyParamSpec(key: "FLOOR", title: "保底价", type: .number, isOptional: true,
                                  placeholder: "12.00", options: [], unit: "元")
            ]
        case .time:
            return [
                StrategyParamSpec(key: "DATE", title: "日期", type: .text, isOptional: false,
                                  placeholder: "2026-10-01", options: [], unit: ""),
                StrategyParamSpec(key: "AT", title: "时刻", type: .text, isOptional: true,
                                  placeholder: "09:30", options: [], unit: "")
            ]
        case .changePct:
            return [
                StrategyParamSpec(key: "PCT", title: "涨跌幅", type: .percent, isOptional: false,
                                  placeholder: "5", options: [], unit: "%"),
                StrategyParamSpec(key: "OP", title: "比较方向", type: .option, isOptional: true,
                                  placeholder: ">=", options: [">=", "<="], unit: "")
            ]
        case .maCross:
            return [
                StrategyParamSpec(key: "PERIOD", title: "周期", type: .option, isOptional: false,
                                  placeholder: "20", options: ["5", "10", "20", "60"], unit: "日"),
                StrategyParamSpec(key: "DIR", title: "方向", type: .option, isOptional: false,
                                  placeholder: "UP", options: ["UP", "DOWN"], unit: "")
            ]
        case .grid:
            return [
                StrategyParamSpec(key: "BASE", title: "基准价", type: .number, isOptional: false,
                                  placeholder: "14.60", options: [], unit: "元"),
                StrategyParamSpec(key: "LOW", title: "区间下界", type: .number, isOptional: false,
                                  placeholder: "13.50", options: [], unit: "元"),
                StrategyParamSpec(key: "HIGH", title: "区间上界", type: .number, isOptional: false,
                                  placeholder: "15.80", options: [], unit: "元"),
                StrategyParamSpec(key: "STEP", title: "间距", type: .percent, isOptional: false,
                                  placeholder: "1.5", options: [], unit: "%"),
                StrategyParamSpec(key: "QTY", title: "每格股数", type: .integer, isOptional: false,
                                  placeholder: "300", options: [], unit: "股"),
                StrategyParamSpec(key: "MULT", title: "倍数", type: .number, isOptional: true,
                                  placeholder: "2", options: [], unit: "倍")
            ]
        case .batch:
            return [
                StrategyParamSpec(key: "TOTAL", title: "总数量", type: .integer, isOptional: false,
                                  placeholder: "3000", options: [], unit: "股"),
                StrategyParamSpec(key: "COUNT", title: "批数", type: .integer, isOptional: false,
                                  placeholder: "3", options: [], unit: "批"),
                StrategyParamSpec(key: "FIRST", title: "首批价", type: .number, isOptional: false,
                                  placeholder: "14.90", options: [], unit: "元"),
                StrategyParamSpec(key: "GAP", title: "每批价差", type: .number, isOptional: false,
                                  placeholder: "0.30", options: [], unit: "元")
            ]
        }
    }

    /// 参数键集合（校验「未识别参数」用）
    static func knownKeys(for kind: StrategyRuleKind) -> Set<String> {
        Set(specs(for: kind).map { $0.key })
    }
}

// MARK: - 规则调用

/// 一条已解析的规则
struct StrategyRuleCall: Equatable {
    var kind: StrategyRuleKind
    var params: [String: String]   // 键大写，值保留用户原文
    var raw: String                // 原始行文本（编辑器里可回显）
    /// 该规则在 RULES 段中的行号（从 1 起）；用于校验报错定位，0 表示未知（如编辑器新建尚未落地的行）
    var line: Int = 0

    /// 相等性只比业务字段（类型 / 参数 / 原文），行号不参与比较，避免编辑器重建出的行被误判为已修改
    static func == (lhs: StrategyRuleCall, rhs: StrategyRuleCall) -> Bool {
        lhs.kind == rhs.kind && lhs.params == rhs.params && lhs.raw == rhs.raw
    }
}

// MARK: - RULES 段解析器

/// RULES 段解析器
enum StrategyRuleParser {

    /// 解析多行 RULES 文本：返回规则数组 + 中文错误清单（错误文案带行号，如「第 1 行：未知规则 PRICE2」）
    /// 规则：空行与 `{...}` 注释行跳过；行格式 `KEYWORD(KEY=VAL, KEY=VAL)`，也容忍 `KEYWORD(KEY = VAL)`、
    /// 中文全角逗号「，」与全角括号；值里的空格去掉；未知关键字 / 未识别参数键 / 括号不闭合 → 报错
    /// （`ORDDIR` / `ORDQTY` / `ORDAMT` / `ORDPT` / `ORDOFF` 为交易指令覆盖保留键，照常收进 params 且不报错）
    static func parse(lines: String) -> (rules: [StrategyRuleCall], errors: [String]) {
        var rules: [StrategyRuleCall] = []
        var errors: [String] = []

        let rawLines = lines.components(separatedBy: .newlines)
        for (idx, raw) in rawLines.enumerated() {
            let n = idx + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }          // 空行跳过
            if trimmed.hasPrefix("{") { continue }   // {…} 注释行跳过

            // 全角括号 / 逗号 / 等号归一化后再解析
            let normalized = normalize(trimmed)

            guard let open = normalized.firstIndex(of: "(") else {
                errors.append("第 \(n) 行：规则格式应为 KEYWORD(KEY=VAL, ...)")
                continue
            }
            guard normalized.hasSuffix(")") else {
                errors.append("第 \(n) 行：括号不闭合")
                continue
            }

            let keywordRaw = String(normalized[normalized.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            let keyword = keywordRaw.uppercased()
            guard let kind = StrategyRuleKind(rawValue: keyword) else {
                let shown = keywordRaw.isEmpty ? trimmed : keywordRaw
                errors.append("第 \(n) 行：未知规则 \(shown)")
                continue
            }

            let innerStart = normalized.index(after: open)
            let innerEnd = normalized.index(before: normalized.endIndex)
            let inner = innerStart <= innerEnd ? String(normalized[innerStart..<innerEnd]) : ""

            var params: [String: String] = [:]
            let known = StrategyRuleCatalog.knownKeys(for: kind)
            for token in inner.components(separatedBy: ",") {
                let t = token.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }            // 容忍尾随逗号
                guard let eq = t.firstIndex(of: "=") else {
                    errors.append("第 \(n) 行：参数格式应为 KEY=VAL（\(t)）")
                    continue
                }
                let key = String(t[t.startIndex..<eq]).trimmingCharacters(in: .whitespaces).uppercased()
                let val = String(t[t.index(after: eq)...])
                    .replacingOccurrences(of: " ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if key.isEmpty {
                    errors.append("第 \(n) 行：参数格式应为 KEY=VAL（\(t)）")
                    continue
                }
                if !known.contains(key) && !StrategyTradeParser.isReservedKey(key) {
                    errors.append("第 \(n) 行：\(kind.title) 未识别参数 \(key)")
                    continue
                }
                params[key] = val
            }

            rules.append(StrategyRuleCall(kind: kind, params: params, raw: trimmed, line: n))
        }
        return (rules, errors)
    }

    /// 序列化一条规则：`STOP_LOSS(BASE=COST, MODE=PCT, PROFIT=10, LOSS=5)`（按 specs 顺序）
    /// 交易指令覆盖保留键（ORD*）按固定顺序追加在末尾，保证 parse → line → parse 可逆
    static func line(for call: StrategyRuleCall) -> String {
        var parts: [String] = []
        for spec in StrategyRuleCatalog.specs(for: call.kind) {
            guard let v = call.params[spec.key], !v.isEmpty else { continue }
            parts.append("\(spec.key)=\(v)")
        }
        for key in StrategyTradeParser.reservedKeys {
            guard let v = call.params[key], !v.isEmpty else { continue }
            parts.append("\(key)=\(v)")
        }
        return "\(call.kind.rawValue)(\(parts.joined(separator: ", ")))"
    }

    /// 全角符号归一化（括号 / 逗号 / 等号 / 减号）
    private static func normalize(_ s: String) -> String {
        var r = s
        let pairs: [(String, String)] = [("（", "("), ("）", ")"), ("，", ","), ("＝", "="), ("－", "-"), ("：", ":")]
        for (from, to) in pairs {
            r = r.replacingOccurrences(of: from, with: to)
        }
        return r
    }
}

// MARK: - 策略校验

/// 策略校验（静态校验，不做任何求值/下单）
enum StrategyValidator {

    /// 校验整份策略文档；返回中文错误清单（空数组 = 通过）
    /// - Parameters:
    ///   - pickerExists: PICKREF 指向的选股公式是否存在于公式库（无 PICKREF 时传 false 无影响）
    ///   - pickSyntaxError: 内嵌 PICK 段的语法错误（由调用方用 TDXFormulaEngine 试算得到，nil = 语法通过或无内嵌）
    static func validate(doc: FormulaDoc, pickerExists: Bool, pickSyntaxError: String? = nil) -> [String] {
        var errors: [String] = []

        let body = doc.pickBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = (doc.pickRef ?? "").trimmingCharacters(in: .whitespaces)
        let hasBody = !body.isEmpty
        let hasRef = !ref.isEmpty

        // 1. 选股条件缺失
        if !hasBody && !hasRef {
            errors.append("策略需要选股条件：请填写内嵌选股公式，或引用一个选股公式")
        }
        // 2. PICKREF 与内嵌选股条件同时存在
        if hasBody && hasRef {
            errors.append("PICKREF 与内嵌选股条件只能二选一，请保留其一")
        }
        // 3. PICKREF 指向的选股公式不存在
        if hasRef && !pickerExists {
            errors.append("引用的选股公式已不存在，请重新选择或改用内嵌选股条件")
        }
        // 4. 内嵌选股公式语法错误
        if let e = pickSyntaxError {
            errors.append("内嵌选股公式语法错误：\(e)")
        }

        // 5. RULES 段为空
        let rulesText = doc.rules.trimmingCharacters(in: .whitespacesAndNewlines)
        if rulesText.isEmpty {
            errors.append("策略至少需要一条交易规则")
        }

        // 6. 解析错误原样带上（已含行号）
        let (calls, parseErrors) = StrategyRuleParser.parse(lines: doc.rules)
        errors.append(contentsOf: parseErrors)

        // 7. 同类型规则重复声明（行号取后出现的那一行）
        for (i, c) in calls.enumerated() {
            let duplicated = calls[0..<i].contains { $0.kind == c.kind }
            if duplicated {
                errors.append("第 \(c.line) 行：\(c.kind.title) 规则重复声明，请保留其一")
            }
        }

        for c in calls {
            // 12. 必填参数缺失
            for spec in StrategyRuleCatalog.specs(for: c.kind) where !spec.isOptional {
                let v = c.params[spec.key]?.trimmingCharacters(in: .whitespaces) ?? ""
                if v.isEmpty {
                    errors.append("第 \(c.line) 行：\(c.kind.title) 缺少参数 \(spec.key)")
                }
            }
            // 11a. 数值型参数填了非数字
            for spec in StrategyRuleCatalog.specs(for: c.kind) {
                guard let raw = c.params[spec.key], !raw.isEmpty else { continue }
                switch spec.type {
                case .number, .percent:
                    if Double(raw) == nil { errors.append("\(spec.title) 需要填数字") }
                case .integer:
                    if Int(raw) == nil { errors.append("\(spec.title) 需要填数字") }
                case .text, .option:
                    break
                }
            }
            // 8 / 9 / 11b. 各类型的语义与取值范围
            switch c.kind {
            case .stopLoss:
                let profit = doubleValue(c, "PROFIT")
                let loss = doubleValue(c, "LOSS")
                if profit == nil && loss == nil {
                    errors.append("止盈止损至少需要设置止盈或止损之一")
                }
                if let profit, profit <= 0 { errors.append("止盈 / 止损值需大于 0") }
                if let loss, loss <= 0 { errors.append("止盈 / 止损值需大于 0") }
            case .trailing:
                if let v = doubleValue(c, "PCT"), v <= 0 { errors.append("幅度需大于 0") }
            case .changePct:
                if let v = doubleValue(c, "PCT"), v <= 0 { errors.append("幅度需大于 0") }
            case .maCross:
                if let raw = c.params["PERIOD"], !raw.isEmpty {
                    let valid = Int(raw).map { [5, 10, 20, 60].contains($0) } ?? false
                    if !valid { errors.append("均线周期只支持 5 / 10 / 20 / 60") }
                }
            case .grid:
                if let low = doubleValue(c, "LOW"), let high = doubleValue(c, "HIGH"), low >= high {
                    errors.append("网格价格区间下界不得高于上界")
                }
                if let step = doubleValue(c, "STEP"), step <= 0 { errors.append("网格间距需大于 0") }
                if let mult = doubleValue(c, "MULT"), mult < 1 || mult > 5 {
                    errors.append("倍数委托需在 1~5 之间")
                }
            case .batch:
                if let n = intValue(c, "COUNT"), n < 2 || n > 5 {
                    errors.append("分批笔数需在 2~5 之间")
                }
            case .price, .time:
                break
            }
        }

        // 10. 网格交易与分批建仓并存
        let hasGrid = calls.contains { $0.kind == .grid }
        let hasBatch = calls.contains { $0.kind == .batch }
        if hasGrid && hasBatch {
            errors.append("网格交易与分批建仓不宜同一策略并存，请保留其一")
        }

        // 13. 交易指令（TRADE 段）与逐规则指令覆盖（仅策略文档）
        if doc.kind == .strategy {
            let trade = doc.trade
            if !trade.isEmpty {
                if trade.direction == nil {
                    errors.append("请选择交易方向")
                }
                if trade.qty != nil && trade.amount != nil {
                    errors.append("交易指令的数量与金额只能二选一")
                }
                if let q = trade.qty, q % 100 != 0 {
                    errors.append("交易指令数量需为 100 股的整数倍")
                }
                if let a = trade.amount, a <= 0 {
                    errors.append("交易指令金额需大于 0")
                }
                if trade.priceType == .limit && trade.offsetTicks == nil {
                    errors.append("限价委托需设置偏移档次（OFFSETTICKS）")
                }
                if trade.validity == .untilDate && trade.expiresAt == nil {
                    errors.append("指定日期有效期需设置到期日（EXPIRES）")
                }
            }
            // 逐规则覆盖：委托数量整手 / 数量与金额互斥（账户为空只提示不阻断，不在校验里报错）
            for c in calls {
                let o = StrategyTradeParser.override(in: c)
                if o.isEmpty { continue }
                let prefix = c.line > 0 ? "第 \(c.line) 行：" : ""
                if let q = o.qty, q % 100 != 0 {
                    errors.append("\(prefix)委托数量需为 100 股的整数倍")
                }
                if o.qty != nil && o.amount != nil {
                    errors.append("\(prefix)委托数量与金额只能二选一")
                }
            }
        }

        return errors
    }

    /// 取参数的非空原文
    private static func value(_ c: StrategyRuleCall, _ key: String) -> String? {
        guard let s = c.params[key], !s.isEmpty else { return nil }
        return s
    }

    /// 取数值型参数（非数字返回 nil）
    private static func doubleValue(_ c: StrategyRuleCall, _ key: String) -> Double? {
        guard let s = value(c, key) else { return nil }
        return Double(s)
    }

    /// 取整数型参数（非整数返回 nil）
    private static func intValue(_ c: StrategyRuleCall, _ key: String) -> Int? {
        guard let s = value(c, key) else { return nil }
        return Int(s)
    }
}

// MARK: - 语义预览

/// 语义预览
enum StrategyPreview {

    /// 固定补充说明（编辑器预览区必须同时展示）
    static let executionNotice = "触发后的下单指令（方向 / 数量 / 报价方式）本阶段未定义，留待接入执行阶段"

    /// 一句话自然语言预览：选股条件摘要 + 各条规则的触发语义
    static func summary(doc: FormulaDoc, pickerName: String?) -> String {
        let pick = pickSummary(doc: doc, pickerName: pickerName)
        let (calls, _) = StrategyRuleParser.parse(lines: doc.rules)
        guard !calls.isEmpty else {
            return "对命中【\(pick)】的标的：暂无交易规则。"
        }
        let marks = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩"]
        let items = calls.enumerated().map { (i, c) -> String in
            let mark = i < marks.count ? marks[i] : "(\(i + 1))"
            return "\(mark) \(triggerText(c))"
        }
        return "对命中【\(pick)】的标的：" + items.joined(separator: "；") + "。"
    }

    /// 选股条件摘要（单独可用）
    static func pickSummary(doc: FormulaDoc, pickerName: String?) -> String {
        let ref = (doc.pickRef ?? "").trimmingCharacters(in: .whitespaces)
        if !ref.isEmpty {
            let name: String
            if let n = pickerName, !n.isEmpty {
                name = n
            } else {
                name = "已删除的公式"
            }
            return "引用选股公式：\(name)"
        }

        let body = doc.pickBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "内嵌选股条件：未填写" }

        let oneLine = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let truncated = oneLine.count > 24 ? String(oneLine.prefix(24)) + "…" : oneLine
        return "内嵌选股条件：\(truncated)"
    }

    /// 交易指令摘要（单独可用）：方向 / 数量或金额 / 报价方式 / 有效期 / 绑定账户数；未配置时返回提示
    static func tradeSummary(doc: FormulaDoc) -> String {
        let trade = doc.trade
        guard !trade.isEmpty else { return "未配置交易指令" }

        var parts: [String] = []
        // 方向 + 数量（或金额：按最新价折算）
        let qtyOrAmount: String? = trade.qty.map { "\($0) 股" }
            ?? trade.amount.map { "\(num($0)) 元（按最新价折算）" }
        if let d = trade.direction {
            parts.append(qtyOrAmount.map { "\(d.title) \($0)" } ?? d.title)
        } else if let qtyOrAmount {
            parts.append(qtyOrAmount)
        }
        // 报价方式
        if let pt = trade.priceType {
            if pt == .limit, let off = trade.offsetTicks {
                parts.append("限价委托（触发价 \(offsetText(off))）")
            } else {
                parts.append(pt == .limit ? "限价委托" : "市价委托")
            }
        }
        // 有效期
        if let v = trade.validity {
            switch v {
            case .day:
                parts.append("当日有效")
            case .longTerm:
                parts.append("长期有效")
            case .untilDate:
                if let e = trade.expiresAt {
                    parts.append("有效期至 \(StrategyTradeParser.text(from: e))")
                } else {
                    parts.append("指定日期有效")
                }
            }
        } else if let e = trade.expiresAt {
            parts.append("有效期至 \(StrategyTradeParser.text(from: e))")
        }
        // 绑定账户数
        if !trade.accountIDs.isEmpty {
            parts.append("绑定 \(trade.accountIDs.count) 个账户")
        }
        return parts.isEmpty ? "未配置交易指令" : parts.joined(separator: " · ")
    }

    // MARK: - 单条规则语义

    /// 一条规则的触发语义（按 MODE / OP / DIR 生成中文）；internal 供策略详情页逐条复用
    static func triggerText(_ c: StrategyRuleCall) -> String {
        switch c.kind {
        case .price:
            let symbol = (value(c, "OP") == "<=") ? "≤" : "≥"
            return "现价 \(symbol) \(priceText(c, "VALUE")) 时触发"

        case .stopLoss:
            let byPrice = (value(c, "MODE")?.uppercased() == "PRICE")
            let profit = doubleValue(c, "PROFIT")
            let loss = doubleValue(c, "LOSS")
            var parts: [String] = []
            if byPrice {
                if let v = profit { parts.append("止盈价 \(price(v))") }
                if let v = loss { parts.append("止损价 \(price(v))") }
            } else {
                if let v = profit { parts.append("止盈 \(percentSigned(v, plus: true))") }
                if let v = loss { parts.append("止损 \(percentSigned(v, plus: false))") }
            }
            if parts.isEmpty { return "止盈止损（未设置止盈或止损）" }
            if parts.count == 1 { return parts[0] }
            return parts.joined(separator: " 或 ") + "（先到者为准）"

        case .trailing:
            var s = "自突破后回撤 \(numText(c, "PCT"))% 触发"
            if let f = doubleValue(c, "FLOOR") { s += "（保底价 \(price(f))）" }
            return s

        case .time:
            let date = value(c, "DATE") ?? "--"
            if let at = value(c, "AT") { return "\(date) \(at) 触发" }
            return "\(date) 触发"

        case .changePct:
            let v = doubleValue(c, "PCT") ?? 0
            let symbol = (value(c, "OP") == "<=") ? "≤" : "≥"
            let word = v < 0 ? "跌幅" : "涨跌幅"
            return "当日\(word) \(symbol) \(num(abs(v)))% 触发"

        case .maCross:
            let dir = value(c, "DIR")?.uppercased() ?? "UP"
            let head = (dir == "DOWN") ? "下破" : "上穿"
            let period = value(c, "PERIOD") ?? "--"
            return "\(head) MA\(period) 触发"

        case .grid:
            var s = "网格区间 \(priceText(c, "LOW")) ~ \(priceText(c, "HIGH"))"
            s += "，每 \(numText(c, "STEP"))% 一档，每档 \(intText(c, "QTY")) 股"
            if let m = doubleValue(c, "MULT") { s += "，倍数 \(num(m))" }
            return s

        case .batch:
            let count = intText(c, "COUNT")
            return "分 \(count) 批建仓：首批 \(priceText(c, "FIRST"))，每批价差 \(priceText(c, "GAP"))"
        }
    }

    // MARK: - 取值与格式化

    private static func value(_ c: StrategyRuleCall, _ key: String) -> String? {
        guard let s = c.params[key], !s.isEmpty else { return nil }
        return s
    }

    private static func doubleValue(_ c: StrategyRuleCall, _ key: String) -> Double? {
        guard let s = value(c, key) else { return nil }
        return Double(s)
    }

    private static func intValue(_ c: StrategyRuleCall, _ key: String) -> Int? {
        guard let s = value(c, key) else { return nil }
        return Int(s)
    }

    /// 价格：两位小数
    private static func price(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    /// 价格参数文案：可解析按两位小数，否则回显原文
    private static func priceText(_ c: StrategyRuleCall, _ key: String) -> String {
        if let d = doubleValue(c, key) { return price(d) }
        return value(c, key) ?? "--"
    }

    /// 百分比/普通数值文案：不带无意义小数（3 → "3"，3.5 → "3.5"）
    private static func numText(_ c: StrategyRuleCall, _ key: String) -> String {
        if let d = doubleValue(c, key) { return num(d) }
        return value(c, key) ?? "--"
    }

    /// 整数文案：可解析按整数，否则回显原文
    private static func intText(_ c: StrategyRuleCall, _ key: String) -> String {
        if let i = intValue(c, key) { return "\(i)" }
        return value(c, key) ?? "--"
    }

    /// 数值格式化：整数不带小数，非整数最多两位且去掉尾随 0
    private static func num(_ v: Double) -> String {
        if v == v.rounded() { return String(format: "%.0f", v) }
        return String(format: "%g", v)
    }

    /// 带符号百分比：plus 为 true 时正数显示 "+"，为 false 时正数显示 "−"（止盈 / 止损语义）
    private static func percentSigned(_ v: Double, plus: Bool) -> String {
        let magnitude = num(abs(v))
        if v < 0 { return "−\(magnitude)%" }
        return "\(plus ? "+" : "−")\(magnitude)%"
    }

    /// 偏移档次文案：正数带 "+"，如 "+2 档"
    private static func offsetText(_ n: Int) -> String {
        n >= 0 ? "+\(n) 档" : "\(n) 档"
    }
}
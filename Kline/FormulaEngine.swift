//
//  FormulaEngine.swift
//  Kline
//
//  通达信风格公式引擎：词法分析 → 语法分析 → 求值。
//  支持主图叠加指标（用户自定义），求值结果为逐根 K 线的序列。
//
//  Created by 孙楚昆 on 2026/8/16.
//

import Foundation

// MARK: - 词法

enum TDXToken: Equatable {
    case number(Double)
    case identifier(String)
    case plus, minus, star, slash
    case assignAssign   // :=
    case assignOutput   // :
    case semicolon
    case comma
    case lparen, rparen
    case lt, gt, le, ge, eq, ne
}

struct TDXLexer {
    private let chars: [Character]
    private var pos = 0

    init(_ source: String) {
        self.chars = Array(source)
    }

    mutating func tokenize() throws -> [TDXToken] {
        var tokens: [TDXToken] = []
        while let tk = try next() { tokens.append(tk) }
        return tokens
    }

    private mutating func next() throws -> TDXToken? {
        skipWhitespaceAndComments()
        guard pos < chars.count else { return nil }
        let c = chars[pos]

        // 数字
        if c.isNumber || (c == "." && pos + 1 < chars.count && chars[pos + 1].isNumber) {
            return .number(readNumber())
        }
        // 标识符 / 关键字
        if c.isLetter || c == "_" {
            return .identifier(readIdentifier())
        }
        pos += 1
        switch c {
        case "+": return .plus
        case "-": return .minus
        case "*": return .star
        case "/": return .slash
        case ";": return .semicolon
        case ",": return .comma
        case "(": return .lparen
        case ")": return .rparen
        case "<":
            if peek() == "=" { pos += 1; return .le }
            if peek() == ">" { pos += 1; return .ne }
            return .lt
        case ">":
            if peek() == "=" { pos += 1; return .ge }
            return .gt
        case "=":
            // 通达信语义：单个 "=" 也是相等比较（"==" 同样支持）
            if peek() == "=" { pos += 1 }
            return .eq
        case ":":
            if peek() == "=" { pos += 1; return .assignAssign }
            return .assignOutput
        default:
            throw TDXEngineError.syntax("无法识别的字符 '\(c)'")
        }
    }

    private func peek() -> Character? {
        guard pos < chars.count else { return nil }
        return chars[pos]
    }

    private mutating func skipWhitespaceAndComments() {
        while pos < chars.count {
            let c = chars[pos]
            if c.isWhitespace || c == "\n" || c == "\r" || c == "\t" {
                pos += 1
            } else if c == "{" {
                // 块注释 {...}
                while pos < chars.count, chars[pos] != "}" { pos += 1 }
                if pos < chars.count { pos += 1 }
            } else {
                break
            }
        }
    }

    private mutating func readNumber() -> Double {
        var s = ""
        while pos < chars.count {
            let c = chars[pos]
            if c.isNumber || c == "." {
                s.append(c); pos += 1
            } else {
                break
            }
        }
        return Double(s) ?? 0
    }

    private mutating func readIdentifier() -> String {
        var s = ""
        while pos < chars.count {
            let c = chars[pos]
            if c.isLetter || c.isNumber || c == "_" {
                s.append(c); pos += 1
            } else {
                break
            }
        }
        return s
    }
}

// MARK: - 语法树

indirect enum TDXExpr {
    case number(Double)
    case variable(String)
    case unary(op: String, rhs: TDXExpr)
    case binary(op: String, lhs: TDXExpr, rhs: TDXExpr)
    case call(name: String, args: [TDXExpr])
}

struct TDXStatement {
    let name: String
    let output: Bool
    let expr: TDXExpr
    let options: [String]
}

enum TDXEngineError: Error, LocalizedError {
    case syntax(String)
    case semantic(String)
    var errorDescription: String? {
        switch self {
        case .syntax(let m), .semantic(let m): return m
        }
    }
}

// MARK: - 语法分析

struct TDXParser {
    private let tokens: [TDXToken]
    private var pos = 0

    init(tokens: [TDXToken]) {
        self.tokens = tokens
    }

    mutating func parse() throws -> [TDXStatement] {
        var stmts: [TDXStatement] = []
        while !isAtEnd {
            let stmt = try parseStatement()
            stmts.append(stmt)
            // 容错：忽略语句后多余的孤立逗号（如 VALUE:=SMA(X,M,1),;）
            while match(.comma) { }
            // 语句之间允许 0 或 1 个分号
            if match(.semicolon) {
                // 继续
            }
        }
        return stmts
    }

    private mutating func parseStatement() throws -> TDXStatement {
        let name = try consumeIdentifier("期望指标名称")
        if match(.assignOutput) {
            let expr = try parseExpr()
            // 输出线可带样式/颜色等选项：名字:表达式,DOTLINE,COLORRED,LINETHICK2;
            // 容错：表达式后出现孤立逗号（如 SMA(X,N,1),;）时忽略，避免解析失败
            var options: [String] = []
            while match(.comma) {
                if case .identifier(let s)? = peek() { pos += 1; options.append(s) } else { break }
            }
            return TDXStatement(name: name, output: true, expr: expr, options: options)
        } else if match(.assignAssign) {
            let expr = try parseExpr()
            return TDXStatement(name: name, output: false, expr: expr, options: [])
        } else {
            throw TDXEngineError.syntax("指标 '\(name)' 后缺少 ':' 或 ':='")
        }
    }

    // 表达式优先级从低到高
    private mutating func parseExpr() throws -> TDXExpr {
        try parseOr()
    }

    private mutating func parseOr() throws -> TDXExpr {
        var lhs = try parseAnd()
        while matchIdentifier("OR") {
            let rhs = try parseAnd()
            lhs = .binary(op: "or", lhs: lhs, rhs: rhs)
        }
        return lhs
    }

    private mutating func parseAnd() throws -> TDXExpr {
        var lhs = try parseNot()
        while matchIdentifier("AND") {
            let rhs = try parseNot()
            lhs = .binary(op: "and", lhs: lhs, rhs: rhs)
        }
        return lhs
    }

    private mutating func parseNot() throws -> TDXExpr {
        if matchIdentifier("NOT") {
            let rhs = try parseNot()
            return .unary(op: "not", rhs: rhs)
        }
        return try parseComparison()
    }

    private mutating func parseComparison() throws -> TDXExpr {
        var lhs = try parseAdditive()
        while true {
            let op: String?
            if match(.lt) { op = "<" }
            else if match(.gt) { op = ">" }
            else if match(.le) { op = "<=" }
            else if match(.ge) { op = ">=" }
            else if match(.eq) { op = "==" }
            else if match(.ne) { op = "!=" }
            else { op = nil }
            guard let o = op else { break }
            let rhs = try parseAdditive()
            lhs = .binary(op: o, lhs: lhs, rhs: rhs)
        }
        return lhs
    }

    private mutating func parseAdditive() throws -> TDXExpr {
        var lhs = try parseMultiplicative()
        while true {
            if match(.plus) {
                let rhs = try parseMultiplicative()
                lhs = .binary(op: "+", lhs: lhs, rhs: rhs)
            } else if match(.minus) {
                let rhs = try parseMultiplicative()
                lhs = .binary(op: "-", lhs: lhs, rhs: rhs)
            } else {
                break
            }
        }
        return lhs
    }

    private mutating func parseMultiplicative() throws -> TDXExpr {
        var lhs = try parseUnary()
        while true {
            if match(.star) {
                let rhs = try parseUnary()
                lhs = .binary(op: "*", lhs: lhs, rhs: rhs)
            } else if match(.slash) {
                let rhs = try parseUnary()
                lhs = .binary(op: "/", lhs: lhs, rhs: rhs)
            } else if isImplicitMulStart(peek()) {
                // 通达信隐式乘法：2HV 等价 2*HV、MA5( 等价 MA5*(、2(C-L) 等价 2*(C-L)
                let rhs = try parseUnary()
                lhs = .binary(op: "*", lhs: lhs, rhs: rhs)
            } else {
                break
            }
        }
        return lhs
    }

    /// 隐式乘法起始符：标识符、数字、左括号之后紧跟它们视为相乘
    /// （排除 AND/OR/NOT 逻辑关键字，避免 "0 AND X" 被误判为 "0*AND"）
    private func isImplicitMulStart(_ t: TDXToken?) -> Bool {
        switch t {
        case .identifier(let s):
            let up = s.uppercased()
            return up != "AND" && up != "OR" && up != "NOT"
        case .number, .lparen: return true
        default: return false
        }
    }

    private mutating func parseUnary() throws -> TDXExpr {
        if match(.minus) {
            let rhs = try parseUnary()
            return .unary(op: "-", rhs: rhs)
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> TDXExpr {
        guard !isAtEnd else { throw TDXEngineError.syntax("表达式不完整") }
        let token = tokens[pos]
        switch token {
        case .number(let v):
            pos += 1
            return .number(v)
        case .identifier(let name):
            pos += 1
            if match(.lparen) {
                var args: [TDXExpr] = []
                if !check(.rparen) {
                    args.append(try parseExpr())
                    while match(.comma) {
                        args.append(try parseExpr())
                    }
                }
                _ = try consume(.rparen, "函数 '\(name)' 缺少右括号 ')'")
                return .call(name: name, args: args)
            }
            return .variable(name)
        case .lparen:
            pos += 1
            let e = try parseExpr()
            _ = try consume(.rparen, "缺少右括号 ')'")
            return e
        default:
            throw TDXEngineError.syntax("非法的表达式起始符")
        }
    }

    // MARK: 工具

    private var isAtEnd: Bool { pos >= tokens.count }

    private func peek() -> TDXToken? {
        guard pos < tokens.count else { return nil }
        return tokens[pos]
    }

    private func check(_ t: TDXToken) -> Bool {
        peek() == t
    }

    private mutating func match(_ t: TDXToken) -> Bool {
        guard check(t) else { return false }
        pos += 1
        return true
    }

    private mutating func matchIdentifier(_ name: String) -> Bool {
        guard case .identifier(let s)? = peek(), s.uppercased() == name else { return false }
        pos += 1
        return true
    }

    private mutating func consume(_ t: TDXToken, _ msg: String) throws -> TDXToken {
        guard match(t) else { throw TDXEngineError.syntax(msg) }
        return t
    }

    private mutating func consumeIdentifier(_ msg: String) throws -> String {
        guard case .identifier(let s)? = peek() else { throw TDXEngineError.syntax(msg) }
        pos += 1
        return s
    }
}

// MARK: - 求值

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

/// 通达信公式求值器
struct TDXEvaluator {
    private let barCount: Int
    private let builtins: [String: [Double]]
    private var vars: [String: [Double]] = [:]
    private let outputValues: [Double]
    /// 最近一次 SAR 调用的红/绿方向（用于输出线红绿点）
    private var sarDirection: [Bool]?

    init(data: [KlineItem]) {
        // 数据需为“最新一根在末尾”的顺序，与图表索引对齐
        self.barCount = data.count
        let c = data.map(\.close)
        self.builtins = [
            "C": c,
            "CLOSE": c,
            "H": data.map(\.high),
            "HIGH": data.map(\.high),
            "L": data.map(\.low),
            "LOW": data.map(\.low),
            "O": data.map(\.open),
            "OPEN": data.map(\.open),
            "V": data.map(\.volume),
            "VOL": data.map(\.volume),
            "AMOUNT": data.map(\.turnover),
        ]
        self.outputValues = c
    }

    mutating func evaluate(stmts: [TDXStatement]) throws -> [TDXOutputLine] {
        var lines: [TDXOutputLine] = []
        for stmt in stmts {
            sarDirection = nil
            let value = try eval(stmt.expr)
            vars[stmt.name] = value
            if stmt.output {
                var line = TDXOutputLine(name: stmt.name, values: value)
                if let applied = applyOptions(stmt.options) {
                    line = applied(value, stmt.name)
                }
                // NOTEXT_ 前缀：不显示该线数值，仅保留线条
                line.hideValue = stmt.name.hasPrefix("NOTEXT_")
                // SAR 输出线：附加红/绿方向用于逐点着色
                if let dir = sarDirection,
                   case .call(let fnName, _) = stmt.expr,
                   fnName.uppercased() == "SAR" {
                    line.markerDirections = dir
                }
                lines.append(line)
            }
        }
        if lines.isEmpty {
            throw TDXEngineError.semantic("公式没有输出行（至少需要一行以 ':' 输出的指标）")
        }
        return lines
    }

    /// 解析输出线选项（类型/粗细/颜色/NOTEXT_），返回一个把样式写入输出线的闭包
    private func applyOptions(_ options: [String]) -> (([Double], String) -> TDXOutputLine)? {
        guard !options.isEmpty else { return nil }
        return { value, name in
            var line = TDXOutputLine(name: name, values: value)
            for opt in options {
                let up = opt.uppercased()
                switch up {
                case "DOTLINE": line.style = .dotline
                case "POINTDOT": line.style = .pointdot
                case "STICK": line.style = .stick
                case "COLORSTICK": line.style = .stick; line.colorStick = true
                case "NODRAW": line.style = .nodraw
                default:
                    if up.hasPrefix("COLOR"), let hex = TDXFormulaColor.hex(forOption: up) {
                        line.colorHex = hex
                    } else if up.hasPrefix("LINETHICK"), let n = Int(up.dropFirst("LINETHICK".count)) {
                        line.lineWidth = Double(min(max(n, 1), 8))
                    } else if up.hasPrefix("L"), up.count >= 2, let n = Int(up.dropFirst()), n <= 8 {
                        line.lineWidth = Double(min(max(n, 1), 8))
                    }
                }
            }
            return line
        }
    }

    // MARK: 表达式求值

    private mutating func eval(_ e: TDXExpr) throws -> [Double] {
        switch e {
        case .number(let n):
            return Array(repeating: n, count: barCount)

        case .variable(let name):
            let key = name.uppercased()
            if let v = vars[key] { return v }
            if let b = builtins[key] { return b }
            throw TDXEngineError.semantic("未定义的变量或函数：'\(name)'")

        case .unary(let op, let rhs):
            let a = try eval(rhs)
            switch op {
            case "-": return a.map { -$0 }
            case "not": return a.map { $0 == 0 ? 1 : 0 }
            default: throw TDXEngineError.semantic("未知一元运算 '\(op)'")
            }

        case .binary(let op, let lhs, let rhs):
            let a = try eval(lhs)
            let b = try eval(rhs)
            return try binary(op, a, b)

        case .call(let name, let args):
            return try evalCall(name, args)
        }
    }

    private func binary(_ op: String, _ a: [Double], _ b: [Double]) throws -> [Double] {
        var result = Array(repeating: 0.0, count: barCount)
        let offsetA = a.count - barCount
        let offsetB = b.count - barCount
        for i in 0..<barCount {
            let ai = offsetA + i
            let bi = offsetB + i
            let x = a[ai]
            let y = b[bi]
            switch op {
            case "+": result[i] = x + y
            case "-": result[i] = x - y
            case "*": result[i] = x * y
            case "/": result[i] = (y == 0) ? 0 : x / y   // 通达信语义：除零结果为 0（否则缺失数据区会变成 NaN）
            case "<": result[i] = x < y ? 1 : 0
            case ">": result[i] = x > y ? 1 : 0
            case "<=": result[i] = x <= y ? 1 : 0
            case ">=": result[i] = x >= y ? 1 : 0
            case "==": result[i] = x == y ? 1 : 0
            case "!=": result[i] = x != y ? 1 : 0
            case "and": result[i] = (x != 0 && y != 0) ? 1 : 0
            case "or": result[i] = (x != 0 || y != 0) ? 1 : 0
            default: throw TDXEngineError.semantic("未知二元运算 '\(op)'")
            }
        }
        return result
    }

    // MARK: 函数

    private mutating func evalCall(_ name: String, _ args: [TDXExpr]) throws -> [Double] {
        let fn = name.uppercased()
        let vals = try args.map { try eval($0) }

        func scalar(_ seq: [Double]) -> Double { seq.isEmpty ? 0 : seq[seq.count - 1] }

        switch fn {
        case "MA":
            try requireArgs(fn, vals, 2)
            return movingAverage(vals[0], period: Int(scalar(vals[1])), ema: false, weight: 1)
        case "EMA":
            try requireArgs(fn, vals, 2)
            return movingAverage(vals[0], period: Int(scalar(vals[1])), ema: true, weight: 1)
        case "SMA":
            // SMA(X, N, M) = (M*X + (N-M)*PREV) / N
            try requireArgs(fn, vals, 3)
            let period = Int(scalar(vals[1]))
            let m = scalar(vals[2])
            return sma(vals[0], period: period, m: m)
        case "REF":
            try requireArgs(fn, vals, 2)
            return reference(vals[0], n: Int(scalar(vals[1])))
        case "HHV":
            try requireArgs(fn, vals, 2)
            return rolling(vals[0], period: Int(scalar(vals[1])), kind: .max)
        case "LLV":
            try requireArgs(fn, vals, 2)
            return rolling(vals[0], period: Int(scalar(vals[1])), kind: .min)
        case "ABS":
            try requireArgs(fn, vals, 1)
            return vals[0].map { abs($0) }
        case "MAX":
            try requireArgs(fn, vals, 2)
            return elementWise(vals[0], vals[1]) { max($0, $1) }
        case "MIN":
            try requireArgs(fn, vals, 2)
            return elementWise(vals[0], vals[1]) { min($0, $1) }
        case "SUM":
            try requireArgs(fn, vals, 2)
            let period = Int(scalar(vals[1]))
            if period <= 0 { return total(vals[0]) }   // SUM(X,0)：从第一天起的全量累计
            return rolling(vals[0], period: period, kind: .sum)
        case "AVEDEV":
            try requireArgs(fn, vals, 2)
            return avedev(vals[0], period: Int(scalar(vals[1])))
        case "SAR":
            // SAR(步长, 极限)：基于 H/L 的抛物线转向，输出红/绿方向
            try requireArgs(fn, vals, 2)
            let step = scalar(vals[0])
            let maxStep = scalar(vals[1])
            let r = sar(highs: builtins["H"] ?? [], lows: builtins["L"] ?? [], step: step, maxStep: maxStep)
            sarDirection = r.isUp
            return r.values
        case "STD":
            try requireArgs(fn, vals, 2)
            return rolling(vals[0], period: Int(scalar(vals[1])), kind: .std)
        case "COUNT":
            try requireArgs(fn, vals, 2)
            return rolling(vals[0], period: Int(scalar(vals[1])), kind: .count)
        case "IF":
            try requireArgs(fn, vals, 3)
            return ternary(vals[0], vals[1], vals[2])
        case "CROSS":
            try requireArgs(fn, vals, 2)
            return cross(vals[0], vals[1])
        case "BARSLAST":
            try requireArgs(fn, vals, 1)
            return barsLast(vals[0])
        case "AND":
            try requireArgs(fn, vals, 2)
            return elementWise(vals[0], vals[1]) { ($0 != 0 && $1 != 0) ? 1 : 0 }
        case "OR":
            try requireArgs(fn, vals, 2)
            return elementWise(vals[0], vals[1]) { ($0 != 0 || $1 != 0) ? 1 : 0 }
        case "NOT":
            try requireArgs(fn, vals, 1)
            return vals[0].map { $0 == 0 ? 1 : 0 }
        default:
            throw TDXEngineError.semantic("不支持的函数：'\(name)'")
        }
    }

    private func requireArgs(_ fn: String, _ vals: [[Double]], _ n: Int) throws {
        guard vals.count >= n else {
            throw TDXEngineError.semantic("函数 \(fn) 至少需要 \(n) 个参数")
        }
    }

    // MARK: 序列算子

    private enum RollingKind { case max, min, sum, std, count }

    private func rolling(_ seq: [Double], period: Int, kind: RollingKind) -> [Double] {
        var result = Array(repeating: Double.nan, count: barCount)
        let offset = seq.count - barCount
        guard period > 0 else { return result }
        for i in 0..<barCount {
            let start = Swift.max(0, i - period + 1)
            var sum = 0.0
            var count = 0
            var mn = Double.greatestFiniteMagnitude
            var mx = -Double.greatestFiniteMagnitude
            var sumSq = 0.0
            for j in start...i {
                let v = seq[offset + j]
                if v.isNaN { continue }
                sum += v; count += 1
                sumSq += v * v
                mn = Swift.min(mn, v)
                mx = Swift.max(mx, v)
            }
            guard count > 0 else { continue }
            switch kind {
            case .max: result[i] = mx
            case .min: result[i] = mn
            case .sum: result[i] = sum
            case .count: result[i] = Double(count)
            case .std:
                let mean = sum / Double(count)
                let variance = Swift.max(0, sumSq / Double(count) - mean * mean)
                result[i] = sqrt(variance)
            }
        }
        return result
    }

    private func movingAverage(_ seq: [Double], period: Int, ema: Bool, weight: Double) -> [Double] {
        var result = Array(repeating: Double.nan, count: barCount)
        let offset = seq.count - barCount
        guard period > 0 else { return result }
        if ema {
            let k = weight / Double(period + 1)
            var prev: Double?
            for i in 0..<barCount {
                let v = seq[offset + i]
                // 跳过无效数据，避免污染后续计算
                if v.isNaN { continue }
                if let p = prev {
                    let cur = v * k + p * (1 - k)
                    result[i] = cur
                    prev = cur
                } else {
                    result[i] = v
                    prev = v
                }
            }
        } else {
            for i in 0..<barCount {
                let start = Swift.max(0, i - period + 1)
                var sum = 0.0
                var count = 0
                for j in start...i {
                    let v = seq[offset + j]
                    if v.isNaN { continue }
                    sum += v; count += 1
                }
                if count > 0 { result[i] = sum / Double(count) }
            }
        }
        return result
    }

    private func sma(_ seq: [Double], period: Int, m: Double) -> [Double] {
        var result = Array(repeating: Double.nan, count: barCount)
        let offset = seq.count - barCount
        guard period > 0 else { return result }
        var prev: Double?
        for i in 0..<barCount {
            let v = seq[offset + i]
            // 跳过无效数据：热身后遇到 NaN 保持前值，避免污染后续所有计算（导致整条线空白）
            if v.isNaN { continue }
            if let p = prev {
                let cur = (m * v + (Double(period) - m) * p) / Double(period)
                result[i] = cur
                prev = cur
            } else {
                result[i] = v
                prev = v
            }
        }
        return result
    }

    /// 从第一天起的全量累计（SUM(X,0)，用于 OBV 等）
    private func total(_ seq: [Double]) -> [Double] {
        var result = Array(repeating: 0.0, count: barCount)
        let offset = seq.count - barCount
        var sum = 0.0
        for i in 0..<barCount {
            let v = seq[offset + i]
            if v.isNaN { result[i] = .nan; continue }
            sum += v
            result[i] = sum
        }
        return result
    }

    /// 平均绝对偏差 AVEDEV(X,N)
    private func avedev(_ seq: [Double], period: Int) -> [Double] {
        var result = Array(repeating: Double.nan, count: barCount)
        let offset = seq.count - barCount
        guard period > 0 else { return result }
        for i in 0..<barCount {
            let start = Swift.max(0, i - period + 1)
            var sum = 0.0
            var count = 0
            for j in start...i {
                let v = seq[offset + j]
                if v.isNaN { continue }
                sum += v; count += 1
            }
            guard count > 0 else { continue }
            let mean = sum / Double(count)
            var dev = 0.0
            for j in start...i {
                let v = seq[offset + j]
                if v.isNaN { continue }
                dev += abs(v - mean)
            }
            result[i] = dev / Double(count)
        }
        return result
    }

    /// 抛物线转向 SAR（红/绿方向逐点着色）
    private func sar(highs: [Double], lows: [Double], step: Double, maxStep: Double) -> (values: [Double], isUp: [Bool]) {
        let count = min(highs.count, lows.count)
        var out = Array(repeating: Double.nan, count: count)
        var upFlag = Array(repeating: true, count: count)
        guard count > 1 else { return (out, upFlag) }
        var isUp = true
        var af = step
        var extreme = highs[0]
        var sarVal = lows[0]
        out[0] = sarVal
        upFlag[0] = isUp
        for i in 1..<count {
            let prev = out[i - 1]
            if isUp {
                sarVal = prev + af * (extreme - prev)
                sarVal = min(sarVal, lows[i - 1])
            } else {
                sarVal = prev + af * (extreme - prev)
                sarVal = max(sarVal, highs[i - 1])
            }
            out[i] = sarVal
            if isUp && lows[i] < sarVal {
                isUp = false
                out[i] = extreme
                extreme = lows[i]
                af = step
            } else if !isUp && highs[i] > sarVal {
                isUp = true
                out[i] = extreme
                extreme = highs[i]
                af = step
            } else {
                if isUp {
                    if highs[i] > extreme { extreme = highs[i]; af = min(af + step, maxStep) }
                } else {
                    if lows[i] < extreme { extreme = lows[i]; af = min(af + step, maxStep) }
                }
            }
            upFlag[i] = isUp
        }
        return (out, upFlag)
    }

    private func reference(_ seq: [Double], n: Int) -> [Double] {
        var result = Array(repeating: Double.nan, count: barCount)
        let offset = seq.count - barCount
        for i in 0..<barCount {
            let src = offset + i - n
            if src >= 0 { result[i] = seq[src] }
        }
        return result
    }

    private func elementWise(_ a: [Double], _ b: [Double], _ f: (Double, Double) -> Double) -> [Double] {
        var result = Array(repeating: 0.0, count: barCount)
        let oa = a.count - barCount
        let ob = b.count - barCount
        for i in 0..<barCount {
            result[i] = f(a[oa + i], b[ob + i])
        }
        return result
    }

    private func ternary(_ cond: [Double], _ a: [Double], _ b: [Double]) -> [Double] {
        var result = Array(repeating: 0.0, count: barCount)
        let oc = cond.count - barCount
        let oa = a.count - barCount
        let ob = b.count - barCount
        for i in 0..<barCount {
            result[i] = cond[oc + i] != 0 ? a[oa + i] : b[ob + i]
        }
        return result
    }

    private func cross(_ a: [Double], _ b: [Double]) -> [Double] {
        var result = Array(repeating: 0.0, count: barCount)
        let oa = a.count - barCount
        let ob = b.count - barCount
        for i in 0..<barCount {
            if i == 0 {
                result[i] = (a[oa + i] > b[ob + i]) ? 1 : 0
            } else {
                let prevA = a[oa + i - 1]
                let prevB = b[ob + i - 1]
                let curA = a[oa + i]
                let curB = b[ob + i]
                result[i] = (prevA <= prevB && curA > curB) ? 1 : 0
            }
        }
        return result
    }

    private func barsLast(_ cond: [Double]) -> [Double] {
        var result = Array(repeating: Double.nan, count: barCount)
        let offset = cond.count - barCount
        var lastIdx: Int?
        // 确保 lastIdx 是相对 barCount 的全局索引
        for g in 0..<(offset + barCount) {
            if cond[g] != 0 { lastIdx = g }
            let i = g - offset
            if i >= 0 {
                result[i] = lastIdx.map { Double(g - $0) } ?? .nan
            }
        }
        return result
    }
}

// MARK: - 公式引擎入口

/// 单个输出行的独立求值单元：包含该行及其全部传递依赖的赋值语句
struct TDXOutputLineUnit {
    let name: String
    /// 该行可独立求值的语句序列（依赖闭包 + 输出语句）
    let statements: [TDXStatement]
    /// 该行的公式文本（含参数替换后的值），用于逐行缓存比较——参数变仅影响对应行
    let text: String
}

enum TDXFormulaEngine {
    /// 解析并求值公式，返回所有输出行（按出现顺序）。纯计算，可在任意线程调用
    nonisolated static func evaluate(formula: String, data: [KlineItem]) throws -> [TDXOutputLine] {
        var lexer = TDXLexer(formula)
        let tokens = try lexer.tokenize()
        guard !tokens.isEmpty else {
            throw TDXEngineError.syntax("公式为空")
        }
        var parser = TDXParser(tokens: tokens)
        let stmts = try parser.parse()
        return try evaluate(statements: stmts, data: data)
    }

    /// 用已解析的语句序列求值（避免重复解析）。纯计算，可在任意线程调用
    nonisolated static func evaluate(statements: [TDXStatement], data: [KlineItem]) throws -> [TDXOutputLine] {
        var evaluator = TDXEvaluator(data: data)
        return try evaluator.evaluate(stmts: statements)
    }

    /// 把公式拆分成「每个输出行一个独立求值单元」。
    /// 每个单元 = 输出行 + 它全部传递依赖的赋值语句，可独立求值与独立缓存；
    /// 这样改某个参数只会使受影响行的单元文本变化，其余输出行可直接复用缓存结果。
    static func splitOutputUnits(formula: String) throws -> [TDXOutputLineUnit] {
        var lexer = TDXLexer(formula)
        let tokens = try lexer.tokenize()
        guard !tokens.isEmpty else { throw TDXEngineError.syntax("公式为空") }
        var parser = TDXParser(tokens: tokens)
        let stmts = try parser.parse()

        // 语句映射：变量名（大写）→ 语句。包含赋值与输出行——
        // 输出行也可能被其他输出行依赖（如 BOLL 的 UP 依赖输出行 MID），须一并纳入依赖闭包
        var stmtMap: [String: TDXStatement] = [:]
        for st in stmts { stmtMap[st.name.uppercased()] = st }

        var units: [TDXOutputLineUnit] = []
        for st in stmts where st.output {
            // BFS 收集输出行的全部传递依赖语句（赋值 + 输出行）
            var needed = Set<String>()
            collectVars(st.expr, into: &needed)
            var queue = needed
            var processed = Set<String>()
            while let name = queue.popFirst() {
                guard !processed.contains(name) else { continue }
                processed.insert(name)
                guard let s = stmtMap[name] else { continue }
                var deps = Set<String>()
                collectVars(s.expr, into: &deps)
                for d in deps where stmtMap[d] != nil && !needed.contains(d) {
                    needed.insert(d)
                    queue.insert(d)
                }
            }
            // 按原顺序取依赖语句（赋值 + 输出行）+ 目标输出行
            var sub: [TDXStatement] = []
            for s in stmts where needed.contains(s.name.uppercased()) { sub.append(s) }
            sub.append(st)
            let text = sub.map(stmtText).joined()
            units.append(TDXOutputLineUnit(name: st.name, statements: sub, text: text))
        }
        if units.isEmpty { throw TDXEngineError.semantic("公式没有输出行（至少需要一行以 ':' 输出的指标）") }
        return units
    }

    /// 递归收集表达式中的变量引用（函数名不会被收集，内置序列 C/H/O/L/V 等无赋值语句，自然跳过）
    static func collectVars(_ e: TDXExpr, into set: inout Set<String>) {
        switch e {
        case .number: break
        case .variable(let n): set.insert(n.uppercased())
        case .unary(_, let r): collectVars(r, into: &set)
        case .binary(_, let l, let r):
            collectVars(l, into: &set)
            collectVars(r, into: &set)
        case .call(_, let args):
            for a in args { collectVars(a, into: &set) }
        }
    }

    /// 语句 → 公式文本（用于逐行缓存的 key）。纯函数，nonisolated 以便在 map 等非隔离闭包中调用
    nonisolated static func stmtText(_ s: TDXStatement) -> String {
        var t = s.name + (s.output ? ":" : ":=") + exprText(s.expr)
        if s.output && !s.options.isEmpty { t += "," + s.options.joined(separator: ",") }
        return t + ";"
    }

    /// 表达式 → 公式文本。纯函数，nonisolated
    nonisolated static func exprText(_ e: TDXExpr) -> String {
        switch e {
        case .number(let n):
            return n == n.rounded() ? String(format: "%.0f", n) : String(format: "%g", n)
        case .variable(let n):
            return n
        case .unary(let op, let r):
            return op + exprText(r)
        case .binary(let op, let l, let r):
            let sym: String
            switch op {
            case "and": sym = " AND "
            case "or": sym = " OR "
            default: sym = " \(op) "
            }
            return "(" + exprText(l) + sym + exprText(r) + ")"
        case .call(let n, let args):
            return n + "(" + args.map(exprText).joined(separator: ",") + ")"
        }
    }
}
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

    nonisolated init(_ source: String) {
        self.chars = Array(source)
    }

    nonisolated mutating func tokenize() throws -> [TDXToken] {
        var tokens: [TDXToken] = []
        while let tk = try next() { tokens.append(tk) }
        return tokens
    }

    private nonisolated mutating func next() throws -> TDXToken? {
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

    private nonisolated func peek() -> Character? {
        guard pos < chars.count else { return nil }
        return chars[pos]
    }

    private nonisolated mutating func skipWhitespaceAndComments() {
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

    private nonisolated mutating func readNumber() -> Double {
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

    private nonisolated mutating func readIdentifier() -> String {
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

    nonisolated init(tokens: [TDXToken]) {
        self.tokens = tokens
    }

    nonisolated mutating func parse() throws -> [TDXStatement] {
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

    private nonisolated mutating func parseStatement() throws -> TDXStatement {
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
    private nonisolated mutating func parseExpr() throws -> TDXExpr {
        try parseOr()
    }

    private nonisolated mutating func parseOr() throws -> TDXExpr {
        var lhs = try parseAnd()
        while matchIdentifier("OR") {
            let rhs = try parseAnd()
            lhs = .binary(op: "or", lhs: lhs, rhs: rhs)
        }
        return lhs
    }

    private nonisolated mutating func parseAnd() throws -> TDXExpr {
        var lhs = try parseNot()
        while matchIdentifier("AND") {
            let rhs = try parseNot()
            lhs = .binary(op: "and", lhs: lhs, rhs: rhs)
        }
        return lhs
    }

    private nonisolated mutating func parseNot() throws -> TDXExpr {
        if matchIdentifier("NOT") {
            let rhs = try parseNot()
            return .unary(op: "not", rhs: rhs)
        }
        return try parseComparison()
    }

    private nonisolated mutating func parseComparison() throws -> TDXExpr {
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

    private nonisolated mutating func parseAdditive() throws -> TDXExpr {
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

    private nonisolated mutating func parseMultiplicative() throws -> TDXExpr {
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
    private nonisolated func isImplicitMulStart(_ t: TDXToken?) -> Bool {
        switch t {
        case .identifier(let s):
            let up = s.uppercased()
            return up != "AND" && up != "OR" && up != "NOT"
        case .number, .lparen: return true
        default: return false
        }
    }

    private nonisolated mutating func parseUnary() throws -> TDXExpr {
        if match(.minus) {
            let rhs = try parseUnary()
            return .unary(op: "-", rhs: rhs)
        }
        return try parsePrimary()
    }

    private nonisolated mutating func parsePrimary() throws -> TDXExpr {
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

    private nonisolated var isAtEnd: Bool { pos >= tokens.count }

    private nonisolated func peek() -> TDXToken? {
        guard pos < tokens.count else { return nil }
        return tokens[pos]
    }

    private nonisolated func check(_ t: TDXToken) -> Bool {
        peek() == t
    }

    private nonisolated mutating func match(_ t: TDXToken) -> Bool {
        guard check(t) else { return false }
        pos += 1
        return true
    }

    private nonisolated mutating func matchIdentifier(_ name: String) -> Bool {
        guard case .identifier(let s)? = peek(), s.uppercased() == name else { return false }
        pos += 1
        return true
    }

    private nonisolated mutating func consume(_ t: TDXToken, _ msg: String) throws -> TDXToken {
        guard match(t) else { throw TDXEngineError.syntax(msg) }
        return t
    }

    private nonisolated mutating func consumeIdentifier(_ msg: String) throws -> String {
        guard case .identifier(let s)? = peek() else { throw TDXEngineError.syntax(msg) }
        pos += 1
        return s
    }
}

// MARK: - 求值

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
    /// 把公式拆分成「每个输出行一个独立求值单元」。
    /// 每个单元 = 输出行 + 它全部传递依赖的赋值语句，可独立求值与独立缓存；
    /// 这样改某个参数只会使受影响行的单元文本变化，其余输出行可直接复用缓存结果。
    nonisolated static func splitOutputUnits(formula: String) throws -> [TDXOutputLineUnit] {
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
    nonisolated static func collectVars(_ e: TDXExpr, into set: inout Set<String>) {
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
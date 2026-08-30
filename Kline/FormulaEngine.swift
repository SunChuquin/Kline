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

/// 引用共享的 Double 数组容器：跨块传递时只复制引用（O(1)），
/// 增量计算只做 `append(新增段)`（O(incLen)），避免每块整段复制。
/// 创建时预分配总容量，避免 append 过程中反复扩容复制（倍增扩容 Σ≈2N 会抵消收益）。
/// 线程安全由调用方保证（后台预计算串行推进，同一公式状态不会被并发访问）
final class TDXSharedArray: @unchecked Sendable {
    var storage: [Double]
    init(_ values: [Double], capacity: Int = 0) {
        storage = values
        if capacity > storage.count {
            storage.reserveCapacity(capacity)
        }
    }
    var count: Int { storage.count }
}

/// 完整基础序列（整个标的的 C/H/L/O/V/AMOUNT），预计算各块共享引用，
/// 避免每块从裁剪数据重复 map（实测是分块预计算慢的主因）
final class TDXSharedSeries: @unchecked Sendable {
    let closes, highs, lows, opens, volumes, turnovers: [Double]
    let count: Int
    init(data: [KlineItem]) {
        self.closes = data.map(\.close)
        self.highs = data.map(\.high)
        self.lows = data.map(\.low)
        self.opens = data.map(\.open)
        self.volumes = data.map(\.volume)
        self.turnovers = data.map(\.turnover)
        self.count = data.count
    }
}

/// 增量求值状态（跨块传递）：后台预计算每块从数据开头起算以保证递归指标正确，
/// 但每块的 [0...上一块末尾] 是重复计算。状态延续让下一块只算新增区间。
/// 该状态包含上一块末尾索引、全部语句变量前缀（引用共享）、递归函数调用末尾值、SAR/BARSLAST 状态机快照。
struct TDXIncrementalState {
    /// 上一块末尾索引；-1 = 从头算
    var index: Int = -1
    /// 上一块算完后的语句变量（引用共享，[0...index]），增量时作为前缀复用
    var vars: [String: TDXSharedArray] = [:]
    /// 递归函数调用（EMA/SMA/SUM(,0) 等）上一块末尾值，key = 规范化调用文本
    var exprTails: [String: Double] = [:]
    /// SAR 状态机快照（key = 语句名）
    var sarStates: [String: (isUp: Bool, af: Double, extreme: Double)] = [:]
    /// SAR 红/绿方向完整数组（key = 语句名）：增量块把上一块前缀与新增方向拼接，
    /// 保证输出线的 markerDirections 与 values 等长（否则渲染逐点取色会错位/兜底错色）
    var sarDirs: [String: [Bool]] = [:]
    /// BARSLAST 状态快照：最近一次条件为真的全局索引（key = 语句名）
    var barsLastStates: [String: Int] = [:]
}

/// 通达信公式求值器
struct TDXEvaluator {
    private let barCount: Int
    private let builtins: [String: [Double]]
    private var vars: [String: TDXSharedArray] = [:]
    private let outputValues: [Double]
    /// 增量求值最终数据长度（用于 TDXSharedArray 预分配容量，避免 append 扩容复制）；
    /// totalCount 未提供时按当前 barCount 预留
    private let finalCount: Int
    /// 最近一次 SAR 调用的红/绿方向（用于输出线红绿点）
    private var sarDirection: [Bool]?
    /// 增量求值状态（resumeFrom = state.index；-1 = 从头算）
    private var incState = TDXIncrementalState()

    init(data: [KlineItem], totalCount: Int? = nil) {
        // 数据需为“最新一根在末尾”的顺序，与图表索引对齐
        self.barCount = data.count
        self.finalCount = max(totalCount ?? data.count, data.count)
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

    /// 基于共享完整基础序列构建（增量预计算各块复用 series，仅切片复制当前块段，
    /// 避免每块从裁剪数据重复 map —— 实测是分块预计算慢的主因）
    init(series: TDXSharedSeries, barCount: Int) {
        self.barCount = barCount
        self.finalCount = series.count
        let cs = Array(series.closes[0..<barCount])
        self.builtins = [
            "C": cs, "CLOSE": cs,
            "H": Array(series.highs[0..<barCount]), "HIGH": Array(series.highs[0..<barCount]),
            "L": Array(series.lows[0..<barCount]), "LOW": Array(series.lows[0..<barCount]),
            "O": Array(series.opens[0..<barCount]), "OPEN": Array(series.opens[0..<barCount]),
            "V": Array(series.volumes[0..<barCount]), "VOL": Array(series.volumes[0..<barCount]),
            "AMOUNT": Array(series.turnovers[0..<barCount]),
        ]
        self.outputValues = cs
    }

    mutating func evaluate(stmts: [TDXStatement]) throws -> [TDXOutputLine] {
        var lines: [TDXOutputLine] = []
        for stmt in stmts {
            sarDirection = nil
            let value = try eval(stmt.expr)
            vars[stmt.name] = TDXSharedArray(value)
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

    // MARK: - 增量求值（状态延续）

    /// 增量求值入口：resuming 为上一块的状态（nil 表示从头算）。
    /// 返回输出行 + 最新增量状态（供下一块传入）。
    mutating func evaluateIncremental(stmts: [TDXStatement], resuming: TDXIncrementalState?) throws -> (lines: [TDXOutputLine], state: TDXIncrementalState) {
        if let resuming { incState = resuming } else { incState = TDXIncrementalState() }
        var lines: [TDXOutputLine] = []
        for stmt in stmts {
            sarDirection = nil
            let shared = try evalStatement(stmt)
            vars[stmt.name] = shared
            incState.vars[stmt.name] = shared
            if stmt.output {
                // 输出行需要完整 [Double] 序列（曲线值），从共享数组复制一次
                var line = TDXOutputLine(name: stmt.name, values: Array(shared.storage))
                if let applied = applyOptions(stmt.options) {
                    line = applied(shared.storage, stmt.name)
                }
                line.hideValue = stmt.name.hasPrefix("NOTEXT_")
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
        // 记录当前块末尾索引，供下一块作为 resumeFrom 增量起点
        incState.index = barCount - 1
        return (lines, incState)
    }

    /// 增量模式下新增区间的起始索引 / 长度
    private var incStart: Int { incState.index + 1 }
    private var incLen: Int { max(0, barCount - incStart) }

    /// 语句求值：增量模式下复用上一块前缀（引用共享）、只算新增区间；含嵌套函数调用的语句从头算
    private mutating func evalStatement(_ stmt: TDXStatement) throws -> TDXSharedArray {
        let name = stmt.name.uppercased()
        let rf = incState.index
        // 表达式含嵌套函数调用时中间结果无法复用前缀，保守从头整段重算。
        // 这类语句不更新 exprTails，后续块同样走从头算路径，前后一致、数值正确
        guard isIncremental(stmt.expr) else {
            return TDXSharedArray(try eval(stmt.expr), capacity: finalCount)
        }
        // 增量路径：有上一块前缀则复用其引用（不整段复制），只计算并追加新增段；
        // 否则从本块数据开头（start=0）开始增量计算。
        // 始终走增量路径（包括第一块）可让 exprTails/sarStates/barsLastStates 从第一块起
        // 持续维护——若第一块走 eval 不存状态，第二块起递归指标（EMA/SMA/SAR/SUM0）会
        // 从错误起点计算导致数值错误
        if rf >= 0, let shared = incState.vars[name], shared.count > rf {
            let tail = try evalInc(stmt.expr, stmtName: name)
            shared.storage.append(contentsOf: tail)
            return shared
        }
        return TDXSharedArray(try evalInc(stmt.expr, stmtName: name), capacity: finalCount)
    }

    /// 语句是否可增量：表达式树中所有函数调用的参数都是叶子（数字/变量），
    /// 即无「嵌套函数调用」。嵌套表达式的中间结果无法复用前缀，保守从头算
    private func isIncremental(_ e: TDXExpr) -> Bool {
        switch e {
        case .number, .variable:
            return true
        case .unary(_, let rhs):
            return isIncremental(rhs)
        case .binary(_, let l, let r):
            return isIncremental(l) && isIncremental(r)
        case .call(_, let args):
            return args.allSatisfy { isIncremental($0) }
        }
    }

    /// 增量表达式求值：只计算新增区间 [incStart...barCount-1]，返回新增部分数组
    private mutating func evalInc(_ e: TDXExpr, stmtName: String) throws -> [Double] {
        switch e {
        case .number(let n):
            return Array(repeating: n, count: incLen)
        case .variable(let name):
            let key = name.uppercased()
            if let v = vars[key], v.storage.count >= barCount { return Array(v.storage[incStart...]) }
            if let b = builtins[key], b.count >= barCount { return Array(b[incStart...]) }
            throw TDXEngineError.semantic("未定义的变量或函数：'\(name)'")
        case .unary(let op, let rhs):
            let a = try evalInc(rhs, stmtName: stmtName)
            switch op {
            case "-": return a.map { -$0 }
            case "not": return a.map { $0 == 0 ? 1 : 0 }
            default: throw TDXEngineError.semantic("未知一元运算 '\(op)'")
            }
        case .binary(let op, let lhs, let rhs):
            let a = try evalInc(lhs, stmtName: stmtName)
            let b = try evalInc(rhs, stmtName: stmtName)
            return try binaryInc(op, a, b)
        case .call(let name, let args):
            return try evalCallInc(name, args, stmtName: stmtName)
        }
    }

    /// 增量二元运算（逐元素，输入均为新增部分，无 offset）
    private func binaryInc(_ op: String, _ a: [Double], _ b: [Double]) throws -> [Double] {
        var result = Array(repeating: 0.0, count: a.count)
        for i in 0..<a.count {
            let x = a[i], y = b[i]
            switch op {
            case "+": result[i] = x + y
            case "-": result[i] = x - y
            case "*": result[i] = x * y
            case "/": result[i] = (y == 0) ? 0 : x / y
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

    /// 参数求值为完整数组（增量模式下参数只能是叶子：数字/变量；嵌套由 isIncremental 排除）
    private mutating func evalFull(_ e: TDXExpr) throws -> [Double] {
        switch e {
        case .number(let n):
            return Array(repeating: n, count: barCount)
        case .variable(let name):
            let key = name.uppercased()
            if let v = vars[key] { return v.storage }
            if let b = builtins[key] { return b }
            throw TDXEngineError.semantic("未定义的变量或函数：'\(name)'")
        case .unary(let op, let rhs):
            let a = try evalFull(rhs)
            switch op {
            case "-": return a.map { -$0 }
            case "not": return a.map { $0 == 0 ? 1 : 0 }
            default: throw TDXEngineError.semantic("未知一元运算 '\(op)'")
            }
        case .binary(let op, let lhs, let rhs):
            let a = try evalFull(lhs)
            let b = try evalFull(rhs)
            return try binary(op, a, b)
        case .call(let name, let args):
            return try evalCall(name, args)
        }
    }

    /// 规范化函数调用文本（用于 exprTail 缓存 key）
    private func callKey(_ fn: String, _ args: [TDXExpr]) -> String {
        fn.uppercased() + "(" + args.map { argDesc($0) }.joined(separator: ",") + ")"
    }
    private func argDesc(_ e: TDXExpr) -> String {
        switch e {
        case .number(let n): return "\(n)"
        case .variable(let n): return n.uppercased()
        case .unary(let op, let r): return op + argDesc(r)
        case .binary(let op, let l, let r): return argDesc(l) + op + argDesc(r)
        case .call(let n, let a): return callKey(n, a)
        }
    }

    /// 增量函数调用：只算新增区间，返回新增部分数组
    private mutating func evalCallInc(_ name: String, _ args: [TDXExpr], stmtName: String) throws -> [Double] {
        let fn = name.uppercased()
        let vals = try args.map { try evalFull($0) }
        func scalar(_ seq: [Double]) -> Double { seq.isEmpty ? 0 : seq[seq.count - 1] }
        func tail(_ arr: [Double]) -> [Double] { Array(arr[incStart...]) }
        switch fn {
        case "MA":
            try requireArgs(fn, vals, 2)
            return movingAverageInc(vals[0], period: Int(scalar(vals[1])), ema: false, weight: 1, tailKey: callKey(fn, args))
        case "EMA":
            try requireArgs(fn, vals, 2)
            return movingAverageInc(vals[0], period: Int(scalar(vals[1])), ema: true, weight: 1, tailKey: callKey(fn, args))
        case "SMA":
            try requireArgs(fn, vals, 3)
            return smaInc(vals[0], period: Int(scalar(vals[1])), m: scalar(vals[2]), tailKey: callKey(fn, args))
        case "REF":
            try requireArgs(fn, vals, 2)
            return referenceInc(vals[0], n: Int(scalar(vals[1])))
        case "HHV":
            try requireArgs(fn, vals, 2)
            return rollingInc(vals[0], period: Int(scalar(vals[1])), kind: .max)
        case "LLV":
            try requireArgs(fn, vals, 2)
            return rollingInc(vals[0], period: Int(scalar(vals[1])), kind: .min)
        case "ABS":
            try requireArgs(fn, vals, 1)
            return tail(vals[0]).map { abs($0) }
        case "MAX":
            try requireArgs(fn, vals, 2)
            return elementWiseInc(vals[0], vals[1]) { max($0, $1) }
        case "MIN":
            try requireArgs(fn, vals, 2)
            return elementWiseInc(vals[0], vals[1]) { min($0, $1) }
        case "SUM":
            try requireArgs(fn, vals, 2)
            let period = Int(scalar(vals[1]))
            if period <= 0 { return totalInc(vals[0], tailKey: callKey(fn, args)) }
            return rollingInc(vals[0], period: period, kind: .sum)
        case "AVEDEV":
            try requireArgs(fn, vals, 2)
            return avedevInc(vals[0], period: Int(scalar(vals[1])))
        case "SAR":
            try requireArgs(fn, vals, 2)
            let step = scalar(vals[0])
            let maxStep = scalar(vals[1])
            let r = sarInc(highs: builtins["H"] ?? [], lows: builtins["L"] ?? [], step: step, maxStep: maxStep, stmtName: stmtName)
            sarDirection = r.isUp
            return r.values
        case "STD":
            try requireArgs(fn, vals, 2)
            return rollingInc(vals[0], period: Int(scalar(vals[1])), kind: .std)
        case "COUNT":
            try requireArgs(fn, vals, 2)
            return rollingInc(vals[0], period: Int(scalar(vals[1])), kind: .count)
        case "IF":
            try requireArgs(fn, vals, 3)
            return ternaryInc(vals[0], vals[1], vals[2])
        case "CROSS":
            try requireArgs(fn, vals, 2)
            return crossInc(vals[0], vals[1])
        case "BARSLAST":
            try requireArgs(fn, vals, 1)
            return barsLastInc(vals[0], stmtName: stmtName)
        case "AND":
            try requireArgs(fn, vals, 2)
            return elementWiseInc(vals[0], vals[1]) { ($0 != 0 && $1 != 0) ? 1 : 0 }
        case "OR":
            try requireArgs(fn, vals, 2)
            return elementWiseInc(vals[0], vals[1]) { ($0 != 0 || $1 != 0) ? 1 : 0 }
        case "NOT":
            try requireArgs(fn, vals, 1)
            return tail(vals[0]).map { $0 == 0 ? 1 : 0 }
        default:
            throw TDXEngineError.semantic("不支持的函数：'\(name)'")
        }
    }

    // MARK: 增量序列算子（只算新增区间 [incStart...barCount-1]，返回新增部分数组）

    /// 增量移动平均：EMA/SMA 等递归用 exprTail 里上一块末尾值继续；MA 窗口从完整输入取
    private mutating func movingAverageInc(_ seq: [Double], period: Int, ema: Bool, weight: Double, tailKey: String) -> [Double] {
        let start = incStart
        let len = incLen
        var result = Array(repeating: Double.nan, count: len)
        let offset = seq.count - barCount
        guard period > 0, len > 0 else { return result }
        if ema {
            let k = weight / Double(period + 1)
            var prev = incState.exprTails[tailKey]
            var prevValid = false
            if let p = prev, !p.isNaN { prevValid = true }
            for i in start..<barCount {
                let v = seq[offset + i]
                if v.isNaN { continue }
                if prevValid {
                    let cur = v * k + prev! * (1 - k)
                    result[i - start] = cur
                    prev = cur
                } else {
                    result[i - start] = v
                    prev = v
                    prevValid = true
                }
            }
            incState.exprTails[tailKey] = prevValid ? prev : .nan
        } else {
            for i in start..<barCount {
                let wStart = Swift.max(0, i - period + 1)
                var sum = 0.0
                var count = 0
                for j in wStart...i {
                    let v = seq[offset + j]
                    if v.isNaN { continue }
                    sum += v; count += 1
                }
                if count > 0 { result[i - start] = sum / Double(count) }
            }
        }
        return result
    }

    /// 增量 SMA(X,N,M)：递归，用 exprTail 里上一块末尾继续
    private mutating func smaInc(_ seq: [Double], period: Int, m: Double, tailKey: String) -> [Double] {
        let start = incStart
        let len = incLen
        var result = Array(repeating: Double.nan, count: len)
        let offset = seq.count - barCount
        guard period > 0, len > 0 else { return result }
        var prev = incState.exprTails[tailKey]
        var prevValid = false
        if let p = prev, !p.isNaN { prevValid = true }
        for i in start..<barCount {
            let v = seq[offset + i]
            if v.isNaN { continue }
            if prevValid {
                let cur = (m * v + (Double(period) - m) * prev!) / Double(period)
                result[i - start] = cur
                prev = cur
            } else {
                result[i - start] = v
                prev = v
                prevValid = true
            }
        }
        incState.exprTails[tailKey] = prevValid ? prev : .nan
        return result
    }

    /// 增量全量累计 SUM(X,0)：用 exprTail 里上一块末尾累计值继续
    private mutating func totalInc(_ seq: [Double], tailKey: String) -> [Double] {
        let start = incStart
        let len = incLen
        var result = Array(repeating: 0.0, count: len)
        let offset = seq.count - barCount
        var sum = incState.exprTails[tailKey] ?? 0
        if let s = incState.exprTails[tailKey], s.isNaN { sum = 0 }
        for i in start..<barCount {
            let v = seq[offset + i]
            if v.isNaN { result[i - start] = .nan; continue }
            sum += v
            result[i - start] = sum
        }
        incState.exprTails[tailKey] = sum
        return result
    }

    /// 增量滑动窗口（HHV/LLV/SUM/STD/COUNT）：窗口从完整输入取
    private func rollingInc(_ seq: [Double], period: Int, kind: RollingKind) -> [Double] {
        let start = incStart
        let len = incLen
        var result = Array(repeating: Double.nan, count: len)
        let offset = seq.count - barCount
        guard period > 0, len > 0 else { return result }
        for i in start..<barCount {
            let wStart = Swift.max(0, i - period + 1)
            var sum = 0.0
            var count = 0
            var mn = Double.greatestFiniteMagnitude
            var mx = -Double.greatestFiniteMagnitude
            var sumSq = 0.0
            for j in wStart...i {
                let v = seq[offset + j]
                if v.isNaN { continue }
                sum += v; count += 1
                sumSq += v * v
                mn = Swift.min(mn, v)
                mx = Swift.max(mx, v)
            }
            guard count > 0 else { continue }
            switch kind {
            case .max: result[i - start] = mx
            case .min: result[i - start] = mn
            case .sum: result[i - start] = sum
            case .count: result[i - start] = Double(count)
            case .std:
                let mean = sum / Double(count)
                let variance = Swift.max(0, sumSq / Double(count) - mean * mean)
                result[i - start] = sqrt(variance)
            }
        }
        return result
    }

    /// 增量平均绝对偏差 AVEDEV
    private func avedevInc(_ seq: [Double], period: Int) -> [Double] {
        let start = incStart
        let len = incLen
        var result = Array(repeating: Double.nan, count: len)
        let offset = seq.count - barCount
        guard period > 0, len > 0 else { return result }
        for i in start..<barCount {
            let wStart = Swift.max(0, i - period + 1)
            var sum = 0.0
            var count = 0
            for j in wStart...i {
                let v = seq[offset + j]
                if v.isNaN { continue }
                sum += v; count += 1
            }
            guard count > 0 else { continue }
            let mean = sum / Double(count)
            var dev = 0.0
            for j in wStart...i {
                let v = seq[offset + j]
                if v.isNaN { continue }
                dev += abs(v - mean)
            }
            result[i - start] = dev / Double(count)
        }
        return result
    }

    /// 增量 REF：查历史，非递归
    private func referenceInc(_ seq: [Double], n: Int) -> [Double] {
        let start = incStart
        let len = incLen
        var result = Array(repeating: Double.nan, count: len)
        let offset = seq.count - barCount
        for i in start..<barCount {
            let src = offset + i - n
            if src >= 0 { result[i - start] = seq[src] }
        }
        return result
    }

    /// 增量逐元素（MAX/MIN/AND/OR）
    private func elementWiseInc(_ a: [Double], _ b: [Double], _ f: (Double, Double) -> Double) -> [Double] {
        let start = incStart
        var result = Array(repeating: 0.0, count: incLen)
        for i in start..<barCount {
            result[i - start] = f(a[i], b[i])
        }
        return result
    }

    /// 增量 IF
    private func ternaryInc(_ cond: [Double], _ a: [Double], _ b: [Double]) -> [Double] {
        let start = incStart
        var result = Array(repeating: 0.0, count: incLen)
        for i in start..<barCount {
            result[i - start] = cond[i] != 0 ? a[i] : b[i]
        }
        return result
    }

    /// 增量 CROSS：需要前一索引，从完整输入取
    private func crossInc(_ a: [Double], _ b: [Double]) -> [Double] {
        let start = incStart
        var result = Array(repeating: 0.0, count: incLen)
        for i in start..<barCount {
            if i == 0 {
                result[i - start] = (a[i] > b[i]) ? 1 : 0
            } else {
                result[i - start] = (a[i - 1] <= b[i - 1] && a[i] > b[i]) ? 1 : 0
            }
        }
        return result
    }

    /// 增量 SAR：用 sarStates 里上一块末尾状态机快照继续，算完更新快照
    private mutating func sarInc(highs: [Double], lows: [Double], step: Double, maxStep: Double, stmtName: String) -> (values: [Double], isUp: [Bool]) {
        let start = incStart
        let len = incLen
        let hOffset = highs.count - barCount
        let lOffset = lows.count - barCount
        var out = Array(repeating: Double.nan, count: len)
        var upFlag = Array(repeating: true, count: len)
        guard len > 0, barCount > 1 else { return (out, upFlag) }
        var isUp = true
        var af = step
        var extreme = highs[hOffset]
        var sarVal = lows[lOffset]
        if let s = incState.sarStates[stmtName] {
            isUp = s.isUp
            af = s.af
            extreme = s.extreme
            if let v = incState.vars[stmtName], incState.index >= 0, v.storage.count > incState.index {
                sarVal = v.storage[incState.index]
            }
        }
        for k in 0..<len {
            let i = start + k
            if i == 0 {
                // 第一根 K 线：SAR 初值直接输出（与非增量实现一致），
                // 否则 lows[lOffset + i - 1] 会访问负索引越界
                out[k] = sarVal
                upFlag[k] = isUp
                continue
            }
            let prev = sarVal
            if isUp {
                sarVal = prev + af * (extreme - prev)
                sarVal = min(sarVal, lows[lOffset + i - 1])
            } else {
                sarVal = prev + af * (extreme - prev)
                sarVal = max(sarVal, highs[hOffset + i - 1])
            }
            out[k] = sarVal
            if isUp && lows[lOffset + i] < sarVal {
                isUp = false
                out[k] = extreme
                extreme = lows[lOffset + i]
                af = step
            } else if !isUp && highs[hOffset + i] > sarVal {
                isUp = true
                out[k] = extreme
                extreme = highs[hOffset + i]
                af = step
            } else {
                if isUp {
                    if highs[hOffset + i] > extreme { extreme = highs[hOffset + i]; af = min(af + step, maxStep) }
                } else {
                    if lows[lOffset + i] < extreme { extreme = lows[lOffset + i]; af = min(af + step, maxStep) }
                }
            }
            upFlag[k] = isUp
        }
        incState.sarStates[stmtName] = (isUp, af, extreme)
        // 把上一块方向前缀与新增方向拼接为完整数组（长度 = barCount），
        // 供输出线 markerDirections 逐点取色；否则仅新增区间的短数组会让前半段点色错位/兜底
        let prevDirs = incState.sarDirs[stmtName] ?? []
        var dirs = prevDirs + upFlag
        if dirs.count > barCount { dirs = Array(dirs[(dirs.count - barCount)...]) }
        incState.sarDirs[stmtName] = dirs
        return (out, dirs)
    }

    /// 增量 BARSLAST：用 barsLastStates 里上一块末尾最近命中索引继续
    private mutating func barsLastInc(_ cond: [Double], stmtName: String) -> [Double] {
        let start = incStart
        let len = incLen
        var result = Array(repeating: Double.nan, count: len)
        let offset = cond.count - barCount
        var lastIdx: Int? = incState.barsLastStates[stmtName]
        for k in 0..<len {
            let g = offset + start + k
            if cond[g] != 0 { lastIdx = g }
            result[k] = lastIdx.map { Double(g - $0) } ?? .nan
        }
        incState.barsLastStates[stmtName] = lastIdx
        return result
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
            if let v = vars[key] { return v.storage }
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

    /// 增量求值入口：对公式求值，resuming 为上一块的状态（nil 表示从头算）。
    /// series 为完整基础序列（各块共享引用，避免重复 map）；barCount 为当前块长度（end+1）。
    /// 返回输出行 + 最新增量状态（供下一块传入）。纯计算，可在任意线程调用
    nonisolated static func evaluateIncremental(formula: String, series: TDXSharedSeries,
                                                barCount: Int,
                                                resuming: TDXIncrementalState?) throws -> (lines: [TDXOutputLine], state: TDXIncrementalState) {
        var lexer = TDXLexer(formula)
        let tokens = try lexer.tokenize()
        guard !tokens.isEmpty else { throw TDXEngineError.syntax("公式为空") }
        var parser = TDXParser(tokens: tokens)
        let stmts = try parser.parse()
        var evaluator = TDXEvaluator(series: series, barCount: barCount)
        return try evaluator.evaluateIncremental(stmts: stmts, resuming: resuming)
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
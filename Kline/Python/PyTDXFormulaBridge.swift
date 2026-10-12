//
//  PyTDXFormulaBridge.swift
//  Kline
//
//  【首帧引擎实验】TDX 公式引擎的 Python 下沉桥（2026-10-12）。
//  分工：Swift 保留 lexer/parser（TDXFormulaEngine 原实现未动）与样式组装（渲染保真零风险），
//  本桥只把 AST 序列化过桥，由 Kline/PyScripts/tdx_eval.py 纯标准库完成数值求值。
//
//  线程约束：evaluate(requests:) 内部走 KlinePythonBridge.blockingCall，
//  只能在后台线程调用（主线程 assert 崩溃）——调用点一律 Task.detached。
//

import Foundation

enum PyTDXFormulaBridge {

    // MARK: - AST 序列化（TDXExpr/TDXStatement → JSON 兼容字典）

    /// 表达式节点：{"t":"num","v":1.5} | {"t":"var","n":"C"}
    ///           | {"t":"un","op":"-","x":..} | {"t":"bin","op":"+","l":..,"r":..}
    ///           | {"t":"call","fn":"MA","args":[..]}
    static func astJSON(_ e: TDXExpr) -> [String: Any] {
        switch e {
        case .number(let v):
            return ["t": "num", "v": v]
        case .variable(let n):
            return ["t": "var", "n": n]
        case .unary(let op, let rhs):
            return ["t": "un", "op": op, "x": astJSON(rhs)]
        case .binary(let op, let l, let r):
            return ["t": "bin", "op": op, "l": astJSON(l), "r": astJSON(r)]
        case .call(let name, let args):
            return ["t": "call", "fn": name, "args": args.map(astJSON)]
        }
    }

    /// 语句节点：{"n":名称, "o":是否输出行, "e":表达式}。
    /// 样式选项（options）不发送——样式组装在 Swift 侧完成，Python 只算数值
    static func stmtJSON(_ s: TDXStatement) -> [String: Any] {
        return ["n": s.name, "o": s.output ? 1 : 0, "e": astJSON(s.expr)]
    }

    // MARK: - 求值（仅后台线程）

    /// 批量求值：requests 与返回的 [[TDXOutputLine]] 按下标对齐（单请求失败对应下标为空数组，
    /// 不拖垮整批——失败信息见日志）。data 为该批公式的公共 K 线区间。
    /// 输出行已应用样式选项/SAR 红绿方向/NOTEXT_ 隐藏（规则与原 TDXEvaluator.applyOptions 一致）。
    static func evaluate(requests: [[TDXStatement]],
                         data: [KlineItem],
                         timeout: TimeInterval = 20) -> Result<[[TDXOutputLine]], String> {
        assert(!Thread.isMainThread, "PyTDXFormulaBridge.evaluate 禁止主线程调用（blockingCall）")
        guard !requests.isEmpty, !data.isEmpty else { return .success([]) }
        let input: [String: Any] = [
            "bars": [
                "c": data.map(\.close),
                "h": data.map(\.high),
                "l": data.map(\.low),
                "o": data.map(\.open),
                "v": data.map(\.volume),
                "a": data.map(\.turnover),
            ],
            "requests": requests.map { ["stmts": $0.map(stmtJSON)] },
        ]
        switch KlinePythonBridge.shared.blockingCall(script: "tdx_eval", input: input, timeout: timeout) {
        case .failure(let err):
            let msg: String
            switch err {
            case .engineNotReady(let m): msg = "引擎未就绪：\(m)"
            case .timeout: msg = "超时（\(timeout)s）"
            case .scriptError(let m): msg = m
            }
            return .failure(msg)
        case .success(let raw):
            return decode(raw: raw, requests: requests)
        }
    }

    // MARK: - 解码与组装

    private static func decode(raw: Data, requests: [[TDXStatement]]) -> Result<[[TDXOutputLine]], String> {
        guard let obj = try? JSONSerialization.jsonObject(with: raw),
              let dict = obj as? [String: Any],
              (dict["ok"] as? Bool) == true,
              let results = dict["results"] as? [[String: Any]] else {
            return .failure("输出 JSON 非法或缺 ok=true")
        }
        guard results.count == requests.count else {
            return .failure("结果数 \(results.count) 与请求数 \(requests.count) 不一致")
        }
        var all: [[TDXOutputLine]] = []
        all.reserveCapacity(requests.count)
        for (i, r) in results.enumerated() {
            guard (r["ok"] as? Bool) == true else {
                let e = (r["error"] as? String) ?? "(缺 error)"
                DebugLogger.shared.log("[PyTDXBridge] 批内请求 #\(i) 求值失败：\(e)")
                all.append([])
                continue
            }
            let lines = (r["lines"] as? [[String: Any]]) ?? []
            all.append(assembleOutputLines(lines: lines, stmts: requests[i]))
        }
        return .success(all)
    }

    /// 把 Python 返回的输出行（仅 name+values+可选 SAR 方向）与 Swift 侧语句序列按输出行顺序对齐，
    /// 组装为带样式的 TDXOutputLine（与原 TDXEvaluator.evaluate 的输出组装规则一致）
    private static func assembleOutputLines(lines: [[String: Any]], stmts: [TDXStatement]) -> [TDXOutputLine] {
        var out: [TDXOutputLine] = []
        var li = 0
        for stmt in stmts where stmt.output {
            guard li < lines.count else { break }
            let l = lines[li]
            li += 1
            var line = TDXOutputLine(name: stmt.name, values: decodeValues(l["v"]))
            applyOptions(stmt.options, to: &line)
            line.hideValue = stmt.name.hasPrefix("NOTEXT_")
            // SAR 输出线：附加红/绿方向用于逐点着色（Python 对根调用为 SAR 的语句返回 d 数组）
            if case .call(let fnName, _) = stmt.expr, fnName.uppercased() == "SAR",
               let dirs = decodeDirs(l["d"]) {
                line.markerDirections = dirs
            }
            out.append(line)
        }
        return out
    }

    /// 序列解码：null（Python 非有限值）→ NaN，数字 → Double
    private static func decodeValues(_ any: Any?) -> [Double] {
        guard let raw = any as? [Any] else { return [] }
        var values = [Double](repeating: .nan, count: raw.count)
        for (i, e) in raw.enumerated() {
            if let n = e as? NSNumber { values[i] = n.doubleValue }
        }
        return values
    }

    /// SAR 方向解码：0/1 → false/true
    private static func decodeDirs(_ any: Any?) -> [Bool]? {
        guard let raw = any as? [Any] else { return nil }
        var dirs = [Bool](repeating: true, count: raw.count)
        for (i, e) in raw.enumerated() {
            if let n = e as? NSNumber { dirs[i] = n.intValue != 0 }
        }
        return dirs
    }

    /// 输出线样式选项（DOTLINE/POINTDOT/STICK/COLORSTICK/NODRAW/COLORXXX/LINETHICKn/Ln）。
    /// 规则逐条镜像原 TDXEvaluator.applyOptions（FormulaEngine.swift，原实现保留未动）
    private static func applyOptions(_ options: [String], to line: inout TDXOutputLine) {
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
    }
}

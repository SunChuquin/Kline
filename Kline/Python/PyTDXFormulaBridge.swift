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
    /// dbAudit：直读库对拍段（阶段1），仅观测——传入时 Python 读主库+增量库组装 bars 与
    /// data 逐字段对拍，差异经日志输出，**不影响求值**（求值输入仍是 data）
    static func evaluate(requests: [[TDXStatement]],
                         data: [KlineItem],
                         dbAudit: [String: Any]? = nil,
                         timeout: TimeInterval = 20) -> Result<[[TDXOutputLine]], String> {
        assert(!Thread.isMainThread, "PyTDXFormulaBridge.evaluate 禁止主线程调用（blockingCall）")
        guard !requests.isEmpty, !data.isEmpty else { return .success([]) }
        // bin 通道：bars 六序列零拷贝进（ctypes 视图）+ 输出行序列二进制出（一次拷贝），
        // JSON 只承载 requests/AST 与 db 对拍段——大数组不再过 JSON 文本化
        let seriesBin: [String: [Double]] = [
            "c": data.map(\.close),
            "h": data.map(\.high),
            "l": data.map(\.low),
            "o": data.map(\.open),
            "v": data.map(\.volume),
            "a": data.map(\.turnover),
        ]
        var input: [String: Any] = [
            "__bin__": 1,
            "requests": requests.map { ["stmts": $0.map(stmtJSON)] },
        ]
        if let dbAudit { input["db"] = dbAudit }
        switch KlinePythonBridge.shared.blockingCallBin(script: "tdx_eval", input: input,
                                                        seriesBin: seriesBin, seriesInto: "bars",
                                                        timeout: timeout) {
        case .failure(let err):
            let msg: String
            switch err {
            case .engineNotReady(let m): msg = "引擎未就绪：\(m)"
            case .timeout: msg = "超时（\(timeout)s）"
            case .scriptError(let m): msg = m
            }
            return .failure(msg)
        case .success(let bin):
            if dbAudit != nil {
                logAuditIfPresent(payload: bin.payload, table: (dbAudit?["table"] as? String) ?? "?")
            }
            return decode(bin: bin, requests: requests)
        }
    }

    /// 对拍结果落日志（每 call 一行标量，无库内容；仅 db 段传入时调用）
    private static func logAuditIfPresent(payload: [String: Any], table: String) {
        guard let a = payload["audit"] as? [String: Any] else { return }
        let dbRows = (a["db_rows"] as? NSNumber)?.intValue ?? -1
        let swRows = (a["swift_rows"] as? NSNumber)?.intValue ?? -1
        let src = (a["source"] as? String) ?? "?"
        if let eq = a["equal"] as? Bool {
            if eq {
                DebugLogger.shared.log("[PyTDXBridge] 对拍<\(table)> \(src) \(dbRows)行 一致")
            } else if let fd = a["first_diff"] as? [String: Any] {
                DebugLogger.shared.log("[PyTDXBridge] 对拍<\(table)> \(src) db=\(dbRows) swift=\(swRows) 首差 idx=\(fd["idx"] ?? "-") field=\(fd["field"] ?? "-") db=\(fd["db"] ?? "-") swift=\(fd["swift"] ?? "-")")
            } else {
                DebugLogger.shared.log("[PyTDXBridge] 对拍<\(table)> \(src) db=\(dbRows) swift=\(swRows) 不一致(无首差)")
            }
        } else {
            DebugLogger.shared.log("[PyTDXBridge] 对拍<\(table)> 异常：\(a["error"] ?? "?")")
        }
    }

    // MARK: - 解码与组装

    private static func decode(bin: PyBinResult, requests: [[TDXStatement]]) -> Result<[[TDXOutputLine]], String> {
        let dict = bin.payload
        guard (dict["ok"] as? Bool) == true,
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
            all.append(assembleOutputLines(lines: lines, stmts: requests[i], arrays: bin.arrays))
        }
        return .success(all)
    }

    /// 把 Python 返回的输出行（仅 name+值序列+可选 SAR 方向）与 Swift 侧语句序列按输出行顺序对齐，
    /// 组装为带样式的 TDXOutputLine（与原 TDXEvaluator.evaluate 的输出组装规则一致）。
    /// 值序列优先取 bin 段（"b" 键 → arrays），缺省回退 JSON "v"（null→NaN，向后兼容）
    private static func assembleOutputLines(lines: [[String: Any]], stmts: [TDXStatement],
                                            arrays: [String: [Double]]) -> [TDXOutputLine] {
        var out: [TDXOutputLine] = []
        var li = 0
        for stmt in stmts where stmt.output {
            guard li < lines.count else { break }
            let l = lines[li]
            li += 1
            var line = TDXOutputLine(name: stmt.name, values: binValues(l["b"], arrays: arrays) ?? decodeValues(l["v"]))
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

    /// bin 段值解码：键 → [Double]（NaN 以原始位模式直达，无 null 转换）
    private static func binValues(_ any: Any?, arrays: [String: [Double]]) -> [Double]? {
        guard let key = any as? String else { return nil }
        return arrays[key]
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

// MARK: - 【首帧引擎实验】同帧波次合并器
//
// 对齐 Swift 原生实现的一次求值波次：主图 + 三个副图在同一次 runloop tick 内触发的
// recompute，合并为**一次** Python call（bars 只序列化/写盘一份），结果按下标发回各请求方。
// 修复首轮实现「每个图表各发一次 call、各带一份 bars」导致的 4 倍 JSON/文件 I/O 开销。
final class PyTDXWave {

    static let shared = PyTDXWave()

    private struct Pending {
        let barsKey: String
        let data: [KlineItem]
        let stmts: [TDXStatement]
        let dbAudit: [String: Any]?
        let completion: (Result<[TDXOutputLine], String>) -> Void
    }

    /// 同区间请求分组（struct 替代带标签元组，规避老编译器泛型/元组解析歧义）
    private struct Group {
        let data: [KlineItem]
        let dbAudit: [String: Any]?
        var slots: [Int]
    }

    /// 单组求值作业（struct 替代带标签元组，同上）
    private struct Job {
        let requests: [[TDXStatement]]
        let data: [KlineItem]
        let dbAudit: [String: Any]?
        let slots: [Int]
    }

    private var pending: [Pending] = []
    private var flushScheduled = false

    /// 主线程提交一次求值请求。同一 runloop tick 内的多个提交（主图 N 个单元 + 副图 3 个）
    /// 在下一 tick 冲刷时按 barsKey 分组合并：同区间共享一份 bars payload → 单组一次 call。
    /// dbAudit：直读库对拍段（同组请求应传同一份；组内取首请求的）
    func submit(barsKey: String, data: [KlineItem], stmts: [TDXStatement],
                dbAudit: [String: Any]? = nil,
                completion: @escaping (Result<[TDXOutputLine], String>) -> Void) {
        assert(Thread.isMainThread, "PyTDXWave.submit 仅限主线程（与 recompute 同帧）")
        pending.append(Pending(barsKey: barsKey, data: data, stmts: stmts,
                               dbAudit: dbAudit, completion: completion))
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { self.flush() }
    }

    private func flush() {
        flushScheduled = false
        let batch = pending
        pending = []
        guard !batch.isEmpty else { return }
        // 按 barsKey 分组保持提交顺序；组内 slots 记录各请求在 batch 中的下标（dbAudit 取首请求的）
        var order: [String] = []
        var groups: [String: Group] = [:]
        for (i, p) in batch.enumerated() {
            if groups[p.barsKey] == nil {
                groups[p.barsKey] = Group(data: p.data, dbAudit: p.dbAudit, slots: [])
                order.append(p.barsKey)
            }
            groups[p.barsKey]!.slots.append(i)
        }
        var jobs: [Job] = []
        jobs.reserveCapacity(order.count)
        for key in order {
            let g = groups[key]!
            jobs.append(Job(requests: g.slots.map { batch[$0].stmts }, data: g.data,
                            dbAudit: g.dbAudit, slots: g.slots))
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // 显式类型标注（不用泛型数组字面量初始化，规避老编译器 '>' 解析歧义）
            var results: [Result<[TDXOutputLine], String>] = []
            results.reserveCapacity(batch.count)
            for j in jobs {
                switch PyTDXFormulaBridge.evaluate(requests: j.requests, data: j.data, dbAudit: j.dbAudit) {
                case .success(let batches):
                    // batches 与 j.requests 按下标对齐；组内逐请求发回，单请求失败不拖垮同组其余
                    for b in batches { results.append(.success(b)) }
                case .failure(let msg):
                    for _ in j.slots { results.append(.failure(msg)) }
                }
            }
            DispatchQueue.main.async {
                for (i, p) in batch.enumerated() where i < results.count {
                    p.completion(results[i])
                }
            }
        }
    }
}

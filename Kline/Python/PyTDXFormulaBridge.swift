//
//  PyTDXFormulaBridge.swift
//  Kline
//
//  TDX 公式引擎的 Python 下沉桥（文本通道版，2026-10-16）。
//  分工：Python 承担【解析 + 拆分 + 求值】全链路（tdx_eval.py text op，AST 按文本缓存
//  跨调用持久）；Swift 只剩样式组装（渲染保真零风险）与调用编排。
//
//  文本通道三入口（全部仅后台线程，内部 blockingCallBin 主线程 assert）：
//  - splitUnits：公式文本 → 每输出行单元 [{name, text}]（主图行缓存的单元 key）
//  - evaluateUnitTexts：单元文本 → 该单元输出行（PyTDXWave 主图波次）
//  - evaluateFormulasWithUnits：公式文本 → 单元数组（单元级错误隔离，联动 as-of 占位语义）
//  - evaluateText：公式文本 → 全部输出行（编辑器/筛选/回测/预取的整式语义）
//
//  错误文案：Python 解析/语义错误文案与已删除的 Swift TDXEngineError 逐字一致
//  （由 tdx_parse_golden.json fixture 锁死）。
//

import Foundation

enum PyTDXFormulaBridge {

    // MARK: - 结果模型

    /// 输出行单元（text_split 结果）：单元文本 = 该行依赖闭包 + 输出行的公式文本，
    /// 可独立解析求值；主图行缓存以此文本为 key（参数变仅影响对应行）
    struct PyUnit {
        let name: String
        let text: String
    }

    /// 单元求值结果（text_eval 结果）：单元级错误隔离——单行求值失败不拖垮同公式其余行
    struct PyUnitEval {
        let name: String
        let text: String
        let lines: [TDXOutputLine]
        let error: String?
    }

    // MARK: - 文本 op 核心（仅后台线程）

    /// text op 统一核心：texts 过桥（零拷贝 bars）→ 解码为按 text 对齐的结果数组。
    /// data 为 nil 时传哑序列（split 模式不读 bars）。失败 → 所有下标同报错误。
    private static func runTextOp(texts: [String], mode: String, data: [KlineItem]?,
                                  timeout: TimeInterval) -> [Result<[String: Any], String>] {
        assert(!Thread.isMainThread, "PyTDXFormulaBridge text op 禁止主线程调用（blockingCallBin）")
        guard !texts.isEmpty else { return [] }
        // 哑序列（split 不读 bars；eval 用真实 data 零拷贝）
        let dummy = [Double](repeating: 0, count: 1)
        let seriesBin: [String: [Double]] = data.map { d in
            ["c": d.map(\.close), "h": d.map(\.high), "l": d.map(\.low),
             "o": d.map(\.open), "v": d.map(\.volume), "a": d.map(\.turnover)]
        } ?? ["c": dummy, "h": dummy, "l": dummy, "o": dummy, "v": dummy, "a": dummy]
        let input: [String: Any] = [
            "__text__": 1,
            "mode": mode,
            "texts": texts.enumerated().map { ["id": $0.offset, "text": $0.element] },
        ]
        let errText: (PyBridgeError) -> String = { err in
            switch err {
            case .engineNotReady(let m): return "引擎未就绪：\(m)"
            case .timeout: return "超时（\(timeout)s）"
            case .scriptError(let m): return m
            }
        }
        switch KlinePythonBridge.shared.blockingCallBin(script: "tdx_eval", input: input,
                                                        seriesBin: seriesBin, seriesInto: "bars",
                                                        timeout: timeout) {
        case .failure(let err):
            let m = errText(err)
            return texts.map { _ in .failure(m) }
        case .success(let bin):
            guard (bin.payload["ok"] as? Bool) == true,
                  let results = bin.payload["results"] as? [[String: Any]],
                  results.count == texts.count else {
                return texts.map { _ in .failure("text op 输出非法") }
            }
            return results.enumerated().map { i, r in
                if (r["ok"] as? Bool) == true {
                    return .success(r)
                }
                return .failure((r["error"] as? String) ?? "(缺 error)")
            }
        }
    }

    // MARK: - 四个公开入口（全部仅后台线程）

    /// 公式文本 → 每输出行单元 [{name, text}]（与 formulas 下标对齐；解析失败对应下标 .failure）
    static func splitUnits(formulas: [String], timeout: TimeInterval = 20) -> [Result<[PyUnit], String>] {
        runTextOp(texts: formulas, mode: "split", data: nil, timeout: timeout).map { r in
            switch r {
            case .failure(let m): return .failure(m)
            case .success(let dict):
                let units = (dict["units"] as? [[String: Any]]) ?? []
                return .success(units.compactMap { u in
                    guard let name = u["name"] as? String, let text = u["text"] as? String else { return nil }
                    return PyUnit(name: name, text: text)
                })
            }
        }
    }

    /// 单元文本 → 该单元输出行（与 texts 下标对齐；单元失败/解析失败 → .failure）。
    /// PyTDXWave 主图波次用——单元已是拆分后的最小求值粒度。
    static func evaluateUnitTexts(texts: [String], data: [KlineItem],
                                  timeout: TimeInterval = 20) -> [Result<[TDXOutputLine], String>] {
        runTextOp(texts: texts, mode: "eval", data: data, timeout: timeout).map { r in
            switch r {
            case .failure(let m): return .failure(m)
            case .success(let dict):
                let units = (dict["units"] as? [[String: Any]]) ?? []
                // 单元文本解析后恰为一个输出行单元；行内含依赖行时目标行在最后
                let lines = units.flatMap { u -> [TDXOutputLine] in
                    guard (u["ok"] as? Bool) == true,
                          let raw = u["lines"] as? [[String: Any]] else { return [] }
                    return raw.compactMap(assembleTextLine)
                }
                return .success(lines)
            }
        }
    }

    /// 公式文本 → 单元数组（单元级错误隔离；与 formulas 下标对齐）。
    /// evaluateAsOf 用——单元成败决定主图曲线占位，与前台规则严格一致。
    static func evaluateFormulasWithUnits(formulas: [String], data: [KlineItem],
                                          timeout: TimeInterval = 20) -> [Result<[PyUnitEval], String>] {
        runTextOp(texts: formulas, mode: "eval", data: data, timeout: timeout).map { r in
            switch r {
            case .failure(let m): return .failure(m)
            case .success(let dict):
                let units = (dict["units"] as? [[String: Any]]) ?? []
                return .success(units.compactMap { u in
                    guard let name = u["name"] as? String, let text = u["text"] as? String else { return nil }
                    var lines: [TDXOutputLine] = []
                    if (u["ok"] as? Bool) == true,
                       let raw = u["lines"] as? [[String: Any]] {
                        lines = raw.compactMap(assembleTextLine)
                    }
                    return PyUnitEval(name: name, text: text, lines: lines,
                                      error: (u["error"] as? String))
                })
            }
        }
    }

    /// 公式文本 → 全部输出行（整式语义；与 formulas 下标对齐）。
    /// 任一单元失败 → 整式 .failure（镜像 Swift TDXFormulaEngine.evaluate 的 throw 语义）；
    /// 成功 → 各单元目标行（每单元最后一行）按输出行顺序拼接。
    /// 编辑器/筛选/回测/预取的统一入口。
    static func evaluateText(formulas: [String], data: [KlineItem],
                             timeout: TimeInterval = 20) -> [Result<[TDXOutputLine], String>] {
        runTextOp(texts: formulas, mode: "eval", data: data, timeout: timeout).map { r in
            switch r {
            case .failure(let m): return .failure(m)
            case .success(let dict):
                let units = (dict["units"] as? [[String: Any]]) ?? []
                var lines: [TDXOutputLine] = []
                for u in units {
                    if let e = u["error"] as? String { return .failure(e) }
                    guard (u["ok"] as? Bool) == true,
                          let raw = u["lines"] as? [[String: Any]] else {
                        return .failure("(单元缺输出)")
                    }
                    let unitLines = raw.compactMap(assembleTextLine)
                    guard let target = unitLines.last else { return .failure("(单元缺输出)") }
                    lines.append(target)
                }
                return .success(lines)
            }
        }
    }

    // MARK: - 文本行组装（样式下沉：opts 由 Python 随行返回）

    /// 文本通道行组装：{"n":名, "v":[...], "opts":[...], "d"?:[...]} → TDXOutputLine
    private static func assembleTextLine(_ l: [String: Any]) -> TDXOutputLine? {
        guard let name = l["n"] as? String else { return nil }
        var line = TDXOutputLine(name: name, values: decodeValues(l["v"]))
        if let opts = l["opts"] as? [String] {
            applyOptions(opts, to: &line)
        }
        line.hideValue = name.hasPrefix("NOTEXT_")
        if let dirs = decodeDirs(l["d"]) {
            line.markerDirections = dirs
        }
        return line
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
    /// 规则逐条镜像原 TDXEvaluator.applyOptions（该求值器已删除，本实现为唯一样式权威）
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

// MARK: - 同帧波次合并器

/// 对齐前台一次求值波次：主图 + 三个副图在同一次 runloop tick 内触发的 recompute，
/// 合并为**一次** Python call（bars 只零拷贝一份），结果按下标发回各请求方。
final class PyTDXWave {

    static let shared = PyTDXWave()

    private struct Pending {
        let barsKey: String
        let data: [KlineItem]
        let unitText: String
        let completion: (Result<[TDXOutputLine], String>) -> Void
    }

    /// 同区间请求分组（struct 替代带标签元组，规避老编译器泛型/元组解析歧义）
    private struct Group {
        let data: [KlineItem]
        var slots: [Int]
    }

    private var pending: [Pending] = []
    private var flushScheduled = false

    /// 主线程提交一次单元求值请求（unitText = 主图行缓存的单元文本 / 副图整式文本）。
    /// 同一 runloop tick 内的多个提交在下一 tick 冲刷时按 barsKey 分组合并。
    func submit(barsKey: String, data: [KlineItem], unitText: String,
                completion: @escaping (Result<[TDXOutputLine], String>) -> Void) {
        assert(Thread.isMainThread, "PyTDXWave.submit 仅限主线程（与 recompute 同帧）")
        pending.append(Pending(barsKey: barsKey, data: data, unitText: unitText, completion: completion))
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { self.flush() }
    }

    private func flush() {
        flushScheduled = false
        let batch = pending
        pending = []
        guard !batch.isEmpty else { return }
        // 按 barsKey 分组保持提交顺序；组内 slots 记录各请求在 batch 中的下标
        var order: [String] = []
        var groups: [String: Group] = [:]
        for (i, p) in batch.enumerated() {
            if groups[p.barsKey] == nil {
                groups[p.barsKey] = Group(data: p.data, slots: [])
                order.append(p.barsKey)
            }
            groups[p.barsKey]!.slots.append(i)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [Result<[TDXOutputLine], String>] = []
            results.reserveCapacity(batch.count)
            for key in order {
                let g = groups[key]!
                let texts = g.slots.map { batch[$0].unitText }
                let rs = PyTDXFormulaBridge.evaluateUnitTexts(texts: texts, data: g.data)
                for r in rs { results.append(r) }
            }
            DispatchQueue.main.async {
                for (i, p) in batch.enumerated() where i < results.count {
                    p.completion(results[i])
                }
            }
        }
    }
}

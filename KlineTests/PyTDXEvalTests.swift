//
//  PyTDXEvalTests.swift
//  KlineTests
//
//  【首帧引擎实验】tdx_eval bin 通道契约测试：Swift 原生 TDXFormulaEngine（oracle，
//  原实现未动）与 PyTDXFormulaBridge（Python bin 通道）对同一公式 + 同一数据求值，
//  逐输出行逐值对拍——覆盖零拷贝输入（ctypes）+ 二进制输出（__bin_out__）全链路。
//
//  对拍口径：
//  - 行数/顺序/名称必须一致；
//  - 值序列 NaN 位点必须逐一相同（bin 通道 NaN 以原始位直达）；
//  - 数值容差 1e-9（两侧同为 IEEE754 双精度 + 同序运算，正常应逐位一致；
//    容差只为吸收潜在的求值顺序微差，不做严格位级断言）。
//
//  skip 语义：引擎未就绪（无引擎构建 / KLINE_SKIP_ENGINE_EMBED=1）→ XCTSkip
//  （降级轮验证 Swift 兜底路径，与本测试正交）。
//

import XCTest
@testable import Kline

final class PyTDXEvalTests: XCTestCase {

    /// 固定种子合成 K 线（与 PyBridgeFirstFramePerfTests.makeBars 同 LCG；升序老→新）
    private static func makeItems(_ n: Int, seed: UInt64 = 20261012) -> [KlineItem] {
        var x = seed
        func rnd() -> Double {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return Double((x >> 11) & 0x1F_FFFF_FFFF_FFFF) / Double(0x1F_FFFF_FFFF_FFFF)
        }
        var price = 100.0
        var items: [KlineItem] = []
        items.reserveCapacity(n)
        for i in 0..<n {
            let o = price
            let c = max(1.0, o * (1 + (rnd() - 0.5) * 0.04))
            let h = max(o, c) * (1 + rnd() * 0.01)
            let l = min(o, c) * (1 - rnd() * 0.01)
            items.append(KlineItem(date: 20260101 + i, open: o, high: h, low: l, close: c,
                                  volume: Double(1000 + i), turnover: Double(10000 + i * 10)))
            price = c
        }
        return items
    }

    /// 解析公式为语句序列（复用 TDXFormulaEngine 同一入口，保证两侧吃到同一 AST）
    private static func parse(_ formula: String) throws -> [TDXStatement] {
        var lexer = TDXLexer(formula)
        let tokens = try lexer.tokenize()
        var parser = TDXParser(tokens: tokens)
        return try parser.parse()
    }

    /// NaN 位点一致 + 数值容差对拍
    private func assertLinesEqual(_ swift: [TDXOutputLine], _ py: [TDXOutputLine],
                                  _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(swift.count, py.count, "\(label)：输出行数不一致", file: file, line: line)
        for (i, (s, p)) in zip(swift, py).enumerated() {
            XCTAssertEqual(s.name, p.name, "\(label)#\(i) 行名不一致", file: file, line: line)
            XCTAssertEqual(s.values.count, p.values.count, "\(label)#\(i) 序列长度不一致", file: file, line: line)
            for j in 0..<min(s.values.count, p.values.count) {
                let a = s.values[j], b = p.values[j]
                if a.isNaN || b.isNaN {
                    XCTAssertTrue(a.isNaN && b.isNaN,
                                  "\(label)#\(i)[\(j)] NaN 位点不一致（swift=\(a) py=\(b)）",
                                  file: file, line: line)
                } else {
                    XCTAssertEqual(a, b, accuracy: 1e-9,
                                   "\(label)#\(i)[\(j)] 数值不一致（swift=\(a) py=\(b)）",
                                   file: file, line: line)
                }
            }
        }
    }

    private func requireEngine() throws {
        if !KlinePythonBridge.shared.isReady {
            let ready = expectation(description: "ensureReady")
            var failMsg: String?
            KlinePythonBridge.shared.ensureReady { result in
                if case .failure(let m) = result { failMsg = m }
                ready.fulfill()
            }
            wait(for: [ready], timeout: 60)
            if let m = failMsg {
                throw XCTSkip("引擎未就绪：\(m)（无引擎构建验证降级路径而非本测试）")
            }
        }
    }

    // MARK: - 对拍用例（公式覆盖：均线/递归/窗口极值/SAR/除零语义/多请求批）

    func testTDXEvalBinParityWithSwiftEngine() throws {
        try requireEngine()

        // 覆盖面：常量序列、双均线、递归 EMA/SMA、窗口 HHV/LLV、SAR 状态机、除零语义
        let formulas: [(String, String)] = [
            ("closeonly", "X: C;"),
            ("ma", "M5: MA(C,5);\nM10: MA(C,10);\nM60: MA(C,60);"),
            ("ema", "E12: EMA(C,12);\nS5: SMA(C,5,2);"),
            ("hhvllv", "H20: HHV(H,20);\nL10: LLV(L,10);"),
            ("sar", "S: SAR(0.02,0.2);"),
            ("divzero", "DZ: C/(C-C);\nN: C/2;"),
            ("std", "ST: STD(C,10);"),
            ("barslast", "B: BARSLAST(C > REF(C,1));"),
        ]
        let data = Self.makeItems(180)

        let exp = expectation(description: "parity")
        var failures: [String] = []
        DispatchQueue.global(qos: .userInitiated).async {
            for (label, formula) in formulas {
                do {
                    let stmts = try Self.parse(formula)
                    let oracle = try TDXFormulaEngine.evaluate(statements: stmts, data: data)
                    switch PyTDXFormulaBridge.evaluate(requests: [stmts], data: data) {
                    case .success(let batches):
                        guard let py = batches.first else {
                            failures.append("\(label)：无返回")
                            continue
                        }
                        self.assertLinesEqual(oracle, py, label)
                    case .failure(let msg):
                        failures.append("\(label)：\(msg)")
                    }
                } catch {
                    failures.append("\(label)：\(error)")
                }
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 60)
        if !failures.isEmpty {
            XCTFail("对拍失败：\(failures.joined(separator: " | "))")
        }
    }

    func testTDXEvalBinMultiRequestBatch() throws {
        try requireEngine()

        // 多请求一批（波次合并形状）：结果数与顺序对齐；SAR 方向数组可用
        let data = Self.makeItems(150)
        let stmtsA = try Self.parse("A1: MA(C,5);")
        let stmtsB = try Self.parse("B1: EMA(C,26);\nB2: SAR(0.02,0.2);")

        let exp = expectation(description: "batch")
        var failures: [String] = []
        DispatchQueue.global(qos: .userInitiated).async {
            switch PyTDXFormulaBridge.evaluate(requests: [stmtsA, stmtsB], data: data) {
            case .success(let batches):
                guard batches.count == 2 else {
                    failures.append("批结果数 \(batches.count) ≠ 2")
                    break
                }
                do {
                    let oracleA = try TDXFormulaEngine.evaluate(statements: stmtsA, data: data)
                    let oracleB = try TDXFormulaEngine.evaluate(statements: stmtsB, data: data)
                    self.assertLinesEqual(oracleA, batches[0], "batchA")
                    self.assertLinesEqual(oracleB, batches[1], "batchB")
                    // SAR 方向数组（markerDirections）必须随行返回（bin 通道不搬 d 数组，仍在 JSON）
                    let sarLine = batches[1].first { $0.markerDirections != nil }
                    XCTAssertNotNil(sarLine, "SAR 行缺 markerDirections")
                } catch {
                    failures.append("\(error)")
                }
            case .failure(let msg):
                failures.append(msg)
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 60)
        if !failures.isEmpty {
            XCTFail("批对拍失败：\(failures.joined(separator: " | "))")
        }
    }
}

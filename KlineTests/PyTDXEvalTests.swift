//
//  PyTDXEvalTests.swift
//  KlineTests
//
//  tdx_eval（Python 解析+求值）契约测试：对照 golden fixture（tdx_eval_golden.json）。
//
//  fixture 来源：2026-10-16 删除 Swift 求值器/解析器前，由 tdx_eval 在固定数据（LCG 种子
//  20261012 / 180 根升序 OHLCV）上对 goldenFormulas 全集求值生成（生成时已通过
//  Swift 差分对拍验证 ≡ Swift 语义）；解析/拆分/错误文案由 tdx_parse_golden.json +
//  scripts/verify_parse_port.py PC 差分锁死（与已删除的 Swift lexer/parser 逐字一致）。
//
//  对拍口径：行数/顺序/名称必须一致；值序列 NaN 位点逐一相同；数值为
//  Double→String 最短往返表示的逐位比对（无容差，同为 IEEE754 double）。
//
//  skip 语义：引擎未就绪（无引擎构建 / KLINE_SKIP_ENGINE_EMBED=1）→ XCTSkip。
//

import XCTest
@testable import Kline

final class PyTDXEvalTests: XCTestCase {

    /// 固定种子合成 K 线（与 PyBridgeFirstFramePerfTests.makeBars 同 LCG；升序老→新）。
    /// ⚠️ 与 fixture 生成时的数据必须保持一致——改种子/根数 = fixture 失效，须重新生成
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

    /// golden 公式集（覆盖：常量/双均线/递归 EMA+SMA/窗口极值/SAR 状态机/除零语义/STD/BARSLAST
    /// + 多请求批两条）——fixture 与测试共用
    static let goldenFormulas: [(String, String)] = [
        ("closeonly", "X: C;"),
        ("ma", "M5: MA(C,5);\nM10: MA(C,10);\nM60: MA(C,60);"),
        ("ema", "E12: EMA(C,12);\nS5: SMA(C,5,2);"),
        ("hhvllv", "H20: HHV(H,20);\nL10: LLV(L,10);"),
        ("sar", "S: SAR(0.02,0.2);"),
        ("divzero", "DZ: C/(C-C);\nN: C/2;"),
        ("std", "ST: STD(C,10);"),
        ("barslast", "B: BARSLAST(C > REF(C,1));"),
        ("batchA", "A1: MA(C,5);"),
        ("batchB", "B1: EMA(C,26);\nB2: SAR(0.02,0.2);"),
    ]

    // MARK: - fixture 对照

    private struct GoldenLine {
        let name: String
        let values: [String]   // "NaN" 或 Double 最短往返字符串
    }

    private func loadGolden() throws -> [String: [GoldenLine]] {
        let url = Bundle(for: Self.self).url(forResource: "tdx_eval_golden", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            XCTFail("golden fixture 缺失或非法：tdx_eval_golden.json")
            return [:]
        }
        var out: [String: [GoldenLine]] = [:]
        for entry in arr {
            guard let label = entry["label"] as? String,
                  let lines = entry["lines"] as? [[String: Any]] else { continue }
            out[label] = lines.map { l in
                GoldenLine(name: (l["name"] as? String) ?? "",
                           values: (l["values"] as? [String]) ?? [])
            }
        }
        return out
    }

    /// 行级对拍：行数/顺序/名称一致；NaN 位点逐一相同；数值字符串逐位一致
    private func assertLinesMatch(_ actual: [TDXOutputLine], _ golden: [GoldenLine],
                                  _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, golden.count, "\(label)：输出行数不一致", file: file, line: line)
        for (i, (a, g)) in zip(actual, golden).enumerated() {
            XCTAssertEqual(a.name, g.name, "\(label)#\(i) 行名不一致", file: file, line: line)
            XCTAssertEqual(a.values.count, g.values.count, "\(label)#\(i) 序列长度不一致", file: file, line: line)
            for j in 0..<min(a.values.count, g.values.count) {
                let v = a.values[j]
                let actualStr = v.isNaN ? "NaN" : String(v)
                XCTAssertEqual(actualStr, g.values[j],
                               "\(label)#\(i)[\(j)] 值不一致（actual=\(actualStr) golden=\(g.values[j])）",
                               file: file, line: line)
            }
        }
    }

    /// 主契约：全公式集经 evaluateText（text 通道：Python 解析+拆分+求值）对照 fixture
    func testTDXEvalAgainstGoldenFixture() throws {
        try requireEngine()
        let golden = try loadGolden()
        guard !golden.isEmpty else { return }
        let data = Self.makeItems(180)

        let exp = expectation(description: "golden parity")
        var failures: [String] = []
        DispatchQueue.global(qos: .userInitiated).async {
            for (label, formula) in Self.goldenFormulas {
                guard let expected = golden[label] else {
                    failures.append("\(label)：fixture 缺该公式")
                    continue
                }
                switch PyTDXFormulaBridge.evaluateText(formulas: [formula], data: data).first {
                case .some(.success(let lines)):
                    self.assertLinesMatch(lines, expected, label)
                case .some(.failure(let msg)):
                    failures.append("\(label)：\(msg)")
                case .none:
                    failures.append("\(label)：无返回")
                }
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 60)
        if !failures.isEmpty {
            XCTFail("golden 对拍失败：\(failures.joined(separator: " | "))")
        }
    }

    /// 多请求批一致性：batchA/batchB 两条公式合并一次 evaluateText 调用，结果须与 fixture
    /// 单请求形式逐位一致（批量 == 单次的语义恒等）
    func testTDXEvalMultiRequestBatchMatchesGolden() throws {
        try requireEngine()
        let golden = try loadGolden()
        guard let goldenA = golden["batchA"], let goldenB = golden["batchB"] else {
            XCTFail("fixture 缺 batchA/batchB"); return
        }
        let data = Self.makeItems(180)
        guard let idxA = Self.goldenFormulas.firstIndex(where: { $0.0 == "batchA" }),
              let idxB = Self.goldenFormulas.firstIndex(where: { $0.0 == "batchB" }) else {
            XCTFail("goldenFormulas 缺 batch 项"); return
        }
        let fA = Self.goldenFormulas[idxA].1
        let fB = Self.goldenFormulas[idxB].1

        let exp = expectation(description: "batch parity")
        var failures: [String] = []
        DispatchQueue.global(qos: .userInitiated).async {
            // evaluateText 一次传两条（共享 data 一次 call）
            let results = PyTDXFormulaBridge.evaluateText(formulas: [fA, fB], data: data)
            guard results.count == 2 else {
                failures.append("批结果数 \(results.count) ≠ 2")
                exp.fulfill()
                return
            }
            switch results[0] {
            case .success(let lines): self.assertLinesMatch(lines, goldenA, "batchA")
            case .failure(let m): failures.append("batchA：\(m)")
            }
            switch results[1] {
            case .success(let lines):
                self.assertLinesMatch(lines, goldenB, "batchB")
                // SAR 方向数组（markerDirections）必须随行返回
                let sarLine = lines.first { $0.markerDirections != nil }
                XCTAssertNotNil(sarLine, "SAR 行缺 markerDirections")
            case .failure(let m): failures.append("batchB：\(m)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 60)
        if !failures.isEmpty {
            XCTFail("批对拍失败：\(failures.joined(separator: " | "))")
        }
    }
}

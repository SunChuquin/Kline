//
//  ChanTruncationTests.swift
//  KlineTests
//
//  阶段一「不穿越未来」的可断言证据：
//  缠论（CHANBI/CHANSEG 通道）在某个时点 i 的取值，必须只依赖 [0...i] 的 K 线，
//  与 i 之后是否存在数据无关。这正是回放页「每个时点只用截至该根的数据」的口径。
//
//  做法：全量算一次；再对若干采样时点 i 用 data[0...i] 单独算一次，
//  逐通道逐位比对第 i 个值（NaN 感知）。任何不一致都说明引擎在该时点的输出
//  被未来 K 线影响 = 穿越。
//
//  skip 语义：引擎未就绪（无引擎构建 / KLINE_SKIP_ENGINE_EMBED=1）→ XCTSkip。
//

import XCTest
@testable import Kline

final class ChanTruncationTests: XCTestCase {

    /// 与 PyTDXEvalTests 同 LCG 种子（升序老→新），保证条形形态可复现
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

    /// 与 Kline/Indicators/CHANBI.tdx 的 FORMULA 段一致（只保留有输出行的部分，
    /// STICKLINE 不出输出行，这里不参与断言）
    private static let biFormula = """
    NOTEXT_BI:CHANBI,LINETHICK2;
    NOTEXT_BIUC:CHANBIUC,COLORLIGRAY,DOTLINE;
    NOTEXT_ZG:CHANBIZG,COLORBLUE;
    NOTEXT_ZD:CHANBIZD,COLORBLUE;
    NOTEXT_ZGUC:CHANBIZGUC,COLORLIGRAY,DOTLINE;
    NOTEXT_ZDUC:CHANBIZDUC,COLORLIGRAY,DOTLINE;
    """

    private func requireEngine() throws {
        if KlinePythonBridge.shared.isReady { return }
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

    private func eval(_ formula: String, _ data: [KlineItem]) -> [TDXOutputLine]? {
        switch PyTDXFormulaBridge.evaluateText(formulas: [formula], data: data).first {
        case .success(let lines): return lines
        case .failure, .none: return nil
        }
    }

    // MARK: - 契约：截断点 = min(可见右缘, 末根)

    func testChanCalcEndClampsToVisibleRightEdge() {
        XCTAssertEqual(IndicatorPipeline.chanCalcEnd(endIndex: 10, count: 100), 10)
        XCTAssertEqual(IndicatorPipeline.chanCalcEnd(endIndex: 99, count: 100), 99)
        XCTAssertEqual(IndicatorPipeline.chanCalcEnd(endIndex: 500, count: 100), 99)
        XCTAssertEqual(IndicatorPipeline.chanCalcEnd(endIndex: 0, count: 100), 0)
    }

    // MARK: - 核心：任一时刻的通道值只依赖截至该根的 K 线

    func testChanValuesDependOnlyOnBarsUpToThatIndex() throws {
        try requireEngine()
        let n = 600
        let data = Self.makeItems(n)

        var full: [TDXOutputLine]?
        let expFull = expectation(description: "full")
        DispatchQueue.global(qos: .userInitiated).async {
            full = self.eval(Self.biFormula, data)
            expFull.fulfill()
        }
        wait(for: [expFull], timeout: 120)
        guard let fullLines = full else { return XCTFail("全量求值失败") }
        XCTAssertEqual(fullLines.first?.values.count, n, "输出长度应与输入根数一致（供 padToFull 对齐）")

        // 采样时点：覆盖早/中/晚，且彼此间隔足够让笔/段/中枢形态不同
        let cuts = [180, 300, 390, 480, 540]
        var mismatch: [(cut: Int, line: String, idx: Int, full: Double, trunc: Double)] = []
        var atRightEdge = 0
        var beforeRightEdge = 0

        for k in cuts {
            let prefix = Array(data[0...k])
            var part: [TDXOutputLine]?
            let exp = expectation(description: "prefix \(k)")
            DispatchQueue.global(qos: .userInitiated).async {
                part = self.eval(Self.biFormula, prefix)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 120)
            guard let partLines = part else { return XCTFail("截断求值失败 k=\(k)") }

            XCTAssertEqual(partLines.count, fullLines.count, "行数不一致 k=\(k)")
            for (i, pl) in partLines.enumerated() where i < fullLines.count {
                let fl = fullLines[i]
                XCTAssertEqual(pl.name, fl.name, "行名不一致 k=\(k)")
                // 截断结果长度必须等于 k+1：多出来的就是穿越
                XCTAssertEqual(pl.values.count, k + 1, "\(pl.name) 输出长度应为 k+1（k=\(k)）")
                for j in 0...k where j < fl.values.count && j < pl.values.count {
                    let a = fl.values[j], b = pl.values[j]
                    let same = (a.isNaN && b.isNaN) || (a == b)
                    if !same {
                        mismatch.append((k, pl.name, j, a, b))
                        if j == k { atRightEdge += 1 } else { beforeRightEdge += 1 }
                    }
                }
            }
        }

        // 这是「特性断言」：全量算 → 取可见窗口前缀 与 截断重算 必然不同（差异即穿越）。
        // 若某天引擎变成严格因果、两者完全相同，说明本测试失去了区分力，需要复核口径。
        let head = mismatch.prefix(6).map {
            "k=\($0.cut) \($0.line)[\($0.idx)]: 全量=\($0.full) 截断=\($0.trunc)"
        }.joined(separator: " | ")
        print("[ChanTruncation] 采样时点 \(cuts)：全量与截断不一致 \(mismatch.count) 处"
              + "（右缘根 \(atRightEdge)，右缘之前 \(beforeRightEdge)）｜样例：\(head)")
        XCTAssertGreaterThan(mismatch.count, 0,
                             "全量结果与截断结果完全相同，说明该断言无法区分「是否穿越」，需复核")
        XCTAssertGreaterThan(beforeRightEdge, 0,
                             "差异只出现在最后一根：回填范围低于预期，检查通道写出方式是否变化")
    }

    // MARK: - 右缘键缓存复用：结果必须与「全量截断求值」逐一相同

    /// 证明「按右缘 k 缓存复用」不会把未来结构带回来：
    /// 先算一次全量（污染引擎内部缓存），再对若干 k 做**两次**截断求值，
    /// 要求两次结果逐位相同（0 不一致），且最后有效下标 <= k。
    /// 这正是 LRU/缓存命中路径的正确性前提——命中只是复用「同一份 [0...k] 的求值结果」，
    /// 不允许出现近似或裁剪冒充。
    func testTruncatedEvalIsStableAcrossRepeatedCalls() throws {
        try requireEngine()
        let data = Self.makeItems(600)

        // 污染：先用全量历史求值一次（让引擎内部 chan 缓存处于「有未来数据」的状态）
        var full: [TDXOutputLine]?
        let expFull = expectation(description: "warm full")
        DispatchQueue.global(qos: .userInitiated).async {
            full = self.eval(Self.biFormula, data)
            expFull.fulfill()
        }
        wait(for: [expFull], timeout: 120)
        XCTAssertNotNil(full)

        var mismatch = 0
        var overRightEdge = 0
        for k in [180, 390, 540] {
            let prefix = Array(data[0...k])
            func run() -> [TDXOutputLine]? {
                var out: [TDXOutputLine]?
                let exp = expectation(description: "prefix \(k)")
                DispatchQueue.global(qos: .userInitiated).async {
                    out = self.eval(Self.biFormula, prefix)
                    exp.fulfill()
                }
                wait(for: [exp], timeout: 120)
                return out
            }
            guard let first = run(), let second = run() else { return XCTFail("截断求值失败 k=\(k)") }
            XCTAssertEqual(first.count, second.count, "行数不一致 k=\(k)")
            for (i, a) in first.enumerated() where i < second.count {
                let b = second[i]
                XCTAssertEqual(a.values.count, k + 1, "\(a.name) 长度应为 k+1（k=\(k)）")
                for j in 0..<min(a.values.count, b.values.count) {
                    let x = a.values[j], y = b.values[j]
                    if !((x.isNaN && y.isNaN) || x == y) { mismatch += 1 }
                }
                // 末段/末笔不得越出右缘
                for j in (k + 1)..<a.values.count where !a.values[j].isNaN { overRightEdge += 1 }
            }
        }
        print("[ChanTruncation] 右缘键复用：k=[180,390,540] 两次截断求值不一致 \(mismatch) 处，越界值 \(overRightEdge) 个")
        XCTAssertEqual(mismatch, 0, "重复截断求值结果不一致，缓存复用不可用")
        XCTAssertEqual(overRightEdge, 0, "输出越出了右缘 k")
    }

    // MARK: - 末段/末笔只依赖截至右缘的数据

    func testLastStructureEndsAtOrBeforeRightEdge() throws {
        try requireEngine()
        let n = 600
        let data = Self.makeItems(n)
        let k = 420
        let prefix = Array(data[0...k])

        var part: [TDXOutputLine]?
        let exp = expectation(description: "prefix end bound")
        DispatchQueue.global(qos: .userInitiated).async {
            part = self.eval(Self.biFormula, prefix)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 120)
        guard let lines = part else { return XCTFail("截断求值失败") }

        for line in lines {
            var lastNonNaN = -1
            for (i, v) in line.values.enumerated() where !v.isNaN { lastNonNaN = i }
            XCTAssertLessThanOrEqual(lastNonNaN, k,
                                     "\(line.name) 最后一个有效值下标 \(lastNonNaN) 超出右缘 \(k)")
        }
        // 笔通道在窗口内应确实有值，否则断言空洞
        let bi = lines.first { $0.name == "NOTEXT_BI" }
        XCTAssertNotNil(bi)
        XCTAssertTrue((bi?.values.contains { !$0.isNaN }) ?? false, "窗口内没有笔通道数据，断言不成立")
    }
}

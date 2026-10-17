//
//  StrategyTdxBoundaryTests.swift
//  KlineTests
//
//  阶段 E-2：`.tdx` 文件边界的 TRADE 段下沉契约测试。
//
//  `.tdx` 的**段落切分**（KIND= / NAME= / PICKREF= / PICK: / RULES:）仍属 GUI 侧；
//  本套件只验证被下沉的那一段（TRADE）在两种后端下**逐字一致**：
//    · `.swift`  → `serialize` / `parse`（`StrategyTradeParser`，现状实现）
//    · `.engine` → `serializeAsync` / `parseAsync`（`trade_serialize` / `trade_parse`）
//  引擎未就绪 → `XCTSkip`（降级路径的验证在无引擎构建里，见 §9.10）。
//

import XCTest
@testable import Kline

@MainActor
final class StrategyTdxBoundaryTests: XCTestCase {

    private func ensureEngineReady() async throws {
        if KlinePythonBridge.shared.isReady { return }
        var failureMsg: String?
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            KlinePythonBridge.shared.ensureReady { r in
                if case .failure(let m) = r { failureMsg = m }
                cont.resume()
            }
        }
        if let m = failureMsg {
            throw XCTSkip("Python 引擎未就绪：\(m)——无引擎构建验证降级路径而非失败")
        }
    }

    /// 全字段策略文档（TRADE 段覆盖全部键，含 EXPIRES / ACCOUNTS）
    private func fullDoc() -> FormulaDoc {
        var spec = StrategyTradeSpec()
        spec.direction = .buy
        spec.qty = 300
        spec.amount = nil
        spec.priceType = .limit
        spec.offsetTicks = 2
        spec.validity = .untilDate
        spec.expiresAt = Date(timeIntervalSince1970: 1_798_704_000)
        spec.accountIDs = [UUID(uuidString: "E621E1F8-C36C-495A-8F1F-1D9A3B5F3E0D")!]
        var doc = FormulaDoc(id: "STR_1", kind: .strategy, name: "策略A",
                             pickBody: "C>1 AND C>REF(C,1)")
        doc.pickRef = nil
        doc.rules = "PRICE(OP=>=, VALUE=1480)\nSTOP_LOSS(MODE=PCT, PROFIT=10, LOSS=5)"
        doc.trade = spec
        return doc
    }

    // MARK: - 序列化：两种后端逐字一致

    func testSerializeParityAcrossModes() async throws {
        try await ensureEngineReady()
        let doc = fullDoc()
        let swiftText = FormulaLibraryStore.serialize(doc)
        let engineText = try await FormulaLibraryStore.serializeAsync(doc)
        XCTAssertEqual(normalizedText(swiftText), normalizedText(engineText),
                       "`.swift` / `.engine` 的 .tdx 序列化必须逐字一致")
    }

    /// 无 TRADE 段的策略（旧文件）与选股公式：两种后端同样逐字一致（不涉引擎）
    func testSerializeParityWithoutTrade() async throws {
        try await ensureEngineReady()
        var doc = FormulaDoc(id: "STR_2", kind: .strategy, name: "策略B", pickBody: "C>1")
        doc.rules = "TIME(DATE=2026-12-31, AT=09:30)"
        let engineNoTrade = try await FormulaLibraryStore.serializeAsync(doc)
        XCTAssertEqual(normalizedText(FormulaLibraryStore.serialize(doc)),
                       normalizedText(engineNoTrade))

        let picker = FormulaDoc(id: "PICK_1", kind: .picker, name: "放量", pickBody: "V>REF(V,1)*2")
        let enginePicker = try await FormulaLibraryStore.serializeAsync(picker)
        XCTAssertEqual(normalizedText(FormulaLibraryStore.serialize(picker)),
                       normalizedText(enginePicker))
    }

    // MARK: - 解析：两种后端结果相等（往返）

    func testParseParityRoundTrip() async throws {
        try await ensureEngineReady()
        let doc = fullDoc()
        let content = FormulaLibraryStore.serialize(doc)

        let swiftDoc = FormulaLibraryStore.parse(content: content, id: "STR_1", kind: .strategy)
        let engineDoc = try await FormulaLibraryStore.parseAsync(content: content, id: "STR_1",
                                                                kind: .strategy)
        XCTAssertNotNil(swiftDoc)
        XCTAssertNotNil(engineDoc)
        XCTAssertEqual(normalizedText(jsonText(SimRulesCodec.tradeSpecJSON(swiftDoc!.trade))),
                       normalizedText(jsonText(SimRulesCodec.tradeSpecJSON(engineDoc!.trade))),
                       "`.swift` / `.engine` 解析出的 TRADE 段必须相等")
        // 段落切分（非 TRADE）也要一致
        XCTAssertEqual(swiftDoc?.rules, engineDoc?.rules)
        XCTAssertEqual(swiftDoc?.pickBody, engineDoc?.pickBody)
        XCTAssertEqual(swiftDoc?.name, engineDoc?.name)
        XCTAssertEqual(swiftDoc?.pickRef, engineDoc?.pickRef)
    }

    /// KIND= 与期望类型不符 → 两种后端都返回 nil（不因引擎参与而改变「跳过」语义）
    func testParseSkipsMismatchedKindInBothModes() async throws {
        try await ensureEngineReady()
        let content = FormulaLibraryStore.serialize(fullDoc())   // KIND=STRATEGY
        XCTAssertNil(FormulaLibraryStore.parse(content: content, id: "X", kind: .picker))
        let engineResult = try await FormulaLibraryStore.parseAsync(content: content, id: "X",
                                                                   kind: .picker)
        XCTAssertNil(engineResult, "类型不符必须跳过，不能被引擎路径放行")
    }

    // MARK: - 比较辅助

    private func jsonText(_ o: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "<encode-failed>" }
        return s
    }

    /// 换行归一化后再比（避免 CRLF 差异干扰）
    private func normalizedText(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
    }
}

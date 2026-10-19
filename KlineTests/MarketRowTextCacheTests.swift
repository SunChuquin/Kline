//
//  MarketRowTextCacheTests.swift
//  KlineTests
//
//  §11.41 回归网：`MarketRow.text()` 的文本缓存必须随**引擎值写入/清空**失效。
//
//  背景（2026-10-19 实测）：清除 Swift 兜底后字段只有引擎一个来源，而引擎快照是异步到达的。
//  UI 常在快照到达前先渲染一次 → 那时 `number()` 为空 → `text()` 把 `"-"` 写进 `textCache`；
//  旧实现 `setPythonValue` 不失效该缓存 → 引擎真值写入后 `text()` 仍返回 `"-"`，
//  表现为**行情表 / 行情卡片 / 自选 / 快捷面板 / 下单面板 / 条件单编辑全列恒显 "-"**
//  （沙盒日志同期显示快照批量计算全部成功，证明不是引擎没算）。
//

import XCTest
@testable import Kline

@MainActor
final class MarketRowTextCacheTests: XCTestCase {

    private func makeRow() -> MarketRow {
        MarketRow(meta: MetaItem(id: 1, file: "SH#600000", code: "600000", name: "浦发银行",
                                 type: "沪深主板", firstDate: 20200101, lastDate: 20200101))
    }

    private func bars() -> [KlineItem] {
        [KlineItem(date: 20260102, open: 12.0, high: 13.0, low: 11.0, close: 12.5,
                   volume: 1000, turnover: 10000)]
    }

    /// 引擎值到达前 → 显式空态；到达后 → 文本必须立刻反映真值（旧实现会卡在 "-"）。
    func testTextFollowsEngineValues() {
        let row = makeRow()
        row.setBars(bars())
        XCTAssertEqual(row.text(.latestPrice), "-", "引擎快照未写入时应为显式空态")
        XCTAssertEqual(row.text(.changePct), "-", "引擎快照未写入时应为显式空态")

        row.setPythonValue(12.34, for: .latestPrice)
        row.setPythonValue(1.25, for: .changePct)

        XCTAssertEqual(row.number(.latestPrice), 12.34)
        XCTAssertEqual(row.text(.latestPrice), "12.34", "引擎值写入后文本必须立即更新（textCache 未失效即报此错）")
        XCTAssertEqual(row.text(.changePct), "+1.25%", "引擎值写入后文本必须立即更新")
    }

    /// 引擎返回 nil（引擎判定「无值」）→ 空态，不得留旧值。
    func testNilEngineValueRendersEmptyState() {
        let row = makeRow()
        row.setBars(bars())
        row.setPythonValue(9.99, for: .latestPrice)
        XCTAssertEqual(row.text(.latestPrice), "9.99")

        row.setPythonValue(nil, for: .latestPrice)
        XCTAssertNil(row.number(.latestPrice))
        XCTAssertEqual(row.text(.latestPrice), "-", "引擎给 nil 时应回到空态，不得保留旧文本")
    }

    /// 引擎失败清空 → 全部回到空态（显式空态，不做 Swift 兜底）。
    func testClearPythonValuesResetsText() {
        let row = makeRow()
        row.setBars(bars())
        row.setPythonValue(12.34, for: .latestPrice)
        XCTAssertEqual(row.text(.latestPrice), "12.34")

        row.clearPythonValues()
        XCTAssertNil(row.number(.latestPrice))
        XCTAssertEqual(row.text(.latestPrice), "-")
    }
}

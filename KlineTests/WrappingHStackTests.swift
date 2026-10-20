//
//  WrappingHStackTests.swift
//  KlineTests
//
//  §回归网：WrappingHStack 断行纯函数（WrappingHStackLayoutMath.layout）的行为锚点。
//
//  背景：App 按 iPad 调校，iPhone 11（竖屏 414pt）上多行水平内容超宽出屏，
//  WrappingHStack 是模拟页指标行、自选 C 工具行、账户卡网格等统一复用的
//  流式换行基建——断行规则一错全线返工，故把「放不下才换行 / 单项超宽独占一行
//  不裁切 / 空集合零高度 / 对齐排布」钉死在单测里。
//

import XCTest
@testable import Kline

final class WrappingHStackTests: XCTestCase {

    /// 与组件默认间距一致：指标胶囊间的 8pt
    private let spacing: CGFloat = 8

    /// 414 宽 + 间距 8：3 个 100 宽项 → 3×100 + 2×8 = 316 ≤ 414，必须单行
    func testThreeItemsFitInOneRow() {
        let sizes = Array(repeating: CGSize(width: 100, height: 30), count: 3)
        let layout = WrappingHStackLayoutMath.layout(
            sizes: sizes, availableWidth: 414,
            horizontalSpacing: spacing, rowSpacing: spacing, alignment: .leading)

        XCTAssertEqual(layout.rows.count, 1, "316 放得下 414，应为单行")
        XCTAssertEqual(layout.rows[0].itemIndices, [0, 1, 2])
        XCTAssertEqual(layout.rows[0].contentWidth, 316)
        XCTAssertEqual(layout.totalSize.height, 30, "单行总高 = 行内最高项")
        XCTAssertEqual(layout.positions[0], CGPoint(x: 0, y: 0))
        XCTAssertEqual(layout.positions[2], CGPoint(x: 216, y: 0), "左对齐：第 3 项 x = 100+8+100+8")
    }

    /// 5 个 100 宽项：第 4 项起 316+8+100=424 > 414 换行 → 2 行，第二行 2 项
    func testFiveItemsWrapIntoTwoRows() {
        let sizes = Array(repeating: CGSize(width: 100, height: 30), count: 5)
        let layout = WrappingHStackLayoutMath.layout(
            sizes: sizes, availableWidth: 414,
            horizontalSpacing: spacing, rowSpacing: spacing, alignment: .leading)

        XCTAssertEqual(layout.rows.count, 2, "第 4 项 424 > 414 应触发换行")
        XCTAssertEqual(layout.rows[0].itemIndices, [0, 1, 2], "第一行应放 3 项")
        XCTAssertEqual(layout.rows[1].itemIndices, [3, 4], "第二行应放剩下 2 项")
        XCTAssertEqual(layout.totalSize.height, 68, "总高 = 30 + 行距 8 + 30")
        XCTAssertEqual(layout.positions[3], CGPoint(x: 0, y: 38), "第二行从 y = 30+8 起")
    }

    /// 单个 500 宽项在 414 容器：独占一行、行宽如实报 500（不裁切）
    func testOversizedItemOccupiesOwnRowUncut() {
        let layout = WrappingHStackLayoutMath.layout(
            sizes: [CGSize(width: 500, height: 30)], availableWidth: 414,
            horizontalSpacing: spacing, rowSpacing: spacing, alignment: .leading)

        XCTAssertEqual(layout.rows.count, 1)
        XCTAssertEqual(layout.rows[0].contentWidth, 500, "超宽行宽应如实上报，不截到容器宽")
        XCTAssertEqual(layout.totalSize.width, 500)
        XCTAssertEqual(layout.positions[0], CGPoint(x: 0, y: 0), "超宽行从原点起，右侧溢出显示")
    }

    /// 超宽项后面的正常项必须换到新行，不被吸进超宽行
    func testItemAfterOversizedStartsNewRow() {
        let layout = WrappingHStackLayoutMath.layout(
            sizes: [CGSize(width: 500, height: 30), CGSize(width: 100, height: 30)],
            availableWidth: 414,
            horizontalSpacing: spacing, rowSpacing: spacing, alignment: .leading)

        XCTAssertEqual(layout.rows.count, 2)
        XCTAssertEqual(layout.rows[0].itemIndices, [0], "超宽项独占第一行")
        XCTAssertEqual(layout.rows[1].itemIndices, [1])
        XCTAssertEqual(layout.positions[1], CGPoint(x: 0, y: 38))
    }

    /// 空集合 → 0 行 0 高（组件渲染空、高度自适应为 0 的锚点）
    func testEmptyItemsProduceZeroRowsAndHeight() {
        let layout = WrappingHStackLayoutMath.layout(
            sizes: [], availableWidth: 414,
            horizontalSpacing: spacing, rowSpacing: spacing, alignment: .leading)

        XCTAssertTrue(layout.rows.isEmpty)
        XCTAssertTrue(layout.positions.isEmpty)
        XCTAssertEqual(layout.totalSize, .zero)
    }

    /// 行高取行内最高项；alignment 决定行内水平排布（在 414 容器内验证三档）
    func testRowHeightAndAlignment() {
        let sizes = [CGSize(width: 100, height: 20),
                     CGSize(width: 100, height: 40),
                     CGSize(width: 100, height: 30)]
        let contentWidth: CGFloat = 3 * 100 + 2 * spacing  // 316

        let leading = WrappingHStackLayoutMath.layout(
            sizes: sizes, availableWidth: 414,
            horizontalSpacing: spacing, rowSpacing: spacing, alignment: .leading)
        XCTAssertEqual(leading.rows[0].height, 40, "行高应取行内最高项")
        XCTAssertEqual(leading.totalSize.height, 40)
        XCTAssertEqual(leading.positions[1], CGPoint(x: 108, y: 0))

        let centered = WrappingHStackLayoutMath.layout(
            sizes: sizes, availableWidth: 414,
            horizontalSpacing: spacing, rowSpacing: spacing, alignment: .center)
        XCTAssertEqual(centered.positions[0].x, (414 - contentWidth) / 2, accuracy: 0.001,
                       "居中起始 x = (414-316)/2 = 49")
        XCTAssertEqual(centered.positions[2].x, 49 + 2 * 108, accuracy: 0.001,
                       "居中行内间距推进不变")

        let trailing = WrappingHStackLayoutMath.layout(
            sizes: sizes, availableWidth: 414,
            horizontalSpacing: spacing, rowSpacing: spacing, alignment: .trailing)
        XCTAssertEqual(trailing.positions[0].x, 98, accuracy: 0.001,
                       "右对齐起始 x = 414-316 = 98")
        XCTAssertEqual(trailing.positions[2].x, 98 + 2 * 108, accuracy: 0.001)
    }
}

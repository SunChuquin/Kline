//
//  CompactWidthTests.swift
//  KlineTests
//
//  §回归网：紧凑宽度判定（AdaptiveStack / 配置 hstack / 模拟指标带 / 首页 widget 共用）。
//  背景：竖屏垂直堆栈规则曾散落在 sizeClass 与「宽度 < 600」两套信号上，iPad 分屏 /
//  旋转时可能互相打架。收口后 `CompactWidth.isCompact` 是唯一阈值入口，这里把边界
//  与「0 = 尚未测量」语义钉死，防止后续页面各自另拍阈值。
//

import XCTest
@testable import Kline

final class CompactWidthTests: XCTestCase {

    /// 0 表示尚未测量（WidthReader 首帧 / Preview 未注入），不能算紧凑
    func testZeroWidthIsNotCompact() {
        XCTAssertFalse(CompactWidth.isCompact(0))
        XCTAssertFalse(CompactWidth.isCompact(-1))
    }

    /// iPhone 11 竖屏 414 命中紧凑
    func testPhonePortraitIsCompact() {
        XCTAssertTrue(CompactWidth.isCompact(414))
        XCTAssertTrue(CompactWidth.isCompact(CompactWidth.threshold - 1))
    }

    /// 阈值本身及更宽不命中（iPhone 11 横屏 848 / iPad mini 5 768、1024）
    func testThresholdAndWiderAreRegular() {
        XCTAssertFalse(CompactWidth.isCompact(CompactWidth.threshold))
        XCTAssertFalse(CompactWidth.isCompact(848))
        XCTAssertFalse(CompactWidth.isCompact(768))
        XCTAssertFalse(CompactWidth.isCompact(1024))
    }
}

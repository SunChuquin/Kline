//
//  ChanReplayUITests.swift
//  KlineUITests
//
//  阶段一「不穿越未来」的机械验证：主图同时挂上两个缠论指标后，
//  长距离拖动 / 来回拖 / 缩放 必须不崩溃、图表仍可交互、缠论指标仍显示。
//
//  为什么用 XCUITest：每次抬手都会按新的可见右缘重算缠论，
//  这是最容易触发越界/空数组/长度不一致闪退的路径；同时挂两个缠论指标
//  是此前闪退的复现前提。
//
//  只负责机械项；线条在真机上是否可辨属于视觉判断，留给用户。
//

import XCTest

final class ChanReplayUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openChart(_ app: XCUIApplication) {
        let market = app.buttons["tab.market"]
        XCTAssertTrue(market.waitForExistence(timeout: 30), "底部「市场」入口未出现")
        market.tap()

        let row = app.descendants(matching: .any).matching(identifier: "market.rowCard").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "行情列表未出现")
        row.tap()

        XCTAssertTrue(app.buttons["kline.backButton"].waitForExistence(timeout: 120),
                      "K 线页未出现（含引擎首次加载）")
    }

    private func enableBothChanIndicators(_ app: XCUIApplication) {
        let ind = app.buttons["chart.mainIndicatorButton"]
        XCTAssertTrue(ind.waitForExistence(timeout: 30), "主图指标入口未出现")
        ind.tap()
        for name in ["缠论笔中枢", "缠论段中枢"] {
            let tile = app.buttons["chart.indicator.main.\(name)"]
            XCTAssertTrue(tile.waitForExistence(timeout: 15), "主图指标面板未出现 \(name)")
            tile.tap()
        }
        let done = app.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "主图指标面板没有「完成」")
        done.tap()
        XCTAssertTrue(ind.label.contains("缠论笔中枢"), "主图未挂上 缠论笔中枢：\(ind.label)")
        XCTAssertTrue(ind.label.contains("缠论段中枢"), "主图未挂上 缠论段中枢：\(ind.label)")
    }

    /// 归一化坐标拖动：dy 固定落在主图区域，避开标题栏与底部指标带
    private func drag(_ app: XCUIApplication, fromX: CGFloat, toX: CGFloat, hold: TimeInterval = 0.05) {
        let a = app.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: 0.45))
        let b = app.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: 0.45))
        a.press(forDuration: hold, thenDragTo: b)
    }

    private func assertAlive(_ app: XCUIApplication, _ stage: String) {
        XCTAssertEqual(app.state, .runningForeground, "\(stage)：App 已不在前台（疑似闪退）")
        XCTAssertTrue(app.buttons["kline.backButton"].exists, "\(stage)：K 线页已消失")
        let ind = app.buttons["chart.mainIndicatorButton"]
        XCTAssertTrue(ind.exists, "\(stage)：主图指标入口消失")
        XCTAssertTrue(ind.label.contains("缠论"), "\(stage)：缠论指标不再显示：\(ind.label)")
    }

    /// 归一化坐标慢速拖动（withVelocity 压低，避免触发惯性滑动导致右缘不可预测）
    private func slowDrag(_ app: XCUIApplication, fromX: CGFloat, toX: CGFloat) {
        let a = app.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: 0.45))
        let b = app.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: 0.45))
        a.press(forDuration: 1.2, thenDragTo: b, withVelocity: 200, thenHoldForDuration: 0.4)
    }

    /// 平移耗时的可复现路径：慢速左拖 → 慢速右拖回原右缘，重复 3 轮。
    /// 断言只做"活着 + 指标在"，耗时数字由设备日志 [ChanTiming] / [ChanTiming] lru-hit 佐证：
    /// 新右缘应只有 2 条 foreground（CHANBI/CHANSEG），回到算过的右缘应只剩 lru-hit、无 foreground。
    func testChanPanTimingAndLruReuse() throws {
        let app = XCUIApplication.launchingClean()
        app.launch()
        openChart(app)
        enableBothChanIndicators(app)
        Thread.sleep(forTimeInterval: 5)
        assertAlive(app, "计时初始")

        for i in 0..<3 {
            slowDrag(app, fromX: 0.62, toX: 0.30)   // 向左看历史：右缘变小 → 新右缘
            Thread.sleep(forTimeInterval: 2.0)
            assertAlive(app, "第 \(i + 1) 轮左拖")
            slowDrag(app, fromX: 0.30, toX: 0.62)   // 拖回原右缘：应命中右缘键缓存
            Thread.sleep(forTimeInterval: 2.0)
            assertAlive(app, "第 \(i + 1) 轮回拖")
        }
        Thread.sleep(forTimeInterval: 3)
        assertAlive(app, "计时收尾")
    }

    // MARK: - 机械验证主用例

    func testChanIndicatorsSurviveLongPanAndZoom() throws {
        let app = XCUIApplication.launchingClean()
        app.launch()
        openChart(app)
        enableBothChanIndicators(app)

        // 等首轮缠论算完，避免在“还没算完”时就开始拖
        Thread.sleep(forTimeInterval: 4)
        assertAlive(app, "初始")

        // 1) 长距离来回拖（模拟此前闪退的长拖动路径）
        for i in 0..<8 {
            drag(app, fromX: 0.15, toX: 0.88, hold: 1.2)   // 往左看历史
            assertAlive(app, "长拖 \(i + 1) 左")
            drag(app, fromX: 0.88, toX: 0.15, hold: 1.2)   // 拉回最新
            assertAlive(app, "长拖 \(i + 1) 右")
            Thread.sleep(forTimeInterval: 0.8)
        }

        // 2) 快速小幅来回拖（连续改变右缘，压测重算排队）
        for i in 0..<16 {
            let left = i % 2 == 0
            drag(app, fromX: left ? 0.35 : 0.65, toX: left ? 0.65 : 0.35, hold: 0.05)
            assertAlive(app, "快拖 \(i + 1)")
            Thread.sleep(forTimeInterval: 0.35)
        }

        // 3) 缩放：缩小再放大（右缘不变时应零重算，右缘变化时只算一次）
        app.pinch(withScale: 0.4, velocity: -2)
        Thread.sleep(forTimeInterval: 1.2)
        assertAlive(app, "缩小")
        app.pinch(withScale: 2.5, velocity: 2)
        Thread.sleep(forTimeInterval: 1.2)
        assertAlive(app, "放大")

        // 4) 缩放后再长拖一轮，确认交互链路没被破坏
        drag(app, fromX: 0.2, toX: 0.85, hold: 1.0)
        Thread.sleep(forTimeInterval: 1.0)
        assertAlive(app, "缩放后长拖")
        drag(app, fromX: 0.85, toX: 0.2, hold: 1.0)
        Thread.sleep(forTimeInterval: 1.5)
        assertAlive(app, "缩放后回拖")

        // 等最后一次重算落盘，再确认还活着
        Thread.sleep(forTimeInterval: 3)
        assertAlive(app, "收尾")
    }
}

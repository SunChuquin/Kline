//
//  SheetOverlayUITests.swift
//  KlineUITests
//
//  P2-5a 弹层浮层链路的端到端机械验证（Web 面板在 WKWebView 内渲染）：
//   行情页 → 进 K 线详情 → 点设置按钮 → Web K线设置面板出现（"K线设置" 标题可达）
//   → 点完成 → 面板关闭、返回详情页。
//
//  为什么用 XCUITest：弹层链路涉及「原生状态 → sheet.open 事件 → 浮层 WebView 就绪 →
//  面板渲染」的跨层时序（此前真机白屏 bug 即时序问题），纯协议 curl 无法覆盖 UI 呈现。
//

import XCTest

final class SheetOverlayUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openChart(_ app: XCUIApplication) {
        let market = app.buttons["tab.market"]
        XCTAssertTrue(market.waitForExistence(timeout: 30), "底部「市场」入口未出现")
        market.tap()

        // Web 行情行（WKWebView 内 div 行卡：aria-label 前缀 market.rowCard）
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'market.rowCard'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "行情列表行未出现（Web 表格）")
        row.tap()

        XCTAssertTrue(app.buttons["kline.backButton"].waitForExistence(timeout: 120),
                      "K 线页未出现（含引擎首次加载）")
    }

    func testSettingsSheetOpensAndCloses() throws {
        let app = XCUIApplication.launchingClean()
        app.launch()

        openChart(app)

        // 打开 K线设置（原生按钮 → sheet.open 事件 → Web 面板渲染）
        let settingsButton = app.buttons["kline.settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15), "设置按钮未出现")
        settingsButton.tap()

        // Web 面板标题可达（WKWebView 可访问性树：staticText label = 文本内容）
        let panelTitle = app.staticTexts["K线设置"]
        XCTAssertTrue(panelTitle.waitForExistence(timeout: 15),
                      "Web K线设置面板未出现（弹层时序/白屏回归）")

        // 显示组开关存在（Web 内容可达性抽查）
        XCTAssertTrue(app.staticTexts["跳空缺口"].waitForExistence(timeout: 10),
                      "设置面板显示组未渲染")

        // 点完成关闭 → 面板消失、详情页仍在
        let done = app.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "完成按钮未出现")
        done.tap()
        XCTAssertFalse(panelTitle.waitForExistence(timeout: 5),
                       "面板关闭后标题仍可达")
        XCTAssertTrue(app.buttons["kline.backButton"].exists, "关闭后应仍在 K 线详情页")
    }

    /// P2-5b 指标面板链路：主图指标入口 → Web 主图面板 → 切换指标格子 → 完成
    func testMainIndicatorsSheetOpensAndToggles() throws {
        let app = XCUIApplication.launchingClean()
        app.launch()

        openChart(app)

        // 打开主图指标面板（原生入口按钮；ChanReplayUITests 同款锚点）
        let indButton = app.buttons["chart.mainIndicatorButton"]
        XCTAssertTrue(indButton.waitForExistence(timeout: 15), "主图指标入口未出现")
        indButton.tap()

        // Web 主图面板出现
        let panelTitle = app.staticTexts["主图指标"]
        XCTAssertTrue(panelTitle.waitForExistence(timeout: 15),
                      "Web 主图指标面板未出现")

        // 切换一个指标格子（aria-label 锚点：chart.indicator.main.<name>；MA 是默认启用集成员）
        let maTile = app.buttons["chart.indicator.main.MA"]
        XCTAssertTrue(maTile.waitForExistence(timeout: 10), "MA 指标格子未出现")
        maTile.tap()

        // 写回后回读快照，面板仍打开（对齐原生交互：面板不因写回关闭）
        XCTAssertTrue(panelTitle.waitForExistence(timeout: 10), "写回后面板意外关闭")

        // 完成 → 关闭 → 回详情页
        let done = app.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "完成按钮未出现")
        done.tap()
        XCTAssertFalse(panelTitle.waitForExistence(timeout: 5), "面板关闭后标题仍可达")
        XCTAssertTrue(app.buttons["kline.backButton"].exists, "关闭后应仍在 K 线详情页")
    }
}

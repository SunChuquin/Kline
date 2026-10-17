//
//  CondOrderSmokeUITests.swift
//  KlineUITests
//
//  条件单冒烟：空仓 / 非持仓标的也能建单。
//
//  背景：条件单页「新建」原先只列已有持仓标的（`SimCondListView.startCreate`），
//  但建单校验层（`SimCondRule.validateCreate` / 引擎 `cond_validate_create`）**只对卖出
//  方向要求持仓**，买入（建仓）本就允许空仓 —— 限制纯在 UI 入口。本用例锁死
//  「选择标的 → 搜索全部标的…」这条入口，防止回退成「必须先持仓」。
//
//  元素定位全部基于 accessibilityIdentifier，不依赖中文文本与布局坐标
//  （confirmationDialog 按钮例外：系统弹窗的 identifier 不稳定，故按文案定位并注释说明）。
//

import XCTest

final class CondOrderSmokeUITests: XCTestCase {

    /// 任一断言失败立即终止当前用例，避免连环误报掩盖首个真实问题
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 工具

    /// 启动 App 并等待底部菜单出现（默认进入「行情」页）
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["tab.simulation"].waitForExistence(timeout: 20),
                      "启动后底部菜单未出现")
        return app
    }

    /// 轮询等待元素可点击（覆盖层遮挡时 exists=true 但 isHittable=false）
    private func waitHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            usleep(100_000) // 100ms
        }
        return element.exists && element.isHittable
    }

    /// 模拟 Tab → 条件单页（`condList.new` 出现即视为已成页）
    private func openCondList(_ app: XCUIApplication) {
        app.buttons["tab.simulation"].tap()
        let entry = app.buttons["sim.cond.entry"].firstMatch
        XCTAssertTrue(waitHittable(entry, timeout: 12), "模拟页未出现条件单入口")
        entry.tap()
        XCTAssertTrue(app.buttons["condList.new"].waitForExistence(timeout: 12),
                      "条件单页未出现「新建」按钮")
    }

    // MARK: - 用例：搜索全部标的建单（空仓建仓入口）

    func test01_SearchAnySymbol_ReachesEditor() throws {
        let app = launchedApp()
        openCondList(app)

        app.buttons["condList.new"].tap()

        // 「选择标的」弹窗：按 identifier 定位（SwiftUI 会把 identifier 传播到内层 label，
        // 故同一按钮会匹配到 2 个元素，用 firstMatch 取首个）
        let searchAll = app.buttons.matching(identifier: "condList.symbolSearch").firstMatch
        XCTAssertTrue(searchAll.waitForExistence(timeout: 10),
                      "「选择标的」弹窗缺少「搜索全部标的…」入口")
        searchAll.tap()

        // 全量标的搜索页：输入关键字 → 取首行结果
        let field = app.textFields["simSymbolPicker.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 12), "搜索全部标的页未出现搜索框")
        field.tap()
        field.typeText("600")

        let anyRow = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "simSymbolPicker.row."))
            .firstMatch
        XCTAssertTrue(anyRow.waitForExistence(timeout: 15),
                      "关键字「600」无结果行（数据库未加载？行 identifier 缺失？）")
        anyRow.tap()

        // 进入编辑器：保存按钮存在即「入单流程可达」；买入方向无持仓校验，不会被拦在门外
        let submit = app.buttons["condEditor.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 12),
                      "选中标的后未进入条件单编辑器")
        // 编辑器应当可保存（未就绪时会因引擎校验未回而禁用，但不应长期灰置）
        XCTAssertTrue(waitHittable(submit, timeout: 12),
                      "条件单编辑器保存按钮不可点击（引擎校验未就绪或校验不通过）")
    }
}

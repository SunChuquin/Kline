//
//  KlineUITests.swift
//  KlineUITests
//
//  第一批冒烟用例：覆盖三条核心链路
//    1. 冷启动 + 底部菜单完整性
//    2. 底部 Tab 逐个切换
//    3. 行情页打开 K 线详情并返回
//
//  元素定位全部基于 accessibilityIdentifier（定义在各页面源码中），
//  不依赖中文文本、布局坐标或元素层级，避免 UI 微调导致用例批量失效。
//

import XCTest

final class KlineUITests: XCTestCase {

    /// 任一断言失败立即终止当前用例，避免连环误报掩盖首个真实问题
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 工具

    /// 轮询等待元素可点击（覆盖层遮挡时 exists=true 但 isHittable=false，
    /// 例如 K 线全屏覆盖层盖住底部菜单的场景）
    private func waitHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            usleep(100_000) // 100ms
        }
        return element.exists && element.isHittable
    }

    // MARK: - 用例 1：冷启动 + 底部菜单完整性

    func test01_Launch_ShowsBottomMenu() throws {
        let app = XCUIApplication()
        app.launch()

        // 启动后默认进入「行情」页（ContentView selectedTab = 2），底部菜单可见即视为启动完成
        XCTAssertTrue(app.buttons["tab.market"].waitForExistence(timeout: 15),
                      "启动后应显示底部菜单")

        // 底部 4 个菜单按钮全部存在
        for id in ["tab.home", "tab.favorites", "tab.market", "tab.simulation"] {
            XCTAssertTrue(app.buttons[id].exists, "底部菜单缺少按钮 \(id)")
        }
    }

    // MARK: - 用例 2：底部 Tab 逐个切换

    func test02_TabSwitching_ShowsEachPage() throws {
        let app = XCUIApplication()
        app.launch()

        let homeTab = app.buttons["tab.home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 15), "底部菜单未出现")

        // 页面切换断言给 10s：模拟器冷启动首次运行时初始化慢，5s 偶发超时误报
        // 首页
        homeTab.tap()
        XCTAssertTrue(app.staticTexts["home.welcome"].waitForExistence(timeout: 10), "首页未显示")

        // 自选
        app.buttons["tab.favorites"].tap()
        XCTAssertTrue(app.staticTexts["favorites.title"].waitForExistence(timeout: 10), "自选页未显示")

        // 模拟
        app.buttons["tab.simulation"].tap()
        XCTAssertTrue(app.staticTexts["simulation.subtitle"].waitForExistence(timeout: 10), "模拟页未显示")

        // 行情（切回）
        app.buttons["tab.market"].tap()
        let marketAgain = app.buttons["tab.market"]
        XCTAssertTrue(marketAgain.waitForExistence(timeout: 10) && marketAgain.exists, "行情页未显示")
    }

    // MARK: - 用例 3：行情页打开 K 线详情并返回

    func test03_Market_OpenKlineDetail_AndBack() throws {
        let app = XCUIApplication()
        app.launch()

        let marketTab = app.buttons["tab.market"]
        XCTAssertTrue(marketTab.waitForExistence(timeout: 15), "底部菜单未出现")
        marketTab.tap()

        // 行情数据来自内置 tdx.db（启动时预热），等待首行卡片出现
        let firstRow = app.descendants(matching: .any)["market.rowCard"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15), "行情列表未加载出行卡片")
        firstRow.tap()

        // K 线页为全屏覆盖层：返回按钮出现即视为打开成功
        let backButton = app.buttons["kline.backButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 15), "K线详情页未打开")

        // 返回后底部菜单恢复可点击（详情页覆盖期间 exists 为真但不可点击，需用 isHittable 判断）
        backButton.tap()
        XCTAssertTrue(waitHittable(marketTab, timeout: 10), "返回后未回到行情页（底部菜单仍被覆盖）")
    }

    // MARK: - 用例 91：临时诊断（ETF 联动单视图重置全链路，定位后删除或转正）

    func test91_Diag_ETFLinkedReset() throws {
        let app = XCUIApplication()
        app.launch()

        // 1. 行情页
        let marketTab = app.buttons["tab.market"]
        XCTAssertTrue(marketTab.waitForExistence(timeout: 15), "底部菜单未出现")
        marketTab.tap()

        // 2. 二级菜单 ETF（种子库唯一标的在 ETF 分类）
        let etfBtn = app.buttons["ETF"].firstMatch
        let etf = etfBtn.exists ? etfBtn : app.staticTexts["ETF"].firstMatch
        XCTAssertTrue(etf.waitForExistence(timeout: 10), "二级菜单未找到 ETF")
        etf.tap()

        // 3. 打开该标的 K 线页
        let row = app.descendants(matching: .any)["market.rowCard"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "ETF 行情行未出现")
        row.tap()
        let back = app.buttons["kline.backButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 15), "K线页未打开")

        // 4. 点「联」字按钮进入双联动（accessibilityLabel=进入联动模式）
        let toggle = app.buttons["进入联动模式"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "未找到进入联动模式按钮")
        toggle.tap()
        Thread.sleep(forTimeInterval: 3)  // 等两个 tile 完成加载

        // 5. 左视图（view 0）副图二横向左滑：日线 → 周线（联动态副图二切周期，左滑=更大级别；
        //    副图二中心 ≈ chartArea 顶部 + 54 + 0.775×chartHeight，横屏 834 高约 dy 0.75）
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.75))
        start.press(forDuration: 0.1, thenDragTo: end)
        Thread.sleep(forTimeInterval: 2)

        // 6. view 0 的重置按钮应变可点（蓝色）——按索引定位，避免 firstMatch 抓到视图1的禁用按钮
        let reset = app.buttons["linked.resetButton.0"].firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 5), "重置按钮未出现")
        print("DIAG reset isEnabled after swipe = \(reset.isEnabled)")
        XCTAssertTrue(reset.isEnabled, "切换周期后重置按钮应可点（蓝色）")

        // 7. 点击重置 → 按钮回灰（视图配置恢复默认）
        reset.tap()
        Thread.sleep(forTimeInterval: 3)
        print("DIAG reset isEnabled after reset tap = \(reset.isEnabled)")
        XCTAssertFalse(reset.isEnabled, "重置后按钮应回到禁用态")
        // 图表数据是否真的重载由 debug_log.txt 的 CONFIG_CHANGE loadData / 图表出现 周期判定
    }

    // MARK: - 用例 92：刘海屏（异形屏）横屏安全区验证——元素坐标断言 + 内嵌截图

    /// 刘海/灵动岛 iPhone 横屏：左右安全区各约 44pt（刘海侧+指示条侧）。
    /// 断言关键交互元素不进入安全区危险带（留 4pt 容差），并内嵌截图供人工复核
    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func test92_NotchSafeAreaLandscape() throws {
        let app = XCUIApplication()
        app.launch()

        // 0) 横屏锁定断言：App 坐标空间必须是宽>高（横屏）
        let screen = app.frame
        XCTAssertGreaterThan(screen.width, screen.height,
                             "App 应处于横屏（宽>\(screen.height)），实际 \(screen.width)x\(screen.height)")
        // 刘海/指示条侧安全区危险带宽度（iPhone 11 横屏约 44pt，留 4pt 容差）
        let safeBand: CGFloat = 40

        // 1. 行情页：导航栏两端按钮不进刘海区/不压指示条
        let marketTab = app.buttons["tab.market"]
        XCTAssertTrue(marketTab.waitForExistence(timeout: 15), "底部菜单未出现")
        let home = app.buttons["tab.home"]
        let sim = app.buttons["tab.simulation"]
        XCTAssertTrue(home.waitForExistence(timeout: 5), "首页按钮未出现")
        XCTAssertGreaterThanOrEqual(home.frame.minX, safeBand,
                                    "导航栏「首页」进入刘海侧危险带 minX=\(home.frame.minX)")
        XCTAssertLessThanOrEqual(sim.frame.maxX, screen.maxX - safeBand,
                                 "导航栏「模拟」压到指示条侧危险带 maxX=\(sim.frame.maxX)")
        snap(app, "notch.market")

        // 2. 二级菜单 ETF → K线页（单图）：工具栏两端元素断言
        let etfBtn = app.buttons["ETF"].firstMatch
        let etf = etfBtn.exists ? etfBtn : app.staticTexts["ETF"].firstMatch
        XCTAssertTrue(etf.waitForExistence(timeout: 10), "二级菜单未找到 ETF")
        etf.tap()
        let row = app.descendants(matching: .any)["market.rowCard"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "ETF 行情行未出现")
        row.tap()
        let back = app.buttons["kline.backButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 15), "K线页未打开")
        XCTAssertGreaterThanOrEqual(back.frame.minX, safeBand,
                                    "K线页返回按钮进入刘海侧危险带 minX=\(back.frame.minX)")
        snap(app, "notch.kline.single")

        // 3. 双联动：信息栏重置/钻取按钮断言
        let toggle = app.buttons["进入联动模式"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "未找到进入联动模式按钮")
        toggle.tap()
        let reset0 = app.buttons["linked.resetButton.0"]
        XCTAssertTrue(reset0.waitForExistence(timeout: 8), "联动信息栏重置按钮未出现")
        XCTAssertGreaterThanOrEqual(reset0.frame.minX, safeBand,
                                    "联动重置按钮进入刘海侧危险带 minX=\(reset0.frame.minX)")
        snap(app, "notch.kline.linked")

        // 4. 返回行情页（覆盖层关闭后导航栏恢复）
        back.tap()
        XCTAssertTrue(waitHittable(marketTab, timeout: 10), "返回后未回到行情页")
        snap(app, "notch.market.back")
    }
}

//
//  ThemeGalleryUITests.swift
//  KlineUITests
//
//  主题视觉回归用例：统一驱动四个主页面 + 个人中心，分别在夜间 / 日间两套主题下截图。
//  运行：xcodebuild test -only-testing:KlineUITests/ThemeGalleryUITests
//  截图随 xcresult 导出（xcrun xcresulttool export attachments），用于人工复核配色一致性。
//

import XCTest

final class ThemeGalleryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureThemePages() throws {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(app.buttons["tab.market"].waitForExistence(timeout: 25), "启动后未显示底部菜单")
        Thread.sleep(forTimeInterval: 2)

        // 夜间模式：主页面 + 个人中心
        setTheme(app, dark: true)
        captureAll(app, suffix: "dark")

        // 日间模式：同一组页面
        setTheme(app, dark: false)
        captureAll(app, suffix: "light")

        // 恢复夜间模式，交给用户继续验收
        setTheme(app, dark: true)
    }

    // MARK: - 主题切换

    private func setTheme(_ app: XCUIApplication, dark: Bool) {
        app.buttons["tab.home"].firstMatch.tap()
        let profile = app.buttons["home.profileButton"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 10), "首页未找到个人中心入口")
        profile.tap()

        let appearance = app.buttons["profile.category.appearance"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 6), "个人中心未找到「主题外观」分类")
        appearance.tap()

        let dropdown = app.buttons["profile.theme.dropdown"].firstMatch
        XCTAssertTrue(dropdown.waitForExistence(timeout: 6), "未找到主题下拉按钮")
        dropdown.tap()

        let option = app.buttons[dark ? "夜间模式" : "日间模式"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 4), "主题选项未出现")
        option.tap()

        let done = app.buttons["完成"].firstMatch
        if done.waitForExistence(timeout: 3) { done.tap() }
        Thread.sleep(forTimeInterval: 1)

        let close = app.buttons["profile.close"].firstMatch
        if close.exists { close.tap() }
        Thread.sleep(forTimeInterval: 1)
    }

    // MARK: - 页面截图

    private func captureAll(_ app: XCUIApplication, suffix: String) {
        // 行情
        app.buttons["tab.market"].firstMatch.tap()
        _ = app.descendants(matching: .any)["market.rowCard"].firstMatch.waitForExistence(timeout: 20)
        Thread.sleep(forTimeInterval: 2)
        snap(app, "01_market_\(suffix)")

        // 自选
        app.buttons["tab.favorites"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        snap(app, "02_favorites_\(suffix)")

        // 首页
        app.buttons["tab.home"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["home.page"].waitForExistence(timeout: 10), "首页未显示")
        Thread.sleep(forTimeInterval: 2)
        snap(app, "03_home_\(suffix)")

        // 模拟
        app.buttons["tab.simulation"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 2.5)
        snap(app, "04_simulation_\(suffix)")

        // 个人中心：账户 / 页面布局 / 数据与同步
        app.buttons["tab.home"].firstMatch.tap()
        let profile = app.buttons["home.profileButton"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 10), "首页未找到个人中心入口")
        profile.tap()
        Thread.sleep(forTimeInterval: 1.2)
        snap(app, "05_profile_account_\(suffix)")

        app.buttons["profile.category.layout"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.8)
        snap(app, "06_profile_layout_\(suffix)")

        app.buttons["profile.category.sync"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.5)
        snap(app, "07_profile_sync_\(suffix)")

        let close = app.buttons["profile.close"].firstMatch
        if close.exists { close.tap() }
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

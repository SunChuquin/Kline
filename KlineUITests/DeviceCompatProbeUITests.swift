//
//  DeviceCompatProbeUITests.swift
//  KlineUITests
//
//  TEMP-DIAG(iPhone11适配)：设备兼容性运行时探针 —— spec 调查脚手架（非功能回归用例）。
//
//  背景：App 此前按 iPad mini 5（1024×768，无刘海）调校，新增 iPhone 11
//  （414×896 逻辑点、刘海屏）后疑似存在控件挤压 / 超出屏幕物理显示范围。
//  本组用例在 iPhone 11 模拟器上逐页面采集**运行时**布局数据（不猜代码）：
//    1) 屏幕几何：竖屏 / 左横 / 右横（App 侧 -screen-probe 探针同步写沙盒日志）
//    2) 布局编辑器 / 训练态K线（单图 + 联动多图）/ 四档自选页 / 四档行情页 / 三档模拟页
//     + 非训练态K线（单图 + 联动）作对照基线（用户反馈非训练态无挤压）
//  每个状态打印关键元素 frame（超出屏幕边界标 ⚠️OVERFLOW）并附截图。
//  结论写入 .trae/specs/ 下 spec 文档；修复方案确认后本文件按 spec 处置。
//

import XCTest

final class DeviceCompatProbeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 探针工具

    /// 等待布局稳定（旋转 / 页面切换后）
    private func settle(_ t: TimeInterval = 1.8) { Thread.sleep(forTimeInterval: t) }

    /// 打印当前页面关键元素 frame；超出屏幕边界的元素带 ⚠️OVERFLOW 标记
    private func dump(_ app: XCUIApplication, _ label: String) {
        let screen = app.frame
        print("== PROBE [\(label)] screen=\(Int(screen.width))x\(Int(screen.height)) origin=(\(Int(screen.minX)),\(Int(screen.minY)))")
        func dumpElements(_ title: String, _ elements: [XCUIElement], cap: Int) {
            var n = 0
            for e in elements where e.exists && e.frame.width > 0 && e.frame.height > 0 {
                if n >= cap { print("   [\(title)] ...超过\(cap)个截断"); break }
                n += 1
                let f = e.frame
                let overflow = (f.minX < screen.minX - 0.5 || f.maxX > screen.maxX + 0.5 ||
                                f.minY < screen.minY - 0.5 || f.maxY > screen.maxY + 0.5)
                let id = e.identifier.isEmpty ? "" : " id=\(e.identifier)"
                let lbl = e.label.isEmpty ? "" : " label=\(e.label.prefix(16))"
                print("   [\(title)]\(id)\(lbl) f=(\(ff(f.minX)),\(ff(f.minY)),\(ff(f.width)),\(ff(f.height)))\(overflow ? "  OVERFLOW!" : "")")
            }
        }
        dumpElements("btn", app.buttons.allElementsBoundByIndex, cap: 100)
        dumpElements("txt", app.staticTexts.allElementsBoundByIndex, cap: 100)
        print("== PROBE [\(label)] END")
    }

    private func ff(_ v: CGFloat) -> String { String(format: "%.1f", v) }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// 三个方向依次采集（竖屏 → 左横 → 右横，最后回到竖屏）
    private func cycleOrientations(_ app: XCUIApplication, label: String) {
        XCUIDevice.shared.orientation = .portrait
        settle(); dump(app, "\(label).P"); snap(app, "\(label).P")
        XCUIDevice.shared.orientation = .landscapeLeft
        settle(); dump(app, "\(label).LL"); snap(app, "\(label).LL")
        XCUIDevice.shared.orientation = .landscapeRight
        settle(); dump(app, "\(label).LR"); snap(app, "\(label).LR")
        XCUIDevice.shared.orientation = .portrait
        settle(0.6)
    }

    /// 统一启动（干净状态 + 屏幕探针 + 可选布局注入）
    private func launchApp(_ extraArgs: [String] = [], reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        if reset { app.launchArguments.append("-uitest-reset") }
        app.launchArguments.append("-screen-probe")
        app.launchArguments += extraArgs
        app.launch()
        return app
    }

    /// 横滑首页快捷入口行，把指定 chip 滚进屏内并返回（参考 KlineUITests.scrollHomeEntryIntoView）
    @discardableResult
    private func scrollHomeEntryIntoView(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        let entry = app.buttons[identifier].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "首页缺少入口 \(identifier)")
        let screen = app.frame
        func rowMidYInScreen() -> CGFloat? {
            let f = entry.frame
            guard f.width > 0 else { return nil }
            let top = max(f.minY, screen.minY + 30)
            let bottom = min(f.maxY, screen.maxY - 30)
            guard bottom - top >= 16 else { return nil }
            return (top + bottom) / 2
        }
        if rowMidYInScreen() == nil {
            for _ in 0..<8 {
                let below = entry.frame.midY >= screen.midY
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.75 : 0.35))
                    .press(forDuration: 0.05,
                           thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.4 : 0.7)))
                Thread.sleep(forTimeInterval: 0.3)
                if rowMidYInScreen() != nil { break }
            }
        }
        guard let rowMidY = rowMidYInScreen() else { return entry }
        for _ in 0..<6 {
            let f = entry.frame
            if f.width > 0, f.minX >= screen.minX + 2, f.maxX <= screen.maxX - 2 { break }
            let dy = rowMidY / screen.height
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: Double(dy)))
                .press(forDuration: 0.1,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: Double(dy))),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
            Thread.sleep(forTimeInterval: 0.35)
        }
        return entry
    }

    /// 种子库只有 1 只 ETF：默认「沪深主板」分类为空态，必须先进 ETF 分类才能看到行。
    /// A/C/D 档共用 MarketHeaderBar（A 需点「市场」展开二级；C/D 二级胶囊默认内联）；
    /// B 档侧栏直接可见。⚠️ 二级胶囊是 Button 包单一 Text，a11y 合并后没有独立
    /// staticText，必须按 Button 查；B 档侧栏项 label 带「, 数量」后缀，故用前缀匹配。
    private func openETFList(_ app: XCUIApplication) {
        let etf = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "ETF指数")).firstMatch
        if !etf.exists {
            let marketTop = app.buttons["market.topMenu.市场"].firstMatch
            XCTAssertTrue(marketTop.waitForExistence(timeout: 10), "一级菜单「市场」未出现")
            marketTop.tap()
            XCTAssertTrue(etf.waitForExistence(timeout: 8), "展开后二级菜单未出现 ETF指数")
        }
        etf.tap()
        XCTAssertTrue(app.descendants(matching: .any)["market.rowCard"].firstMatch.waitForExistence(timeout: 15),
                      "ETF 分类下行情行未出现")
    }

    // MARK: - 用例 1：屏幕几何（竖屏 / 左横 / 右横）
    // 数值主体由 App 侧 -screen-probe 探针写沙盒日志 debug_log.txt；此处补 app.frame 与截图

    func testProbe01_ScreenGeometry() throws {
        let app = launchApp()
        XCTAssertTrue(app.buttons["tab.market"].waitForExistence(timeout: 15), "底部菜单未出现")
        cycleOrientations(app, label: "geometry.homeTab")
        app.terminate()
    }

    // MARK: - 用例 2：四档行情页（A/B/C/D × 三方向）

    func testProbe02_Market_ABCD() throws {
        for style in ["A", "B", "C", "D"] {
            let app = launchApp(["-kline.marketLayout", style])
            XCTAssertTrue(app.buttons["tab.market"].waitForExistence(timeout: 15), "底部菜单未出现(\(style))")
            openETFList(app)
            settle(1.0)
            cycleOrientations(app, label: "market\(style)")
            app.terminate()
        }
    }

    // MARK: - 用例 3：四档自选页（A/B/C/D × 三方向；先加一只自选保证列表非空）

    func testProbe03_Favorites_ABCD() throws {
        // 3.1 首次启动（重置）：加自选
        let app = launchApp(["-kline.favoritesLayout", "A"])
        XCTAssertTrue(app.buttons["tab.market"].waitForExistence(timeout: 15), "底部菜单未出现")
        openETFList(app)
        let row = app.descendants(matching: .any)["market.rowCard"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "行情行未出现")
        row.press(forDuration: 1.2)
        let favToggle = app.descendants(matching: .any)["rowMenu.toggleFavorite"].firstMatch
        XCTAssertTrue(favToggle.waitForExistence(timeout: 8), "长按面板未出现加自选项")
        if app.staticTexts["加自选"].firstMatch.waitForExistence(timeout: 3) {
            favToggle.tap()
            settle(1.5)
        } else {
            app.buttons["取消"].firstMatch.tap()
        }
        app.buttons["tab.favorites"].tap()
        XCTAssertTrue(app.staticTexts["favorites.title"].waitForExistence(timeout: 10), "自选页未显示")
        _ = app.descendants(matching: .any)["favorites.rowCard"].firstMatch.waitForExistence(timeout: 8)
        settle(1.0)
        cycleOrientations(app, label: "favA")
        app.terminate()

        // 3.2 B/C/D：不重置（保留自选），仅注入布局档位
        for style in ["B", "C", "D"] {
            let app2 = launchApp(["-kline.favoritesLayout", style], reset: false)
            XCTAssertTrue(app2.buttons["tab.favorites"].waitForExistence(timeout: 15), "底部菜单未出现(\(style))")
            app2.buttons["tab.favorites"].tap()
            XCTAssertTrue(app2.staticTexts["favorites.title"].waitForExistence(timeout: 10), "自选页未显示(\(style))")
            settle(1.0)
            cycleOrientations(app2, label: "fav\(style)")
            app2.terminate()
        }
    }

    // MARK: - 用例 4：三档模拟页（A/B/C × 三方向）

    func testProbe04_Simulation_ABC() throws {
        for style in ["A", "B", "C"] {
            let app = launchApp(["-kline.simulationLayout", style])
            XCTAssertTrue(app.buttons["tab.simulation"].waitForExistence(timeout: 15), "底部菜单未出现(\(style))")
            app.buttons["tab.simulation"].tap()
            XCTAssertTrue(app.staticTexts["simulation.subtitle"].waitForExistence(timeout: 10), "模拟页未显示(\(style))")
            settle(1.2)
            cycleOrientations(app, label: "sim\(style)")
            app.terminate()
        }
    }

    // MARK: - 用例 5：布局编辑器（三方向；树面板 + 检查器 + 顶部栏）

    func testProbe05_LayoutEditor() throws {
        let app = launchApp()
        XCTAssertTrue(app.buttons["tab.home"].waitForExistence(timeout: 15), "底部菜单未出现")
        app.buttons["tab.home"].tap()
        XCTAssertTrue(app.staticTexts["home.page"].waitForExistence(timeout: 10), "首页未显示")
        let entry = scrollHomeEntryIntoView(app, identifier: "home.entry.layoutEditor")
        entry.tap()
        XCTAssertTrue(app.buttons["layoutEditor.save"].waitForExistence(timeout: 8), "布局编辑器未打开")
        settle(1.2)
        cycleOrientations(app, label: "editor")
        // 选中一个控件节点，让右侧检查器出现参数行（挤压高发区）
        let treeRow = app.descendants(matching: .any)["layout.tree.widget.home.quickEntryRow"].firstMatch
        if !treeRow.waitForExistence(timeout: 3) {
            for _ in 0..<14 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.45))
                    .press(forDuration: 0.08,
                           thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.21)))
                if treeRow.waitForExistence(timeout: 1) { break }
            }
        }
        if treeRow.waitForExistence(timeout: 5) {
            treeRow.tap()
            settle(1.0)
            cycleOrientations(app, label: "editor.selected")
        }
        app.terminate()
    }

    // MARK: - 用例 6：非训练态 K 线（单图 + 联动多图，对照基线）

    func testProbe06_KlineNormal_Baseline() throws {
        let app = launchApp()
        XCTAssertTrue(app.buttons["tab.market"].waitForExistence(timeout: 15), "底部菜单未出现")
        openETFList(app)
        let row = app.descendants(matching: .any)["market.rowCard"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "行情行未出现")
        row.tap()
        XCTAssertTrue(app.buttons["kline.backButton"].waitForExistence(timeout: 15), "K线页未打开")
        settle(2.0)
        cycleOrientations(app, label: "klineN.single")

        let toggle = app.buttons["进入联动模式"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "未找到进入联动模式按钮")
        toggle.tap()
        settle(3.5)
        cycleOrientations(app, label: "klineN.linked")
        app.terminate()
    }

    // MARK: - 用例 7：训练态 K 线（单图 + 联动多图 × 三方向）

    func testProbe07_TrainingKline() throws {
        let app = launchApp()
        XCTAssertTrue(app.buttons["tab.home"].waitForExistence(timeout: 15), "底部菜单未出现")
        app.buttons["tab.home"].tap()
        XCTAssertTrue(app.staticTexts["home.page"].waitForExistence(timeout: 10), "首页未显示")

        // 打开训练设置窗：随机抽取标的 → 开始训练
        let entry = scrollHomeEntryIntoView(app, identifier: "home.entry.training")
        entry.tap()
        let start = app.buttons["trainingSetup.start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 8), "训练设置窗未打开")
        let random = app.buttons["随机抽取"].firstMatch
        XCTAssertTrue(random.waitForExistence(timeout: 5), "未找到随机抽取按钮")
        random.tap()
        settle(1.2)
        start.tap()

        // 训练态 K 线页：徽标行出现即视为打开
        let badges = app.descendants(matching: .any)["training.badges"].firstMatch
        XCTAssertTrue(badges.waitForExistence(timeout: 25), "训练态K线页未打开（徽标未出现）")
        settle(2.0)
        cycleOrientations(app, label: "train.single")

        // 联动多图。⚠️ 竖屏下「联」按钮在屏外（本探针发现的问题），先转横屏再点
        XCUIDevice.shared.orientation = .landscapeLeft
        settle()
        let toggle = app.buttons["进入联动模式"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "训练态未找到进入联动模式按钮")
        toggle.tap()
        settle(3.5)
        cycleOrientations(app, label: "train.linked")
        app.terminate()
    }
}

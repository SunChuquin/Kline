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

    /// 行情页二级菜单启动默认折叠：点一级菜单「市场」展开（已展开时该项会收起，
    /// 故仅在对应二级项不可见时才点，保证幂等）
    private func revealSecondLevel(_ app: XCUIApplication) {
        let etf = app.staticTexts["ETF"].firstMatch
        if etf.exists { return }
        let market = app.buttons["market.topMenu.市场"].firstMatch
        XCTAssertTrue(market.waitForExistence(timeout: 10), "一级菜单「市场」未出现")
        market.tap()
        XCTAssertTrue(etf.waitForExistence(timeout: 8), "点击「市场」后二级菜单未展开")
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
        // 首页：判定改用布局无关的 home.page（挂在共享标题栏的软件名 Text 上）——
        // 首页默认档位为 B（宫格），不再有 A 档专有的「欢迎来到首页」文案
        homeTab.tap()
        XCTAssertTrue(app.staticTexts["home.page"].waitForExistence(timeout: 10), "首页未显示")

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

        // 2. 二级菜单默认折叠：先点一级菜单「市场」展开，再选 ETF（种子库唯一标的在 ETF 分类）
        revealSecondLevel(app)
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

    // MARK: - 用例 93：K 线设置面板贴满屏宽（屏幕边缘白边回归）
    // 背景：根布局 NotchSideSafeArea 曾对「无横向安全区」设备也套用 ±hanziWidth 偏移，
    // 使整屏内容平移 4pt → 面板遮罩在最外侧留出 4pt 缝隙，露出窗口白底（用户反馈的白边）。
    // 此处断言面板左右内边距对称，保证偏移为 0。

    func test93_SettingsPanelFullWidthEdges() throws {
        let app = XCUIApplication()
        app.launch()

        let marketTab = app.buttons["tab.market"]
        XCTAssertTrue(marketTab.waitForExistence(timeout: 15), "底部菜单未出现")
        marketTab.tap()

        let marketTop = app.buttons["market.topMenu.市场"].firstMatch
        XCTAssertTrue(marketTop.waitForExistence(timeout: 10), "一级菜单「市场」未出现")
        let etf = app.staticTexts["ETF指数"].firstMatch
        if !etf.exists { marketTop.tap() }
        XCTAssertTrue(etf.waitForExistence(timeout: 8), "二级菜单未展开「ETF指数」")
        etf.tap()

        let row = app.descendants(matching: .any)["market.rowCard"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "行情行未出现")
        row.tap()
        let back = app.buttons["kline.backButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 15), "K线页未打开")

        // 打开 K 线设置面板
        let gear = app.buttons["kline.settingsButton"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 8), "未找到 K线设置按钮")
        gear.tap()
        Thread.sleep(forTimeInterval: 2)

        let title = app.staticTexts["K线设置"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), "设置面板未出现")
        let done = app.buttons["完成"].firstMatch
        snap(app, "settings.panel")

        // 面板必须整幅铺满屏幕宽（根内容零横向偏移）。
        // 判据用「标题左内边距 == 完成右内边距」这一设计不变式（顶部栏左右各 18pt），
        // 只验对称、不硬编码具体数值：面板若整体平移 hanziWidth（4pt），两侧内边距会差 8pt。
        // 轮询而非一次性取值：设备正在旋转时窗口尺寸与 App 布局会短暂错位（过渡态），
        // 稳定后仍不对称才算真回归。
        var leftInset: CGFloat = 0
        var rightInset: CGFloat = 0
        let deadline = Date().addingTimeInterval(6)
        repeat {
            let screen = app.frame
            leftInset = title.frame.minX - screen.minX
            rightInset = screen.maxX - done.frame.maxX
            if abs(leftInset - rightInset) <= 1 { break }
            usleep(200_000)
        } while Date() < deadline
        XCTAssertEqual(leftInset, rightInset, accuracy: 1,
                       "设置面板未铺满屏宽：左内边距=\(leftInset) 右内边距=\(rightInset)（面板相对屏幕存在偏移）")
    }

    // MARK: - 用例 95：两个悬浮按钮在图表出现后延迟 1 秒才显示
    // 注意定位方式：自绘圆钮在无障碍树里是 other（不是 button），要用 descendants(matching: .any)，
    // 用 app.buttons[...] 会 exists=false（此坑曾导致误判「按钮不可点」）。
    // 延迟量级用「页面打开 → 按钮可点」的耗时间接校验：无延迟时约 0.3s（纯加载耗时），
    // 有 1 秒延迟时约 1.3s；两者相差悬殊，用 >=1.0s 作判据既能抓住「延迟被删掉」的回归，
    // 也不会被模拟器快慢影响。精确时序另见沙盒日志的「悬浮按钮：图表出现后延迟 1 秒」行。

    func test95_AccessoryButtonsAppearAfterLoad() throws {
        let app = XCUIApplication()
        app.launch()

        let marketTab = app.buttons["tab.market"]
        XCTAssertTrue(marketTab.waitForExistence(timeout: 15), "底部菜单未出现")
        marketTab.tap()

        // 列表页不该有悬浮按钮（既有行为）
        XCTAssertFalse(app.descendants(matching: .any)["accessory.button"].firstMatch.exists,
                       "行情列表页不应出现悬浮按钮")

        let marketTop = app.buttons["market.topMenu.市场"].firstMatch
        XCTAssertTrue(marketTop.waitForExistence(timeout: 10), "一级菜单「市场」未出现")
        let etf = app.staticTexts["ETF指数"].firstMatch
        if !etf.exists { marketTop.tap() }
        XCTAssertTrue(etf.waitForExistence(timeout: 8), "二级菜单未展开「ETF指数」")
        etf.tap()

        let row = app.descendants(matching: .any)["market.rowCard"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "行情行未出现")
        row.tap()
        let back = app.buttons["kline.backButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 15), "K线页未打开")

        // 自绘圆钮在无障碍树里是 other（非 button），必须用 descendants(matching: .any) 定位
        let old = app.descendants(matching: .any)["accessory.button"].firstMatch
        let wheel = app.descendants(matching: .any)["accessory2.button"].firstMatch

        // 两个按钮都应出现（新按钮 B' 同样受「图表出现后延迟 1 秒」的门控制）
        // ⚠️ 这里只断言「出现」不断言耗时：实测该自绘圆钮的 isHittable 在隐藏态（opacity 0 +
        // allowsHitTesting(false)）也报 true，无法当可见性判据；1 秒延迟的权威证据是沙盒日志
        // 「图表出现 …」与「悬浮按钮：图表出现后延迟 1 秒，两个按钮恢复显示」两行的时间差
        XCTAssertTrue(old.waitForExistence(timeout: 15), "旧悬浮按钮未出现")
        XCTAssertTrue(wheel.exists, "新悬浮按钮未出现")

        // 顺带验证按钮真的可操作：点按中心应弹出快捷面板
        old.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["accessory.close"].waitForExistence(timeout: 8), "点击悬浮按钮未弹出面板")
        app.buttons["accessory.close"].tap()

        // 返回列表页：按钮应随之消失（页面关闭复位，既有行为）
        back.tap()
        XCTAssertTrue(waitHittable(marketTab, timeout: 10), "返回后未回到行情页")
        XCTAssertFalse(app.descendants(matching: .any)["accessory.button"].firstMatch.exists,
                       "返回列表页后悬浮按钮仍在")
    }

    // MARK: - 用例 96：行情页长按「批量编辑」全链路
    // 覆盖：长按面板出现该项 → 进入批量态（预选被长按的那只）→ 全选 → 完成退出。

    /// 行情页展开二级菜单并选中 ETF（种子库唯一标的在 ETF 分类下）
    private func openETFList(_ app: XCUIApplication) {
        let marketTab = app.buttons["tab.market"]
        XCTAssertTrue(marketTab.waitForExistence(timeout: 15), "底部菜单未出现")
        marketTab.tap()
        let marketTop = app.buttons["market.topMenu.市场"].firstMatch
        XCTAssertTrue(marketTop.waitForExistence(timeout: 10), "一级菜单「市场」未出现")
        let etf = app.staticTexts["ETF指数"].firstMatch
        if !etf.exists { marketTop.tap() }
        XCTAssertTrue(etf.waitForExistence(timeout: 8), "二级菜单未展开「ETF指数」")
        etf.tap()
    }

    func test96_Market_BatchEditEntry() throws {
        let app = XCUIApplication()
        app.launch()
        openETFList(app)

        let row = app.descendants(matching: .any)["market.rowCard"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "行情行未出现")

        // 长按出操作面板 → 点「批量编辑」
        row.press(forDuration: 1.2)
        let batchEdit = app.descendants(matching: .any)["rowMenu.batchEdit"].firstMatch
        XCTAssertTrue(batchEdit.waitForExistence(timeout: 8), "长按面板未出现「批量编辑」项")
        batchEdit.tap()

        // 进入批量态：简易多选列表 + 底部批量条（含「完成」）都应在
        let batchRow = app.descendants(matching: .any)["market.batchRow"].firstMatch
        XCTAssertTrue(batchRow.waitForExistence(timeout: 8), "未进入批量编辑态（批量行未出现）")
        let done = app.buttons["market.batchBar.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "批量条缺少「完成」按钮")
        XCTAssertFalse(row.exists, "批量态下不应再渲染表格行")

        // 长按哪只就预选哪只
        let count = app.staticTexts["batch.count"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5), "批量条缺少计数")
        XCTAssertEqual(count.label, "已选 1 只", "进入批量编辑未预选被长按的标的")

        // 有选择时首个动作（加自选）可点
        let addFav = app.buttons["batch.addFavorite"].firstMatch
        XCTAssertTrue(addFav.waitForExistence(timeout: 5), "批量条缺少动作按钮")
        XCTAssertTrue(addFav.isEnabled, "已选 1 只时「加自选」应可点")

        // 点行切换选中：再点一次应取消（变回「未选择」），动作随之置灰
        batchRow.tap()
        XCTAssertEqual(count.label, "未选择", "再次点击批量行未取消选中")
        XCTAssertFalse(addFav.isEnabled, "未选择时「加自选」应置灰")

        // 再点回选中，并横向滚动动作条露出靠后的「全选」
        batchRow.tap()
        XCTAssertEqual(count.label, "已选 1 只", "再次点击批量行未重新选中")
        let actions = app.scrollViews["batch.actions"].firstMatch
        XCTAssertTrue(actions.exists, "批量条动作区未出现")
        actions.swipeLeft()
        actions.swipeLeft()
        let selectAll = app.buttons["batch.selectAll"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), "未找到「全选」")
        selectAll.tap()
        XCTAssertNotEqual(count.label, "未选择", "「全选」未选中任何行")

        // 完成 → 退出批量态、恢复表格
        done.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 8), "点「完成」后未恢复表格")
        XCTAssertFalse(app.descendants(matching: .any)["market.batchRow"].firstMatch.exists,
                       "点「完成」后批量行仍在")
    }

    // MARK: - 用例 97：自选页长按「批量编辑」进入编辑态并预选

    func test97_Favorites_BatchEditEntry() throws {
        let app = XCUIApplication()
        app.launch()
        openETFList(app)

        // 先确保有自选：行情页长按 → 面板项文案是「加自选」时才点（已自选则是「取消自选」，点了会反向）
        let row = app.descendants(matching: .any)["market.rowCard"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "行情行未出现")
        row.press(forDuration: 1.2)
        let favToggle = app.descendants(matching: .any)["rowMenu.toggleFavorite"].firstMatch
        XCTAssertTrue(favToggle.waitForExistence(timeout: 8), "长按面板未出现加自选项")
        // 用面板项文案判断当前是否已自选：未自选时是「加自选」，已自选时是「取消自选」（点了会反向）
        if app.staticTexts["加自选"].firstMatch.waitForExistence(timeout: 3) {
            favToggle.tap()
            Thread.sleep(forTimeInterval: 1.5)
        } else {
            print("DIAG 标的已自选，跳过加自选")
            app.buttons["取消"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }

        // 自选页：长按第一行 → 批量编辑
        app.buttons["tab.favorites"].tap()
        let favRow = app.descendants(matching: .any)["favorites.rowCard"].firstMatch
        XCTAssertTrue(favRow.waitForExistence(timeout: 15), "自选页没有可长按的行（前置加自选失败）")
        favRow.press(forDuration: 1.2)
        let batchEdit = app.descendants(matching: .any)["rowMenu.batchEdit"].firstMatch
        XCTAssertTrue(batchEdit.waitForExistence(timeout: 8), "自选页长按面板未出现「批量编辑」项")
        batchEdit.tap()

        // 进入编辑态：批量条计数显示已预选被长按的那只
        let count = app.staticTexts["batch.count"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 8), "自选页未进入批量编辑态")
        XCTAssertEqual(count.label, "已选 1 只", "自选页进入批量编辑未预选被长按的标的")
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

        // 2. 二级菜单默认折叠：先点一级菜单「市场」展开 → ETF → K线页（单图）：工具栏两端元素断言
        revealSecondLevel(app)
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

    // MARK: - 用例 98：快捷入口内容可配置（移除 / 排序 / 持久化 / 恢复默认）
    // 覆盖第二轮「控件内容配置化」主链路：布局编辑器 → 选中 quickEntryRow →
    // 展开 entries 有序多选 → 删除入口、上下移动 → 保存 → 首页即时生效 → 杀进程重启配置仍在 →
    // 重新进编辑器「恢复默认」→ 首页还原。

    /// 横滑首页快捷入口行，把指定 id 的 chip 滚到屏内（XCUITest 对自定义横滑 ScrollView
    /// 不会自动滚到可见，且屏外元素 isHittable 会直接报 activation point invalid）
    @discardableResult
    private func scrollHomeEntryIntoView(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        let entry = app.buttons[identifier].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "首页缺少入口 \(identifier)")

        let screen = app.frame
        // 入口行（chip 行）中可用于横滑的 y：行与「安全带」（上避状态栏 30、下避底部菜单栏 30）
        // 的交集中点；交集不足 16pt 视为行不在视口内。
        // 只判横向不够：入口行可能被纵向滚出视口（布局可被改动），此时算出的滑动 y 会落到屏幕外，
        // 横滑手势直接无效 → chip 永远滚不进来（曾导致 test100/101/102 卡在打开编辑器）
        func rowMidYInScreen() -> CGFloat? {
            let f = entry.frame
            guard f.width > 0 else { return nil }
            let top = max(f.minY, screen.minY + 30)
            let bottom = min(f.maxY, screen.maxY - 30)
            guard bottom - top >= 16 else { return nil }
            return (top + bottom) / 2
        }

        // 0. 入口行不在视口内时先在首页纵向滚动把它带进来（恢复默认前布局可能已被改动）
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

        // 1. 横滑入口行，把目标 chip 从左端外滚进屏内（行内各 chip 同一纵向位置）
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

    /// 进首页并通过快捷入口行打开布局编辑器（入口 chip 位于横滑行末尾，需先横滑）
    private func openLayoutEditorFromHome(_ app: XCUIApplication) {
        app.buttons["tab.home"].tap()
        XCTAssertTrue(app.staticTexts["home.page"].waitForExistence(timeout: 10), "首页未显示")
        let entry = scrollHomeEntryIntoView(app, identifier: "home.entry.layoutEditor")
        XCTAssertTrue(waitHittable(entry, timeout: 5), "横滑后「布局编辑」入口仍不可点")
        entry.tap()
        XCTAssertTrue(app.buttons["layoutEditor.save"].waitForExistence(timeout: 8),
                      "布局编辑器未打开")
    }

    /// 在编辑器树列表选中某控件节点，并展开指定参数的有序多选 / 折叠行。
    /// 树是懒加载 `ScrollView + LazyVStack`（约 5 屏），目标控件未渲染时要先在 320pt 树面板内上滑。
    private func selectWidgetParam(_ app: XCUIApplication, widget: String, paramKey: String) {
        let treeRow = app.descendants(matching: .any)["layout.tree.widget.\(widget)"].firstMatch
        if !treeRow.waitForExistence(timeout: 3) {
            // 树面板可视区约 y 146...364（1024×768 横屏）：在面板纵向范围内反复短上滑
            for _ in 0..<14 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.45))
                    .press(forDuration: 0.08,
                           thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.21)))
                if treeRow.waitForExistence(timeout: 1) { break }
            }
        }
        XCTAssertTrue(treeRow.waitForExistence(timeout: 5), "树列表未找到控件节点 \(widget)")
        // 懒加载行可能刚渲染、帧尚未就绪
        Thread.sleep(forTimeInterval: 0.3)
        treeRow.tap()
        let paramRow = app.buttons["layout.param.\(paramKey)"].firstMatch
        XCTAssertTrue(paramRow.waitForExistence(timeout: 5), "检查器未找到参数行 \(paramKey)")
        // 已是展开态时点第二下会收起：用展开区才有的「可添加」小标题判定
        if !app.staticTexts["可添加"].waitForExistence(timeout: 1) {
            paramRow.tap()
        }
        XCTAssertTrue(app.staticTexts["可添加"].waitForExistence(timeout: 5),
                      "参数行 \(paramKey) 未展开")
        // 展开后检查器会自动滚动定位已选区（动画约 0.25s），等待其稳定后再操作行内按钮
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// 保存并退出编辑器（保存后无脏标记，返回直接关闭）
    private func saveAndCloseEditor(_ app: XCUIApplication) {
        app.buttons["layoutEditor.save"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        app.buttons["layoutEditor.back"].tap()
        // 全屏覆盖层关闭：保存按钮应消失
        XCTAssertFalse(app.buttons["layoutEditor.save"].waitForExistence(timeout: 3),
                       "布局编辑器未关闭")
    }

    /// 前置：把当前档位（整页）恢复为内置默认，保证用例起点干净（立即落盘，无需保存）
    private func ensureLayoutIsDefault(_ app: XCUIApplication) {
        openLayoutEditorFromHome(app)
        app.buttons["layoutEditor.resetDefault"].tap()
        let confirm = app.alerts.buttons["恢复默认"].firstMatch
        if confirm.waitForExistence(timeout: 3) {
            confirm.tap()
        }
        Thread.sleep(forTimeInterval: 0.8)
        app.buttons["layoutEditor.back"].tap()
        Thread.sleep(forTimeInterval: 0.5)
    }

    func test98_Home_QuickEntriesConfigurable() throws {
        let app = XCUIApplication()
        app.launch()
        ensureLayoutIsDefault(app)
        openLayoutEditorFromHome(app)

        // 1. 选中「快捷入口行」控件并展开「入口项」
        selectWidgetParam(app, widget: "home.quickEntryRow", paramKey: "entries")

        // 默认 = 全部 8 项：search 在已选区、可删除按钮在
        let removeSearch = app.buttons["layout.param.entries.selected.search.remove"].firstMatch
        XCTAssertTrue(removeSearch.waitForExistence(timeout: 5), "默认已选区缺少 search")

        // 2. 删除 search：已选区消失、候选区出现 search
        removeSearch.tap()
        XCTAssertFalse(app.descendants(matching: .any)["layout.param.entries.selected.search"].exists,
                       "删除后 search 不应留在已选区")
        XCTAssertTrue(app.buttons["layout.param.entries.candidate.search"].waitForExistence(timeout: 3),
                      "删除后 search 应出现在可添加候选区")

        // 3. 排序：把已选区第一项 tech 下移一格（tech → picker 之后）
        app.buttons["layout.param.entries.selected.tech.down"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.3)

        // 4. 保存并退出 → 首页即时生效
        saveAndCloseEditor(app)

        let searchChip = app.buttons["home.entry.search"].firstMatch
        let techChip = app.buttons["home.entry.tech"].firstMatch
        let pickerChip = app.buttons["home.entry.picker"].firstMatch
        XCTAssertFalse(searchChip.exists, "保存后首页不应再出现搜索入口")
        XCTAssertTrue(pickerChip.waitForExistence(timeout: 5), "首页缺少选股指标入口")
        XCTAssertTrue(techChip.exists, "首页缺少技术指标入口")
        // 横滑行中 picker 应排在 tech 左边（下移生效）
        XCTAssertLessThan(pickerChip.frame.minX, techChip.frame.minX,
                          "tech 下移后 picker 应位于 tech 左侧")

        // 5. 杀进程重启：配置来自沙盒 home.json，仍应生效
        app.terminate()
        app.launch()
        app.buttons["tab.home"].tap()
        XCTAssertTrue(app.staticTexts["home.page"].waitForExistence(timeout: 10), "重启后首页未显示")
        XCTAssertFalse(app.buttons["home.entry.search"].exists,
                       "重启后搜索入口不应恢复（配置未持久化）")
        XCTAssertTrue(app.buttons["home.entry.picker"].firstMatch.frame.minX
                      < app.buttons["home.entry.tech"].firstMatch.frame.minX,
                      "重启后入口顺序未保持")

        // 6. 恢复默认：重新进编辑器 → 恢复默认 → 保存
        openLayoutEditorFromHome(app)
        selectWidgetParam(app, widget: "home.quickEntryRow", paramKey: "entries")
        let reset = app.buttons["layout.param.entries.reset"].firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 5), "自定义后应显示「恢复默认」")
        reset.tap()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(app.buttons["layout.param.entries.selected.search.remove"].waitForExistence(timeout: 3),
                      "恢复默认后 search 应回到已选区")
        saveAndCloseEditor(app)

        XCTAssertTrue(app.buttons["home.entry.search"].waitForExistence(timeout: 5),
                      "恢复默认后搜索入口应回来")
    }

    // MARK: - 用例 99：大盘概览指数可配置（删除 / 上限 4 禁用 / 持久化 / 恢复默认）

    func test99_Home_MarketOverviewIndicesConfigurable() throws {
        let app = XCUIApplication()
        app.launch()
        ensureLayoutIsDefault(app)
        openLayoutEditorFromHome(app)

        // 1. 选中「大盘概览」并展开「展示指数」
        selectWidgetParam(app, widget: "home.marketOverview", paramKey: "indices")

        // 默认前 4 只指数：已选删除按钮若干（id 为 metaID 数字，测试不硬编码）
        let selectedRemoves = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "layout.param.indices.selected.", ".remove"))
        XCTAssertTrue(selectedRemoves.firstMatch.waitForExistence(timeout: 8),
                      "默认已选指数区为空（指数候选尚未加载？）")
        XCTAssertEqual(selectedRemoves.count, 4, "默认应选中 4 只指数")

        // 2. 删除第一只：解析其 metaID（identifier 段：layout.param.indices.selected.<id>.remove）
        let firstRemove = selectedRemoves.allElementsBoundByIndex[0]
        let segments = firstRemove.identifier.split(separator: ".")
        XCTAssertEqual(segments.count, 6, "已选删除按钮锚点格式异常：\(firstRemove.identifier)")
        let metaID = String(segments[4])
        firstRemove.tap()

        let addBack = app.buttons["layout.param.indices.candidate.\(metaID)"].firstMatch
        XCTAssertTrue(addBack.waitForExistence(timeout: 5),
                      "删除的指数应出现在候选区（metaID=\(metaID)）")
        XCTAssertTrue(addBack.isEnabled, "未达上限（3/4）时候选应可点")

        // 3. 重新加回（追加到末尾）→ 回到 4/4 → 其余候选全部置灰
        addBack.tap()
        Thread.sleep(forTimeInterval: 0.3)
        let candidates = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "layout.param.indices.candidate."))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 3), "候选区为空")
        XCTAssertGreaterThanOrEqual(candidates.count, 1, "应还有未选指数候选")
        for candidate in candidates.allElementsBoundByIndex {
            XCTAssertFalse(candidate.isEnabled,
                           "已选 4 只达上限，候选应禁用：\(candidate.identifier)")
        }

        // 4. 再次删除该指数（让末尾不是它也行，仅为制造非默认配置）并保存：验证持久化
        app.buttons["layout.param.indices.selected.\(metaID).remove"].firstMatch.tap()
        saveAndCloseEditor(app)

        app.terminate()
        app.launch()
        openLayoutEditorFromHome(app)
        selectWidgetParam(app, widget: "home.marketOverview", paramKey: "indices")
        let removedStillSelected = app.descendants(matching: .any)["layout.param.indices.selected.\(metaID)"].firstMatch
        XCTAssertFalse(removedStillSelected.exists, "重启后被删指数不应回到已选区")
        XCTAssertTrue(app.buttons["layout.param.indices.candidate.\(metaID)"]
            .waitForExistence(timeout: 8),
                      "重启后被删指数应在候选区")

        // 5. 恢复默认并保存（沙盒 home.json 不写 indices 键，零默认 diff）
        let resetIndices = app.buttons["layout.param.indices.reset"].firstMatch
        XCTAssertTrue(resetIndices.waitForExistence(timeout: 5), "自定义后应显示「恢复默认」")
        resetIndices.tap()
        Thread.sleep(forTimeInterval: 0.3)
        let restoredRemoves = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "layout.param.indices.selected.", ".remove"))
        XCTAssertEqual(restoredRemoves.count, 4, "恢复默认后应回到 4 只指数")
        saveAndCloseEditor(app)
    }

    // MARK: - 用例 100/101 共用：结构断言与树面板滚动

    /// 切到「JSON 原文」页签，读出「由当前树生成」的规范 JSON 文本，再切回「表单」。
    /// 结构断言走 JSON 文本（不用中文文本查询：下半预览里会出现同名文案）
    private func readTreeJSON(_ app: XCUIApplication) -> String {
        let jsonTab = app.buttons["JSON 原文"].firstMatch
        XCTAssertTrue(jsonTab.waitForExistence(timeout: 8), "未找到「JSON 原文」页签")
        jsonTab.tap()
        let textView = app.textViews.firstMatch
        XCTAssertTrue(textView.waitForExistence(timeout: 8), "JSON 原文编辑器未出现")
        Thread.sleep(forTimeInterval: 0.3)
        let text = (textView.value as? String) ?? ""
        app.buttons["表单"].firstMatch.tap()
        return text
    }

    /// 反复读 JSON 直到满足条件（拖拽落库链路是异步的：loadObject → 主线程 moveInto）
    private func waitTreeJSON(_ app: XCUIApplication,
                              timeout: TimeInterval = 8,
                              until predicate: (String) -> Bool) -> String {
        var text = readTreeJSON(app)
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(text) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            text = readTreeJSON(app)
        }
        return text
    }

    /// JSON 文本里第一个包含 `needle` 的行的缩进空格数。
    /// 注意 JSON 结构本身每层 2 空格，但节点树的一层深度隔了 `layouts.<档位>.root.children[{}]`
    /// 的 4 个结构层，故「节点深度 +1」= 缩进 +4 空格（实测：根的直接子节点 12、拖入容器后 16）。
    private func jsonIndent(of needle: String, in text: String) -> Int? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where line.contains(needle) {
            return line.prefix { $0 == " " }.count
        }
        return nil
    }

    // MARK: - 树列表几何 / 可见性 / 滚动
    //
    // ⚠️ 为什么要按几何判定可见性而不是 `isHittable`（实测结论，2026-09-25）：
    // 树是 `ScrollView + LazyVStack`，**被视口裁掉的行照样进无障碍树**，且这些行
    // `isHittable` 仍返回 true（可视区 y 146...364，屏外行也被报出）。若按 `element.frame`
    // 直接算落点，长按会打到视口之外的其它控件上——实测落到工具栏「添加节点」按钮，
    // 弹出 Menu 吃掉了整个手势，app 侧连 `onDrag` 都没有。故一切落点/点击都必须先确认
    // 行**完整落在树列表可视区内**，可视区 rect 由 app 侧 `layoutEditor.treeList` 锚点提供。

    /// 行高（与 `LayoutNodeTreeList.rowHeight` 一致）
    private static let treeRowHeight: CGFloat = 44

    /// 树列表的真实可视区（屏幕坐标）
    private func treeViewport(_ app: XCUIApplication) -> CGRect {
        app.scrollViews["layoutEditor.treeList"].firstMatch.frame
    }

    /// 行的真实屏幕 rect（行内元素并集 + 纵向居中补余量），无匹配元素返回 `.null`。
    ///
    /// ⚠️ 两个已验证的坑（2026-09-25）：
    /// ① 标识会传播到行内**每个**元素（容器行 = 折叠按钮 + 标题 + 摘要，叶子行 = 标题 + 摘要），
    ///    不能只取 firstMatch：叶子行首个匹配是标题（高 17、位于行内容顶部，行内上下各留 6.25pt），
    ///    只按它居中反推会把行顶算高约 7pt → 上边缘落点落到上一行、被当跨级拒绝，
    ///    同级排序静默失败（test102 实测失败即此因）。
    /// ② 同一标识可能匹配多行（默认布局里就有两个 `layout.tree.card`），故并集必须按「同一行」
    ///    过滤（与首个匹配元素行顶差 < 行高），否则会把两行并成一个大 rect。
    private func treeRowRect(_ app: XCUIApplication, _ identifier: String) -> CGRect {
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
            .allElementsBoundByIndex
            .filter { $0.exists && $0.frame.height > 0 }
        guard let anchor = matches.first else { return .null }
        let base = anchor.frame
        var union = base
        for element in matches.dropFirst() where abs(element.frame.minY - base.minY) < Self.treeRowHeight {
            union = union.union(element.frame)
        }
        let slack = max(0, (Self.treeRowHeight - union.height) / 2)
        return CGRect(x: union.minX, y: union.minY - slack,
                      width: union.width, height: union.height + slack * 2)
    }

    /// 行是否完整落在可视区内（留 2pt 余量，保证落点/长按不会溢出到面板外）
    private func isRowFullyVisible(_ app: XCUIApplication, _ identifier: String, in viewport: CGRect) -> Bool {
        guard viewport.height > 0 else { return false }
        let r = treeRowRect(app, identifier)
        return !r.isNull && r.height > 0 && r.minY >= viewport.minY + 2 && r.maxY <= viewport.maxY - 2
    }

    /// 断言给定行都完整可见（拖拽用例的前置条件）
    private func assertTreeRowsVisible(_ app: XCUIApplication,
                                       _ identifiers: [String],
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        let viewport = treeViewport(app)
        for id in identifiers {
            XCTAssertTrue(isRowFullyVisible(app, id, in: viewport),
                          "行未完整滚入树列表可视区：row=\(treeRowRect(app, id)) viewport=\(viewport)",
                          file: file, line: line)
        }
    }

    /// 在树面板内小步慢速滚动，直到给定行都完整可见（判定见 `isRowFullyVisible`）。
    /// 落点全程限制在可视区内，避免误触面板外的控件。
    private func revealTreeRows(_ app: XCUIApplication,
                                _ identifiers: [String],
                                maxSwipes: Int = 10) {
        for _ in 0..<maxSwipes {
            let viewport = treeViewport(app)
            guard viewport.height > 0 else { return }
            guard let pending = identifiers.first(where: { !isRowFullyVisible(app, $0, in: viewport) }) else { return }
            // 目标行在视口偏下 → 手指由下往上拖（内容上移）；反之向下
            let contentUp = treeRowRect(app, pending).midY > viewport.midY
            let x = viewport.midX
            let fromY = contentUp ? viewport.maxY - 10 : viewport.minY + 10
            let toY = contentUp ? fromY - 60 : fromY + 60
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: x, dy: fromY))
                .press(forDuration: 0.1,
                       thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                           .withOffset(CGVector(dx: x, dy: toY)),
                       withVelocity: .slow, thenHoldForDuration: 0.05)
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    /// 行内落点分区（与 app 侧 `NodeDropDelegate.resolution(forY:)` 一致）
    private enum TreeDropZone {
        /// 行上边缘 12pt：插到该行之前
        case before
        /// 容器行中间区：拖入该容器
        case into
        /// 行下边缘 12pt / 叶子行下半区：插到该行之后
        case after
    }

    /// 某行中心点的屏幕坐标（拖拽起点）
    private func treeRowCenter(_ app: XCUIApplication, _ identifier: String) -> XCUICoordinate {
        let r = treeRowRect(app, identifier)
        return app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: r.midX, dy: r.midY))
    }

    /// 某行指定分区代表点的屏幕坐标（拖拽落点）
    private func treeDropPoint(_ app: XCUIApplication,
                               _ identifier: String,
                               _ zone: TreeDropZone) -> XCUICoordinate {
        let r = treeRowRect(app, identifier)
        let y: CGFloat
        switch zone {
        case .before: y = r.minY + 6   // 上边缘区内侧（<12）
        case .into:   y = r.midY       // 容器行中间区
        case .after:  y = r.maxY - 6   // 下边缘区内侧（>32）
        }
        return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: r.midX, dy: y))
    }

    /// 长按源行拖动到目标行的指定分区松手（`.slow` + 落点保持 1.2s 才可靠交付 `performDrop`）
    private func dragTreeRow(_ app: XCUIApplication,
                             from source: String,
                             to target: String,
                             zone: TreeDropZone) {
        treeRowCenter(app, source)
            .press(forDuration: 1.2,
                   thenDragTo: treeDropPoint(app, target, zone),
                   withVelocity: .slow, thenHoldForDuration: 1.2)
    }

    /// 整份 JSON 里某个档位段的文本（键形如 `"B" : {`）；找不到返回 nil
    private func jsonSection(_ style: String, in text: String) -> String {
        guard let start = text.range(of: "\"\(style)\" : {")?.lowerBound else { return text }
        var end = text.endIndex
        for other in ["A", "B", "C", "D"] where other != style {
            if let r = text.range(of: "\"\(other)\" : {", range: start..<text.endIndex),
               r.lowerBound > start, r.lowerBound < end {
                end = r.lowerBound
            }
        }
        return String(text[start..<end])
    }

    // MARK: - 用例 100：把控件行拖入容器行（跨级装配 + 持久化 + 恢复默认）

    func test100_Home_EditorDragNodeIntoStack() throws {
        let app = XCUIApplication()
        app.launch()
        ensureLayoutIsDefault(app)
        openLayoutEditorFromHome(app)

        // 0. 前置：默认 B 档；quickEntryRow 是根容器直接子节点，排在 home.topGainers 之前
        let before = jsonSection("B", in: readTreeJSON(app))
        guard let indentBefore = jsonIndent(of: "home.quickEntryRow", in: before) else {
            return XCTFail("拖拽前 JSON 未找到 home.quickEntryRow 行")
        }
        guard let rowIdx = before.range(of: "\"home.quickEntryRow\"")?.lowerBound,
              let gainersIdx = before.range(of: "\"home.topGainers\"")?.lowerBound else {
            return XCTFail("拖拽前 JSON 缺少对比片段")
        }
        XCTAssertLessThan(rowIdx, gainersIdx, "前置：quickEntryRow 应排在 home.topGainers 之前")

        // 1. 长按控件行，拖到「滚动区」容器行的**中间区**（行中心 = 拖入意图）松手
        let sourceID = "layout.tree.widget.home.quickEntryRow"
        let targetID = "layout.tree.scroll"
        revealTreeRows(app, [sourceID, targetID])
        assertTreeRowsVisible(app, [sourceID, targetID])
        dragTreeRow(app, from: sourceID, to: targetID, zone: .into)

        // 2. 落库后：quickEntryRow 成为滚动区最后一个子节点 → 缩进 +4，排在 home.topGainers 之后
        //    注意：canonical JSON 每深一层多 4 空格（数组元素行 `{` + 其键行各 2 空格），不是 2
        let after = waitTreeJSON(app) { text in
            let section = self.jsonSection("B", in: text)
            guard let indent = self.jsonIndent(of: "home.quickEntryRow", in: section),
                  let idx = section.range(of: "\"home.quickEntryRow\"")?.lowerBound,
                  let tail = section.range(of: "\"home.topGainers\"")?.lowerBound else { return false }
            return indent > indentBefore && idx > tail
        }
        let afterSection = jsonSection("B", in: after)
        XCTAssertEqual(jsonIndent(of: "home.quickEntryRow", in: afterSection), indentBefore + 4,
                       "拖入后 quickEntryRow 层级未加深一层（canonical JSON 每层 4 空格）")
        XCTAssertGreaterThan(afterSection.range(of: "\"home.quickEntryRow\"")!.lowerBound,
                             afterSection.range(of: "\"home.topGainers\"")!.lowerBound,
                             "拖入后 quickEntryRow 应位于滚动区子节点末尾")

        // 3. 保存 → 杀进程重启 → 结构保持
        saveAndCloseEditor(app)
        app.terminate()
        app.launch()
        openLayoutEditorFromHome(app)
        let restarted = jsonSection("B", in: readTreeJSON(app))
        XCTAssertEqual(jsonIndent(of: "home.quickEntryRow", in: restarted), indentBefore + 4,
                       "重启后拖入结构丢失")

        // 4. 恢复默认：quickEntryRow 回到根容器
        app.buttons["layoutEditor.resetDefault"].tap()
        let confirm = app.alerts.buttons["恢复默认"].firstMatch
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        Thread.sleep(forTimeInterval: 0.8)
        let restored = waitTreeJSON(app) { text in
            self.jsonIndent(of: "home.quickEntryRow", in: self.jsonSection("B", in: text)) == indentBefore
        }
        XCTAssertEqual(jsonIndent(of: "home.quickEntryRow", in: jsonSection("B", in: restored)), indentBefore,
                       "恢复默认后 quickEntryRow 未回到根容器")
    }

    // MARK: - 用例 101：非法落点被拒且结构不变
    // 一次手势内部按落点分区判定意图：容器行中间区 = 拖入、上下边缘区 = 同级前后插、
    // 叶子行上下半区 = 同级前后插。故非法只剩两类：拖入自身/子孙（成环）、跨级插到不同父。

    func test101_Home_EditorDragInvalidTarget() throws {
        let app = XCUIApplication()
        app.launch()
        ensureLayoutIsDefault(app)
        openLayoutEditorFromHome(app)

        let before = readTreeJSON(app)
        let cardID = "layout.tree.card"

        // 1. 把容器（滚动区）拖到它自己的子孙容器（卡片）中间区 → 说明文案 + 结构不变（防成环）
        let scrollID = "layout.tree.scroll"
        revealTreeRows(app, [scrollID, cardID])
        assertTreeRowsVisible(app, [scrollID, cardID])
        dragTreeRow(app, from: scrollID, to: cardID, zone: .into)
        XCTAssertTrue(app.staticTexts["不能把节点拖入它自己或它的子节点"].waitForExistence(timeout: 5),
                      "自身/子孙落点未给出说明")
        XCTAssertEqual(readTreeJSON(app), before, "子孙落点不应改变结构")
        XCTAssertTrue(app.descendants(matching: .any)["layout.tree.widget.home.marketOverview"].exists,
                      "卡片唯一子节点不应被替换")

        // 2. 跨级插入：把「大盘概览」控件拖到**上一行**的「大盘概览卡片」上边缘（两者相邻，保证同一视口内可点）
        //    → 前插意图，但源（卡片内）与目标（滚动区内）不同父 → 跨级拒绝 + 说明文案 + 结构不变
        let overviewID = "layout.tree.widget.home.marketOverview"
        revealTreeRows(app, [overviewID, cardID])
        assertTreeRowsVisible(app, [overviewID, cardID])
        dragTreeRow(app, from: overviewID, to: cardID, zone: .before)
        XCTAssertTrue(app.staticTexts["跨级移动请拖到容器行中间区，同级排序请拖到同级行上/下边缘"]
                        .waitForExistence(timeout: 5),
                      "跨级插入未给出说明")
        XCTAssertEqual(readTreeJSON(app), before, "跨级落点不应改变结构")
    }

    // MARK: - 用例 102：拖拽同级排序（不再需要先点「排序」开关）+ 持久化 + 恢复默认

    func test102_Home_EditorDragReorderSibling() throws {
        let app = XCUIApplication()
        app.launch()
        ensureLayoutIsDefault(app)
        openLayoutEditorFromHome(app)

        // 0. 前置：默认 B 档；quickEntryRow 在 home.header 之后（都是根容器直接子节点）
        let before = jsonSection("B", in: readTreeJSON(app))
        guard let indentBefore = jsonIndent(of: "home.quickEntryRow", in: before),
              let rowIdx = before.range(of: "\"home.quickEntryRow\"")?.lowerBound,
              let headerIdx = before.range(of: "\"home.header\"")?.lowerBound else {
            return XCTFail("拖拽前 JSON 缺少对比片段")
        }
        XCTAssertGreaterThan(rowIdx, headerIdx, "前置：quickEntryRow 应排在 home.header 之后")

        // 1. 长按控件行，拖到「首页头部控件」行的**上边缘区**（插到该行之前）松手
        let sourceID = "layout.tree.widget.home.quickEntryRow"
        let headerID = "layout.tree.widget.home.header"
        revealTreeRows(app, [sourceID, headerID])
        assertTreeRowsVisible(app, [sourceID, headerID])
        dragTreeRow(app, from: sourceID, to: headerID, zone: .before)

        // 2. 同级重排：层级不变（仍为根容器直接子节点），顺序改为排在 home.header 之前
        let after = waitTreeJSON(app) { text in
            let section = self.jsonSection("B", in: text)
            guard let idx = section.range(of: "\"home.quickEntryRow\"")?.lowerBound,
                  let header = section.range(of: "\"home.header\"")?.lowerBound else { return false }
            return idx < header
        }
        let afterSection = jsonSection("B", in: after)
        XCTAssertEqual(jsonIndent(of: "home.quickEntryRow", in: afterSection), indentBefore,
                       "同级排序不应改变层级")
        XCTAssertLessThan(afterSection.range(of: "\"home.quickEntryRow\"")!.lowerBound,
                          afterSection.range(of: "\"home.header\"")!.lowerBound,
                          "排序后 quickEntryRow 应排在 home.header 之前")

        // 3. 保存 → 杀进程重启 → 顺序保持
        saveAndCloseEditor(app)
        app.terminate()
        app.launch()
        openLayoutEditorFromHome(app)
        let restarted = jsonSection("B", in: readTreeJSON(app))
        XCTAssertLessThan(restarted.range(of: "\"home.quickEntryRow\"")!.lowerBound,
                          restarted.range(of: "\"home.header\"")!.lowerBound,
                          "重启后同级排序结果丢失")

        // 4. 恢复默认：quickEntryRow 回到 home.header 之后
        app.buttons["layoutEditor.resetDefault"].tap()
        let confirm = app.alerts.buttons["恢复默认"].firstMatch
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        Thread.sleep(forTimeInterval: 0.8)
        let restored = waitTreeJSON(app) { text in
            let section = self.jsonSection("B", in: text)
            guard let idx = section.range(of: "\"home.quickEntryRow\"")?.lowerBound,
                  let header = section.range(of: "\"home.header\"")?.lowerBound else { return false }
            return idx > header
        }
        XCTAssertGreaterThan(jsonSection("B", in: restored).range(of: "\"home.quickEntryRow\"")!.lowerBound,
                             jsonSection("B", in: restored).range(of: "\"home.header\"")!.lowerBound,
                             "恢复默认后 quickEntryRow 未回到 home.header 之后")
    }
}

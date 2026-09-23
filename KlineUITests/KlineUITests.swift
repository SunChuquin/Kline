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
}

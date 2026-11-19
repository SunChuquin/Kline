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

    /// P2-6a 快捷面板链路：悬浮球 → Web 快捷面板（详情态）→ 票面买入提交 → 成功反馈 → 关闭
    func testQuickPanelTicketSubmit() throws {
        let app = XCUIApplication.launchingClean()
        app.launch()

        openChart(app)

        // 悬浮球（详情页打开 + 图表首屏加载完成后延迟 1 秒淡入；干净启动引擎首算可达 30-60s）
        // ⚠️ 树中类型是 Other（SwiftUI 组合图形映射），不是 Button——用任意后代匹配
        let accessory = app.descendants(matching: .any).matching(identifier: "accessory.button").firstMatch
        XCTAssertTrue(accessory.waitForExistence(timeout: 90), "悬浮球未出现（图表加载超时）")
        sleep(2)   // 等延迟淡入完成
        accessory.tap()

        // Web 快捷面板出现（详情态）
        let panelTitle = app.staticTexts["快捷面板"]
        XCTAssertTrue(panelTitle.waitForExistence(timeout: 15), "Web 快捷面板未出现")
        XCTAssertTrue(app.staticTexts["委托价"].waitForExistence(timeout: 10), "票面未渲染")

        // 默认数量 100（seed 账户资金充足）→ 点买入提交（按钮 label = "买入 限价"）
        let submit = app.buttons["买入 限价"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10), "买入提交按钮未出现")
        submit.tap()

        // 成功反馈（toast 文案）
        XCTAssertTrue(app.staticTexts["委托已提交"].waitForExistence(timeout: 10),
                      "下单成功反馈未出现（提交链路回归）")

        // 关闭面板
        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "关闭按钮未出现")
        close.tap()
        XCTAssertFalse(panelTitle.waitForExistence(timeout: 5), "面板关闭后标题仍可达")
        XCTAssertTrue(app.buttons["kline.backButton"].exists, "关闭后应仍在 K 线详情页")
    }

    // MARK: - P2-6c-1 全屏 Web 页（个人中心三入口）

    /// 反复整屏上滑直到原生入口行完整进入屏幕（个人中心较长，入口可能离屏）
    private func revealEntry(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let entry = app.buttons[id].firstMatch
        for _ in 0..<30 {
            let f = entry.exists ? entry.frame : .zero
            let s = app.frame
            let onScreen = f.width > 1 && f.height > 1
                && f.minY >= s.minY && f.maxY <= s.maxY
            if onScreen { return entry }
            app.swipeUp()
            usleep(300_000)
        }
        XCTFail("个人中心未在屏幕内找到入口 \(id)")
        return entry
    }

    /// 本地更新页链路：首页 → 个人中心 → 本地更新入口 → Web 页打开（补缺口卡片可达）→ 返回
    func testLocalUpdatePageOpensAndCloses() throws {
        let app = XCUIApplication.launchingClean()
        app.launch()

        // 默认启动在行情 Tab（selectedTab=2）→ 先切首页
        let homeTab = app.buttons["tab.home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 20), "底部「首页」入口未出现")
        homeTab.tap()

        // 首页（Web）→ 个人中心（原生 overlay）
        let profileButton = app.buttons["home.profileButton"].firstMatch
        XCTAssertTrue(profileButton.waitForExistence(timeout: 30), "首页标题栏用户入口未出现")
        profileButton.tap()
        XCTAssertTrue(app.staticTexts["个人中心"].waitForExistence(timeout: 10), "个人中心未打开")

        // 本地更新入口行（原生）→ Web 全屏页（Web 专属锚点 gapBackfill.run 可达 = 页面真渲染）
        let entry = revealEntry(app, "profile.localUpdate.entry")
        entry.tap()
        let runButton = app.buttons["gapBackfill.run"].firstMatch
        XCTAssertTrue(runButton.waitForExistence(timeout: 15), "Web 本地更新页未打开")

        // 返回（page.back）→ Web 页销毁（Web 专属锚点消失）、回到个人中心
        let back = app.buttons["page.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "返回按钮未出现")
        back.tap()
        XCTAssertFalse(runButton.waitForExistence(timeout: 5), "返回后 Web 页仍可达")
        XCTAssertTrue(app.buttons["profile.localUpdate.entry"].exists, "返回后应回到个人中心")
    }

    /// 联机同步页链路：首页 → 个人中心 → 联机同步入口 → Web 页打开（本机服务卡可达）→ 返回
    func testLanSyncPageOpensAndCloses() throws {
        let app = XCUIApplication.launchingClean()
        app.launch()

        // 默认启动在行情 Tab（selectedTab=2）→ 先切首页
        let homeTab = app.buttons["tab.home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 20), "底部「首页」入口未出现")
        homeTab.tap()

        let profileButton = app.buttons["home.profileButton"].firstMatch
        XCTAssertTrue(profileButton.waitForExistence(timeout: 30), "首页标题栏用户入口未出现")
        profileButton.tap()
        XCTAssertTrue(app.staticTexts["个人中心"].waitForExistence(timeout: 10), "个人中心未打开")

        let entry = revealEntry(app, "profile.lansync.entry")
        entry.tap()
        // 本机服务卡（Web 专属锚点；div aria-label 经 descendants(any) 匹配）
        let statusCard = app.descendants(matching: .any)["lansync.local.status"].firstMatch
        XCTAssertTrue(statusCard.waitForExistence(timeout: 15), "Web 联机同步页未打开")

        let back = app.buttons["page.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "返回按钮未出现")
        back.tap()
        XCTAssertFalse(statusCard.waitForExistence(timeout: 5), "返回后 Web 页仍可达")
        XCTAssertTrue(app.buttons["profile.lansync.entry"].exists, "返回后应回到个人中心")
    }
}

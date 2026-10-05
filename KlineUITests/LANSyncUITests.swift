//
//  LANSyncUITests.swift
//  KlineUITests
//
//  「局域网设备联机同步」双模拟器联测（**替代人工双机点击**）：
//  UD1（发起方）：个人中心 → 联机同步 → 手动直连 127.0.0.1:5052（UD2 对端）→
//  推送方向 → 勾选「自选」→ 开始同步 → 断言出现「同步完成」卡片而非「同步失败」。
//
//  对端 UD2 由外部脚本先行准备：KLINE_HTTP_PORT=5052 KLINE_AUTOPAIR=1 launch
//  （App 启动即监听，autopair 由服务端路由直接签发 token，不弹确认）。
//  同步是否真正生效以两端 Documents/favorites.json 的 sha256 对比为准（外部脚本验证）。
//
//  元素定位全部基于 accessibilityIdentifier：
//   - home.profileButton / tab.home            首页标题栏用户入口（进入个人中心）
//   - profile.lansync.entry                    个人中心「联机同步」入口（ProfileDetailView）
//   - lansync.local.status / .manual.field / .manual.connect   devices 页（LANSyncView）
//   - lansync.direction.push / .category.favorites / .start    configure 页
//   - lansync.pair.allow / .pair.deny          接收方配对确认弹窗（本机作为接收方时的兜底）
//   - lansync.result.summary / .done.button    完成卡片（本次联测补的 identifier）
//   - lansync.fail.message                     失败卡片错误文本（打进 XCTFail 消息）
//
//  ⚠️ 沿用 GapBackfillUITests 的两条踩坑记录：
//  1) SwiftUI 离屏元素 isHittable 误报 true → 要点的元素一律用「帧完整落在屏幕内」判定；
//  2) 非懒加载 VStack 里离屏元素 exists / label 可直接读，不为读值而滑动。
//

import XCTest

final class LANSyncUITests: XCTestCase {

    /// 等待同步完成/失败结论的上限：本机回环（127.0.0.1）传 favorites 一个小文件，
    /// 正常几秒内完成；配对等待 + 传输余量给 60s（任务规格值）
    private static let verdictTimeout: TimeInterval = 60

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 工具（与 GapBackfillUITests 同款）

    /// 帧是否完整落在屏幕内（不信 isHittable）
    private func isFullyOnScreen(_ element: XCUIElement, _ app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let f = element.frame
        let s = app.frame
        return f.width > 1 && f.height > 1
            && f.minY >= s.minY && f.maxY <= s.maxY
            && f.minX >= s.minX && f.maxX <= s.maxX
    }

    /// 反复整屏上滑直到目标元素完整进入屏幕（对 GapBackfillUITests.reveal 系列的泛化）
    private func reveal(_ id: String, in app: XCUIApplication,
                        using match: (XCUIApplication) -> XCUIElement) -> XCUIElement {
        let element = match(app)
        for _ in 0..<40 {
            if isFullyOnScreen(element, app) { return element }
            app.swipeUp()
            usleep(300_000)
        }
        XCTFail("未能滚动到屏幕内找到元素 \(id)（exists=\(element.exists)，"
                + "frame=\(element.exists ? "\(element.frame)" : "无")，屏幕 \(app.frame)）")
        return element
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// 收起软键盘（iPad 模拟器可能连了硬件键盘 → 软键盘不出现；有则用工具栏「完成」/ return 收起）
    private func dismissKeyboardIfPresent(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        let done = app.toolbars.buttons["完成"].firstMatch
        if done.exists { done.tap(); usleep(300_000); return }
        let ret = app.keyboards.buttons["return"].firstMatch
        if ret.exists { ret.tap(); usleep(300_000); return }
        app.swipeDown()
        usleep(300_000)
    }

    // MARK: - 用例：手动直连推送「自选」到对端（双模拟器联测 UD1 侧）

    func testPushFavoritesToManualPeer() throws {
        let app = XCUIApplication()
        app.launch()

        // 0) 启动就绪：底部菜单出现
        XCTAssertTrue(app.buttons["tab.home"].firstMatch.waitForExistence(timeout: 20),
                      "启动后未显示底部菜单")

        // 1) 首页 → 个人中心（走标题栏用户入口，不依赖中文文案）
        app.buttons["tab.home"].firstMatch.tap()
        let profileButton = app.buttons["home.profileButton"].firstMatch
        XCTAssertTrue(profileButton.waitForExistence(timeout: 10), "首页标题栏未找到用户入口")
        profileButton.tap()
        XCTAssertTrue(app.staticTexts["个人中心"].firstMatch.waitForExistence(timeout: 10),
                      "个人中心未打开")

        // 2) 滚到「联机同步」入口并点击（个人中心较长，入口在本地更新卡片之后）
        let entry = reveal("profile.lansync.entry", in: app) {
            $0.buttons["profile.lansync.entry"].firstMatch
        }
        entry.tap()

        // 3) devices 页：本机服务卡片出现即页面就绪
        XCTAssertTrue(app.otherElements["lansync.local.status"].firstMatch
            .waitForExistence(timeout: 10)
            || app.descendants(matching: .any)["lansync.local.status"].firstMatch
                .waitForExistence(timeout: 5),
            "联机同步页未打开（未找到 lansync.local.status）")

        // 4) 手动直连：输入对端地址 127.0.0.1:5052（UD2）→ 连接
        let field = reveal("lansync.manual.field", in: app) {
            $0.textFields["lansync.manual.field"].firstMatch
        }
        field.tap()
        field.typeText("127.0.0.1:5052")
        print("LAN manualAddress 已输入")
        dismissKeyboardIfPresent(app)

        let connect = reveal("lansync.manual.connect", in: app) {
            $0.buttons["lansync.manual.connect"].firstMatch
        }
        connect.tap()

        // 5) configure 页就绪：方向分段控件出现。
        //    若连接失败会弹 alert（无法连接 / 对端不可同步），读 alert 文本打进断言消息。
        let push = app.descendants(matching: .any)["lansync.direction.push"].firstMatch
        var connectAlert: String? = nil
        let connectDeadline = Date().addingTimeInterval(15)
        while Date() < connectDeadline {
            if push.exists { break }
            let alert = app.alerts.firstMatch
            if alert.exists { connectAlert = alert.label; break }
            usleep(500_000)
        }
        if let alertText = connectAlert {
            let detail = app.alerts.firstMatch.staticTexts.firstMatch.label
            XCTFail("手动直连后未进入配置页，弹出提示：「\(alertText)」\(detail.isEmpty ? "" : " / \(detail)")")
            return
        }
        XCTAssertTrue(push.waitForExistence(timeout: 5), "连接成功但配置页未出现（lansync.direction.push 不存在）")
        print("LAN 已进入 configure 页")

        // 6) 方向：推送（本机 → 对端）
        push.tap()
        usleep(300_000)

        // 7) 勾选「自选」（favorites）
        let fav = reveal("lansync.category.favorites", in: app) {
            $0.buttons["lansync.category.favorites"].firstMatch
        }
        fav.tap()
        print("LAN 已勾选 favorites")

        // 8) 开始同步
        let start = reveal("lansync.start", in: app) {
            $0.buttons["lansync.start"].firstMatch
        }
        snap(app, "lansync.beforeStart")
        start.tap()

        // 9) 轮询结论（≤60s）：完成卡片 / 失败卡片 / 兜底接收方配对弹窗（正常 autopair 不弹）
        let summary = app.staticTexts["lansync.result.summary"].firstMatch
        let failMsg = app.staticTexts["lansync.fail.message"].firstMatch
        let allow = app.buttons["lansync.pair.allow"].firstMatch
        let deadline = Date().addingTimeInterval(Self.verdictTimeout)
        var doneSummary: String? = nil
        var failureText: String? = nil
        var tick = 0
        while Date() < deadline {
            if failMsg.exists {
                failureText = failMsg.label
                break
            }
            if allow.exists && allow.isHittable {
                print("LAN 出现接收方配对弹窗（预期 autopair 不弹），兜底点允许")
                allow.tap()
                usleep(500_000)
                continue
            }
            if summary.exists && !summary.label.isEmpty {
                doneSummary = summary.label
                break
            }
            tick += 1
            if tick % 20 == 0 {   // 每 10s 打一次进度，便于看链路卡在哪
                print("LAN tick=\(tick / 2)s 等待同步结论中…")
            }
            usleep(500_000)
        }
        snap(app, "lansync.verdict")
        print("LAN resultSummary = \(doneSummary ?? "<未出现>")")
        print("LAN failureText = \(failureText ?? "<无>")")

        // 10) 断言：完成而非失败（失败时把错误文本带出来）
        if let failure = failureText {
            XCTFail("同步失败卡片出现：\(failure)")
            return
        }
        guard let finalSummary = doneSummary else {
            XCTFail("同步未在 \(Int(Self.verdictTimeout))s 内出结论（既无完成卡片也无失败卡片，可能卡在配对/传输）")
            return
        }
        XCTAssertTrue(app.buttons["lansync.done.button"].firstMatch.waitForExistence(timeout: 5),
                      "完成汇总已出现但「完成」按钮不存在（done 卡片渲染不完整）")
        print("LAN 同步完成，汇总：\(finalSummary)")
    }
}

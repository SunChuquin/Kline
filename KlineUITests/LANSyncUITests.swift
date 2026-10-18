//
//  LANSyncUITests.swift
//  KlineUITests
//
//  「局域网设备联机同步」双模拟器联测（**替代人工双机点击**，仅拉取模型）：
//  UD1（发起方）：个人中心 → 联机同步 → 手动直连 127.0.0.1:5052（UD2 对端）→
//  勾选「自选」→ 开始拉取 → 断言出现「同步完成」卡片而非「同步失败」。
//
//  对端 UD2 由外部脚本先行准备：
//  SIMCTL_CHILD_KLINE_EXPOSED=1 SIMCTL_CHILD_KLINE_HTTP_PORT=5052 launch
//  （App 启动即监听并自动暴露：isExposed=true + 恢复 mDNS 广播；暴露即授权，
//  对端 /sync/request-pair 直接签发 token，无确认弹窗）。
//  同步是否真正生效以两端 Documents/favorites.json 的 sha256 对比为准（外部脚本验证）。
//
//  元素定位全部基于 accessibilityIdentifier：
//   - home.profileButton / tab.home            首页标题栏用户入口（进入个人中心）
//   - profile.lansync.entry                    个人中心「联机同步」入口（ProfileDetailView）
//   - lansync.local.status / .manual.field / .manual.connect   devices 页（LANSyncView）
//   - lansync.expose.toggle / .scan.once       devices 页暴露开关 / 扫描一次按钮
//   - lansync.category.favorites / .start      configure 页（方向已固定为拉取，无方向控件）
//   - lansync.result.summary / .done.button    完成卡片（本次联测补的 identifier）
//   - lansync.fail.message                     失败卡片错误文本（打进 XCTFail 消息）
//
//  ⚠️ 沿用 GapBackfillUITests 的两条踩坑记录：
//  1) SwiftUI 离屏元素 isHittable 误报 true → 要点的元素一律用「帧完整落在屏幕内」判定；
//  2) 非懒加载 VStack 里离屏元素 exists / label 可直接读，不为读值而滑动。
//

import XCTest

final class LANSyncUITests: XCTestCase {

    /// 等待拉取完成/失败结论的上限：本机回环（127.0.0.1）传 favorites 一个小文件，
    /// 正常几秒内完成；配对 + 传输余量给 60s（任务规格值）
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

    // MARK: - 用例：从手动直连对端拉取「自选」到本机（双模拟器联测 UD1 侧）

    func testPullFavoritesFromManualPeer() throws {
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

        // 4) 手动直连：输入对端地址（默认 UD2 的 127.0.0.1:5052；可用 TEST_RUNNER_LAN_PEER
        //    覆盖为真机地址如 192.168.2.13:5051，做「模拟器 ← 真机」跨设备验收）
        let peerAddr = ProcessInfo.processInfo.environment["LAN_PEER"] ?? "127.0.0.1:5052"
        let field = reveal("lansync.manual.field", in: app) {
            $0.textFields["lansync.manual.field"].firstMatch
        }
        field.tap()
        field.typeText(peerAddr)
        print("LAN manualAddress 已输入 \(peerAddr)")
        dismissKeyboardIfPresent(app)

        let connect = reveal("lansync.manual.connect", in: app) {
            $0.buttons["lansync.manual.connect"].firstMatch
        }
        connect.tap()

        // 5) configure 页就绪：内容勾选行出现（方向固定为拉取，无方向控件）。
        //    若连接失败会弹 alert（无法连接 / 对端不可同步），读 alert 文本打进断言消息。
        let fav = app.buttons["lansync.category.favorites"].firstMatch
        var connectAlert: String? = nil
        let connectDeadline = Date().addingTimeInterval(15)
        while Date() < connectDeadline {
            if fav.exists { break }
            let alert = app.alerts.firstMatch
            if alert.exists { connectAlert = alert.label; break }
            usleep(500_000)
        }
        if let alertText = connectAlert {
            let detail = app.alerts.firstMatch.staticTexts.firstMatch.label
            XCTFail("手动直连后未进入配置页，弹出提示：「\(alertText)」\(detail.isEmpty ? "" : " / \(detail)")")
            return
        }
        _ = reveal("lansync.category.favorites", in: app) {
            $0.buttons["lansync.category.favorites"].firstMatch
        }
        print("LAN 已进入 configure 页")

        // 6) 勾选「自选」（favorites）
        fav.tap()
        print("LAN 已勾选 favorites")

        // 7) 开始拉取（对端已暴露，自动授权，无需在其上确认）
        let start = reveal("lansync.start", in: app) {
            $0.buttons["lansync.start"].firstMatch
        }
        snap(app, "lansync.beforeStart")
        start.tap()

        // 8) 轮询结论（≤60s）：完成卡片 / 失败卡片（对端暴露即授权，不存在确认弹窗分支）
        let summary = app.staticTexts["lansync.result.summary"].firstMatch
        let failMsg = app.staticTexts["lansync.fail.message"].firstMatch
        let deadline = Date().addingTimeInterval(Self.verdictTimeout)
        var doneSummary: String? = nil
        var failureText: String? = nil
        var tick = 0
        while Date() < deadline {
            if failMsg.exists {
                failureText = failMsg.label
                break
            }
            if summary.exists && !summary.label.isEmpty {
                doneSummary = summary.label
                break
            }
            tick += 1
            if tick % 20 == 0 {   // 每 10s 打一次进度，便于看链路卡在哪
                print("LAN tick=\(tick / 2)s 等待拉取结论中…")
            }
            usleep(500_000)
        }
        snap(app, "lansync.verdict")
        print("LAN resultSummary = \(doneSummary ?? "<未出现>")")
        print("LAN failureText = \(failureText ?? "<无>")")

        // 9) 断言：完成而非失败（失败时把错误文本带出来）
        if let failure = failureText {
            XCTFail("拉取失败卡片出现：\(failure)")
            return
        }
        guard let finalSummary = doneSummary else {
            XCTFail("拉取未在 \(Int(Self.verdictTimeout))s 内出结论（既无完成卡片也无失败卡片，可能卡在配对/传输）")
            return
        }
        XCTAssertTrue(app.buttons["lansync.done.button"].firstMatch.waitForExistence(timeout: 5),
                      "完成汇总已出现但「完成」按钮不存在（done 卡片渲染不完整）")
        print("LAN 拉取完成，汇总：\(finalSummary)")
    }

    // MARK: - 用例：单次扫描能发现已暴露的对端（真机 Bonjour 浏览回归）

    /// 前置：**同网段**另有一台实例已启动并暴露（外部脚本准备，如
    /// `SIMCTL_CHILD_KLINE_EXPOSED=1 SIMCTL_CHILD_KLINE_HTTP_PORT=5052 launch`）。
    /// 本机进「联机同步 → 扫描一次」，断言列表出现对端（lansync.peer.0）。
    ///
    /// 回归对象：真机缺失 `NSBonjourServices` 时 NWBrowser 浏览报 -65555 NoAuth，
    /// 扫描恒 0 台（模拟器不做该门禁，故只有真机暴露）。此用例在真机上跑才有意义。
    func testScanOnceDiscoversExposedPeer() throws {
        let app = XCUIApplication()
        // 首次声明 NSBonjourServices 后 iOS 会弹「查找本地网络中的设备」系统权限框；
        // 点「允许」，否则 Bonjour 浏览/发布被拒（NoAuth）。
        addUIInterruptionMonitor(withDescription: "本地网络权限") { alert in
            for label in ["允许", "Allow", "好", "OK"] {
                let btn = alert.buttons[label]
                if btn.exists { btn.tap(); return true }
            }
            return false
        }
        app.launch()

        XCTAssertTrue(app.buttons["tab.home"].firstMatch.waitForExistence(timeout: 20),
                      "启动后未显示底部菜单")
        app.buttons["tab.home"].firstMatch.tap()
        let profileButton = app.buttons["home.profileButton"].firstMatch
        XCTAssertTrue(profileButton.waitForExistence(timeout: 10), "首页标题栏未找到用户入口")
        profileButton.tap()
        XCTAssertTrue(app.staticTexts["个人中心"].firstMatch.waitForExistence(timeout: 10),
                      "个人中心未打开")

        let entry = reveal("profile.lansync.entry", in: app) {
            $0.buttons["profile.lansync.entry"].firstMatch
        }
        entry.tap()

        XCTAssertTrue(app.descendants(matching: .any)["lansync.local.status"].firstMatch
            .waitForExistence(timeout: 10)
            || app.otherElements["lansync.local.status"].firstMatch
                .waitForExistence(timeout: 5),
            "联机同步页未打开（未找到 lansync.local.status）")

        let scan = reveal("lansync.scan.once", in: app) {
            $0.buttons["lansync.scan.once"].firstMatch
        }
        scan.tap()
        print("LAN 已点击扫描一次")

        // 扫描窗口 4s + 解析余量（resolve 上限 5s）：给 20s
        let peer0 = app.descendants(matching: .any)["lansync.peer.0"].firstMatch
        XCTAssertTrue(peer0.waitForExistence(timeout: 20),
                      "扫描后未发现任何对端设备（真机 Bonjour 浏览失败？检查 NSBonjourServices / 本地网络权限）")
        snap(app, "lansync.scan.discovered")
        print("LAN 扫描发现对端：\(peer0.label)")
    }

    // MARK: - 辅助：自动化授予「本地网络」权限（真机）

    /// 验收辅助用例：在「设置 → 隐私与安全性 → 本地网络」把 Kline 的开关打开。
    /// 前置：调用前先把「设置」停在本地网络页，可用
    /// `xcrun devicectl device process openURL --device <id> "prefs:root=Privacy&path=LOCAL_NETWORK"`。
    /// 说明：iOS 14+ 的本地网络权限没有任何程序接口可授予，只能系统设置里点开关；
    /// 该用例让真机验收无需人工点击（依赖「开发者 → Enable UI Automation」已开）。
    func testEnableKlineLocalNetwork() throws {
        // 默认跳过：它会打开「设置」并改动系统权限，只能在需要时显式运行：
        //   TEST_RUNNER_LAN_GRANT=1 xcodebuild test ... -only-testing:KlineUITests/LANSyncUITests/testEnableKlineLocalNetwork
        guard ProcessInfo.processInfo.environment["LAN_GRANT"] == "1" else {
            throw XCTSkip("仅在手动授予真机本地网络权限时运行（需 TEST_RUNNER_LAN_GRANT=1）")
        }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()

        let kline = settings.staticTexts["Kline"].firstMatch
        var hit = false
        for _ in 0..<30 {
            if kline.exists && kline.isHittable { hit = true; break }
            settings.swipeUp()
            usleep(300_000)
        }
        XCTAssertTrue(hit, "未在「本地网络」列表中找到 Kline（设置页需先停在本地网络页）")

        let y = kline.frame.midY
        let rowSwitch = settings.switches.allElementsBoundByIndex
            .first { abs($0.frame.midY - y) < 24 }
        guard let sw = rowSwitch else { XCTFail("未找到 Kline 行对应的开关"); return }
        if (sw.value as? String) == "1" {
            print("LAN Kline 本地网络权限已经是开")
        } else {
            sw.tap()
            usleep(500_000)
            print("LAN 已打开 Kline 本地网络权限，现值=\(String(describing: sw.value))")
        }
        snap(settings, "settings.localNetwork.kline")
    }
}

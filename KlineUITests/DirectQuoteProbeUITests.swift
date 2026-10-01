//
//  DirectQuoteProbeUITests.swift
//  KlineUITests
//
//  设备侧「直连源链对拍」PoC 的自动化验收（**替代人工点击**）：
//  个人中心 → 本地更新 → 「直连源链对拍（仅调试用）」→ 跑一次对拍 →
//  等结论出来后断言「量纲零偏差」（腾讯 / 新浪两源与云端 CNB 分片逐只对拍）。
//
//  元素定位全部基于 accessibilityIdentifier（定义在各页面源码中）：
//   - home.profileButton   首页标题栏用户入口（打开个人中心）
//   - directProbe.run      「跑一次对拍」整行按钮
//   - directProbe.status / .baseline / .tencent / .sina / .verdict   五个读数行（值是 staticText）
//   - directProbe.detail.N 对拍明细逐行
//
//  ⚠️ 踩坑记录（两条，都值钱）：
//  1) SwiftUI 里**离屏元素的 `isHittable` 会误报 true**
//     （实测按钮 frame=(16, 854, 992, 48)、屏高仅 768，仍返回 hittable=true），
//     照它点击会落在屏幕外被系统丢弃（表现为「点了没反应」）。
//     故本文件对**要点的**元素一律用「帧是否完整落在屏幕内」判定可见性，不信 isHittable。
//  2) **读取不需要可见性**：`ScrollView` 内是非懒加载 `VStack`，离屏元素同样在无障碍树里，
//     `exists` / `label` 都能直接读。早期版本对每一行都做「滑动找可见」，
//     30 行明细里 24 行本就不存在 → 白滑 637 次、单次用例耗时 21 分钟。现已改为直接读。
//

import XCTest

final class DirectQuoteProbeUITests: XCTestCase {

    /// 结论轮询上限：两源全市场取数（腾讯 34 批 + 新浪 12 批）实测 10~25s，
    /// 模拟器冷启动 + 网络抖动留足余量
    private static let verdictTimeout: TimeInterval = 180

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 工具

    /// 帧是否完整落在屏幕内（不信 isHittable）
    private func isFullyOnScreen(_ element: XCUIElement, _ app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let f = element.frame
        let s = app.frame
        return f.width > 1 && f.height > 1
            && f.minY >= s.minY && f.maxY <= s.maxY
            && f.minX >= s.minX && f.maxX <= s.maxX
    }

    /// 个人中心内容很长（本地更新 / 数据同步 / 清单标的自动更新 / 直连对拍四组卡片），
    /// 目标行在视口下方：反复整屏上滑直到按钮完整进入屏幕。
    private func revealProbeButton(_ app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["directProbe.run"].firstMatch
        for _ in 0..<40 {
            if isFullyOnScreen(button, app) { return button }
            app.swipeUp()
            usleep(400_000)
        }
        XCTFail("个人中心底部未能在屏幕内找到「跑一次对拍」按钮（directProbe.run，"
                + "frame=\(button.exists ? "\(button.frame)" : "不存在")，屏幕 \(app.frame)）")
        return button
    }

    /// 读某行读数的文案：**离屏也能读 `label`**（不需要滚进视口，见文件头踩坑记录第 2 条）。
    /// 只有 `tap` 才要求元素在屏幕内；`ScrollView` 内是非懒加载 `VStack`，整棵树都暴露在无障碍树里。
    private func readText(_ app: XCUIApplication, _ id: String) -> String {
        let element = app.staticTexts[id].firstMatch
        return element.exists ? element.label : ""
    }

    /// 等状态行离开「尚未运行」（= run() 已被触发）
    private func waitStatusChange(_ status: XCUIElement, _ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if status.exists && status.label != "尚未运行" { return true }
            usleep(500_000)
        }
        return false
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    // MARK: - 用例 110：直连源链对拍（腾讯 / 新浪 vs CNB 分片）

    func test110_DirectProbe_TencentSinaMatchCNBSnapshot() throws {
        let app = XCUIApplication()
        app.launch()

        // 0) 启动就绪：底部菜单出现，且主库已加载出行情行（metaList 就绪的前置条件）
        let marketTab = app.buttons["tab.market"]
        XCTAssertTrue(marketTab.waitForExistence(timeout: 20), "启动后未显示底部菜单")
        XCTAssertTrue(app.descendants(matching: .any)["market.rowCard"].firstMatch
            .waitForExistence(timeout: 20), "行情列表未加载（主库未就绪）")

        // 1) 首页 → 个人中心（走标题栏用户入口，不依赖中文文案）
        app.buttons["tab.home"].tap()
        XCTAssertTrue(app.staticTexts["home.page"].waitForExistence(timeout: 10), "首页未显示")
        let profileButton = app.buttons["home.profileButton"].firstMatch
        XCTAssertTrue(profileButton.waitForExistence(timeout: 10), "首页标题栏未找到用户入口")
        profileButton.tap()
        XCTAssertTrue(app.staticTexts["个人中心"].firstMatch.waitForExistence(timeout: 10),
                      "个人中心未打开")

        // 2) 滚到底部「直连源链对拍」卡片，点「跑一次对拍」
        let runButton = revealProbeButton(app)
        snap(app, "directProbe.before")
        print("PROBE runButton frame=\(runButton.frame) 屏幕=\(app.frame)")

        let status = app.staticTexts["directProbe.status"].firstMatch
        func statusLabel() -> String { status.exists ? status.label : "<离屏>" }

        // 3) 触发：等状态行离开「尚未运行」（没离开就是点击没到达 Button action）
        runButton.tap()
        _ = waitStatusChange(status, 8)
        print("PROBE status(after tap) = \(statusLabel())")
        XCTAssertNotEqual(statusLabel(), "尚未运行",
                          "点击「跑一次对拍」未触发 DirectQuoteProbe.run()（状态仍为「尚未运行」）")

        // 4) 轮询结论行：从占位「—」变为最终结论（离屏元素仍可读 label，故只需容错 exists）
        let verdict = app.staticTexts["directProbe.verdict"].firstMatch
        let deadline = Date().addingTimeInterval(Self.verdictTimeout)
        var verdictLabel = "—"
        var tick = 0
        while Date() < deadline {
            if verdict.exists {
                verdictLabel = verdict.label
                if verdictLabel != "—" { break }
            }
            tick += 1
            if tick % 20 == 0 {                                  // 每 10s 打一次状态，便于看进度
                print("PROBE tick=\(tick / 2)s status=\(statusLabel()) verdict=\(verdictLabel)")
            }
            usleep(500_000)
        }
        snap(app, "directProbe.after")

        // 5) 打印全量读数（失败时便于定位；完整报告另见沙盒 [DirectProbe] 日志）
        for id in ["directProbe.status", "directProbe.baseline",
                   "directProbe.tencent", "directProbe.sina", "directProbe.verdict"] {
            let label = readText(app, id)
            print("PROBE \(id) = \(label.isEmpty ? "<缺失>" : label)")
        }
        var details: [String] = []
        for i in 0..<30 {
            let label = readText(app, "directProbe.detail.\(i)")
            guard !label.isEmpty else { continue }
            details.append(label)
            print("PROBE detail[\(i)] = \(label)")
        }

        // 6) 断言
        XCTAssertNotEqual(verdictLabel, "—",
                          "对拍未在 \(Int(Self.verdictTimeout))s 内出结论（仍在运行或已卡死）")
        XCTAssertFalse(verdictLabel.contains("失败"), "对拍失败：\(verdictLabel)")
        XCTAssertTrue(verdictLabel.contains("腾讯与 CNB 分片逐只零偏差"),
                      "腾讯未与 CNB 分片逐只零偏差（价/量）：\(verdictLabel)")
        XCTAssertTrue(verdictLabel.contains("新浪量纲零错位"),
                      "新浪量纲出现错位（手/股 100 倍）：\(verdictLabel)")
        XCTAssertFalse(details.contains { $0.contains("量纲错位") },
                       "明细出现量纲错位：\(details.filter { $0.contains("量纲错位") })")
        XCTAssertGreaterThanOrEqual(details.count, 2,
                                    "对拍明细一行都没读到（无障碍树没暴露明细行？）")

        // 腾讯那一栏必须满命中：它是主源，缺一只都说明映射/批量有问题
        let tencent = readText(app, "directProbe.tencent")
        XCTAssertTrue(tencent.contains("缺 0"),
                      "腾讯存在缺失标的（应为主源满命中）：\(tencent.isEmpty ? "<缺失>" : tencent)")
    }
}
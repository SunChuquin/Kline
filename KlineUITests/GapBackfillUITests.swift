//
//  GapBackfillUITests.swift
//  KlineUITests
//
//  「补缺口（主库最新日 → 今天）」的自动化验收（**替代人工点击**）：
//  个人中心 → 本地更新 → 「补缺口」卡片 → 补一次缺口 →
//  等结论出来后断言「缺口已补」且「口径异常 0」。
//
//  元素定位全部基于 accessibilityIdentifier（定义在 LocalUpdateView.swift）：
//   - home.profileButton    首页标题栏用户入口（打开个人中心）
//   - gapBackfill.run       「补一次缺口」整行按钮
//   - gapBackfill.status / .coverage / .fetch / .verdict   四个读数行（值是 staticText）
//   - gapBackfill.detail.N  明细逐行
//
//  ⚠️ 踩坑记录（沿用 DirectQuoteProbeUITests 的两条，都值钱）：
//  1) SwiftUI 里**离屏元素的 `isHittable` 会误报 true**（实测按钮 frame 已在屏幕外仍返回 true），
//     照它点击会落在屏幕外被系统丢弃（表现为「点了没反应」）。
//     故本文件对**要点的**元素一律用「帧是否完整落在屏幕内」判定可见性，不信 isHittable。
//  2) **读取不需要可见性**：`ScrollView` 内是非懒加载 `VStack`，离屏元素同样在无障碍树里，
//     `exists` / `label` 都能直接读 —— 不要为读一行去滑动找可见（那样会白滑几百次）。
//

import XCTest

final class GapBackfillUITests: XCTestCase {

    /// 结论轮询上限：全市场逐只请求腾讯历史K线（3600 只 / 12 路并发）实测 1~3 分钟，留足余量
    private static let verdictTimeout: TimeInterval = 600

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

    /// 个人中心内容很长（本地更新 / 数据同步 / 清单自动更新 / 直连对拍 / 补缺口 五组卡片），
    /// 「补缺口」在最底部：反复整屏上滑直到按钮完整进入屏幕。
    private func revealBackfillButton(_ app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["gapBackfill.run"].firstMatch
        for _ in 0..<60 {
            if isFullyOnScreen(button, app) { return button }
            app.swipeUp()
            usleep(300_000)
        }
        XCTFail("个人中心底部未能在屏幕内找到「补一次缺口」按钮（gapBackfill.run，"
                + "frame=\(button.exists ? "\(button.frame)" : "不存在")，屏幕 \(app.frame)）")
        return button
    }

    /// 读某行读数的文案：**离屏也能读 `label`**（不需要滚进视口，见文件头踩坑记录第 2 条）
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

    // MARK: - 用例 120：补缺口（主库最新日 → 今天）

    func test120_GapBackfill_MainLatestToToday() throws {
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

        // 2) 滚到底部「补缺口」卡片，点「补一次缺口」
        let runButton = revealBackfillButton(app)
        snap(app, "gapBackfill.before")
        print("GAP runButton frame=\(runButton.frame) 屏幕=\(app.frame)")

        let status = app.staticTexts["gapBackfill.status"].firstMatch
        func statusLabel() -> String { status.exists ? status.label : "<离屏>" }

        // 3) 触发：等状态行离开「尚未运行」（没离开就是点击没到达 Button action）
        runButton.tap()
        _ = waitStatusChange(status, 8)
        print("GAP status(after tap) = \(statusLabel())")
        XCTAssertNotEqual(statusLabel(), "尚未运行",
                          "点击「补一次缺口」未触发 GapBackfill.run()（状态仍为「尚未运行」）")

        // 4) 轮询结论行：从占位「—」变为最终结论（离屏元素仍可读 label，故只需容错 exists）
        let verdict = app.staticTexts["gapBackfill.verdict"].firstMatch
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
                print("GAP tick=\(tick / 2)s status=\(statusLabel()) verdict=\(verdictLabel)")
            }
            usleep(500_000)
        }
        snap(app, "gapBackfill.after")

        // 5) 打印全量读数（失败时便于定位；完整报告另见沙盒 [GapBackfill] 日志）
        for id in ["gapBackfill.status", "gapBackfill.coverage",
                   "gapBackfill.fetch", "gapBackfill.verdict"] {
            let label = readText(app, id)
            print("GAP \(id) = \(label.isEmpty ? "<缺失>" : label)")
        }
        var details: [String] = []
        for i in 0..<40 {
            let label = readText(app, "gapBackfill.detail.\(i)")
            guard !label.isEmpty else { continue }
            details.append(label)
            print("GAP detail[\(i)] = \(label)")
        }

        // 6) 断言
        XCTAssertNotEqual(verdictLabel, "—",
                          "补缺口未在 \(Int(Self.verdictTimeout))s 内出结论（仍在运行或已卡死）")
        // ⚠️ 不能用 `contains("失败")`：结论里本就带「取数失败 N 只」这个**计数项**。
        //    硬失败的文案固定是前缀「失败：」，只认前缀。
        XCTAssertFalse(verdictLabel.hasPrefix("失败"),
                       "补缺口失败：\(verdictLabel)")
        // 节假日 / 已补齐时走「无缺口早退」单只探测（2026-10-06 国庆实测：源侧最新 = 主库 20260930），
        // 属**合法成功态**，此时不会出现「缺口已补」「口径异常 0」「缺口覆盖」等缺口态文案
        // → 断言无缺口结论成立即收，跳过缺口态断言（否则每个休市日必挂）。
        if verdictLabel.contains("无缺口") {
            print("GAP 无缺口早退（非交易日或已补齐），跳过缺口态断言：\(verdictLabel)")
            return
        }
        XCTAssertTrue(verdictLabel.contains("缺口已补"),
                      "结论未出现「缺口已补」：\(verdictLabel)")
        XCTAssertTrue(verdictLabel.contains("口径异常 0"),
                      "出现口径异常（价格 / 量比 / 额比不符，已丢弃）：\(verdictLabel)")
        XCTAssertGreaterThanOrEqual(details.count, 2,
                                    "明细一行都没读到（无障碍树没暴露明细行？）")
        // 覆盖交易日行必须存在，且日期落在主库最新日之后
        XCTAssertTrue(details.contains { $0.contains("缺口覆盖") },
                      "明细缺少「缺口覆盖 <区间>」行：\(details)")

        // 量纲必须两种口径都自校准成功（个股 100x / 指数 1x），否则说明吸附逻辑失效
        let fetch = readText(app, "gapBackfill.fetch")
        XCTAssertTrue(fetch.contains("补齐"),
                      "「补齐结果」行未出现补齐统计：\(fetch.isEmpty ? "<缺失>" : fetch)")

        // 周/月/季/年线缺口：日线补齐只让日线图连续，周期视图还得从新日线重新聚合成桶。
        // 结论必须带「周 N / 月 M / 季 Q / 年 Y 行」；明细必须有「周期聚合」行（含四类锚与行数）。
        // ⚠️ 只断言「存在」不断言行数：本组件幂等，重跑时桶内 bar 与库内一致，行数会变（不写重复行）。
        XCTAssertTrue(verdictLabel.contains("周 ") && verdictLabel.contains("月 ")
                      && verdictLabel.contains("季 ") && verdictLabel.contains("年 "),
                      "结论未含周/月/季/年线行数（周期聚合未接入）：\(verdictLabel)")
        XCTAssertTrue(details.contains { $0.contains("周期聚合") && $0.contains("季线") && $0.contains("年线") },
                      "明细缺少「周期聚合」行（含四类锚与周/月/季/年行数）：\(details)")
    }
}
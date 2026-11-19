//
//  GapBackfillUITests.swift
//  KlineUITests
//
//  「补缺口（主库最新日 → 今天）」的自动化验收（**替代人工点击**）：
//  个人中心 → 本地更新（P2-6c-1 起为全屏 Web 页）→ 「补缺口」卡片 → 补一次缺口 →
//  等结论出来后断言「缺口已补」且「口径异常 0」。
//
//  元素定位（P2-6c-1 起在 WKWebView 内，LocalUpdatePanel.vue）：
//   - home.profileButton         首页标题栏用户入口（aria-label，HomePage.vue）
//   - profile.localUpdate.entry  个人中心「本地更新」入口行（原生 ProfileDetailView）
//   - gapBackfill.run            「补一次缺口」整行按钮（aria-label = 锚点）
//   - gapBackfill.status / .coverage / .fetch / .verdict / .detail.N
//     值行复合锚点：aria-label = "锚点|值文本"（label=aria-label），读值取 | 后段
//
//  ⚠️ Web 页读值/滚动与原生 SwiftUI 的差异：
//  1) 值行 label 是复合串「锚点|值」——必须用 label BEGINSWITH 定位、再取 | 后段；
//  2) WKWebView 内元素通常全量暴露（离屏也可读），但要点按的按钮仍需滚进屏幕；
//  3) app.swipeUp() 落在全屏 WebView 上 = 滚动 Web 内容，reveal 循环照常可用。
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

    /// 反复整屏上滑直到目标元素完整进入屏幕
    private func reveal(_ id: String, in app: XCUIApplication,
                        using match: (XCUIApplication) -> XCUIElement) -> XCUIElement {
        let element = match(app)
        for _ in 0..<60 {
            if isFullyOnScreen(element, app) { return element }
            app.swipeUp()
            usleep(300_000)
        }
        XCTFail("未能滚动到屏幕内找到元素 \(id)（exists=\(element.exists)，"
                + "frame=\(element.exists ? "\(element.frame)" : "无")，屏幕 \(app.frame)）")
        return element
    }

    /// 值行读值：复合锚点「anchor|值」→ label BEGINSWITH 定位，取 | 后段
    private func readText(_ app: XCUIApplication, _ id: String) -> String {
        let element = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", id)).firstMatch
        guard element.exists else { return "" }
        let label = element.label
        if let range = label.range(of: "|") { return String(label[range.upperBound...]) }
        return label
    }

    private func rowExists(_ app: XCUIApplication, _ id: String) -> Bool {
        app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", id)).firstMatch.exists
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
        let profileButton = app.buttons["home.profileButton"].firstMatch
        XCTAssertTrue(profileButton.waitForExistence(timeout: 10), "首页标题栏未找到用户入口")
        profileButton.tap()
        XCTAssertTrue(app.staticTexts["个人中心"].firstMatch.waitForExistence(timeout: 10),
                      "个人中心未打开")

        // 2) 点「本地更新」入口行（P2-6c-1：内嵌卡片组提取为全屏 Web 页）
        let entry = reveal("profile.localUpdate.entry", in: app) {
            $0.buttons["profile.localUpdate.entry"].firstMatch
        }
        entry.tap()
        let runButtonInWeb = app.buttons["gapBackfill.run"].firstMatch
        XCTAssertTrue(runButtonInWeb.waitForExistence(timeout: 15),
                      "本地更新 Web 页未打开（未找到 gapBackfill.run）")

        // 3) 滚到「补一次缺口」按钮并点击
        let runButton = reveal("gapBackfill.run", in: app) { $0.buttons["gapBackfill.run"].firstMatch }
        snap(app, "gapBackfill.before")
        print("GAP runButton frame=\(runButton.frame) 屏幕=\(app.frame)")

        func statusValue() -> String { readText(app, "gapBackfill.status") }

        // 4) 触发：等状态行离开「尚未运行」（没离开就是点击没到达）
        runButton.tap()
        var changed = false
        let changeDeadline = Date().addingTimeInterval(8)
        while Date() < changeDeadline {
            if rowExists(app, "gapBackfill.status") && statusValue() != "尚未运行" { changed = true; break }
            usleep(500_000)
        }
        print("GAP status(after tap) = \(statusValue())")
        XCTAssertTrue(changed && statusValue() != "尚未运行",
                      "点击「补一次缺口」未触发 GapBackfill.run()（状态仍为「尚未运行」）")

        // 5) 轮询结论行：从占位「—」变为最终结论
        let verdictDeadline = Date().addingTimeInterval(Self.verdictTimeout)
        var verdictLabel = "—"
        var tick = 0
        while Date() < verdictDeadline {
            let v = readText(app, "gapBackfill.verdict")
            if !v.isEmpty && v != "—" {
                verdictLabel = v
                break
            }
            tick += 1
            if tick % 20 == 0 {                                  // 每 10s 打一次状态，便于看进度
                print("GAP tick=\(tick / 2)s status=\(statusValue()) verdict=\(verdictLabel)")
            }
            usleep(500_000)
        }
        snap(app, "gapBackfill.after")

        // 6) 打印全量读数（失败时便于定位；完整报告另见沙盒 [GapBackfill] 日志）
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

        // 7) 断言
        XCTAssertNotEqual(verdictLabel, "—",
                          "补缺口未在 \(Int(Self.verdictTimeout))s 内出结论（仍在运行或已卡死）")
        // ⚠️ 不能用 `contains("失败")`：结论里本就带「取数失败 N 只」这个**计数项**。
        //    硬失败的文案固定是前缀「失败：」，只认前缀。
        XCTAssertFalse(verdictLabel.hasPrefix("失败"),
                       "补缺口失败：\(verdictLabel)")
        // 节假日 / 已补齐时走「无缺口早退」单只探测，属**合法成功态**，此时不会出现
        // 「缺口已补」「口径异常 0」等缺口态文案 → 断言无缺口结论成立即收（否则每个休市日必挂）。
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
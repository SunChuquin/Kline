//
//  UITestLaunch.swift
//  KlineUITests
//
//  用例统一启动入口：注入 `-uitest-reset`，让 App 在启动时清空用户态后走既有 seed 重建。
//
//  为什么必须：UI 用例会改 App 的持久化用户态（最典型是布局编辑用例改写
//  `Documents/Layouts/home.json`），下一条用例启动后看到被改过的初始态
//  → 入口位置/控件消失 → 串跑出现「互相污染」的假失败（单跑却通过）。
//
//  参数语义与清理范围见 App 侧 `UITestStateReset.swift`；行情主库不受影响。
//

import XCTest

extension XCUIApplication {
    /// 以「干净状态」构造（随后由用例自行 `launch()`）
    static func launchingClean() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-uitest-reset")
        return app
    }
}

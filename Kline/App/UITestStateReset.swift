//
//  UITestStateReset.swift
//  Kline
//
//  UI 测试专用：**用例级状态隔离**（hermetic）。
//
//  问题：UI 用例会改 App 的持久化用户态（最典型的是布局编辑用例改写
//  `Documents/Layouts/home.json`），下一条用例启动后看到的是被改过的初始态
//  → 入口位置/控件消失 → 串跑出现「互相污染」的假失败（单跑却通过）。
//
//  做法：带 `-uitest-reset` 启动时，先清空**用户态**再走既有 seed 重建，使每条用例
//  都从同一初始态开始。用例侧由 `XCUIApplication.launchingClean()` 统一注入该参数。
//
//  「用户态」＝ UserDefaults（布局档位 / 图表配置 / 自选分组等）
//            + `Documents/Layouts/*.json`（页面布局配置，含首页/自选/行情/模拟）
//            + `Documents/**/*.json`（Simulation/sim.json 等各 Store 自建状态）
//  **不动行情数据**（`Documents/tdx.db` / `tdx_live.db` —— 由 PC 生成、非用户态）。
//
//  ⚠️ 新增一个「落盘到 Documents 的 Store」时，确认其目录是否已被下面的清理覆盖；
//     仅新建 Layouts/Simulation 之外的**非 JSON** 状态目录时才需要补清理项。
//
//  仅在 DEBUG 生效：Release 构建下本文件是空实现，参数不构成任何外部可触发的破坏面。
//

import Foundation

enum UITestStateReset {

    static let launchArgument = "-uitest-reset"

    /// 是否由 UI 测试以「干净状态」启动
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// 命中参数则清空用户态（幂等；任何一步失败都只记日志，绝不阻断启动）
    static func runIfRequested() {
        #if DEBUG
        guard isRequested else { return }
        let fm = FileManager.default

        // 1) 偏好项：布局档位 / 图表配置 / 模拟 T+1 标记等
        //    （`DatabaseManager` 的主库基线键一并清掉是安全的：它会回落到 DB 文件创建时间重算）
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

        // 2) 页面布局配置：Documents/Layouts/<page>.json（污染高发区）
        try? fm.removeItem(at: docs.appendingPathComponent("Layouts", isDirectory: true))

        // 3) 各 Store 自建的 JSON 状态：Documents/Simulation/sim.json 等
        try? fm.removeItem(at: docs.appendingPathComponent("Simulation", isDirectory: true))
        if let files = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension == "json" {
                try? fm.removeItem(at: url)
            }
        }

        DebugLogger.shared.log("[UITest] \(launchArgument)：已清空用户态"
                               + "（UserDefaults + Documents/Layouts + Documents/**/*.json）")
        #endif
    }
}

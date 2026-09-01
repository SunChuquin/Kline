//
//  KlineApp.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/19.
//

import SwiftUI

@main
struct KlineApp: App {
    /// 应用版本号，便于通过设备日志识别已安装的构建
    static let appVersion = "1.0.1"

    init() {
        // 每次启动重置沙盒日志，保证 debug_log.txt 只含本次启动到现在的记录
        DebugLogger.shared.clear()
        DebugLogger.shared.log("== App 启动 == 版本:\(KlineApp.appVersion)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

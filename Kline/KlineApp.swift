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
        print("[Kline] 启动构建版本: \(KlineApp.appVersion)")
        DebugLogger.shared.log("== App 启动 == 版本:\(KlineApp.appVersion)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

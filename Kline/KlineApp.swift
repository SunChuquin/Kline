//
//  KlineApp.swift
//  Kline
//
//  Created by 孙楚坤 on 2026/6/19.
//

import SwiftUI
import UIKit

/// 方向锁定：iPad 与 iPhone 均仅横屏（左右两个横屏方向可自由切换），旋转设备不翻转。
/// 与 pbxproj 的 INFOPLIST_KEY_UISupportedInterfaceOrientations_* 双重保险，
/// 启动即正确方向，前后台切换/设备旋转全程稳定横屏。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return [.landscapeLeft, .landscapeRight]
    }
}

@main
struct KlineApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// 应用版本号，便于通过设备日志识别已安装的构建
    static let appVersion = "1.0.2"

    init() {
        // 每次启动重置沙盒日志，保证 debug_log.txt 只含本次启动到现在的记录
        DebugLogger.shared.clear()
        DebugLogger.shared.log("== App 启动 == 版本:\(KlineApp.appVersion)")

        // 启动本地 HTTP 服务器（A2 本地更新安装 + 🥈 远程更新触发）
        KlineHTTPServer.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

//
//  KlineApp.swift
//  Kline
//
//  Created by 孙楚坤 on 2026/6/19.
//

import SwiftUI
import UIKit

/// 方向锁定：iPad 仅横屏（左右两个横屏方向可自由切换），iPhone 仅竖屏。
/// 与 pbxproj 的 INFOPLIST_KEY_UISupportedInterfaceOrientations_* 双重保险，
/// 启动即正确方向，用户旋转设备也不会翻转。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return UIDevice.current.userInterfaceIdiom == .pad
            ? [.landscapeLeft, .landscapeRight]
            : [.portrait]
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

        // 诊断：记录容器/文档目录实际状态（排查 TrollStore no-sandbox 版数据存储位置）
        logPathDiagnostics()

        // 启动本地 HTTP 服务器（A2 本地更新安装 + 🥈 远程更新触发）
        KlineHTTPServer.shared.start()
    }

    /// 诊断：记录沙盒/容器路径的实际状态，供拉日志分析「持久化数据到底存哪了」
    /// （TrollStore no-sandbox 版：documentDirectory 可能指向公共区或返回空，需实测确认）
    private func logPathDiagnostics() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).map { $0.path }
        DebugLogger.shared.log("诊断 documentDirectory: \(docs)")
        let home = NSHomeDirectory()
        DebugLogger.shared.log("诊断 NSHomeDirectory: \(home)")
        let homeDocs = home + "/Documents"
        DebugLogger.shared.log("诊断 Home/Documents 存在: \(fm.fileExists(atPath: homeDocs))")
        if let items = try? fm.contentsOfDirectory(atPath: homeDocs) {
            DebugLogger.shared.log("诊断 Home/Documents 顶层: \(items)")
        }
        for d in docs {
            if let items = try? fm.contentsOfDirectory(atPath: d) {
                DebugLogger.shared.log("诊断 \(d) 顶层: \(items)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

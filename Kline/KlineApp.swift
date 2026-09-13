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

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // iPadOS 26+ 已废弃 UIRequiresFullScreen，窗口化多任务模式下系统会忽略
        // 方向声明（Apple 开发者论坛实测回归）。官方替代路径（TN3192）= 运行时对每个
        // UIWindowScene：① sizeRestrictions 固定为横屏全屏尺寸（禁缩放）；
        // ② requestGeometryUpdate 主动请求横屏几何。在 scene 激活/设备姿态变化时重新应用。
        // ⚠️ UIApplication.connectedScenes 只在通知回调读取，绝不在 SwiftUI body 求值期读取
        //（body 期读 UIKit 会毒化视图更新事务，项目历史踩坑）。
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(lockAllScenes),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(lockAllScenes),
                                               name: UIScene.didActivateNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(orientationDidChange),
                                               name: UIDevice.orientationDidChangeNotification,
                                               object: nil)
        // 姿态通知默认不生成，必须显式开启，否则上面的 observer 永不触发
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        return true
    }

    @objc private func orientationDidChange() {
        // 设备姿态变化后（iPadOS 26 可能把 App 强转竖屏），下一帧重新请求横屏
        DispatchQueue.main.async { [weak self] in self?.lockAllScenes() }
    }

    @objc private func lockAllScenes() {
        for case let ws as UIWindowScene in UIApplication.shared.connectedScenes {
            applyLandscapeLock(to: ws)
        }
    }

    private func applyLandscapeLock(to scene: UIWindowScene) {
        guard #available(iOS 16.0, *) else { return }
        // ① 固定横屏全屏尺寸：minimum = maximum，窗口不可缩放（iPhone 上 sizeRestrictions=nil，无操作）
        let screen = scene.screen.bounds.size
        let landscape = CGSize(width: max(screen.width, screen.height),
                               height: min(screen.width, screen.height))
        scene.sizeRestrictions?.minimumSize = landscape
        scene.sizeRestrictions?.maximumSize = landscape
        // ② 主动请求横屏几何更新（系统忽略声明时的强制路径）
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: [.landscapeLeft, .landscapeRight]))
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

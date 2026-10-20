//
//  KlineApp.swift
//  Kline
//
//  Created by 孙楚坤 on 2026/6/19.
//

import SwiftUI
import UIKit

/// 方向：跟随系统自动旋转（支持全部方向，竖屏即竖屏比例布局）。
/// 方向声明见 pbxproj 的 INFOPLIST_KEY_UISupportedInterfaceOrientations_*，
/// 此处不再做任何强制锁定。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .all
    }
}

@main
struct KlineApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// 应用版本号，便于通过设备日志识别已安装的构建
    static let appVersion = "1.0.2"

    init() {
        // UI 测试专用：带 -uitest-reset 启动时先清空用户态（用例级 hermetic 隔离，见 UITestStateReset）。
        // 必须放在任何 Store 读盘之前，故置于 init 首行。
        UITestStateReset.runIfRequested()

        // 日志滚动：上次会话归档为 debug_log.prev.txt（保留一份），本次清空重新记录；
        // 排障取证通道：debug_log.txt（本次）/ debug_log.prev.txt（上次）/ py_stderr.log
        DebugLogger.shared.rollOnLaunch()
        DebugLogger.shared.log("== App 启动 == 版本:\(KlineApp.appVersion)")

        // 启动本地 HTTP 服务器（A2 本地更新安装 + 🥈 远程更新触发）
        KlineHTTPServer.shared.start()

        // 启动增量库（Documents/tdx_live.db）指纹监视：前台每 5 分钟检查一次，
        // 回前台立即检查；指纹未变什么都不做，变化则热重载并广播数据版本
        LiveDataStore.shared.startWatching(interval: 300)

        // 启动设备侧更新调度（默认开启）：前台按 11:00 / 14:30 / 15:05 / 17:30 时刻表检查，
        // 到点即走腾讯直连链路——11:00/14:30/15:05 先补「清单并集」范围缺口再写当日 bar，
        // 17:30 为全市场补缺口（含自动合并主库）
        TdxSyncManager.shared.start()

        // 【首帧引擎实验】R1 启动后台预热：引擎加载 + tdx_eval 空转 text 调用（编译/AST 缓存
        // 一次性成本全部移出用户链路，首个真实求值直接进入稳态）；预热必须后台异步，绝不阻塞启动主线程
        KlinePythonBridge.shared.warmUp()

        // 阶段 A5-1：交易域信任链（套件 8）——启动即校验脚本哈希 / 版本锁，
        // 供 §9.10 降级矩阵判定交易可用性（过渡期 mode=.swift 时该闸门不生效）。
        SimRulesTrust.shared.refresh()

        // TEMP-DIAG(iPhone11适配): 屏幕几何探针（spec 调查脚手架，见文件底部说明）
        ScreenGeometryProbe.installIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - TEMP-DIAG(iPhone11适配): 屏幕几何探针（spec 调查脚手架，确认后随修复一并处理）
//
// 带 `-screen-probe` 启动时：把窗口尺寸 + 安全区 inset（含刘海左右）写入沙盒日志
// Documents/debug_log.txt，启动后 2s 记一次，此后每次设备方向变化（0.6s 防抖）再记一次。
// 目的：运行时确认 iPhone 11 竖屏 / 左横 / 右横的实际可用宽度与安全区（非代码推断）。
enum ScreenGeometryProbe {
    static let launchArgument = "-screen-probe"

    static func installIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        log()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { log() }
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification,
                                               object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { log() }
        }
    }

    static func log() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first else { return }
        let f = window.frame
        let s = window.safeAreaInsets
        let orientName: String
        switch scene.interfaceOrientation {
        case .portrait: orientName = "portrait"
        case .portraitUpsideDown: orientName = "portraitUpsideDown"
        case .landscapeLeft: orientName = "landscapeLeft"
        case .landscapeRight: orientName = "landscapeRight"
        default: orientName = "unknown(\(scene.interfaceOrientation.rawValue))"
        }
        DebugLogger.shared.log("[ScreenProbe] orient=\(orientName) window=\(Int(f.width))x\(Int(f.height)) safeArea top=\(String(format: "%.1f", s.top)) bottom=\(String(format: "%.1f", s.bottom)) left=\(String(format: "%.1f", s.left)) right=\(String(format: "%.1f", s.right)) scale=\(window.screen.scale)")
    }
}

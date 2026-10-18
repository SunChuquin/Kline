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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

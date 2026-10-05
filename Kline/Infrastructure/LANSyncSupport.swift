//
//  LANSyncSupport.swift
//  Kline
//
//  局域网设备联机同步 · 服务端支撑（KlineHTTPServer 的路由实现依赖本文件）：
//  1. LANSyncPairing —— 配对代理：暴露即授权（本机开启「暴露」后对端请求配对直接签发 token）
//  2. LANSyncReload  —— 配置/指标热重载：对端文件覆盖落盘后按 scope 重载各 Store
//  3. LANSyncSupport —— 本机 6 类可同步内容清单构建（GET /sync/status 的 items 段）
//
//  共享 wire format 契约见 LANSyncModels.swift（字段名即线上格式，两端共用，勿单独改动）。
//

import Foundation
import Combine

// MARK: - 通知名

extension Notification.Name {
    /// 主库 tdx.db 已被对端整库替换：App 收到后弹「主库已替换，请重启」提示
    /// （SQLite 连接与内存缓存需重启 App 才能安全重建，不做热重载）
    static let lansyncMainDBReplaced = Notification.Name("LANSyncMainDBReplaced")
}

// MARK: - 配对代理

/// 配对流程（仅拉取模型 · 暴露即授权，无逐次确认弹窗）：
///   本机在联机同步页打开「暴露」开关 → isExposed = true（同时 LANSyncAdvertiser 发布
///   mDNS 广播）；对端 POST /sync/request-pair → requestPair(from:items:completion:)
///   同步判定：isExposed（或 KLINE_AUTOPAIR=1，UI 测试用）→ 立即签发仅本会话有效的
///   token 回调；未暴露 → 回调 nil（发起方收到 403，提示"对端未开启暴露"）。
///   token 存入 sessionTokens，后续 /sync/backup、/sync/reload-config 请求头
///   X-Kline-Pair 携带并由 isValidToken 校验。
final class LANSyncPairing: ObservableObject {
    static let shared = LANSyncPairing()

    /// 本机是否对外暴露（发布 mDNS 广播 + 自动接受配对请求）。
    /// 默认 false：App 启动即隐藏、不可被同步；由联机同步页「暴露」开关读写，
    /// 退出联机同步页置回 false。仅主线程写（UI 事件），跨线程读 Bool 可容忍弱一致。
    @Published var isExposed: Bool

    /// 本会话有效 token 集合（进程存续期间有效）。
    /// 签发在调用线程、校验在监听队列 → 读写均经 tokenLock 串行化。
    private(set) var sessionTokens: Set<String> = []
    private let tokenLock = NSLock()

    private init() {
        // UI 测试专用：以 KLINE_EXPOSED=1（SIMCTL_CHILD_ 前缀透传）启动的实例
        // 启动即自动暴露（广播恢复由 KlineHTTPServer.start 就绪回调完成），无需进页面
        isExposed = ProcessInfo.processInfo.environment["KLINE_EXPOSED"] == "1"
    }

    // MARK: 请求配对（服务端路由调用，可能来自监听队列）

    /// 对端请求配对：暴露即授权 —— isExposed（或 KLINE_AUTOPAIR=1，UI 测试双模拟器
    /// 联测兼容）立即签发 token 回调；否则回调 nil（对端未暴露，服务端路由回 403）。
    /// 同步判定，无挂起状态、无超时定时器。
    func requestPair(from: String, items: [String], completion: @escaping (String?) -> Void) {
        let autoPair = ProcessInfo.processInfo.environment["KLINE_AUTOPAIR"] == "1"
        if isExposed || autoPair {
            DebugLogger.shared.log("[LANSyncPairing] 已暴露（autopair=\(autoPair)），签发 token（from=\(from)）")
            completion(issueToken())
        } else {
            DebugLogger.shared.log("[LANSyncPairing] 未暴露，拒绝配对请求 from=\(from)")
            completion(nil)
        }
    }

    // MARK: token 校验（服务端路由调用，来自监听队列）

    /// 会话 token 校验（/sync/backup、/sync/reload-config 请求头 X-Kline-Pair）
    func isValidToken(_ t: String) -> Bool {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        return sessionTokens.contains(t)
    }

    // MARK: 私有

    /// 签发新 token 并写入会话集合
    private func issueToken() -> String {
        let t = UUID().uuidString
        tokenLock.lock()
        sessionTokens.insert(t)
        tokenLock.unlock()
        return t
    }
}

// MARK: - 配置 / 指标热重载

/// 对端覆盖配置 / 指标文件后按 scope 热重载各 Store（POST /sync/reload-config，主线程执行）。
/// scope 命名与 LANSyncCategory 的 key 一致（favorites/sim/layouts/indicators），另有 main（主库替换通知）。
enum LANSyncReload {
    static func apply(scopes: [String]) {
        for scope in scopes {
            switch scope {
            case "favorites":
                FavoritesStore.shared.reloadFromDisk()          // LAN同步热重载
            case "sim":
                SimStore.shared.reloadFromDisk()                // LAN同步热重载
            case "layouts":
                PageLayoutConfigStore.shared.reloadFromDisk()   // LAN同步热重载
            case "indicators":
                // 指标公式目录镜像后重载全部周期定义（复用既有入口，与自定义指标增删改同款）
                SystemIndicatorStore.shared.reloadAllPeriods()
            case "main":
                // 主库整库替换不做热重载（SQLite 连接/内存缓存需重启重建）：
                // 只发通知，由 App 弹「主库已替换，请重启」提示
                NotificationCenter.default.post(name: .lansyncMainDBReplaced, object: nil)
            default:
                DebugLogger.shared.log("[LANSyncReload] 未知 scope: \(scope)")
            }
        }
        DebugLogger.shared.log("[LANSyncReload] applied scopes: \(scopes.joined(separator: ","))")
    }
}

// MARK: - 本机可同步内容清单

/// 扫描本地 Documents 生成 6 类可同步内容清单（GET /sync/status 的 items 段）。
/// key = LANSyncCategory.rawValue，文件条目字段与 LANSyncModels 契约一致。
enum LANSyncSupport {
    static func buildSyncInventory() -> [LANSyncItem] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return LANSyncCategory.allCases.map { category in
            LANSyncItem(key: category.rawValue, files: files(for: category, docs: docs))
        }
    }

    /// 单类的文件清单（该类文件均不存在时返回 []）
    private static func files(for category: LANSyncCategory, docs: URL) -> [LANSyncFileEntry] {
        switch category {
        case .favorites:
            return entries(docs: docs, rels: ["Favorites/favorites.json"])
        case .sim:
            return entries(docs: docs, rels: ["Simulation/sim.json"])
        case .layouts:
            return dirEntries(docs: docs, dir: "Layouts", ext: "json", recursive: false)
        case .indicators:
            // 指标公式三处目录（与 FormulaKind 的目录约定一致）：
            // indicator/<周期>/*.tdx、formula/picker/*.tdx、formula/strategy/*.tdx
            var out = dirEntries(docs: docs, dir: "indicator", ext: "tdx", recursive: true)
            out += dirEntries(docs: docs, dir: "formula/picker", ext: "tdx", recursive: false)
            out += dirEntries(docs: docs, dir: "formula/strategy", ext: "tdx", recursive: false)
            return out.sorted { $0.path < $1.path }
        case .live:
            return entries(docs: docs, rels: ["tdx_live.db", "tdx_live.manifest.json"])
        case .main:
            return entries(docs: docs, rels: ["tdx.db"])
        }
    }

    /// 若干精确相对路径 → 其中存在的文件条目
    private static func entries(docs: URL, rels: [String]) -> [LANSyncFileEntry] {
        rels.compactMap { entry(docs: docs, rel: $0) }
    }

    /// 单个文件条目（size/mtime 取文件属性；文件不存在返回 nil）
    private static func entry(docs: URL, rel: String) -> LANSyncFileEntry? {
        let full = docs.appendingPathComponent(rel).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: full),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mod = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        return LANSyncFileEntry(path: rel, size: size, mod: mod)
    }

    /// 目录下（可选递归）收集指定扩展名的文件条目；目录不存在返回 []
    private static func dirEntries(docs: URL, dir: String, ext: String, recursive: Bool) -> [LANSyncFileEntry] {
        let fm = FileManager.default
        let full = docs.appendingPathComponent(dir).path
        let names: [String]
        if recursive {
            // enumerator 返回相对 dir 的路径（如 "Day/MA.tdx"），拼回 Documents 相对路径
            guard let en = fm.enumerator(atPath: full) else { return [] }
            names = en.allObjects.compactMap { $0 as? String }
        } else {
            names = (try? fm.contentsOfDirectory(atPath: full)) ?? []
        }
        return names.filter { $0.hasSuffix(".\(ext)") }
            .map { dir + "/" + $0 }
            .compactMap { entry(docs: docs, rel: $0) }
            .sorted { $0.path < $1.path }
    }
}

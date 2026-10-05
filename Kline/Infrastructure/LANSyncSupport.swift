//
//  LANSyncSupport.swift
//  Kline
//
//  局域网设备联机同步 · 服务端支撑（KlineHTTPServer 的路由实现依赖本文件）：
//  1. LANSyncPairing —— 配对代理：对端请求配对时前台弹确认，同意后签发仅本会话有效的 token
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

/// 配对流程：
///   对端 POST /sync/request-pair → requestPair(from:items:) → pendingRequest 置位
///   （LANSyncView 监听此值弹确认框）→ 用户 approve()/deny()（或 60s 超时）
///   → 回调 completion(nil / token)；token 存入 sessionTokens，
///   后续 /sync/backup、/sync/reload-config 请求头 X-Kline-Pair 携带并由 isValidToken 校验。
/// KLINE_AUTOPAIR=1（UI 测试双模拟器联测）时跳过确认直接签发。
final class LANSyncPairing: ObservableObject {
    static let shared = LANSyncPairing()

    /// 前台待确认的配对请求（nil = 无挂起请求；LANSyncView 监听此值弹确认框）
    @Published var pendingRequest: PairRequest?

    /// 一次配对请求（id 供 SwiftUI 识别用）
    struct PairRequest: Identifiable {
        let id = UUID()
        let from: String
        let items: [String]
    }

    /// 挂起的 completion + 超时任务（approve/deny/超时三者谁先触发即清空）
    private var pendingCompletion: ((String?) -> Void)?
    private var pendingTimeout: DispatchWorkItem?

    /// 本会话有效 token 集合（进程存续期间有效）。
    /// 签发在主线程、校验在监听队列 → 读写均经 tokenLock 串行化。
    private(set) var sessionTokens: Set<String> = []
    private let tokenLock = NSLock()

    private init() {}

    // MARK: 请求配对（服务端路由调用，可能来自监听队列）

    /// 对端请求配对：主线程置 pendingRequest 弹确认；60s 无应答自动拒绝并回调 nil；
    /// KLINE_AUTOPAIR=1（UI 测试）时立即签发并回调 token，不弹确认。
    /// 同一时间只处理一个配对请求：已有挂起请求时后来者直接拒绝。
    func requestPair(from: String, items: [String], completion: @escaping (String?) -> Void) {
        // UI 测试专用：环境变量 KLINE_AUTOPAIR=1 跳过确认直接签发
        if ProcessInfo.processInfo.environment["KLINE_AUTOPAIR"] == "1" {
            DebugLogger.shared.log("[LANSyncPairing] autopair：直接签发 token（from=\(from)）")
            completion(issueToken())
            return
        }
        // 路由在监听队列执行，@Published 必须回主线程改（否则触发 Combine 运行时警告）
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { completion(nil); return }
            guard self.pendingRequest == nil else {
                DebugLogger.shared.log("[LANSyncPairing] 已有挂起请求，拒绝后来者 from=\(from)")
                completion(nil)
                return
            }
            self.pendingRequest = PairRequest(from: from, items: items)
            self.pendingCompletion = completion
            // 60s 无应答自动拒绝（approve/deny 时取消该任务）
            let timeout = DispatchWorkItem { [weak self] in
                self?.resolve(token: nil, reason: "60s 超时自动拒绝")
            }
            self.pendingTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
            DebugLogger.shared.log("[LANSyncPairing] 收到配对请求 from=\(from) items=\(items.joined(separator: ","))")
        }
    }

    // MARK: 用户应答（UI 在主线程调用）

    /// 同意配对：签发 UUID token 存入会话集合，并回调挂起的 completion
    func approve() {
        resolve(token: issueToken(), reason: "用户同意")
    }

    /// 拒绝配对：回调挂起的 completion(nil)
    func deny() {
        resolve(token: nil, reason: "用户拒绝")
    }

    // MARK: token 校验（服务端路由调用，来自监听队列）

    /// 会话 token 校验（/sync/backup、/sync/reload-config 请求头 X-Kline-Pair）
    func isValidToken(_ t: String) -> Bool {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        return sessionTokens.contains(t)
    }

    // MARK: 私有

    /// 结束当前挂起请求：清 pendingRequest、取消超时任务，并回调 completion（主线程）
    private func resolve(token: String?, reason: String) {
        guard let completion = pendingCompletion else { return }
        pendingCompletion = nil
        pendingTimeout?.cancel()
        pendingTimeout = nil
        pendingRequest = nil
        DebugLogger.shared.log("[LANSyncPairing] 配对结束（\(reason)）→ \(token == nil ? "拒绝" : "签发 token")")
        completion(token)
    }

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

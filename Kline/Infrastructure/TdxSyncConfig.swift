//
//  TdxSyncConfig.swift
//  Kline
//
//  增量行情库（Documents/tdx_live.db）自动拉取配置：UserDefaults 持久化。
//  与 ChartConfigStore / KlineThemeStore 同惯例：ObservableObject 单例，@Published 写入即持久化。
//
//  默认 **关闭**（enabled = false），需用户在「个人中心 → 本地更新 → 数据同步」显式开启。
//

import Foundation
import Combine

// MARK: - 数据源地址解析结果

/// 一个数据源解析出的两个完整地址（同一目录下的 db 与 manifest）
struct TdxSyncURLs {
    /// 用户填写的原始值（日志 / UI 展示用）
    var source: String
    /// tdx_live.db 完整地址
    var db: URL
    /// tdx_live.manifest.json 完整地址
    var manifest: URL
}

// MARK: - 配置

/// 同步配置（单例）
final class TdxSyncConfig: ObservableObject {
    static let shared = TdxSyncConfig()

    // MARK: - 默认值

    /// 默认数据源，按顺序尝试：
    /// ① 主源 `raw.githubusercontent.com`（data 分支，更新后立即生效）
    /// ② 备源 jsDelivr CDN（同分支镜像，主源被墙 / 超时兜底；注意 CDN 有缓存延迟）
    static let defaultSourceURLs: [String] = [
        "https://raw.githubusercontent.com/SunChuquin/Kline/data",
        "https://cdn.jsdelivr.net/gh/SunChuquin/Kline@data",
    ]

    /// 默认更新时刻（北京时间，交易日）：11:00 / 14:30 为盘中快照，15:05 为当日完整K线
    static let defaultScheduleTimes: [String] = ["11:00", "14:30", "15:05"]

    /// data 分支上的两个文件名
    static let dbFileName = "tdx_live.db"
    static let manifestFileName = "tdx_live.manifest.json"

    // MARK: - UserDefaults 键

    static let enabledKey = "kline.tdxsync.enabled"
    static let sourceURLsKey = "kline.tdxsync.sourceURLs"
    static let scheduleTimesKey = "kline.tdxsync.scheduleTimes"
    static let tradingDaysOnlyKey = "kline.tdxsync.tradingDaysOnly"
    static let checkIntervalKey = "kline.tdxsync.foregroundCheckInterval"

    // MARK: - 持久化项

    /// 是否启用自动拉取（默认 false：需用户显式开启）
    @Published var enabled: Bool = false {
        didSet { if enabled != oldValue { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) } }
    }

    /// 数据源地址列表（按顺序尝试，可增删改；写法见 `resolve(_:)`）
    @Published var sourceURLs: [String] = TdxSyncConfig.defaultSourceURLs {
        didSet { if sourceURLs != oldValue { Self.save(sourceURLs, key: Self.sourceURLsKey) } }
    }

    /// 更新时刻（"HH:mm"，24 小时制，可编辑）
    @Published var scheduleTimes: [String] = TdxSyncConfig.defaultScheduleTimes {
        didSet { if scheduleTimes != oldValue { Self.save(scheduleTimes, key: Self.scheduleTimesKey) } }
    }

    /// 仅在周一至周五（交易日）拉取
    @Published var tradingDaysOnly: Bool = true {
        didSet { if tradingDaysOnly != oldValue { UserDefaults.standard.set(tradingDaysOnly, forKey: Self.tradingDaysOnlyKey) } }
    }

    /// 前台轮询间隔（秒）：用于「到点触发」的检查频率
    @Published var foregroundCheckInterval: TimeInterval = 60 {
        didSet { if foregroundCheckInterval != oldValue { UserDefaults.standard.set(Double(foregroundCheckInterval), forKey: Self.checkIntervalKey) } }
    }

    private init() {
        let d = UserDefaults.standard
        // 注：init 内的赋值不会触发 didSet，因此不会反向写回 UserDefaults
        enabled = d.bool(forKey: Self.enabledKey)
        sourceURLs = Self.load([String].self, key: Self.sourceURLsKey) ?? Self.defaultSourceURLs
        scheduleTimes = Self.load([String].self, key: Self.scheduleTimesKey) ?? Self.defaultScheduleTimes
        tradingDaysOnly = (d.object(forKey: Self.tradingDaysOnlyKey) as? Bool) ?? true
        foregroundCheckInterval = (d.object(forKey: Self.checkIntervalKey) as? Double) ?? 60
    }

    // MARK: - 地址解析（base → db / manifest）

    /// 把用户填写的地址解析为 db / manifest 两个完整 URL。两种写法都支持：
    ///
    /// 1) **目录型 base**（不以 `.db` 结尾）：视为目录，分别拼接 `tdx_live.db` 与 `tdx_live.manifest.json`
    ///    - `https://raw.githubusercontent.com/SunChuquin/Kline/data`
    ///      → `…/data/tdx_live.db`、`…/data/tdx_live.manifest.json`
    ///    - `https://cdn.jsdelivr.net/gh/SunChuquin/Kline@data`
    ///      → `…/Kline@data/tdx_live.db`、`…/Kline@data/tdx_live.manifest.json`
    /// 2) **完整 db 地址**（以 `.db` 结尾）：db 用它本身，manifest 取同目录下的 `tdx_live.manifest.json`
    ///    - `…/data/tdx_live.db` → manifest `…/data/tdx_live.manifest.json`
    ///
    /// 末尾多余的 `/` 会被忽略；只接受 http / https，无法得到合法 URL 时返回 nil（该源跳过）。
    static func resolve(_ raw: String) -> TdxSyncURLs? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        guard !s.isEmpty else { return nil }

        let dbString: String
        let dirString: String
        if s.lowercased().hasSuffix(".db") {
            dbString = s
            dirString = directory(of: s)
        } else {
            dirString = s
            dbString = s + "/" + dbFileName
        }

        guard let dbURL = URL(string: dbString),
              let manifestURL = URL(string: dirString + "/" + manifestFileName),
              let scheme = dbURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              manifestURL.scheme?.lowercased() == scheme else { return nil }

        return TdxSyncURLs(source: raw, db: dbURL, manifest: manifestURL)
    }

    /// 取字符串最后一个 "/" 之前的目录部分
    private static func directory(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return path }
        return String(path[path.startIndex..<idx])
    }

    // MARK: - 可编辑文本 ⇄ 数组

    /// 源地址数组 → 单行可编辑文本（", " 分隔；URL 内不会出现逗号 / 空格）
    static func sourceText(_ urls: [String]) -> String {
        urls.joined(separator: ", ")
    }

    /// 可编辑文本 → 规范源地址数组：按逗号 / 分号 / 换行 / 空白拆分，去重、保持输入顺序，
    /// 只保留能解析出 http(s) 地址的项（非法项直接丢弃，避免写坏配置）
    static func parseSourceText(_ text: String) -> [String] {
        let parts = text.split(whereSeparator: { ",，;；\n\r\t ".contains($0) })
        var out: [String] = []
        for part in parts {
            var s = String(part).trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            while s.hasSuffix("/") { s = String(s.dropLast()) }
            guard resolve(s) != nil, !out.contains(s) else { continue }
            out.append(s)
        }
        return out
    }

    /// 时刻数组 → 可编辑文本（"11:00, 14:30, 15:05"）
    static func scheduleText(_ times: [String]) -> String {
        times.joined(separator: ", ")
    }

    /// 可编辑文本 → 规范时刻数组：按逗号 / 空格 / 换行拆分，仅保留合法 "HH:mm"，
    /// 统一补零为 "HH:mm"（保证字典序 = 时间序）、去重、升序
    static func parseScheduleText(_ text: String) -> [String] {
        let parts = text.split(whereSeparator: { ",，;；\n\r\t ".contains($0) })
        var out: [String] = []
        for part in parts {
            let segs = part.split(separator: ":")
            guard segs.count == 2,
                  let h = Int(segs[0]), let m = Int(segs[1]),
                  (0...23).contains(h), (0...59).contains(m) else { continue }
            let norm = String(format: "%02d:%02d", h, m)
            if !out.contains(norm) { out.append(norm) }
        }
        return out.sorted()
    }

    // MARK: - UserDefaults 读写工具

    private static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
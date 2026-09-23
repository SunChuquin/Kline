//
//  SearchHistoryStore.swift
//  Kline
//
//  本地搜索历史：搜索页「热门搜索」的数据源。
//  口径：记录用户**点开过**的标的，最近在前、按 meta.id 去重、最多 10 条；
//  持久化走 UserDefaults（key `kline.searchHistory`，与 kline.displayTheme 同惯例）。
//  无历史时的固定清单回落由搜索页自己决定，本 Store 不掺业务。
//

import Foundation
import Combine

// MARK: - 一条历史

/// 只存回显与再次检索所需的字段：`id` 用于去重，`name` 用于回填搜索框；
/// `code` / `type` 留作列表回显扩展，不参与逻辑。
struct SearchHistoryEntry: Codable, Equatable, Identifiable {
    let id: Int
    let name: String
    let code: String
    let type: String
}

// MARK: - Store

/// 本地搜索历史（单例 + ObservableObject）：与 `FavoritesStore` / `MarketConfigStore` 同惯例
/// —— **只在主线程读写**（调用方为搜索页，均在主线程），因此不加 actor 隔离。
final class SearchHistoryStore: ObservableObject {

    static let shared = SearchHistoryStore()

    /// 保留条数上限（超出丢最旧）
    static let maxCount = 10

    /// UserDefaults key（惯例：`kline.<域>`）
    private static let storageKey = "kline.searchHistory"

    /// 最近点开的标的，倒序（[0] 最新）
    @Published private(set) var entries: [SearchHistoryEntry] = []

    private let defaults = UserDefaults.standard

    init() {
        load()
    }

    // MARK: - 读写

    /// 记录一次点开：已存在则提到最前（去重），超出上限丢最旧
    func record(_ meta: MetaItem) {
        let entry = SearchHistoryEntry(id: meta.id, name: meta.name,
                                       code: meta.code, type: meta.type)
        if entries.first == entry { return }
        var next = entries
        next.removeAll { $0.id == meta.id }
        next.insert(entry, at: 0)
        if next.count > Self.maxCount {
            next = Array(next.prefix(Self.maxCount))
        }
        entries = next
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        guard let decoded = try? JSONDecoder().decode([SearchHistoryEntry].self, from: data) else {
            // 解码失败（版本/格式变化）：按空历史处理，不阻塞搜索页
            return
        }
        entries = Array(decoded.prefix(Self.maxCount))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
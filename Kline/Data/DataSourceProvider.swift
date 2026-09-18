//
//  DataSourceProvider.swift
//  Kline
//
//  数据源切换中心：在 SQLite（tdx.db）与二进制行情文件（bin）之间运行时切换。
//  切换时清空进程内数据/指标缓存、重建 meta 列表、按 file 主键重映射收藏，
//  无需重启 App。选择持久化在 UserDefaults（key: dataSourceMode）。
//
//  Created by 孙楚昆 on 2026/9/18.
//

import Foundation
import Combine

enum DataSourceMode: String, CaseIterable {
    case db = "db"
    case bin = "bin"

    var displayName: String {
        switch self {
        case .db: return "数据库 (tdx.db)"
        case .bin: return "行情文件 (bin)"
        }
    }

    var shortName: String {
        self == .db ? "DB" : "Bin"
    }
}

final class DataSourceProvider: ObservableObject {

    static let shared = DataSourceProvider()

    @Published private(set) var mode: DataSourceMode

    private let defaults = UserDefaults.standard
    private let defaultsKey = "dataSourceMode"

    private init() {
        let raw = defaults.string(forKey: defaultsKey) ?? DataSourceMode.db.rawValue
        mode = DataSourceMode(rawValue: raw) ?? .db
    }

    /// 切换数据源：清缓存 → 后台重建 meta 列表 → 主线程发布并重映射收藏
    func setMode(_ newMode: DataSourceMode) {
        guard newMode != mode else { return }
        let oldMeta = DatabaseManager.shared.metaList
        mode = newMode
        defaults.set(newMode.rawValue, forKey: defaultsKey)
        // 先清进程内缓存：指标曲线缓存与 bin 数据缓存
        ChartCacheStore.shared.clearAll()
        BinDataStore.shared.resetCaches()
        // 重建 meta 列表（bin 索引扫描 / SQLite 载入都在后台做，避免主线程 IO）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let newMeta = DatabaseManager.shared.rebuildMetaListSync()
            DispatchQueue.main.async {
                DatabaseManager.shared.publishMetaList(newMeta)
                Task { @MainActor in
                    FavoritesStore.shared.remapMetaIDs(from: oldMeta, to: newMeta)
                }
            }
        }
    }
}
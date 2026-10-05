//
//  LANSyncModels.swift
//  Kline
//
//  局域网设备联机同步：共享契约模型（wire format）。
//  该文件是 KlineHTTPServer（产出 JSON）与 LANSyncDiscovery / LANSyncTransfer
//  （解析 JSON）之间的共享契约，字段名即线上格式，改动需两端同步。
//

import Foundation

// MARK: - 同步内容分类（6 类）

/// 联机同步的 6 类内容；rawValue 同时作为 /sync/status JSON 里 items[].key
enum LANSyncCategory: String, CaseIterable, Identifiable {
    case favorites   // 自选 Documents/Favorites/favorites.json
    case sim         // 模拟交易 Documents/Simulation/sim.json
    case layouts     // 页面布局 Documents/Layouts/*.json
    case indicators  // 指标公式 indicator/<周期>/*.tdx + formula/picker/*.tdx + formula/strategy/*.tdx
    case live        // 增量库 tdx_live.db(+manifest)
    case main        // 主库 tdx.db

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: return "自选"
        case .sim: return "模拟交易"
        case .layouts: return "页面布局"
        case .indicators: return "指标公式"
        case .live: return "增量库"
        case .main: return "主库"
        }
    }

    var subtitle: String {
        switch self {
        case .favorites: return "Documents/Favorites/favorites.json"
        case .sim: return "Documents/Simulation/sim.json"
        case .layouts: return "Documents/Layouts/*.json"
        case .indicators: return "indicator/ + formula/picker/ + formula/strategy/ (*.tdx)"
        case .live: return "Documents/tdx_live.db (+manifest)"
        case .main: return "Documents/tdx.db（替换后需重启 App 生效）"
        }
    }

    /// 是否整目录镜像语义（备份 → 清空对端 → 写入全部文件）
    var isDirectoryMirror: Bool { self == .indicators }

    /// 同步完成后是否需要热重载配置 / 指标
    var needsConfigReload: Bool {
        switch self {
        case .favorites, .sim, .layouts, .indicators: return true
        case .live, .main: return false
        }
    }
}

// MARK: - 文件清单条目

/// 单个可同步文件（path 为 Documents 相对路径，如 "Favorites/favorites.json"）
struct LANSyncFileEntry: Codable, Equatable {
    let path: String
    let size: Int64
    let mod: TimeInterval
}

/// 一个类别的清单（files 可为空 = 该设备没有此类内容）
struct LANSyncItem: Codable, Equatable {
    let key: String
    let files: [LANSyncFileEntry]

    var category: LANSyncCategory? { LANSyncCategory(rawValue: key) }
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

// MARK: - 对端状态（GET /sync/status 扩展段）

/// 对端设备信息与 6 类内容清单
struct LANSyncPeerStatus: Codable, Equatable {
    struct Device: Codable, Equatable {
        let name: String
        let appVersion: String
        let app: String
    }
    let device: Device
    let items: [LANSyncItem]

    func item(_ category: LANSyncCategory) -> LANSyncItem? {
        items.first { $0.key == category.rawValue }
    }
}

// MARK: - 发现的对端设备

/// 发现到的对端设备（Bonjour 或手动 IP）
struct LANSyncPeer: Identifiable, Equatable {
    /// 稳定标识："host:port" 或 Bonjour 服务名
    let id: String
    let name: String
    let host: String
    let port: UInt16
}

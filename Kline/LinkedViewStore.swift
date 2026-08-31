//
//  LinkedViewStore.swift
//  Kline
//
//  联动视图配置（按标的持久记忆）：
//  保存「打开某标的时，联动视图的数量、以及每个视图各自的(标的,周期)」，
//  落地到沙盒 Documents/LinkedViews.json。首次使用某标的无记录时，
//  默认 2 个视图：左视图=当前标的·日线，右视图=当前标的·周线。
//
//  Created by 孙楚昆 on 2026/8/31.
//

import Foundation
import SwiftUI

/// 联动视图数量（2 / 3 / 4）
enum LinkedViewCount: Int, CaseIterable, Identifiable, Codable {
    case two = 2
    case three = 3
    case four = 4

    var id: Int { rawValue }

    var label: String { "\(rawValue) 个视图" }
}

/// 单个联动视图的配置：该视图显示的 (标的, 周期)。每视图可独立选择。
struct LinkedViewConfig: Codable, Identifiable, Hashable {
    /// 视图下标（0-based），用于稳定标识
    var index: Int
    var metaID: Int
    var name: String
    var code: String
    var type: String
    var period: KlinePeriod

    var id: Int { index }

    /// 便捷展示代码（与 MetaItem.displayCode 一致）
    var displayCode: String {
        code.replacingOccurrences(of: "SH", with: "").replacingOccurrences(of: "SZ", with: "")
    }
}

/// 按「当前打开的主标的 metaID」记忆该标的的联动视图配置
final class LinkedViewStore: ObservableObject {
    static let shared = LinkedViewStore()

    /// key = 打开的主标的 metaID；value = 该标的的联动视图配置数组
    @Published private(set) var configs: [Int: [LinkedViewConfig]] = [:]

    private let fm = FileManager.default

    /// 关联到某个主标的的联动视图配置文件（沙盒 Documents/LinkedViews.json）
    private var fileURL: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("LinkedViews.json")
    }

    private init() {
        loadFromDisk()
    }

    // MARK: - 读取 / 写入

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Int: [LinkedViewConfig]].self, from: data) else {
            configs = [:]
            return
        }
        configs = decoded
    }

    private func saveToDisk() {
        if let data = try? JSONEncoder().encode(configs) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 取某主标的当前的联动视图配置。无记录时创建默认：2 个视图（日线/周线，标的=该主标的），并立即落盘。
    func configs(for metaID: Int) -> [LinkedViewConfig] {
        if let existing = configs[metaID], !existing.isEmpty { return existing }
        let name = currentName(for: metaID)
        let def: [LinkedViewConfig] = [
            LinkedViewConfig(index: 0, metaID: metaID, name: name.0, code: name.1, type: name.2, period: .daily),
            LinkedViewConfig(index: 1, metaID: metaID, name: name.0, code: name.1, type: name.2, period: .weekly),
        ]
        configs[metaID] = def
        saveToDisk()
        return def
    }

    /// 覆盖保存某主标的的联动视图配置（保留 tail 与关节/替换都传完整数组）。
    func setConfigs(_ views: [LinkedViewConfig], for metaID: Int) {
        configs[metaID] = views
        saveToDisk()
    }

    /// 更新某主标的的第 index 个视图配置
    func updateView(_ view: LinkedViewConfig, for metaID: Int) {
        var cur = configs(for: metaID)
        if view.index < cur.count {
            cur[view.index] = view
        } else {
            cur.append(view)
        }
        configs[metaID] = cur
        saveToDisk()
    }

    /// 清空某主标的的联动视图配置（重置：恢复默认 2 视图）
    func reset(for metaID: Int) {
        configs[metaID] = nil
        _ = configs(for: metaID)   // 触发默认重建并落盘
    }

    /// 删除一个视图（数量 2→1 时保留最小为 2，因最少 2 个视图）
    func removeView(at index: Int, for metaID: Int) {
        var cur = configs(for: metaID)
        guard index < cur.count, cur.count > 2 else { return }
        cur.remove(at: index)
        // 重排 index
        for i in cur.indices { cur[i].index = i }
        configs[metaID] = cur
        saveToDisk()
    }

    /// 数量控制：把某主标的强制为指定视图数量（不足补默认、多余裁剪）
    func setViewCount(_ count: LinkedViewCount, for metaID: Int) {
        var cur = configs(for: metaID)
        if cur.count < count.rawValue {
            // 补到目标数量的默认视图（后面补齐的用未占用周期）
            let periods = KlinePeriod.allCases
            while cur.count < count.rawValue {
                let idx = cur.count
                let p = periods.indices.contains(idx) ? periods[idx] : .daily
                let name = displayInfo(of: cur.first)
                cur.append(LinkedViewConfig(index: idx, metaID: metaID, name: name.0, code: name.1, type: name.2, period: p))
            }
        } else if cur.count > count.rawValue {
            // 裁剪到目标数量（保留前面的）
            cur = Array(cur.prefix(count.rawValue))
        }
        // 重排 index，保证连续性
        for i in cur.indices { cur[i].index = i }
        configs[metaID] = cur
        saveToDisk()
    }

    // MARK: - 辅助

    /// 当前视图的标的是否可以在候选列表里按 dir 切换到上/下一个标的
    func canSwitchItem(current view: LinkedViewConfig, dir: Int) -> Bool {
        let candidates = DetailRouter.shared.navItems
        guard let cur = candidates.firstIndex(where: { $0.id == view.metaID }) else { return false }
        let t = cur + dir
        return t >= 0 && t < candidates.count
    }

    private func currentName(for metaID: Int) -> (String, String, String) {
        // 优先用配置里已有的名称兜底（避免跨标的命名错误）
        if let cur = configs[metaID], let first = cur.first {
            return (first.name, first.code, first.type)
        }
        return ("", "", "")
    }

    private func displayInfo(of view: LinkedViewConfig?) -> (String, String, String) {
        guard let view else { return ("", "", "") }
        return (view.name, view.code, view.type)
    }
}
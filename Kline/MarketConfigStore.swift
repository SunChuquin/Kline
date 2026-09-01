//
//  MarketConfigStore.swift
//  Kline
//
//  Created by AI on 2026/09/01.
//
//  行情/自选页面表单的展示配置（字段显隐、列顺序、列宽、排序规则）。
//  按"页面ID"维度独立保存（行情Tab、自选Tab各自一份；自选Tab不同分组可共享）。
//  持久化到 Documents/Market/market_columns.json
//

import Foundation
import SwiftUI
import Combine

/// 可独立配置表头的页面 ID（不同页面不共用）
enum MarketConfigPage: String, Codable, CaseIterable {
    case marketBoard    // 行情页面（沪深主板/指数）
    case favorites      // 自选页面
}

/// 单列配置
struct MarketColumnPref: Codable, Hashable, Identifiable {
    var field: MarketField
    var visible: Bool
    /// 若用户手动拖改过列宽，则覆盖默认宽度；nil 表示使用 defaultWidth
    var widthOverride: CGFloat?
    var id: String { field.rawValue }
}

/// 某页面的完整配置
struct MarketPageConfig: Codable {
    /// 当前列顺序（含所有字段，显隐一起保存，避免新增字段时丢失）
    var columns: [MarketColumnPref]
    /// 当前排序规则（可选；nil 表示默认顺序，即列表源顺序）
    var sortRule: MarketSortRule?
}

@MainActor
final class MarketConfigStore: ObservableObject {
    static let shared = MarketConfigStore()

    @Published private var configs: [MarketConfigPage: MarketPageConfig] = [:]

    private let fm = FileManager.default

    private init() {
        if !loadFromDisk() {
            // 首次启动：为每个页面写默认值
            resetAll()
        }
    }

    // MARK: - 持久化

    private var fileURL: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Market", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("market_columns.json")
    }

    private func loadFromDisk() -> Bool {
        let url = fileURL
        guard fm.fileExists(atPath: url.path) else { return false }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let box = try decoder.decode([String: MarketPageConfig].self, from: data)
            var out: [MarketConfigPage: MarketPageConfig] = [:]
            for (k, v) in box {
                if let p = MarketConfigPage(rawValue: k) { out[p] = v }
            }
            configs = out
            return !configs.isEmpty
        } catch {
            DebugLogger.shared.log("[MarketConfigStore] load failed \(error)")
            return false
        }
    }

    private func saveToDisk() {
        var box: [String: MarketPageConfig] = [:]
        for (k, v) in configs { box[k.rawValue] = v }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(box)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DebugLogger.shared.log("[MarketConfigStore] save failed \(error)")
        }
    }

    // MARK: - 读配置

    func config(for page: MarketConfigPage) -> MarketPageConfig {
        if let c = configs[page] { return c }
        let d = Self.defaultConfig()
        configs[page] = d
        saveToDisk()
        return d
    }

    /// 返回可见列数组（按配置顺序过滤），保证字段顺序与用户设置一致
    func visibleColumns(for page: MarketConfigPage) -> [MarketColumnPref] {
        let c = config(for: page)
        return c.columns.filter { $0.visible }
    }

    func sortRule(for page: MarketConfigPage) -> MarketSortRule? {
        config(for: page).sortRule
    }

    func width(for field: MarketField, page: MarketConfigPage) -> CGFloat {
        let c = config(for: page)
        if let col = c.columns.first(where: { $0.field == field }) {
            return col.widthOverride ?? field.defaultWidth
        }
        return field.defaultWidth
    }

    // MARK: - 写配置

    /// 更新整个页面配置（列显隐/顺序/宽度 / 排序一次全存）
    func update(_ page: MarketConfigPage, config: MarketPageConfig) {
        configs[page] = config
        saveToDisk()
    }

    /// 设置单列显隐
    func setVisible(_ field: MarketField, visible: Bool, page: MarketConfigPage) {
        var c = self.config(for: page)
        if let idx = c.columns.firstIndex(where: { $0.field == field }) {
            c.columns[idx].visible = visible
        }
        update(page, config: c)
    }

    /// 列排序：用户在"编辑表头"里上下移动（调整 columns 数组顺序）
    func moveColumns(page: MarketConfigPage, fromOffsets: IndexSet, toOffset: Int) {
        var c = self.config(for: page)
        c.columns.move(fromOffsets: fromOffsets, toOffset: toOffset)
        update(page, config: c)
    }

    /// 覆盖列宽
    func setWidthOverride(_ field: MarketField, width: CGFloat?, page: MarketConfigPage) {
        var c = self.config(for: page)
        if let idx = c.columns.firstIndex(where: { $0.field == field }) {
            c.columns[idx].widthOverride = width
        }
        update(page, config: c)
    }

    /// 设置排序规则（点击表头切换：同字段循环 asc/desc/nil；其他字段切 desc 起）
    func toggleSort(field: MarketField, page: MarketConfigPage) {
        var c = self.config(for: page)
        if let r = c.sortRule, r.field == field {
            switch r.order {
            case .descending: c.sortRule = MarketSortRule(field: field, order: .ascending)
            case .ascending:  c.sortRule = nil   // 第 3 击 = 取消排序，恢复列表原生顺序
            }
        } else {
            c.sortRule = MarketSortRule(field: field, order: .descending)
        }
        update(page, config: c)
    }

    /// 重置单页（点击"恢复默认")
    func reset(page: MarketConfigPage) {
        configs[page] = Self.defaultConfig()
        saveToDisk()
    }

    /// 重写全部（首次启动 or 全部重置）
    func resetAll() {
        for p in MarketConfigPage.allCases {
            configs[p] = Self.defaultConfig()
        }
        saveToDisk()
    }

    // MARK: - 默认值

    static func defaultConfig() -> MarketPageConfig {
        let defaultsVisible: [MarketField] = MarketField.defaultsVisible
        var cols: [MarketColumnPref] = []
        // 先按 defaultsVisible 顺序
        for f in defaultsVisible {
            cols.append(MarketColumnPref(field: f, visible: true, widthOverride: nil))
        }
        // 其他字段默认隐藏，接在后面
        for f in MarketField.allCases where !defaultsVisible.contains(f) {
            cols.append(MarketColumnPref(field: f, visible: false, widthOverride: nil))
        }
        return MarketPageConfig(columns: cols, sortRule: nil)
    }
}

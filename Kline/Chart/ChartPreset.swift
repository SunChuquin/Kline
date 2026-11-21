//
//  ChartPreset.swift
//  Kline
//
//  指标组合模型：五套全局默认组合的按周期配置快照（主图启用集合 / 主图自定义 / 三副图选择）。
//  组合粒度=仅启用集合：指标参数（MA 周期参数等）保持全局（SystemIndicatorStore），不随组合切换。
//  与「局部独立配置」（ChartConfigStore 的按周期记忆，现补落盘）同构，切换全局生效。
//

import Foundation

/// 一套指标组合：按周期记录主图/副图的启用集合（不含参数）。
/// 落盘口径：Set→排序数组（保证 JSON 稳定）、KlinePeriod 用 rawValue（中文）作字典 key、
/// 自定义指标存 uuidString（缺 key = 该周期无激活的自定义主图）。
struct ChartPreset: Codable, Equatable, Identifiable {
    /// 固定槽位 id："p1"…"p5"
    let id: String
    /// 展示名（下拉菜单 label，可重命名）
    var name: String
    /// period.rawValue → 主图启用指标 id 集合（缺 key = 回退默认 ["MA","CMK"]）
    var mainIndicatorsByPeriod: [String: [String]]
    /// period.rawValue → 主图自定义指标 uuidString（缺 key = 无）
    var activeCustomByPeriod: [String: String]
    /// period.rawValue → 三副图选择（缺 key 或数量≠3 = 回退默认 CDJ/COL/MACD）
    var subSelectionsByPeriod: [String: [SubChartSelection]]

    /// 默认槽（新建组合时的初始值：全空字典，读取侧缺槽回退默认集合）
    static func empty(id: String, name: String) -> ChartPreset {
        ChartPreset(id: id, name: name,
                    mainIndicatorsByPeriod: [:],
                    activeCustomByPeriod: [:],
                    subSelectionsByPeriod: [:])
    }

    /// 读取某周期的主图启用集合（缺槽回退默认）
    func mainIndicators(for period: KlinePeriod) -> Set<String> {
        if let arr = mainIndicatorsByPeriod[period.rawValue] { return Set(arr) }
        return ["MA", "CMK"]
    }

    /// 读取某周期的主图自定义指标 id（缺 key = nil）
    func activeCustomID(for period: KlinePeriod) -> UUID? {
        activeCustomByPeriod[period.rawValue].flatMap(UUID.init(uuidString:))
    }

    /// 读取某周期的三副图选择（缺槽/数量≠3 回退默认 CDJ/COL/MACD）
    func subSelections(for period: KlinePeriod) -> [SubChartSelection] {
        if let sels = subSelectionsByPeriod[period.rawValue], sels.count == 3 { return sels }
        return [
            SubChartSelection(kind: "CDJ", customID: nil),
            SubChartSelection(kind: "COL", customID: nil),
            SubChartSelection(kind: "MACD", customID: nil),
        ]
    }
}

/// 固定 5 槽 id（协议口径：preset.snapshot 的 presets 顺序与此一致）
enum ChartPresetSlots {
    static let ids = ["p1", "p2", "p3", "p4", "p5"]

    /// 默认槽名（首次初始化用；用户可在编辑页重命名后覆盖）
    static func defaultName(_ id: String) -> String {
        let index = ids.firstIndex(of: id).map { $0 + 1 } ?? 0
        return "组合\(index)"
    }
}

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
import Combine

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

/// Tile 数据的全局缓存键（进程内共享）。
/// 负责把「某 owner 下第 N 格视图的 (metaID, period) 查询结果」挂到共享存储上，
/// 不再依赖单个 LinkedKlineTile 实例的 @State。当 SwiftUI 因 .id 变化销毁旧 tile、
/// 创建新 tile 时，新实例 onAppear 能直接拿到旧实例写入的正确结果，彻底避免
/// 「旧实例 self.view 仍是旧快照 → 视图上下文漂移守卫误丢正确数据 → 新实例再查
/// 但被 Xcode 旧 onChange 缓存的旧周期 loadData 反向覆盖」的竞态链。
struct LinkedTileDataKey: Hashable {
    let ownerMetaID: Int
    let tileIndex: Int
}

/// 单格视图的共享 series 缓存 + 在途查询登记
final class LinkedTileDataSlot {
    /// 已成功写入的最新 series（nil 也表示明确"该视图无数据"）
    var series: ChartSeries?
    /// 最后一次成功写入时的目标 (metaID, period) —— 命中则 onAppear 直接复用，不再查 DB
    var loadedMetaID: Int?
    var loadedPeriod: KlinePeriod?
    /// 是否正在加载中（用于 isLoading 显示占位圈）
    var isLoading: Bool = true
    /// 在途查询目标：若命中则 onAppear 不重复发起 DB 查询
    var inFlightMetaID: Int?
    var inFlightPeriod: KlinePeriod?
    /// 在途查询发起时间（DebugLogger 诊断用）
    var inFlightStart: Date?
}

/// 按「当前打开的主标的 metaID」记忆该标的的联动视图配置
final class LinkedViewStore: ObservableObject {
    static let shared = LinkedViewStore()

    /// key = 打开的主标的 metaID；value = 该标的的联动视图配置数组
    @Published private(set) var configs: [Int: [LinkedViewConfig]] = [:]

    /// 进程内全局的 tile 数据槽。key = (ownerMetaID, tileIndex)。
    /// series/isLoading/inFlight 都挂在这，彻底解耦单个 SwiftUI tile 实例的生命周期。
    /// @Published 保证写入 series 时所有读到这个槽的 View 重新渲染。
    @Published private(set) var tileData: [LinkedTileDataKey: LinkedTileDataSlot] = [:]

    private let fm = FileManager.default

    // MARK: - 共享数据槽读写（线程安全：只在主线程访问）

    /// 获取/创建某格的数据槽（永远非空）。必须在主线程调用。
    func slot(ownerMetaID: Int, tileIndex: Int) -> LinkedTileDataSlot {
        let key = LinkedTileDataKey(ownerMetaID: ownerMetaID, tileIndex: tileIndex)
        if let exist = tileData[key] { return exist }
        let s = LinkedTileDataSlot()
        tileData[key] = s
        return s
    }

    /// 把某格 series 成功写入槽（同步更新 loadedMetaID/loadedPeriod，清在途标记，触发 UI 刷新）
    func commitSlot(ownerMetaID: Int, tileIndex: Int,
                    metaID: Int, period: KlinePeriod,
                    series: ChartSeries?,
                    isLoading: Bool = false) {
        let s = slot(ownerMetaID: ownerMetaID, tileIndex: tileIndex)
        s.series = series
        s.loadedMetaID = metaID
        s.loadedPeriod = period
        s.isLoading = isLoading
        // 清在途（仅当在途仍是本次提交的目标时才清，避免快速切两次时后发的 inFlight 被误清）
        if s.inFlightMetaID == metaID, s.inFlightPeriod == period {
            s.inFlightMetaID = nil
            s.inFlightPeriod = nil
            s.inFlightStart = nil
        }
        // objectWillChange 手动触发（值类型 class 引用属性变化 SwiftUI 不自动 fire）
        objectWillChange.send()
    }

    /// 登记在途查询（返回 true = 本次由调用方负责查询；返回 false = 已有相同目标在途，跳过重复查）
    @discardableResult
    func tryBeginFlight(ownerMetaID: Int, tileIndex: Int,
                        metaID: Int, period: KlinePeriod) -> Bool {
        let s = slot(ownerMetaID: ownerMetaID, tileIndex: tileIndex)
        if s.inFlightMetaID == metaID, s.inFlightPeriod == period {
            return false  // 同目标已经在飞，跳过
        }
        s.inFlightMetaID = metaID
        s.inFlightPeriod = period
        s.inFlightStart = Date()
        s.isLoading = true
        objectWillChange.send()
        return true
    }

    /// 强行置某格为"加载中+清空旧 series"（用于切周期/切标入口，保证视觉立即反馈）
    func markLoading(ownerMetaID: Int, tileIndex: Int) {
        let s = slot(ownerMetaID: ownerMetaID, tileIndex: tileIndex)
        // 保留已登记的 inFlight（若有），只把 isLoading 翻为 true、series 不提前清空
        // （原因：若 series 在此被置 nil，在途成功结果写入前的几十毫秒会有白屏闪烁）
        s.isLoading = true
        objectWillChange.send()
    }

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
    ///
    /// ⚠️ 返回值**强制按 LinkedViewConfig.index 升序排序**。这是消除「信息栏按数组 offset 渲染、
    /// 图表 ForEach 按 element.index 保持 identity」之间错位的根本措施：一旦 JSON 读写或
    /// append/remove 操作导致数组内顺序漂移，信息栏显示的（按 offset 取）周期/代码就会和
    /// 真实渲染的 chartSeries（按 identity 匹配到的旧 @State 缓存）对不上，表现为"日线
    /// 标签实际显示周线数据，但 DB 数据本身没错"。统一 index 排序后，数组 offset 恒等
    /// 于 element.index，信息栏与图表永远一一对应。
    ///
    /// - Parameters:
    ///   - metaID: 主标的 ID
    ///   - nameHint: 主标的 (name, code, type) 信息，由调用方（当前详情页/当前 tile 视图）传入；
    ///     用于首次初始化时填充默认视图，以及**修复旧版遗留空数据**（旧版 currentName 有自引用 bug，
    ///     生成的默认视图 name/code/type 全空，导致信息栏代码永远不显示）
    func configs(for metaID: Int,
                 nameHint: (name: String, code: String, type: String)? = nil) -> [LinkedViewConfig] {
        if var existing = configs[metaID], !existing.isEmpty {
            // 旧数据补丁：任意元素 name/code 为空时用 hint 补齐，并立即回写磁盘
            if let hint = nameHint, existing.contains(where: { $0.name.isEmpty || $0.code.isEmpty || $0.type.isEmpty }) {
                for i in existing.indices {
                    if existing[i].name.isEmpty { existing[i].name = hint.name }
                    if existing[i].code.isEmpty { existing[i].code = hint.code }
                    if existing[i].type.isEmpty { existing[i].type = hint.type }
                }
                existing.sort { $0.index < $1.index }
                configs[metaID] = existing
                saveToDisk()
                return existing
            }
            existing.sort { $0.index < $1.index }
            return existing
        }
        let n = nameHint ?? currentName(for: metaID)
        let def: [LinkedViewConfig] = [
            LinkedViewConfig(index: 0, metaID: metaID, name: n.0, code: n.1, type: n.2, period: .daily),
            LinkedViewConfig(index: 1, metaID: metaID, name: n.0, code: n.1, type: n.2, period: .weekly),
        ]
        configs[metaID] = def
        saveToDisk()
        return def
    }

    /// 覆盖保存某主标的的联动视图配置（保留 tail 与关节/替换都传完整数组）。
    /// 保存前强制按 element.index 升序排序，保证落盘 JSON 顺序与渲染顺序一致。
    func setConfigs(_ views: [LinkedViewConfig], for metaID: Int) {
        let sorted = views.sorted { $0.index < $1.index }
        configs[metaID] = sorted
        saveToDisk()
    }

    /// 更新某主标的的第 index 个视图配置（按元素 index 字段匹配位置，不信任数组下标顺序）
    func updateView(_ view: LinkedViewConfig, for metaID: Int) {
        var cur = configs(for: metaID)
        if let matchIdx = cur.firstIndex(where: { $0.index == view.index }) {
            cur[matchIdx] = view
        } else {
            cur.append(view)
        }
        cur.sort { $0.index < $1.index }
        configs[metaID] = cur
        saveToDisk()
    }

    /// 清空某主标的的联动视图配置（重置：恢复默认 2 视图）
    func reset(for metaID: Int,
               nameHint: (name: String, code: String, type: String)? = nil) {
        configs[metaID] = nil
        _ = configs(for: metaID, nameHint: nameHint)   // 触发默认重建并落盘
    }

    /// 删除一个视图（数量 2→1 时保留最小为 2，因最少 2 个视图）
    func removeView(at index: Int, for metaID: Int,
                    nameHint: (name: String, code: String, type: String)? = nil) {
        var cur = configs(for: metaID, nameHint: nameHint)
        cur.sort { $0.index < $1.index }
        guard index < cur.count, cur.count > 2 else { return }
        cur.remove(at: index)
        // 重排 index
        for i in cur.indices { cur[i].index = i }
        configs[metaID] = cur
        saveToDisk()
    }

    /// 数量控制：把某主标的强制为指定视图数量（不足补默认、多余裁剪）。
    /// 新增视图继承 nameHint（优先）或 cur.first（次优先）的 name/code/type，保证新视图代码非空
    func setViewCount(_ count: LinkedViewCount, for metaID: Int,
                      nameHint: (name: String, code: String, type: String)? = nil) {
        var cur = configs(for: metaID, nameHint: nameHint)
        cur.sort { $0.index < $1.index }
        if cur.count < count.rawValue {
            // 补到目标数量的默认视图（后面补齐的用未占用周期）
            let periods = KlinePeriod.allCases
            while cur.count < count.rawValue {
                let idx = cur.count
                let p = periods.indices.contains(idx) ? periods[idx] : .daily
                let name = nameHint.map { ($0.name, $0.code, $0.type) } ?? displayInfo(of: cur.first)
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
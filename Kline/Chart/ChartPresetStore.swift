//
//  ChartPresetStore.swift
//  Kline
//
//  指标组合仓库：五套全局默认组合（固定槽）+ 当前生效模式（局部独立 / 某组合）。
//  UserDefaults JSON 持久化（跨启动保留）；内容/模式变化通过 bump ChartConfigStore 的
//  configModeRevision 通知图表 force 重算（指纹已含 mode，缓存自动失效）。
//
//  与 ChartConfigStore 的分工：本仓库只管「组合数据」；读取 resolver 与写路径分流在
//  ChartConfigStore（调用方零改动）——preset 模式下的指标开关/副图选择就地改写组合本体
//  （「生效中即编辑」语义，与局部独立模式行为对齐）。
//

import Foundation
import Combine

@MainActor
final class ChartPresetStore: ObservableObject {
    static let shared = ChartPresetStore()

    static let localMode = "local"
    static let presetsKey = "kline.chart.presets.v1"
    static let activeModeKey = "kline.chart.activeMode"

    /// 五套全局组合（固定槽，顺序 = 下拉菜单顺序）
    @Published private(set) var presets: [ChartPreset]
    /// 当前生效模式："local"（局部独立配置）或 "p1"…"p5"
    @Published private(set) var activeMode: String

    /// 生成引擎临时覆盖：非 nil 时 resolver/指纹按该组合解析（仅主线程组装段置位，
    /// await 挂起期间已退出——UI 渲染不会读到覆盖值）
    private(set) var resolverOverride: String? = nil

    /// resolver 生效模式（override 优先）
    var effectiveMode: String { resolverOverride ?? activeMode }

    /// 在覆盖上下文中执行（同步闭包；resolver 临时按指定组合解析）
    func withResolverOverride<T>(_ mode: String, _ body: () -> T) -> T {
        resolverOverride = mode
        defer { resolverOverride = nil }
        return body()
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.presetsKey),
           let decoded = try? JSONDecoder().decode([ChartPreset].self, from: data),
           decoded.count == ChartPresetSlots.ids.count {
            presets = decoded
        } else {
            presets = ChartPresetSlots.ids.map { ChartPreset.empty(id: $0, name: ChartPresetSlots.defaultName($0)) }
        }
        let mode = UserDefaults.standard.string(forKey: Self.activeModeKey) ?? Self.localMode
        // 兜底：落盘 mode 必须是合法槽位（组合 id 不会变，防脏数据）
        activeMode = (mode == Self.localMode || ChartPresetSlots.ids.contains(mode)) ? mode : Self.localMode
    }

    // MARK: - 查询

    var isLocalMode: Bool { activeMode == Self.localMode }

    /// 当前生效的组合（local 模式返回 nil）
    var activePreset: ChartPreset? {
        guard !isLocalMode else { return nil }
        return presets.first { $0.id == activeMode }
    }

    /// resolver 生效组合（override 优先；ChartConfigStore.activePreset 走这里）
    var effectivePreset: ChartPreset? {
        let mode = effectiveMode
        guard mode != Self.localMode else { return nil }
        return presets.first { $0.id == mode }
    }

    func preset(id: String) -> ChartPreset? {
        presets.first { $0.id == id }
    }

    // MARK: - 模式切换（K 线设置面板下拉）

    /// 切换生效模式并通知图表重算（写 UserDefaults + bump revision → 指纹变化 → 缓存失效重算）
    func setActiveMode(_ mode: String) {
        guard mode == Self.localMode || preset(id: mode) != nil else { return }
        guard mode != activeMode else { return }
        activeMode = mode
        UserDefaults.standard.set(mode, forKey: Self.activeModeKey)
        ChartConfigStore.shared.bumpConfigModeRevision()
        DebugLogger.shared.log("[ChartPreset] 生效组合 → \(mode)")
    }

    // MARK: - 组合内容写路径（preset 模式下指标面板/设置面板的就地编辑）

    /// 主图指标开关（就地改写生效中组合）
    func toggleMain(_ id: String, period: KlinePeriod) {
        guard var preset = activePreset else { return }
        var cur = preset.mainIndicators(for: period)
        if cur.contains(id) { cur.remove(id) } else { cur.insert(id) }
        preset.mainIndicatorsByPeriod[period.rawValue] = cur.sorted()
        commit(preset)
    }

    /// 主图自定义指标激活（就地改写生效中组合）
    func setActiveCustom(_ id: UUID?, period: KlinePeriod) {
        guard var preset = activePreset else { return }
        if let id {
            preset.activeCustomByPeriod[period.rawValue] = id.uuidString
        } else {
            preset.activeCustomByPeriod.removeValue(forKey: period.rawValue)
        }
        commit(preset)
    }

    /// 三副图选择记录（就地改写生效中组合；sels 由 ChartConfigStore 从共享模型组装）
    func recordSubSelections(_ sels: [SubChartSelection], period: KlinePeriod) {
        guard sels.count == 3, var preset = activePreset else { return }
        preset.subSelectionsByPeriod[period.rawValue] = sels
        commit(preset)
    }

    /// 期2 编辑页整包提交（五套组合批量写回）
    func replacePresets(_ newPresets: [ChartPreset]) {
        guard newPresets.count == ChartPresetSlots.ids.count else { return }
        presets = newPresets
        persistPresets()
        ChartConfigStore.shared.bumpConfigModeRevision()
    }

    // MARK: - 持久化与联动

    private func commit(_ preset: ChartPreset) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var copy = presets
        if copy[idx] != preset {
            copy[idx] = preset
            presets = copy
        }
        persistPresets()
        // 生效中的组合被编辑 → 图表 force 重算（指纹含组合内容 + revision 兜底触发）
        ChartConfigStore.shared.bumpConfigModeRevision()
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.presetsKey)
        }
    }
}

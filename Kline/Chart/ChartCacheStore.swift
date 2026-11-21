//
//  ChartCacheStore.swift
//  Kline
//
//  图表指标计算缓存：按 (标的ID, 周期) 缓存主图/副图曲线与计算覆盖状态，
//  同一标的内切换周期或重新进入时不重复计算；LRU 保留最近 3 个标的的所有周期缓存。
//
//  Created by 孙楚昆 on 2026/8/29.
//

import SwiftUI

/// 图表指标计算缓存仓库（全局单例）
final class ChartCacheStore {
    static let shared = ChartCacheStore()

    /// 单个 (标的, 周期) 的指标计算缓存
    final class Entry {
        /// 主图指标曲线（值类型，计算后写回）
        var mainCurves: [IndicatorLine] = []
        /// 主图各指标按输出行的缓存（class 引用，与视图共享同一实例）
        var mainCache = MainIndicatorCache()
        /// 副图曲线（槽位 0/1/2 → subTop/subBottom/subThird）
        var subCurves: [Int: [IndicatorLine]] = [:]
        /// 前台近似计算的覆盖区间（绝对索引）
        var coverageStart = 0
        var coverageEnd = -1
        /// 后台正确计算的覆盖末端（从数据开头向右推进）
        var bgCoverageEnd = 0
        /// 该周期是否已完成全量正确预计算（用于“当前周期算完后继续算其它周期”）
        var prefetchDone = false
        /// 缠论通道行求值时的右缘（绝对索引）：缠论必须截到可见窗口右缘，
        /// 右缘一变即失效；-1 表示尚未按截断口径算过
        var chanCalcEnd = -1
        /// 后台预计算是否进行中（避免对同一周期重复启动）
        var isPrefetching = false
        /// 计算该缓存时所用的指标配置指纹：配置（主/副图指标与参数）变了，缓存视为无效需重算
        var configFingerprint = ""
    }

    struct CacheKey: Hashable {
        let metaId: Int
        let period: KlinePeriod
        /// 指标组合维度（"local"/"p1".."p5"）：同标的不同组合是不同缓存
        let comboKey: String
    }

    private var entries: [CacheKey: Entry] = [:]
    /// 标的 LRU 顺序（最近使用的在末尾）
    private var metaOrder: [Int] = []
    /// P2 指标组合：组合切换（configModeRevision）会让指纹变化使旧条目失效，容量 3→4
    /// 保证「局部/组合来回切换 + 2~3 个常看标的」的常见场景下主组合缓存不被挤掉
    private let maxMetaCount = 4

    /// 当前组合键（缓存 key 组装自动携带；调用方零改动）
    private var comboKey: String { ChartPresetStore.shared.activeMode }

    /// 获取 (组合, 标的, 周期) 的缓存条目（不存在则创建），并更新标的 LRU
    func entry(for metaId: Int, period: KlinePeriod) -> Entry {
        let key = CacheKey(metaId: metaId, period: period, comboKey: comboKey)
        let e: Entry
        if let existing = entries[key] {
            e = existing
        } else {
            e = Entry()
            entries[key] = e
        }
        touch(metaId)
        return e
    }

    /// 指标配置变化时，使该 (标的, 周期) 缓存失效：
    /// 若缓存所用指纹与当前配置不一致（旧配置残留），清掉「完成标记 / 覆盖末端 / 曲线」，
    /// 防止旧配置的完成状态被误当成当前配置的完成状态（否则切换周期后进度条卡死、指标不更新）。
    /// 返回 true 表示确实发生了失效重置（调用方应同步把自身预计算进度归零，避免写回把覆盖末端顶回去）
    @discardableResult
    func invalidateIfConfigChanged(metaId: Int, period: KlinePeriod, currentFingerprint: String) -> Bool {
        guard let e = entries[CacheKey(metaId: metaId, period: period, comboKey: comboKey)] else { return false }
        guard e.configFingerprint != currentFingerprint else { return false }
        e.prefetchDone = false
        e.bgCoverageEnd = 0
        e.mainCurves = []
        e.mainCache = MainIndicatorCache()
        e.subCurves = [:]
        e.configFingerprint = currentFingerprint
        return true
    }

    private func touch(_ metaId: Int) {
        metaOrder.removeAll { $0 == metaId }
        metaOrder.append(metaId)
        // 淘汰超出上限的最久未使用标的
        while metaOrder.count > maxMetaCount {
            let oldest = metaOrder.removeFirst()
            entries = entries.filter { $0.key.metaId != oldest }
        }
    }

    /// 清空全部缓存（数据源切换 / 底层行情数据整体更新时调用，防止旧配置曲线残留）
    func clearAll() {
        entries.removeAll()
        metaOrder.removeAll()
    }

    // MARK: - 磁盘联动（P2 指标组合期3：IndicatorCacheDB 注水 / 落盘）

    /// 从磁盘注水内存条目（同步单行查询 + 行级校验；全过才恢复）。
    /// 调用点：IndicatorComputationStore.init 内存未命中时（主线程，单行 <10ms）。
    /// - Parameters:
    ///   - barCount: 当前加载的 bars 根数（源数据根数校验）
    ///   - lastBarDate: 当前 bars 末根日期（补缺口尾部追加 → 不匹配即失效）
    /// - Returns: 注水是否成功（true = entry 已恢复完整曲线，调用方直接取用）
    @discardableResult
    func hydrateFromDisk(metaId: Int, period: KlinePeriod,
                         fingerprint: String, barCount: Int, lastBarDate: Int) -> Bool {
        let combo = comboKey
        guard let data = IndicatorCacheDB.shared.load(
            comboKey: combo, metaId: metaId, period: period,
            fingerprint: fingerprint, lastBarDate: lastBarDate, sourceBarCount: barCount),
            let env = try? JSONDecoder().decode(IndicatorCacheEnvelope.self, from: data) else {
            return false
        }
        let main = env.main.compactMap { $0.toLine() }
        guard !main.isEmpty, main.allSatisfy({ $0.values.count == barCount }) else { return false }
        var subs: [Int: [IndicatorLine]] = [:]
        for (slot, blobs) in env.subs {
            let lines = blobs.compactMap { $0.toLine() }
            guard lines.allSatisfy({ $0.values.count == barCount }) else { return false }
            subs[slot] = lines
        }
        // 注水进内存条目（后续切周期/切回零读盘）；mainCache 重建为空（增量重算时自建）
        let entry = self.entry(for: metaId, period: period)
        entry.mainCurves = main
        entry.mainCache = MainIndicatorCache()
        entry.subCurves = subs
        entry.coverageStart = env.coverageStart
        entry.coverageEnd = env.coverageEnd
        entry.bgCoverageEnd = env.bgCoverageEnd
        entry.prefetchDone = env.bgCoverageEnd >= barCount - 1
        entry.chanCalcEnd = -1
        entry.configFingerprint = fingerprint
        DebugLogger.shared.log("[IndicatorCache] 磁盘注水 meta=\(metaId) \(period.rawValue) combo=\(combo) mode=\(env.main.isEmpty ? "?" : "ok")")
        return true
    }

    /// 把内存条目落盘（异步写；调用点：全量预计算 commitPrefetch / commitToCache）。
    /// 行级校验字段随行保存：指纹（配置/组合一致才复用）、源根数、末根日期（补缺口失效）。
    func persistToDisk(metaId: Int, period: KlinePeriod, fingerprint: String,
                       barCount: Int, lastBarDate: Int) {
        let combo = comboKey
        let entry = self.entry(for: metaId, period: period)
        guard !entry.mainCurves.isEmpty else { return }
        let env = IndicatorCacheEnvelope(
            main: entry.mainCurves.map { IndicatorLineBlob(from: $0) },
            subs: entry.subCurves.mapValues { $0.map { IndicatorLineBlob(from: $0) } },
            coverageStart: entry.coverageStart,
            coverageEnd: entry.coverageEnd,
            bgCoverageEnd: entry.bgCoverageEnd)
        guard let data = try? JSONEncoder().encode(env) else { return }
        IndicatorCacheDB.shared.save(comboKey: combo, metaId: metaId, period: period,
                                     fingerprint: fingerprint, genMode: "runtime",
                                     lastBarDate: lastBarDate, sourceBarCount: barCount,
                                     payload: data)
    }
}

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
        /// 后台预计算是否进行中（避免对同一周期重复启动）
        var isPrefetching = false
        /// 计算该缓存时所用的指标配置指纹：配置（主/副图指标与参数）变了，缓存视为无效需重算
        var configFingerprint = ""
    }

    struct CacheKey: Hashable {
        let metaId: Int
        let period: KlinePeriod
    }

    private var entries: [CacheKey: Entry] = [:]
    /// 标的 LRU 顺序（最近使用的在末尾）
    private var metaOrder: [Int] = []
    private let maxMetaCount = 3

    /// 获取 (标的, 周期) 的缓存条目（不存在则创建），并更新标的 LRU
    func entry(for metaId: Int, period: KlinePeriod) -> Entry {
        let key = CacheKey(metaId: metaId, period: period)
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
        guard let e = entries[CacheKey(metaId: metaId, period: period)] else { return false }
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
}

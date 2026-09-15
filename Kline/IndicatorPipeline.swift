//
//  IndicatorPipeline.swift
//  Kline
//
//  指标/预计算域：IndicatorComputationStore 状态模型 + 计算管线（3b 起包含 extension 方法）。
//  从 KlineChartView.swift 拆分而来：按"低频写入、无 .onChange 挂钩"原则打包，
//  收敛视图属性区；写入仍触发本视图 body 重绘（与原 @State 行为一致，性能中性）。
//  全部状态写入收敛在主线程（预计算循环 Task { @MainActor in } 包裹，detached 只跑纯函数）。
//

import Foundation
import SwiftUI

/// 指标/预计算状态模型：KlineChartView 每实例一份（@StateObject 持有），
/// init 内完成跳空缺口一次性计算与 (标的, 周期) 缓存恢复（指纹一致时）。
final class IndicatorComputationStore: ObservableObject {
    // MARK: @Published（body 直接读 / 动画挂钩——若降为普通 var 渲染/动画会静默失效）
    /// 主图叠加指标曲线（渲染直接来源：mainCanvas / mainLegendRow / priceRange）
    @Published var mainCurves: [IndicatorLine] = []
    /// 后台正确计算的覆盖末端（绝对索引）：从数据开头（最左）向右逐块推进，
    /// 保证 EMA/SMA 等递归指标从第一根开始累积、数值最正确；覆盖到可见窗口末端后才替换前台近似结果。
    /// 进度条（showCoverageBar/coverageProgressBar）与 .animation(value:) 依赖此值
    @Published var bgCoverageEnd = 0

    // MARK: 普通 var（body 零读，写入不触发 objectWillChange；若未来进 body/onChange 须升 @Published）
    /// 指标已计算的覆盖区间（绝对索引，随滑动/缩放单调扩展）：
    /// 左右滑动时，只要可见窗口仍落在已覆盖范围内就复用曲线不重算，保证"已经计算过的部分不丢失"。
    /// 覆盖区间跨度超上限时（超大幅滑动）重置为当前需要区间，避免退化为全量计算
    var indicatorCoverageStart = 0
    var indicatorCoverageEnd = -1
    /// 历史指标预计算任务 token（nil = 无任务）：打开标的后分块向更久远历史预计算指标，
    /// 切换周期/标的/指标或用户交互时更新使其失效。仅管线方法读写，纯取消哨兵
    var prefetchToken: UUID? = nil
    /// 主图各指标结果缓存（class 引用，原地改 units 本就不触发重绘——原设计保留；
    /// 引用替换仅发生在缓存恢复路径，必伴随 mainCurves @Published 写）
    var mainCache = MainIndicatorCache()

    // MARK: let（init 一次定，此后只读）
    /// 全数据集预计算的跳空缺口（只在数据加载时计算一次，避免每次重绘全量扫描）
    let gaps: [GapInfo]
    /// 指标覆盖区间最大跨度：防止一次滑到很老的历史后覆盖区间扩展到全量
    let maxCoverageSpan = 2000
    /// 预计算每块向右推进的根数（单块毫秒级，块间让出主线程，不阻塞 UI）
    let prefetchBlockSize = 500
    /// 指标计算左侧预热根数：往前多算这一段历史，保证 MA（需前 N 根）与 EMA/SMA 等递归指标
    /// 在可见窗口内已收敛、数值准确；也避免每次拖动/缩放后全量重算。
    /// 取 50 使前台近似总计算量 ≈ 可见窗口(默认100) + 预热(50) ≈ 150 根，降低打开标的时的卡顿；
    /// 长周期指标在可见窗口前段的收敛精度会略降，由后台分块预计算随后覆盖为正确值
    let indicatorWarmup = 50

    /// - Parameters:
    ///   - all: 全量K线（升序）
    ///   - metaId: 标的 id；nil 时跳过缓存恢复（无标的预览等场景）
    ///   - period: 当前周期（缺口计算无关周期；缓存按 (标的, 周期) 维度恢复）
    init(all: [KlineItem], metaId: Int?, period: KlinePeriod) {
        // 全数据集预计算跳空缺口（一次计算，绘制时只按可见区间过滤）
        self.gaps = Self.computeGaps(all)
        // 同一标的内切换周期：从 (标的, 周期) 缓存恢复上次的计算结果与覆盖状态，
        // 保证切回该周期时已算过的部分不重算、不丢失（LRU 保留最近 3 个标的的所有周期）。
        // 仅当缓存所用指标配置指纹与当前一致时才恢复，否则视为无效、按新配置重新计算
        if let metaId {
            let entry = ChartCacheStore.shared.entry(for: metaId, period: period)
            let fingerprint = KlineChartView.currentConfigFingerprint(period: period)
            if entry.configFingerprint == fingerprint {
                mainCurves = entry.mainCurves
                mainCache = entry.mainCache
                indicatorCoverageStart = entry.coverageStart
                indicatorCoverageEnd = entry.coverageEnd
                bgCoverageEnd = entry.bgCoverageEnd
            }
        }
    }

    /// 跳空缺口计算（采用维护缺口列表的线性算法：缺口形成后，某根后续K线价格触及缺口区间即视为回补，
    /// 记录该K线索引为 filledIdx；从未被回补的缺口 filledIdx 为 nil（持续显示））。
    static func computeGaps(_ items: [KlineItem]) -> [GapInfo] {
        guard items.count > 1 else { return [] }
        struct Pending {
            let startIdx: Int
            let top: Double
            let bottom: Double
            let isUp: Bool
        }
        var pending: [Pending] = []
        var result: [GapInfo] = []
        for (i, cur) in items.enumerated() {
            // 当前K线触及缺口区间即回补完成，记录回补位置
            var filled: [Pending] = []
            pending.removeAll { g in
                let isFilled = cur.high >= g.bottom && cur.low <= g.top
                if isFilled { filled.append(g) }
                return isFilled
            }
            for g in filled {
                result.append(GapInfo(startIdx: g.startIdx, top: g.top, bottom: g.bottom, isUp: g.isUp, filledIdx: i))
            }
            // 与上一根K线之间形成新缺口
            if i > 0 {
                let prev = items[i - 1]
                if cur.low > prev.high {
                    pending.append(Pending(startIdx: i, top: cur.low, bottom: prev.high, isUp: true))
                } else if cur.high < prev.low {
                    pending.append(Pending(startIdx: i, top: prev.low, bottom: cur.high, isUp: false))
                }
            }
        }
        // 遍历结束后仍未回补的缺口（一直显示）
        for g in pending {
            result.append(GapInfo(startIdx: g.startIdx, top: g.top, bottom: g.bottom, isUp: g.isUp, filledIdx: nil))
        }
        return result
    }
}

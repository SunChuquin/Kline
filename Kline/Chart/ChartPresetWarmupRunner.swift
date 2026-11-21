//
//  ChartPresetWarmupRunner.swift
//  Kline
//
//  指标缓存生成引擎（P2 指标组合期4）：按选中组合 × 周期 × 全市场标的批量预生成指标缓存，
//  结果直接落盘 IndicatorCacheDB（不触碰内存 LRU / 可见视图）。分「全量」（完整计算）与
//  「预热」（只算最新 N 根近似，buffer 120 保证长窗口指标边界完整）两种模式。
//
//  范式：StrategyPickRunner 同款（@MainActor 单例 + 分批错峰 + 可取消 + @Published 进度）。
//  组装复用 IndicatorPipeline.swift 文件内的私有 helper（ChartWarmupComposer）。
//
//  量级参考：全量 3354 只 ≈ 28~56 分钟/组合；预热 N=80(+120buffer) ≈ 6~17 分钟/组合。
//  批间 sleep 让路前台计算（引擎单例队列是瓶颈，utility QoS 自然低优先级）。
//

import Foundation
import Combine

@MainActor
final class ChartPresetWarmupRunner: ObservableObject {
    static let shared = ChartPresetWarmupRunner()

    /// 阶段：空闲 → 运行（done/total）→ 结束 / 取消
    enum Phase: Equatable {
        case idle
        case running(done: Int, total: Int, comboLabel: String)
        case finished
        case cancelled
    }

    @Published private(set) var phase: Phase = .idle
    /// 预热保留根数（缓存管理页可配置；默认 80）
    @Published var warmupN: Int = 80

    /// 预热切片的边界缓冲根数：保证 MA60 等长窗口指标在保留段前段已收敛（边界无 NaN）
    static let warmupBuffer = 120

    private init() {}

    // MARK: - 入口

    /// 启动生成：combos = 组合 id 列表（"p1".."p5"，不含 local——局部配置的缓存由
    /// 图表运行时自然产出）；mode = "full" | "warm"；periods 默认仅日线。
    func start(combos: [String], mode: String, periods: [KlinePeriod]) {
        cancelFlag = false
        let presets = ChartPresetStore.shared
        let targets: [(comboKey: String, label: String)] = combos.map { id in
            (id, presets.preset(id: id)?.name ?? id)
        }
        guard !targets.isEmpty, !periods.isEmpty, mode == "full" || mode == "warm" else {
            phase = .finished
            return
        }
        let metas = DatabaseManager.shared.metaList
        guard !metas.isEmpty else {
            phase = .finished
            return
        }
        let total = targets.count * periods.count * metas.count
        phase = .running(done: 0, total: total, comboLabel: targets[0].label)
        DebugLogger.shared.log("[Warmup] 生成启动 combos=\(combos) mode=\(mode) periods=\(periods.map(\.rawValue)) 标的=\(metas.count) total=\(total)")

        Task { @MainActor in
            var done = 0
            var failed = 0
            batch: for (ti, target) in targets.enumerated() {
                for period in periods {
                    for meta in metas {
                        if cancelFlag {
                            self.phase = .cancelled
                            DebugLogger.shared.log("[Warmup] 已取消 done=\(done)/\(total)")
                            return
                        }
                        // 组装（主线程：读 store 配置 + fetchBars 走内部队列）
                        let ok = await Self.generateOne(metaId: meta.id, comboKey: target.comboKey,
                                                        period: period, mode: mode,
                                                        warmupN: max(20, self.warmupN))
                        if !ok { failed += 1 }
                        done += 1
                        if done % 10 == 0 || done == total {
                            self.phase = .running(done: done, total: total, comboLabel: target.label)
                            if done % 50 == 0 {
                                DebugLogger.shared.log("[Warmup] 进度 \(done)/\(total) 失败=\(failed) combo=\(target.label)")
                            }
                        }
                        // 批间让路：每 8 只停 150ms，给前台计算让出引擎队列
                        if done % 8 == 0 {
                            try? await Task.sleep(nanoseconds: 150_000_000)
                        }
                    }
                }
                _ = ti
            }
            self.phase = .finished
            DebugLogger.shared.log("[Warmup] 完成 done=\(done)/\(total) 失败=\(failed)")
        }
    }

    /// 取消当前生成（幂等）
    func cancel() {
        cancelFlag = true
    }

    private var cancelFlag = false

    /// 单标的生成：主线程组装请求 → 后台 Python 求值 → 组装 envelope → 落盘。
    /// 失败原因限次落日志（前 8 次，防止 3354 只全刷屏）。
    private static var failLogCount = 0
    private static func failLog(_ reason: String, metaId: Int) {
        guard failLogCount < 8 else { return }
        failLogCount += 1
        DebugLogger.shared.log("[Warmup] 失败#\(failLogCount) meta=\(metaId) \(reason)")
    }

    private static func generateOne(metaId: Int, comboKey: String, period: KlinePeriod,
                                    mode: String, warmupN: Int) async -> Bool {
        let data = DatabaseManager.shared.fetchBars(metaId: metaId, period: period)
        guard !data.isEmpty else {
            failLog("bars 为空", metaId: metaId)
            return false
        }
        // 生成只处理「全局组合」的内容快照：临时按组合配置组装请求
        // （makeFullRequest 读 ChartConfigStore 的 resolver——组合模式下 resolver 已返回组合内容；
        //  但生成要为**每个**组合生成，不能依赖当前 activeMode——这里直接按 preset 构建请求）
        guard let req = makePresetRequest(data: data, period: period, comboKey: comboKey) else {
            failLog("makePresetRequest nil（组合缺槽/主图集为空）", metaId: metaId)
            return false
        }
        // 缠论通道指标不做预生成（右缘截断语义与离线批量冲突，沿用 prefetchOtherPeriod 先例）
        if req.mainFormulas.contains(where: { referencesChanChannel($0) }) {
            failLog("缠论通道指标排除", metaId: metaId)
            return false
        }

        let fingerprint = "gen:\(comboKey)|\(Self.fingerprintCore(period: period))"
        let lastBarDate = data.last?.date ?? 0
        if mode == "warm" {
            // 预热：末 (warmupN + buffer) 根切片求值
            let slice = Array(data.suffix(warmupN + ChartPresetWarmupRunner.warmupBuffer))
            guard let sliceReq = makePresetRequest(data: slice, period: period, comboKey: comboKey) else {
                failLog("切片 makePresetRequest nil", metaId: metaId)
                return false
            }
            let r = await Task.detached(priority: .utility) {
                KlineChartView.evaluatePrefetch(sliceReq)
            }.value
            guard let env = ChartWarmupComposer.warmEnvelope(req: sliceReq, result: r,
                                                             period: period, total: data.count,
                                                             keepN: warmupN) else {
                failLog("warmEnvelope nil（求值空/长度不齐 sliceLen=\(slice.count)）", metaId: metaId)
                return false
            }
            let payload = try? JSONEncoder.indicatorCache.encode(env)
            guard let payload else {
                failLog("encode 失败", metaId: metaId)
                return false
            }
            IndicatorCacheDB.shared.save(comboKey: comboKey, metaId: metaId, period: period,
                                         fingerprint: fingerprint, genMode: "warm",
                                         lastBarDate: lastBarDate, sourceBarCount: data.count,
                                         payload: payload)
            return true
        } else {
            // 全量：整段求值（超时随根数放宽）
            let result = await Task.detached(priority: .utility) {
                KlineChartView.evaluatePrefetch(req)
            }.value
            guard let env = ChartWarmupComposer.fullEnvelope(req: req, result: result,
                                                             period: period,
                                                             barCount: data.count) else {
                failLog("fullEnvelope nil（求值空/长度不齐 n=\(data.count)）", metaId: metaId)
                return false
            }
            let payload = try? JSONEncoder.indicatorCache.encode(env)
            guard let payload else {
                failLog("encode 失败", metaId: metaId)
                return false
            }
            IndicatorCacheDB.shared.save(comboKey: comboKey, metaId: metaId, period: period,
                                         fingerprint: fingerprint, genMode: "full",
                                         lastBarDate: lastBarDate, sourceBarCount: data.count,
                                         payload: payload)
            return true
        }
    }

    /// 按指定组合构建求值请求（不依赖当前 activeMode：直接读 preset 的按周期配置组装公式集）
    private static func makePresetRequest(data: [KlineItem], period: KlinePeriod, comboKey: String) -> PrefetchCalcRequest? {
        guard !data.isEmpty, let preset = ChartPresetStore.shared.preset(id: comboKey) else { return nil }
        let config = ChartConfigStore.shared
        let sys = SystemIndicatorStore.shared
        let customStore = CustomIndicatorStore.shared
        let volumes = data.map(\.volume)
        let turnovers = data.map(\.turnover)
        // 主图：preset 启用集合 ∩ 该周期可用指标
        let enabled = preset.mainIndicators(for: period)
        var mainFormulas: [String] = []
        var mainIDs: [String] = []
        for def in sys.mainIndicatorDefs(period: period) where enabled.contains(def.id) {
            mainFormulas.append(sys.formula(for: def.id, values: [:], period: period) ?? "")
            mainIDs.append(def.id)
        }
        if let customID = preset.activeCustomID(for: period),
           let custom = customStore.indicators.first(where: { $0.id == customID }) {
            mainFormulas.append(custom.formula)
            mainIDs.append(MainIndicatorCache.customKey)
        }
        // 副图：preset 三槽选择
        var subs: [SubPrefetchRequest] = []
        for sel in preset.subSelections(for: period) {
            let customInd = sel.customID.flatMap { id in customStore.indicators.first { $0.id == id } }
            if let customInd {
                subs.append(SubPrefetchRequest(kind: sel.kind, customFormula: customInd.formula,
                                               formula: nil, volPeriods: []))
            } else if sel.kind == "VOL" || sel.kind == "AMO" {
                subs.append(SubPrefetchRequest(kind: sel.kind, customFormula: nil, formula: nil,
                                               volPeriods: volMAFixedPeriods))
            } else {
                subs.append(SubPrefetchRequest(kind: sel.kind, customFormula: nil,
                                               formula: sys.formula(for: sel.kind, values: [:], period: period),
                                               volPeriods: []))
            }
        }
        return PrefetchCalcRequest(calcStart: 0, calcEnd: data.count - 1,
                                   data: data, volumes: volumes, turnovers: turnovers,
                                   mainFormulas: mainFormulas, mainIDs: mainIDs, subs: subs)
    }

    /// 指纹核心（组合内容指纹：与运行时指纹同口径，保证生成行与运行时校验一致）
    private static func fingerprintCore(period: KlinePeriod) -> String {
        // 复用运行时指纹算法（resolver 已含组合内容），剥掉 mode 前缀部分
        let fp = KlineChartView.currentConfigFingerprint(period: period)
        // 运行时指纹首段为 "mode=xxx"——生成行按组合 key 分行，fingerprint 用其内容部分
        if let range = fp.range(of: "\u{1F}") {
            return String(fp[range.upperBound...])
        }
        return fp
    }
}

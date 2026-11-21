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

    /// 启动生成：combos = 组合 id 列表（"local"=局部独立配置——按当前局部配置解析，
    /// 指纹 mode=local 与运行时同源；"p1".."p5"=全局组合）；mode = "full" | "warm"；
    /// periods 默认仅日线；
    /// onlyStale = true 时只处理该组合下「过期行」的标的（口径与管理页徽标一致：
    /// 缓存末根日期 ≠ meta 表最新日期，补缺口/日更后未重新生成）。
    func start(combos: [String], mode: String, periods: [KlinePeriod], onlyStale: Bool = false) {
        // 重入保护：新任务等待旧任务完全退出（旧任务在求值完成后回到循环头检查标志退出），
        // 避免「重跑先取消旧轮」缺位导致两个任务并发抢引擎队列（2026-11-21 实测：连续两次
        // 点生成，local 与 p1 任务交错求值，进度日志互相覆盖）。
        let old = runTask
        runTask = Task { @MainActor in
            await old?.value
            self.cancelFlag = false
            let presets = ChartPresetStore.shared
            let targets: [(comboKey: String, label: String)] = combos.map { id in
                let label = id == ChartPresetStore.localMode
                    ? "局部独立配置"
                    : (presets.preset(id: id)?.name ?? id)
                return (id, label)
            }
            guard !targets.isEmpty, !periods.isEmpty, mode == "full" || mode == "warm" else {
                self.phase = .finished
                return
            }
            var metas = DatabaseManager.shared.metaList
            if onlyStale {
                let periodNames = Set(periods.map(\.rawValue))
                let targetKeys = Set(targets.map(\.comboKey))
                let metaByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
                var staleIDs = Set<Int>()
                for row in IndicatorCacheDB.shared.rowsDetail()
                where targetKeys.contains(row.comboKey) && periodNames.contains(row.period) {
                    if let meta = metaByID[row.metaID], let lastDate = meta.lastDate,
                       row.lastBarDate != lastDate {
                        staleIDs.insert(row.metaID)
                    }
                }
                metas = metas.filter { staleIDs.contains($0.id) }
            }
            guard !metas.isEmpty else {
                self.phase = .finished
                DebugLogger.shared.log("[Warmup] 无\(onlyStale ? "过期" : "")标的需要生成")
                return
            }
            let total = targets.count * periods.count * metas.count
            self.phase = .running(done: 0, total: total, comboLabel: targets[0].label)
            DebugLogger.shared.log("[Warmup] 生成启动 combos=\(combos) mode=\(mode) onlyStale=\(onlyStale) periods=\(periods.map(\.rawValue)) 标的=\(metas.count) total=\(total)")

            var done = 0
            var failed = 0
            for target in targets {
                for period in periods {
                    for meta in metas {
                        if self.cancelFlag || Task.isCancelled {
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
            }
            self.phase = .finished
            DebugLogger.shared.log("[Warmup] 完成 done=\(done)/\(total) 失败=\(failed)")
        }
    }

    /// 取消当前生成（幂等；协作取消加速退出）
    func cancel() {
        cancelFlag = true
        runTask?.cancel()
    }

    private var cancelFlag = false
    private var runTask: Task<Void, Never>? = nil

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
        // 组装段（override 上下文：resolver/指纹按该组合解析）——与运行时 activeMode=comboKey
        // 的指纹口径完全一致，保证「生成后切到该组合」注水命中
        let (req, fingerprint, sliceReq) = ChartPresetStore.shared.withResolverOverride(comboKey) {
            let req = KlineChartView.makeFullRequest(data: data, period: period)
            let fp = KlineChartView.currentConfigFingerprint(period: period)
            // 预热：末 (warmupN + buffer) 根切片（buffer 保证 MA60 等长窗口指标边界收敛）
            let slice = mode == "warm" ? Array(data.suffix(warmupN + ChartPresetWarmupRunner.warmupBuffer)) : []
            let sliceReq = slice.isEmpty ? nil : KlineChartView.makeFullRequest(data: slice, period: period)
            return (req, fp, sliceReq)
        }
        guard let req else {
            failLog("makeFullRequest nil（主图集为空/裸K）", metaId: metaId)
            return false
        }
        // 缠论通道指标不做预生成（右缘截断语义与离线批量冲突，沿用 prefetchOtherPeriod 先例）
        if req.mainFormulas.contains(where: { referencesChanChannel($0) }) {
            failLog("缠论通道指标排除", metaId: metaId)
            return false
        }
        let lastBarDate = data.last?.date ?? 0

        // 求值（后台；不持有 override）
        let envelopeData: Data?
        if mode == "warm" {
            guard let sliceReq else {
                failLog("切片 makeFullRequest nil", metaId: metaId)
                return false
            }
            let r = await Task.detached(priority: .utility) {
                KlineChartView.evaluatePrefetch(sliceReq)
            }.value
            // 组装段（override 恢复：副图选择/颜色按组合解析）
            envelopeData = ChartPresetStore.shared.withResolverOverride(comboKey) {
                guard let env = ChartWarmupComposer.warmEnvelope(req: sliceReq, result: r,
                                                                 period: period, total: data.count,
                                                                 keepN: warmupN) else { return nil as Data? }
                return try? JSONEncoder.indicatorCache.encode(env)
            }
        } else {
            let r = await Task.detached(priority: .utility) {
                KlineChartView.evaluatePrefetch(req)
            }.value
            envelopeData = ChartPresetStore.shared.withResolverOverride(comboKey) {
                guard let env = ChartWarmupComposer.fullEnvelope(req: req, result: r,
                                                                 period: period,
                                                                 barCount: data.count) else { return nil as Data? }
                return try? JSONEncoder.indicatorCache.encode(env)
            }
        }
        guard let payload = envelopeData else {
            failLog("envelope nil/encode 失败（求值空/长度不齐 n=\(data.count)）", metaId: metaId)
            return false
        }
        IndicatorCacheDB.shared.save(comboKey: comboKey, metaId: metaId, period: period,
                                     fingerprint: fingerprint, genMode: mode,
                                     lastBarDate: lastBarDate, sourceBarCount: data.count,
                                     payload: payload)
        return true
    }
}

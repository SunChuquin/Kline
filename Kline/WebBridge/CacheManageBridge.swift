//
//  CacheManageBridge.swift
//  Kline
//
//  指标缓存管理桥（协议 v2 cacheManage.*）：P2 指标组合期4 缓存管理页的 Swift 侧。
//  呈现域：page（入口在个人中心 → page.open("cacheManage")，shell 层全屏页）。
//
//  动作：
//  - stats：六组合占用统计（条目数/字节/过期数）+ 生成运行态 + 预热根数偏好
//  - clear {ids}：按组合清除磁盘缓存（幂等目标态）
//  - generate {combos, mode, periods, warmupN}：启动生成引擎（全市场批量，进度随 changed 推送）
//  - cancelGenerate {}：取消生成（幂等）
//
//  事件 cacheManage.changed {reason: progress|done|cancelled|cleared}（route:"page"）。
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Combine
import Foundation

@MainActor
final class CacheManageBridge: ObservableObject {

    static let shared = CacheManageBridge()

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // 生成引擎进度 → changed 推送（route:"page"；StrategyPickRunner 订阅转发同款）
        ChartPresetWarmupRunner.shared.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                _ = self
                let payload: [String: Any]
                switch phase {
                case .idle:
                    payload = ["reason": "progress", "state": "idle"]
                case .running(let done, let total, let label):
                    payload = ["reason": "progress", "state": "running",
                               "done": done, "total": total, "comboLabel": label]
                case .finished:
                    payload = ["reason": "done"]
                case .cancelled:
                    payload = ["reason": "cancelled"]
                }
                WebMessageRouter.shared.pushEvent("cacheManage.changed", payload: payload, route: "page")
            }
            .store(in: &cancellables)
    }

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "stats":
            return WebBridgeResponse.ok(request.id, data: statsData())
        case "clear":
            return clear(request)
        case "generate":
            return generate(request)
        case "cancelGenerate":
            ChartPresetWarmupRunner.shared.cancel()
            return WebBridgeResponse.ok(request.id)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "cacheManage.\(request.action) 未实现")
        }
    }

    // MARK: 统计

    /// 六组合（local + p1..p5）占用统计：条目数/字节/过期数（末根日期≠meta 最新日 = 过期）。
    /// local 的磁盘缓存同样统计（图表运行时全量预计算落盘也带 comboKey=local）。
    private static func statsData() -> [String: Any] {
        let store = ChartPresetStore.shared
        let db = IndicatorCacheDB.shared
        let rows = db.rowsDetail()
        let metaByID = Dictionary(uniqueKeysWithValues: DatabaseManager.shared.metaList.map { ($0.id, $0) })

        // 行按 comboKey 聚合
        var byCombo: [String: (count: Int, bytes: Int, stale: Int)] = [:]
        for row in rows {
            var agg = byCombo[row.comboKey] ?? (0, 0, 0)
            agg.count += 1
            agg.bytes += row.bytes
            // 过期判定（日线行）：缓存末根日期 ≠ meta 表最新日期（补缺口/日更后未重新生成）
            if row.period == "日线", let meta = metaByID[row.metaID],
               let lastDate = meta.lastDate, row.lastBarDate != lastDate {
                agg.stale += 1
            }
            byCombo[row.comboKey] = agg
        }

        var combos: [[String: Any]] = []
        // local 在前，p1..p5 依次
        for (key, label) in [(ChartPresetStore.localMode, "局部独立配置")]
            + store.presets.map { ($0.id, $0.name) } {
            let agg = byCombo[key] ?? (0, 0, 0)
            combos.append(["comboKey": key, "label": label,
                           "count": agg.count, "bytes": agg.bytes, "staleCount": agg.stale])
        }

        let runner = ChartPresetWarmupRunner.shared
        var running: [String: Any] = ["state": "idle"]
        if case .running(let done, let total, let label) = runner.phase {
            running = ["state": "running", "done": done, "total": total, "comboLabel": label]
        } else if case .finished = runner.phase {
            running = ["state": "finished"]
        } else if case .cancelled = runner.phase {
            running = ["state": "cancelled"]
        }

        return ["combos": combos,
                "running": running,
                "warmupN": runner.warmupN,
                "bufferNote": "预热保留最新 \(runner.warmupN) 根（另含 \(ChartPresetWarmupRunner.warmupBuffer) 根边界缓冲）"]
    }

    // MARK: 清除

    /// cacheManage.clear {ids}：按组合清除磁盘缓存（ids 缺省 = 清全部六组合）
    private static func clear(_ request: WebBridgeRequest) -> [String: Any] {
        let ids = (request.payload["ids"] as? [String]) ?? []
        let targets: [String?] = ids.isEmpty ? [nil] : ids
        for id in targets {
            if let id { IndicatorCacheDB.shared.clear(comboKey: id) } else { IndicatorCacheDB.shared.clear() }
        }
        let label = ids.isEmpty ? "全部组合" : ids.joined(separator: ",")
        DebugLogger.shared.log("[CacheManage] 清除缓存：\(label)")
        WebMessageRouter.shared.pushEvent("cacheManage.changed",
                                          payload: ["reason": "cleared"],
                                          route: "page")
        return WebBridgeResponse.ok(request.id)
    }

    // MARK: 生成

    /// cacheManage.generate {combos, mode, periods?, warmupN?, onlyStale?}：启动生成引擎。
    /// combos = ["local"] + ["p1".."p5"] 子集（local=局部独立配置，按当前局部配置解析）；
    /// mode = "full" | "warm"；periods 缺省 ["日线"]；
    /// onlyStale = true 时只重跑该组合下过期标的（管理页「刷新过期」便捷动作）；
    /// 同一时刻只跑一个任务（单例 Runner，重跑先取消旧轮）。
    private static func generate(_ request: WebBridgeRequest) -> [String: Any] {
        let combos = (request.payload["combos"] as? [String]) ?? []
        let validCombos = combos.filter {
            $0 == ChartPresetStore.localMode || ChartPresetStore.shared.preset(id: $0) != nil
        }
        guard !validCombos.isEmpty else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "组合需为 local 或组合槽位（p1..p5）")
        }
        let mode = request.payload["mode"] as? String ?? "warm"
        guard mode == "full" || mode == "warm" else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload",
                                          message: "mode 必须为 full / warm")
        }
        let periodsRaw = (request.payload["periods"] as? [String]) ?? ["日线"]
        let periods = periodsRaw.compactMap(KlinePeriod.init(rawValue:))
        guard !periods.isEmpty else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "periods 非法")
        }
        if let n = (request.payload["warmupN"] as? NSNumber)?.intValue, n >= 20, n <= 1000 {
            ChartPresetWarmupRunner.shared.warmupN = n
        }
        let onlyStale = (request.payload["onlyStale"] as? Bool) ?? false
        ChartPresetWarmupRunner.shared.start(combos: validCombos, mode: mode, periods: periods,
                                             onlyStale: onlyStale)
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }
}

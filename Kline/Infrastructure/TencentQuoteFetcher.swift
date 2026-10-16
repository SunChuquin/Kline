//
//  TencentQuoteFetcher.swift
//  Kline
//
//  设备侧「清单标的当日K线」取数器 —— **单源腾讯**（`web.ifzq.gtimg.cn/appstock/app/newfqkline/get`）。
//  供 `WatchlistSyncManager` 在四个时刻拉「清单并集」的最新一根 K 线，写入增量库并触发条件单/预警重扫。
//  **不依赖 PC、不依赖云端分片**。
//
//  历史：原实现走东财 `push2.eastmoney.com/api/qt/ulist.np/get` 批量快照（已删除：真机持续
//  HTTP 502，且用户已定「只用腾讯源」）。本取数器**逐只复用** `GapBackfill` 的腾讯取数 + 自校准
//  管线（`fetchGap`），保证与「补缺口」**同一量纲口径** —— 这是硬要求：腾讯源 vol 是**手**、
//  主库个股是**股**，直接写增量库会让成交量柱只有历史的 1/100（旧云分片就踩过这个断崖）。
//
//  取数口径（全部沿用 GapBackfill，改这里前先读它）：
//   - 每只一条请求 `<marketCode>,day,<锚点日>,<今日>,<根数>,bfq`（`bfq` 不可省 = 不复权 = 主库口径）；
//   - 锚点日 = 该只主库 `meta.last_date` 当天那一行（`GapJob.base`），自校准要求锚点日价格逐字段相等，
//     量比吸附 1 / 100 / 1e-4 / 1e-7，额比哨兵 2% → 任一条不符即丢弃该只（宁可少写，绝不写错量纲）；
//   - 产出 = **最新一根**（`date > 锚点日` 的最后一行）；通常就是当日盘中/收盘那根。
//     中间空档日不在此处补 —— 同一时刻的「清单范围补缺口」已在前面跑过（见 `TdxSyncManager.checkSchedule`）。
//
//  file → 腾讯码映射：复用 `GapBackfill` 的 `ProbeItem`（SH#→sh、SZ#→sz、27#→hk、12#→us、
//  SH#999999→sh000001、62#/102# 000 段→sh 其余→sz；映射不到 → 该只跳过）。
//  62#/102# **定制段**（930/931/932/950/987/970/CN 等）腾讯无码 → 预过滤跳过（`noSourceSegment`）。
//
//  线程约定：`fetch(jobs:completion:)` 全流程在内部串行队列上执行（并发取数，24 路 × 4 条 h2 连接），
//  `completion` 也在该队列回调；调用方需自行切回主线程更新 UI / @Published 状态。
//

import Foundation

// MARK: - 返回结构契约

/// 单只标的的最新一根K线（值**已折算到主库口径**：个股 vol = 股、amo = 元；指数按自校准系数）
struct QuoteDailyBar {
    /// 交易日 YYYYMMDD，来自腾讯行内的日期字段
    let date: Int
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let vol: Double
    let amo: Double
}

/// 跳过 / 失败的原因分类（逐条记录）。
enum QuoteSkipReason {
    /// `ProbeItem` 映射不到腾讯码（42#/46# 等两源皆无）
    case unmappable
    /// 62#/102# 定制段：腾讯无码，预过滤跳过
    case noSourceSegment
    /// 主库无该 file 的锚点行（`meta.last_date` 缺失 / 主库日线缺那一行）→ 无从自校准
    case noBaseline
    /// 锚点日已不早于今日 → 本来就无新 bar（非交易日 / 已最新）
    case upToDate
    /// 源侧锚点量为 0 → 真实停牌，无从折算
    case suspended
    /// 源侧没有锚点日那一根（长期停牌，两边无重叠校准日）→ 跳过（不是口径异常）
    case anchorMissing
    /// 口径异常（价格 / 量比 / 额比不符）→ 丢弃该只
    case anomaly(String)
    /// 取数失败（网络 / 接口无该代码 / 解析不出行）
    case failed(String)

    var text: String {
        switch self {
        case .unmappable:     return "无腾讯码映射"
        case .noSourceSegment: return "腾讯无源段"
        case .noBaseline:     return "无主库锚点"
        case .upToDate:       return "已最新"
        case .suspended:      return "停牌"
        case .anchorMissing:  return "无重叠校准日"
        case .anomaly:        return "口径异常"
        case .failed:         return "取数失败"
        }
    }
}

/// 被跳过的标的及原因。
struct QuoteSkip {
    let file: String
    let reason: QuoteSkipReason
    let detail: String
}

/// 单只取数失败（网络 / 接口无码等）。**单只失败不影响其他只**。
struct QuoteSourceFailure {
    let file: String
    let marketCode: String
    let error: String
}

/// 一次拉取的完整结果。
struct QuoteFetchResult {
    /// 全部命中标的的最新交易日（应一致，取最大值）；无命中为 0
    let tradeDate: Int
    /// file -> 最新一根K线（只含命中项）
    let bars: [String: QuoteDailyBar]
    /// 跳过清单（含原因）
    let skipped: [QuoteSkip]
    /// 逐只取数失败清单
    let batchFailures: [QuoteSourceFailure]

    var hitCount: Int { bars.count }
    var isEmpty: Bool { bars.isEmpty }
}

// MARK: - 取数器

final class TencentQuoteFetcher {
    static let shared = TencentQuoteFetcher()

    // MARK: 常量（与 GapBackfill 同拐点）

    /// 并发路数：12 路 18.6 只/s、24 路 30.6 只/s、32 路延迟雪崩 → 24 为吞吐拐点（PC 实测）
    static let concurrency = 24
    /// Session 数 = h2 连接数：单连接 24 并发流会被服务端掐断 → 4 条各分摊 ≤6 流
    static let sessionCount = 4

    // MARK: 内部

    private let queue = DispatchQueue(label: "com.sunck.kline.tencent.quote")
    /// 无缓存多会话（单请求 20s 超时、整体资源 60s，与 GapBackfill 同参数）
    private let sessions: [URLSession] = (0..<TencentQuoteFetcher.sessionCount).map { _ in
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }

    private init() {}

    // MARK: - 对外入口

    /// 拉取 `jobs`（每只 = 主库 meta + 腾讯码 + 主库锚点行）的**最新一根**当日K线。
    /// - 24 路并发、逐只单请求；每只经「锚点自校准」折算到主库口径，对不上者丢弃并逐条记录。
    /// - `completion` 在内部串行队列回调（调用方自行切主线程）。
    func fetch(jobs: [GapJob], completion: @escaping (QuoteFetchResult) -> Void) {
        queue.async {
            completion(self.performFetch(jobs: jobs))
        }
    }

    // MARK: - 主流程（只在 `queue` 上执行）

    private func performFetch(jobs: [GapJob]) -> QuoteFetchResult {
        let today = TdxSyncManager.todayYMD()
        let total = jobs.count
        let t0 = Date()

        var bars: [String: QuoteDailyBar] = [:]
        var skipped: [QuoteSkip] = []
        var failures: [QuoteSourceFailure] = []
        let lock = NSLock()
        let gate = DispatchSemaphore(value: Self.concurrency)

        if total > 0 {
            DispatchQueue.concurrentPerform(iterations: total) { idx in
                gate.wait()
                let job = jobs[idx]
                let outcome = self.fetchOne(job: job, today: today,
                                            session: self.sessions[idx % self.sessions.count])
                gate.signal()
                lock.lock()
                switch outcome {
                case .bar(let bar):
                    bars[job.meta.file] = bar
                case .skip(let skip):
                    skipped.append(skip)
                case .failure(let failure):
                    failures.append(failure)
                }
                lock.unlock()
            }
        }

        // 交易日本应一致（跨日 / 个别停牌标的会偏旧），取最大值并记日志
        let tradeDate = bars.values.map { $0.date }.max() ?? 0
        let distinct = Set(bars.values.map { $0.date })
        if distinct.count > 1 {
            DebugLogger.shared.log("[TencQuote] 交易日不一致 \(distinct.sorted())，取最大值 \(tradeDate)")
        }
        let seconds = Date().timeIntervalSince(t0)
        DebugLogger.shared.log("[TencQuote] 完成：待取 \(total) 只 → 命中 \(bars.count)"
            + " / 跳过 \(skipped.count) / 取数失败 \(failures.count) / 交易日 \(tradeDate)"
            + String(format: "，耗时 %.1fs", seconds))
        return QuoteFetchResult(tradeDate: tradeDate, bars: bars,
                                skipped: skipped, batchFailures: failures)
    }

    // MARK: - 单只（并发执行）

    private enum OneOutcome {
        case bar(QuoteDailyBar)
        case skip(QuoteSkip)
        case failure(QuoteSourceFailure)
    }

    /// 单只：锚点日 ≥ 今日 → 已最新；否则复用 `GapBackfill.fetchGap`（取数 + 自校准）取最新一根。
    private func fetchOne(job: GapJob, today: Int, session: URLSession) -> OneOutcome {
        let file = job.meta.file
        let anchor = job.base.date
        guard anchor > 0 else {
            return .skip(QuoteSkip(file: file, reason: .noBaseline, detail: "主库锚点日无效"))
        }
        guard today > anchor else {
            return .skip(QuoteSkip(file: file, reason: .upToDate,
                                   detail: "锚点日 \(anchor) 已不早于今日 \(today)"))
        }
        let outcome = GapBackfill.shared.fetchGap(job: job, mainLatest: anchor,
                                                  today: today, session: session)
        switch outcome {
        case .gap(let gapBars, _, _):
            // 只取最新一根（中间空档日由同刻的「清单范围补缺口」负责）
            guard let last = gapBars.last else {
                return .skip(QuoteSkip(file: file, reason: .upToDate, detail: "无 date > \(anchor) 的行"))
            }
            return .bar(QuoteDailyBar(date: last.date, open: last.open, high: last.high,
                                      low: last.low, close: last.close,
                                      vol: last.vol, amo: last.amo))
        case .upToDate:
            return .skip(QuoteSkip(file: file, reason: .upToDate, detail: "源侧无 date > \(anchor) 的行"))
        case .suspended:
            return .skip(QuoteSkip(file: file, reason: .suspended, detail: "源侧锚点日 \(anchor) 量为 0"))
        case .anchorMissing:
            return .skip(QuoteSkip(file: file, reason: .anchorMissing,
                                   detail: "源侧无锚点日 \(anchor) 那一根"))
        case .anomaly(let why):
            return .skip(QuoteSkip(file: file, reason: .anomaly(why), detail: why))
        case .failed(let why):
            return .failure(QuoteSourceFailure(file: file, marketCode: job.item.marketCode, error: why))
        }
    }
}

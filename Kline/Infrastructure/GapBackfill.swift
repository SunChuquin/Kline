//
//  GapBackfill.swift
//  Kline
//
//  补缺口（**App 直连腾讯历史K线自行补齐 · 不依赖 CNB**）
//
//  背景：主库 `tdx.db` 的 `meta.last_date` / `daily` 止于导入时点（实测 20260828），
//  而云源（CNB 分片）每天只给「最后一根」，中间的空档永远没人补 → 日线图上一段空白。
//
//  本组件一次跑完（可重复跑，幂等）：
//    ① 主库 `meta.last_date` 最大值 = 全市场主库最新交易日 `mainLatest`；
//    ② 读主库 `mainLatest` 当天每只的 OHLCV/AMO 作为**自校准基准**（一次 SQL 取全市场）；
//    ③ 逐只直连腾讯历史K线 `newfqkline` 拉 `[mainLatest, today]` 的日线
//       （4 条 h2 连接 × 24 路并发；根数按缺口自然日差动态算 + 10 余量、封顶 320；
//        腾讯失败/无码自动落东财 push2his 第二源——62#/102# 定制段 930/931 等只有东财有）；
//    ④ 用基准当天那一行做**自校准**（价格必须逐字段相等；量比吸附到 1 或 100；额比须 ≈1），
//       任一条不符 → 判为口径异常并**丢弃该只**（宁可少补，绝不静默写错值）；
//    ⑤ 生成 `date > mainLatest` 的缺口行（量按自校准系数折算到**主库口径**），
//       经 `LiveDataStore.upsertDaily` 写入 `tdx_live.db`（`(file,date)` UPSERT）
//       → 查询层「live 覆盖 main」自动生效，日线图立刻连续。
//    ⑥ 缺口区间的**周/月/季/年线**：日线落库后，以「主库最新日所在周期桶」为锚，把锚桶及之后各桶
//       用「主库日线 ∪ 增量库日线」逐桶重算（`LiveDataStore.rebuildGapPeriods`）→ 周期视图同样连续。
//       **锚桶必须一起重算**：主库那一份是**被截断**的（8 月月线只聚到 0828，而 0831 仍属 8 月；
//       季线 Q3、年线 2026 同理，`close` 都是 0828 的收盘）。
//       柱的 `date` = 该周期内该只的**首个交易日**（与主库口径逐槽一致，停牌股会落在周中/月中）。
//       季/年**不读整年日线**：直接取主库该桶当期 bar 作基期再叠加缺口日线（口径同 `mergePeriodBar`）。
//
//  顺带修掉「旧断崖」：云分片那几天的 `live_daily.vol` 是**手**（腾讯快照口径），而主库个股是**股**，
//  查询层直接拼接 → 增量那几天成交量柱只有历史 1/100 高（已由子代理全链路核查确认无任何换算）。
//  本组件的缺口行覆盖整个 `(mainLatest, today]` 区间，`(file,date)` UPSERT 会把旧的「手」值
//  **就地覆盖**成「股」—— 断崖随补缺口一并消除。
//
//  ---- 腾讯 newfqkline 字段语义（2026-10-02 实测确认，**写错即静默错值**）----
//    URL: https://web.ifzq.gtimg.cn/appstock/app/newfqkline/get
//         ?param=<marketCode>,day,<起>,<止>,<根数>,<复权>
//    ⚠️ **param 必须 6 段**（缺第 6 段复权类型 → 接口一律返回 `{"code":1,"msg":"bad params"}`，
//       全市场 3312 只全灭。本组件第一版就是漏了这一段，由 GapBackfillUITests 逮住）
//      · `,bfq`（或逗号后留空）→ 响应键 `day`，**不复权 = 主库口径** ✅
//      · `,qfq` → 响应键 `qfqday`（前复权，价格会与主库不等）
//    响应: {"code":0,"data":{"sh600000":{"day":[[...],[...]]}}}
//    行数组 11 字段：
//      [0]日期(YYYY-MM-DD)  [1]**开**  [2]**收**  [3]**高**  [4]**低**
//      [5]量(手)            [6]{}      [7]换手率%  [8]**成交额(万元)**  [9]0.00  [10]0.00
//    ⚠️ 价格顺序是 **开-收-高-低**（与 `qt.gtimg.cn/q=` 快照的 开-高-低-收 **不同**！写错即静默错值）
//    ⚠️ 结束日生效、起始日会被接口**向前扩**，故用「根数」控制返回条数更可靠（实测 320 有效）
//    ⚠️ 指数的量/额量纲与个股不同（如 sh000001 量 4.1 亿），但**由自校准吸附，无需硬编码**
//
//  ---- 量纲自校准（实测锚定，SH#600000 五日逐字段核实）----
//    主库 vol(股) ÷ 100 = 接口 vol(手)   → 个股 volRatio = 100
//    主库 amo(元) ÷ 10000 = 接口[8](万元) → amo = [8] × 10000
//    指数/科创板等「主库本来就按手」→ volRatio = 1
//    **一律用基准当天实算吸附，不硬编码任何例外规则**。
//
//  仅为「补缺口」功能，不参与自动同步调度；写入仅落在增量库（不动主库）。
//

import Foundation
import Combine

/// 一只标的的补缺口作业（清单 + 可映射源代码 + 基准行）
private struct GapJob {
    let meta: MetaItem
    let item: ProbeItem
    /// 主库 `mainLatest` 当天那一根（自校准锚点）
    let base: KlineItem
}

/// 源侧（腾讯）原始一根日线
private struct SourceBar {
    let date: Int
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    /// 手（腾讯口径）
    let vol: Double
    /// 万元（腾讯口径）
    let amo: Double
}

/// 折算到**主库口径**后、待写入增量库的缺口行
private struct GapBar {
    let date: Int
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    /// 股（或指数的手，按自校准系数）
    let vol: Double
    /// 元
    let amo: Double
}

/// 单只取数结果
private enum GapOutcome {
    /// 有缺口行（含自校准系数，供汇总统计量纲分布）；priceOnly = 量额缺失只补价格
    case gap(bars: [GapBar], volRatio: Double, priceOnly: Bool)
    /// 接口返回的行全部 ≤ 主库最新日 → 本来就是最新的
    case upToDate
    /// 基准日停牌（量或额为 0）→ 无从校准
    case suspended
    /// 源侧没有主库最新日那根（长期停牌，两边**无重叠校准日**）→ 跳过（**不是口径异常**）
    case anchorMissing
    /// 口径异常（价格 / 量比 / 额比不符）→ 丢弃
    case anomaly(String)
    /// 取数失败（网络 / 接口无该代码 / 解析不出行）
    case failed(String)
}

/// 补缺口（**App 直连腾讯历史K线为主源、东财 push2his 兜底，自行把主库最新日 → 今天的日线补齐**）
final class GapBackfill: ObservableObject {
    static let shared = GapBackfill()

    enum State { case idle, running, ok, failed }

    // MARK: 常量

    /// 腾讯历史K线（带成交额）：`param=<marketCode>,day,<起>,<止>,<根数>,bfq`
    /// ⚠️ 末尾 `bfq` 不可省（= 不复权，与主库口径一致）；省略第 6 段会被接口判 `bad params`
    static let klineURLPrefix = "https://web.ifzq.gtimg.cn/appstock/app/newfqkline/get?param="
    /// 并发路数（2026-10-03 PC 实测：12 路 18.6 只/s、24 路 30.6 只/s、32 路延迟雪崩
    /// max 18.5s 且吞吐掉到 10.6 只/s → 24 是吞吐拐点，且未复现限流）
    static let concurrency = 24
    /// Session 数 = h2 连接数：URLSession 对同一 host 复用**单条** HTTP/2 连接，
    /// PC 实测单连接 24 并发流会被服务端掐断（PROTOCOL_ERROR last_stream_id=661）、
    /// 12 流正常 → 4 条连接分摊，每条 ≤6 流
    static let sessionCount = 4
    static let requestTimeout: TimeInterval = 20
    /// 每只请求的**最大**根数（实测 320 有效）。正常缺口用 `barsCount(from:to:)` 动态算，
    /// 只有缺口超过 310 个自然日时才会用到这个上限（保留旧行为）
    static let maxBars = 320
    /// 动态根数的额外余量（自然日差已覆盖交易日，余量只防长假边界取整）
    static let barsMargin = 10
    /// 价格相对容差（主库与源应逐字段相等，只留浮点余量）
    static let priceTolerance = 1e-5
    /// 量比吸附：落在这两个窗口内才认（1 → [0.5, 2]；100 → [50, 200]），窗口外判口径异常。
    /// 窗口刻意开得比「±2%」宽：实测深市指数（399006/399102）源与主库本身就有 +4%
    /// 的统计口径差（1.0403），它离 100 十万八千里，必须吸附到 1；
    /// 而「既不像 1 也不像 100」的比值仍会被拦下（宁可少补，绝不写错量纲）。
    static let volRatioBand1: ClosedRange<Double> = 0.5...2
    static let volRatioBand100: ClosedRange<Double> = 50...200
    /// 中证/国证指数（62#/102# 的 000/399/980 段）：主库 vol = 源 vol ÷ 10000（PC 全量对拍精确 1e-4）
    static let volRatioBand0_0001: ClosedRange<Double> = 0.00005...0.0002
    /// 恒生系（27# → hk）：主库 vol = 源 vol ÷ 1e7 **再四舍五入到整数**。
    /// 2026-10-03 复检（30 日 × 3 只）：round(源/1e7)==主库vol 90 样本仅 2 例边界违例（银行家舍入），
    /// amo 关系精确 ×0.01 —— 主库港股指数口径就是「成交额(港元)÷1e7」，可安全换算
    static let volRatioBand1e_7: ClosedRange<Double> = 0.00000008...0.000000125
    /// 成交额相对容差：**只当量纲哨兵用**（拦 100x / 10000x 级别错误），不做数值一致性判据。
    /// 个股实测偏差 0.0000%；但深市指数（399006/399102）源与主库自身就有 **+0.73%** 的
    /// 统计口径差（与两者 vol 差 +4% 同源），卡在 0.5% 会把它们误判成口径异常。
    static let amoRatioTolerance = 0.02
    /// 取数重试：并发 12 路猛打会被腾讯瞬时限流（实测全市场 42 只 HTTP 失败、
    /// 且失败的是**连续代码段** → 限流特征）；失败后短退避重试一次即可恢复
    static let maxAttempts = 2
    static let retryDelay: TimeInterval = 0.4
    /// 明细里异常 / 失败样本最多各列几条
    static let sampleLimit = 8

    // MARK: 对外只读状态（一律在主线程发布）

    @Published private(set) var state: State = .idle
    @Published private(set) var statusText = "尚未运行"
    /// 主库最新交易日 → 今日
    @Published private(set) var coverageText = "—"
    /// 取数汇总（可比只数 / 各类计数）
    @Published private(set) var fetchText = "—"
    /// 结论一句话（UI 断言锚点：含「缺口已补」= 通过）
    @Published private(set) var verdictText = "—"
    /// 明细分行（覆盖交易日 / 异常与失败样本）
    @Published private(set) var detailLines: [String] = []

    var isRunning: Bool { state == .running }

    // MARK: 内部

    private let queue = DispatchQueue(label: "com.sunck.kline.gapbackfill")
    /// 多 Session = 多条独立 h2 连接（原因见 `sessionCount` 注释）
    private let sessions: [URLSession] = (0..<GapBackfill.sessionCount).map { _ in
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }

    private init() {}

    // MARK: - 入口（按钮调用，主线程）

    func run() {
        // 入口无条件落日志：区分「按钮没点到」与「点到了但早退」（UI 测试排障用）
        DebugLogger.shared.log("[GapBackfill] run() 入口 state=\(state) meta=\(DatabaseManager.shared.metaList.count)")
        guard state != .running else {
            DebugLogger.shared.log("[GapBackfill] 已在运行，忽略本次点击")
            return
        }
        // @Published metaList 只能在主线程读
        let metas = DatabaseManager.shared.metaList
        guard !metas.isEmpty else {
            DebugLogger.shared.log("[GapBackfill] metaList 为空，中止（等待主库打开）")
            state = .failed
            statusText = "主库 metaList 为空（等待主库打开）"
            verdictText = "失败：主库 metaList 为空"
            return
        }
        let mainLatest = metas.compactMap { $0.lastDate }.max() ?? 0
        let today = TdxSyncManager.todayYMD()

        state = .running
        statusText = "准备中…"
        coverageText = "主库 \(mainLatest) → 今日 \(today)"
        fetchText = "—"
        verdictText = "—"
        detailLines = []
        DebugLogger.shared.log("[GapBackfill] 开始补缺口：清单 \(metas.count) 只，主库最新 \(mainLatest)，今日 \(today)")

        guard mainLatest > 0, today > mainLatest else {
            state = .ok
            statusText = "无缺口"
            verdictText = "无缺口：主库 \(mainLatest) 已不早于今日 \(today)"
            DebugLogger.shared.log("[GapBackfill] 主库已是最新（\(mainLatest) ≥ \(today)），无需补")
            return
        }

        // ⓪ 单只探测：源侧最新交易日 ≤ 主库最新 → 无缺口早退（节假日/已补齐时省 3312 次请求）。
        //    探测失败（网络抖动）→ 照旧跑全市场（fail-open，不因探测阻塞正常补缺口）
        probeUpToDate(mainLatest: mainLatest, today: today) {
            var metaIdByFile: [String: Int] = [:]
            for m in metas { metaIdByFile[m.file] = m.id }
            // 基准行：主库 mainLatest 当天的 OHLCV/AMO（一次 SQL 取全市场）
            DatabaseManager.shared.performOnDBQueue({ db in
                DatabaseManager.readMainDaily(db: db, metaIdByFile: metaIdByFile,
                                              fromDate: mainLatest, toDate: mainLatest)
            }, completion: { [weak self] baseline in
                guard let self = self else { return }
                self.queue.async {
                    self.perform(metas: metas, baseline: baseline, mainLatest: mainLatest, today: today)
                }
            })
        }
    }

    /// 无缺口早退探测：拉一只活跃标的（SH#600000）最近几根，源侧最新日 ≤ 主库最新 → 判定全市场无缺口。
    /// 回调（proceed）在主线程。探针失败 → 照常继续（宁可多跑，不因探测失败阻塞补缺口）。
    private func probeUpToDate(mainLatest: Int, today: Int, proceed: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let item = ProbeItem(file: "SH#600000", type: "股票") else { proceed(); return }
            let (fetched, why) = self.fetchSourceBars(item: item, from: mainLatest, to: today,
                                                      count: 10, session: self.sessions[0])
            if let rows = fetched, let srcLatest = rows.last?.date {
                if srcLatest <= mainLatest {
                    DebugLogger.shared.log("[GapBackfill] 探测：源侧最新 \(srcLatest) ≤ 主库 \(mainLatest) → 无缺口早退")
                    self.publish {
                        self.state = .ok
                        self.statusText = "无缺口"
                        self.coverageText = "主库 \(mainLatest) → 今日 \(today)"
                        self.fetchText = "—"
                        self.verdictText = "无缺口：源侧最新 \(srcLatest) ≤ 主库 \(mainLatest)（非交易日或已补齐）"
                        self.detailLines = ["探测 \(item.marketCode)：源侧最新 \(srcLatest) ≤ 主库 \(mainLatest)"]
                    }
                    return
                }
                DebugLogger.shared.log("[GapBackfill] 探测：源侧最新 \(srcLatest) > 主库 \(mainLatest) → 有缺口，跑全市场")
            } else {
                DebugLogger.shared.log("[GapBackfill] 探测失败（\(why)）→ 照旧跑全市场")
            }
            DispatchQueue.main.async(execute: proceed)
        }
    }

    // MARK: - 主流程（只在 queue 上）

    private func perform(metas: [MetaItem], baseline: [String: [KlineItem]],
                         mainLatest: Int, today: Int) {
        let t0 = Date()

        // ① 筛出「需要补 + 可映射 + 有基准行」的作业
        var jobs: [GapJob] = []
        var unmappable = 0
        var noBaseline = 0
        for m in metas {
            let last = m.lastDate ?? 0
            guard last < today else { continue }              // 已到今日（或无 last_date）→ 无需补
            guard let item = ProbeItem(file: m.file, type: m.type) else { unmappable += 1; continue }
            guard last == mainLatest,
                  let base = baseline[m.file]?.first(where: { $0.date == mainLatest }) else {
                noBaseline += 1
                continue
            }
            jobs.append(GapJob(meta: m, item: item, base: base))
        }
        let total = jobs.count
        publish {
            self.statusText = "取数中… 0/\(total)"
            self.coverageText = "主库 \(mainLatest) → 今日 \(today) · 待补 \(total) 只"
        }
        DebugLogger.shared.log("[GapBackfill] 可补作业 \(total) 只"
            + "（不可映射 \(unmappable) 只 · 基准行缺失 \(noBaseline) 只）")

        guard total > 0 else {
            finishEmpty(mainLatest: mainLatest, today: today, unmappable: unmappable, noBaseline: noBaseline)
            return
        }

        // ② 并发逐只取数（结果按下标回填，共享计数加锁；信号量限制在途请求数）
        let lock = NSLock()
        let gate = DispatchSemaphore(value: Self.concurrency)
        var outcomes = [GapOutcome?](repeating: nil, count: total)
        var emFlags = [Bool](repeating: false, count: total)
        var processed = 0
        var lastPublish = Date.distantPast
        DispatchQueue.concurrentPerform(iterations: total) { idx in
            gate.wait()
            let session = self.sessions[idx % self.sessions.count]
            let (outcome, usedEM) = self.fetchGap(job: jobs[idx], mainLatest: mainLatest, today: today,
                                                  session: session)
            gate.signal()
            lock.lock()
            outcomes[idx] = outcome
            emFlags[idx] = usedEM
            processed += 1
            let done = processed
            // UI 节流 0.25s：既不刷爆主线程，又让用户看到「还在跑、跑到哪」
            let now = Date()
            let shouldPublish = done == total || now.timeIntervalSince(lastPublish) >= 0.25
            if shouldPublish { lastPublish = now }
            lock.unlock()
            let elapsed = now.timeIntervalSince(t0)
            let rate = Double(done) / max(elapsed, 0.001)
            if shouldPublish {
                let remaining = Double(total - done) / max(rate, 0.001)
                self.publish {
                    self.statusText = String(format: "取数中… %d/%d · %.1f只/s · 预计剩余%.0fs",
                                              done, total, rate, remaining)
                }
            }
            if done % 200 == 0 {
                DebugLogger.shared.log(String(format: "[GapBackfill] 进度 %d/%d · %.1fs · %.1f只/s · 剩余%.0fs",
                                                    done, total, elapsed, rate,
                                                    Double(total - done) / max(rate, 0.001)))
            }
        }
        publish { self.statusText = "写入增量库…" }

        // ③ 汇总
        var outMetas: [LiveUpsertMeta] = []
        var outBars: [LiveUpsertBar] = []
        var gapFiles = 0
        var upToDate = 0
        var suspended = 0
        var anchorMissing = 0
        var anomalies: [String] = []
        var failures: [String] = []
        var ratio1 = 0
        var ratio100 = 0
        var ratio10000 = 0
        var emCount = 0
        var priceOnlyCount = 0
        var gapDates = Set<Int>()
        for (idx, outcome) in outcomes.enumerated() {
            guard let outcome = outcome else { continue }
            let m = jobs[idx].meta
            switch outcome {
            case .gap(let bars, let volRatio, let priceOnly):
                gapFiles += 1
                if emFlags[idx] { emCount += 1 }
                if priceOnly {
                    priceOnlyCount += 1
                } else if volRatio == 1 { ratio1 += 1 }
                else if volRatio == 100 { ratio100 += 1 }
                else { ratio10000 += 1 }
                outMetas.append(LiveUpsertMeta(file: m.file, code: m.code, name: m.name, type: m.type))
                for b in bars {
                    gapDates.insert(b.date)
                    outBars.append(LiveUpsertBar(file: m.file, date: b.date,
                                                 open: b.open, high: b.high, low: b.low, close: b.close,
                                                 vol: b.vol, amo: b.amo))
                }
            case .upToDate:
                upToDate += 1
            case .suspended:
                suspended += 1
            case .anchorMissing:
                anchorMissing += 1
            case .anomaly(let why):
                if anomalies.count < Self.sampleLimit { anomalies.append("\(m.file) \(why)") }
            case .failed(let why):
                if failures.count < Self.sampleLimit { failures.append("\(m.file) \(why)") }
            }
        }
        let anomalyCount = outcomes.filter { if case .anomaly = $0 { return true }; return false }.count
        let failureCount = outcomes.filter { if case .failed = $0 { return true }; return false }.count

        let dateList = gapDates.sorted()
        let dateSpan = dateList.isEmpty ? "-" : "\(dateList.first!) ~ \(dateList.last!) 共 \(dateList.count) 个交易日"
        let seconds = Date().timeIntervalSince(t0)

        var lines: [String] = []
        lines.append("主库 \(mainLatest) → 今日 \(today)：待补 \(total) 只"
            + "（不可映射 \(unmappable) · 基准行缺 \(noBaseline)）")
        lines.append("缺口覆盖 \(dateSpan)")
        lines.append(String(format: "自校准量纲：1x %d 只 / 100x %d 只 / 指数折算 %d 只 / 仅补价格 %d 只"
                                  + " · 东财兜底 %d 只 · 口径异常 %d 只 · 取数失败 %d 只"
                                  + " · 无重叠校准日 %d 只 · 停牌 %d 只 · 已最新 %d 只（%.1fs）",
                            ratio1, ratio100, ratio10000, priceOnlyCount, emCount,
                            anomalyCount, failureCount,
                            anchorMissing, suspended, upToDate, seconds))
        for s in anomalies { lines.append("口径异常：\(s)") }
        for s in failures { lines.append("取数失败：\(s)") }

        publish {
            self.fetchText = "补齐 \(gapFiles) 只 / \(outBars.count) 行 · \(dateSpan)"
            self.detailLines = lines
        }
        DebugLogger.shared.log("[GapBackfill] 取数完成：补齐 \(gapFiles) 只 / \(outBars.count) 行"
            + "（1x \(ratio1) / 100x \(ratio100) / 指数折算 \(ratio10000) · 最新 \(upToDate) · 停牌 \(suspended)"
            + " · 无重叠校准日 \(anchorMissing) · 口径异常 \(anomalyCount) · 失败 \(failureCount)）"
            + "，覆盖 \(dateSpan)，耗时 \(String(format: "%.1fs", seconds))")

        guard !outBars.isEmpty else {
            state = .ok
            statusText = "无缺口行可补"
            verdictText = "无缺口：待补 \(total) 只均无新行（最新 \(upToDate) · 停牌 \(suspended)）"
            DebugLogger.shared.log("[GapBackfill] 无缺口行可写，结束")
            return
        }

        // ④ 写入增量库（(file,date) UPSERT：旧云分片的「手」值就地覆盖为「股」→ 断崖消除）
        LiveDataStore.shared.upsertDaily(metas: outMetas, bars: outBars,
                                        updatedAt: Self.utcMidnightEpoch(today)) { [weak self] merge in
            guard let self = self else { return }
            guard merge.ok else {
                self.state = .failed
                self.statusText = "写入增量库失败"
                self.verdictText = "失败：写入增量库 \(merge.message)"
                DebugLogger.shared.log("[GapBackfill] 写入增量库失败 \(merge.message)")
                return
            }
            DebugLogger.shared.log("[GapBackfill] 写入增量库成功 \(merge.message)")
            // ⑥ 缺口区间的周/月/季/年线：日线落库后，按「主库最新日所在周期桶 → 今日」逐桶重算
            //    （日线补齐只让日线图连续；周期视图还得从新日线聚合，否则周/月/季/年仍是洞）
            self.rebuildPeriods(metas: metas, mainLatest: mainLatest, today: today) { period in
                let periodText = period.ok
                    ? " · 周 \(period.weeklyRows) / 月 \(period.monthlyRows)"
                        + " / 季 \(period.quarterlyRows) / 年 \(period.yearlyRows) 行"
                    : " · 周/月/季/年线聚合失败"
                DebugLogger.shared.log("[GapBackfill] 周期聚合：\(period.message)")
                lines.append("周期聚合：" + period.message)
                guard period.ok else {
                    self.state = .failed
                    self.statusText = "周/月/季/年线聚合失败"
                    self.fetchText = "补齐 \(gapFiles) 只 / \(outBars.count) 行（新写入 \(merge.dailyRows) 行）· \(dateSpan)"
                    self.verdictText = "失败：周期聚合 \(period.message)"
                    self.detailLines = lines
                    LiveDataStore.shared.reloadAsync { _ in }
                    return
                }
                // ⑦ 自动合并入主库：五张表（日/周/月/季/年）+ meta.last_date，单事务 UPSERT；
                //    合并器内部含「裁剪增量（保留最新 3 个交易日）→ 热刷新 → 通知全 App 重查」，
                //    其 completion 在热刷新之后回调，此处无需再刷
                self.publish { self.statusText = "合并入主库…" }
                MainDBMerger.shared.mergeIncrementIntoMainDB { merged in
                    DebugLogger.shared.log("[GapBackfill] 自动合并主库：\(merged.ok ? "成功" : "失败") \(merged.message)")
                    lines.append("自动合并主库：" + merged.message)
                    self.state = .ok
                    self.statusText = merged.ok ? "缺口已补（含周/月/季/年线，已合并主库）" : "缺口已补，但合并主库失败"
                    self.fetchText = "补齐 \(gapFiles) 只 / \(outBars.count) 行（新写入 \(merge.dailyRows) 行）· \(dateSpan)"
                    self.verdictText = "缺口已补：\(gapFiles) 只 / \(outBars.count) 行 · 新写入 \(merge.dailyRows) 行"
                        + " · 量纲 1x \(ratio1) / 100x \(ratio100) / 指数折算 \(ratio10000)"
                        + " · 仅补价格 \(priceOnlyCount) · 东财兜底 \(emCount)"
                        + " · 口径异常 \(anomalyCount) · 取数失败 \(failureCount)"
                        + " · 未补（无重叠校准日 \(anchorMissing) · 停牌 \(suspended)）"
                        + periodText
                        + " · " + (merged.ok ? "已合并主库" : "合并主库失败：\(merged.message)")
                        + " · 覆盖 \(dateSpan)"
                    self.detailLines = lines
                }
            }
        }
    }

    /// 缺口区间的周/月/季/年线：读主库「日线（周/月锚桶窗口）」+「季/年当期基期 bar」→ 逐桶聚合。
    /// 季/年**刻意不读整年日线**（160 个交易日 × 3600 只 ≈ 57 万行）：主库那根当期 bar 本身就是
    /// 「该周期起始日 → `mainLatest`」的聚合快照，叠加缺口日线即可（口径同 `mergePeriodBar`）。
    /// 主库数据必须先在 `DatabaseManager.dbQueue` 上读完再进 LiveDataStore 队列（禁止跨队列嵌套）。
    private func rebuildPeriods(metas: [MetaItem], mainLatest: Int, today: Int,
                                completion: @escaping (LiveMergeResult) -> Void) {
        publish { self.statusText = "聚合周/月/季/年线…" }
        let weekAnchor = KlinePeriod.periodDateRange(.weekly, date: mainLatest).0
        let monthAnchor = KlinePeriod.periodDateRange(.monthly, date: mainLatest).0
        let quarterAnchor = KlinePeriod.periodDateRange(.quarterly, date: mainLatest).0
        let yearAnchor = KlinePeriod.periodDateRange(.yearly, date: mainLatest).0
        let dailyFrom = Swift.min(weekAnchor, monthAnchor)
        var metaIdByFile: [String: Int] = [:]
        for m in metas { metaIdByFile[m.file] = m.id }
        DatabaseManager.shared.performOnDBQueue({ db -> ([String: [KlineItem]], [String: [String: KlineItem]]) in
            let daily = DatabaseManager.readMainDaily(db: db, metaIdByFile: metaIdByFile,
                                                      fromDate: dailyFrom, toDate: mainLatest)
            var bases: [String: [String: KlineItem]] = [:]
            for (period, table, start) in [("quarterly", "quarterly", quarterAnchor),
                                           ("yearly", "yearly", yearAnchor)] {
                bases[period] = DatabaseManager.readMainCurrentPeriodBar(db: db, table: table,
                                                                         metaIdByFile: metaIdByFile,
                                                                         fromDate: start)
            }
            return (daily, bases)
        }, completion: { [weak self] (mainDaily, bases) in
            guard let self = self else { return }
            DebugLogger.shared.log("[GapBackfill] 周期聚合：主库日线 [\(dailyFrom), \(mainLatest)] 覆盖 \(mainDaily.count) 只"
                + " · 当期基期 bar 季 \(bases["quarterly"]?.count ?? 0) 只 / 年 \(bases["yearly"]?.count ?? 0) 只")
            LiveDataStore.shared.rebuildGapPeriods(mainLatest: mainLatest, referenceDate: today,
                                                   mainDaily: mainDaily, mainPeriodBars: bases,
                                                   completion: completion)
        })
    }

    /// 没有任何可补作业（全部已最新 / 不可映射）
    private func finishEmpty(mainLatest: Int, today: Int, unmappable: Int, noBaseline: Int) {
        state = .ok
        statusText = "无缺口行可补"
        verdictText = "无缺口：主库 \(mainLatest) → 今日 \(today) 无可补标的"
            + "（不可映射 \(unmappable) · 基准行缺 \(noBaseline)）"
        DebugLogger.shared.log("[GapBackfill] 无可补作业，结束")
    }

    // MARK: - 单只取数与自校准（并发执行）

    private func fetchGap(job: GapJob, mainLatest: Int, today: Int, session: URLSession) -> (GapOutcome, Bool) {
        let count = Self.barsCount(from: mainLatest, to: today)
        // ⓪ 主源腾讯；失败/空 → 东财兜底（62#/102# 定制段 930/931/932/987 等只有东财有）
        var (fetched, why) = fetchSourceBars(item: job.item, from: mainLatest, to: today,
                                             count: count, session: session)
        var usedEM = false
        if fetched == nil || fetched?.isEmpty == true {
            let (emRows, whyEM) = fetchEastmoneyBars(item: job.item, from: mainLatest, to: today,
                                                     session: session)
            if let em = emRows, !em.isEmpty {
                fetched = em
                usedEM = true
            } else {
                why = "\(why)｜东财:\(whyEM)"
            }
        }
        guard let rows = fetched, !rows.isEmpty else { return (.failed(why), false) }
        // 基准当天那行（自校准锚点）；源侧没有该行 = 长期停牌、两边无重叠可校准日 → 跳过
        guard let anchor = rows.first(where: { $0.date == mainLatest }) else {
            return (.anchorMissing, usedEM)
        }
        let b = job.base
        // ① 价格必须逐字段相等（口径不同：复权 / 代码错配 / 接口换版 → 绝不写库）
        guard Self.near(b.open, anchor.open), Self.near(b.high, anchor.high),
              Self.near(b.low, anchor.low), Self.near(b.close, anchor.close) else {
            return (.anomaly(String(format: "价格不符 主库 %.3f/%.3f/%.3f/%.3f 源 %.3f/%.3f/%.3f/%.3f",
                                    b.open, b.high, b.low, b.close,
                                    anchor.open, anchor.high, anchor.low, anchor.close)), usedEM)
        }
        // ② 主库锚点无量额口径（如 MSCI 定制指数官方不发布）→ **只补价格**，vol/amo 写 0 与主库一致
        if b.volume <= 0 {
            let bars = rows.filter { $0.date > mainLatest }.map {
                GapBar(date: $0.date, open: $0.open, high: $0.high, low: $0.low, close: $0.close,
                       vol: 0, amo: 0)
            }
            return bars.isEmpty ? (.upToDate, usedEM) : (.gap(bars: bars, volRatio: 1, priceOnly: true), usedEM)
        }
        // 源侧锚点量为 0 → 真实停牌，无从折算
        guard anchor.vol > 0 else { return (.suspended, usedEM) }
        // ③ 量比吸附到 1 / 100 / 0.0001（中证指数）/ 1e-7（恒生系）
        let rawVol = b.volume / anchor.vol
        let volRatio: Double
        if Self.volRatioBand1.contains(rawVol) {
            volRatio = 1
        } else if Self.volRatioBand100.contains(rawVol) {
            volRatio = 100
        } else if Self.volRatioBand0_0001.contains(rawVol) {
            volRatio = 0.0001
        } else if Self.volRatioBand1e_7.contains(rawVol) {
            volRatio = 1e-7
        } else {
            return (.anomaly(String(format: "量比异常 %.3g（既不像 1/100/1e-4/1e-7）", rawVol)), usedEM)
        }
        // ④ 额比哨兵：rawAmo = 主库 / (源[万]×10000)。个股/普通指数 ≈1（主库元）；
        //    指数折算类（中证/恒生，volRatio<1）主库额 = 源×0.01（PC 实测精确）→ rawAmo ≈1e-6
        if anchor.amo > 0, b.turnover > 0 {
            let expected = volRatio >= 1 ? 1.0 : 1e-6
            let rawAmo = b.turnover / (anchor.amo * 10000)
            if abs(rawAmo - expected) / expected > Self.amoRatioTolerance {
                return (.anomaly(String(format: "额比异常 %.4g", rawAmo)), usedEM)
            }
        }
        // ⑤ 生成缺口行：量/额折算到**主库口径**。额：个股=源(万)×10000；指数类=源(万)×0.01。
        //    量：指数折算类主库是**整数舍入**口径 → round 对齐（个股 100x 精确整数，round 无损）
        let amoScale: Double = volRatio >= 1 ? 10_000 : 0.01
        let bars = rows.filter { $0.date > mainLatest }.map {
            GapBar(date: $0.date, open: $0.open, high: $0.high, low: $0.low, close: $0.close,
                   vol: volRatio >= 1 ? $0.vol * volRatio : ($0.vol * volRatio).rounded(),
                   amo: $0.amo * amoScale)
        }
        return bars.isEmpty ? (.upToDate, usedEM) : (.gap(bars: bars, volRatio: volRatio, priceOnly: false), usedEM)
    }

    // MARK: - 腾讯 newfqkline 取数

    /// 缺口需要的根数：**自然日差 + 余量**（交易日 ≤ 自然日，余量 10 防长假边界），
    /// 封顶 `maxBars`。接口恒返回「最近 N 根」（起始日会被向前扩，见文件头），
    /// 只要 N ≥ 缺口交易日数 + 1（含锚点日）即正确；若仍不够会缺锚点 → `anchorMissing`
    /// 安全跳过（宁可少补，绝不写错值）。PC 实测 45 根响应 5.8KB vs 320 根 31.6KB（-82%），
    /// 弱网（热点）下直接缩短传输时间。
    static func barsCount(from: Int, to: Int) -> Int {
        guard from > 0, to >= from else { return maxBars }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        func date(_ v: Int) -> Date? {
            var comps = DateComponents()
            comps.year = v / 10000
            comps.month = (v / 100) % 100
            comps.day = v % 100
            return cal.date(from: comps)
        }
        let days: Int
        if let d1 = date(from), let d2 = date(to) {
            days = cal.dateComponents([.day], from: d1, to: d2).day ?? (to - from)
        } else {
            days = to - from
        }
        return Swift.min(maxBars, days + barsMargin)
    }

    /// 取某只 `[from, to]` 的日线（**不复权**，与主库同口径）。
    /// 返回 `(K线, 失败原因)`：成功时原因为空串；请求 / 解析 / 接口报错都给出可读原因
    private func fetchSourceBars(item: ProbeItem, from: Int, to: Int, count: Int,
                                 session: URLSession) -> ([SourceBar]?, String) {
        // param 必须 6 段：<代码>,day,<起>,<止>,<根数>,bfq（bfq = 不复权；缺这段接口判 bad params）
        let param = "\(item.marketCode),day,\(Self.ymd(from)),\(Self.ymd(to)),\(count),bfq"
        guard let encoded = param.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: Self.klineURLPrefix + encoded) else {
            return (nil, "URL 非法")
        }
        guard let data = getData(url, session) else { return (nil, "HTTP 失败/超时") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (nil, "响应非 JSON")
        }
        if let code = (root["code"] as? NSNumber)?.intValue, code != 0 {
            return (nil, "接口 code=\(code) \(root["msg"] as? String ?? "")")
        }
        guard let container = (root["data"] as? [String: Any])?[item.marketCode] as? [String: Any] else {
            return (nil, "响应无 data.\(item.marketCode)")
        }
        // `bfq` → `day`；万一接口换版返回复权键，兜底取任一 *day（价格会对不上，由自校准拦下）
        var raw: [[Any]]? = container["day"] as? [[Any]]
        if raw == nil { raw = container["qfqday"] as? [[Any]] }
        if raw == nil {
            for (key, value) in container where key.hasSuffix("day") {
                if let arr = value as? [[Any]] { raw = arr; break }
            }
        }
        guard let rows = raw else { return (nil, "响应无 K 线数组") }
        var out: [SourceBar] = []
        out.reserveCapacity(rows.count)
        for r in rows {
            // 字段顺序：开-收-高-低（见文件头，写错即静默错值）
            guard r.count >= 9,
                  let ds = r[0] as? String,
                  let date = Int(ds.replacingOccurrences(of: "-", with: "")),
                  let open = Self.num(r[1]), let close = Self.num(r[2]),
                  let high = Self.num(r[3]), let low = Self.num(r[4]),
                  let vol = Self.num(r[5]), let amo = Self.num(r[8]) else { continue }
            out.append(SourceBar(date: date, open: open, high: high, low: low,
                                 close: close, vol: vol, amo: amo))
        }
        return (out, "")
    }

    /// 东财 push2his 日线（**第二源**）：62#/102# 定制段（930/931/932/950/987/970 等）只有东财有。
    /// fields2=f51..f57 → 日期,开,收,高,低,量(手),额(元)——开收高低顺序与腾讯一致（PC 校准确认）；
    /// amo 元→万元 折算，与腾讯 SourceBar 同口径（额比哨兵/写库逻辑共用）。
    /// 量纲经 PC 对拍与腾讯同构（中证类量比 1e-4、额比 1e-6），自校准窗口原样适用。
    private func fetchEastmoneyBars(item: ProbeItem, from: Int, to: Int,
                                    session: URLSession) -> ([SourceBar]?, String) {
        let secids = item.emSecids
        guard !secids.isEmpty else { return (nil, "无东财候选") }
        var lastWhy = "无候选"
        for secid in secids {
            let urlStr = "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=\(secid)"
                + "&fields1=f1,f2,f3&fields2=f51,f52,f53,f54,f55,f56,f57&klt=101&fqt=0"
                + "&beg=\(from)&end=\(to)"
            guard let url = URL(string: urlStr) else { lastWhy = "URL 非法"; continue }
            guard let data = getData(url, session) else { lastWhy = "HTTP 失败/超时"; continue }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                lastWhy = "响应非 JSON"; continue
            }
            guard let d = root["data"] as? [String: Any],
                  let lines = d["klines"] as? [String], !lines.isEmpty else {
                lastWhy = "无 klines"; continue
            }
            var out: [SourceBar] = []
            out.reserveCapacity(lines.count)
            for line in lines {
                let p = line.split(separator: ",").map(String.init)
                guard p.count >= 7,
                      let date = Int(p[0].replacingOccurrences(of: "-", with: "")),
                      let open = Self.num(p[1]), let close = Self.num(p[2]),
                      let high = Self.num(p[3]), let low = Self.num(p[4]),
                      let vol = Self.num(p[5]), let amo = Self.num(p[6]) else { continue }
                out.append(SourceBar(date: date, open: open, high: high, low: low,
                                     close: close, vol: vol, amo: amo / 10000))
            }
            if !out.isEmpty { return (out, "") }
            lastWhy = "klines 全部解析失败"
        }
        return (nil, lastWhy)
    }

    /// 同步 GET（并发调用，各自等待）；失败落日志并返回 nil。
    /// 失败短退避重试 `maxAttempts` 次（服务端偶发掐 h2 连接 / 限流都可自愈）
    private func getData(_ url: URL, _ session: URLSession) -> Data? {
        for attempt in 1...Self.maxAttempts {
            if let data = getDataOnce(url, session) { return data }
            if attempt < Self.maxAttempts {
                DebugLogger.shared.log("[GapBackfill] GET 失败，退避重试(\(attempt)) \(url.absoluteString)")
                Thread.sleep(forTimeInterval: Self.retryDelay * Double(attempt))
            }
        }
        return nil
    }

    private func getDataOnce(_ url: URL, _ session: URLSession) -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = Self.requestTimeout
        req.setValue(DirectQuoteProbe.userAgent, forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        session.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            guard error == nil else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code), let data = data else { return }
            out = data
        }.resume()
        if sem.wait(timeout: .now() + Self.requestTimeout + 5) == .timedOut { return nil }
        return out
    }

    // MARK: - 工具

    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    /// 相对容差比较（价格逐字段相等判定）
    private static func near(_ a: Double, _ b: Double) -> Bool {
        let scale = max(abs(a), abs(b), 1)
        return abs(a - b) / scale <= priceTolerance
    }

    /// JSON 里的数字（可能是 NSNumber 也可能是字符串）
    private static func num(_ any: Any) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// `20260828` → `2026-08-28`
    private static func ymd(_ date8: Int) -> String {
        let s = String(format: "%08d", date8)
        return "\(s.prefix(4))-\(s.dropFirst(4).prefix(2))-\(s.dropFirst(6))"
    }

    /// 与 `WatchlistSyncManager.utcMidnightEpoch` 同口径（live_meta.updated_at）
    private static func utcMidnightEpoch(_ date8: Int) -> Int {
        guard date8 > 0 else { return 0 }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd"
        guard let d = f.date(from: String(date8)) else { return 0 }
        return Int(d.timeIntervalSince1970)
    }
}
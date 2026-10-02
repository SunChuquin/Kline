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
//    ③ 逐只直连腾讯历史K线 `newfqkline` 拉 `[mainLatest, today]` 的日线（并发 12 路）；
//    ④ 用基准当天那一行做**自校准**（价格必须逐字段相等；量比吸附到 1 或 100；额比须 ≈1），
//       任一条不符 → 判为口径异常并**丢弃该只**（宁可少补，绝不静默写错值）；
//    ⑤ 生成 `date > mainLatest` 的缺口行（量按自校准系数折算到**主库口径**），
//       经 `LiveDataStore.upsertDaily` 写入 `tdx_live.db`（`(file,date)` UPSERT）
//       → 查询层「live 覆盖 main」自动生效，日线图立刻连续。
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
    /// 有缺口行（含自校准系数，供汇总统计量纲分布）
    case gap(bars: [GapBar], volRatio: Double)
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

/// 补缺口（**App 直连腾讯历史K线，自行把主库最新日 → 今天的日线补齐**）
final class GapBackfill: ObservableObject {
    static let shared = GapBackfill()

    enum State { case idle, running, ok, failed }

    // MARK: 常量

    /// 腾讯历史K线（带成交额）：`param=<marketCode>,day,<起>,<止>,<根数>,bfq`
    /// ⚠️ 末尾 `bfq` 不可省（= 不复权，与主库口径一致）；省略第 6 段会被接口判 `bad params`
    static let klineURLPrefix = "https://web.ifzq.gtimg.cn/appstock/app/newfqkline/get?param="
    /// 并发路数（逐只请求；全市场 3600 只约 1~3 分钟）
    static let concurrency = 12
    static let requestTimeout: TimeInterval = 20
    /// 每只请求的最大根数（实测 320 有效；足够从今日回溯到主库最新日）
    static let maxBars = 320
    /// 价格相对容差（主库与源应逐字段相等，只留浮点余量）
    static let priceTolerance = 1e-5
    /// 量比吸附：落在这两个窗口内才认（1 → [0.5, 2]；100 → [50, 200]），窗口外判口径异常。
    /// 窗口刻意开得比「±2%」宽：实测深市指数（399006/399102）源与主库本身就有 +4%
    /// 的统计口径差（1.0403），它离 100 十万八千里，必须吸附到 1；
    /// 而「既不像 1 也不像 100」的比值仍会被拦下（宁可少补，绝不写错量纲）。
    static let volRatioBand1: ClosedRange<Double> = 0.5...2
    static let volRatioBand100: ClosedRange<Double> = 50...200
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
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

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
        var processed = 0
        DispatchQueue.concurrentPerform(iterations: total) { idx in
            gate.wait()
            let outcome = self.fetchGap(job: jobs[idx], mainLatest: mainLatest, today: today)
            gate.signal()
            lock.lock()
            outcomes[idx] = outcome
            processed += 1
            let done = processed
            lock.unlock()
            if done % 200 == 0 {
                self.publish { self.statusText = "取数中… \(done)/\(total)" }
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
        var gapDates = Set<Int>()
        for (idx, outcome) in outcomes.enumerated() {
            guard let outcome = outcome else { continue }
            let m = jobs[idx].meta
            switch outcome {
            case .gap(let bars, let volRatio):
                gapFiles += 1
                if volRatio > 10 { ratio100 += 1 } else { ratio1 += 1 }
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
        lines.append(String(format: "自校准量纲：1x %d 只 / 100x %d 只；口径异常 %d 只 · 取数失败 %d 只"
                                  + " · 无重叠校准日 %d 只 · 停牌 %d 只 · 已最新 %d 只（%.1fs）",
                            ratio1, ratio100, anomalyCount, failureCount,
                            anchorMissing, suspended, upToDate, seconds))
        for s in anomalies { lines.append("口径异常：\(s)") }
        for s in failures { lines.append("取数失败：\(s)") }

        publish {
            self.fetchText = "补齐 \(gapFiles) 只 / \(outBars.count) 行 · \(dateSpan)"
            self.detailLines = lines
        }
        DebugLogger.shared.log("[GapBackfill] 取数完成：补齐 \(gapFiles) 只 / \(outBars.count) 行"
            + "（1x \(ratio1) / 100x \(ratio100) · 最新 \(upToDate) · 停牌 \(suspended)"
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
            self.state = .ok
            self.statusText = "缺口已补"
            self.fetchText = "补齐 \(gapFiles) 只 / \(outBars.count) 行（新写入 \(merge.dailyRows) 行）· \(dateSpan)"
            self.verdictText = "缺口已补：\(gapFiles) 只 / \(outBars.count) 行 · 新写入 \(merge.dailyRows) 行"
                + " · 量纲 1x \(ratio1) / 100x \(ratio100)"
                + " · 口径异常 \(anomalyCount) · 取数失败 \(failureCount)"
                + " · 未补（无重叠校准日 \(anchorMissing) · 停牌 \(suspended)）"
                + " · 覆盖 \(dateSpan)"
            // 热刷新：让查询层与图表立刻看到补入的行
            LiveDataStore.shared.reloadAsync { summary in
                DebugLogger.shared.log("[GapBackfill] 热刷新完成 可用=\(summary.isAvailable)"
                    + " 内容变化=\(summary.contentChanged) 最新=\(summary.latestDateAfter)")
            }
        }
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

    private func fetchGap(job: GapJob, mainLatest: Int, today: Int) -> GapOutcome {
        let (fetched, why) = fetchSourceBars(item: job.item, from: mainLatest, to: today)
        guard let rows = fetched else { return .failed(why) }
        guard !rows.isEmpty else { return .failed("接口返回 0 根") }
        // 基准当天那行（自校准锚点）；源侧没有该行 = 长期停牌、两边无重叠可校准日 → 跳过
        guard let anchor = rows.first(where: { $0.date == mainLatest }) else {
            return .anchorMissing
        }
        let b = job.base
        // ① 价格必须逐字段相等（口径不同：复权 / 代码错配 / 接口换版 → 绝不写库）
        guard Self.near(b.open, anchor.open), Self.near(b.high, anchor.high),
              Self.near(b.low, anchor.low), Self.near(b.close, anchor.close) else {
            return .anomaly(String(format: "价格不符 主库 %.3f/%.3f/%.3f/%.3f 源 %.3f/%.3f/%.3f/%.3f",
                                   b.open, b.high, b.low, b.close,
                                   anchor.open, anchor.high, anchor.low, anchor.close))
        }
        // ② 量比吸附到 1 或 100（主库个股=股 / 指数=手；接口恒为手）
        guard anchor.vol > 0, b.volume > 0 else { return .suspended }
        let rawVol = b.volume / anchor.vol
        let volRatio: Double
        if Self.volRatioBand1.contains(rawVol) {
            volRatio = 1
        } else if Self.volRatioBand100.contains(rawVol) {
            volRatio = 100
        } else {
            return .anomaly(String(format: "量比异常 %.4f（既不像 1 也不像 100）", rawVol))
        }
        // ③ 额比须 ≈1（主库元 ÷ (接口万元 × 10000)）；主库额为 0 时跳过该校验
        if anchor.amo > 0, b.turnover > 0 {
            let rawAmo = b.turnover / (anchor.amo * 10000)
            if abs(rawAmo - 1) > Self.amoRatioTolerance {
                return .anomaly(String(format: "额比异常 %.4f", rawAmo))
            }
        }
        // ④ 生成缺口行：date > mainLatest，量折算到主库口径，额用真实万元 × 10000
        let bars = rows.filter { $0.date > mainLatest }.map {
            GapBar(date: $0.date, open: $0.open, high: $0.high, low: $0.low, close: $0.close,
                   vol: $0.vol * volRatio, amo: $0.amo * 10000)
        }
        return bars.isEmpty ? .upToDate : .gap(bars: bars, volRatio: volRatio)
    }

    // MARK: - 腾讯 newfqkline 取数

    /// 取某只 `[from, to]` 的日线（**不复权**，与主库同口径）。
    /// 返回 `(K线, 失败原因)`：成功时原因为空串；请求 / 解析 / 接口报错都给出可读原因
    private func fetchSourceBars(item: ProbeItem, from: Int, to: Int) -> ([SourceBar]?, String) {
        // param 必须 6 段：<代码>,day,<起>,<止>,<根数>,bfq（bfq = 不复权；缺这段接口判 bad params）
        let param = "\(item.marketCode),day,\(Self.ymd(from)),\(Self.ymd(to)),\(Self.maxBars),bfq"
        guard let encoded = param.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: Self.klineURLPrefix + encoded) else {
            return (nil, "URL 非法")
        }
        guard let data = getData(url) else { return (nil, "HTTP 失败/超时") }
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

    /// 同步 GET（并发调用，各自等待）；失败落日志并返回 nil。
    /// 12 路猛打会被腾讯瞬时限流 → 失败短退避重试 `maxAttempts` 次
    private func getData(_ url: URL) -> Data? {
        for attempt in 1...Self.maxAttempts {
            if let data = getDataOnce(url) { return data }
            if attempt < Self.maxAttempts {
                DebugLogger.shared.log("[GapBackfill] GET 失败，退避重试(\(attempt)) \(url.absoluteString)")
                Thread.sleep(forTimeInterval: Self.retryDelay * Double(attempt))
            }
        }
        return nil
    }

    private func getDataOnce(_ url: URL) -> Data? {
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
//
//  DirectQuoteProbe.swift
//  Kline
//
//  【仅调试用 PoC · 不参与任何同步流程 · 不写库 · 不改配置】
//
//  目的：验证「App 设备侧直连行情源（腾讯 / 新浪）」取回的当日K线，
//  与云端 CNB 分片（`bucket_<id>.db` 的 `bkt_daily` 表）**逐只逐字段对拍**，
//  先证明量纲（成交量「手/股」）与数值零偏差，再决定是否让 App 全市场直连、下线 CNB。
//
//  取数口径与 PC 端 `cloud/scripts/live_db_builder.py` **逐条对齐**（改这里前先读那边）：
//   - 腾讯 `qt.gtimg.cn/q=`        ≤100/批，GBK，需 Referer；
//     `[3]`收 `[5]`开 `[33]`高 `[34]`低 `[6]`量(手) `[35].split("/")[2]`额 `[30]`时间戳 YYYYMMDDHHMMSS
//   - 新浪 `hq.sinajs.cn/list=`    ≤300/批，GBK，需 Referer；
//     `[1]`开 `[3]`收 `[4]`高 `[5]`低 `[8]`量(股) `[9]`额(元) `[30]`日期 YYYY-MM-DD
//   （同花顺逐只取数太慢，「全市场直连」不可行，已从源链与对拍中移除。）
//
//  量纲（**写错任何一条都是静默 100 倍错误**；分片 `bkt_daily.vol` 存的是**腾讯口径 = 手**）：
//   ① **腾讯 `[6]` 本来就是「手」**，是各源对齐的基准 → **原样保留，永不 ÷100**；
//   ② **新浪 `[8]` 报「股」** → ÷100 再**四舍五入**（实测腾讯用四舍五入而非截断：
//      300750 新浪 29699471/100 = 296994.71 → 腾讯 296995）；
//   ③ 例外（原样不除）：科创板 688xxx（腾讯/新浪都报股）、沪市指数（新浪按上交所口径报手）。
//
//  2026-10-02 实测（分片 bucket_20726 = 20260930，可比 3312 只）：
//   腾讯 3312/3312 原始量与分片**逐只全等**、价格零差异 → ①正确；
//   新浪 ÷100 后 3307 只全等（另 5 只为停牌：整行 0，按未命中处理，同 PC 端）。
//
//  基准：`TdxSyncConfig.shared.sourceURLs[0]` → `<base>/live/manifest.json` → 最新分片
//        `<base>/live/bucket_<id>.db` → `bkt_daily(file,date,open,high,low,close,vol,amo)`
//

import Foundation
import Combine
import SQLite3

// MARK: - 探针内部口径

/// 一支标的的当日一根K线（探针内部口径，非业务模型）
struct DirectProbeQuote {
    var date: Int
    var open: Double
    var high: Double
    var low: Double
    var close: Double
    var vol: Double
    var amo: Double
}

/// 单个源的对拍统计
struct DirectProbeSourceStat {
    var name = ""
    /// 参与对拍的 file 数（有基准行、且可映射到该源）
    var requested = 0
    /// 命中数（取到且可解析）
    var hit = 0
    /// 缺失数（请求失败 / 接口无该标的）
    var missing = 0
    var missingSample: [String] = []
    /// 交易日与基准不一致数
    var dateMismatch = 0
    /// 开/高/低/收 任一不一致的标的数
    var priceMismatch = 0
    var priceMismatchSample: [String] = []
    /// 量比 ≈ 1
    var volSame = 0
    /// 量比 ≈ 100 或 ≈ 1/100 —— **量纲错位的铁证**
    var volScaled = 0
    /// 量比既非 1 也非 100
    var volOther = 0
    var volOtherSample: [String] = []
    /// 成交额最大相对偏差
    var amoMaxRel: Double = 0
    var amoMaxRelFile = "-"
    /// 取数耗时（秒）
    var seconds: Double = 0

    /// 一句话摘要（UI / 日志共用）
    var summary: String {
        let s = String(format: "命中 %d/%d · 缺 %d · 量1x %d / 量100x %d / 量其他 %d",
                       hit, requested, missing, volSame, volScaled, volOther)
        let t = String(format: " · 价异 %d · 额偏差 %.4f%% · %.1fs",
                       priceMismatch, amoMaxRel * 100, seconds)
        return s + t
    }
}

// MARK: - 探针

/// 直连源链对拍探针（**仅调试用**）
final class DirectQuoteProbe: ObservableObject {
    static let shared = DirectQuoteProbe()

    enum State { case idle, running, ok, failed }

    /// 源侧成交量的量纲口径（决定要不要 ÷100 换成「手」）
    enum VolUnit {
        /// 源本来就报「手」= 分片口径（**腾讯 `[6]`**，是各源对齐的基准）→ 原样
        case hand
        /// 源报「股」→ ÷100 四舍五入换手（**新浪 `[8]`**）；例外见 `ProbeItem.volIsRaw`
        case share
    }

    // MARK: 常量（严格照抄 PC 端 live_db_builder.py）

    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    static let tencentBatch = 100
    static let sinaBatch = 300
    static let requestTimeout: TimeInterval = 20

    static let tencentURLPrefix = "https://qt.gtimg.cn/q="
    static let tencentReferer = "https://gu.qq.com/"
    static let sinaURLPrefix = "https://hq.sinajs.cn/list="
    static let sinaReferer = "https://finance.sina.com.cn/"

    // MARK: 对外只读状态（一律在主线程发布）

    @Published private(set) var state: State = .idle
    @Published private(set) var statusText = "尚未运行"
    @Published private(set) var baselineText = "—"
    @Published private(set) var tencentText = "—"
    @Published private(set) var sinaText = "—"
    /// 结论一句话（UI 断言锚点：含「量纲零偏差」= 通过）
    @Published private(set) var verdictText = "—"
    /// 不一致明细（最多若干行，逐条列出）
    @Published private(set) var detailLines: [String] = []

    var isRunning: Bool { state == .running }

    // MARK: 内部

    /// 网络与解析工作队列（串行；同花顺内部再并发）
    private let queue = DispatchQueue(label: "com.sunck.kline.directprobe")
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
        // 入口无条件落日志：区分「按钮没点到」与「点到了但早退」（UA 测试排障用）
        DebugLogger.shared.log("[DirectProbe] run() 入口 state=\(state) meta=\(DatabaseManager.shared.metaList.count)")
        guard state != .running else {
            DebugLogger.shared.log("[DirectProbe] 已在运行，忽略本次点击")
            return
        }
        // metaList 在主线程读取（DatabaseManager 约定）
        let entries = DatabaseManager.shared.metaList.map { (file: $0.file, type: $0.type) }
        guard !entries.isEmpty else {
            DebugLogger.shared.log("[DirectProbe] metaList 为空，中止（等待主库打开）")
            state = .failed
            statusText = "主库 metaList 为空（等待主库打开）"
            verdictText = "失败：主库 metaList 为空"
            return
        }
        let baseURL = TdxSyncConfig.shared.sourceURLs.first
        state = .running
        statusText = "准备中…（清单 \(entries.count) 只）"
        baselineText = "—"
        tencentText = "—"
        sinaText = "—"
        verdictText = "—"
        detailLines = []
        DebugLogger.shared.log("[DirectProbe] 开始对拍：清单 \(entries.count) 只，基准源 \(baseURL ?? "-")")

        queue.async { [weak self] in
            guard let self = self else { return }
            self.perform(entries: entries, baseURL: baseURL)
        }
    }

    // MARK: - 主流程（只在 queue 上）

    private func perform(entries: [(file: String, type: String)], baseURL: String?) {
        let t0 = Date()

        // ① 基准：CNB 最新分片
        guard let base = Self.resolveBase(baseURL) else {
            finishFailed("数据源地址非法：\(baseURL ?? "无")")
            return
        }
        guard let manifestData = getData(base.appendingPathComponent("manifest.json")) else {
            finishFailed("取 manifest 失败：\(base.absoluteString)/manifest.json")
            return
        }
        let manifest = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any]
        let buckets = manifest?["buckets"] as? [[String: Any]] ?? []
        let latestID = (manifest?["latest_bucket"] as? NSNumber)?.intValue
        let bucketFile = (buckets.first(where: { ($0["id"] as? NSNumber)?.intValue == latestID })
                          ?? buckets.first)?["file"] as? String
        guard let bucketFile = bucketFile else {
            finishFailed("manifest 无分片（buckets=\(buckets.count) latest=\(latestID.map(String.init) ?? "-")）")
            return
        }
        // 注意：base 由 `deletingLastPathComponent()` 得到，absoluteString 末尾**自带 `/`**，
        // 字符串拼接会得到 `…/live//bucket_x.db`（CNB 上直接 404）——必须用 appendingPathComponent
        let bucketURL = base.appendingPathComponent(bucketFile)
        guard let bucketData = getData(bucketURL) else {
            finishFailed("下载分片失败：\(bucketURL.absoluteString)")
            return
        }
        let bucketPath = NSTemporaryDirectory() + "/" + bucketFile
        guard (try? bucketData.write(to: URL(fileURLWithPath: bucketPath))) != nil else {
            finishFailed("分片落盘失败：\(bucketPath)")
            return
        }
        let baseline = readBucket(path: bucketPath)
        try? FileManager.default.removeItem(atPath: bucketPath)
        guard !baseline.isEmpty else {
            finishFailed("分片 \(bucketFile) 的 bkt_daily 为空")
            return
        }
        let baseDate = baseline.values.map { $0.date }.max() ?? 0
        DebugLogger.shared.log("[DirectProbe] 基准分片 \(bucketFile)：\(baseline.count) 行，交易日 \(baseDate)")

        // ② 可映射清单（只留 SH#/SZ#，扩展指数 27#/62#/102# 不参与）
        var items: [ProbeItem] = []
        var unmapped = 0
        for entry in entries {
            guard let item = ProbeItem(file: entry.file, type: entry.type) else {
                unmapped += 1
                continue
            }
            items.append(item)
        }
        // 只对「基准里有当日行」的标的对拍（基准没有的无法判定）
        let comparable = items.filter { baseline[$0.file]?.date == baseDate }
        let baseMissing = items.count - comparable.count

        var lines: [String] = []
        let header = "基准 \(bucketFile) · 交易日 \(baseDate) · 清单 \(entries.count) 只"
            + "（可映射 \(items.count) / 扩展指数等不可映射 \(unmapped)）"
            + " · 有基准行 \(comparable.count) · 基准缺 \(baseMissing)"
        lines.append(header)
        publish { self.baselineText = "\(bucketFile) · \(baseDate) · \(comparable.count) 只可比" }

        // ③ 腾讯（全量）
        var t1 = Date()
        let (tencentQuotes, tencentFailed) = fetchTencent(comparable)
        var stat = Self.compare(name: "腾讯", quotes: tencentQuotes, failed: tencentFailed,
                                items: comparable, baseline: baseline, volUnit: .hand)
        stat.seconds = Date().timeIntervalSince(t1)
        publish { self.tencentText = stat.summary }
        lines.append("腾讯：" + stat.summary)
        lines.append(contentsOf: Self.detailLines(stat))
        DebugLogger.shared.log("[DirectProbe] 腾讯：" + stat.summary)

        // ④ 新浪（全量）
        t1 = Date()
        let (sinaQuotes, sinaFailed) = fetchSina(comparable)
        var statSina = Self.compare(name: "新浪", quotes: sinaQuotes, failed: sinaFailed,
                                    items: comparable, baseline: baseline, volUnit: .share)
        statSina.seconds = Date().timeIntervalSince(t1)
        publish { self.sinaText = statSina.summary }
        lines.append("新浪：" + statSina.summary)
        lines.append(contentsOf: Self.detailLines(statSina))
        DebugLogger.shared.log("[DirectProbe] 新浪：" + statSina.summary)

        // ⑤ 结论：腾讯是主源，要求逐只全等；新浪只是兜底源，要求量纲不错位
        let totalScaled = stat.volScaled + statSina.volScaled
        let tencentClean = stat.hit == stat.requested && stat.priceMismatch == 0
            && stat.volOther == 0
        let tencentBad = stat.priceMismatch + stat.volOther + stat.missing
        let verdict: String
        if tencentClean && totalScaled == 0 {
            verdict = "✅ 腾讯与 CNB 分片逐只零偏差（价/量）· 新浪量纲零错位"
        } else {
            verdict = "⚠️ 量纲错位 \(totalScaled) 例 / 腾讯偏差 \(tencentBad) 例（见下）"
        }
        lines.append(verdict + String(format: " · 总耗时 %.1fs", Date().timeIntervalSince(t0)))

        let finalLines = lines
        DispatchQueue.main.async {
            self.detailLines = finalLines
            self.verdictText = verdict
            self.statusText = "完成 · " + String(format: "总耗时 %.1fs", Date().timeIntervalSince(t0))
            self.state = (tencentClean && totalScaled == 0) ? .ok : .failed
            DebugLogger.shared.log("[DirectProbe] \(verdict)")
            for line in finalLines { DebugLogger.shared.log("[DirectProbe] | " + line) }
        }
    }

    private func finishFailed(_ reason: String) {
        DebugLogger.shared.log("[DirectProbe] 失败：\(reason)")
        DispatchQueue.main.async {
            self.statusText = "失败：" + reason
            self.verdictText = "失败：" + reason
            self.state = .failed
        }
    }

    /// 主线程发布小状态
    private func publish(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    // MARK: - 基准解析

    /// `sourceURLs[0]` → 分片目录 URL（`<base>/live`）
    private static func resolveBase(_ raw: String?) -> URL? {
        guard let raw = raw, let urls = TdxSyncConfig.resolve(raw) else { return nil }
        // liveManifest = <base>/live/manifest.json → 去掉最后一段即分片目录
        return urls.liveManifest.deletingLastPathComponent()
    }

    /// 读分片的 `bkt_daily`（同一 file 多行时取 date 最大的一行）
    private func readBucket(path: String) -> [String: DirectProbeQuote] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_close(db) }
        let sql = "SELECT file, date, open, high, low, close, vol, amo FROM bkt_daily;"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(st) }
        var out: [String: DirectProbeQuote] = [:]
        while sqlite3_step(st) == SQLITE_ROW {
            guard let cFile = sqlite3_column_text(st, 0) else { continue }
            let file = String(cString: cFile)
            let q = DirectProbeQuote(date: Int(sqlite3_column_int64(st, 1)),
                                     open: sqlite3_column_double(st, 2),
                                     high: sqlite3_column_double(st, 3),
                                     low: sqlite3_column_double(st, 4),
                                     close: sqlite3_column_double(st, 5),
                                     vol: sqlite3_column_double(st, 6),
                                     amo: sqlite3_column_double(st, 7))
            if let old = out[file], old.date > q.date { continue }
            out[file] = q
        }
        return out
    }

    // MARK: - 腾讯

    /// 腾讯快照（全量、串行分批）
    private func fetchTencent(_ items: [ProbeItem]) -> ([String: DirectProbeQuote], [String]) {
        var quotes: [String: DirectProbeQuote] = [:]
        var failed: [String] = []
        for chunk in stride(from: 0, to: items.count, by: Self.tencentBatch).map({
            Array(items[$0 ..< Swift.min($0 + Self.tencentBatch, items.count)])
        }) {
            let codes = chunk.map { $0.tencentCode }
            guard let url = URL(string: Self.tencentURLPrefix + codes.joined(separator: ",")) else {
                failed.append(contentsOf: chunk.map { $0.file })
                continue
            }
            guard let data = getData(url, referer: Self.tencentReferer),
                  let text = Self.gbk(data) else {
                failed.append(contentsOf: chunk.map { $0.file })
                continue
            }
            let parsed = Self.parseTencent(text)
            for item in chunk {
                if let q = parsed[item.tencentCode] {
                    quotes[item.file] = q
                } else {
                    failed.append(item.file)
                }
            }
        }
        return (quotes, failed)
    }

    /// 腾讯响应解析：逐行 `v_sh600000="1~名称~代码~收~昨收~开~量~...";`
    private static func parseTencent(_ text: String) -> [String: DirectProbeQuote] {
        var out: [String: DirectProbeQuote] = [:]
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            var key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("v_") { key = String(key.dropFirst(2)) }
            var body = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if body.hasSuffix(";") { body.removeLast() }
            body = body.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !body.isEmpty else { continue }
            let f = body.components(separatedBy: "~")
            guard f.count > 35 else { continue }
            guard let close = Double(f[3]), let open = Double(f[5]),
                  let high = Double(f[33]), let low = Double(f[34]) else { continue }
            // 成交量与成交额：量取 [6]（本就是要对拍的「腾讯口径」），额取 [35] 的第三段
            let vol = Double(f[6]) ?? 0
            let amoParts = f[35].components(separatedBy: "/")
            let amo = amoParts.count >= 3 ? (Double(amoParts[2]) ?? 0) : 0
            guard let date = Int(f[30].prefix(8)) else { continue }
            out[key.lowercased()] = DirectProbeQuote(date: date, open: open, high: high,
                                                     low: low, close: close, vol: vol, amo: amo)
        }
        return out
    }

    // MARK: - 新浪

    /// 新浪快照（全量、串行分批）
    private func fetchSina(_ items: [ProbeItem]) -> ([String: DirectProbeQuote], [String]) {
        var quotes: [String: DirectProbeQuote] = [:]
        var failed: [String] = []
        for chunk in stride(from: 0, to: items.count, by: Self.sinaBatch).map({
            Array(items[$0 ..< Swift.min($0 + Self.sinaBatch, items.count)])
        }) {
            let codes = chunk.map { $0.sinaCode }
            guard let url = URL(string: Self.sinaURLPrefix + codes.joined(separator: ",")) else {
                failed.append(contentsOf: chunk.map { $0.file })
                continue
            }
            guard let data = getData(url, referer: Self.sinaReferer),
                  let text = Self.gbk(data) else {
                failed.append(contentsOf: chunk.map { $0.file })
                continue
            }
            let parsed = Self.parseSina(text)
            for item in chunk {
                if let q = parsed[item.sinaCode] {
                    quotes[item.file] = q
                } else {
                    failed.append(item.file)
                }
            }
        }
        return (quotes, failed)
    }

    /// 新浪响应解析：逐行 `var hq_str_sh600000="名称,开,昨收,收,高,低,...,量(股),额(元),...,日期,时间,..";`
    private static func parseSina(_ text: String) -> [String: DirectProbeQuote] {
        var out: [String: DirectProbeQuote] = [:]
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            var key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            key = key.replacingOccurrences(of: "var hq_str_", with: "")
                .trimmingCharacters(in: .whitespaces)
            var body = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if body.hasSuffix(";") { body.removeLast() }
            body = body.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let f = body.components(separatedBy: ",")
            guard f.count > 31 else { continue }
            guard let open = Double(f[1]), let close = Double(f[3]),
                  let high = Double(f[4]), let low = Double(f[5]) else { continue }
            // 停牌 / 退市整行为 0 → 跳过并计入未命中（与 PC 端 `close in (None, 0)` 一致）
            guard close != 0 else { continue }
            let raw = Double(f[8]) ?? 0
            let amo = Double(f[9]) ?? 0
            guard let date = Int(f[30].replacingOccurrences(of: "-", with: "")) else { continue }
            out[key.lowercased()] = DirectProbeQuote(date: date, open: open, high: high,
                                                     low: low, close: close, vol: raw, amo: amo)
        }
        return out
    }

    // MARK: - 对拍

    /// 与基准逐只比对（量纲先按 PC 端 `_vol_keep_raw` 规则换算）
    private static func compare(name: String, quotes: [String: DirectProbeQuote],
                                failed: [String], items: [ProbeItem],
                                baseline: [String: DirectProbeQuote],
                                volUnit: VolUnit) -> DirectProbeSourceStat {
        var stat = DirectProbeSourceStat(name: name)
        stat.requested = items.count
        let failedSet = Set(failed)
        for item in items {
            guard let base = baseline[item.file] else { continue }
            guard let q = quotes[item.file] else {
                stat.missing += 1
                if stat.missingSample.count < 5 {
                    stat.missingSample.append(item.file + (failedSet.contains(item.file) ? "(请求失败)" : "(无报价)"))
                }
                continue
            }
            stat.hit += 1
            if q.date != base.date {
                stat.dateMismatch += 1
            }
            if !near(q.open, base.open) || !near(q.high, base.high)
                || !near(q.low, base.low) || !near(q.close, base.close) {
                stat.priceMismatch += 1
                if stat.priceMismatchSample.count < 5 {
                    stat.priceMismatchSample.append("\(item.file) 基准 O/H/L/C="
                        + String(format: "%.3f/%.3f/%.3f/%.3f", base.open, base.high, base.low, base.close)
                        + " 源=" + String(format: "%.3f/%.3f/%.3f/%.3f", q.open, q.high, q.low, q.close))
                }
            }
            // 量纲：分片 vol 存的是「腾讯口径 = 手」。腾讯 [6] 本就是手 → 原样；
            // 新浪 [8] 报股 → ÷100 四舍五入（科创板 688xxx / 沪市指数例外，见 volIsRaw）
            let vol: Double = (volUnit == .hand || item.volIsRaw)
                ? q.vol : (q.vol / 100).rounded()
            if base.vol > 0 {
                let r = vol / base.vol
                if abs(r - 1) < 1e-6 {
                    stat.volSame += 1
                } else if abs(r - 100) < 0.01 || abs(r - 0.01) < 1e-5 {
                    stat.volScaled += 1
                } else {
                    stat.volOther += 1
                    if stat.volOtherSample.count < 5 {
                        stat.volOtherSample.append("\(item.file) 基准=\(Self.fmt(base.vol)) 源=\(Self.fmt(vol)) 比值=\(String(format: "%.4f", r))")
                    }
                }
            } else if vol != base.vol {
                stat.volOther += 1
            } else {
                stat.volSame += 1
            }
            let rel = abs(q.amo - base.amo) / max(abs(base.amo), 1)
            if rel > stat.amoMaxRel {
                stat.amoMaxRel = rel
                stat.amoMaxRelFile = item.file
            }
        }
        return stat
    }

    /// 明细行（最多 3 类各 2 行，避免 UI 过长）
    private static func detailLines(_ stat: DirectProbeSourceStat) -> [String] {
        var out: [String] = []
        func push(_ label: String, _ sample: [String]) {
            guard !sample.isEmpty, out.count < 6 else { return }
            out.append("\(stat.name)\(label)：" + sample.prefix(2).joined(separator: "；"))
        }
        push("价异明细", stat.priceMismatchSample)
        push("量异常明细", stat.volOtherSample)
        if stat.missing > 0 && out.count < 6 {
            out.append("\(stat.name)缺失样例：" + stat.missingSample.joined(separator: "、"))
        }
        if stat.volScaled != 0 {
            out.append("\(stat.name)量纲错位 \(stat.volScaled) 例（应为 0）")
        }
        return out
    }

    // MARK: - 工具

    private static func near(_ a: Double, _ b: Double) -> Bool {
        if a == b { return true }
        // 指数点位上千，两源在第 3 位小数上各自取整（实测 6660.910 vs 6660.909）→ 放相对容差
        let scale = max(abs(a), abs(b))
        return scale > 0 && abs(a - b) / scale <= 1e-5
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.4f", v)
    }

    /// GBK / GB18030 解码
    private static func gbk(_ data: Data) -> String? {
        let enc = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: enc))
    }

    /// 同步 GET（在后台队列调用；返回 nil = 失败）
    private func getData(_ url: URL, referer: String? = nil, timeout: TimeInterval? = nil) -> Data? {
        let limit = timeout ?? Self.requestTimeout
        var req = URLRequest(url: url, timeoutInterval: limit)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer = referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        session.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            guard error == nil else {
                DebugLogger.shared.log("[DirectProbe] GET 失败 \(url.absoluteString) err=\(error!.localizedDescription)")
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code), let data = data else {
                DebugLogger.shared.log("[DirectProbe] GET 非 2xx code=\(code) \(url.absoluteString)")
                return
            }
            out = data
        }.resume()
        if sem.wait(timeout: .now() + limit + 5) == .timedOut { return nil }
        return out
    }
}

// MARK: - 清单条目 → 各源代码

/// 一条可对拍清单（`file` + 两源代码 + 量纲口径）
struct ProbeItem {
    let file: String
    let isIndex: Bool
    /// 腾讯 / 新浪代码（`sh600000` / `sz000001`）
    let marketCode: String
    var tencentCode: String { marketCode }
    var sinaCode: String { marketCode }
    /// 源侧成交量是否**原样保留**（不做 ÷100 换手）：科创板 688xxx、沪市指数
    let volIsRaw: Bool

    /// `SH#600000` → ProbeItem；不可映射 → nil
    /// 映射规则（2026-10-03 PC 全量对拍 299 只扩展行情实测）：
    ///   · `SH#`/`SZ#` → `sh`/`sz`（上证指数伪代码 999999 → 000001）
    ///   · `12#NDX` 等纳指系 → `usNDX`（us 前缀；当前 meta 无 12#，留作扩展）
    ///   · `62#`/`102#` 的 000 段 → `sh`、399/980 段 → `sz`（深交所国证发布段；
    ///     量比精确 1e-4、额比精确 1e-6 → 由补缺口 ÷10000 窗口吸附。smartbox 实测
    ///     12 只 980 段（国证芯片 980017 等）全部对拍通过；930/931/932/950/H30 段
    ///     直接探测 0/80 无源）
    ///   · ⚠️ `27#` 恒生系**不映射**：价格虽逐字段相等，但源 vol 与主库 vol 比值 ≈1e-7
    ///     且**非精确倍数**（逐只偏差达 0.03% → 额/量语义不同，日间浮动），
    ///     按比例换算会把错误的量写进缺口行 → 宁可少补
    ///   · 其余（62#/102# 的 930/931/932/950/CN 段国证指数、42#、46# 贵金属）→ 腾讯无源，nil
    /// 兜底：错映射是**安全的**——补缺口自校准要求锚点日价格逐字段相等 + 量比吸附，对不上判异常丢弃
    init?(file: String, type: String) {
        let parts = file.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let prefix = parts[0].uppercased()
        var code = String(parts[1])
        guard !code.isEmpty else { return nil }
        // 上证指数的通达信伪代码
        if prefix == "SH" && code == "999999" { code = "000001" }
        let market: String
        switch prefix {
        case "SH": market = "sh"
        case "SZ": market = "sz"
        case "12": market = "us"                    // 纳斯达克系指数
        case "62", "102":                           // 国证/中证扩展：仅交易所发布段有源
            if code.hasPrefix("000") { market = "sh" }
            else if code.hasPrefix("399") || code.hasPrefix("980") { market = "sz" }
            else { return nil }
        default: return nil                         // 27# 恒生系（量纲不可换算）/ 42#/46# 等无源
        }
        let isIndex = type.contains("指数")
        self.file = file
        self.isIndex = isIndex
        self.marketCode = market + code
        // 688xxx（腾讯按「股」报量）与指数（量纲杂）原样保留；其余 ÷100 四舍五入
        self.volIsRaw = code.hasPrefix("688") || isIndex
    }
}
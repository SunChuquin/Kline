//
//  EastmoneyQuoteFetcher.swift
//  Kline
//
//  设备侧东财「当日K线」取数器：向公开行情接口 push2.eastmoney.com/api/qt/ulist.np/get
//  批量拉取「清单并集」标的的当日快照，折算成「file -> 当日一根K线」，供增量库写入并触发
//  条件单/预警重扫。**不依赖 PC**。
//
//  取数口径与 PC 侧已验证可用的生成端 src/live_db_builder.py **逐条对齐**（改这里前先读那边）：
//   - 批量快照 ulist.np/get，每批 ≤ 100 个 secid（ULIST_BATCH=100，约 :121）
//   - OHLC 取 f17/f15/f16/f2（开/高/低/收，**不是 OHLC 顺序**），量额取 f5/f6（约 :466-486）
//   - 交易日只由 f124（秒级 epoch）按**北京时间 UTC+8** 换算成 YYYYMMDD（约 :448-459）；
//     f124 缺失/非正数 → 该条丢弃并记日志；**绝不用本机日期/本机时区**（否则非交易日会造假日K线）
//   - 带 User-Agent（约 :108-109 的 UA 字符串，原样照抄）、失败指数退避重试（约 :413-431，
//     含首次共 4 次尝试）、单批失败只记日志不影响其他批（约 :489-512）
//
//  secid 映射（与 live_db_builder.secid_for_file 同规则，约 :301-315，+ 扩展指数覆盖表）：
//   - SH# -> 1.<code>；SZ# / BJ# -> 0.<code>；SH#999999 -> 1.000001（SPECIAL_FILE_SECID，约 :296-299）
//   - 27# / 62# / 102# 扩展行情指数 -> 查 Bundle 内 universe_secids.txt 覆盖表；
//     读不到表时**降级**为「只用前缀规则」，并记一条明确日志（不静默、不崩）
//
//  线程约定：`fetch(files:completion:)` 全流程在内部串行队列上执行，`completion` 也在该队列回调；
//  调用方需自行切回主线程更新 UI / @Published 状态。
//

import Foundation

// MARK: - 返回结构契约

/// 单只标的的当日一根K线（值口径见文件头注释）。
struct EastmoneyDailyBar {
    /// 交易日 YYYYMMDD，**来自 f124 的北京时间 UTC+8 换算**
    let date: Int
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let vol: Double
    let amo: Double
}

/// 跳过 / 失败的原因分类（逐条记录）。
enum EastmoneySkipReason {
    /// 映射不到 secid（扩展指数覆盖表缺失、前缀不支持）
    case unmappable
    /// 所属批次请求最终失败（原因另见 batchFailures）
    case batchFailed
    /// 接口正常返回但没有该 secid 的报价（停牌 / 退市 / 非交易时段）
    case noQuote
    /// OHLC 含 '-' / null（视为无效）
    case invalidValue
    /// f124 缺失 / 非正数 → 无法判定交易日，丢弃（不造假日K线）
    case missingTimestamp

    var text: String {
        switch self {
        case .unmappable: return "无secid映射"
        case .batchFailed: return "批次失败"
        case .noQuote: return "接口无报价"
        case .invalidValue: return "OHLC无效"
        case .missingTimestamp: return "f124缺失"
        }
    }
}

/// 被跳过的标的及原因。
struct EastmoneySkip {
    let file: String
    let reason: EastmoneySkipReason
    let detail: String
}

/// 单批请求最终失败（重试耗尽）。**单批失败不影响其他批**。
struct EastmoneyBatchFailure {
    /// 第几批（1-based）
    let index: Int
    /// 总批数
    let total: Int
    let secids: [String]
    let error: String
}

/// 一次拉取的完整结果。
struct EastmoneyFetchResult {
    /// 全部命中结果的交易日（应一致，取最大值）；无命中为 0
    let tradeDate: Int
    /// file -> 当日K线（只含命中项）
    let bars: [String: EastmoneyDailyBar]
    /// 跳过 / 失败清单（含原因）
    let skipped: [EastmoneySkip]
    /// 批次级失败清单
    let batchFailures: [EastmoneyBatchFailure]

    var hitCount: Int { bars.count }
    var isEmpty: Bool { bars.isEmpty }
}

// MARK: - 取数器

final class EastmoneyQuoteFetcher {
    static let shared = EastmoneyQuoteFetcher()

    // MARK: 常量（严格照抄 PC 端 live_db_builder.py）

    /// PC 端 UA（约 :108-109）：请求头必须原样带上
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    /// PC 端 SNAPSHOT_ULIST_URL（约 :141-144）；调用时以逗号拼接 secids 追加到末尾
    static let ulistURLPrefix = "https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&invt=2&np=1&fields=f12,f13,f14,f2,f5,f6,f15,f16,f17,f18,f124"
    /// PC 端 ULIST_BATCH（约 :121）
    static let ulistBatch = 100
    /// PC 端 REQUEST_TIMEOUT（约 :125）
    static let requestTimeout: TimeInterval = 20
    /// PC 端 REQUEST_RETRIES（约 :124）：含首次共 4 次尝试（≥3 次重试）
    static let maxAttempts = 4
    /// 指数退避基数（PC 端为 0.5 * 2^attempt）
    static let retryBaseDelay: TimeInterval = 0.5
    /// 批间轻微间隔（PC 端 MIN_REQUEST_INTERVAL=0.25，约 :123）
    static let batchInterval: TimeInterval = 0.25

    /// 通达信伪代码 -> 东财 secid 特例表（PC 端 SPECIAL_FILE_SECID，约 :296-299）
    static let specialFileSecid: [String: String] = ["SH#999999": "1.000001"]

    /// 扩展指数覆盖表资源（Kline/Resources/universe_secids.txt，随同步文件夹自动打包）
    static let overrideResourceName = "universe_secids"
    static let overrideResourceSubdirectory = "Resources"

    // MARK: 内部

    private let queue = DispatchQueue(label: "com.sunck.kline.eastmoney.quote")
    /// file -> secid 覆盖表（读不到时为 `[:]`，只走前缀规则）
    private let overrideSecids: [String: String]

    /// 无缓存会话：单请求 20s 超时（与 PC 一致），整体资源上限 60s
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    private init() {
        overrideSecids = Self.loadOverrideSecids()
    }

    // MARK: - file -> secid 映射

    /// file 前缀 / 特例表 / 覆盖表 → 东财 secid。映射不到返回 nil（调用方跳过并逐条记录）。
    func secid(forFile file: String) -> String? {
        // ① 特例表（SH#999999 上证指数 → 1.000001），必须先于前缀规则
        if let special = Self.specialFileSecid[file] { return special }
        let parts = file.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let prefix = parts[0].uppercased()
        let code = String(parts[1])
        guard !code.isEmpty else { return nil }
        // ② 前缀规则（用 file 前缀判定市场，不从 6 位 code 猜）
        if prefix == "SH" { return "1." + code }
        if prefix == "SZ" || prefix == "BJ" { return "0." + code }
        // ③ 扩展行情指数（27#/62#/102#）→ 覆盖表；表缺失时此步必然 nil（已记降级日志）
        return overrideSecids[file]
    }

    /// 读 Bundle 内覆盖表；读不到 → 降级为「只用前缀规则」并记一条明确日志（不静默、不崩）。
    private static func loadOverrideSecids() -> [String: String] {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: overrideResourceName, withExtension: "txt",
                            subdirectory: overrideResourceSubdirectory),
            Bundle.main.url(forResource: overrideResourceName, withExtension: "txt"),
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            DebugLogger.shared.log("[EMQuote] 覆盖表 \(overrideResourceName).txt 未打进 Bundle → 降级：仅用前缀规则映射（27#/62#/102# 扩展指数将全部跳过）")
            return [:]
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            DebugLogger.shared.log("[EMQuote] 覆盖表 \(url.lastPathComponent) 读取失败 → 降级：仅用前缀规则映射")
            return [:]
        }
        var map: [String: String] = [:]
        // 源文件带 UTF-8 BOM；首行是注释，先整体去 BOM 再逐行解析
        let cleaned = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
        for rawLine in cleaned.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // 两列：file <TAB|空格> secid
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard parts.count >= 2, parts[0].contains("#") else { continue }
            map[parts[0]] = parts[1]
        }
        DebugLogger.shared.log("[EMQuote] 覆盖表 \(url.lastPathComponent) 载入 \(map.count) 条 secid 覆盖")
        return map
    }

    // MARK: - 交易日换算（唯一权威口径）

    /// 北京时间（UTC+8）格式化器。**显式 UTC+8，不依赖本机时区**（与 PC 端 BEIJING_TZ 一致）。
    private static let beijingDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    /// f124（秒级 epoch）→ 北京时间 YYYYMMDD；缺失 / 非正数 → nil（调用方丢弃该条）。
    static func beijingDate(fromEpoch ts: Double?) -> Int? {
        guard let ts = ts else { return nil }
        let seconds = Int(ts)
        guard seconds > 0 else { return nil }
        // Date 是绝对时间轴，时区只由 formatter 决定 → 与 PC 端 fromtimestamp(ts, BEIJING_TZ) 等价
        let text = beijingDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        return Int(text)
    }

    // MARK: - 对外入口

    /// 拉取 `files`（`SH#600000` 形式）的当日K线。
    /// - 按 ≤100 分批、串行、批间轻微间隔；带 UA；失败指数退避重试（含首次 4 次尝试）。
    /// - 单批失败只记日志，不影响其他批；映射不到 secid 的 file 逐条跳过。
    /// - `completion` 在内部串行队列回调（调用方自行切主线程）。
    func fetch(files: [String], completion: @escaping (EastmoneyFetchResult) -> Void) {
        var seen = Set<String>()
        let uniqueFiles = files.filter { seen.insert($0).inserted }
        queue.async { [weak self] in
            guard let self = self else {
                completion(EastmoneyFetchResult(tradeDate: 0, bars: [:], skipped: [], batchFailures: []))
                return
            }
            self.performFetch(uniqueFiles: uniqueFiles, completion: completion)
        }
    }

    // MARK: - 主流程（只在 `queue` 上执行）

    private func performFetch(uniqueFiles: [String],
                              completion: @escaping (EastmoneyFetchResult) -> Void) {
        // ① file -> secid；映射不到的逐条记录并跳过
        var fileSecid: [String: String] = [:]
        var orderedSecids: [String] = []
        var seenSecid = Set<String>()
        var skipped: [EastmoneySkip] = []
        for file in uniqueFiles {
            guard let secid = self.secid(forFile: file) else {
                skipped.append(EastmoneySkip(file: file, reason: .unmappable,
                                             detail: "无 secid 映射（扩展指数覆盖表缺失或前缀不支持）"))
                continue
            }
            fileSecid[file] = secid
            if seenSecid.insert(secid).inserted { orderedSecids.append(secid) }
        }

        // ② 按 ≤100 分批
        let batches: [[String]] = stride(from: 0, to: orderedSecids.count, by: Self.ulistBatch).map {
            Array(orderedSecids[$0 ..< Swift.min($0 + Self.ulistBatch, orderedSecids.count)])
        }

        var snapshots: [String: EMSnapshot] = [:]
        var batchFailures: [EastmoneyBatchFailure] = []

        // ③ 收尾：折算成「file -> 当日K线」+ 交易日一致性
        func finish() {
            let failedSecids = Set(batchFailures.flatMap { $0.secids })
            var bars: [String: EastmoneyDailyBar] = [:]
            var dates: [Int] = []
            for file in uniqueFiles {
                guard let secid = fileSecid[file] else { continue }   // 已在 skipped 记录
                guard let snap = snapshots[secid] else {
                    if failedSecids.contains(secid) {
                        skipped.append(EastmoneySkip(file: file, reason: .batchFailed,
                                                     detail: "所属批次请求最终失败（\(secid)）"))
                    } else {
                        skipped.append(EastmoneySkip(file: file, reason: .noQuote,
                                                     detail: "接口未返回 \(secid) 的报价"))
                    }
                    continue
                }
                guard let open = snap.open, let high = snap.high,
                      let low = snap.low, let close = snap.close else {
                    skipped.append(EastmoneySkip(file: file, reason: .invalidValue,
                                                 detail: "OHLC 含 '-'/null（\(secid)）"))
                    continue
                }
                guard let date = Self.beijingDate(fromEpoch: snap.ts) else {
                    skipped.append(EastmoneySkip(file: file, reason: .missingTimestamp,
                                                 detail: "f124 缺失或非正数（\(secid)）"))
                    continue
                }
                bars[file] = EastmoneyDailyBar(date: date, open: open, high: high, low: low,
                                               close: close, vol: snap.vol ?? 0, amo: snap.amo ?? 0)
                dates.append(date)
            }
            // 交易日本应一致；不一致（跨日 / 个别陈旧残留）取最大值并记日志
            let tradeDate = dates.max() ?? 0
            let distinct = Set(dates)
            if distinct.count > 1 {
                DebugLogger.shared.log("[EMQuote] 交易日不一致 \(distinct.sorted())，取最大值 \(tradeDate)")
            }
            DebugLogger.shared.log("[EMQuote] 完成：file \(uniqueFiles.count) 个 / 批 \(batches.count) 次 / 命中 \(bars.count) / 跳过 \(skipped.count) / 批次失败 \(batchFailures.count) / 交易日 \(tradeDate)")
            completion(EastmoneyFetchResult(tradeDate: tradeDate, bars: bars,
                                            skipped: skipped, batchFailures: batchFailures))
        }

        // ④ 逐批串行拉取（递归推进），单批失败只记录、继续下一批
        func runBatch(_ index: Int) {
            guard index < batches.count else { finish(); return }
            let chunk = batches[index]
            let batchNo = index + 1
            self.fetchChunk(chunk) { outcome in
                switch outcome {
                case .ok(let partial):
                    for (key, value) in partial { snapshots[key] = value }
                case .failed(let message):
                    batchFailures.append(EastmoneyBatchFailure(index: batchNo, total: batches.count,
                                                               secids: chunk, error: message))
                    DebugLogger.shared.log("[EMQuote] 第 \(batchNo)/\(batches.count) 批失败（\(chunk.count) 个 secid）：\(message)")
                }
                if batchNo < batches.count {
                    // 批间轻微间隔，礼貌取数
                    self.queue.asyncAfter(deadline: .now() + Self.batchInterval) { runBatch(batchNo) }
                } else {
                    finish()
                }
            }
        }

        runBatch(0)
    }

    // MARK: - 单批请求（限速已由批间间隔 + 串行保证；失败指数退避重试）

    private func fetchChunk(_ secids: [String], completion: @escaping (ChunkOutcome) -> Void) {
        let urlString = Self.ulistURLPrefix + "&secids=" + secids.joined(separator: ",")
        guard let url = URL(string: urlString) else {
            completion(.failed("请求 URL 构造失败"))
            return
        }
        attemptFetch(url: url, attempt: 1, completion: completion)
    }

    private func attemptFetch(url: URL, attempt: Int, completion: @escaping (ChunkOutcome) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")

        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            let outcome = Self.decodeChunk(data: data, response: response, error: error)
            // 回内部串行队列，保证状态修改与递归推进都不跨线程
            self.queue.async {
                switch outcome {
                case .ok:
                    completion(outcome)
                case .failed(let message):
                    if attempt < Self.maxAttempts {
                        let delay = Self.retryBaseDelay * pow(2.0, Double(attempt - 1))
                        DebugLogger.shared.log("[EMQuote] 请求失败（第 \(attempt)/\(Self.maxAttempts) 次）：\(message) → \(String(format: "%.2f", delay))s 后重试")
                        self.queue.asyncAfter(deadline: .now() + delay) {
                            self.attemptFetch(url: url, attempt: attempt + 1, completion: completion)
                        }
                    } else {
                        completion(.failed("重试 \(Self.maxAttempts) 次仍失败：\(message)"))
                    }
                }
            }
        }.resume()
    }

    /// 解析单批响应 → {secid: 快照}；HTTP / JSON 异常 → failed（交给上层重试）。
    private static func decodeChunk(data: Data?, response: URLResponse?, error: Error?) -> ChunkOutcome {
        if let error = error { return .failed(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let data = data, (200..<300).contains(status) else { return .failed("HTTP \(status)") }
        do {
            let decoded = try JSONDecoder().decode(EMResponse.self, from: data)
            var out: [String: EMSnapshot] = [:]
            for item in decoded.data?.diff ?? [] {
                // secid = "\(f13).\(f12)"（反查 {market}.{code}）
                guard let f12 = item.f12?.stringValue, let f13 = item.f13?.stringValue else { continue }
                let secid = f13 + "." + f12
                out[secid] = EMSnapshot(
                    open: item.f17?.doubleValue,    // f17 = 开
                    high: item.f15?.doubleValue,    // f15 = 高
                    low: item.f16?.doubleValue,     // f16 = 低
                    close: item.f2?.doubleValue,    // f2  = 收
                    vol: item.f5?.doubleValue,      // f5  = 成交量
                    amo: item.f6?.doubleValue,      // f6  = 成交额
                    ts: item.f124?.doubleValue)     // f124 = 行情时间戳（秒级 epoch）
            }
            return .ok(out)
        } catch {
            return .failed("JSON 解析失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 内部类型

/// 单批请求结果（String 不满足 Error，故不用 Result）。
private enum ChunkOutcome {
    case ok([String: EMSnapshot])
    case failed(String)
}

/// 东财快照的原始字段（值可能为 '-' / null，故一律 Optional）。
private struct EMSnapshot {
    let open: Double?
    let high: Double?
    let low: Double?
    let close: Double?
    let vol: Double?
    let amo: Double?
    let ts: Double?
}

/// 东财 JSON 值：可能是数字、整型、字符串（含 '-'）或 null。
private enum EMValue: Decodable {
    case number(Double)
    case integer(Int)
    case text(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let i = try? container.decode(Int.self) { self = .integer(i); return }
        if let d = try? container.decode(Double.self) { self = .number(d); return }
        if let s = try? container.decode(String.self) { self = .text(s); return }
        self = .null
    }

    /// 数值化：'-' / '--' / 空串 / null → nil（与 PC 端 _num 一致）。
    var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .integer(let i): return Double(i)
        case .text(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "-" || t == "--" { return nil }
            return Double(t)
        case .null: return nil
        }
    }

    /// 字符串化：数字也转字符串（f12 代码 / f13 市场号用）。
    var stringValue: String? {
        switch self {
        case .text(let s): return s
        case .integer(let i): return String(i)
        case .number(let d): return String(d)
        case .null: return nil
        }
    }
}

/// ulist 响应体（`data.diff` 为数组）。属性名与 JSON key 一一对应。
private struct EMResponse: Decodable {
    let rc: Int?
    let data: EMData?

    struct EMData: Decodable {
        let diff: [EMDiffItem]?
    }
}

/// diff 单项（属性名与 JSON key 一一对应；缺失 / null → nil）。
private struct EMDiffItem: Decodable {
    let f12: EMValue?      // 6 位代码
    let f13: EMValue?      // 市场号
    let f14: EMValue?      // 名称
    let f2: EMValue?       // 收
    let f5: EMValue?       // 成交量
    let f6: EMValue?       // 成交额
    let f15: EMValue?      // 高
    let f16: EMValue?      // 低
    let f17: EMValue?      // 开
    let f18: EMValue?      // 昨收（口径未用，保留以对齐字段）
    let f124: EMValue?     // 行情时间戳（秒级 epoch）
}
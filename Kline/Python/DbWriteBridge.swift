//
//  DbWriteBridge.swift
//  Kline
//
//  数据层「写路径」下沉桥（《Python引擎下沉可行性分析.md》§9.9 S5）。
//
//  角色：把 `db_write.py` 的写 op 封装成 Swift 调用点，供 `MainDBMerger` 等**写口**使用；
//  Swift 侧退化为「取数 + 内存比对 + 调 op + 应用结果」，不再直接执行写 SQL。
//
//  设计：
//    · 同步阻塞调用（`KlinePythonBridge.blockingCall`）——调用点本就持有
//      `DatabaseManager.dbQueue`，同步等待可保持「主库访问全部串行」这一既有不变式；
//      ⚠️ `blockingCall` 内部断言禁止主线程，调用点务必在后台队列上。
//    · 引擎未就绪 → `.engineNotReady`：按用户 2026-10-18 拍板「先不管降级」，
//      调用方跳过本次写并记日志（不再保留 Swift 影子写路径）。
//

import Foundation

enum DbWriteBridge {

    /// 调用失败分类。
    enum Failure: Error, CustomStringConvertible {
        case engineNotReady
        case badOutput
        case callError(String)

        var description: String {
            switch self {
            case .engineNotReady: return "引擎未就绪"
            case .badOutput: return "引擎输出非 JSON 对象"
            case .callError(let msg): return msg
            }
        }
    }

    /// 主库合并（`main_db_merge`）出参。
    struct MainMergeOutcome {
        var ok = false
        var dailyRows = 0
        var weeklyRows = 0
        var monthlyRows = 0
        var quarterlyRows = 0
        var yearlyRows = 0
        var hitSymbols = 0
        var skippedNoFile = 0
        var latestDate = 0
        var message = ""

        init(from d: [String: Any]) {
            func int(_ key: String) -> Int { (d[key] as? NSNumber)?.intValue ?? 0 }
            ok = (d["ok"] as? Bool) ?? false
            dailyRows = int("dailyRows")
            weeklyRows = int("weeklyRows")
            monthlyRows = int("monthlyRows")
            quarterlyRows = int("quarterlyRows")
            yearlyRows = int("yearlyRows")
            hitSymbols = int("hitSymbols")
            skippedNoFile = int("skippedNoFile")
            latestDate = int("latestDate")
            message = (d["message"] as? String) ?? ""
        }
    }

    /// 增量库行级写（`live_upsert_daily`）出参。
    struct LiveUpsertOutcome {
        var ok = false
        var metaRows = 0
        var dailyRows = 0
        var quarterlyRows = 0
        var yearlyRows = 0
        var coveredFiles = 0
        var message = ""

        init(from d: [String: Any]) {
            func int(_ key: String) -> Int { (d[key] as? NSNumber)?.intValue ?? 0 }
            ok = (d["ok"] as? Bool) ?? false
            metaRows = int("metaRows")
            dailyRows = int("dailyRows")
            quarterlyRows = int("quarterlyRows")
            yearlyRows = int("yearlyRows")
            coveredFiles = int("coveredFiles")
            message = (d["message"] as? String) ?? ""
        }
    }

    /// 增量库裁剪（`live_trim`）出参。
    struct LiveTrimOutcome {
        var ok = false
        var deletedRows = 0
        var message = ""

        init(from d: [String: Any]) {
            ok = (d["ok"] as? Bool) ?? false
            deletedRows = (d["deletedRows"] as? NSNumber)?.intValue ?? 0
            message = (d["message"] as? String) ?? ""
        }
    }

    /// 统一入口：跑一次 `db_write.py` op，返回 `result` 字典。
    static func run(_ op: String, _ input: [String: Any],
                    timeout: TimeInterval) -> Result<[String: Any], Failure> {
        guard KlinePythonBridge.shared.isReady else { return .failure(.engineNotReady) }
        var payload = input
        payload["op"] = op
        switch KlinePythonBridge.shared.blockingCall(script: "db_write", input: payload, timeout: timeout) {
        case .failure(let e):
            return .failure(.callError(String(describing: e)))
        case .success(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = obj["ok"] as? Bool else {
                return .failure(.badOutput)
            }
            guard ok else {
                return .failure(.callError((obj["error"] as? String) ?? "未知错误"))
            }
            guard let result = obj["result"] as? [String: Any] else {
                return .failure(.badOutput)
            }
            return .success(result)
        }
    }

    /// 主库合并（同步阻塞；调用点须在后台队列上且持有主库串行化队列）。
    static func mainDBMerge(dbPath: String,
                            snapshot: [String: [[String: Any]]],
                            timeout: TimeInterval = 120) -> Result<MainMergeOutcome, Failure> {
        run("main_db_merge", ["dbPath": dbPath, "snapshot": snapshot], timeout: timeout)
            .map { MainMergeOutcome(from: $0) }
    }

    /// 增量库行级写（同步阻塞；调用点在 `LiveDataStore.queue` 上）。
    /// ⚠️ 自 §11.34 起**写前比对也在引擎内**（哪些行变化 / meta 存在性 / 表名解析），
    /// 调用方只传原始入参（全量 metas / bars / periodBars），不再预筛。
    static func liveUpsertDaily(dbPath: String,
                                metas: [[String: Any]],
                                metaUpdatedAt: Int,
                                bars: [[String: Any]],
                                periodBars: [String: [[String: Any]]],
                                timeout: TimeInterval = 120) -> Result<LiveUpsertOutcome, Failure> {
        run("live_upsert_daily", ["dbPath": dbPath, "metaUpdatedAt": metaUpdatedAt,
                                  "metas": metas, "bars": bars, "periodBars": periodBars],
            timeout: timeout)
            .map { LiveUpsertOutcome(from: $0) }
    }

    /// 主库 K 线**按批读**（`db_query_batch`，**bin 通道**；同步阻塞，调用点在后台队列上）。
    /// ⚠️ §11.42 按批摊薄 + §11.45 出参走二进制（省掉 2.8 万数的 JSON 编码/解析）；
    /// 只返回**主库原始行**（各自 DESC），增量库读与 live/main 合并仍由 Swift 完成。
    static func dbQueryBatch(dbPath: String, table: String,
                             requests: [(metaID: Int, limit: Int?)],
                             timeout: TimeInterval = 120) -> Result<[Int: [[Any]]], Failure> {
        guard KlinePythonBridge.shared.isReady else { return .failure(.engineNotReady) }
        let symbols: [[String: Any]] = requests.map { r in
            var d: [String: Any] = ["metaID": r.metaID]
            if let limit = r.limit { d["limit"] = limit }
            return d
        }
        let input: [String: Any] = ["op": "db_query_batch", "dbPath": dbPath,
                                    "table": table, "symbols": symbols]
        // 出参走 `__bin_out__`（键 = metaID，值 = 行扁平化的 double 序列）→ 必须用 bin 通道读回
        switch KlinePythonBridge.shared.blockingCallBin(script: "db_write", input: input,
                                                        seriesBin: [:], seriesInto: "",
                                                        timeout: timeout) {
        case .failure(let e):
            return .failure(.callError(String(describing: e)))
        case .success(let bin):
            var out: [Int: [[Any]]] = [:]
            for (key, flat) in bin.arrays {
                guard let id = Int(key) else { continue }
                out[id] = Self.rows(fromFlat: flat)
            }
            return .success(out)
        }
    }

    /// 扁平 double 序列 → 行（每 7 个一组：date,open,high,low,close,vol,amo）。
    /// `date` 还原为 `Int` —— 与 JSON 通道 / Swift mirror 同形（便于对拍与 `klineItems` 解析）。
    private static func rows(fromFlat flat: [Double]) -> [[Any]] {
        var out: [[Any]] = []
        out.reserveCapacity(flat.count / 7)
        var i = 0
        while i + 7 <= flat.count {
            out.append([Int(flat[i]), flat[i + 1], flat[i + 2], flat[i + 3],
                        flat[i + 4], flat[i + 5], flat[i + 6]])
            i += 7
        }
        return out
    }

    /// 增量库裁剪（同步阻塞）。`items = [{table, bound, inclusive}]`，边界由调用方算。
    static func liveTrim(dbPath: String, beforeDate: Int,
                         items: [[String: Any]],
                         timeout: TimeInterval = 60) -> Result<LiveTrimOutcome, Failure> {
        run("live_trim", ["dbPath": dbPath, "beforeDate": beforeDate, "items": items],
            timeout: timeout)
            .map { LiveTrimOutcome(from: $0) }
    }
}

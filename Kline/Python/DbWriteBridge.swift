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

    /// 主库合并（同步阻塞；调用点须在后台队列上且持有主库串行化队列）。
    static func mainDBMerge(dbPath: String,
                            snapshot: [String: [[String: Any]]],
                            timeout: TimeInterval = 120) -> Result<MainMergeOutcome, Failure> {
        guard KlinePythonBridge.shared.isReady else { return .failure(.engineNotReady) }
        let input: [String: Any] = ["op": "main_db_merge", "dbPath": dbPath, "snapshot": snapshot]
        switch KlinePythonBridge.shared.blockingCall(script: "db_write", input: input, timeout: timeout) {
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
            return .success(MainMergeOutcome(from: result))
        }
    }
}

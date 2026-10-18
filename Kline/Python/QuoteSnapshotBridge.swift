//
//  QuoteSnapshotBridge.swift
//  Kline
//
//  阶段 C：行情快照「桥接客户端」——通过 Python 引擎计算行情快照字段。
//
//  角色：把 `quote_snapshot.py` 的 quote_snapshot / quote_snapshot_batch op 封装成 Swift 异步 API，
//  供 SimQuoteCenter / MarketRowCache 调用。Swift 侧负责从 DatabaseManager
//  取 bars 并传入，Python 侧只做纯计算（latestPrice / prevClose / change 等）。
//
//  设计：
//    · 输入 / 输出均为 [String: Any] 字典（JSON 形状）；
//    · 引擎未就绪 → .engineNotReady，调用方按 §9.10 显式降级（保留 Swift 现状计算）；
//    · 所有调用异步，完成回调派发主线程。
//    · batch 方法支持一次计算多个标的的多个字段，减少桥接调用次数。
//

import Foundation

enum QuoteSnapshotBridge {

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

    // MARK: - 统一入口（引擎唯一后端）

    /// 跑一次 quote_snapshot op：异步调 Python 引擎（引擎未就绪 → .engineNotReady）。
    @MainActor
    static func payload(bars: [[String: Any]], fields: [String]?,
                        timeout: TimeInterval = 30,
                        completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        guard KlinePythonBridge.shared.isReady else {
            completion(.failure(.engineNotReady))
            return
        }
        var input: [String: Any] = ["op": "quote_snapshot", "bars": bars]
        if let fields { input["fields"] = fields }
        KlinePythonBridge.shared.call(script: "quote_snapshot", input: input, timeout: timeout) { r in
            switch r {
            case .success(let data):
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ok = obj["ok"] as? Bool, ok else {
                    completion(.failure(.badOutput))
                    return
                }
                completion(.success(obj))
            case .failure(let e):
                completion(.failure(.callError(String(describing: e))))
            }
        }
    }

    /// 跑一次 quote_snapshot_batch op：批量多标的快照计算（引擎未就绪 → .engineNotReady）。
    /// - symbols: 每个元素含 "metaID"（Int）和 "bars"（[[String: Any]]）
    @MainActor
    static func payloadBatch(symbols: [[String: Any]], fields: [String]?,
                             timeout: TimeInterval = 30,
                             completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        guard KlinePythonBridge.shared.isReady else {
            completion(.failure(.engineNotReady))
            return
        }
        var input: [String: Any] = ["op": "quote_snapshot_batch", "symbols": symbols]
        if let fields { input["fields"] = fields }
        KlinePythonBridge.shared.call(script: "quote_snapshot", input: input, timeout: timeout) { r in
            switch r {
            case .success(let data):
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ok = obj["ok"] as? Bool, ok else {
                    completion(.failure(.badOutput))
                    return
                }
                completion(.success(obj))
            case .failure(let e):
                completion(.failure(.callError(String(describing: e))))
            }
        }
    }

    // MARK: - 便捷方法（返回 Double?，失败时 nil）

    /// 计算 latestPrice（最新收盘价）。失败 → nil。
    static func latestPrice(bars: [[String: Any]],
                            completion: @escaping (Result<Double?, Failure>) -> Void) {
        payload(bars: bars, fields: ["latestPrice"]) { r in
            switch r {
            case .success(let obj):
                let result = obj["result"] as? [String: Any] ?? [:]
                completion(.success(result["latestPrice"] as? Double))
            case .failure(let f):
                completion(.failure(f))
            }
        }
    }

    /// 计算 prevClose（昨收）。失败 → nil。
    static func prevClose(bars: [[String: Any]],
                          completion: @escaping (Result<Double?, Failure>) -> Void) {
        payload(bars: bars, fields: ["prevClose"]) { r in
            switch r {
            case .success(let obj):
                let result = obj["result"] as? [String: Any] ?? [:]
                completion(.success(result["prevClose"] as? Double))
            case .failure(let f):
                completion(.failure(f))
            }
        }
    }

    /// 批量计算快照字段。失败 → [:]。
    static func snapshot(bars: [[String: Any]], fields: [String],
                         completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        payload(bars: bars, fields: fields) { r in
            switch r {
            case .success(let obj):
                completion(.success(obj["result"] as? [String: Any] ?? [:]))
            case .failure(let f):
                completion(.failure(f))
            }
        }
    }

    /// 批量多标的快照计算。返回 [metaIDString: [field: value]]。
    static func snapshotBatch(symbols: [[String: Any]], fields: [String],
                              completion: @escaping (Result<[String: [String: Any]], Failure>) -> Void) {
        payloadBatch(symbols: symbols, fields: fields) { r in
            switch r {
            case .success(let obj):
                let result = obj["result"] as? [String: [String: Any]] ?? [:]
                completion(.success(result))
            case .failure(let f):
                completion(.failure(f))
            }
        }
    }
}

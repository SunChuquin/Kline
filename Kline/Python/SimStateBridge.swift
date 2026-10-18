//
//  SimStateBridge.swift
//  Kline
//
//  阶段 B：交易状态「桥接客户端」——通过 Python 引擎读写 sim.json。
//
//  角色：把 `sim_state.py` 的五个 op（sim_state_load / sim_state_save / sim_state_apply /
//  sim_state_get_revision / sim_state_sync）封装成 Swift 异步 API，供 SimStore
//  （投影缓存 + 桥接客户端）调用。Swift 侧不再直接读写 sim.json 文件，
//  所有状态变更经 Python 引擎持久化。
//
//  设计：
//    · 输入 / 输出均为 [String: Any] 字典（JSON 形状），编解码由调用方（SimStore）
//      负责，本层只做 JSON 通路 + 错误分类。
//    · 引擎未就绪 → .engineNotReady（调用方按 §9.10 显式降级，不静默用 Swift 兜底）。
//    · 所有调用异步，完成回调派发主线程。
//    · 状态同步协议：client 通过 sim_state_get_revision 获取服务端 revision，
//      若本地 revision 旧，通过 sim_state_sync 拉取完整状态（diff 留作优化）。
//

import Foundation

enum SimStateBridge {

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

    /// 跑一次 sim_state op：异步调 Python 引擎（引擎未就绪 → .engineNotReady）。
    @MainActor
    static func payload(op: String, input: [String: Any], timeout: TimeInterval = 30,
                        completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        guard KlinePythonBridge.shared.isReady else {
            completion(.failure(.engineNotReady))
            return
        }
        var payload = input
        payload["op"] = op
        KlinePythonBridge.shared.call(script: "sim_state", input: payload, timeout: timeout) { r in
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

    // MARK: - sim_state op

    /// 读取 sim.json，返回完整状态（含 revision）。
    static func simStateLoad(filePath: String,
                             completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        payload(op: "sim_state_load", input: ["filePath": filePath], completion: completion)
    }

    /// 写入完整状态到 sim.json。
    static func simStateSave(filePath: String, state: [String: Any],
                             completion: @escaping (Result<Void, Failure>) -> Void) {
        payload(op: "sim_state_save", input: ["filePath": filePath, "state": state]) { r in
            switch r {
            case .success: completion(.success(()))
            case .failure(let f): completion(.failure(f))
            }
        }
    }

    /// 增量应用状态变更，返回更新后的完整状态 + 新 revision。
    static func simStateApply(filePath: String, changes: [String: Any],
                              merge: [String: String] = [:],
                              completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        payload(op: "sim_state_apply",
                input: ["filePath": filePath, "changes": changes, "merge": merge],
                completion: completion)
    }

    /// 轻量获取当前 revision，用于同步前检查是否需要同步。
    static func simStateGetRevision(filePath: String,
                                    completion: @escaping (Result<Int, Failure>) -> Void) {
        payload(op: "sim_state_get_revision", input: ["filePath": filePath]) { r in
            switch r {
            case .success(let obj):
                let rev = obj["revision"] as? Int ?? 0
                completion(.success(rev))
            case .failure(let f):
                completion(.failure(f))
            }
        }
    }

    /// 基于 revision 的差分同步。
    /// - 若客户端 revision < 服务端 revision：返回完整状态（state 非空）。
    /// - 若无变更：state 为空 dict。
    static func simStateSync(filePath: String, clientRevision: Int,
                             completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        payload(op: "sim_state_sync",
                input: ["filePath": filePath, "clientRevision": clientRevision]) { r in
            switch r {
            case .success(let obj):
                let serverRev = obj["revision"] as? Int ?? 0
                let state = obj["state"] as? [String: Any] ?? [:]
                var merged = state
                merged["revision"] = serverRev
                completion(.success(merged))
            case .failure(let f):
                completion(.failure(f))
            }
        }
    }

    /// 入金：交给 Python 引擎计算新余额并持久化，返回更新后的完整状态 + revision。
    static func simStateDeposit(filePath: String, accountID: UUID, amount: Double,
                                note: String,
                                ledgerEntry: [String: Any]?,
                                logEntry: [String: Any]?,
                                completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        var input: [String: Any] = [
            "filePath": filePath,
            "accountID": accountID.uuidString,
            "amount": amount,
            "note": note,
        ]
        if let ledgerEntry { input["ledgerEntry"] = ledgerEntry }
        if let logEntry { input["logEntry"] = logEntry }
        payload(op: "sim_state_deposit", input: input, completion: completion)
    }

    /// 出金：交给 Python 引擎计算新余额（受可用资金限制）并持久化，返回更新后的完整状态 + revision。
    static func simStateWithdraw(filePath: String, accountID: UUID, amount: Double,
                                 note: String,
                                 ledgerEntry: [String: Any]?,
                                 logEntry: [String: Any]?,
                                 completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        var input: [String: Any] = [
            "filePath": filePath,
            "accountID": accountID.uuidString,
            "amount": amount,
            "note": note,
        ]
        if let ledgerEntry { input["ledgerEntry"] = ledgerEntry }
        if let logEntry { input["logEntry"] = logEntry }
        payload(op: "sim_state_withdraw", input: input, completion: completion)
    }

    /// 新建账户：交给 Python 引擎生成 UUID、创建账户并持久化，
    /// 返回更新后的完整状态 + revision + 新账户对象（含生成的 id）。
    static func simStateCreateAccount(filePath: String, name: String, badge: String,
                                      colorHex: String, initialCapital: Double, cash: Double,
                                      createdAt: Date,
                                      ledgerEntry: [String: Any]?,
                                      logEntry: [String: Any]?,
                                      completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        let iso = ISO8601DateFormatter()
        var input: [String: Any] = [
            "filePath": filePath,
            "name": name,
            "badge": badge,
            "colorHex": colorHex,
            "initialCapital": initialCapital,
            "cash": cash,
            "createdAt": iso.string(from: createdAt),
        ]
        if let ledgerEntry { input["ledgerEntry"] = ledgerEntry }
        if let logEntry { input["logEntry"] = logEntry }
        payload(op: "sim_state_create_account", input: input, completion: completion)
    }
}

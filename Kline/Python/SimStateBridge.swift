//
//  SimStateBridge.swift
//  Kline
//
//  阶段 B：交易状态「桥接客户端」——通过 Python 引擎读写 sim.json。
//
//  角色：把 `sim_state.py` 的三个 op（sim_state_load / sim_state_save / sim_state_apply）
//  封装成 Swift 异步 API，供 SimStateStore（投影缓存）调用。Swift 侧不再直接
//  读写 sim.json 文件，所有状态变更经 Python 引擎持久化。
//
//  设计：
//    · 输入 / 输出均为 [String: Any] 字典（JSON 形状），编解码由调用方（SimStateStore）
//      负责，本层只做 JSON 通路 + 错误分类。
//    · 引擎未就绪 → .engineNotReady（调用方按 §9.10 显式降级，不静默用 Swift 兜底）。
//    · 所有调用异步，完成回调派发主线程。
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
}

//
//  SimRulesBridge.swift
//  Kline
//
//  阶段 A6：交易判定「引擎唯一后端」门面（**A6 删 Swift 实现后**）。
//
//  角色：把一次「交易判定 op」的结果产出统一经 `KlinePythonBridge` 调 `sim_rules.py`，
//  原样返回其 `kline_result`。不再保留 Swift 参考后端，不存在双语义。
//
//  与 sim_rules.py 的对应（op 清单见 §11.3）：
//    sim_format / cond_evaluate / cond_validate_create / cond_grid_level_count / cond_text /
//    cond_expired_reason / cond_fire_direction / cond_execution_price / cond_advance /
//    cond_repeatable_finished / cond_alert_message / trade_calc / trade_validate /
//    strategy_drafts / strategy_entry_draft / strategy_parse / strategy_rule_line /
//    strategy_catalog / strategy_validate / strategy_preview / trade_parse /
//    trade_serialize / trade_override / backtest_run。
//
//  降级（§9.10）：引擎未就绪 → `.failure(.engineNotReady)`，
//  调用方按 §9.10 走**显式降级**（不静默用 Swift 兜底，避免双语义）。
//

import Foundation

enum SimRulesBridge {

    // MARK: - 调用失败分类

    /// `.engineNotReady` 即 §9.10 的「返回 nil」语义（显式降级）。
    enum Failure: Error, CustomStringConvertible {
        case engineNotReady
        case unknownOp(String)
        case badOutput
        case callError(String)

        var description: String {
            switch self {
            case .engineNotReady: return "引擎未就绪"
            case .unknownOp(let op): return "未知 op：\(op)"
            case .badOutput: return "引擎输出非 JSON 对象"
            case .callError(let msg): return msg
            }
        }
    }

    // MARK: - 统一入口（引擎唯一后端）

    /// 跑一次 op：异步调 `sim_rules.py`（引擎未就绪 → `.engineNotReady`）。
    @MainActor
    static func payload(op: String, input: [String: Any], timeout: TimeInterval = 30,
                        completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        enginePayload(op: op, input: input, timeout: timeout, completion: completion)
    }

    /// 判定 / 结算可用性判据（§9.10 显式降级）：
    /// 需引擎自身就绪 —— 未就绪时条件单**不结算**（保持 monitoring），**不用 Swift 兜底**。
    @MainActor
    static var judgmentAvailable: Bool {
        KlinePythonBridge.shared.isReady
    }

    /// 引擎后端：调 `sim_rules.py`，原样返回 `kline_result`（含 `ok:true`）。
    /// 引擎未就绪 → `.engineNotReady`（**不触发** ensureReady / 不加载）。
    static func enginePayload(op: String, input: [String: Any], timeout: TimeInterval = 30,
                              completion: @escaping (Result<[String: Any], Failure>) -> Void) {
        guard KlinePythonBridge.shared.isReady else {
            completion(.failure(.engineNotReady))
            return
        }
        var payload = input
        payload["op"] = op
        KlinePythonBridge.shared.call(script: "sim_rules", input: payload, timeout: timeout) { r in
            switch r {
            case .success(let data):
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(.badOutput))
                    return
                }
                completion(.success(obj))
            case .failure(let e):
                completion(.failure(.callError(String(describing: e))))
            }
        }
    }

}

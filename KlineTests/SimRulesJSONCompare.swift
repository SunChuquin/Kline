//
//  SimRulesJSONCompare.swift
//  KlineTests
//
//  交易判定契约测试共用的 JSON 逐字段比较器（阶段 A1/A3/A4）。
//
//  三处契约测试共用同一比较口径，避免各写一份漂移：
//    · SimRulesContractTests（Swift 现状 ↔ fixture，A1 dump/断言）
//    · PyBridgeSimRulesTests （Python ↔ fixture，A3）
//    · SimRulesDiffTests      （Swift ↔ Python 同用例双跑，A4）
//
//  口径（与 §10.1 数值容差一致）：
//    · 递归；对象**键集必须完全一致**（缺键 / 多键都报错）；
//    · 数值（非 bool 的 NSNumber）相对容差 `1e-9 * max(1, |expected|)`；
//    · bool / string 精确相等；NSNull 只对 NSNull；
//    · 返回错误串列表（空 = 相等），由调用方决定 XCTFail 还是聚合。
//

import Foundation

enum SimRulesJSONCompare {

    static func report(expected: Any, actual: Any, path: String) -> [String] {
        if let e = expected as? [String: Any] {
            guard let a = actual as? [String: Any] else {
                return ["\(path)：期望对象，实得 \(actual)"]
            }
            var errs: [String] = []
            for k in e.keys {
                if let av = a[k] { errs += report(expected: e[k]!, actual: av, path: "\(path).\(k)") }
                else { errs.append("\(path).\(k)：缺失") }
            }
            for k in a.keys where e[k] == nil { errs.append("\(path).\(k)：多余字段") }
            return errs
        }
        if let e = expected as? [Any] {
            guard let a = actual as? [Any] else { return ["\(path)：期望数组，实得 \(actual)"] }
            if e.count != a.count { return ["\(path)：长度 期望 \(e.count)，实得 \(a.count)"] }
            var errs: [String] = []
            for (i, pair) in zip(e, a).enumerated() {
                errs += report(expected: pair.0, actual: pair.1, path: "\(path)[\(i)]")
            }
            return errs
        }
        if expected is NSNull || actual is NSNull {
            if !(expected is NSNull && actual is NSNull) {
                return ["\(path)：期望 \(expected)，实得 \(actual)"]
            }
            return []
        }
        if let e = expected as? NSNumber, let a = actual as? NSNumber,
           CFGetTypeID(e) != CFBooleanGetTypeID(), CFGetTypeID(a) != CFBooleanGetTypeID() {
            if abs(e.doubleValue - a.doubleValue) > 1e-9 * max(1.0, abs(e.doubleValue)) {
                return ["\(path)：期望 \(e)，实得 \(a)"]
            }
            return []
        }
        if let e = expected as? Bool, let a = actual as? Bool, e == a { return [] }
        if let e = expected as? String, let a = actual as? String, e == a { return [] }
        if String(describing: expected) == String(describing: actual) { return [] }
        return ["\(path)：期望 \(expected)，实得 \(actual)"]
    }
}

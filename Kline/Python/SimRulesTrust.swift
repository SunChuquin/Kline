//
//  SimRulesTrust.swift
//  Kline
//
//  阶段 A5-1：交易域「信任链」（《Python引擎下沉可行性分析.md》§10.9 套件 8 /
//  §9.10 降级矩阵）。
//
//  D2 已定「硬约束复核一并下沉」→ Swift 侧不再有交易规则实现，红线 4 的缓解只剩
//  「签名 + 版本锁 + 脚本哈希」；本文件即该三重缓解的 Swift 侧落点：
//    · 签名      —— App 整体代码签名由 iOS 安装期强制授信（本文件不复核，仅依赖）
//    · 版本锁    —— 脚本声明的 requiredApiVersion ↔ 引擎 manifest.apiVersion 精确配对
//    · 脚本哈希  —— Bundle 内 sim_rules.py 的 sha256 ↔ 编译期常量 expectedScriptSHA256
//  任一不满足 → state = .untrusted（交易 / 回测 / 条件单 / 预警**整体禁用**，§9.10：
//  不允许「GUI 还能点但引擎不下单」的半可用态）。
//
//  ⚠️ expectedScriptSHA256 / scriptVersion / requiredAPIVersion 由
//     `python3 scripts/gen_sim_rules_trust.py` 从 Kline/PyScripts/sim_rules.py 生成，
//     三处（脚本 / 本文件常量 / KlineTests/Fixtures/sim_rules_trust.json）必须一致；
//     KlineTests/SimRulesTrustTests 与 `verify_sim_rules.py --trust` 会拦下漂移。
//     **改了 sim_rules.py（含仅注释）后必须重跑该脚本。**
//

import Foundation
import CryptoKit
import Combine

@MainActor
final class SimRulesTrust: ObservableObject {

    static let shared = SimRulesTrust()

    /// 信任状态（三重缓解的判定结果）
    enum State: Equatable {
        case unknown                 // 尚未校验
        case trusted                 // 脚本哈希 + 版本锁 + 引擎可定位 全部满足
        case untrusted(String)       // 任一不满足（拒绝使用引擎，交易整体禁用）

        /// nonisolated：纯判定，供非隔离的信任链纯函数读取。
        nonisolated var isTrusted: Bool {
            if case .trusted = self { return true }
            return false
        }
    }

    // MARK: - 编译期常量（sim_rules.py 声明的镜像；自动生成，勿手改）

    /// sim_rules.py 的 sha256（sha256sum 全小写十六进制）
    /// nonisolated：编译期常量，需在非隔离上下文（信任链纯判定 / 测试注入）读取。
    nonisolated static let expectedScriptSHA256 = "4c2eff2680806bb999abf2434e6529b7a9c88bfcedf7d025c590f13ca86aabea"
    /// sim_rules.py 的 SIM_RULES_SCRIPT_VERSION
    nonisolated static let scriptVersion = 1
    /// sim_rules.py 的 SIM_RULES_REQUIRED_API_VERSION（与 manifest.apiVersion 配对）
    nonisolated static let requiredAPIVersion = 1

    /// 业务脚本名（桥接按 Bundle 内 <name>.py 定位）
    nonisolated static let scriptName = "sim_rules"

    @Published private(set) var state: State = .unknown

    private init() {}

    // MARK: - 校验

    /// 重算信任状态（主线程；只读 Bundle 与 manifest，绝不触发引擎初始化）。
    /// 返回新状态，便于调用点立即判定。
    @discardableResult
    func refresh() -> State {
        let next = Self.evaluate(scriptData: Self.bundledScriptData(),
                                 engineAPIVersion: PythonEngineHost.shared.engineManifest()?.apiVersion)
        if next != state { state = next }
        return next
    }

    /// 纯判定（无副作用；供测试注入合成数据）。
    /// - 脚本缺失 / 哈希不匹配 / 版本声明缺失或不配对 / 引擎 manifest 不可读
    ///   → `.untrusted(原因)`；全部满足 → `.trusted`。
    nonisolated static func evaluate(scriptData: Data?, engineAPIVersion: Int?) -> State {
        guard let data = scriptData else {
            return .untrusted("业务脚本缺失：Bundle/PyScripts/\(scriptName).py")
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedScriptSHA256 else {
            return .untrusted("脚本哈希不匹配（期望 \(expectedScriptSHA256.prefix(12))…，"
                              + "实际 \(actual.prefix(12))…）")
        }
        guard let declared = declaredVersions(from: data) else {
            return .untrusted("脚本未声明版本（SIM_RULES_SCRIPT_VERSION / "
                              + "SIM_RULES_REQUIRED_API_VERSION 缺失）")
        }
        guard declared.scriptVersion == scriptVersion else {
            return .untrusted("脚本契约版本不配对（脚本 \(declared.scriptVersion)，"
                              + "本 App 期望 \(scriptVersion)）")
        }
        guard declared.requiredAPIVersion == requiredAPIVersion else {
            return .untrusted("脚本要求的引擎 apiVersion 不配对（脚本 \(declared.requiredAPIVersion)，"
                              + "本 App 期望 \(requiredAPIVersion)）")
        }
        guard let api = engineAPIVersion else {
            return .untrusted("引擎 manifest 不可读（无内嵌引擎且未安装 Engine.app）")
        }
        guard api == requiredAPIVersion else {
            return .untrusted("引擎 apiVersion 不配对（引擎 \(api)，脚本要求 \(requiredAPIVersion)）")
        }
        return .trusted
    }

    /// 从脚本文本解析两处版本声明（缺任一 → nil）。
    nonisolated static func declaredVersions(from data: Data) -> (scriptVersion: Int, requiredAPIVersion: Int)? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let sv = firstInt(after: "SIM_RULES_SCRIPT_VERSION", in: text),
              let av = firstInt(after: "SIM_RULES_REQUIRED_API_VERSION", in: text) else { return nil }
        return (sv, av)
    }

    nonisolated private static func firstInt(after key: String, in text: String) -> Int? {
        // 逐行找「行首 = key」，取该行 `=` 后的首个整数（与 gen 脚本的行首正则同口径）
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key) else { continue }
            let rest = trimmed.dropFirst(key.count)
            guard rest.hasPrefix(" ") || rest.hasPrefix("=") || rest.hasPrefix("\t") else { continue }
            var digits = ""
            var seenEq = false
            for ch in rest {
                if ch == "=" { seenEq = true; continue }
                if ch.isNumber { digits.append(ch) }
                else if seenEq && !digits.isEmpty { break }
                else if seenEq { continue }
                else if ch == " " || ch == "\t" { continue }
                else { break }
            }
            if let v = Int(digits) { return v }
        }
        return nil
    }

    /// Bundle 内业务脚本内容（与 KlinePythonBridge 的定位口径一致）。
    nonisolated static func bundledScriptData() -> Data? {
        let path = Bundle.main.bundlePath + "/PyScripts/" + scriptName + ".py"
        return FileManager.default.contents(atPath: path)
    }

    // MARK: - 降级矩阵（§9.10）

    /// 交易域（条件单 / 预警 / 下单 / 回测）当前是否可用。
    /// 生产默认（A5-5 起 `.engine`）：仅当信任链 `trusted` **且**引擎就绪才可用，否则整体禁用。
    var isTradingAvailable: Bool {
        Self.isTradingAvailable(state: state, engineReady: KlinePythonBridge.shared.isReady)
    }

    /// 纯判定（供测试注入）：仅当信任链 `trusted` **且**引擎就绪才可用，否则整体禁用。
    nonisolated static func isTradingAvailable(state: State, engineReady: Bool) -> Bool {
        state.isTrusted && engineReady
    }
}

//
//  StrategyProjection.swift
//  Kline
//
//  阶段 E-4：策略编辑器「引擎投影层」。
//
//  背景（与 `SimRulesProjection` / `SimTradeRulesProjection` 同属「防抖 + 投影」：见
//  《Python引擎下沉可行性分析.md》§10.10 闸门 6）：策略编辑器（`StrategyFormulaEditorView`）
//  的字段都是**每帧同步算**的纯函数（规则目录 / RULES 行序列化 / 解析 / 校验 / 语义预览）。
//  下沉到引擎后这些变成异步 op，直接把「视图每帧等引擎」搬进 UI 会卡。
//  本层即解法：
//    · 视图按当前入参同步取值（命中缓存→立即返回，`body` 里可安全调用）；
//    · 状态变更由显式 `request*` 入队（按 key 去重 + 防抖合并），到点后逐个调引擎 op；
//    · 结果按「op + 入参」为键写进 `@Published` 缓存，视图自然重绘；
//    · 未命中 → 返回 `nil` / 空，由视图给显式占位（`placeholderText`）。
//
//  过渡期语义（A5-5 前 `SimRulesBridge.mode == .swift`）：本层**完全直通** Swift 现状实现
//  （零行为变化、零引擎请求、零缓存写入）；`request*` 直接 return。
//
//  降级（§9.10 / §11.7）：引擎未就绪 / 出参形状非法 → 标记 `.failed`，取值给 `nil`，
//  由视图呈现显式占位，**不静默用 Swift 兜底**。需要「确定值」的场合（保存 / 生成条件单）
//  仍由调用方直接 `await` 引擎。
//
//  ⚠️ 取值（getter）**绝不做副作用入队**：避免在视图 `body` 里改 `@Published` 触发
//  「Publishing changes from within view updates」。入队只由显式 `request*` 触发。
//

import Foundation
import Combine

@MainActor
final class StrategyProjection: ObservableObject {

    static let shared = StrategyProjection()

    /// 未就绪占位（显式空态，§9.10）
    static let placeholderText = "…"

    /// 每键可用性（供视图区分「计算中」与「失败」，与 `SimRulesProjection.Availability` 同形态）。
    /// `.failed` 之后**不自动重试**（否则未就绪期每次变更都刷一轮），待引擎就绪时的 `reset()`。
    enum Availability: Equatable { case computing, ready, failed }

    /// 规则行 ORD* 覆盖摘要（缓存值类型，故为 internal）
    struct OverrideSummary: Equatable {
        var isEmpty: Bool
        var summary: String?
    }

    /// RULES 文本解析结果（缓存值类型）
    struct ParseResult: Equatable {
        var rules: [StrategyRuleCall]
        var errors: [String]
    }

    // MARK: - 投影缓存

    /// 规则目录（`strategy_catalog`，静态，永久缓存；键 = 规则类型）
    @Published private(set) var catalog: [StrategyRuleKind: SimRulesCodec.StrategyCatalogEntry] = [:]

    /// RULES 行文本（键见 `lineKey`）
    @Published private(set) var ruleLines: [String: String] = [:]

    /// 规则行 ORD* 覆盖摘要（键见 `overrideKey`）
    @Published private(set) var overrideSummaries: [String: OverrideSummary] = [:]

    /// RULES 文本 → 解析结果（键见 `parseKey`）
    @Published private(set) var parses: [String: ParseResult] = [:]

    /// 校验清单（键见 `validateKey`）
    @Published private(set) var validations: [String: [String]] = [:]

    /// 语义预览（键见 `previewKey`）（tz 由门面内部注入，不入键）
    @Published private(set) var previews: [String: SimRulesCodec.StrategyPreviewResult] = [:]

    /// 各投影键的可用性（含目录键 `catalogKey`）
    @Published private(set) var availability: [String: Availability] = [:]

    /// 重置令牌：`reset()` 自增。本类不在重置时做副作用重发，由视图据此（`.onChange`）
    /// 重新入队当前取值——保证「引擎就绪后清空失效键并重新请求」。
    @Published private(set) var resetToken = 0

    /// 防抖间隔（合并连续变更，编辑输入时不致每次击键都打引擎）
    var debounce: TimeInterval = 0.05

    private static let catalogKey = "strategy_catalog"

    private var pending: [String: () async throws -> Void] = [:]
    private var requestedSig: [String: String] = [:]   // 上次已请求内容（去重：内容未变不重复打引擎）
    private var scheduled = false
    private var inflight = 0

    private init() {}

    // MARK: - 生命周期

    /// 引擎就绪 / 信任链重算后调用（见 `KlinePythonBridge.ensureReady` 成功路径）：
    /// 清空缓存与失效键，并自增 `resetToken` 让视图重新入队。
    func reset() {
        catalog.removeAll()
        ruleLines.removeAll()
        overrideSummaries.removeAll()
        parses.removeAll()
        validations.removeAll()
        previews.removeAll()
        availability.removeAll()
        pending.removeAll()
        requestedSig.removeAll()
        resetToken += 1
    }

    /// 测试辅助：立刻冲一次防抖队列，并等到本轮请求全部落地。
    func flushAndWait(timeout: TimeInterval = 5) async {
        flush()
        let deadline = Date().addingTimeInterval(timeout)
        while inflight > 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: - 取值（同步；视图 `body` 直接调）

    /// 某规则类型的参数规格清单（`strategy_catalog`）。
    /// `.engine` 目录未就绪 → 返回空数组（视图按「参数加载中」占位，**不渲染空 specs**）。
    func specs(for kind: StrategyRuleKind) -> [StrategyParamSpec] {
        if SimRulesBridge.mode == .swift { return StrategyRuleCatalog.specs(for: kind) }
        guard availability[Self.catalogKey] == .ready else { return [] }
        return catalog[kind]?.specs ?? []
    }

    /// 一条规则 → RULES 文本（`strategy_rule_line`）。
    /// `.engine` 未就绪 → `nil`（⚠️ 不用空串，否则编辑器会拼出空行 / 漏行）。
    func ruleLine(kind: StrategyRuleKind, params: [String: String]) -> String? {
        if SimRulesBridge.mode == .swift {
            return StrategyRuleParser.line(for: StrategyRuleCall(kind: kind, params: params, raw: ""))
        }
        return ruleLines[Self.lineKey(kind, params)]
    }

    /// 规则行内 ORD* 覆盖（`trade_override`）。未就绪 → `nil`（视图不显示指令提示行）。
    func overrideSummary(kind: StrategyRuleKind, params: [String: String]) -> OverrideSummary? {
        if SimRulesBridge.mode == .swift {
            let o = StrategyTradeParser.override(in: StrategyRuleCall(kind: kind, params: params, raw: ""))
            return OverrideSummary(isEmpty: o.isEmpty, summary: o.summary)
        }
        return overrideSummaries[Self.overrideKey(kind, params)]
    }

    /// RULES 文本 → 解析结果（`strategy_parse`）。未就绪 → `nil`。
    func parse(rules: String) -> ParseResult? {
        if SimRulesBridge.mode == .swift {
            let r = StrategyRuleParser.parse(lines: rules)
            return ParseResult(rules: r.rules, errors: r.errors)
        }
        return parses[Self.parseKey(rules)]
    }

    /// 整份策略文档静态校验（`strategy_validate`）。未就绪 → `nil`（视图显示占位，**不视为通过**）。
    func issues(doc: FormulaDoc, pickerExists: Bool, pickSyntaxError: String?) -> [String]? {
        if SimRulesBridge.mode == .swift {
            return StrategyValidator.validate(doc: doc, pickerExists: pickerExists,
                                              pickSyntaxError: pickSyntaxError)
        }
        return validations[Self.validateKey(doc, pickerExists, pickSyntaxError)]
    }

    /// 语义预览（`strategy_preview`，全为展示文案）。未就绪 → `nil`。
    func preview(doc: FormulaDoc, pickerName: String?) -> SimRulesCodec.StrategyPreviewResult? {
        if SimRulesBridge.mode == .swift { return Self.swiftPreview(doc: doc, pickerName: pickerName) }
        return previews[Self.previewKey(doc, pickerName)]
    }

    /// `.swift` 模式的预览（逐字段直通 `StrategyPreview.*`，与引擎出参同形状）。
    private static func swiftPreview(doc: FormulaDoc, pickerName: String?)
        -> SimRulesCodec.StrategyPreviewResult {
        let (calls, _) = StrategyRuleParser.parse(lines: doc.rules)
        return SimRulesCodec.StrategyPreviewResult(
            summary: StrategyPreview.summary(doc: doc, pickerName: pickerName),
            pick: StrategyPreview.pickSummary(doc: doc, pickerName: pickerName),
            trade: StrategyPreview.tradeSummary(doc: doc),
            executionNotice: StrategyPreview.executionNotice,
            triggers: calls.map { StrategyPreview.triggerText($0) })
    }

    // MARK: - 入队（状态变化时由视图显式调用；`.swift` 模式直接 return，零开销）

    /// 规则目录（一次取全 8 类，静态）。
    func requestCatalog() {
        guard SimRulesBridge.mode == .engine else { return }
        let key = Self.catalogKey
        enqueue(key: key, sig: "catalog") { [weak self] in
            let catalog = try await SimRulesBridge.strategyCatalog(kind: nil)
            self?.catalog = catalog
        }
    }

    /// 批量：每行 ruleLine + 每行 trade_override。
    func requestRules(_ calls: [StrategyRuleCall]) {
        guard SimRulesBridge.mode == .engine else { return }
        for call in calls {
            let lk = Self.lineKey(call.kind, call.params)
            enqueue(key: lk, sig: lk) { [weak self] in
                let line = try await SimRulesBridge.strategyRuleLine(call)
                self?.ruleLines[lk] = line
            }
            let ok = Self.overrideKey(call.kind, call.params)
            enqueue(key: ok, sig: ok) { [weak self] in
                let r = try await SimRulesBridge.tradeOverride(call)
                self?.overrideSummaries[ok] = OverrideSummary(isEmpty: r.isEmpty, summary: r.summary)
            }
        }
    }

    /// RULES 文本解析。
    func requestParse(rules: String) {
        guard SimRulesBridge.mode == .engine else { return }
        let key = Self.parseKey(rules)
        enqueue(key: key, sig: rules) { [weak self] in
            let r = try await SimRulesBridge.strategyParse(lines: rules)
            self?.parses[key] = ParseResult(rules: r.rules, errors: r.errors)
        }
    }

    /// 整份文档校验。
    func requestValidate(doc: FormulaDoc, pickerExists: Bool, pickSyntaxError: String?) {
        guard SimRulesBridge.mode == .engine else { return }
        let key = Self.validateKey(doc, pickerExists, pickSyntaxError)
        enqueue(key: key, sig: key) { [weak self] in
            let list = try await SimRulesBridge.strategyValidate(doc: doc, pickerExists: pickerExists,
                                                                pickSyntaxError: pickSyntaxError)
            self?.validations[key] = list
        }
    }

    /// 语义预览。
    func requestPreview(doc: FormulaDoc, pickerName: String?) {
        guard SimRulesBridge.mode == .engine else { return }
        let key = Self.previewKey(doc, pickerName)
        enqueue(key: key, sig: key) { [weak self] in
            let r = try await SimRulesBridge.strategyPreview(doc: doc, pickerName: pickerName)
            self?.previews[key] = r
        }
    }

    // MARK: - 内部：键 / 去重 / 防抖 / 冲刷

    /// 参数稳定串（键按名排序拼接），保证同样的参数得到同样的键。
    private static func paramsKey(_ params: [String: String]) -> String {
        params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    private static func lineKey(_ kind: StrategyRuleKind, _ params: [String: String]) -> String {
        "line|\(kind.rawValue)|\(paramsKey(params))"
    }

    private static func overrideKey(_ kind: StrategyRuleKind, _ params: [String: String]) -> String {
        "override|\(kind.rawValue)|\(paramsKey(params))"
    }

    private static func parseKey(_ lines: String) -> String { "parse|\(lines)" }

    private static func validateKey(_ doc: FormulaDoc, _ pickerExists: Bool,
                                    _ pickSyntaxError: String?) -> String {
        "validate|\(jsonString(SimRulesCodec.formulaDocJSON(doc)))|\(pickerExists ? 1 : 0)"
            + "|\(pickSyntaxError ?? "")"
    }

    private static func previewKey(_ doc: FormulaDoc, _ pickerName: String?) -> String {
        "preview|\(jsonString(SimRulesCodec.formulaDocJSON(doc)))|\(pickerName ?? "")"
    }

    /// 任意 JSON 对象 → 键排序文本（作为稳定入参签名）。
    private static func jsonString(_ o: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "<encode-failed>" }
        return s
    }

    /// 入队一次请求（同键同内容去重）+ 起防抖定时。
    /// ⚠️ 本方法**只改非 `@Published` 状态**（`pending` / `requestedSig` / `scheduled`），
    /// 故可安全地在视图 `onChange`（非 `body`）里调用。
    private func enqueue(key: String, sig: String, _ run: @escaping () async throws -> Void) {
        if availability[key] == .failed { return }
        if requestedSig[key] == sig { return }
        requestedSig[key] = sig
        pending[key] = run
        if availability[key] == nil { availability[key] = .computing }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.flush()
        }
    }

    private func flush() {
        let batch = pending
        pending.removeAll()
        guard !batch.isEmpty else { return }
        inflight += batch.count
        for (key, run) in batch {
            Task { @MainActor [weak self] in
                do {
                    try await run()
                    self?.availability[key] = .ready
                } catch {
                    DebugLogger.shared.log("[StrategyProjection] \(key) 失败：\(error)")
                    self?.availability[key] = .failed
                }
                self?.inflight -= 1
            }
        }
    }
}

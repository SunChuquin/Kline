//
//  FormulaKind.swift
//  Kline
//
//  三类公式分域：技术指标 / 选股指标 / 交易策略 的类型标记、公式文档模型与选股·策略公式库存储。
//
//  Created by 孙楚昆 on 2026/9/20.
//

import Foundation
import Combine

/// 公式类型：三类公式分域的类型标记（rawValue 即 .tdx 文件里的 KIND= 取值）
enum FormulaKind: String, Codable, CaseIterable, Identifiable {
    case tech = "TECH"          // 技术指标公式：落在 Documents/indicator/<周期目录>/*.tdx，由 SystemIndicatorStore 装载
    case picker = "PICKER"      // 选股指标公式：落在 Documents/formula/picker/*.tdx
    case strategy = "STRATEGY"  // 交易策略指标公式：落在 Documents/formula/strategy/*.tdx

    var id: String { rawValue }

    /// 展示名
    var title: String {
        switch self {
        case .tech: return "技术指标"
        case .picker: return "选股指标"
        case .strategy: return "交易策略"
        }
    }

    /// 公式库子目录名（选股 picker / 策略 strategy）；技术指标由 SystemIndicatorStore 按周期管理，返回 nil
    var libraryDirName: String? {
        switch self {
        case .tech: return nil
        case .picker: return "picker"
        case .strategy: return "strategy"
        }
    }
}

/// 公式文档（值类型）：id 即文件名（不含扩展名），稳定不变，重命名只改 name
struct FormulaDoc: Identifiable, Equatable {
    var id: String
    var kind: FormulaKind
    var name: String
    var pickBody: String = ""     // 选股公式文本；策略时表示内嵌的选股条件
    var pickRef: String? = nil    // 仅 strategy：引用选股公式库中某条目的 id
    var rules: String = ""        // 仅 strategy：RULES 段原文（多行文本）
    var trade: StrategyTradeSpec = StrategyTradeSpec()  // 仅 strategy：TRADE 段（交易指令），默认空 = 未配置
}

/// 选股公式测试结果
struct PickerTestResult {
    var display: String   // 逐条输出行的「名称: 最后一根有效值」，用三个空格拼接
    var hit: Bool         // 最后一条输出行的最后一根有效值 > 0 视为命中
    var error: String?    // 中文错误文案（nil 表示解析成功）
}

/// 公式库仓库：管理选股公式与策略公式（技术指标不在此处）
final class FormulaLibraryStore: ObservableObject {
    static let shared = FormulaLibraryStore()

    @Published private(set) var pickers: [FormulaDoc] = []
    @Published private(set) var strategies: [FormulaDoc] = []

    /// 策略库不可用说明（E-2）：引擎不可用时置文案（列表同时置空）——§9.10 fail-closed 显式空态。
    @Published private(set) var strategyLoadError: String?

    private let fileExt = "tdx"

    /// 引擎不可用时策略库的统一文案（§9.10：交易 / 回测 / 条件单 / 预警整体不可用）
    static let strategyUnavailableText = "Python 引擎不可用，交易策略暂不可用"

    private init() {
        // 选股公式库不涉引擎（无 TRADE 段）→ 同步加载，零行为变化
        reload(kind: .picker)
        // 策略库：`.swift`（过渡期默认）→ 同步加载，零行为变化；`.engine` → 异步（TRADE 段走引擎）
        if SimRulesBridge.mode == .swift {
            reload(kind: .strategy)
        } else {
            Task { await reloadStrategy() }
        }
    }

    // MARK: - 目录

    /// Documents/formula/<picker|strategy>（tech 返回 ""）
    static func dir(for kind: FormulaKind) -> String {
        guard let sub = kind.libraryDirName else { return "" }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("formula", isDirectory: true)
            .appendingPathComponent(sub, isDirectory: true).path
    }

    /// 确保公式库目录存在，返回其路径（tech 返回 nil）
    private static func ensureDir(_ kind: FormulaKind) -> String? {
        let d = dir(for: kind)
        guard !d.isEmpty else { return nil }
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: - 查询

    func docs(kind: FormulaKind) -> [FormulaDoc] {
        switch kind {
        case .picker: return pickers
        case .strategy: return strategies
        case .tech: return []   // 技术指标不归本仓库管理
        }
    }

    func doc(kind: FormulaKind, id: String) -> FormulaDoc? {
        docs(kind: kind).first { $0.id == id }
    }

    /// 按 id 取选股公式文本（供自选分组刷新选股使用），取不到返回 nil
    func formulaText(id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return resolvePickBody(id: id)
    }

    /// 按 id 取选股公式名称
    func pickerName(id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        if let p = pickers.first(where: { $0.id == id }) { return p.name }
        if let s = strategies.first(where: { $0.id == id }) { return s.name }
        return nil
    }

    /// 解析某 id 对应的选股正文：选股公式直接取；策略取内嵌 PICK，其次取 PICKREF 引用的选股公式
    private func resolvePickBody(id: String) -> String? {
        if let p = pickers.first(where: { $0.id == id }) { return p.pickBody }
        if let s = strategies.first(where: { $0.id == id }) {
            if !s.pickBody.isEmpty { return s.pickBody }
            if let ref = s.pickRef { return pickers.first(where: { $0.id == ref })?.pickBody }
        }
        return nil
    }

    // MARK: - 增删改

    /// 保存：doc.id 为空串视为新增（生成 id）；写文件后重载该类型；返回落盘后的 doc
    @discardableResult
    func save(_ doc: FormulaDoc) -> FormulaDoc? {
        guard doc.kind != .tech else { return nil }
        guard let dir = Self.ensureDir(doc.kind) else { return nil }
        var d = doc
        if d.id.isEmpty {
            d.id = nextID(kind: d.kind)
            if d.name.trimmingCharacters(in: .whitespaces).isEmpty { d.name = d.id }
        }
        // 文件名安全化（生成的 id 已是 ASCII，此处仅兜底）
        let file = CustomIndicatorStore.sanitized(d.id)
        guard !file.isEmpty else { return nil }
        d.id = file
        let path = dir + "/\(file).\(fileExt)"
        do {
            try Self.serialize(d).write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        reload(kind: d.kind)
        return self.doc(kind: d.kind, id: d.id)
    }

    /// 重命名：只改 NAME= 行，id 不变（保证引用不失效）
    @discardableResult
    func rename(kind: FormulaKind, id: String, to name: String) -> Bool {
        guard kind != .tech else { return false }
        guard var d = doc(kind: kind, id: id) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard let dir = Self.ensureDir(kind) else { return false }
        let file = CustomIndicatorStore.sanitized(id)
        guard !file.isEmpty else { return false }
        d.name = trimmed
        let path = dir + "/\(file).\(fileExt)"
        do {
            try Self.serialize(d).write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        reload(kind: kind)
        return self.doc(kind: kind, id: file)?.name == trimmed
    }

    func delete(kind: FormulaKind, id: String) {
        guard kind != .tech else { return }
        let dir = Self.dir(for: kind)
        guard !dir.isEmpty else { return }
        let file = CustomIndicatorStore.sanitized(id)
        guard !file.isEmpty else { return }
        let path = dir + "/\(file).\(fileExt)"
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        reload(kind: kind)
    }

    // MARK: - 加载

    func reload(kind: FormulaKind) {
        guard kind.libraryDirName != nil else { return }
        let dir = Self.dir(for: kind)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var result: [FormulaDoc] = []
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for f in files.sorted() where f.hasSuffix(".\(fileExt)") {
                let id = (f as NSString).deletingPathExtension
                let path = dir + "/" + f
                let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                // 解析失败（KIND 缺失 / 类型不符）直接跳过，不报错
                if let parsed = Self.parse(content: content, id: id, kind: kind) {
                    result.append(parsed)
                }
            }
        }
        // 值未变不写：同值赋值也会发布，避免发布风暴
        switch kind {
        case .picker:
            if pickers != result { pickers = result }
        case .strategy:
            if strategies != result { strategies = result }
        case .tech:
            break
        }
    }

    func reloadAll() {
        reload(kind: .picker)
        reload(kind: .strategy)
    }

    // MARK: - 策略库（引擎感知 · E-2）

    /// 重新加载交易策略库（TRADE 段走引擎）。
    /// - `.swift` 模式：走同步 `reload`（零行为变化）。
    /// - `.engine` 模式：逐个 `.tdx` 走 `FormulaKind.parseAsync`；**任一文件因引擎不可用失败 →
    ///   整体不可用**（列表置空 + `strategyLoadError`，§9.10 fail-closed），返回 `false`。
    @discardableResult
    @MainActor
    func reloadStrategy() async -> Bool {
        guard SimRulesBridge.mode == .engine else {
            reload(kind: .strategy)
            return true
        }
        let dir = Self.dir(for: .strategy)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var result: [FormulaDoc] = []
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for f in files.sorted() where f.hasSuffix(".\(fileExt)") {
                let id = (f as NSString).deletingPathExtension
                let content = (try? String(contentsOfFile: dir + "/" + f, encoding: .utf8)) ?? ""
                do {
                    if let parsed = try await Self.parseAsync(content: content, id: id,
                                                             kind: .strategy) {
                        result.append(parsed)
                    }
                } catch {
                    DebugLogger.shared.log("[FormulaLibraryStore] 策略库加载失败：\(error)")
                    strategies = []
                    strategyLoadError = Self.strategyUnavailableText
                    return false
                }
            }
        }
        // 值未变不写（与同步 `reload` 同口径）
        if strategies != result { strategies = result }
        strategyLoadError = nil
        return true
    }

    /// 保存交易策略（TRADE 段走引擎）。`.swift` 模式走同步 `save`（零行为变化）。
    /// 引擎不可用 → 不落盘、返回 nil 并置 `strategyLoadError`（fail-closed，**不静默用 Swift 序列化**）。
    @discardableResult
    @MainActor
    func saveStrategy(_ doc: FormulaDoc) async -> FormulaDoc? {
        guard doc.kind == .strategy else { return save(doc) }
        guard SimRulesBridge.mode == .engine else { return save(doc) }   // `.swift` 直通
        var d = doc
        if d.id.isEmpty {
            d.id = nextID(kind: .strategy)
            if d.name.trimmingCharacters(in: .whitespaces).isEmpty { d.name = d.id }
        }
        let file = CustomIndicatorStore.sanitized(d.id)
        guard !file.isEmpty, let dir = Self.ensureDir(.strategy) else { return nil }
        d.id = file
        let text: String
        do {
            text = try await Self.serializeAsync(d)
        } catch {
            DebugLogger.shared.log("[FormulaLibraryStore] 策略序列化失败：\(error)")
            strategyLoadError = Self.strategyUnavailableText
            return nil
        }
        do {
            try text.write(toFile: dir + "/\(file).\(fileExt)", atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        await reloadStrategy()
        return self.doc(kind: .strategy, id: d.id)
    }

    /// 删除交易策略。`.swift` 模式走同步 `delete`（零行为变化）。
    @MainActor
    func deleteStrategy(id: String) async {
        guard SimRulesBridge.mode == .engine else {
            delete(kind: .strategy, id: id)
            return
        }
        let file = CustomIndicatorStore.sanitized(id)
        guard !file.isEmpty, !Self.dir(for: .strategy).isEmpty else { return }
        let path = Self.dir(for: .strategy) + "/\(file).\(fileExt)"
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        await reloadStrategy()
    }

    /// 目录内最大序号 +1：picker → "PICK_<n>"，strategy → "STR_<n>"
    func nextID(kind: FormulaKind) -> String {
        let prefix: String
        switch kind {
        case .picker: prefix = "PICK_"
        case .strategy: prefix = "STR_"
        case .tech: return ""
        }
        var maxN = 0
        for d in docs(kind: kind) where d.id.hasPrefix(prefix) {
            if let n = Int(d.id.dropFirst(prefix.count)) { maxN = max(maxN, n) }
        }
        return prefix + String(maxN + 1)
    }

    /// 迁移导入：以给定名称在选股库中建公式（重名自动加序号后缀），返回新 id
    func importPicker(name: String, formula: String) -> String? {
        let base = name.trimmingCharacters(in: .whitespaces)
        let safeName = base.isEmpty ? "导入选股" : base
        var candidate = safeName
        var n = 2
        while pickers.contains(where: { $0.name == candidate }) {
            candidate = "\(safeName)_\(n)"
            n += 1
        }
        let doc = FormulaDoc(id: "", kind: .picker, name: candidate, pickBody: formula)
        return save(doc)?.id
    }

    // MARK: - 测试

    /// 在给定行情数据上求值（异步）：与既有 FormulaEditorView.runTest 的取值/格式化方式一致。
    /// 求值走 Python 引擎（后台线程），结果回调主线程；引擎未就绪/解析/求值失败 → error 文案
    func testPicker(formula: String, data: [KlineItem], completion: @escaping (PickerTestResult) -> Void) {
        guard !data.isEmpty else {
            completion(PickerTestResult(display: "", hit: false, error: "暂无行情数据用于测试"))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: PickerTestResult
            switch PyTDXFormulaBridge.evaluateText(formulas: [formula], data: data).first {
            case .some(.success(let lines)):
                let display = lines.map { line in
                    let last = line.values.last(where: { !$0.isNaN }).map { String(format: "%.3f", $0) } ?? "-"
                    return "\(line.name): \(last)"
                }.joined(separator: "   ")
                // 最后一条输出行的最后一根有效值 > 0 视为命中
                var hit = false
                if let lastLine = lines.last,
                   let v = lastLine.values.last(where: { !$0.isNaN }) {
                    hit = v > 0
                }
                result = PickerTestResult(display: display, hit: hit, error: nil)
            case .some(.failure(let msg)):
                result = PickerTestResult(display: "", hit: false, error: msg)
            case .none:
                result = PickerTestResult(display: "", hit: false, error: "内部错误")
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - 序列化 / 解析

    static func serialize(_ doc: FormulaDoc) -> String {
        serialize(doc, tradeText: doc.trade.isEmpty ? nil : StrategyTradeParser.serialize(doc.trade))
    }

    /// 同 `serialize`，但 TRADE 段走引擎（`.engine` 模式的生产写盘路径，E-2）。
    /// 结构切分（KIND= / NAME= / PICKREF= / PICK: / RULES:）仍留在 GUI 侧（§11.25）。
    /// ⚠️ 引擎不可用 → 抛错（调用方 fail-closed，见 `FormulaLibraryStore.saveStrategy`）。
    static func serializeAsync(_ doc: FormulaDoc) async throws -> String {
        var tradeText: String?
        if doc.kind == .strategy, !doc.trade.isEmpty {
            tradeText = try await SimRulesBridge.tradeSerialize(doc.trade)
        } else if !doc.trade.isEmpty {
            tradeText = StrategyTradeParser.serialize(doc.trade)
        }
        return serialize(doc, tradeText: tradeText)
    }

    /// 序列化正文（`tradeText` 已由调用方按后端取好；nil = 不输出 TRADE: 段）
    private static func serialize(_ doc: FormulaDoc, tradeText: String?) -> String {
        var out = "KIND=\(doc.kind.rawValue)\n"
        out += "NAME=\(doc.name)\n"
        if doc.kind == .strategy {
            // 顺序固定：PICKREF（头部键）→ TRADE: 段 → PICK: 段 → RULES: 段。
            // 头部键必须写在 TRADE: 段之前，否则会被当成 TRADE 段内容吞掉
            if let ref = doc.pickRef, !ref.isEmpty {
                out += "PICKREF=\(ref)\n"
            }
            if let tradeText {
                out += "TRADE:\n" + tradeText + "\n"
            }
            if !doc.pickBody.isEmpty {
                out += "PICK:\n\(doc.pickBody)\n"
            }
            out += "RULES:\n\(doc.rules)"
        } else {
            out += "FORMULA:\n\(doc.pickBody)"
        }
        return out
    }

    /// 段落切分（纯文件格式，GUI 侧职责）：KIND= 缺失、或与 kind 参数不一致时返回 nil。
    /// 返回的 `doc` **不含** TRADE 段取值（由调用方按后端补：`parse` 走 Swift / `parseAsync` 走引擎）。
    private static func structure(content: String, id: String, kind: FormulaKind)
        -> (doc: FormulaDoc, tradeLines: [String])? {
        var parsedKind: FormulaKind? = nil
        var name: String? = nil
        var pickRef: String? = nil
        var pickLines: [String] = []
        var ruleLines: [String] = []
        var tradeLines: [String] = []
        var inPick = false
        var inRules = false
        var inTrade = false

        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)

            // 段标记：FORMULA: 与 PICK: 都作为选股正文段的开始（FORMULA: 是兼容别名）
            if line == "FORMULA:" || line == "PICK:" {
                inPick = true
                inRules = false
                inTrade = false
                continue
            }
            if line == "RULES:" {
                inRules = true
                inPick = false
                inTrade = false
                continue
            }
            // TRADE: 仅策略使用；头部仍只认 KIND= / NAME= / PICKREF=
            if line == "TRADE:" {
                inTrade = true
                inPick = false
                inRules = false
                continue
            }

            if inTrade {
                // 兜底：头部键若出现在 TRADE: 段之后（手工编辑 / 旧顺序文件），退出 trade 段按头部键处理，
                // 避免 PICKREF= 被当成 TRADE 段内容吞掉导致引用丢失
                if line.hasPrefix("KIND=") || line.hasPrefix("NAME=") || line.hasPrefix("PICKREF=") {
                    inTrade = false
                } else {
                    // 段内忽略空行；{...} 注释行保留原样（交给 trade 解析器跳过）
                    if !line.isEmpty { tradeLines.append(line) }
                    continue
                }
            }
            if inPick {
                // 段内忽略空行；{...} 注释行保留原样
                if !line.isEmpty { pickLines.append(line) }
                continue
            }
            if inRules {
                if !line.isEmpty { ruleLines.append(line) }
                continue
            }

            // 头部键值（段开始前）
            if line.hasPrefix("KIND=") {
                let v = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces).uppercased()
                parsedKind = FormulaKind(rawValue: v)
            } else if line.hasPrefix("NAME=") {
                name = String(line.dropFirst(5))
            } else if line.hasPrefix("PICKREF=") {
                let v = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                pickRef = v.isEmpty ? nil : v
            }
        }

        // KIND= 缺失、无法识别、或与期望类型不一致 → nil
        guard let k = parsedKind, k == kind else { return nil }

        // NAME= 缺失时用 id 兜底
        let finalName: String
        if let n = name, !n.isEmpty {
            finalName = n
        } else {
            finalName = id
        }

        var doc = FormulaDoc(id: id, kind: kind, name: finalName,
                             pickBody: pickLines.joined(separator: "\n"))
        if kind == .strategy {
            doc.pickRef = pickRef
            doc.rules = ruleLines.joined(separator: "\n")
        }
        return (doc: doc, tradeLines: tradeLines)
    }

    /// 解析 .tdx 内容（`.swift` 直通：TRADE 段走 `StrategyTradeParser`，零行为变化）
    static func parse(content: String, id: String, kind: FormulaKind) -> FormulaDoc? {
        guard var r = structure(content: content, id: id, kind: kind) else { return nil }
        if kind == .strategy {
            // TRADE 段缺失（旧文件）→ 保持默认空值；段内解析错误不阻断文件加载，交给校验层报出
            r.doc.trade = StrategyTradeParser.parse(lines: r.tradeLines).spec
        }
        return r.doc
    }

    /// 同 `parse`，但 TRADE 段走引擎（`.engine` 模式的生产加载路径，E-2）。
    /// ⚠️ 引擎不可用 / 出参形状非法 → 抛错（调用方 fail-closed：策略库整体不可用，见
    /// `FormulaLibraryStore.reloadStrategy`）。
    static func parseAsync(content: String, id: String, kind: FormulaKind) async throws -> FormulaDoc? {
        guard var r = structure(content: content, id: id, kind: kind) else { return nil }
        if kind == .strategy {
            r.doc.trade = try await SimRulesBridge.tradeParse(lines: r.tradeLines).spec
        }
        return r.doc
    }
}
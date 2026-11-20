//
//  StrategyEditorBridge.swift
//  Kline
//
//  策略公式编辑器桥（协议 v2 strategyEdit.*）：P2-8b 策略公式编辑器 Web 化的 Swift 侧。
//
//  呈现链：Web 公式中心（原生 FormulaCenterView 策略段）「编辑/新建」→ requestOpen(doc) →
//  WebPageBridge.open("strategyEditor") 全屏 Web 页（route:"page"，shell 层呈现——
//  策略段入口只在 Home/Sim shell 的公式中心与个人中心，详情页不涉及）。
//  关闭后原生中心仍在其宿主层级（被 zIndex 1002 盖住），编辑器关闭即回到中心。
//
//  校验/预览全部同步直通（StrategyValidator / StrategyPreview 为纯 Swift，主线程安全）：
//  内嵌选股公式的语法校验走独立异步动作 testPick（Python 试算），结果经
//  strategyEdit.changed(pickTest) 推送，Web 端随后续 evaluate 带回 pickSyntaxError。
//  保存走引擎终校 fail-closed（SimRulesBridge.strategyValidate + library.saveStrategy）。
//
//  线程约定：动作入口均在主线程（native messageHandler 与 HTTP /bridge 皆主线程跳转）。
//

import Combine
import Foundation

@MainActor
final class StrategyEditorBridge: ObservableObject {

    static let shared = StrategyEditorBridge()

    /// 编辑中的策略文档（打开前暂存；id 空串 = 新建）
    private(set) var doc: FormulaDoc = FormulaDoc(id: "", kind: .strategy, name: "")

    /// 样例行情数据（候选池首只标的 K 线，供测试选股公式/语法校验；onOpen 异步加载）
    private var sampleData: [KlineItem] = []
    private var sampleLoaded = false

    // MARK: - 打开

    /// 原生公式中心策略段「编辑/新建」入口：暂存文档 → 打开全屏 Web 编辑器页
    func requestOpen(initialDoc: FormulaDoc) {
        doc = initialDoc
        WebPageBridge.shared.open("strategyEditor")
        loadSampleDataIfNeeded()
    }

    func onOpen() {
        loadSampleDataIfNeeded()
    }

    /// 样例行情加载（同 FormulaEditorBridge：候选池首只，就绪后推 dataReady）
    private func loadSampleDataIfNeeded() {
        guard !sampleLoaded, !DatabaseManager.shared.metaList.isEmpty else { return }
        guard let meta = DatabaseManager.shared.metaList.first else { return }
        sampleLoaded = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let bars = DatabaseManager.shared.fetchBars(metaId: meta.id, period: .daily)
                .sorted { $0.date < $1.date }
            DispatchQueue.main.async {
                self?.sampleData = bars
                WebMessageRouter.shared.pushEvent("strategyEdit.changed",
                                                  payload: ["reason": "dataReady"], route: "page")
            }
        }
    }

    /// 测试/语法校验的样例数据是否就绪
    private var hasData: Bool { sampleData.count > 0 }

    // MARK: - 动作分发

    static func handle(_ request: WebBridgeRequest) -> [String: Any] {
        switch request.action {
        case "snapshot":
            return snapshot(request)
        case "evaluate":
            return evaluate(request)
        case "testPick":
            return testPick(request)
        case "save":
            return save(request)
        default:
            return WebBridgeResponse.fail(request.id, code: "unknown_action",
                                          message: "strategyEdit.\(request.action) 未实现")
        }
    }

    // MARK: 快照

    /// strategyEdit.snapshot：编辑对象（rows 由初始 RULES 文本解析）+ 上下文（选股公式库 /
    /// 可绑定账户 / 规则目录）。规则目录静态下发，Web 端按 specs 动态渲染参数控件。
    private static func snapshot(_ request: WebBridgeRequest) -> [String: Any] {
        let bridge = shared
        let library = FormulaLibraryStore.shared
        let sim = SimStore.shared

        let parsed = StrategyRuleParser.parse(lines: bridge.doc.rules)
        let rowsAny: [[String: Any]] = parsed.rules.map {
            ["kind": $0.kind.rawValue, "params": $0.params]
        }
        let trade = bridge.doc.trade
        let docAny: [String: Any] = [
            "id": bridge.doc.id,
            "name": bridge.doc.name,
            "mode": (bridge.doc.pickRef ?? "").isEmpty ? "inline" : "reference",
            "pickBody": bridge.doc.pickBody,
            "pickRef": bridge.doc.pickRef ?? "",
            "rows": rowsAny,
            "parseErrors": parsed.errors,
            "trade": tradeAny(trade),
        ]

        let pickersAny: [[String: Any]] = library.pickers.map {
            ["id": $0.id, "name": $0.name, "pickBody": $0.pickBody]
        }
        let accountsAny: [[String: Any]] = sim.accounts.map {
            ["id": $0.id.uuidString, "name": $0.name, "badge": $0.badge,
             "colorHex": $0.colorHex, "cash": $0.cash, "archived": $0.isArchived]
        }
        let catalogAny: [[String: Any]] = StrategyRuleKind.allCases.map { kind in
            let specs: [[String: Any]] = StrategyRuleCatalog.specs(for: kind).map {
                ["key": $0.key, "title": $0.title, "type": paramTypeName($0.type),
                 "isOptional": $0.isOptional, "placeholder": $0.placeholder,
                 "options": $0.options, "unit": $0.unit]
            }
            return ["kind": kind.rawValue, "title": kind.title,
                    "conditionOrderTitle": kind.conditionOrderTitle, "specs": specs]
        }

        return WebBridgeResponse.ok(request.id, data: [
            "doc": docAny,
            "pickers": pickersAny,
            "accounts": accountsAny,
            "ruleCatalog": catalogAny,
            "hasData": bridge.hasData,
        ])
    }

    private static func paramTypeName(_ t: StrategyParamType) -> String {
        switch t {
        case .number: return "number"
        case .percent: return "percent"
        case .integer: return "integer"
        case .text: return "text"
        case .option: return "option"
        }
    }

    private static func tradeAny(_ t: StrategyTradeSpec) -> [String: Any] {
        ["direction": t.direction?.rawValue ?? "",
         "qty": t.qty ?? 0,
         "hasQty": t.qty != nil,
         "amount": t.amount ?? 0,
         "hasAmount": t.amount != nil,
         "priceType": t.priceType?.rawValue ?? "",
         "offsetTicks": t.offsetTicks ?? 0,
         "hasOffset": t.offsetTicks != nil,
         "validity": t.validity?.rawValue ?? "",
         // 到期日用 YYYY-MM-DD 文本（与 TRADE 段 EXPIRES 序列化口径一致；日期精度足够）
         "expiresAt": t.expiresAt.map(StrategyTradeParser.text(from:)) ?? "",
         "accountIDs": t.accountIDs.map(\.uuidString)]
    }

    // MARK: - 文档 payload → FormulaDoc

    /// Web 端编辑态 → FormulaDoc（rows 结构化 → RULES 文本逐行序列化，纯 Swift 同步）。
    /// 解析失败（kind 非法）返回 nil → fail invalid_payload。
    private static func doc(fromPayload p: [String: Any]) -> FormulaDoc? {
        let name = (p["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let mode = p["mode"] as? String ?? "inline"
        let pickBody = p["pickBody"] as? String ?? ""
        let pickRef = p["pickRef"] as? String ?? ""
        let rowsAny = p["rows"] as? [[String: Any]] ?? []
        let tradeAny = p["trade"] as? [String: Any] ?? [:]

        var calls: [StrategyRuleCall] = []
        for row in rowsAny {
            guard let kindRaw = row["kind"] as? String,
                  let kind = StrategyRuleKind(rawValue: kindRaw),
                  let params = row["params"] as? [String: String] else { return nil }
            calls.append(StrategyRuleCall(kind: kind, params: params, raw: ""))
        }
        let rulesText = calls.map { StrategyRuleParser.line(for: $0) }.joined(separator: "\n")

        var trade = StrategyTradeSpec()
        trade.direction = SimOrderDirection(rawValue: tradeAny["direction"] as? String ?? "")
        if (tradeAny["hasQty"] as? Bool) == true { trade.qty = (tradeAny["qty"] as? NSNumber)?.intValue }
        if (tradeAny["hasAmount"] as? Bool) == true { trade.amount = (tradeAny["amount"] as? NSNumber)?.doubleValue }
        trade.priceType = SimPriceType(rawValue: tradeAny["priceType"] as? String ?? "")
        if (tradeAny["hasOffset"] as? Bool) == true { trade.offsetTicks = (tradeAny["offsetTicks"] as? NSNumber)?.intValue }
        trade.validity = SimCondValidity(rawValue: tradeAny["validity"] as? String ?? "")
        if let text = tradeAny["expiresAt"] as? String, !text.isEmpty {
            trade.expiresAt = StrategyTradeParser.date(from: text)
        }
        trade.accountIDs = ((tradeAny["accountIDs"] as? [String]) ?? []).compactMap(UUID.init(uuidString:))

        return FormulaDoc(id: p["id"] as? String ?? "",
                          kind: .strategy,
                          name: name,
                          pickBody: mode == "inline" ? pickBody : "",
                          pickRef: mode == "reference" ? pickRef : nil,
                          rules: rulesText,
                          trade: trade)
    }

    /// PICKREF 指向的选股公式是否仍存在
    private static func pickerExists(_ pickRef: String) -> Bool {
        guard !pickRef.isEmpty else { return false }
        return FormulaLibraryStore.shared.doc(kind: .picker, id: pickRef) != nil
    }

    /// Web 端语法校验结果归一化：空串 = 通过（nil）；非空 = 错误文案
    private static func normalizedSyntaxError(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    // MARK: 校验 + 预览（同步直通）

    /// strategyEdit.evaluate {doc, pickSyntaxError}：静态校验 + 语义预览（纯 Swift 同步，
    /// 主线程安全）。Web 端每次文档变化（防抖）后调用；pickSyntaxError 由 Web 端持有
    /// 最近一次 testPick 的语法校验结果（nil = 通过或无内嵌）。
    private static func evaluate(_ request: WebBridgeRequest) -> [String: Any] {
        guard let docPayload = request.payload["doc"] as? [String: Any],
              let doc = doc(fromPayload: docPayload) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "doc 解析失败")
        }
        let pickSyntaxError = normalizedSyntaxError(request.payload["pickSyntaxError"] as? String)
        let ref = doc.pickRef ?? ""
        let exists = pickerExists(ref)

        var issues = StrategyValidator.validate(doc: doc, pickerExists: exists,
                                                pickSyntaxError: pickSyntaxError)
        if doc.name.trimmingCharacters(in: .whitespaces).isEmpty && !issues.contains("请填写策略名称") {
            issues.insert("请填写策略名称", at: 0)
        }
        let preview: [String: Any] = [
            "trade": StrategyPreview.tradeSummary(doc: doc),
            "summary": StrategyPreview.summary(doc: doc, pickerName: libraryPickerName(ref)),
            "executionNotice": StrategyPreview.executionNotice,
        ]
        return WebBridgeResponse.ok(request.id, data: [
            "ready": true,
            "issues": issues,
            "preview": preview,
        ])
    }

    private static func libraryPickerName(_ id: String) -> String? {
        guard !id.isEmpty else { return nil }
        return FormulaLibraryStore.shared.pickerName(id: id)
    }

    // MARK: 内嵌公式测试 + 语法校验（异步）

    /// strategyEdit.testPick {pickBody}：样例行情试算（FormulaLibraryStore.testPicker，后台回调），
    /// 结果推 strategyEdit.changed(pickTest)：{syntaxError, testMessage, testIsError}。
    /// 样例数据未就绪 / 空公式 → syntaxError 空（语法校验旁路，与原生编辑器一致）。
    private static func testPick(_ request: WebBridgeRequest) -> [String: Any] {
        let body = (request.payload["pickBody"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let data = shared.sampleData
        FormulaLibraryStore.shared.testPicker(formula: body, data: data) { result in
            DispatchQueue.main.async {
                var payload: [String: Any] = ["reason": "pickTest",
                                              "syntaxError": "", "testMessage": "", "testIsError": false]
                if let err = result.error {
                    payload["syntaxError"] = err
                    payload["testMessage"] = "✗ \(err)"
                    payload["testIsError"] = true
                } else {
                    let verdict = result.hit ? "命中：最后一根输出值 > 0" : "未命中：最后一根输出值 ≤ 0"
                    payload["testMessage"] = "✓ 解析成功\n\(result.display)\n\(verdict)"
                }
                WebMessageRouter.shared.pushEvent("strategyEdit.changed", payload: payload, route: "page")
            }
        }
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    // MARK: 保存

    /// strategyEdit.save {doc, pickSyntaxError}：
    /// 同步静态校验不过 → 立即 fail（中文文案）；过 → {queued} 后台引擎终校 +
    /// 写公式库（fail-closed），结果经 changed(saveResult) 推送，成功即原生关页。
    private static func save(_ request: WebBridgeRequest) -> [String: Any] {
        guard let docPayload = request.payload["doc"] as? [String: Any],
              let doc = doc(fromPayload: docPayload) else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "doc 解析失败")
        }
        let pickSyntaxError = normalizedSyntaxError(request.payload["pickSyntaxError"] as? String)
        let ref = doc.pickRef ?? ""

        // 第一道：静态校验（同步，纯 Swift）——不过直接 fail，反馈零延迟
        let issues = StrategyValidator.validate(doc: doc, pickerExists: pickerExists(ref),
                                                pickSyntaxError: pickSyntaxError)
        if doc.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: "请填写策略名称")
        }
        guard issues.isEmpty else {
            return WebBridgeResponse.fail(request.id, code: "invalid_payload", message: issues.first ?? "校验未通过")
        }

        // 第二道：引擎终校 + 写库（后台，fail-closed）
        let exists = pickerExists(ref)
        Task { @MainActor in
            var payload: [String: Any] = ["reason": "saveResult", "ok": false, "error": ""]
            do {
                let engineIssues = try await SimRulesBridge.strategyValidate(
                    doc: doc, pickerExists: exists, pickSyntaxError: pickSyntaxError)
                guard engineIssues.isEmpty else {
                    payload["error"] = engineIssues.first ?? "校验未通过"
                    WebMessageRouter.shared.pushEvent("strategyEdit.changed", payload: payload, route: "page")
                    return
                }
            } catch {
                payload["error"] = "Python 引擎不可用，暂不能保存，请稍后重试"
                WebMessageRouter.shared.pushEvent("strategyEdit.changed", payload: payload, route: "page")
                return
            }
            guard let saved = await FormulaLibraryStore.shared.saveStrategy(doc) else {
                payload["error"] = FormulaLibraryStore.shared.strategyLoadError ?? "保存失败，请检查公式内容"
                WebMessageRouter.shared.pushEvent("strategyEdit.changed", payload: payload, route: "page")
                return
            }
            DebugLogger.shared.log("[StrategyEditorBridge] saved \(saved.name) id=\(saved.id)")
            WebMessageRouter.shared.pushEvent("strategyEdit.changed",
                                              payload: ["reason": "saveResult", "ok": true, "error": ""],
                                              route: "page")
            shared.closePage()
        }
        return WebBridgeResponse.ok(request.id, data: ["queued": true])
    }

    private func closePage() {
        WebPageBridge.shared.close()
    }
}

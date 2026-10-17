//
//  SimRulesCodec.swift
//  Kline
//
//  阶段 A5-2：交易判定「生产编解码层」——Swift 生产模型 ↔ `sim_rules.py` op JSON。
//
//  角色（与 `SimRulesBridge` 分工）：
//    · `SimRulesBridge` = 过渡期**双跑门面**：JSON 入参 → JSON 出参（`.swift` 投影 /
//      `.engine` 转发）。它服务「契约测试」与「Swift 现状 dump」。
//    · 本文件 = **生产**编解码：把 App 的领域模型（`SimCondOrder` / `FormulaDoc` /
//      `BacktestParams` …）编成 op 入参 JSON，把引擎出参 JSON 反解回领域模型。
//      业务调用点只与本层打交道（A5-4 逐子系统切换）。
//
//  单一来源：JSON ↔ Swift 的**双向**转换只在本文件实现一次；`SimRulesBridge` 的
//  同名方向一律委派到此处，避免两份漂移（哪个方向漂了，A1/A3/A4 契约测试会红）。
//
//  口径：与 §11.2 / §11.6 完全一致——枚举用 rawValue；日期 ISO8601 字符串；
//  时间相关 op 显式带 `tzOffsetSeconds`（iOS 沙盒无保证 tzdata，不用 IANA 名）。
//

import Foundation

nonisolated enum SimRulesCodec {

    enum CodecError: Error, CustomStringConvertible {
        case badShape(String)
        var description: String {
            switch self { case .badShape(let k): return "引擎出参形状非法：缺 \(k)" }
        }
    }

    // MARK: - 基础转换（JSON → Swift）

    static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

    static func num(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber else { return nil }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        return n.doubleValue
    }

    static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    static func str(_ v: Any?) -> String? { v as? String }

    static func uuid(_ v: Any?) -> UUID? { (v as? String).flatMap { UUID(uuidString: $0) } }

    static func isoDate(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    static func isoString(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    static func dateList(_ v: Any?) -> [Int] { (v as? [Any])?.compactMap { int($0) } ?? [] }

    // MARK: - 交易标的与账户（JSON → Swift）

    static func metaItemFromJSON(_ any: Any?) -> MetaItem {
        let d = (any as? [String: Any]) ?? [:]
        return MetaItem(id: int(d["id"]) ?? 0, file: str(d["file"]) ?? "",
                        code: str(d["code"]) ?? "", name: str(d["name"]) ?? "标的",
                        type: str(d["type"]) ?? "股票", firstDate: nil, lastDate: nil)
    }

    static func accountFromJSON(_ any: Any?) -> SimAccount {
        let d = (any as? [String: Any]) ?? [:]
        return SimAccount(id: uuid(d["id"]) ?? UUID(),
                          name: str(d["name"]) ?? "账户", badge: "主", colorHex: "#1E5FA8",
                          initialCapital: num(d["initialCapital"]) ?? 1_000_000,
                          cash: num(d["cash"]) ?? 0,
                          createdAt: Date(timeIntervalSince1970: 0),
                          isArchived: bool(d["isArchived"]) ?? false)
    }

    static func positionFromJSON(_ any: Any?) -> SimPosition? {
        guard let any, let d = any as? [String: Any] else { return nil }
        return SimPosition(id: UUID(), accountID: uuid(d["accountID"]) ?? UUID(),
                           metaID: int(d["metaID"]) ?? 0, code: str(d["code"]) ?? "",
                           name: str(d["name"]) ?? "",
                           qty: int(d["qty"]) ?? 0, availableQty: int(d["availableQty"]) ?? 0,
                           costPrice: num(d["costPrice"]) ?? 0,
                           openedAt: Date(timeIntervalSince1970: 0))
    }

    static func snapshotFromJSON(_ any: Any?) -> SimCondSnapshot {
        let d = (any as? [String: Any]) ?? [:]
        return SimCondSnapshot(last: num(d["last"]), prevClose: num(d["prevClose"]),
                               high: num(d["high"]), low: num(d["low"]),
                               changePct: num(d["changePct"]), ma: num(d["ma"]))
    }

    // MARK: - 通用 Codable 桥（引擎契约形状 == Swift Codable 形状，双向对称）

    static func decodeJSON<T: Decodable>(_ type: T.Type, from any: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: any)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(type, from: data)
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> [String: Any] {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(value)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodecError.badShape("encodeJSON")
        }
        return obj
    }

    // MARK: - 条件单（双向）

    /// live 条件单 → 引擎 `order` JSON（Codable 对称编码，见 `condOrderFromJSON`）。
    static func condOrderJSON(_ order: SimCondOrder) -> [String: Any]? {
        try? encodeJSON(order)
    }

    /// 引擎 `order` JSON → `SimCondOrder`（缺失键取默认；空对象也可）。
    static func condOrderFromJSON(_ any: Any?) throws -> SimCondOrder {
        try decodeJSON(SimCondOrder.self, from: any ?? [:] as [String: Any])
    }

    /// 条件单指令 → 引擎 JSON（`cond_execution_price` 入参）。
    static func directiveJSON(_ d: SimCondDirective) -> [String: Any] {
        var o: [String: Any] = ["direction": d.direction.rawValue,
                                "priceType": d.priceType.rawValue,
                                "offsetTicks": d.offsetTicks,
                                "qty": d.qty]
        if let a = d.alertOnly { o["alertOnly"] = a }
        return o
    }

    // MARK: - 判定 / 结算 / 交易规则（A5-4：领域模型的写出与写回）

    /// 行情快照 → 引擎 JSON。**缺项不写键**（两侧同口径：缺键 = nil）。
    static func snapshotJSON(_ s: SimCondSnapshot) -> [String: Any] {
        var o: [String: Any] = [:]
        if let v = s.last { o["last"] = v }
        if let v = s.prevClose { o["prevClose"] = v }
        if let v = s.high { o["high"] = v }
        if let v = s.low { o["low"] = v }
        if let v = s.changePct { o["changePct"] = v }
        if let v = s.ma { o["ma"] = v }
        return o
    }

    /// 条件单运行时 ← 引擎 JSON（缺失键取默认；与 `SimCondRuntime` 自身的宽容解码同口径）。
    static func runtimeFromJSON(_ any: Any?) -> SimCondRuntime {
        (try? decodeJSON(SimCondRuntime.self, from: any ?? [:] as [String: Any])) ?? SimCondRuntime()
    }

    /// 判定结果 ← 引擎 JSON（`cond_evaluate` 的 `result`）。
    /// 形状见 §11.6 / `SimRulesBridge.decisionJSON`；未知 `decision` → nil（调用方按降级处理）。
    static func condDecisionFromJSON(_ any: Any?) -> SimCondDecision? {
        guard let d = any as? [String: Any], let kind = str(d["decision"]) else { return nil }
        switch kind {
        case "fire":     return .fire(qty: int(d["qty"]) ?? 0, at: num(d["at"]) ?? 0)
        case "hold":     return .hold(runtimeFromJSON(d["runtime"]))
        case "abort":    return .abort(str(d["reason"]) ?? "")
        case "complete": return .complete(str(d["reason"]) ?? "")
        default:         return nil
        }
    }

    /// 建单拒绝 ← 引擎 JSON（`cond_validate_create` 的 `result`；nil = 通过）。
    static func condRejectionFromJSON(_ any: Any?) -> SimCondRejection? {
        guard let d = any as? [String: Any], let code = str(d["code"]) else { return nil }
        switch code {
        case "accountUnavailable": return .accountUnavailable
        case "noQuote":            return .noQuote
        case "noPosition":         return .noPosition
        case "invalidOCORange":    return .invalidOCORange
        case "invalidGridRange":   return .invalidGridRange
        case "invalidGridStep":    return .invalidGridStep
        case "invalidBatchCount":  return .invalidBatchCount
        case "invalidFireDate":    return .invalidFireDate
        case "invalidQty":         return .invalidQty(lot: int(d["lot"]) ?? 0)
        case "batchTooSmall":      return .batchTooSmall(lot: int(d["lot"]) ?? 0)
        case "missingParam":       return .missingParam(str(d["name"]) ?? "")
        default:                   return nil
        }
    }

    /// 下单拒绝 ← 引擎 JSON（`trade_validate` 的 `result`；nil = 通过）。
    /// ⚠️ `insufficientCash` 的 `available` 是 Double、`insufficientShares` 的 `available` 是 Int
    /// （与 `SimRulesBridge.orderRejectionJSON` 严格对称）。
    static func orderRejectionFromJSON(_ any: Any?) -> SimOrderRejection? {
        guard let d = any as? [String: Any], let code = str(d["code"]) else { return nil }
        switch code {
        case "emptyAccount":       return .emptyAccount
        case "noQuote":            return .noQuote
        case "notLotMultiple":     return .notLotMultiple(lot: int(d["lot"]) ?? 0)
        case "insufficientCash":
            return .insufficientCash(available: num(d["available"]) ?? 0,
                                     affordableQty: int(d["affordableQty"]) ?? 0)
        case "insufficientShares": return .insufficientShares(available: int(d["available"]) ?? 0)
        case "priceOutOfLimit":    return .priceOutOfLimit(lower: num(d["lower"]) ?? 0,
                                                           upper: num(d["upper"]) ?? 0)
        default:                   return nil
        }
    }

    /// 下单草稿 → 引擎 JSON（`trade_validate` 入参）。
    static func orderDraftJSON(_ d: SimOrderDraft) -> [String: Any] {
        var o: [String: Any] = ["accountID": d.accountID.uuidString,
                                "metaID": d.metaID, "code": d.code, "name": d.name,
                                "direction": d.direction.rawValue,
                                "priceType": d.priceType.rawValue, "qty": d.qty]
        if let p = d.price { o["price"] = p }
        return o
    }

    /// 账户 → 引擎 JSON（`trade_validate` 入参；键集是 fixture `account` 的超集，多出的键两侧都不读）。
    static func accountJSON(_ a: SimAccount) -> [String: Any] {
        ["id": a.id.uuidString, "name": a.name, "cash": a.cash,
         "initialCapital": a.initialCapital, "isArchived": a.isArchived]
    }

    /// 持仓 → 引擎 JSON（`trade_validate` / `trade_calc.sellableQty` 入参）。
    static func positionJSON(_ p: SimPosition) -> [String: Any] {
        ["accountID": p.accountID.uuidString, "metaID": p.metaID, "code": p.code, "name": p.name,
         "qty": p.qty, "availableQty": p.availableQty, "costPrice": p.costPrice]
    }

    // MARK: - 策略交易规格（双向）

    static func tradeSpecFromJSON(_ any: Any?) -> StrategyTradeSpec {
        let d = (any as? [String: Any]) ?? [:]
        var s = StrategyTradeSpec()
        s.direction = (d["direction"] as? String).flatMap(SimOrderDirection.init(rawValue:))
        s.qty = int(d["qty"])
        s.amount = num(d["amount"])
        s.priceType = (d["priceType"] as? String).flatMap(SimPriceType.init(rawValue:))
        s.offsetTicks = int(d["offsetTicks"])
        s.validity = (d["validity"] as? String).flatMap(SimCondValidity.init(rawValue:))
        s.expiresAt = isoDate(d["expiresAt"])
        s.accountIDs = (d["accountIDs"] as? [String])?.compactMap { UUID(uuidString: $0) } ?? []
        return s
    }

    static func tradeSpecJSON(_ s: StrategyTradeSpec) -> [String: Any] {
        ["direction": s.direction?.rawValue ?? NSNull(),
         "qty": s.qty ?? NSNull(),
         "amount": s.amount ?? NSNull(),
         "priceType": s.priceType?.rawValue ?? NSNull(),
         "offsetTicks": s.offsetTicks ?? NSNull(),
         "validity": s.validity?.rawValue ?? NSNull(),
         "expiresAt": s.expiresAt.map { isoString($0) } ?? NSNull(),
         "accountIDs": s.accountIDs.map { $0.uuidString }]
    }

    // MARK: - 策略条件单草稿（双向，D 组）

    /// 标的 → 引擎 JSON（`strategy_drafts` / `strategy_entry_draft` 入参）。
    static func metaItemJSON(_ m: MetaItem) -> [String: Any] {
        ["id": m.id, "code": m.code, "name": m.name]
    }

    /// 策略草稿 → 引擎 JSON（两个 D 组 op 的出参形状，亦是 A1 dump 的写入形状）。
    static func strategyDraftJSON(_ d: StrategyCondDraft) throws -> [String: Any] {
        var o: [String: Any] = [
            "accountID": d.accountID.uuidString,
            "metaID": d.metaID,
            "code": d.code,
            "name": d.name,
            "kind": d.kind.rawValue,
            "params": try encodeJSON(d.params),
            "directive": ["direction": d.directive.direction.rawValue,
                          "priceType": d.directive.priceType.rawValue,
                          "offsetTicks": d.directive.offsetTicks,
                          "qty": d.directive.qty],
            "validity": d.validity.rawValue,
        ]
        if d.validity == .untilDate, let e = d.expiresAt { o["expiresAt"] = isoString(e) }
        return o
    }

    /// 引擎 JSON → 策略草稿。缺键 / 枚举非法即抛（形状非法不静默兜底）。
    static func strategyDraftFromJSON(_ any: Any?) throws -> StrategyCondDraft {
        guard let d = any as? [String: Any],
              let accountID = uuid(d["accountID"]),
              let kind = str(d["kind"]).flatMap(SimCondKind.init(rawValue:)),
              let validity = str(d["validity"]).flatMap(SimCondValidity.init(rawValue:)),
              let dir = d["directive"] as? [String: Any],
              let direction = str(dir["direction"]).flatMap(SimOrderDirection.init(rawValue:)),
              let priceType = str(dir["priceType"]).flatMap(SimPriceType.init(rawValue:)),
              let paramsJSON = d["params"] as? [String: Any] else {
            throw CodecError.badShape("strategyDraft")
        }
        return StrategyCondDraft(accountID: accountID,
                                 metaID: int(d["metaID"]) ?? 0,
                                 code: str(d["code"]) ?? "",
                                 name: str(d["name"]) ?? "",
                                 kind: kind,
                                 params: try decodeJSON(SimCondParams.self, from: paramsJSON),
                                 directive: SimCondDirective(direction: direction,
                                                             priceType: priceType,
                                                             offsetTicks: int(dir["offsetTicks"]) ?? 0,
                                                             qty: int(dir["qty"]) ?? 0),
                                 validity: validity,
                                 expiresAt: isoDate(d["expiresAt"]))
    }

    // MARK: - 公式文档（双向）

    static func formulaDocFromJSON(_ any: Any?) -> FormulaDoc {
        let d = (any as? [String: Any]) ?? [:]
        let kind = (d["kind"] as? String).flatMap(FormulaKind.init(rawValue:)) ?? .strategy
        return FormulaDoc(id: "strategy", kind: kind,
                          name: str(d["name"]) ?? "策略",
                          pickBody: str(d["pickBody"]) ?? "",
                          pickRef: str(d["pickRef"]),
                          rules: str(d["rules"]) ?? "",
                          trade: tradeSpecFromJSON(d["trade"]))
    }

    static func formulaDocJSON(_ doc: FormulaDoc) -> [String: Any] {
        ["kind": doc.kind.rawValue,
         "name": doc.name,
         "pickBody": doc.pickBody,
         "pickRef": doc.pickRef ?? NSNull(),
         "rules": doc.rules,
         "trade": tradeSpecJSON(doc.trade)]
    }

    // MARK: - 策略 DSL（双向，E 组）

    /// 规则目录条目（`strategy_catalog` 出参单元）。
    struct StrategyCatalogEntry {
        var title: String
        var conditionOrderTitle: String
        var simCondKind: String
        var specs: [StrategyParamSpec]
        var knownKeys: [String]
    }

    /// 语义预览结果（`strategy_preview` 出参，全为展示文案）。
    struct StrategyPreviewResult {
        var summary: String
        var pick: String
        var trade: String
        var executionNotice: String
        var triggers: [String]
    }

    /// `[String: Any]` → `[String: String]`（`JSONSerialization` 的字典值不是 `String` 静态类型）。
    static func stringMap(_ v: Any?) -> [String: String] {
        guard let d = v as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, val) in d { out[k] = str(val) ?? "" }
        return out
    }

    /// 规则调用 → 引擎 JSON（`strategy_parse` 出参元素，亦是 `strategy_rule_line` / `trade_override` 的入参形状）。
    static func ruleCallJSON(_ c: StrategyRuleCall) -> [String: Any] {
        ["kind": c.kind.rawValue, "params": c.params, "raw": c.raw, "line": c.line]
    }

    /// 引擎 JSON → 规则调用。`kind` 非法即抛（形状非法不静默兜底）。
    static func ruleCallFromJSON(_ any: Any?) throws -> StrategyRuleCall {
        guard let d = any as? [String: Any],
              let raw = str(d["kind"]),
              let kind = StrategyRuleKind(rawValue: raw) else {
            throw CodecError.badShape("ruleCall.kind")
        }
        return StrategyRuleCall(kind: kind, params: stringMap(d["params"]),
                                raw: str(d["raw"]) ?? "", line: int(d["line"]) ?? 0)
    }

    static func paramTypeName(_ t: StrategyParamType) -> String {
        switch t {
        case .number: return "number"
        case .percent: return "percent"
        case .integer: return "integer"
        case .text: return "text"
        case .option: return "option"
        }
    }

    static func paramTypeFromName(_ v: Any?) -> StrategyParamType? {
        switch str(v) {
        case "number": return .number
        case "percent": return .percent
        case "integer": return .integer
        case "text": return .text
        case "option": return .option
        default: return nil
        }
    }

    static func paramSpecJSON(_ s: StrategyParamSpec) -> [String: Any] {
        ["key": s.key, "title": s.title, "type": paramTypeName(s.type),
         "isOptional": s.isOptional, "placeholder": s.placeholder,
         "options": s.options, "unit": s.unit]
    }

    /// 引擎 JSON → 参数规格（缺 `key` 或 `type` 非法 → nil，调用方按「未知规格」跳过）。
    static func paramSpecFromJSON(_ any: Any?) -> StrategyParamSpec? {
        guard let d = any as? [String: Any],
              let key = str(d["key"]),
              let type = paramTypeFromName(d["type"]) else { return nil }
        return StrategyParamSpec(key: key, title: str(d["title"]) ?? key,
                                 type: type,
                                 isOptional: bool(d["isOptional"]) ?? false,
                                 placeholder: str(d["placeholder"]) ?? "",
                                 options: (d["options"] as? [String]) ?? [],
                                 unit: str(d["unit"]) ?? "")
    }

    /// 引擎 JSON → 规则目录（`kind` 非法或有残缺的条目直接跳过，不整批失败）。
    static func catalogFromJSON(_ any: Any?) -> [StrategyRuleKind: StrategyCatalogEntry] {
        guard let d = any as? [String: Any] else { return [:] }
        var out: [StrategyRuleKind: StrategyCatalogEntry] = [:]
        for (raw, v) in d {
            guard let kind = StrategyRuleKind(rawValue: raw),
                  let e = v as? [String: Any] else { continue }
            out[kind] = StrategyCatalogEntry(
                title: str(e["title"]) ?? kind.title,
                conditionOrderTitle: str(e["conditionOrderTitle"]) ?? kind.conditionOrderTitle,
                simCondKind: str(e["simCondKind"]) ?? "",
                specs: ((e["specs"] as? [Any]) ?? []).compactMap { paramSpecFromJSON($0) },
                knownKeys: (e["knownKeys"] as? [String]) ?? [])
        }
        return out
    }

    static func previewFromJSON(_ any: Any?) -> StrategyPreviewResult? {
        guard let d = any as? [String: Any] else { return nil }
        return StrategyPreviewResult(summary: str(d["summary"]) ?? "",
                                     pick: str(d["pick"]) ?? "",
                                     trade: str(d["trade"]) ?? "",
                                     executionNotice: str(d["executionNotice"]) ?? "",
                                     triggers: (d["triggers"] as? [String]) ?? [])
    }

    static func directiveOverrideJSON(_ o: StrategyDirectiveOverride) -> [String: Any] {
        ["dir": o.dir?.rawValue ?? NSNull(),
         "qty": o.qty ?? NSNull(),
         "amount": o.amount ?? NSNull(),
         "priceType": o.priceType?.rawValue ?? NSNull(),
         "offsetTicks": o.offsetTicks ?? NSNull()]
    }

    /// 引擎 JSON → 规则行内指令覆盖（`isEmpty` 由本地按字段推导，与 `StrategyDirectiveOverride.isEmpty` 同义）。
    static func directiveOverrideFromJSON(_ any: Any?) -> StrategyDirectiveOverride {
        let d = (any as? [String: Any]) ?? [:]
        var o = StrategyDirectiveOverride()
        o.dir = str(d["dir"]).flatMap(SimOrderDirection.init(rawValue:))
        o.qty = int(d["qty"])
        o.amount = num(d["amount"])
        o.priceType = str(d["priceType"]).flatMap(SimPriceType.init(rawValue:))
        o.offsetTicks = int(d["offsetTicks"])
        return o
    }

    // MARK: - 回测：生产模型 → op 入参 JSON

    /// 回测入参（与 `KlineTests/Fixtures/backtest_golden.json` 的 input 同形状）。
    /// `tzOffsetSeconds`：Swift 侧用 `Calendar.current`（含 DST），引擎用固定偏移；
    /// 生产调用点传 `TimeZone.current.secondsFromGMT()`。注意 DST 时区下二者可能相差
    /// 一小时（§11.5 已知限制；回测窗口切日边界影响极小，暂不引入 IANA tzdata）。
    static func backtestInput(doc: FormulaDoc, bars: [Int: [KlineItem]],
                              pickHits: [Int: Set<Int>], metas: [Int: MetaItem],
                              params: BacktestParams, tzOffsetSeconds: Int) -> [String: Any] {
        var barsJSON: [String: Any] = [:]
        for (mid, arr) in bars {
            barsJSON[String(mid)] = arr.map { b -> [String: Any] in
                ["date": b.date, "open": b.open, "high": b.high, "low": b.low, "close": b.close]
            }
        }
        var hitsJSON: [String: Any] = [:]
        for (mid, set) in pickHits { hitsJSON[String(mid)] = set.sorted() }
        var metasJSON: [String: Any] = [:]
        for (mid, m) in metas {
            metasJSON[String(mid)] = ["id": m.id, "code": m.code, "name": m.name]
        }
        return ["doc": formulaDocJSON(doc),
                "params": ["days": params.days, "initialCapital": params.initialCapital,
                           "executeNextOpen": params.executeNextOpen,
                           "includeEntry": params.includeEntry],
                "bars": barsJSON,
                "pickHits": hitsJSON,
                "metas": metasJSON,
                "tzOffsetSeconds": tzOffsetSeconds]
    }

    /// 回测入参反解（测试与引擎契约用；生产不需要——生产从活的模型直接编码）。
    static func backtestInputDecode(_ input: [String: Any])
        -> (doc: FormulaDoc, bars: [Int: [KlineItem]], pickHits: [Int: Set<Int>],
            metas: [Int: MetaItem], params: BacktestParams, tzOffsetSeconds: Int) {
        let doc = formulaDocFromJSON(input["doc"])
        var bars: [Int: [KlineItem]] = [:]
        for (k, v) in (input["bars"] as? [String: Any]) ?? [:] {
            guard let mid = Int(k), let arr = v as? [[String: Any]] else { continue }
            bars[mid] = arr.map { b in
                KlineItem(date: int(b["date"]) ?? 0, open: num(b["open"]) ?? 0,
                          high: num(b["high"]) ?? 0, low: num(b["low"]) ?? 0,
                          close: num(b["close"]) ?? 0, volume: 0, turnover: 0)
            }
        }
        var hits: [Int: Set<Int>] = [:]
        for (k, v) in (input["pickHits"] as? [String: Any]) ?? [:] {
            guard let mid = Int(k) else { continue }
            hits[mid] = Set(dateList(v))
        }
        var metas: [Int: MetaItem] = [:]
        for (k, v) in (input["metas"] as? [String: Any]) ?? [:] {
            guard let mid = Int(k) else { continue }
            let m = metaItemFromJSON(v)   // 以字典键为主键（与 runBacktest / 引擎口径一致）
            metas[mid] = MetaItem(id: mid, file: m.file, code: m.code, name: m.name,
                                  type: m.type, firstDate: nil, lastDate: nil)
        }
        let pj = (input["params"] as? [String: Any]) ?? [:]
        var params = BacktestParams()
        params.days = int(pj["days"]) ?? 250
        params.initialCapital = num(pj["initialCapital"]) ?? 100_000
        params.executeNextOpen = bool(pj["executeNextOpen"]) ?? true
        params.includeEntry = bool(pj["includeEntry"]) ?? true
        return (doc, bars, hits, metas, params, int(input["tzOffsetSeconds"]) ?? 0)
    }

    // MARK: - 回测：引擎出参 JSON → 生产模型

    static func backtestResult(from payload: [String: Any], params: BacktestParams) throws -> BacktestResult {
        guard let sj = payload["stats"] as? [String: Any] else { throw CodecError.badShape("stats") }
        let stats = BacktestStats(
            initialCapital: num(sj["initialCapital"]) ?? 0,
            finalEquity: num(sj["finalEquity"]) ?? 0,
            totalReturn: num(sj["totalReturn"]) ?? 0,
            annualized: num(sj["annualized"]) ?? 0,
            winRate: num(sj["winRate"]) ?? 0,
            profitFactor: num(sj["profitFactor"]) ?? 0,
            maxDrawdown: num(sj["maxDrawdown"]) ?? 0,
            tradeCount: int(sj["tradeCount"]) ?? 0,
            roundTrips: int(sj["roundTrips"]) ?? 0,
            avgHoldDays: num(sj["avgHoldDays"]) ?? 0)

        let equity = (payload["equity"] as? [[String: Any]] ?? []).map {
            BacktestEquityPoint(date: int($0["date"]) ?? 0, equity: num($0["equity"]) ?? 0)
        }

        var range: ClosedRange<Int>?
        if let r = payload["maxDrawdownRange"] as? [Any], r.count == 2,
           let lo = int(r[0]), let hi = int(r[1]) { range = lo...hi }

        let trades = (payload["trades"] as? [[String: Any]] ?? []).map { t -> BacktestTrade in
            BacktestTrade(
                signalDate: int(t["signalDate"]) ?? 0, date: int(t["date"]) ?? 0,
                metaID: int(t["metaID"]) ?? 0, code: str(t["code"]) ?? "",
                name: str(t["name"]) ?? "",
                ruleKind: (str(t["ruleKind"])).flatMap(StrategyRuleKind.init(rawValue:)),
                direction: SimOrderDirection(rawValue: str(t["direction"]) ?? "buy") ?? .buy,
                qty: int(t["qty"]) ?? 0, price: num(t["price"]) ?? 0,
                amount: num(t["amount"]) ?? 0, fee: num(t["fee"]) ?? 0,
                realizedPnL: num(t["realizedPnL"]), holdDays: int(t["holdDays"]))
        }

        // params：引擎只回传四个标量（pool / period 是取数期概念，引擎不关心）→ 以调用方传入的为准
        var p = params
        if let pj = payload["params"] as? [String: Any] {
            p.days = int(pj["days"]) ?? p.days
            p.initialCapital = num(pj["initialCapital"]) ?? p.initialCapital
            p.executeNextOpen = bool(pj["executeNextOpen"]) ?? p.executeNextOpen
            p.includeEntry = bool(pj["includeEntry"]) ?? p.includeEntry
        }

        return BacktestResult(params: p, stats: stats, equity: equity, maxDrawdownRange: range,
                              trades: trades,
                              scannedCount: int(payload["scannedCount"]) ?? 0,
                              hitCount: int(payload["hitCount"]) ?? 0,
                              warnings: (payload["warnings"] as? [String]) ?? [],
                              skipped: (payload["skipped"] as? [String]) ?? [])
    }

    /// 生产模型 → fixture/引擎同形状 JSON（与 §11.6 一致；**不含** `BacktestTrade.id`）。
    static func backtestJSON(_ r: BacktestResult) -> [String: Any] {
        var o: [String: Any] = [:]
        o["stats"] = ["initialCapital": r.stats.initialCapital, "finalEquity": r.stats.finalEquity,
                      "totalReturn": r.stats.totalReturn, "annualized": r.stats.annualized,
                      "winRate": r.stats.winRate, "profitFactor": r.stats.profitFactor,
                      "maxDrawdown": r.stats.maxDrawdown, "tradeCount": r.stats.tradeCount,
                      "roundTrips": r.stats.roundTrips, "avgHoldDays": r.stats.avgHoldDays]
        o["equity"] = r.equity.map { ["date": $0.date, "equity": $0.equity] }
        if let rg = r.maxDrawdownRange { o["maxDrawdownRange"] = [rg.lowerBound, rg.upperBound] }
        else { o["maxDrawdownRange"] = NSNull() }
        o["trades"] = r.trades.map { t -> [String: Any] in
            ["signalDate": t.signalDate, "date": t.date, "metaID": t.metaID, "code": t.code,
             "name": t.name, "ruleKind": t.ruleKind?.rawValue ?? NSNull(),
             "direction": t.direction.rawValue, "qty": t.qty, "price": t.price,
             "amount": t.amount, "fee": t.fee,
             "realizedPnL": t.realizedPnL ?? NSNull(), "holdDays": t.holdDays ?? NSNull()]
        }
        o["scannedCount"] = r.scannedCount
        o["hitCount"] = r.hitCount
        o["warnings"] = r.warnings
        o["skipped"] = r.skipped
        o["params"] = ["days": r.params.days, "initialCapital": r.params.initialCapital,
                       "executeNextOpen": r.params.executeNextOpen, "includeEntry": r.params.includeEntry]
        return o
    }
}

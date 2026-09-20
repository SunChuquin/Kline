//
//  StrategyCondGenerator.swift
//  Kline
//
//  策略条件单生成器：把交易策略（TRADE 段 + RULES 段）翻译成可直接落库的条件单草稿，
//  按「账户 × 标的 × 规则」三维展开，逐条走 SimCondRule.validateCreate 校验，并按账户去重 / 限额截断。
//  约定：本文件只产出草稿，绝不写盘、绝不调用 SimStore.submit；
//  落盘由确认页调用 SimStore.upsertCondOrders(_:) 一次性完成。
//
//  Created by 孙楚昆 on 2026/9/20.
//

import Foundation

// MARK: - 产出模型

/// 待写入的条件单草稿（账户 + 标的 + 类型 + 参数 + 指令）
struct StrategyCondDraft: Identifiable {
    var id = UUID()
    var accountID: UUID
    var metaID: Int
    var code: String
    var name: String
    var kind: SimCondKind
    var params: SimCondParams
    var directive: SimCondDirective
    var validity: SimCondValidity
    var expiresAt: Date?

    /// 装配完整条件单（createdAt/updatedAt = now、status = .monitoring）
    func order() -> SimCondOrder {
        let now = Date()
        return SimCondOrder(id: id,
                            accountID: accountID,
                            metaID: metaID,
                            code: code,
                            name: name,
                            kind: kind,
                            params: params,
                            directive: directive,
                            validity: validity,
                            expiresAt: validity == .untilDate ? expiresAt : nil,
                            createdAt: now,
                            updatedAt: now,
                            status: .monitoring,
                            runtime: SimCondRuntime(),
                            triggeredCount: 0,
                            triggeredAt: nil,
                            originOrderID: nil)
    }

    /// 一句话摘要（复用 SimCondRule.previewSentence 的口径）
    var summary: String { SimCondRule.previewSentence(order()) }
}

/// 被跳过的条目（含原因，供确认页展示）
struct StrategyGenSkip: Identifiable {
    var id = UUID()
    var title: String     // 如「贵州茅台 600519.SH · 止盈止损」
    var reason: String    // 如「卖出规则需先有持仓」「该标的已存在同类监控中条件单」
}

/// 生成结果（尚未写入）
struct StrategyGenOutcome {
    var drafts: [StrategyCondDraft] = []
    var skips: [StrategyGenSkip] = []
    var truncatedByLimit: Bool = false
}

// MARK: - 生成器

/// 策略规则 → 条件单草稿。
/// - `generate(...)` 读全局（SimStore / SimQuoteCenter / SimCondSnapshotCenter），故整体 `@MainActor`；
/// - `drafts(...)` / `entryDraft(...)` 为纯函数（入参给全、不读全局），标 `nonisolated` 以便单测与局部复用。
@MainActor
enum StrategyCondGenerator {

    /// 单次生成上限（超出截断并置 truncatedByLimit）
    static let maxDraftsPerRun = 200
    /// 单账户监控中条件单上限
    static let maxMonitoringPerAccount = 1000

    // MARK: 全量生成（三维展开 + 校验 + 去重 + 限额）

    /// 生成条件单草稿（不写盘）：账户 × 标的 × 规则 三维展开，逐条走 SimCondRule.validateCreate 校验与去重
    static func generate(doc: FormulaDoc, metas: [MetaItem], includeEntry: Bool, accountIDs: [UUID]) -> StrategyGenOutcome {
        let store = SimStore.shared
        var outcome = StrategyGenOutcome()

        for accountID in accountIDs {
            // 1. 账户闸门：不存在或已归档 → 整账户跳过
            guard let account = store.account(id: accountID), !account.isArchived else {
                outcome.skips.append(StrategyGenSkip(title: "账户 \(accountID.uuidString)",
                                                     reason: "账户不存在或已归档"))
                continue
            }
            // 该账户已有条件单：monitoring 部分既参与去重，也计入单账户限额
            let monitoring = store.condOrders(accountID: accountID).filter { $0.status == .monitoring }
            let existingKeys = Set(monitoring.map { dedupKey($0.metaID, $0.kind) })
            var addedForAccount = 0

            for meta in metas {
                // 2. 行情闸门：无最新价（行情未就绪）→ 该标的整体跳过
                guard let lastPrice = SimQuoteCenter.lastPrice(metaID: meta.id), lastPrice > 0 else {
                    outcome.skips.append(StrategyGenSkip(title: metaTitle(meta), reason: "行情未就绪"))
                    continue
                }
                let position = store.position(accountID: accountID, metaID: meta.id)

                // 规则 → 草稿（纯映射，映射阶段失败的原因原样并入 skips）
                let mapped = drafts(doc: doc, meta: meta, accountID: accountID,
                                    lastPrice: lastPrice, costPrice: position?.costPrice)
                outcome.skips.append(contentsOf: mapped.skips)

                var candidates = mapped.drafts
                // 6. 可选入场单：仅在开启开关且 TRADE 段给了方向时追加
                if includeEntry,
                   let entry = entryDraft(doc: doc, meta: meta, accountID: accountID, lastPrice: lastPrice) {
                    candidates.append(entry)
                }

                for draft in candidates {
                    let title = "\(metaTitle(meta)) · \(draft.kind.title)"

                    // 5a. 单次生成上限（全局）
                    if outcome.drafts.count >= maxDraftsPerRun {
                        outcome.truncatedByLimit = true
                        outcome.skips.append(StrategyGenSkip(title: title,
                                                             reason: "已达单次生成上限 \(maxDraftsPerRun) 条"))
                        continue
                    }
                    // 5b. 单账户监控中上限
                    if monitoring.count + addedForAccount >= maxMonitoringPerAccount {
                        outcome.truncatedByLimit = true
                        outcome.skips.append(StrategyGenSkip(title: title,
                                                             reason: "该账户监控中条件单已达上限 \(maxMonitoringPerAccount) 条"))
                        continue
                    }
                    // 4. 去重：同标的 + 同类型 且监控中（放在校验之前，避免对已存在单误报「无持仓」等）
                    if existingKeys.contains(dedupKey(draft.metaID, draft.kind)) {
                        outcome.skips.append(StrategyGenSkip(title: title,
                                                             reason: "该标的已存在同类监控中条件单"))
                        continue
                    }
                    // 3. 建单校验：被拒则把 SimCondRejection 的中文文案收进 skips
                    let order = draft.order()
                    if let rejection = SimCondRule.validateCreate(order: order,
                                                                  account: account,
                                                                  position: position,
                                                                  snapshot: SimCondSnapshotCenter.snapshot(for: order)) {
                        outcome.skips.append(StrategyGenSkip(title: title, reason: rejection.message))
                        continue
                    }
                    outcome.drafts.append(draft)
                    addedForAccount += 1
                }
            }
        }
        return outcome
    }

    // MARK: 单标的 × 全部规则（纯函数）

    /// 单标的 × 全部规则（供单测/局部复用）：只做「规则 → 草稿」映射，
    /// 不做 SimStore 校验（校验需要账户 / 持仓 / 行情快照，全在 `generate` 内完成）
    nonisolated static func drafts(doc: FormulaDoc, meta: MetaItem,
                                   accountID: UUID, lastPrice: Double, costPrice: Double?)
        -> (drafts: [StrategyCondDraft], skips: [StrategyGenSkip]) {
        var result: [StrategyCondDraft] = []
        var skips: [StrategyGenSkip] = []
        let (calls, _) = StrategyRuleParser.parse(lines: doc.rules)
        for call in calls {
            let mapped = build(call: call, trade: doc.trade, meta: meta, accountID: accountID,
                               lastPrice: lastPrice, costPrice: costPrice)
            if let draft = mapped.draft {
                result.append(draft)
            } else {
                skips.append(StrategyGenSkip(title: "\(metaTitle(meta)) · \(call.kind.title)",
                                             reason: mapped.reason ?? "该规则无法生成条件单"))
            }
        }
        return (result, skips)
    }

    // MARK: 入场单（纯函数）

    /// 可选入场单：PRICE(OP=>=, VALUE=最新价)，按 TRADE 段的方向/数量/报价方式
    nonisolated static func entryDraft(doc: FormulaDoc, meta: MetaItem,
                                       accountID: UUID, lastPrice: Double) -> StrategyCondDraft? {
        let trade = doc.trade
        // 未配置交易方向（旧策略文件）或无有效最新价 → 不生成
        guard let direction = trade.direction, lastPrice > 0 else { return nil }

        var params = SimCondParams()
        params.compareUp = true          // 现价 ≥ 最新价（突破当前价即入场）
        params.triggerPrice = lastPrice

        let directive = SimCondDirective(direction: direction,
                                         priceType: trade.priceType ?? .market,
                                         offsetTicks: trade.offsetTicks ?? 0,
                                         qty: resolvedQty(kind: .price, params: params,
                                                          overrides: StrategyDirectiveOverride(),
                                                          trade: trade, lastPrice: lastPrice))
        let validity = trade.validity ?? .longTerm
        return StrategyCondDraft(accountID: accountID, metaID: meta.id, code: meta.code, name: meta.name,
                                 kind: .price, params: params, directive: directive,
                                 validity: validity,
                                 expiresAt: validity == .untilDate ? trade.expiresAt : nil)
    }

    // MARK: 单条规则 → 草稿（纯映射）

    /// 把一条规则装配成草稿；返回 `draft == nil` 时 `reason` 为中文原因
    private nonisolated static func build(call: StrategyRuleCall, trade: StrategyTradeSpec, meta: MetaItem,
                                          accountID: UUID, lastPrice: Double, costPrice: Double?)
        -> (draft: StrategyCondDraft?, reason: String?) {
        let kind = condKind(call.kind)
        let overrides = StrategyTradeParser.override(in: call)
        var params = SimCondParams()

        switch call.kind {
        case .price:
            guard let value = number(call, "VALUE"), value > 0 else {
                return (nil, "价格条件缺少有效的触发价（VALUE）")
            }
            params.compareUp = (text(call, "OP") == "<=") ? false : true
            params.triggerPrice = value

        case .stopLoss:
            // MODE 缺省按 PCT（参数目录 placeholder 即 PCT，PROFIT / LOSS 亦声明为百分数）
            let percentMode = (text(call, "MODE")?.uppercased() != "PRICE")
            // BASE 缺省按 COST（成本价）；未持仓时成本价为 nil
            let base = (text(call, "BASE")?.uppercased() == "LAST") ? lastPrice : costPrice
            let profit = number(call, "PROFIT")
            let loss = number(call, "LOSS")
            guard profit != nil || loss != nil else {
                return (nil, "止盈止损至少需设置止盈或止损之一")
            }
            params.baseMode = percentMode ? .percent : .price
            params.basePrice = base
            if percentMode {
                // 百分数 → 价格：止盈 = 基准 ×(1+PROFIT/100)，止损 = 基准 ×(1-LOSS/100)
                if let profit, let base { params.takeProfitPrice = base * (1 + profit / 100) }
                if let loss, let base { params.stopLossPrice = base * (1 - loss / 100) }
            } else {
                params.takeProfitPrice = profit
                params.stopLossPrice = loss
            }

        case .trailing:
            guard let pct = number(call, "PCT"), pct > 0 else {
                return (nil, "回落卖出缺少有效的回落幅度（PCT）")
            }
            params.trailPct = pct
            params.breakoutPrice = lastPrice         // 以最新价为突破价起点
            if let floor = number(call, "FLOOR"), floor > 0 {
                params.floorPrice = floor
                params.floorEnabled = true
            }

        case .time:
            guard let dateText = text(call, "DATE"),
                  let fire = fireDate(dateText: dateText, atText: text(call, "AT") ?? "09:30") else {
                return (nil, "时间条件缺少有效日期（DATE）")
            }
            params.fireDate = fire

        case .changePct:
            guard let pct = number(call, "PCT"), pct != 0 else {
                return (nil, "涨跌幅条件缺少有效的幅度（PCT）")
            }
            // changeThreshold 正数 = 涨幅达到，负数 = 跌幅达到；OP 缺省按 '>='
            params.changeThreshold = (text(call, "OP") == "<=") ? -abs(pct) : abs(pct)

        case .maCross:
            guard let period = integer(call, "PERIOD") else {
                return (nil, "均线条件缺少周期（PERIOD）")
            }
            params.maPeriod = period
            let dir = text(call, "DIR")?.uppercased()
            if dir == "UP" {
                params.maAbove = true                // 上穿
            } else if dir == "DOWN" {
                params.maAbove = false               // 下破
            }                                        // 其余（缺省 / 非法）留 nil，由 validateCreate 报「穿越方向」

        case .grid:
            guard let base = number(call, "BASE"),
                  let low = number(call, "LOW"),
                  let high = number(call, "HIGH"),
                  let step = number(call, "STEP"),
                  let qty = integer(call, "QTY") else {
                return (nil, "网格交易参数不完整（BASE / LOW / HIGH / STEP / QTY）")
            }
            params.gridBase = base
            params.gridLower = low
            params.gridUpper = high
            params.gridStepPct = step                // STEP 同为百分数，无需换算
            params.gridQtyPerLevel = qty
            params.gridMultiplier = number(call, "MULT") ?? 1

        case .batch:
            guard let total = integer(call, "TOTAL"),
                  let count = integer(call, "COUNT"),
                  let first = number(call, "FIRST"), first > 0,
                  let gap = number(call, "GAP") else {
                return (nil, "分批建仓参数不完整（TOTAL / COUNT / FIRST / GAP）")
            }
            params.batchTotalQty = total
            params.batchCount = count
            params.batchFirstPrice = first
            // 注意：策略参数 GAP 以「元」填写（每批价差），而 SimCondParams.batchStepPct 是
            // 「以上一批/首批价为基准的百分数」（见 SimCondRule.batch 的 offset 计算与编辑器单位 %），
            // 故此处做必要换算：percent = GAP / 首批价 × 100
            params.batchStepPct = gap / first * 100
        }

        // 指令装配：规则行内覆盖 > TRADE 段 > 内置默认
        let directive = SimCondDirective(direction: resolvedDirection(kind: kind, overrides: overrides, trade: trade),
                                         priceType: overrides.priceType ?? trade.priceType ?? .market,
                                         offsetTicks: overrides.offsetTicks ?? trade.offsetTicks ?? 0,
                                         qty: resolvedQty(kind: kind, params: params,
                                                          overrides: overrides, trade: trade, lastPrice: lastPrice))
        let validity = trade.validity ?? .longTerm
        return (StrategyCondDraft(accountID: accountID, metaID: meta.id, code: meta.code, name: meta.name,
                                  kind: kind, params: params, directive: directive,
                                  validity: validity,
                                  expiresAt: validity == .untilDate ? trade.expiresAt : nil), nil)
    }

    // MARK: - 映射辅助（纯函数）

    /// 策略规则种类 → 条件单种类
    private nonisolated static func condKind(_ kind: StrategyRuleKind) -> SimCondKind {
        switch kind {
        case .price:     return .price
        case .stopLoss:  return .stopLoss
        case .trailing:  return .trailing
        case .time:      return .time
        case .changePct: return .changePct
        case .maCross:   return .maCross
        case .grid:      return .grid
        case .batch:     return .batch
        }
    }

    /// 触发后委托方向：覆盖 > TRADE > 内置默认（分批缺省买入，其余缺省卖出）
    private nonisolated static func resolvedDirection(kind: SimCondKind,
                                                      overrides: StrategyDirectiveOverride,
                                                      trade: StrategyTradeSpec) -> SimOrderDirection {
        if let dir = overrides.dir { return dir }
        if let dir = trade.direction { return dir }
        return kind == .batch ? .buy : .sell
    }

    /// 触发后委托数量：网格取每格股数、分批取总数量，其余按 覆盖 > TRADE > 金额按最新价折算
    private nonisolated static func resolvedQty(kind: SimCondKind, params: SimCondParams,
                                                overrides: StrategyDirectiveOverride,
                                                trade: StrategyTradeSpec, lastPrice: Double) -> Int {
        switch kind {
        case .grid:
            return params.gridQtyPerLevel ?? 0       // 网格数量由 params 承载，directive.qty 可为 0
        case .batch:
            return params.batchTotalQty ?? 0         // 分批数量由 params 承载
        default:
            if let qty = overrides.qty { return qty }
            if let amount = overrides.amount { return lotQty(amount: amount, lastPrice: lastPrice) }
            if let qty = trade.qty { return qty }
            if let amount = trade.amount { return lotQty(amount: amount, lastPrice: lastPrice) }
            return 0
        }
    }

    /// 金额按最新价折算为整手股数（至少 1 手）；无法折算时返回 0（交给 validateCreate 报数量错误）
    private nonisolated static func lotQty(amount: Double, lastPrice: Double) -> Int {
        guard amount > 0, lastPrice > 0 else { return 0 }
        let lots = Int(amount / lastPrice / 100)
        return max(lots, 1) * 100
    }

    /// 时间条件的 DATE + AT（缺省 09:30）→ fireDate（Calendar + 当前时区拼年月日时分）
    private nonisolated static func fireDate(dateText: String, atText: String) -> Date? {
        let dateParts = dateText.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard dateParts.count == 3,
              let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]) else {
            return nil
        }
        let timeParts = atText.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard timeParts.count == 2, let hour = Int(timeParts[0]), let minute = Int(timeParts[1]) else {
            return nil
        }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.date(from: comps)
    }

    /// 去重键：同标的 + 同类型
    private nonisolated static func dedupKey(_ metaID: Int, _ kind: SimCondKind) -> String {
        "\(metaID)#\(kind.rawValue)"
    }

    /// 标的展示名：名称 + 代码（如「贵州茅台 600519.SH」）
    private nonisolated static func metaTitle(_ meta: MetaItem) -> String {
        "\(meta.name) \(meta.code)"
    }

    /// 取参数非空原文
    private nonisolated static func text(_ call: StrategyRuleCall, _ key: String) -> String? {
        guard let value = call.params[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    /// 取数值型参数（非数字返回 nil）
    private nonisolated static func number(_ call: StrategyRuleCall, _ key: String) -> Double? {
        guard let raw = text(call, key) else { return nil }
        return Double(raw)
    }

    /// 取整数型参数（非整数返回 nil）
    private nonisolated static func integer(_ call: StrategyRuleCall, _ key: String) -> Int? {
        guard let raw = text(call, key) else { return nil }
        return Int(raw)
    }
}
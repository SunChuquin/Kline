//
//  SimConditionModels.swift
//  Kline
//
//  条件单领域模型：8 种条件类型枚举 / 状态 / 有效期 / 涨跌基准，以及触发后委托指令、
//  扁平化参数集（不用带载荷枚举）、运行时进度与条件单实体。
//  约定：参数一律用扁平原生可选字段 + 逐项兜底解码（decodeIfPresent），
//  缺字段的老档案不会使整条条件单解码失败；分段归类（SimCondSegment）也在此定义，
//  供管理页与 SimStore 查询共用。
//  另含「仅提醒」指令开关（SimCondDirective.alertOnly）与预警记录实体（SimAlertRecord）。
//

import Foundation

// MARK: - 枚举

/// 条件单类型（8 种，进阶版）
enum SimCondKind: String, Codable, CaseIterable, Hashable {
    case price          // 价格条件
    case stopLoss       // 止盈止损（OCO）
    case trailing       // 回落卖出 / 反弹买入
    case time           // 时间条件
    case changePct      // 涨跌幅条件
    case maCross        // 均线条件
    case grid           // 网格交易
    case batch          // 分批建仓 / 分批卖出

    /// 编辑器类型 chips 的中文标题
    var title: String {
        switch self {
        case .price:     return "价格条件"
        case .stopLoss:  return "止盈止损"
        case .trailing:  return "回落卖出"
        case .time:      return "时间条件"
        case .changePct: return "涨跌幅"
        case .maCross:   return "均线条件"
        case .grid:      return "网格交易"
        case .batch:     return "分批建仓"
        }
    }

    /// 是否多触发类型（触发后仍保持监控，可反复推进档位 / 批次）
    var repeatable: Bool {
        switch self {
        case .grid, .batch: return true
        case .price, .stopLoss, .trailing, .time, .changePct, .maCross: return false
        }
    }
}

/// 条件单状态
enum SimCondStatus: String, Codable, Hashable {
    case monitoring     // 监控中
    case triggered      // 已触发
    case completed      // 已完成（多触发类型走完全部档位 / 批次）
    case expired        // 已失效（过期或参数越界）
    case cancelled      // 已撤销
    case rejected       // 触发后被拒

    var title: String {
        switch self {
        case .monitoring: return "监控中"
        case .triggered:  return "已触发"
        case .completed:  return "已完成"
        case .expired:    return "已失效"
        case .cancelled:  return "已撤销"
        case .rejected:   return "已拒绝"
        }
    }

    /// 是否仍参与结算（仅监控中）
    var isActive: Bool { self == .monitoring }
}

/// 有效期
enum SimCondValidity: String, Codable, Hashable {
    case day            // 当日
    case untilDate      // 指定日期
    case longTerm       // 长期

    var title: String {
        switch self {
        case .day:       return "当日"
        case .untilDate: return "指定日期"
        case .longTerm:  return "长期"
        }
    }
}

/// 止盈止损的涨跌基准
enum SimCondBaseMode: String, Codable, Hashable {
    case price          // 按价格
    case percent        // 按百分比
    case diff           // 按差价

    var title: String {
        switch self {
        case .price:   return "按价格"
        case .percent: return "按百分比"
        case .diff:    return "按差价"
        }
    }
}

/// 列表页分段（已失效段含已撤销 / 已过期 / 已拒绝；已完成归「已触发」段）
enum SimCondSegment: String, CaseIterable, Identifiable, Hashable {
    case monitoring
    case triggered
    case invalid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monitoring: return "监控中"
        case .triggered:  return "已触发"
        case .invalid:    return "已失效"
        }
    }
}

// MARK: - 触发后委托指令

/// 触发后要下发的委托指令
/// nonisolated：纯数据，需在后台线程（历史回测 / 条件单批量生成）装配
nonisolated struct SimCondDirective: Codable, Hashable {
    var direction: SimOrderDirection = .sell
    var priceType: SimPriceType = .market
    var offsetTicks: Int = 0        // 触发价 ± N 档，仅 priceType == .limit 时使用
    var qty: Int = 0                // 网格类型不使用（用 params.gridQtyPerLevel）
    /// 「仅提醒」形态（不下单）：触发时只记触发时间 / 触发价 / 文案并追加一条预警记录。
    /// 可选 + 解码兜底 false：旧 sim.json 没有该字段也不会整条条件单解码失败
    var alertOnly: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case direction, priceType, offsetTicks, qty, alertOnly
    }
}

extension SimCondDirective {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direction = (try? c.decode(SimOrderDirection.self, forKey: .direction)) ?? .sell
        priceType = (try? c.decode(SimPriceType.self, forKey: .priceType)) ?? .market
        offsetTicks = (try? c.decode(Int.self, forKey: .offsetTicks)) ?? 0
        qty = (try? c.decode(Int.self, forKey: .qty)) ?? 0
        alertOnly = try? c.decodeIfPresent(Bool.self, forKey: .alertOnly)
    }

    /// 是否「仅提醒」（nil / 缺字段一律按普通条件单处理）
    var isAlertOnly: Bool { alertOnly ?? false }
}

// MARK: - 类型参数

/// 条件单参数集：各类型的扁平可选字段集合（不用带载荷枚举，避免读档脆弱性）
/// nonisolated：纯数据，需在后台线程（历史回测 / 条件单批量生成）装配
nonisolated struct SimCondParams: Codable, Hashable {
    // 价格条件
    var compareUp: Bool? = nil              // true: 现价 ≥ 触发价；false: 现价 ≤ 触发价
    var triggerPrice: Double? = nil
    // 止盈止损（OCO）
    var basePrice: Double? = nil
    var baseMode: SimCondBaseMode = .price
    var takeProfitPrice: Double? = nil
    var stopLossPrice: Double? = nil        // 两腿至少有一条非 nil
    // 回落卖出 / 反弹买入
    var breakoutPrice: Double? = nil        // 突破价
    var trailPct: Double? = nil             // 回落 / 反弹幅度（百分数，3.0 表示 3%）
    var floorEnabled: Bool = false          // 保底价触发
    var floorPrice: Double? = nil
    // 时间条件
    var fireDate: Date? = nil
    // 涨跌幅条件
    var changeThreshold: Double? = nil      // 正数 = 涨幅达到，负数 = 跌幅达到
    // 均线条件
    var maPeriod: Int? = nil                // 5 / 10 / 20 / 60
    var maAbove: Bool? = nil                // true = 上穿，false = 下破
    // 网格交易
    var gridBase: Double? = nil
    var gridUpper: Double? = nil
    var gridLower: Double? = nil
    var gridStepPct: Double? = nil          // 网格间距（百分数）
    var gridQtyPerLevel: Int? = nil
    var gridMultiplier: Double? = nil       // 倍数委托，1...5
    // 分批建仓 / 分批卖出
    var batchTotalQty: Int? = nil
    var batchCount: Int? = nil              // 2...5
    var batchFirstPrice: Double? = nil
    var batchStepPct: Double? = nil         // 每批价差（百分数，正数）

    private enum CodingKeys: String, CodingKey {
        case compareUp, triggerPrice
        case basePrice, baseMode, takeProfitPrice, stopLossPrice
        case breakoutPrice, trailPct, floorEnabled, floorPrice
        case fireDate
        case changeThreshold
        case maPeriod, maAbove
        case gridBase, gridUpper, gridLower, gridStepPct, gridQtyPerLevel, gridMultiplier
        case batchTotalQty, batchCount, batchFirstPrice, batchStepPct
    }
}

extension SimCondParams {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        compareUp = try? c.decodeIfPresent(Bool.self, forKey: .compareUp)
        triggerPrice = try? c.decodeIfPresent(Double.self, forKey: .triggerPrice)
        basePrice = try? c.decodeIfPresent(Double.self, forKey: .basePrice)
        baseMode = (try? c.decode(SimCondBaseMode.self, forKey: .baseMode)) ?? .price
        takeProfitPrice = try? c.decodeIfPresent(Double.self, forKey: .takeProfitPrice)
        stopLossPrice = try? c.decodeIfPresent(Double.self, forKey: .stopLossPrice)
        breakoutPrice = try? c.decodeIfPresent(Double.self, forKey: .breakoutPrice)
        trailPct = try? c.decodeIfPresent(Double.self, forKey: .trailPct)
        floorEnabled = (try? c.decode(Bool.self, forKey: .floorEnabled)) ?? false
        floorPrice = try? c.decodeIfPresent(Double.self, forKey: .floorPrice)
        fireDate = try? c.decodeIfPresent(Date.self, forKey: .fireDate)
        changeThreshold = try? c.decodeIfPresent(Double.self, forKey: .changeThreshold)
        maPeriod = try? c.decodeIfPresent(Int.self, forKey: .maPeriod)
        maAbove = try? c.decodeIfPresent(Bool.self, forKey: .maAbove)
        gridBase = try? c.decodeIfPresent(Double.self, forKey: .gridBase)
        gridUpper = try? c.decodeIfPresent(Double.self, forKey: .gridUpper)
        gridLower = try? c.decodeIfPresent(Double.self, forKey: .gridLower)
        gridStepPct = try? c.decodeIfPresent(Double.self, forKey: .gridStepPct)
        gridQtyPerLevel = try? c.decodeIfPresent(Int.self, forKey: .gridQtyPerLevel)
        gridMultiplier = try? c.decodeIfPresent(Double.self, forKey: .gridMultiplier)
        batchTotalQty = try? c.decodeIfPresent(Int.self, forKey: .batchTotalQty)
        batchCount = try? c.decodeIfPresent(Int.self, forKey: .batchCount)
        batchFirstPrice = try? c.decodeIfPresent(Double.self, forKey: .batchFirstPrice)
        batchStepPct = try? c.decodeIfPresent(Double.self, forKey: .batchStepPct)
    }
}

// MARK: - 运行时进度

/// 运行时进度（极值追踪 / 网格档位 / 分批笔数等，随每次评估推进）
struct SimCondRuntime: Codable, Hashable {
    var extreme: Double? = nil              // 回落 / 反弹的极值（最高价 / 最低价）
    var lastPrice: Double? = nil            // 上次评估时的最新价
    var gridLevel: Int? = nil               // 网格已触发档位数
    var gridLastPrice: Double? = nil        // 网格上次触发时的价格
    var batchDone: Int = 0                  // 分批已完成笔数
    var lastEvaluatedAt: Date? = nil
    var lastMessage: String = ""
    var lastTriggerPrice: Double? = nil

    private enum CodingKeys: String, CodingKey {
        case extreme, lastPrice, gridLevel, gridLastPrice
        case batchDone, lastEvaluatedAt, lastMessage, lastTriggerPrice
    }
}

extension SimCondRuntime {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        extreme = try? c.decodeIfPresent(Double.self, forKey: .extreme)
        lastPrice = try? c.decodeIfPresent(Double.self, forKey: .lastPrice)
        gridLevel = try? c.decodeIfPresent(Int.self, forKey: .gridLevel)
        gridLastPrice = try? c.decodeIfPresent(Double.self, forKey: .gridLastPrice)
        batchDone = (try? c.decode(Int.self, forKey: .batchDone)) ?? 0
        lastEvaluatedAt = try? c.decodeIfPresent(Date.self, forKey: .lastEvaluatedAt)
        lastMessage = (try? c.decode(String.self, forKey: .lastMessage)) ?? ""
        lastTriggerPrice = try? c.decodeIfPresent(Double.self, forKey: .lastTriggerPrice)
    }
}

// MARK: - 条件单实体

/// 条件单
/// nonisolated：纯数据，需在后台线程（历史回测 / 条件单批量生成）装配
nonisolated struct SimCondOrder: Identifiable, Codable, Hashable {
    var id: UUID
    var accountID: UUID
    var metaID: Int
    var code: String
    var name: String
    var kind: SimCondKind
    var params: SimCondParams
    var directive: SimCondDirective
    var validity: SimCondValidity
    var expiresAt: Date? = nil              // validity == .untilDate 时有效
    var createdAt: Date
    var updatedAt: Date
    var status: SimCondStatus = .monitoring
    var runtime: SimCondRuntime = SimCondRuntime()
    var triggeredCount: Int = 0
    var triggeredAt: Date? = nil
    var originOrderID: UUID? = nil          // 最近一次触发生成的委托 id

    private enum CodingKeys: String, CodingKey {
        case id, accountID, metaID, code, name, kind
        case params, directive, validity, expiresAt
        case createdAt, updatedAt, status, runtime
        case triggeredCount, triggeredAt, originOrderID
    }
}

extension SimCondOrder {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        accountID = (try? c.decode(UUID.self, forKey: .accountID)) ?? UUID()
        metaID = (try? c.decode(Int.self, forKey: .metaID)) ?? 0
        code = (try? c.decode(String.self, forKey: .code)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        kind = (try? c.decode(SimCondKind.self, forKey: .kind)) ?? .price
        params = (try? c.decode(SimCondParams.self, forKey: .params)) ?? SimCondParams()
        directive = (try? c.decode(SimCondDirective.self, forKey: .directive)) ?? SimCondDirective()
        validity = (try? c.decode(SimCondValidity.self, forKey: .validity)) ?? .longTerm
        expiresAt = try? c.decodeIfPresent(Date.self, forKey: .expiresAt)
        let created = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        createdAt = created
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? created
        status = (try? c.decode(SimCondStatus.self, forKey: .status)) ?? .monitoring
        runtime = (try? c.decode(SimCondRuntime.self, forKey: .runtime)) ?? SimCondRuntime()
        triggeredCount = (try? c.decode(Int.self, forKey: .triggeredCount)) ?? 0
        triggeredAt = try? c.decodeIfPresent(Date.self, forKey: .triggeredAt)
        originOrderID = try? c.decodeIfPresent(UUID.self, forKey: .originOrderID)
    }
}

// MARK: - 便捷派生

extension SimCondOrder {
    /// 是否为多触发类型（转发 kind.repeatable）
    var isRepeatable: Bool { kind.repeatable }

    /// 列表分段归类（completed 归「已触发」段）
    var segment: SimCondSegment {
        switch status {
        case .monitoring:                    return .monitoring
        case .triggered, .completed:         return .triggered
        case .expired, .cancelled, .rejected: return .invalid
        }
    }
}

// MARK: - 预警记录

/// 预警记录：条件单「仅提醒」形态（`SimCondDirective.isAlertOnly`）每次触发追加一条，
/// 不产生任何委托 / 成交。存在 sim.json（`SimRoot.alertRecords`），只保留最近若干条。
struct SimAlertRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var condID: UUID?      // 来源条件单（可为空：条件单被删后记录仍保留）
    var metaID: Int
    var code: String
    var name: String
    var price: Double?     // 触发价
    var message: String    // 触发文案
    var occurredAt: Date
}
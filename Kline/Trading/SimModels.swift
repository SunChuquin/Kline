//
//  SimModels.swift
//  Kline
//
//  模拟交易领域模型：账户 / 持仓 / 委托 / 成交 / 资金流水 / 操作日志六类实体
//  与配套枚举，以及统一取数助手 SimQuoteCenter（走既有的 MarketRowCache
//  与 DatabaseManager，避免各视图各写一份取价逻辑）。
//

import Foundation

// MARK: - 枚举

/// 委托方向
enum SimOrderDirection: String, Codable, Hashable {
    case buy
    case sell

    var title: String {
        switch self {
        case .buy:  return "买入"
        case .sell: return "卖出"
        }
    }

    /// 是否买入（买入红 / 卖出绿等配色与文案判断用）
    var isBuy: Bool { self == .buy }
}

/// 报价类型
enum SimPriceType: String, Codable, Hashable {
    case limit
    case market

    var title: String {
        switch self {
        case .limit:  return "限价"
        case .market: return "市价"
        }
    }
}

/// 委托状态
enum SimOrderStatus: String, Codable, Hashable {
    case pending
    case reported
    case partial
    case filled
    case cancelled

    var title: String {
        switch self {
        case .pending:   return "待报"
        case .reported:  return "已报"
        case .partial:   return "部成"
        case .filled:    return "已成交"
        case .cancelled: return "已撤"
        }
    }

    /// 是否在途（可撤单）
    var isActive: Bool {
        switch self {
        case .pending, .reported, .partial: return true
        case .filled, .cancelled:           return false
        }
    }
}

/// 资金流水类型
enum LedgerKind: String, Codable, Hashable {
    case deposit
    case withdraw
    case buy
    case sell
    case fee
    case reset

    var title: String {
        switch self {
        case .deposit:  return "入金"
        case .withdraw: return "出金"
        case .buy:      return "买入回款"
        case .sell:     return "卖出回款"
        case .fee:      return "费用"
        case .reset:    return "重置"
        }
    }
}

/// 操作日志模块分类
enum ActionModule: String, Codable, Hashable {
    case order
    case fill
    case cancel
    case amend
    case cash
    case account
    case alert
    case condition

    var title: String {
        switch self {
        case .order:     return "委托"
        case .fill:      return "成交"
        case .cancel:    return "撤单"
        case .amend:     return "改价"
        case .cash:      return "资金"
        case .account:   return "账户"
        case .alert:     return "提醒"
        case .condition: return "条件单"
        }
    }
}

// MARK: - 实体

/// 模拟账户（资金 / 持仓 / 委托按账户完全隔离）
struct SimAccount: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String            // 如 "主策略账户"
    var badge: String           // 单字图标，如 "主"
    var colorHex: String        // 如 "#1E5FA8"
    var initialCapital: Double
    var cash: Double            // 可用资金
    var createdAt: Date
    var isArchived: Bool
}

/// 持仓（availableQty 受 T+1 限制：当日买入次日才可卖）
struct SimPosition: Identifiable, Codable, Hashable {
    var id: UUID
    var accountID: UUID
    var metaID: Int
    var code: String            // 如 "600519.SH"
    var name: String
    var qty: Int                // 持仓总量
    var availableQty: Int       // 可卖（T+1 限制当日买入不可卖）
    var costPrice: Double
    var openedAt: Date
}

/// 委托
struct SimOrder: Identifiable, Codable, Hashable {
    var id: UUID
    var accountID: UUID
    var metaID: Int
    var code: String
    var name: String
    var direction: SimOrderDirection
    var priceType: SimPriceType
    var price: Double?          // market 时为 nil
    var qty: Int
    var filledQty: Int
    var status: SimOrderStatus
    var createdAt: Date
    var updatedAt: Date
    /// 由条件单触发时回链条件单 id（手动下单为 nil）
    var originCondID: UUID? = nil
}

/// 成交
struct SimFill: Identifiable, Codable, Hashable {
    var id: UUID
    var orderID: UUID
    var accountID: UUID
    var metaID: Int
    var code: String
    var name: String
    var direction: SimOrderDirection
    var price: Double
    var qty: Int
    var amount: Double          // price * qty
    var fee: Double
    var tradedAt: Date
    var contractNo: String      // 如 "20260919-001"
}

/// 资金流水（amount 有符号：入金为正、买入为负）
struct LedgerEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var accountID: UUID
    var kind: LedgerKind
    var note: String
    var amount: Double          // 有符号：入金为正、买入为负
    var balanceAfter: Double
    var occurredAt: Date
}

/// 操作日志
struct ActionLog: Identifiable, Codable, Hashable {
    var id: UUID
    var accountID: UUID?        // nil = 全局事件
    var module: ActionModule
    var content: String
    var result: String
    var occurredAt: Date
    var condID: UUID? = nil     // 条件单相关日志回链（非条件单日志为 nil）
}

// MARK: - 行情取数助手

/// 模拟交易取数：最新价 / 昨收 / 元信息（走既有的 MarketRowCache 与 DatabaseManager）。
/// 两者均为 @MainActor 隔离，故本枚举整体标注 @MainActor。
@MainActor
enum SimQuoteCenter {
    /// 标的元信息（代码 / 名称 / 板块类型）
    static func meta(metaID: Int) -> MetaItem? {
        DatabaseManager.shared.metaList.first { $0.id == metaID }
    }

    /// 最新价（行情尚未就绪时为 nil）
    static func lastPrice(metaID: Int) -> Double? {
        MarketRowCache.shared.numberFor(metaID, .latestPrice)
    }

    /// 昨收（涨跌停区间计算用，行情尚未就绪时为 nil）
    static func prevClose(metaID: Int) -> Double? {
        MarketRowCache.shared.numberFor(metaID, .prevClose)
    }
}

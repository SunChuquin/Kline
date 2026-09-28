//
//  TrainingModels.swift
//  Kline
//
//  「K 线单人训练」数据模型：会话（一次训练 = 一条记录）与成交（一笔 = 一条记录）。
//  纯值类型，默认 MainActor 隔离（项目 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor）；
//  成交方向复用模拟交易的 `SimOrderDirection`（nonisolated），训练态不依赖 SimStore。
//

import Foundation

/// 训练会话状态
enum TrainSessionStatus: String {
    case running
    case finished

    var title: String { self == .running ? "进行中" : "已完成" }
}

/// 训练会话记录（一次训练 = 一条）
struct TrainSessionRecord: Identifiable, Equatable {
    var id: String            // UUID 字符串（sqlite TEXT 主键）
    var metaID: Int
    var code: String
    var name: String
    var startDate: Int        // YYYYMMDD；= 开始训练那根 K 线的日期（不是第一笔交易日期）
    var endDate: Int?         // YYYYMMDD；nil = 尚未结束
    var tradeCount: Int
    var status: TrainSessionStatus
    var createdAt: Date
    var updatedAt: Date

    /// 20260512 → "2026-05-12"；nil → "—"
    static func dateText(_ v: Int?) -> String {
        guard let v = v else { return "—" }
        let s = String(v)
        guard s.count == 8 else { return s }
        return "\(s.prefix(4))-\(s.dropFirst(4).prefix(2))-\(s.dropFirst(6))"
    }

    var startDateText: String { Self.dateText(startDate) }
    var endDateText: String { Self.dateText(endDate) }
}

/// 训练成交的触发来源（落训练库，管理页与记录页可见）
enum TrainTradeTrigger: String {
    case manual         // 手动下单（快捷面板）
    case cond           // 条件单触发（自动下单）

    var title: String { self == .manual ? "手动" : "条件单" }
}

/// 主图信号标记种类：B 买入 / S 卖出 / T 做 T（同一训练日既有买入又有卖出）
enum TrainTradeMark: String {
    case buy = "B"
    case sell = "S"
    case dayTrade = "T"
}

/// 主图信号标记（按训练日聚合，一日一个）
struct TrainSignalMark: Equatable {
    var mark: TrainTradeMark
    /// 该日成交是否含条件单触发（条件单画空心、手动画实心）
    var isConditional: Bool

    var text: String { mark.rawValue }
    /// 画在 K 线下方（买入 / 做 T）；false = 上方（卖出）
    var isBelow: Bool { mark != .sell }
}

/// 训练预警记录（条件单「仅提醒」触发时追加一条，不产生成交）
struct TrainAlertRecord: Identifiable, Equatable {
    var id: String
    var sessionID: String
    var condID: String?       // 来源条件单（可为空）
    var tradeDate: Int        // 触发时所在训练日 YYYYMMDD
    var price: Double         // 触发价（训练日收盘价）
    var message: String       // 触发文案
    var occurredAt: Date

    var tradeDateText: String { TrainSessionRecord.dateText(tradeDate) }
}

/// 训练条件单（含创建时所在训练日，供「当日有效」在训练态下的判定）
struct TrainCondRecord: Equatable, Identifiable {
    var order: SimCondOrder
    var createdDate: Int

    var id: String { order.id.uuidString }
}

/// 训练交易记录（一笔）
struct TrainTradeRecord: Identifiable, Equatable {
    var id: String            // UUID 字符串
    var sessionID: String
    var seq: Int              // 会话内序号，从 1 开始
    var direction: SimOrderDirection
    var tradeDate: Int        // YYYYMMDD；成交那根 K 线日期
    var price: Double
    var qty: Int
    var amount: Double
    var fee: Double
    var pnl: Double?          // 卖出（平仓）时的已实现盈亏；买入为 nil
    var note: String          // 备注，可为空串
    var trigger: TrainTradeTrigger = .manual
    var condKind: String?     // 触发它的条件单类型中文名（手动为 nil）
    var mark: TrainTradeMark = .buy

    var tradeDateText: String { TrainSessionRecord.dateText(tradeDate) }
}

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

// MARK: - 交易规则（按标的类别）

/// 交收规则：T+1 = 当日买入的份额下一训练日才可卖；T+0 = 当日买入当日即可卖。
/// 口径按 `MetaItem.type` 分类（工程内 meta.type 仅三种取值，见 src/data/universe.txt）：
///   - 沪深主板     → T+1
///   - 沪深京指数   → T+1（沪深交易所的 ETF / 指数）
///   - 扩展行情指数 → T+0（非大陆品种：港股通 / 恒生系列等）
enum TrainSettlementRule: String {
    case tPlus1 = "T+1"
    case tPlus0 = "T+0"

    var title: String { rawValue }

    /// 当日买入是否当日可卖
    var allowsSameDaySell: Bool { self == .tPlus0 }

    /// 由标的类别判定交收规则；未知类别按沪深规则（T+1）兜底
    static func resolve(for meta: MetaItem?) -> TrainSettlementRule {
        switch meta?.type {
        case "扩展行情指数": return .tPlus0
        default:            return .tPlus1
        }
    }
}

// MARK: - 交易模式

/// 训练交易模式：决定「下单」在什么时点、以什么价格成交
enum TrainTradeMode: String, CaseIterable, Identifiable {
    /// 当日收盘价成交：下单即刻以当前训练日收盘价成交，成交日 = 当前训练日
    case sameDayClose
    /// 隔日委托：下单只挂单，推进到下一训练日才以该日收盘价成交，成交日 = 下一训练日
    case nextDayClose

    var id: String { rawValue }

    var title: String { self == .sameDayClose ? "当日收盘价成交" : "隔日委托" }

    /// 紧凑处（票面元信息行 / 面板）使用的短名
    var shortTitle: String { self == .sameDayClose ? "当日成交" : "隔日委托" }

    var subtitle: String {
        self == .sameDayClose
            ? "点下单立刻以当前训练日收盘价成交（成交日 = 当前训练日）"
            : "隔日限价委托：点下单只挂单，仅下一训练日有效；该日行情触及委托价才按委托价成交，未触及即作废"
    }
}

/// 隔日委托队列里的一笔限价委托：仅下一训练日有效，该日行情触及 price 时按 price 成交
struct TrainPendingOrder: Identifiable, Equatable {
    var id: String = UUID().uuidString
    var direction: SimOrderDirection
    var qty: Int
    /// 委托价：买入要求当日最低价 ≤ 委托价、卖出要求当日最高价 ≥ 委托价
    var price: Double
    var note: String
    /// 挂单时所在训练日（判定日为推进后的新训练日）
    var placedDate: Int
}

// MARK: - 训练账户类型

/// 训练账户类型
enum TrainAccountType: String, CaseIterable, Identifiable {
    /// 百分比账户：不占用资金，按仓位比例（1/4、1/3、1/2、全仓）买卖，任何标的都买得起
    case percent
    /// 仓位金额账户：固定本金，买入前校验资金是否足够
    case fixedAmount

    var id: String { rawValue }

    var title: String { self == .percent ? "百分比账户" : "仓位金额账户" }

    /// 徽标 / 紧凑处使用的短名
    var shortTitle: String { self == .percent ? "百分比" : "金额" }

    var subtitle: String {
        self == .percent
            ? "不占用资金，按仓位比例（1/4、1/3、1/2、全仓）买卖，任何标的都买得起"
            : "固定本金，买入前校验资金；开启训练要求本金至少买得起 2 手（200 股）"
    }
}

/// 训练账户的规则常量与预检计算
enum TrainAccountRule {
    /// 仓位金额账户开启训练的最低手数要求（2 手）
    static let minLots = 2
    /// 仓位金额账户默认本金
    static let defaultCapital: Double = 100_000
    /// 百分比账户的名义本金：仅用于把「仓位比例」换算成股数，不参与资金校验
    static let notionalCapital: Double = 1_000_000

    /// 「至少能买 N 手」所需的最低资金（按 price 计，含买入费用）
    static func minCapital(price: Double, lotSize: Int, lots: Int = minLots) -> Double {
        guard price > 0 else { return 0 }
        let amount = price * Double(lotSize * lots)
        return amount + SimTradingRules.default.fee(amount: amount, direction: .buy)
    }
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

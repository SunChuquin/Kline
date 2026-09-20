//
//  SimTradingRules.swift
//  Kline
//
//  模拟交易规则：下单草稿入参、拒绝原因（带可直接展示的中文文案）、
//  以及集中管理的交易规则（T+1 / 整手 / 佣金 / 印花税 / 涨跌停 / 交易时段）
//  与校验逻辑。规则层是纯计算，校验失败不产生任何数据写入（写入由 SimStore 负责）。
//

import Foundation

// MARK: - 下单草稿

/// 下单草稿（视图 → SimStore 的入参）
struct SimOrderDraft {
    var accountID: UUID
    var metaID: Int
    var code: String
    var name: String
    var direction: SimOrderDirection
    var priceType: SimPriceType
    var price: Double?     // market 时为 nil
    var qty: Int
    /// 由条件单触发时携带来源条件单 id（手动下单保持 nil）
    var originCondID: UUID? = nil
}

// MARK: - 拒绝原因

/// 下单被拒原因（带可直接展示的中文文案）
enum SimOrderRejection: Error, Equatable {
    case emptyAccount
    case notLotMultiple(lot: Int)                                   // "委托数量需为 100 股的整数倍"
    case insufficientCash(available: Double, affordableQty: Int)    // "可用资金不足，可买 xxx 股"
    case insufficientShares(available: Int)                         // "可卖数量不足（T+1：当日买入不可卖）"
    case priceOutOfLimit(lower: Double, upper: Double)              // "委托价超出涨跌停区间 a ~ b"
    case noQuote                                                    // "暂无该标的行情，无法下单"

    var message: String {
        switch self {
        case .emptyAccount:
            return "请先选择有效的模拟账户"
        case .notLotMultiple(let lot):
            return "委托数量需为 \(lot) 股的整数倍"
        case .insufficientCash(let available, let affordableQty):
            return "可用资金不足，可买 \(affordableQty) 股（可用 \(SimFormat.amount(available))）"
        case .insufficientShares:
            return "可卖数量不足（T+1：当日买入不可卖）"
        case .priceOutOfLimit(let lower, let upper):
            return "委托价超出涨跌停区间 \(SimFormat.price(lower)) ~ \(SimFormat.price(upper))"
        case .noQuote:
            return "暂无该标的行情，无法下单"
        }
    }
}

// MARK: - 交易规则

/// 交易规则（集中管理，多账户可各自挂一份）
/// nonisolated：纯计算值类型，需在后台线程（如历史回测引擎）调用，不参与 UI 隔离
nonisolated struct SimTradingRules {
    var tPlus1Enabled: Bool = true
    var lotSize: Int = 100
    var commissionRate: Double = 0.00025      // 佣金万 2.5
    var commissionMin: Double = 5.0           // 最低 5 元
    var stampTaxRate: Double = 0.001          // 卖出印花税千一
    var limitPct: Double = 0.10               // 涨跌停 ±10%
    var priceTick: Double = 0.01              // 最小报价档位

    static let `default` = SimTradingRules()

    // MARK: 费用

    /// 佣金：成交额 × 费率，不足最低佣金按最低收
    func commission(amount: Double) -> Double {
        max(amount * commissionRate, commissionMin)
    }

    /// 印花税：仅卖出收取，买入为 0
    func stampTax(amount: Double, direction: SimOrderDirection) -> Double {
        direction == .sell ? amount * stampTaxRate : 0
    }

    /// 总费用：佣金 + 印花税
    func fee(amount: Double, direction: SimOrderDirection) -> Double {
        commission(amount: amount) + stampTax(amount: amount, direction: direction)
    }

    // MARK: 时段

    /// 交易时段：周一至周五 09:30–11:30 或 13:00–15:00（用系统当前时区判断）
    func isTradingSession(at date: Date) -> Bool {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)   // 1 = 周日 … 7 = 周六
        guard weekday >= 2 && weekday <= 6 else { return false }

        let minutes = calendar.component(.hour, from: date) * 60
            + calendar.component(.minute, from: date)
        let morning = (9 * 60 + 30)...(11 * 60 + 30)
        let afternoon = (13 * 60)...(15 * 60)
        return morning.contains(minutes) || afternoon.contains(minutes)
    }

    // MARK: 涨跌停

    /// 涨跌停区间（prevClose 为 nil 或非正时返回 nil，表示无法校验）
    func limitRange(prevClose: Double?) -> ClosedRange<Double>? {
        guard let prevClose = prevClose, prevClose > 0 else { return nil }
        return (prevClose * (1 - limitPct))...(prevClose * (1 + limitPct))
    }

    // MARK: 可买 / 可卖

    /// 按可用资金与委托价计算可买股数（向下取整到 lotSize，并预留佣金）
    func affordableQty(cash: Double, price: Double) -> Int {
        let lot = max(lotSize, 1)
        guard price > 0, cash > 0 else { return 0 }
        // 费用 = max(成交额 × 费率, 最低佣金)，故两个上界需同时满足，取较小者
        let byRate = cash / (price * (1 + commissionRate))
        let byMin = (cash - commissionMin) / price
        let raw = Int(min(byRate, byMin))
        guard raw > 0 else { return 0 }
        return raw / lot * lot
    }

    /// 按持仓计算可卖股数（T+1 开启时取 availableQty，向下取整到 lotSize）
    func sellableQty(position: SimPosition?) -> Int {
        guard let position = position else { return 0 }
        let lot = max(lotSize, 1)
        let raw = tPlus1Enabled ? position.availableQty : position.qty
        guard raw > 0 else { return 0 }
        return raw / lot * lot
    }

    // MARK: 校验

    /// 校验下单草稿：返回 nil 表示通过。
    /// 顺序：账户 → 整手 → 行情/报价 → 涨跌停 → 买入资金 / 卖出股数。
    func validate(draft: SimOrderDraft, account: SimAccount,
                  position: SimPosition?, lastPrice: Double?, prevClose: Double?) -> SimOrderRejection? {
        // 1. 账户：未选择（草稿与账户不匹配）或已归档的账户不可下单
        if account.isArchived || account.id != draft.accountID {
            return .emptyAccount
        }

        // 2. 整手：数量必须为正且为 lotSize 的整数倍
        let lot = max(lotSize, 1)
        if draft.qty <= 0 || draft.qty % lot != 0 {
            return .notLotMultiple(lot: lot)
        }

        // 3. 行情 / 报价：市价单需要最新价，限价单需要委托价
        let price: Double
        switch draft.priceType {
        case .market:
            guard let last = lastPrice, last > 0 else { return .noQuote }
            price = last
        case .limit:
            guard let limitPrice = draft.price, limitPrice > 0 else { return .noQuote }
            price = limitPrice
        }

        // 4. 涨跌停：仅限价单校验；prevClose 缺失时无法校验则跳过
        if draft.priceType == .limit, let range = limitRange(prevClose: prevClose), !range.contains(price) {
            return .priceOutOfLimit(lower: range.lowerBound, upper: range.upperBound)
        }

        // 5. 资金 / 股数
        switch draft.direction {
        case .buy:
            let amount = price * Double(draft.qty)
            let total = amount + fee(amount: amount, direction: .buy)
            if total > account.cash {
                return .insufficientCash(available: account.cash,
                                         affordableQty: affordableQty(cash: account.cash, price: price))
            }
        case .sell:
            let sellable = sellableQty(position: position)
            if draft.qty > sellable {
                return .insufficientShares(available: sellable)
            }
        }

        return nil
    }
}

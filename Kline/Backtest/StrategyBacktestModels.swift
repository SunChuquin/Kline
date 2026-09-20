//
//  StrategyBacktestModels.swift
//  Kline
//
//  历史回测的值类型模型：参数 / 成交 / 净值点 / 指标 / 结果（纯数据，无副作用）。
//
//  Created by 孙楚昆 on 2026/9/20.
//

import Foundation

// MARK: - 回测参数

/// 回测参数
/// nonisolated：纯值类型，需在后台线程参与回测计算（与 SimCondParams 同做法）
nonisolated struct BacktestParams: Equatable {
    var days: Int = 250                 // 区间交易日数（UI 给 60/120/250/500）
    var initialCapital: Double = 100000 // 初始资金
    var pool: StrategyPickPool = .market // 候选池（复用阶段二的枚举）
    var executeNextOpen: Bool = true    // true = 信号次日开盘成交；false = 当日收盘成交
    var period: KlinePeriod = .daily
    var includeEntry: Bool = true       // 是否把「选股命中」当作入场信号（默认是）
}

// MARK: - 成交

/// 一笔成交
/// nonisolated：纯值类型，需在后台线程参与回测计算
nonisolated struct BacktestTrade: Identifiable, Equatable {
    var id = UUID()
    var signalDate: Int      // 信号日（YYYYMMDD）
    var date: Int            // 成交日
    var metaID: Int
    var code: String
    var name: String
    var ruleKind: StrategyRuleKind?   // 触发规则；入场信号为 nil
    var direction: SimOrderDirection
    var qty: Int
    var price: Double
    var amount: Double
    var fee: Double
    var realizedPnL: Double?  // 仅卖出（已实现净盈亏，已扣卖出费用）
    var holdDays: Int?        // 仅卖出（自然日差）
}

// MARK: - 净值

/// 净值点
/// nonisolated：纯值类型，需在后台线程参与回测计算
nonisolated struct BacktestEquityPoint: Equatable {
    var date: Int
    var equity: Double
}

// MARK: - 指标

/// 指标
/// nonisolated：纯值类型，需在后台线程参与回测计算
nonisolated struct BacktestStats: Equatable {
    var initialCapital: Double
    var finalEquity: Double
    var totalReturn: Double      // 0.15 = +15%
    var annualized: Double
    var winRate: Double          // 0...1
    var profitFactor: Double     // Σ盈利 / |Σ亏损|
    var maxDrawdown: Double      // 0...1
    var tradeCount: Int          // 成交笔数
    var roundTrips: Int          // 平仓笔数
    var avgHoldDays: Double
}

// MARK: - 结果

/// 回测结果
/// nonisolated：纯值类型，需在后台线程参与回测计算
nonisolated struct BacktestResult: Equatable {
    var params: BacktestParams
    var stats: BacktestStats
    var equity: [BacktestEquityPoint]
    /// 最大回撤区间：equity 数组的**下标**区间（画图高亮用）
    var maxDrawdownRange: ClosedRange<Int>?
    var trades: [BacktestTrade]
    var scannedCount: Int
    var hitCount: Int
    var warnings: [String]      // 未来函数 / 跳空可疑 / 口径说明
    var skipped: [String]       // 取数失败等
}
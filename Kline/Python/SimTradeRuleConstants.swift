//
//  SimTradeRuleConstants.swift
//  Kline
//
//  ⚠️ **本文件由 scripts/gen_sim_rules_trust.py 自动生成，勿手改。**
//
//  真源 = `Kline/PyScripts/sim_rules.py` 顶部的交易规则常量
//  （_LOT_SIZE, _PRICE_TICK, _COMMISSION_RATE, _COMMISSION_MIN, _STAMP_TAX_RATE, _LIMIT_PCT）。
//
//  角色（《Python引擎下沉可行性分析.md》§10.9 套件 8 的扩展，见 §11.22）：
//  D2 之后交易规则单一真源是引擎脚本，Swift 侧只保存**自动生成的镜像**——
//  漂移由 `gen_sim_rules_trust.py --check` / `verify_sim_rules.py --trust` /
//  `KlineTests/SimRulesTrustTests` 三重拦下。因此呈现层可以**同步**读到正确常量，
//  无需为「整手 / 最小报价档位 / 费率 / 涨跌停幅」在每帧走一次引擎请求（闸门 6）。
//
//  ⚠️ 改了 sim_rules.py（含仅注释）后必须重跑
//     `python3 scripts/gen_sim_rules_trust.py`。
//

import Foundation

enum SimTradeRuleConstants {
    /// sim_rules.py `_LOT_SIZE`
    static let lotSize = 100
    /// sim_rules.py `_PRICE_TICK`
    static let priceTick = 0.01
    /// sim_rules.py `_COMMISSION_RATE`
    static let commissionRate = 0.00025
    /// sim_rules.py `_COMMISSION_MIN`
    static let commissionMin = 5.0
    /// sim_rules.py `_STAMP_TAX_RATE`
    static let stampTaxRate = 0.001
    /// sim_rules.py `_LIMIT_PCT`
    static let limitPct = 0.1
}

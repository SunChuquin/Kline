#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_sim_rules.py — sim_rules.py（条件单判定 / 交易规则下沉）PC 侧验证。

阶段 A0：把《Python引擎下沉可行性分析.md》§11 的 op 契约变成可跑代码。
本脚本内置一份用例如下：

  用例期望值由 Swift 现状（SimCondRule / SimCondEngine / SimTradingRules /
  SimFormat / SimConditionModels）逐条手工推得（见各用例注释），用于在
  A1「Swift 现状 dump」落地前先锁定移植口径、防回归。

  A1 之后以 golden 差分为主：scripts/verify_sim_rules.py --fixture
  KlineTests/Fixtures/sim_rules.json（该模式为逐位精确比对，浮点不容差）。

用法:
  python3 scripts/verify_sim_rules.py                    # 跑内置 A0 用例
  python3 scripts/verify_sim_rules.py --fixture FILE     # 跑 fixture 差分
  python3 scripts/verify_sim_rules.py --trust            # 套件 8 信任链三方一致性
退出码 0 = 全过；非 0 = 有失败（逐条打印）。

说明:
  - 值域比较：A0 用 rel_tol=1e-9 容差（避免手写浮点字面量 1 ULP 误报，
    公式级错误仍会暴露）；--fixture 模式为逐位精确（契约权威）。
  - 所有时间相关 op 显式注入 now + tzOffsetSeconds（不使用 IANA 时区名）。
"""

import datetime
import json
import math
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, "Kline", "PyScripts", "sim_rules.py")

A0_TOL = 1e-9          # A0 内嵌用例浮点容差（相对）
FIXTURE_TOL = 0.0      # fixture 差分：逐位精确


# ---------------------------------------------------------------------------
# 执行 sim_rules.py
# ---------------------------------------------------------------------------

_SRC = None


def run_op(inp):
    """以 PC 方式执行 sim_rules.py：注入 kline_input 后 exec，取 kline_result。"""
    global _SRC
    if _SRC is None:
        _SRC = open(SCRIPT, encoding="utf-8").read()
    g = {"kline_input": inp, "__name__": "__main__"}
    exec(compile(_SRC, SCRIPT, "exec"), g)
    return g["kline_result"]


# ---------------------------------------------------------------------------
# 递归比较
# ---------------------------------------------------------------------------

def _cmp(expected, actual, tol, path):
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return ["%s: 期望对象，实得 %r" % (path, actual)]
        errs = []
        for k in expected:
            if k not in actual:
                errs.append("%s.%s: 缺失" % (path, k))
            else:
                errs += _cmp(expected[k], actual[k], tol, "%s.%s" % (path, k))
        for k in actual:
            if k not in expected:
                errs.append("%s.%s: 多余字段（实得 %r）" % (path, k, actual[k]))
        return errs
    if isinstance(expected, list):
        if not isinstance(actual, list):
            return ["%s: 期望列表，实得 %r" % (path, actual)]
        if len(expected) != len(actual):
            return ["%s: 长度 期望 %d，实得 %d" % (path, len(expected), len(actual))]
        errs = []
        for i, (e, a) in enumerate(zip(expected, actual)):
            errs += _cmp(e, a, tol, "%s[%d]" % (path, i))
        return errs
    if isinstance(expected, bool) or isinstance(actual, bool):
        if expected is not actual:
            return ["%s: 期望 %r，实得 %r" % (path, expected, actual)]
        return []
    if isinstance(expected, (int, float)) and isinstance(actual, (int, float)):
        if tol > 0:
            if abs(expected - actual) > tol * max(1.0, abs(expected)):
                return ["%s: 期望 %r，实得 %r" % (path, expected, actual)]
            return []
        if expected != actual:
            return ["%s: 期望 %r（%r），实得 %r（%r）"
                    % (path, expected, repr(expected), actual, repr(actual))]
        return []
    if expected != actual:
        return ["%s: 期望 %r，实得 %r" % (path, expected, actual)]
    return []


# ---------------------------------------------------------------------------
# 用例构造helper
# ---------------------------------------------------------------------------

def C(name, op, inp, expected):
    return {"name": name, "op": op, "input": inp, "expected": expected}


def order(kind, params=None, direction="sell", price_type="market", qty=0,
          offset_ticks=0, alert_only=False, runtime=None, validity="longTerm",
          account_id="acc-1", name="条件单", created_at=None, expires_at=None):
    o = {
        "accountID": account_id,
        "name": name,
        "kind": kind,
        "params": params or {},
        "directive": {"direction": direction, "priceType": price_type,
                      "offsetTicks": offset_ticks, "qty": qty, "alertOnly": alert_only},
        "validity": validity,
        "runtime": runtime or {},
    }
    if created_at is not None:
        o["createdAt"] = created_at
    if expires_at is not None:
        o["expiresAt"] = expires_at
    return o


def _directive(**over):
    d = {"direction": "sell", "priceType": "market", "offsetTicks": 0,
         "qty": 300, "alertOnly": False}
    d.update(over)
    return d


def _order_with_directive(kind, params, d, **extra):
    return order(kind, params, direction=d["direction"], price_type=d["priceType"],
                 qty=d["qty"], offset_ticks=d["offsetTicks"], alert_only=d["alertOnly"], **extra)


def ev(kind, params, snapshot, directive=None, runtime=None, now="2026-10-17T01:00:00Z"):
    o = _order_with_directive(kind, params, _directive(**(directive or {})), runtime=runtime)
    return {"op": "cond_evaluate", "order": o, "snapshot": snapshot, "now": now}


def vc(kind, params, snapshot, directive=None, position=None, account=None,
       validity="longTerm", expires_at=None, now="2026-10-17T01:00:00Z"):
    over = directive or {}
    d = _directive(**over)
    if "direction" not in over:
        d["direction"] = "buy"      # 建单校验默认买入方向
    o = _order_with_directive(kind, params, d, validity=validity, expires_at=expires_at)
    acc = {"id": "acc-1", "isArchived": False, "cash": 1000000.0}
    acc.update(account or {})
    return {"op": "cond_validate_create", "order": o, "account": acc,
            "position": position, "snapshot": snapshot, "now": now}


def rej(code, message, **extra):
    r = {"code": code}
    r.update(extra)
    r["message"] = message
    return {"ok": True, "result": r}


OK_NULL = {"ok": True, "result": None}
OK = {"ok": True}


# ---------------------------------------------------------------------------
# A0 内置用例
# ---------------------------------------------------------------------------

def cases():
    cs = []

    # ---- sim_format（SimFormat.swift 逐字对拍） ----
    def fmt(fn, value, **kw):
        inp = {"op": "sim_format", "fn": fn, "value": value}
        inp.update(kw)
        return inp

    cs += [
        C("format.price", "sim_format", fmt("price", 1500.0), {"ok": True, "value": "1,500.00"}),
        C("format.price_frac", "sim_format", fmt("price", 1466.1712), {"ok": True, "value": "1,466.17"}),
        C("format.amount", "sim_format", fmt("amount", 1028446.5), {"ok": True, "value": "1,028,446.50"}),
        C("format.amount0_half_even_down", "sim_format", fmt("amount0", 1028446.5),
          {"ok": True, "value": "1,028,446"}),
        C("format.amount0_half_even_up", "sim_format", fmt("amount0", 1028447.5),
          {"ok": True, "value": "1,028,448"}),
        # NumberFormatter 默认 halfEven：0.125 → 0.12（不是 0.13）
        C("format.amount_half_boundary", "sim_format", fmt("amount", 0.125),
          {"ok": True, "value": "0.12"}),
        # 发现 2：舍入对象是「最短往返十进制表示」，不是二进制精确值（macOS Foundation 探针实证）
        C("format.amount_shortest_roundtrip_up", "sim_format", fmt("amount", 2.675),
          {"ok": True, "value": "2.68"}),
        C("format.amount_shortest_roundtrip_down", "sim_format", fmt("amount", 0.005),
          {"ok": True, "value": "0.00"}),
        C("format.amount_shortest_roundtrip_up2", "sim_format", fmt("amount", 0.015),
          {"ok": True, "value": "0.02"}),
        C("format.amount_shortest_roundtrip_even", "sim_format", fmt("amount", 0.025),
          {"ok": True, "value": "0.02"}),
        # 发现 3：amount / price 保留负零与「舍入到 0 的负数」的负号（不可归一）
        C("format.amount_neg_zero", "sim_format", fmt("amount", -0.0),
          {"ok": True, "value": "-0.00"}),
        C("format.amount_neg_rounds_to_zero", "sim_format", fmt("amount", -0.004),
          {"ok": True, "value": "-0.00"}),
        C("format.amount0_neg_zero", "sim_format", fmt("amount0", -0.0),
          {"ok": True, "value": "-0"}),
        C("format.signed_neg", "sim_format", fmt("signed", -420.0), {"ok": True, "value": "-420.00"}),
        C("format.signed_pos", "sim_format", fmt("signed", 2841.0), {"ok": True, "value": "+2,841.00"}),
        C("format.signed_neg_zero", "sim_format", fmt("signed", -0.0), {"ok": True, "value": "+0.00"}),
        C("format.pct_pos", "sim_format", fmt("pct", 0.31), {"ok": True, "value": "+0.31%"}),
        C("format.pct_neg", "sim_format", fmt("pct", -1.18), {"ok": True, "value": "-1.18%"}),
        C("format.shares", "sim_format", fmt("shares", 1000), {"ok": True, "value": "1,000"}),
        C("format.shares_big", "sim_format", fmt("shares", 1234567), {"ok": True, "value": "1,234,567"}),
        C("format.time_tz8", "sim_format",
          {"op": "sim_format", "fn": "time", "date": "2026-10-16T02:30:00Z", "tzOffsetSeconds": 28800},
          {"ok": True, "value": "10:30:00"}),
        C("format.dateTime_tz8", "sim_format",
          {"op": "sim_format", "fn": "dateTime", "date": "2026-09-19T06:52:00Z", "tzOffsetSeconds": 28800},
          {"ok": True, "value": "09-19 14:52"}),
        C("format.shortDate_tz8", "sim_format",
          {"op": "sim_format", "fn": "shortDate", "date": "2026-09-19T06:52:00Z", "tzOffsetSeconds": 28800},
          {"ok": True, "value": "09-19"}),
    ]

    # ---- cond_evaluate（SimCondRule.evaluate 三态） ----
    SPEC_PARAMS = {"triggerPrice": 1500.0, "compareUp": True}
    cs += [
        C("eval.price_up_fire", "cond_evaluate",
          ev("price", SPEC_PARAMS, {"last": 1501.0}, {"direction": "sell", "qty": 300}),
          {"ok": True, "result": {"decision": "fire", "qty": 300, "at": 1500.0}}),
        C("eval.price_down_fire", "cond_evaluate",
          ev("price", {"triggerPrice": 1400.0, "compareUp": False}, {"last": 1399.0},
             {"direction": "buy", "qty": 200}),
          {"ok": True, "result": {"decision": "fire", "qty": 200, "at": 1400.0}}),
        C("eval.price_hold", "cond_evaluate",
          ev("price", SPEC_PARAMS, {"last": 1499.0}, {"qty": 300}),
          {"ok": True, "result": {"decision": "hold", "runtime": {"batchDone": 0}}}),
        C("eval.price_abort", "cond_evaluate",
          ev("price", {}, {"last": 1500.0}, {"qty": 300}),
          {"ok": True, "result": {"decision": "abort", "reason": "触发价缺失"}}),
        C("eval.no_quote_hold", "cond_evaluate",
          ev("price", SPEC_PARAMS, {"last": None}, {"qty": 300}),
          {"ok": True, "result": {"decision": "hold", "runtime": {"batchDone": 0}}}),
        # OCO：两条腿同时满足取止损腿（风控优先）
        C("eval.stoploss_oco_prefers_stop", "cond_evaluate",
          ev("stopLoss", {"stopLossPrice": 1450.0, "takeProfitPrice": 1430.0}, {"last": 1440.0},
             {"qty": 300}),
          {"ok": True, "result": {"decision": "fire", "qty": 300, "at": 1450.0}}),
        C("eval.stoploss_take_only", "cond_evaluate",
          ev("stopLoss", {"takeProfitPrice": 1500.0}, {"last": 1501.0}, {"qty": 300}),
          {"ok": True, "result": {"decision": "fire", "qty": 300, "at": 1500.0}}),
        C("eval.stoploss_abort", "cond_evaluate",
          ev("stopLoss", {}, {"last": 1500.0}, {"qty": 300}),
          {"ok": True, "result": {"decision": "abort", "reason": "止盈止损参数缺失"}}),
        # 回落：未突破且从未突破过 → hold，runtime 不变（不写 extreme）
        C("eval.trailing_no_breakout_hold", "cond_evaluate",
          ev("trailing", {"breakoutPrice": 1500.0, "trailPct": 3.0}, {"last": 1490.0},
             {"direction": "sell", "qty": 300}),
          {"ok": True, "result": {"decision": "hold", "runtime": {"batchDone": 0}}}),
        # 首次突破 → 采样极值（drawdown 0）→ hold 且写回 extreme
        C("eval.trailing_track_extreme", "cond_evaluate",
          ev("trailing", {"breakoutPrice": 1500.0, "trailPct": 3.0}, {"last": 1520.0},
             {"direction": "sell", "qty": 300}),
          {"ok": True, "result": {"decision": "hold", "runtime": {"batchDone": 0, "extreme": 1520.0}}}),
        # (1600-1540)/1600*100 = 3.75 ≥ 3 → fire
        C("eval.trailing_drawdown_fire", "cond_evaluate",
          ev("trailing", {"breakoutPrice": 1500.0, "trailPct": 3.0}, {"last": 1540.0},
             {"direction": "sell", "qty": 300}, runtime={"extreme": 1600.0}),
          {"ok": True, "result": {"decision": "fire", "qty": 300, "at": 1540.0}}),
        C("eval.trailing_floor_fire", "cond_evaluate",
          ev("trailing", {"breakoutPrice": 1500.0, "trailPct": 3.0, "floorEnabled": True,
                          "floorPrice": 1400.0}, {"last": 1395.0}, {"direction": "sell", "qty": 300}),
          {"ok": True, "result": {"decision": "fire", "qty": 300, "at": 1395.0}}),
        C("eval.time_hold_future", "cond_evaluate",
          {"op": "cond_evaluate", "order": order("time", {"fireDate": "2026-10-20T01:30:00Z"},
                                                 qty=300),
           "snapshot": {"last": 1500.0}, "now": "2026-10-17T01:30:00Z"},
          {"ok": True, "result": {"decision": "hold", "runtime": {"batchDone": 0}}}),
        # 契约发现：evaluate 顶部 `guard last > 0` 先命中 → last 缺失时 time 也 hold，
        # 「退化用昨收」分支（snapshot.last ?? snapshot.prevClose）实际不可达。
        # 锁现状：不得顺手「修正」为昨收触发。
        C("eval.time_no_quote_holds", "cond_evaluate",
          {"op": "cond_evaluate", "order": order("time", {"fireDate": "2026-10-16T01:30:00Z"},
                                                 qty=300),
           "snapshot": {"last": None, "prevClose": 1480.0}, "now": "2026-10-17T01:30:00Z"},
          {"ok": True, "result": {"decision": "hold", "runtime": {"batchDone": 0}}}),
        # 时间到且 last>0 → 触发价取 last
        C("eval.time_fire_with_last", "cond_evaluate",
          {"op": "cond_evaluate", "order": order("time", {"fireDate": "2026-10-16T01:30:00Z"},
                                                 qty=300),
           "snapshot": {"last": 1500.0, "prevClose": 1480.0}, "now": "2026-10-17T01:30:00Z"},
          {"ok": True, "result": {"decision": "fire", "qty": 300, "at": 1500.0}}),
        C("eval.time_abort", "cond_evaluate",
          {"op": "cond_evaluate", "order": order("time", {}, qty=300),
           "snapshot": {"last": 1500.0}, "now": "2026-10-17T01:00:00Z"},
          {"ok": True, "result": {"decision": "abort", "reason": "触发时间缺失"}}),
        C("eval.changepct_up_fire", "cond_evaluate",
          ev("changePct", {"changeThreshold": 5.0}, {"last": 1500.0, "changePct": 5.5}, {"qty": 300}),
          {"ok": True, "result": {"decision": "fire", "qty": 300, "at": 1500.0}}),
        C("eval.changepct_down_fire", "cond_evaluate",
          ev("changePct", {"changeThreshold": -5.0}, {"last": 1400.0, "changePct": -5.2}, {"qty": 300}),
          {"ok": True, "result": {"decision": "fire", "qty": 300, "at": 1400.0}}),
        C("eval.changepct_hold", "cond_evaluate",
          ev("changePct", {"changeThreshold": 5.0}, {"last": 1500.0, "changePct": 4.9}, {"qty": 300}),
          {"ok": True, "result": {"decision": "hold", "runtime": {"batchDone": 0}}}),
        C("eval.changepct_abort", "cond_evaluate",
          ev("changePct", {"changeThreshold": 0.0}, {"last": 1500.0, "changePct": 5.0}, {"qty": 300}),
          {"ok": True, "result": {"decision": "abort", "reason": "涨跌幅阈值缺失"}}),
        C("eval.macross_up_fire", "cond_evaluate",
          ev("maCross", {"maPeriod": 20, "maAbove": True},
             {"last": 1505.0, "ma": 1500.0, "prevClose": 1495.0}, {"qty": 300}),
          {"ok": True, "result": {"decision": "fire", "qty": 300, "at": 1505.0}}),
        C("eval.macross_down_fire", "cond_evaluate",
          ev("maCross", {"maPeriod": 20, "maAbove": False},
             {"last": 1495.0, "ma": 1500.0, "prevClose": 1505.0}, {"qty": 300}),
          {"ok": True, "result": {"decision": "fire", "qty": 300, "at": 1495.0}}),
        C("eval.macross_hold", "cond_evaluate",
          ev("maCross", {"maPeriod": 20, "maAbove": True},
             {"last": 1510.0, "ma": 1500.0, "prevClose": 1505.0}, {"qty": 300}),
          {"ok": True, "result": {"decision": "hold", "runtime": {"batchDone": 0}}}),
        C("eval.macross_abort", "cond_evaluate",
          ev("maCross", {}, {"last": 1505.0, "ma": 1500.0, "prevClose": 1495.0}, {"qty": 300}),
          {"ok": True, "result": {"decision": "abort", "reason": "均线参数缺失"}}),
        # 网格首档：(1000-940)/1000*100 = 6 ≥ 5 → 第 0 档买入 100 股
        C("eval.grid_first_level_fire", "cond_evaluate",
          ev("grid", {"gridBase": 1000.0, "gridLower": 800.0, "gridUpper": 1200.0,
                      "gridStepPct": 5.0, "gridQtyPerLevel": 100, "gridMultiplier": 1.0},
             {"last": 940.0}, {"direction": "buy", "qty": 0}),
          {"ok": True, "result": {"decision": "fire", "qty": 100, "at": 940.0}}),
        C("eval.grid_hold_in_step", "cond_evaluate",
          ev("grid", {"gridBase": 1000.0, "gridLower": 800.0, "gridUpper": 1200.0,
                      "gridStepPct": 5.0, "gridQtyPerLevel": 100, "gridMultiplier": 1.0},
             {"last": 980.0}, {"direction": "buy", "qty": 0}),
          {"ok": True, "result": {"decision": "hold",
                                  "runtime": {"batchDone": 0, "gridLevel": 0,
                                              "gridLastPrice": 1000.0}}}),
        C("eval.grid_out_of_range_complete", "cond_evaluate",
          ev("grid", {"gridBase": 1000.0, "gridLower": 800.0, "gridUpper": 1200.0,
                      "gridStepPct": 5.0, "gridQtyPerLevel": 100, "gridMultiplier": 1.0},
             {"last": 1300.0}, {"direction": "buy", "qty": 0}),
          {"ok": True, "result": {"decision": "complete", "reason": "价格已越出网格区间"}}),
        # 第 4 档 × 3 倍：pow(3,4)=81 → 100*81 = 8100
        C("eval.grid_level4_multiplier", "cond_evaluate",
          ev("grid", {"gridBase": 1000.0, "gridLower": 800.0, "gridUpper": 1200.0,
                      "gridStepPct": 5.0, "gridQtyPerLevel": 100, "gridMultiplier": 3.0},
             {"last": 940.0}, {"direction": "buy", "qty": 0},
             runtime={"gridLevel": 4, "gridLastPrice": 1000.0}),
          {"ok": True, "result": {"decision": "fire", "qty": 8100, "at": 940.0}}),
        C("eval.grid_alertonly_zero_qty", "cond_evaluate",
          ev("grid", {"gridBase": 1000.0, "gridLower": 800.0, "gridUpper": 1200.0,
                      "gridStepPct": 5.0},
             {"last": 940.0}, {"direction": "buy", "qty": 0, "alertOnly": True}),
          {"ok": True, "result": {"decision": "fire", "qty": 0, "at": 940.0}}),
        C("eval.grid_abort_missing_step", "cond_evaluate",
          ev("grid", {"gridBase": 1000.0, "gridLower": 800.0, "gridUpper": 1200.0,
                      "gridQtyPerLevel": 100},
             {"last": 940.0}, {"direction": "buy", "qty": 0}),
          {"ok": True, "result": {"decision": "abort", "reason": "网格参数不完整"}}),
        # 分批首批：目标价 = 100*(1-0) = 100，95 ≤ 100；qty = 900/3/100*100 = 300
        C("eval.batch_buy_first", "cond_evaluate",
          ev("batch", {"batchCount": 3, "batchFirstPrice": 100.0, "batchStepPct": 5.0,
                       "batchTotalQty": 900},
             {"last": 95.0}, {"direction": "buy", "qty": 300}),
          {"ok": True, "result": {"decision": "fire", "qty": 300, "at": 95.0}}),
        # 第 2 批卖出：目标 100*(1+0.05)=105，106 ≥ 105
        C("eval.batch_sell_second", "cond_evaluate",
          ev("batch", {"batchCount": 3, "batchFirstPrice": 100.0, "batchStepPct": 5.0,
                       "batchTotalQty": 900},
             {"last": 106.0}, {"direction": "sell", "qty": 300}, runtime={"batchDone": 1}),
          {"ok": True, "result": {"decision": "fire", "qty": 300, "at": 106.0}}),
        # 末批吃余数：perBatch=1000/3/100*100=300，末批 = 1000-300*2 = 400
        C("eval.batch_last_remainder", "cond_evaluate",
          ev("batch", {"batchCount": 3, "batchFirstPrice": 100.0, "batchStepPct": 5.0,
                       "batchTotalQty": 1000},
             {"last": 85.0}, {"direction": "buy", "qty": 300}, runtime={"batchDone": 2}),
          {"ok": True, "result": {"decision": "fire", "qty": 400, "at": 85.0}}),
        C("eval.batch_complete", "cond_evaluate",
          ev("batch", {"batchCount": 3, "batchFirstPrice": 100.0, "batchStepPct": 5.0,
                       "batchTotalQty": 900},
             {"last": 85.0}, {"direction": "buy", "qty": 300}, runtime={"batchDone": 3}),
          {"ok": True, "result": {"decision": "complete", "reason": "分批已全部完成"}}),
        C("eval.batch_alertonly_no_total", "cond_evaluate",
          ev("batch", {"batchCount": 3, "batchFirstPrice": 100.0, "batchStepPct": 5.0},
             {"last": 95.0}, {"direction": "buy", "qty": 0, "alertOnly": True}),
          {"ok": True, "result": {"decision": "fire", "qty": 0, "at": 95.0}}),
        C("eval.batch_abort_count", "cond_evaluate",
          ev("batch", {"batchCount": 1, "batchFirstPrice": 100.0, "batchStepPct": 5.0,
                       "batchTotalQty": 900},
             {"last": 95.0}, {"direction": "buy", "qty": 300}),
          {"ok": True, "result": {"decision": "abort", "reason": "分批参数不完整"}}),
    ]

    # ---- cond_validate_create（SimCondRule.validateCreate） ----
    POS = {"availableQty": 500, "qty": 500}
    cs += [
        C("vc.ok_price_buy", "cond_validate_create",
          vc("price", {"triggerPrice": 1500.0}, {"last": 1500.0}, position=POS), OK_NULL),
        C("vc.archived_account", "cond_validate_create",
          vc("price", {"triggerPrice": 1500.0}, {"last": 1500.0}, position=POS,
             account={"isArchived": True}),
          rej("accountUnavailable", "请先选择有效的模拟账户")),
        C("vc.account_mismatch", "cond_validate_create",
          vc("price", {"triggerPrice": 1500.0}, {"last": 1500.0}, position=POS,
             account={"id": "other"}),
          rej("accountUnavailable", "请先选择有效的模拟账户")),
        C("vc.qty_not_lot", "cond_validate_create",
          vc("price", {"triggerPrice": 1500.0}, {"last": 1500.0}, directive={"qty": 150},
             position=POS),
          rej("invalidQty", "委托数量需为 100 股的整数倍且大于 0", lot=100)),
        C("vc.no_quote", "cond_validate_create",
          vc("price", {"triggerPrice": 1500.0}, {"last": None}, position=POS),
          rej("noQuote", "暂无该标的行情，无法创建条件单")),
        C("vc.sell_no_position", "cond_validate_create",
          vc("price", {"triggerPrice": 1500.0}, {"last": 1500.0},
             directive={"direction": "sell"}, position=None),
          rej("noPosition", "当前账户无可卖持仓，无法创建卖出条件单")),
        C("vc.price_missing_trigger", "cond_validate_create",
          vc("price", {}, {"last": 1500.0}, position=POS),
          rej("missingParam", "触发价不能为空", name="触发价")),
        C("vc.stoploss_missing_both", "cond_validate_create",
          vc("stopLoss", {"baseMode": "price"}, {"last": 1500.0}, position=POS),
          rej("missingParam", "止盈价或止损价不能为空", name="止盈价或止损价")),
        C("vc.stoploss_oco_invalid", "cond_validate_create",
          vc("stopLoss", {"baseMode": "price", "basePrice": 1500.0, "takeProfitPrice": 1490.0},
             {"last": 1500.0}, position=POS),
          rej("invalidOCORange", "止盈价应高于基准价，止损价应低于基准价")),
        C("vc.trailing_missing_breakout", "cond_validate_create",
          vc("trailing", {}, {"last": 1500.0}, position=POS),
          rej("missingParam", "突破价不能为空", name="突破价")),
        C("vc.trailing_floor_missing", "cond_validate_create",
          vc("trailing", {"breakoutPrice": 1500.0, "trailPct": 3.0, "floorEnabled": True},
             {"last": 1500.0}, position=POS),
          rej("missingParam", "保底价不能为空", name="保底价")),
        C("vc.time_past_invalid", "cond_validate_create",
          vc("time", {"fireDate": "2026-10-16T01:00:00Z"}, {"last": 1500.0}, position=POS,
             now="2026-10-17T01:00:00Z"),
          rej("invalidFireDate", "时间条件需选择未来的触发时间")),
        C("vc.time_future_ok", "cond_validate_create",
          vc("time", {"fireDate": "2026-10-20T01:00:00Z"}, {"last": 1500.0}, position=POS,
             now="2026-10-17T01:00:00Z"),
          OK_NULL),
        C("vc.changepct_missing", "cond_validate_create",
          vc("changePct", {}, {"last": 1500.0}, position=POS),
          rej("missingParam", "涨跌幅阈值不能为空", name="涨跌幅阈值")),
        C("vc.macross_bad_period", "cond_validate_create",
          vc("maCross", {"maPeriod": 7, "maAbove": True}, {"last": 1500.0}, position=POS),
          rej("missingParam", "均线周期不能为空", name="均线周期")),
        C("vc.macross_missing_above", "cond_validate_create",
          vc("maCross", {"maPeriod": 20}, {"last": 1500.0}, position=POS),
          rej("missingParam", "穿越方向不能为空", name="穿越方向")),
        C("vc.grid_inverted", "cond_validate_create",
          vc("grid", {"gridBase": 1000.0, "gridLower": 1200.0, "gridUpper": 800.0,
                      "gridStepPct": 5.0, "gridQtyPerLevel": 100},
             {"last": 1000.0}, position=POS),
          rej("invalidGridRange", "网格价格区间下界需低于上界")),
        C("vc.grid_bad_step", "cond_validate_create",
          vc("grid", {"gridBase": 1000.0, "gridLower": 800.0, "gridUpper": 1200.0,
                      "gridStepPct": 0.0, "gridQtyPerLevel": 100},
             {"last": 1000.0}, position=POS),
          rej("invalidGridStep", "网格间距需大于 0")),
        C("vc.grid_qty_not_lot", "cond_validate_create",
          vc("grid", {"gridBase": 1000.0, "gridLower": 800.0, "gridUpper": 1200.0,
                      "gridStepPct": 5.0, "gridQtyPerLevel": 150},
             {"last": 1000.0}, position=POS),
          rej("invalidQty", "委托数量需为 100 股的整数倍且大于 0", lot=100)),
        C("vc.batch_bad_count", "cond_validate_create",
          vc("batch", {"batchCount": 1, "batchTotalQty": 900, "batchFirstPrice": 100.0,
                       "batchStepPct": 5.0}, {"last": 100.0}, position=POS),
          rej("invalidBatchCount", "分批笔数需为 2 ~ 5 笔")),
        C("vc.batch_too_small", "cond_validate_create",
          vc("batch", {"batchCount": 3, "batchTotalQty": 200, "batchFirstPrice": 100.0,
                       "batchStepPct": 5.0}, {"last": 100.0}, position=POS),
          rej("batchTooSmall", "分批总数量不足：每批至少 1 手（100 股）", lot=100)),
        C("vc.untildate_missing_expires", "cond_validate_create",
          vc("price", {"triggerPrice": 1500.0}, {"last": 1500.0}, position=POS,
             validity="untilDate", expires_at=None),
          rej("missingParam", "有效期到期日不能为空", name="有效期到期日")),
        C("vc.alertonly_sell_no_position_ok", "cond_validate_create",
          vc("price", {"triggerPrice": 1500.0}, {"last": 1500.0},
             directive={"direction": "sell", "qty": 0, "alertOnly": True}, position=None),
          OK_NULL),
        C("vc.alertonly_grid_no_qty_ok", "cond_validate_create",
          vc("grid", {"gridBase": 1000.0, "gridLower": 800.0, "gridUpper": 1200.0,
                      "gridStepPct": 5.0},
             {"last": 1000.0}, directive={"direction": "buy", "qty": 0, "alertOnly": True},
             position=None),
          OK_NULL),
    ]

    # ---- cond_grid_level_count ----
    cs += [
        C("glc.basic", "cond_grid_level_count",
          {"op": "cond_grid_level_count",
           "order": order("grid", {"gridBase": 1000.0, "gridUpper": 1200.0,
                                   "gridLower": 800.0, "gridStepPct": 5.0})},
          {"ok": True, "count": 7}),   # floor(log1.05(1.2)) + floor(log1.05(1.25)) = 3 + 4
        C("glc.missing", "cond_grid_level_count",
          {"op": "cond_grid_level_count", "order": order("grid", {"gridBase": 1000.0})},
          {"ok": True, "count": 1}),
    ]

    # ---- cond_expired_reason ----
    def exp(validity, created, expires, now, tz, reason):
        o = {"validity": validity, "createdAt": created}
        if expires is not None:
            o["expiresAt"] = expires
        return {"op": "cond_expired_reason", "order": o, "now": now, "tzOffsetSeconds": tz}

    cs += [
        C("exp.longterm", "cond_expired_reason",
          exp("longTerm", "2026-01-01T00:00:00Z", None, "2026-10-17T01:00:00Z", 0, None),
          {"ok": True, "reason": None}),
        C("exp.day_crossed", "cond_expired_reason",
          exp("day", "2026-10-16T01:00:00Z", None, "2026-10-17T01:00:00Z", 0, None),
          {"ok": True, "reason": "当日有效条件单已跨日失效"}),
        C("exp.day_same", "cond_expired_reason",
          exp("day", "2026-10-17T01:00:00Z", None, "2026-10-17T23:00:00Z", 0, None),
          {"ok": True, "reason": None}),
        C("exp.untildate_expired", "cond_expired_reason",
          exp("untilDate", "2026-10-01T00:00:00Z", "2026-10-16T01:00:00Z",
              "2026-10-17T01:00:00Z", 0, None),
          {"ok": True, "reason": "已超过指定有效期"}),
        C("exp.untildate_same", "cond_expired_reason",
          exp("untilDate", "2026-10-01T00:00:00Z", "2026-10-17T01:00:00Z",
              "2026-10-17T23:00:00Z", 0, None),
          {"ok": True, "reason": None}),
        C("exp.untildate_null", "cond_expired_reason",
          exp("untilDate", "2026-10-01T00:00:00Z", None, "2026-10-17T01:00:00Z", 0, None),
          {"ok": True, "reason": None}),
        # 时区决定「本地日」：tz=+8 时 UTC 10-16T20:00 与 10-17T02:00 同为本地 10-17 → 未跨日
        C("exp.day_tz8_not_crossed", "cond_expired_reason",
          exp("day", "2026-10-16T20:00:00Z", None, "2026-10-17T02:00:00Z", 28800, None),
          {"ok": True, "reason": None}),
    ]

    # ---- cond_fire_direction ----
    cs += [
        C("fire_dir.nongrid", "cond_fire_direction",
          {"op": "cond_fire_direction", "order": order("price", {}, direction="sell"),
           "triggerPrice": 940.0},
          {"ok": True, "direction": "sell"}),
        C("fire_dir.grid_down_buy", "cond_fire_direction",
          {"op": "cond_fire_direction",
           "order": order("grid", {"gridBase": 1000.0}, runtime={"gridLastPrice": 1000.0}),
           "triggerPrice": 940.0},
          {"ok": True, "direction": "buy"}),
        C("fire_dir.grid_up_sell", "cond_fire_direction",
          {"op": "cond_fire_direction",
           "order": order("grid", {"gridBase": 1000.0}, runtime={"gridLastPrice": 1000.0}),
           "triggerPrice": 1060.0},
          {"ok": True, "direction": "sell"}),
        C("fire_dir.grid_base_fallback", "cond_fire_direction",
          {"op": "cond_fire_direction", "order": order("grid", {"gridBase": 1000.0}),
           "triggerPrice": 940.0},
          {"ok": True, "direction": "buy"}),
        C("fire_dir.grid_trigger_fallback", "cond_fire_direction",
          {"op": "cond_fire_direction", "order": order("grid", {}), "triggerPrice": 940.0},
          {"ok": True, "direction": "sell"}),
    ]

    # ---- cond_execution_price ----
    cs += [
        C("exec.market_nil", "cond_execution_price",
          {"op": "cond_execution_price",
           "directive": {"priceType": "market", "offsetTicks": 0}, "triggerPrice": 1500.0},
          {"ok": True, "price": None}),
        C("exec.limit_zero_tick", "cond_execution_price",
          {"op": "cond_execution_price",
           "directive": {"priceType": "limit", "offsetTicks": 0}, "triggerPrice": 1500.0},
          {"ok": True, "price": 1500.0}),
        C("exec.limit_up_2", "cond_execution_price",
          {"op": "cond_execution_price",
           "directive": {"priceType": "limit", "offsetTicks": 2}, "triggerPrice": 1500.0},
          {"ok": True, "price": 1500.0 + 2 * 0.01}),
        C("exec.limit_down_1", "cond_execution_price",
          {"op": "cond_execution_price",
           "directive": {"priceType": "limit", "offsetTicks": -1}, "triggerPrice": 1500.0},
          {"ok": True, "price": 1500.0 - 1 * 0.01}),
        C("exec.limit_floor_001", "cond_execution_price",
          {"op": "cond_execution_price",
           "directive": {"priceType": "limit", "offsetTicks": -100}, "triggerPrice": 1.0},
          {"ok": True, "price": 0.01}),
    ]

    # ---- cond_advance ----
    cs += [
        C("adv.grid", "cond_advance",
          {"op": "cond_advance",
           "order": order("grid", {}, runtime={"gridLevel": 2, "gridLastPrice": 1000.0}),
           "triggerPrice": 940.0},
          {"ok": True, "runtime": {"batchDone": 0, "gridLevel": 3, "gridLastPrice": 940.0}}),
        C("adv.batch", "cond_advance",
          {"op": "cond_advance", "order": order("batch", {}, runtime={"batchDone": 1}),
           "triggerPrice": 100.0},
          {"ok": True, "runtime": {"batchDone": 2}}),
        C("adv.nongrid_unchanged", "cond_advance",
          {"op": "cond_advance", "order": order("price", {}, runtime={"batchDone": 0}),
           "triggerPrice": 100.0},
          {"ok": True, "runtime": {"batchDone": 0}}),
    ]

    # ---- cond_repeatable_finished ----
    GRID7 = {"gridBase": 1000.0, "gridUpper": 1200.0, "gridLower": 800.0, "gridStepPct": 5.0}
    cs += [
        C("rep.grid_not_finished", "cond_repeatable_finished",
          {"op": "cond_repeatable_finished", "order": order("grid", GRID7, runtime={"gridLevel": 6})},
          {"ok": True, "finished": False}),
        C("rep.grid_finished", "cond_repeatable_finished",
          {"op": "cond_repeatable_finished", "order": order("grid", GRID7, runtime={"gridLevel": 7})},
          {"ok": True, "finished": True}),
        C("rep.batch_finished", "cond_repeatable_finished",
          {"op": "cond_repeatable_finished",
           "order": order("batch", {"batchCount": 3}, runtime={"batchDone": 3})},
          {"ok": True, "finished": True}),
        C("rep.batch_not_finished", "cond_repeatable_finished",
          {"op": "cond_repeatable_finished",
           "order": order("batch", {"batchCount": 3}, runtime={"batchDone": 2})},
          {"ok": True, "finished": False}),
        C("rep.nongrid_false", "cond_repeatable_finished",
          {"op": "cond_repeatable_finished", "order": order("price", {})},
          {"ok": True, "finished": False}),
    ]

    # ---- cond_alert_message ----
    def am(kind, params, price, direction="sell", runtime=None):
        return {"op": "cond_alert_message", "order": order(kind, params, direction=direction,
                                                           runtime=runtime),
                "triggerPrice": price}

    cs += [
        C("alert.price_up", "cond_alert_message",
          am("price", {"triggerPrice": 1500.0, "compareUp": True}, 1512.3),
          {"ok": True, "message": "预警：现价 1,512.30 上穿 1,500.00"}),
        C("alert.price_down", "cond_alert_message",
          am("price", {"triggerPrice": 1500.0, "compareUp": False}, 1488.0),
          {"ok": True, "message": "预警：现价 1,488.00 下破 1,500.00"}),
        C("alert.price_no_target", "cond_alert_message",
          am("price", {}, 1512.3),
          {"ok": True, "message": "预警：现价 1,512.30 触发价格条件"}),
        C("alert.stoploss_stop", "cond_alert_message",
          am("stopLoss", {"stopLossPrice": 1450.0, "takeProfitPrice": 1500.0}, 1440.0),
          {"ok": True, "message": "预警：现价 1,440.00 下破止损价 1,450.00"}),
        C("alert.stoploss_take", "cond_alert_message",
          am("stopLoss", {"stopLossPrice": 1450.0, "takeProfitPrice": 1500.0}, 1455.0),
          {"ok": True, "message": "预警：现价 1,455.00 上穿止盈价 1,500.00"}),
        C("alert.trailing_floor", "cond_alert_message",
          am("trailing", {"breakoutPrice": 1500.0, "trailPct": 3.0, "floorEnabled": True,
                          "floorPrice": 1400.0}, 1395.0),
          {"ok": True, "message": "预警：现价 1,395.00 跌破保底价 1,400.00"}),
        C("alert.trailing_sell", "cond_alert_message",
          am("trailing", {"breakoutPrice": 1500.0, "trailPct": 3.0}, 1500.0, direction="sell"),
          {"ok": True, "message": "预警：现价 1,500.00 回落达到 3.0%"}),
        C("alert.time", "cond_alert_message",
          am("time", {}, 1500.0),
          {"ok": True, "message": "预警：现价 1,500.00 到达触发时间"}),
        C("alert.changepct_up", "cond_alert_message",
          am("changePct", {"changeThreshold": 5.0}, 1500.0),
          {"ok": True, "message": "预警：现价 1,500.00 日涨幅达到 5.0%"}),
        C("alert.changepct_down", "cond_alert_message",
          am("changePct", {"changeThreshold": -5.0}, 1500.0),
          {"ok": True, "message": "预警：现价 1,500.00 日跌幅达到 5.0%"}),
        C("alert.macross", "cond_alert_message",
          am("maCross", {"maPeriod": 20, "maAbove": True}, 1500.0),
          {"ok": True, "message": "预警：现价 1,500.00 上穿 MA20"}),
        C("alert.grid", "cond_alert_message",
          am("grid", {}, 1500.0),
          {"ok": True, "message": "预警：现价 1,500.00 触发网格档位"}),
        C("alert.batch", "cond_alert_message",
          am("batch", {"batchCount": 3}, 1500.0, runtime={"batchDone": 1}),
          {"ok": True, "message": "预警：现价 1,500.00 触发分批第 2 批"}),
    ]

    # ---- cond_text（SimCondRule 文案族） ----
    def txt(field, o, tz=0):
        return {"op": "cond_text", "field": field, "order": o, "tzOffsetSeconds": tz}

    cs += [
        C("text.cond_price_up", "cond_text",
          txt("condition", order("price", {"triggerPrice": 1500.0, "compareUp": True})),
          {"ok": True, "text": "现价 ≥ 1,500.00"}),
        C("text.cond_price_down", "cond_text",
          txt("condition", order("price", {"triggerPrice": 1500.0, "compareUp": False})),
          {"ok": True, "text": "现价 ≤ 1,500.00"}),
        C("text.cond_stoploss", "cond_text",
          txt("condition", order("stopLoss", {"takeProfitPrice": 1600.0, "stopLossPrice": 1450.0,
                                              "basePrice": 1500.0})),
          {"ok": True, "text": "止盈 1,600.00（+6.67%）或 止损 1,450.00（-3.33%）"}),
        C("text.cond_trailing_sell", "cond_text",
          txt("condition", order("trailing", {"breakoutPrice": 1450.0, "trailPct": 3.0},
                                 direction="sell")),
          {"ok": True, "text": "回落卖出 · 突破 1,450.00 后回落 3.0%"}),
        C("text.cond_trailing_buy_floor", "cond_text",
          txt("condition", order("trailing", {"breakoutPrice": 1550.0, "trailPct": 2.5,
                                              "floorEnabled": True, "floorPrice": 1500.0},
                                 direction="buy")),
          {"ok": True, "text": "反弹买入 · 突破 1,550.00 后反弹 2.5% · 保底 1,500.00"}),
        C("text.cond_time_tz8", "cond_text",
          txt("condition", order("time", {"fireDate": "2026-09-19T06:52:00Z"}), tz=28800),
          {"ok": True, "text": "09-19 14:52 触发"}),
        C("text.cond_changepct_up", "cond_text",
          txt("condition", order("changePct", {"changeThreshold": 5.0})),
          {"ok": True, "text": "日涨幅 ≥ 5.0%"}),
        C("text.cond_changepct_down", "cond_text",
          txt("condition", order("changePct", {"changeThreshold": -5.0})),
          {"ok": True, "text": "日跌幅 ≥ 5.0%"}),
        C("text.cond_macross_default", "cond_text",
          txt("condition", order("maCross", {})),
          {"ok": True, "text": "上穿 MA20"}),
        C("text.cond_grid", "cond_text",
          txt("condition", order("grid", {"gridLower": 800.0, "gridUpper": 1200.0,
                                          "gridStepPct": 5.0})),
          {"ok": True, "text": "网格交易 · 区间 800.00 ~ 1,200.00 · 间距 5.0%"}),
        C("text.cond_batch", "cond_text",
          txt("condition", order("batch", {"batchCount": 3, "batchFirstPrice": 100.0,
                                           "batchStepPct": 5.0}, direction="buy")),
          {"ok": True, "text": "分批买入 3 批 · 首批 100.00 · 每批 5.0%"}),
        C("text.core_limit_offset", "cond_text",
          txt("directiveCore", order("price", {}, price_type="limit", direction="buy",
                                     qty=300, offset_ticks=2)),
          {"ok": True, "text": "限价买入（触发价 +2 档） 300 股"}),
        C("text.core_market", "cond_text",
          txt("directiveCore", order("price", {}, price_type="market", direction="sell", qty=300)),
          {"ok": True, "text": "市价卖出 300 股"}),
        C("text.core_grid", "cond_text",
          txt("directiveCore", order("grid", {"gridQtyPerLevel": 100, "gridMultiplier": 1.5},
                                     price_type="market", direction="buy")),
          {"ok": True, "text": "市价 · 每格 100 股 · 倍数 1.5"}),
        C("text.directive_prefix", "cond_text",
          txt("directive", order("price", {}, price_type="market", direction="buy", qty=300)),
          {"ok": True, "text": "触发后 市价买入 300 股"}),
        C("text.validity_day", "cond_text",
          txt("validity", order("price", {}, validity="day")),
          {"ok": True, "text": "当日有效"}),
        C("text.validity_longterm", "cond_text",
          txt("validity", order("price", {}, validity="longTerm")),
          {"ok": True, "text": "长期有效"}),
        C("text.validity_untildate_tz8", "cond_text",
          txt("validity", order("price", {}, validity="untilDate",
                                expires_at="2026-09-19T06:52:00Z"), tz=28800),
          {"ok": True, "text": "09-19 前有效"}),
        C("text.preview", "cond_text",
          txt("preview", order("price", {"triggerPrice": 1500.0, "compareUp": True},
                               price_type="market", direction="buy", qty=300, name="策略A")),
          {"ok": True, "text": "当 策略A 现价 ≥ 1,500.00 时，以 市价买入 300 股，长期有效"}),
    ]

    # ---- trade_calc（SimTradingRules 数值族） ----
    def tc(calc, **kw):
        inp = {"op": "trade_calc", "calc": calc}
        inp.update(kw)
        return inp

    cs += [
        C("calc.commission_rate", "trade_calc", tc("commission", amount=100000.0),
          {"ok": True, "value": 25.0}),
        C("calc.commission_min", "trade_calc", tc("commission", amount=1000.0),
          {"ok": True, "value": 5.0}),
        C("calc.stamp_sell", "trade_calc", tc("stampTax", amount=100000.0, direction="sell"),
          {"ok": True, "value": 100.0}),
        C("calc.stamp_buy", "trade_calc", tc("stampTax", amount=100000.0, direction="buy"),
          {"ok": True, "value": 0.0}),
        C("calc.fee_buy", "trade_calc", tc("fee", amount=100000.0, direction="buy"),
          {"ok": True, "value": 25.0}),
        C("calc.fee_sell", "trade_calc", tc("fee", amount=100000.0, direction="sell"),
          {"ok": True, "value": 125.0}),
        C("calc.limit_range", "trade_calc", tc("limitRange", prevClose=1500.0),
          {"ok": True, "range": {"lower": 1500.0 * (1 - 0.10), "upper": 1500.0 * (1 + 0.10)}}),
        C("calc.limit_range_nil", "trade_calc", tc("limitRange", prevClose=None),
          {"ok": True, "range": None}),
        C("calc.limit_range_zero", "trade_calc", tc("limitRange", prevClose=0.0),
          {"ok": True, "range": None}),
        C("calc.affordable_basic", "trade_calc", tc("affordableQty", cash=100000.0, price=100.0),
          {"ok": True, "value": 900}),
        C("calc.affordable_below_lot", "trade_calc", tc("affordableQty", cash=400.0, price=100.0),
          {"ok": True, "value": 0}),
        C("calc.affordable_zero_cash", "trade_calc", tc("affordableQty", cash=0.0, price=100.0),
          {"ok": True, "value": 0}),
        C("calc.sellable_t1", "trade_calc",
          tc("sellableQty", position={"availableQty": 250, "qty": 300}, tPlus1Enabled=True),
          {"ok": True, "value": 200}),
        C("calc.sellable_no_t1", "trade_calc",
          tc("sellableQty", position={"availableQty": 250, "qty": 300}, tPlus1Enabled=False),
          {"ok": True, "value": 300}),
        C("calc.sellable_nil", "trade_calc", tc("sellableQty", position=None),
          {"ok": True, "value": 0}),
        C("calc.session_morning", "trade_calc",
          tc("isTradingSession", at="2026-10-16T02:00:00Z", tzOffsetSeconds=28800),
          {"ok": True, "value": True}),
        C("calc.session_noon_break", "trade_calc",
          tc("isTradingSession", at="2026-10-16T04:00:00Z", tzOffsetSeconds=28800),
          {"ok": True, "value": False}),
        C("calc.session_weekend", "trade_calc",
          tc("isTradingSession", at="2026-10-17T02:00:00Z", tzOffsetSeconds=28800),
          {"ok": True, "value": False}),
        C("calc.session_open_boundary", "trade_calc",
          tc("isTradingSession", at="2026-10-16T01:30:00Z", tzOffsetSeconds=28800),
          {"ok": True, "value": True}),
        C("calc.session_close_boundary", "trade_calc",
          tc("isTradingSession", at="2026-10-16T03:30:00Z", tzOffsetSeconds=28800),
          {"ok": True, "value": True}),
        C("calc.session_after", "trade_calc",
          tc("isTradingSession", at="2026-10-16T03:31:00Z", tzOffsetSeconds=28800),
          {"ok": True, "value": False}),
    ]

    # ---- trade_validate（SimTradingRules.validate） ----
    def tv(direction="buy", price_type="market", qty=100, price=None, cash=1000000.0,
           position=None, last_price=1500.0, prev_close=1500.0, account_id="acc-1"):
        draft = {"accountID": account_id, "direction": direction, "priceType": price_type, "qty": qty}
        if price is not None:
            draft["price"] = price
        return {"op": "trade_validate", "draft": draft,
                "account": {"id": "acc-1", "isArchived": False, "cash": cash},
                "position": position, "lastPrice": last_price, "prevClose": prev_close}

    cs += [
        C("tv.ok_market_buy", "trade_validate", tv(), OK_NULL),
        C("tv.not_lot", "trade_validate", tv(qty=150),
          rej("notLotMultiple", "委托数量需为 100 股的整数倍", lot=100)),
        C("tv.no_quote_market", "trade_validate", tv(last_price=None),
          rej("noQuote", "暂无该标的行情，无法下单")),
        C("tv.no_quote_limit", "trade_validate", tv(price_type="limit", price=None),
          rej("noQuote", "暂无该标的行情，无法下单")),
        C("tv.out_of_limit", "trade_validate",
          tv(price_type="limit", price=1700.0, prev_close=1500.0),
          rej("priceOutOfLimit", "委托价超出涨跌停区间 1,350.00 ~ 1,650.00",
              lower=1500.0 * (1 - 0.10), upper=1500.0 * (1 + 0.10))),
        C("tv.limit_in_range", "trade_validate",
          tv(price_type="limit", price=1600.0, prev_close=1500.0), OK_NULL),
        C("tv.insufficient_cash", "trade_validate",
          tv(price_type="market", qty=100, last_price=100.0, cash=10000.0),
          rej("insufficientCash", "可用资金不足，可买 0 股（可用 10,000.00）",
              available=10000.0, affordableQty=0)),
        C("tv.insufficient_shares", "trade_validate",
          tv(direction="sell", qty=300, position={"availableQty": 200, "qty": 200}),
          rej("insufficientShares", "可卖数量不足（T+1：当日买入不可卖）", available=200)),
        C("tv.empty_account", "trade_validate", tv(account_id="other"),
          rej("emptyAccount", "请先选择有效的模拟账户")),
    ]

    # ---- E 组 · strategy_parse（StrategyRuleParser.parse） ----
    def sp(lines):
        return {"op": "strategy_parse", "lines": lines}

    def rule(kind, params, raw, line):
        return {"kind": kind, "params": params, "raw": raw, "line": line}

    cs += [
        C("sp.basic_two_lines", "strategy_parse",
          sp("PRICE(OP=>=, VALUE=1480)\n{注释行}\n\nSTOP_LOSS(MODE=PCT, PROFIT=10, LOSS=5)"),
          {"ok": True, "errors": [], "rules": [
              rule("PRICE", {"OP": ">=", "VALUE": "1480"},
                   "PRICE(OP=>=, VALUE=1480)", 1),
              rule("STOP_LOSS", {"MODE": "PCT", "PROFIT": "10", "LOSS": "5"},
                   "STOP_LOSS(MODE=PCT, PROFIT=10, LOSS=5)", 4),
          ]}),
        # 全角括号 / 等号 / 逗号归一化；raw 保留原文
        C("sp.fullwidth", "strategy_parse",
          sp("PRICE（OP＝>=, VALUE＝1480）"),
          {"ok": True, "errors": [], "rules": [
              rule("PRICE", {"OP": ">=", "VALUE": "1480"}, "PRICE（OP＝>=, VALUE＝1480）", 1)]}),
        # 关键字大小写不敏感、参数键统一大写、值里空格去掉
        C("sp.lowercase_and_spaces", "strategy_parse",
          sp("price(op=>=, value=1 480)"),
          {"ok": True, "errors": [], "rules": [
              rule("PRICE", {"OP": ">=", "VALUE": "1480"}, "price(op=>=, value=1 480)", 1)]}),
        # ORD* 保留键照常收进 params 且不报错
        C("sp.reserved_keys", "strategy_parse",
          sp("PRICE(OP=>=, VALUE=1, ORDQTY=300, ORDOFF=2)"),
          {"ok": True, "errors": [], "rules": [
              rule("PRICE", {"OP": ">=", "VALUE": "1", "ORDQTY": "300", "ORDOFF": "2"},
                   "PRICE(OP=>=, VALUE=1, ORDQTY=300, ORDOFF=2)", 1)]}),
        # 空括号 / 尾随逗号都容忍
        C("sp.empty_inner", "strategy_parse", sp("PRICE()"),
          {"ok": True, "errors": [], "rules": [rule("PRICE", {}, "PRICE()", 1)]}),
        C("sp.trailing_comma", "strategy_parse", sp("PRICE(VALUE=1,)"),
          {"ok": True, "errors": [], "rules": [rule("PRICE", {"VALUE": "1"}, "PRICE(VALUE=1,)", 1)]}),
        C("sp.unknown_keyword", "strategy_parse", sp("PRICE2(VALUE=1)"),
          {"ok": True, "rules": [], "errors": ["第 1 行：未知规则 PRICE2"]}),
        C("sp.no_paren", "strategy_parse", sp("PRICE VALUE=1"),
          {"ok": True, "rules": [], "errors": ["第 1 行：规则格式应为 KEYWORD(KEY=VAL, ...)"]}),
        C("sp.unclosed", "strategy_parse", sp("PRICE(VALUE=1"),
          {"ok": True, "rules": [], "errors": ["第 1 行：括号不闭合"]}),
        # 单个 token 出错只跳过该 token，规则本体照常产出（与 Swift 一致）
        C("sp.bad_param", "strategy_parse", sp("PRICE(OP)"),
          {"ok": True, "errors": ["第 1 行：参数格式应为 KEY=VAL（OP）"],
           "rules": [rule("PRICE", {}, "PRICE(OP)", 1)]}),
        C("sp.unknown_param", "strategy_parse", sp("PRICE(OP=>=, XXX=1)"),
          {"ok": True, "errors": ["第 1 行：价格条件 未识别参数 XXX"],
           "rules": [rule("PRICE", {"OP": ">="}, "PRICE(OP=>=, XXX=1)", 1)]}),
        # 一行内多个错误按 token 顺序累积
        C("sp.multi_errors_one_line", "strategy_parse", sp("PRICE(OP, XXX=1)"),
          {"ok": True,
           "errors": ["第 1 行：参数格式应为 KEY=VAL（OP）", "第 1 行：价格条件 未识别参数 XXX"],
           "rules": [rule("PRICE", {}, "PRICE(OP, XXX=1)", 1)]}),
        # CRLF：Swift `components(separatedBy: .newlines)` 把 \r 与 \n 视为**两个**分隔符，
        # 切出一个中间空行 → 第二行规则的行号是 3（A1 dump 实证，非「一个换行」）
        C("sp.crlf_lines", "strategy_parse", sp("PRICE(VALUE=1)\r\nTIME(DATE=2026-10-20)"),
          {"ok": True, "errors": [], "rules": [
              rule("PRICE", {"VALUE": "1"}, "PRICE(VALUE=1)", 1),
              rule("TIME", {"DATE": "2026-10-20"}, "TIME(DATE=2026-10-20)", 3)]}),
    ]

    # ---- E 组 · strategy_rule_line（StrategyRuleParser.line） ----
    cs += [
        C("srl.spec_order", "strategy_rule_line",
          {"op": "strategy_rule_line",
           "call": {"kind": "STOP_LOSS",
                    "params": {"LOSS": "5", "PROFIT": "10", "MODE": "PCT", "BASE": "COST"}}},
          {"ok": True, "line": "STOP_LOSS(BASE=COST, MODE=PCT, PROFIT=10, LOSS=5)"}),
        C("srl.reserved_last", "strategy_rule_line",
          {"op": "strategy_rule_line",
           "call": {"kind": "PRICE",
                    "params": {"VALUE": "1480", "OP": ">=", "ORDOFF": "2", "ORDQTY": "300"}}},
          {"ok": True, "line": "PRICE(OP=>=, VALUE=1480, ORDQTY=300, ORDOFF=2)"}),
        C("srl.empty", "strategy_rule_line",
          {"op": "strategy_rule_line", "call": {"kind": "PRICE", "params": {}}},
          {"ok": True, "line": "PRICE()"}),
        C("srl.bad_kind", "strategy_rule_line",
          {"op": "strategy_rule_line", "call": {"kind": "NOPE", "params": {}}},
          {"ok": False, "error": "strategy_rule_line 的 call.kind 必须是 %s 之一（实得 'NOPE'）"
                                 % " / ".join(["PRICE", "STOP_LOSS", "TRAILING", "TIME",
                                               "CHANGE_PCT", "MA_CROSS", "GRID", "BATCH"])}),
    ]

    # ---- E 组 · strategy_catalog（StrategyRuleCatalog） ----
    cs += [
        C("scat.price", "strategy_catalog", {"op": "strategy_catalog", "kind": "PRICE"},
          {"ok": True, "catalog": {"PRICE": {
              "title": "价格条件", "conditionOrderTitle": "价格条件", "simCondKind": "price",
              "specs": [
                  {"key": "OP", "title": "比较方向", "type": "option", "isOptional": False,
                   "placeholder": ">=", "options": [">=", "<="], "unit": ""},
                  {"key": "VALUE", "title": "触发价", "type": "number", "isOptional": False,
                   "placeholder": "1480.00", "options": [], "unit": "元"},
              ],
              "knownKeys": ["OP", "VALUE"],
          }}}),
        C("scat.macross", "strategy_catalog", {"op": "strategy_catalog", "kind": "MA_CROSS"},
          {"ok": True, "catalog": {"MA_CROSS": {
              "title": "均线条件", "conditionOrderTitle": "均线条件", "simCondKind": "maCross",
              "specs": [
                  {"key": "PERIOD", "title": "周期", "type": "option", "isOptional": False,
                   "placeholder": "20", "options": ["5", "10", "20", "60"], "unit": "日"},
                  {"key": "DIR", "title": "方向", "type": "option", "isOptional": False,
                   "placeholder": "UP", "options": ["UP", "DOWN"], "unit": ""},
              ],
              "knownKeys": ["DIR", "PERIOD"],
          }}}),
    ]

    # ---- E 组 · strategy_validate（StrategyValidator.validate） ----
    def sv(body=None, ref=None, rules="", kind="STRATEGY", trade=None,
           picker_exists=False, syntax=None):
        doc = {"kind": kind, "pickBody": body or "", "pickRef": ref,
               "rules": rules, "trade": trade if trade is not None else {}}
        inp = {"op": "strategy_validate", "doc": doc, "pickerExists": picker_exists}
        if syntax is not None:
            inp["pickSyntaxError"] = syntax
        return inp

    OK_PRICE = "PRICE(OP=>=, VALUE=1)"
    cs += [
        C("sval.missing_pick", "strategy_validate", sv(rules=OK_PRICE),
          {"ok": True, "issues": ["策略需要选股条件：请填写内嵌选股公式，或引用一个选股公式"]}),
        C("sval.ok_minimal", "strategy_validate", sv(body="C>1", rules=OK_PRICE),
          {"ok": True, "issues": []}),
        C("sval.both_body_and_ref", "strategy_validate",
          sv(body="C>1", ref="abc", rules=OK_PRICE),
          {"ok": True, "issues": [
              "PICKREF 与内嵌选股条件只能二选一，请保留其一",
              "引用的选股公式已不存在，请重新选择或改用内嵌选股条件"]}),
        C("sval.ref_exists", "strategy_validate",
          sv(ref="abc", rules=OK_PRICE, picker_exists=True),
          {"ok": True, "issues": []}),
        C("sval.pick_syntax_error", "strategy_validate",
          sv(body="C>1", rules=OK_PRICE, syntax="缺少右括号"),
          {"ok": True, "issues": ["内嵌选股公式语法错误：缺少右括号"]}),
        C("sval.empty_rules", "strategy_validate", sv(body="C>1"),
          {"ok": True, "issues": ["策略至少需要一条交易规则"]}),
        C("sval.missing_required_param", "strategy_validate",
          sv(body="C>1", rules="PRICE(OP=>=)"),
          {"ok": True, "issues": ["第 1 行：价格条件 缺少参数 VALUE"]}),
        C("sval.number_not_numeric", "strategy_validate",
          sv(body="C>1", rules="PRICE(OP=>=, VALUE=abc)"),
          {"ok": True, "issues": ["触发价 需要填数字"]}),
        C("sval.macross_bad_period", "strategy_validate",
          sv(body="C>1", rules="MA_CROSS(PERIOD=7, DIR=UP)"),
          {"ok": True, "issues": ["均线周期只支持 5 / 10 / 20 / 60"]}),
        C("sval.grid_inverted", "strategy_validate",
          sv(body="C>1", rules="GRID(BASE=1000, LOW=1200, HIGH=800, STEP=5, QTY=300)"),
          {"ok": True, "issues": ["网格价格区间下界不得高于上界"]}),
        C("sval.grid_and_batch", "strategy_validate",
          sv(body="C>1",
             rules="GRID(BASE=1000, LOW=800, HIGH=1200, STEP=5, QTY=300)\n"
                   "BATCH(TOTAL=900, COUNT=3, FIRST=10, GAP=0.1)"),
          {"ok": True, "issues": ["网格交易与分批建仓不宜同一策略并存，请保留其一"]}),
        C("sval.duplicate_rule", "strategy_validate",
          sv(body="C>1", rules="PRICE(OP=>=, VALUE=1)\nPRICE(OP=>=, VALUE=2)"),
          {"ok": True, "issues": ["第 2 行：价格条件 规则重复声明，请保留其一"]}),
        C("sval.parse_error_passthrough", "strategy_validate",
          sv(body="C>1", rules="PRICE2(VALUE=1)"),
          {"ok": True, "issues": ["第 1 行：未知规则 PRICE2"]}),
        C("sval.override_qty_not_lot", "strategy_validate",
          sv(body="C>1", rules="PRICE(OP=>=, VALUE=1, ORDQTY=150)"),
          {"ok": True, "issues": ["第 1 行：委托数量需为 100 股的整数倍"]}),
        C("sval.trade_missing_direction", "strategy_validate",
          sv(body="C>1", rules=OK_PRICE, trade={"qty": 300}),
          {"ok": True, "issues": ["请选择交易方向"]}),
        C("sval.trade_qty_and_amount", "strategy_validate",
          sv(body="C>1", rules=OK_PRICE,
             trade={"direction": "buy", "qty": 300, "amount": 15000.0}),
          {"ok": True, "issues": ["交易指令的数量与金额只能二选一"]}),
        C("sval.trade_qty_not_lot", "strategy_validate",
          sv(body="C>1", rules=OK_PRICE, trade={"direction": "buy", "qty": 150}),
          {"ok": True, "issues": ["交易指令数量需为 100 股的整数倍"]}),
        C("sval.trade_limit_no_offset", "strategy_validate",
          sv(body="C>1", rules=OK_PRICE,
             trade={"direction": "buy", "qty": 300, "priceType": "limit"}),
          {"ok": True, "issues": ["限价委托需设置偏移档次（OFFSETTICKS）"]}),
        C("sval.trade_untildate_no_expires", "strategy_validate",
          sv(body="C>1", rules=OK_PRICE,
             trade={"direction": "buy", "qty": 300, "validity": "untilDate"}),
          {"ok": True, "issues": ["指定日期有效期需设置到期日（EXPIRES）"]}),
        # 非 STRATEGY 文档不校验 TRADE 段
        C("sval.tech_skips_trade", "strategy_validate",
          sv(body="C>1", rules=OK_PRICE, kind="TECH", trade={"qty": 150}),
          {"ok": True, "issues": []}),
    ]

    # ---- E 组 · strategy_preview（StrategyPreview） ----
    PREVIEW_DOC = {
        "kind": "STRATEGY",
        "pickBody": "C>1 AND C>REF(C,1)",
        "rules": "PRICE(OP=>=, VALUE=1480)\nSTOP_LOSS(MODE=PCT, PROFIT=10, LOSS=5)",
        "trade": {"direction": "buy", "qty": 300, "priceType": "limit",
                  "offsetTicks": 2, "validity": "day"},
    }
    NOTICE = "触发后的下单指令（方向 / 数量 / 报价方式）本阶段未定义，留待接入执行阶段"
    cs += [
        C("spv.full", "strategy_preview",
          {"op": "strategy_preview", "doc": PREVIEW_DOC, "tzOffsetSeconds": 28800},
          {"ok": True,
           "summary": "对命中【内嵌选股条件：C>1 AND C>REF(C,1)】的标的："
                      "① 现价 ≥ 1480.00 时触发；② 止盈 +10% 或 止损 \u22125%（先到者为准）。",
           "pick": "内嵌选股条件：C>1 AND C>REF(C,1)",
           "trade": "买入 300 股 · 限价委托（触发价 +2 档） · 当日有效",
           "executionNotice": NOTICE,
           "triggers": ["现价 ≥ 1480.00 时触发", "止盈 +10% 或 止损 \u22125%（先到者为准）"]}),
        C("spv.no_rules_with_ref", "strategy_preview",
          {"op": "strategy_preview", "doc": {"kind": "STRATEGY", "pickRef": "sel1",
                                             "pickBody": "", "rules": "", "trade": {}},
           "pickerName": "强势股", "tzOffsetSeconds": 28800},
          {"ok": True,
           "summary": "对命中【引用选股公式：强势股】的标的：暂无交易规则。",
           "pick": "引用选股公式：强势股",
           "trade": "未配置交易指令",
           "executionNotice": NOTICE,
           "triggers": []}),
        C("spv.deleted_picker_and_truncate", "strategy_preview",
          {"op": "strategy_preview",
           "doc": {"kind": "STRATEGY", "pickRef": "gone", "pickBody": "",
                   "rules": "", "trade": {"amount": 15000.5}},
           "tzOffsetSeconds": 28800},
          {"ok": True,
           "summary": "对命中【引用选股公式：已删除的公式】的标的：暂无交易规则。",
           "pick": "引用选股公式：已删除的公式",
           "trade": "15,000.5 元（按最新价折算）".replace(",", ""),
           "executionNotice": NOTICE,
           "triggers": []}),
        C("spv.body_truncated_and_trigger_fallback", "strategy_preview",
          {"op": "strategy_preview",
           "doc": {"kind": "STRATEGY", "pickBody": "A>1 AND B>2 AND C>3 AND D>4 AND E>5",
                   "rules": "PRICE(OP=>=, VALUE=abc)\nTIME(DATE=2026-10-20, AT=09:30)\n"
                            "CHANGE_PCT(PCT=5, OP=<=)\nMA_CROSS(PERIOD=20, DIR=DOWN)\n"
                            "GRID(BASE=1000, LOW=800, HIGH=1200, STEP=5, QTY=300, MULT=2)\n"
                            "BATCH(TOTAL=900, COUNT=3, FIRST=10.5, GAP=0.3)",
                   "trade": {}},
           "tzOffsetSeconds": 28800},
          {"ok": True,
           "summary": "对命中【内嵌选股条件：A>1 AND B>2 AND C>3 AND …】的标的："
                      "① 现价 ≥ abc 时触发；② 2026-10-20 09:30 触发；③ 当日涨跌幅 ≤ 5% 触发；"
                      "④ 下破 MA20 触发；⑤ 网格区间 800.00 ~ 1200.00，每 5% 一档，每档 300 股，倍数 2；"
                      "⑥ 分 3 批建仓：首批 10.50，每批价差 0.30。",
           "pick": "内嵌选股条件：A>1 AND B>2 AND C>3 AND …",
           "trade": "未配置交易指令",
           "executionNotice": NOTICE,
           "triggers": ["现价 ≥ abc 时触发", "2026-10-20 09:30 触发", "当日涨跌幅 ≤ 5% 触发",
                        "下破 MA20 触发",
                        "网格区间 800.00 ~ 1200.00，每 5% 一档，每档 300 股，倍数 2",
                        "分 3 批建仓：首批 10.50，每批价差 0.30"]}),
    ]

    # ---- E 组 · trade_parse（StrategyTradeParser.parse） ----
    TZ8 = 28800
    ACC = "E621E1F8-C36C-495A-8F1F-1D9A3B5F3E0D"
    cs += [
        C("tp.all_keys", "trade_parse",
          {"op": "trade_parse", "tzOffsetSeconds": TZ8,
           "lines": ["DIRECTION=BUY", "QTY=300", "AMOUNT=15000.5", "PRICETYPE=LIMIT",
                     "OFFSETTICKS=2", "VALIDITY=DATE", "EXPIRES=2026-12-31",
                     "ACCOUNTS=" + ACC],
           },
          {"ok": True, "errors": [],
           "spec": {"direction": "buy", "qty": 300, "amount": 15000.5, "priceType": "limit",
                    "offsetTicks": 2, "validity": "untilDate",
                    "expiresAt": "2026-12-30T16:00:00Z", "accountIDs": [ACC]}}),
        C("tp.errors_and_unknown_key", "trade_parse",
          {"op": "trade_parse", "tzOffsetSeconds": TZ8,
           "lines": ["FOO=1", "QTY=abc", "DIRECTION=X", "PRICETYPE=Y", "VALIDITY=Z",
                     "EXPIRES=abc", "ACCOUNTS=bad", "NOKEY"]},
          {"ok": True,
           "errors": ["TRADE 段未识别键 FOO", "QTY 需要填整数", "DIRECTION 只能是 BUY 或 SELL",
                      "PRICETYPE 只能是 MARKET 或 LIMIT", "VALIDITY 只能是 DAY / LONG / DATE",
                      "EXPIRES 日期格式应为 YYYY-MM-DD", "ACCOUNTS 含非法账户 id：bad",
                      "TRADE 段格式应为 KEY=VALUE（NOKEY）"],
           "spec": {"direction": None, "qty": None, "amount": None, "priceType": None,
                    "offsetTicks": None, "validity": None, "expiresAt": None, "accountIDs": []}}),
        # 全角等号归化 + 值内空格去掉 + 小写枚举容忍 + 小写 uuid 归一为大写
        C("tp.fullwidth_and_case", "trade_parse",
          {"op": "trade_parse", "tzOffsetSeconds": TZ8,
           "lines": ["DIRECTION＝buy", "QTY=3 00", "VALIDITY=longterm",
                     "ACCOUNTS=" + ACC.lower()]},
          {"ok": True, "errors": [],
           "spec": {"direction": "buy", "qty": 300, "amount": None, "priceType": None,
                    "offsetTicks": None, "validity": "longTerm", "expiresAt": None,
                    "accountIDs": [ACC]}}),
        # 单字符串入参也接受（按行拆分）
        C("tp.single_string", "trade_parse",
          {"op": "trade_parse", "tzOffsetSeconds": TZ8, "lines": "DIRECTION=SELL\nVALIDITY=LONG"},
          {"ok": True, "errors": [],
           "spec": {"direction": "sell", "qty": None, "amount": None, "priceType": None,
                    "offsetTicks": None, "validity": "longTerm", "expiresAt": None,
                    "accountIDs": []}}),
    ]

    # ---- E 组 · trade_serialize（StrategyTradeParser.serialize） ----
    cs += [
        C("ts.roundtrip", "trade_serialize",
          {"op": "trade_serialize", "tzOffsetSeconds": TZ8,
           "spec": {"direction": "sell", "qty": 300, "amount": 15000.5, "priceType": "limit",
                    "offsetTicks": -1, "validity": "untilDate",
                    "expiresAt": "2026-12-30T16:00:00Z", "accountIDs": [ACC]}},
          {"ok": True, "text": "DIRECTION=SELL\nQTY=300\nAMOUNT=15000.5\nPRICETYPE=LIMIT\n"
                               "OFFSETTICKS=-1\nVALIDITY=DATE\nEXPIRES=2026-12-31\nACCOUNTS=" + ACC}),
        C("ts.integral_amount", "trade_serialize",
          {"op": "trade_serialize", "tzOffsetSeconds": TZ8,
           "spec": {"direction": "buy", "amount": 15000.0}},
          {"ok": True, "text": "DIRECTION=BUY\nAMOUNT=15000"}),
        C("ts.empty", "trade_serialize",
          {"op": "trade_serialize", "tzOffsetSeconds": TZ8, "spec": {}},
          {"ok": True, "text": ""}),
    ]

    # ---- E 组 · trade_override（StrategyTradeParser.override） ----
    cs += [
        C("to.full", "trade_override",
          {"op": "trade_override",
           "call": {"kind": "PRICE",
                    "params": {"ORDDIR": "sell", "ORDQTY": "300", "ORDPT": "limit",
                               "ORDOFF": "2"}}},
          {"ok": True, "isEmpty": False, "summary": "卖出 300 股 限价 +2 档",
           "override": {"dir": "sell", "qty": 300, "amount": None, "priceType": "limit",
                        "offsetTicks": 2}}),
        C("to.empty", "trade_override",
          {"op": "trade_override", "call": {"kind": "PRICE", "params": {}}},
          {"ok": True, "isEmpty": True, "summary": None,
           "override": {"dir": None, "qty": None, "amount": None, "priceType": None,
                        "offsetTicks": None}}),
        C("to.offset_only_negative", "trade_override",
          {"op": "trade_override", "call": {"kind": "PRICE", "params": {"ORDOFF": "-1"}}},
          {"ok": True, "isEmpty": False, "summary": "-1 档",
           "override": {"dir": None, "qty": None, "amount": None, "priceType": None,
                        "offsetTicks": -1}}),
        C("to.amount_only", "trade_override",
          {"op": "trade_override", "call": {"kind": "PRICE", "params": {"ORDAMT": "15000.5"}}},
          {"ok": True, "isEmpty": False, "summary": "15000.5 元",
           "override": {"dir": None, "qty": None, "amount": 15000.5, "priceType": None,
                        "offsetTicks": None}}),
        C("to.bad_values_are_none", "trade_override",
          {"op": "trade_override",
           "call": {"kind": "PRICE", "params": {"ORDDIR": "X", "ORDQTY": "abc", "ORDPT": "Y"}}},
          {"ok": True, "isEmpty": True, "summary": None,
           "override": {"dir": None, "qty": None, "amount": None, "priceType": None,
                        "offsetTicks": None}}),
    ]

    # ---- D 组 · strategy_drafts（StrategyCondGenerator.drafts 纯映射） ----
    META = {"id": 7, "code": "600519.SH", "name": "贵州茅台"}

    def sd(rules, trade=None, last=1500.0, cost=1450.0):
        return {"op": "strategy_drafts", "rules": rules,
                "trade": trade if trade is not None else {}, "meta": META,
                "accountID": "acc-1", "lastPrice": last, "costPrice": cost,
                "tzOffsetSeconds": TZ8}

    def draft(kind, params, direction, price_type, offset_ticks, qty, validity):
        return {"accountID": "acc-1", "metaID": 7, "code": "600519.SH", "name": "贵州茅台",
                "kind": kind, "params": params,
                "directive": {"direction": direction, "priceType": price_type,
                              "offsetTicks": offset_ticks, "qty": qty},
                "validity": validity}

    cs += [
        C("sd.price_defaults", "strategy_drafts", sd("PRICE(OP=>=, VALUE=1480)"),
          {"ok": True, "skips": [],
           "drafts": [draft("price",
                            {"compareUp": True, "triggerPrice": 1480.0,
                             "baseMode": "price", "floorEnabled": False},
                            "sell", "market", 0, 0, "longTerm")]}),
        C("sd.price_compare_down", "strategy_drafts", sd("PRICE(OP=<=, VALUE=1480)"),
          {"ok": True, "skips": [],
           "drafts": [draft("price",
                            {"compareUp": False, "triggerPrice": 1480.0,
                             "baseMode": "price", "floorEnabled": False},
                            "sell", "market", 0, 0, "longTerm")]}),
        # MODE 缺省 = PCT；BASE 缺省 = COST → 以成本价 1450 折算止盈 / 止损价
        C("sd.stoploss_percent_from_cost", "strategy_drafts",
          sd("STOP_LOSS(PROFIT=10, LOSS=5)"),
          {"ok": True, "skips": [],
           "drafts": [draft("stopLoss",
                            {"basePrice": 1450.0, "baseMode": "percent",
                             "takeProfitPrice": 1595.0, "stopLossPrice": 1377.5,
                             "floorEnabled": False},
                            "sell", "market", 0, 0, "longTerm")]}),
        C("sd.stoploss_price_mode_last", "strategy_drafts",
          sd("STOP_LOSS(BASE=LAST, MODE=PRICE, PROFIT=1600, LOSS=1400)"),
          {"ok": True, "skips": [],
           "drafts": [draft("stopLoss",
                            {"basePrice": 1500.0, "baseMode": "price",
                             "takeProfitPrice": 1600.0, "stopLossPrice": 1400.0,
                             "floorEnabled": False},
                            "sell", "market", 0, 0, "longTerm")]}),
        # 未持仓（costPrice=None）+ 缺省 BASE=COST → basePrice nil、止盈止损价无法折算
        C("sd.stoploss_no_cost", "strategy_drafts",
          sd("STOP_LOSS(PROFIT=10)", cost=None),
          {"ok": True, "skips": [],
           "drafts": [draft("stopLoss",
                            {"baseMode": "percent", "floorEnabled": False},
                            "sell", "market", 0, 0, "longTerm")]}),
        C("sd.trailing_with_floor", "strategy_drafts", sd("TRAILING(PCT=3, FLOOR=1400)"),
          {"ok": True, "skips": [],
           "drafts": [draft("trailing",
                            {"breakoutPrice": 1500.0, "trailPct": 3.0,
                             "floorEnabled": True, "floorPrice": 1400.0,
                             "baseMode": "price"},
                            "sell", "market", 0, 0, "longTerm")]}),
        C("sd.time_default_at", "strategy_drafts", sd("TIME(DATE=2026-10-20)"),
          {"ok": True, "skips": [],
           "drafts": [draft("time",
                            {"fireDate": "2026-10-20T01:30:00Z",
                             "baseMode": "price", "floorEnabled": False},
                            "sell", "market", 0, 0, "longTerm")]}),
        # Calendar 归一化：2 月 30 日 → 3 月 2 日
        C("sd.time_normalizes_overflow", "strategy_drafts",
          sd("TIME(DATE=2026-02-30, AT=09:30)"),
          {"ok": True, "skips": [],
           "drafts": [draft("time",
                            {"fireDate": "2026-03-02T01:30:00Z",
                             "baseMode": "price", "floorEnabled": False},
                            "sell", "market", 0, 0, "longTerm")]}),
        C("sd.grid", "strategy_drafts",
          sd("GRID(BASE=1000, LOW=800, HIGH=1200, STEP=5, QTY=300, MULT=2)"),
          {"ok": True, "skips": [],
           "drafts": [draft("grid",
                            {"gridBase": 1000.0, "gridLower": 800.0, "gridUpper": 1200.0,
                             "gridStepPct": 5.0, "gridQtyPerLevel": 300,
                             "gridMultiplier": 2.0,
                             "baseMode": "price", "floorEnabled": False},
                            "sell", "market", 0, 300, "longTerm")]}),
        # MULT 缺省 = 1；GAP（元）→ batchStepPct（%）= GAP / 首批价 × 100
        C("sd.batch_gap_conversion", "strategy_drafts",
          sd("BATCH(TOTAL=3000, COUNT=3, FIRST=15, GAP=0.30)"),
          {"ok": True, "skips": [],
           "drafts": [draft("batch",
                            {"batchTotalQty": 3000, "batchCount": 3,
                             "batchFirstPrice": 15.0, "batchStepPct": 2.0,
                             "baseMode": "price", "floorEnabled": False},
                            "buy", "market", 0, 3000, "longTerm")]}),
        C("sd.macross_and_changepct", "strategy_drafts",
          sd("MA_CROSS(PERIOD=20, DIR=UP)\nCHANGE_PCT(PCT=5, OP=<=)"),
          {"ok": True, "skips": [],
           "drafts": [
               draft("maCross",
                     {"maPeriod": 20, "maAbove": True, "baseMode": "price",
                      "floorEnabled": False}, "sell", "market", 0, 0, "longTerm"),
               draft("changePct",
                     {"changeThreshold": -5.0, "baseMode": "price", "floorEnabled": False},
                     "sell", "market", 0, 0, "longTerm"),
           ]}),
        # ORD* 覆盖 > TRADE 段
        C("sd.override_beats_trade", "strategy_drafts",
          sd("PRICE(VALUE=1480, ORDDIR=BUY, ORDQTY=500, ORDPT=LIMIT, ORDOFF=2)",
             trade={"direction": "sell", "qty": 300, "priceType": "market",
                    "validity": "day"}),
          {"ok": True, "skips": [],
           "drafts": [draft("price",
                            {"compareUp": True, "triggerPrice": 1480.0,
                             "baseMode": "price", "floorEnabled": False},
                            "buy", "limit", 2, 500, "day")]}),
        # TRADE 金额按最新价折算整手（15000/1500 = 10 股 → 不足 1 手 → 补足 1 手 = 100 股）
        C("sd.trade_amount_to_lots", "strategy_drafts",
          sd("PRICE(VALUE=100)",
             trade={"direction": "buy", "amount": 15000.0, "priceType": "limit",
                    "offsetTicks": 1, "validity": "untilDate",
                    "expiresAt": "2026-12-31T00:00:00Z"}),
          {"ok": True, "skips": [],
           "drafts": [dict(draft("price",
                                 {"compareUp": True, "triggerPrice": 100.0,
                                  "baseMode": "price", "floorEnabled": False},
                                 "buy", "limit", 1, 100, "untilDate"),
                           expiresAt="2026-12-31T00:00:00Z")]}),
        # 失败规则进 skips；成功规则照常产出
        C("sd.skip_and_draft", "strategy_drafts",
          sd("PRICE(VALUE=100)\nGRID(BASE=1)\nTIME(DATE=abc)"),
          {"ok": True,
           "drafts": [draft("price",
                            {"compareUp": True, "triggerPrice": 100.0,
                             "baseMode": "price", "floorEnabled": False},
                            "sell", "market", 0, 0, "longTerm")],
           "skips": [
               {"title": "贵州茅台 600519.SH · 网格交易",
                "reason": "网格交易参数不完整（BASE / LOW / HIGH / STEP / QTY）"},
               {"title": "贵州茅台 600519.SH · 时间条件",
                "reason": "时间条件缺少有效日期（DATE）"},
           ]}),
        # 解析错误行被忽略（drafts 只取 calls，与 Swift 一致）
        C("sd.parse_errors_ignored", "strategy_drafts",
          sd("PRICE2(VALUE=1)\nPRICE(OP=>=)"),
          {"ok": True, "drafts": [], "skips": [
              {"title": "贵州茅台 600519.SH · 价格条件",
               "reason": "价格条件缺少有效的触发价（VALUE）"}]}),
    ]

    # ---- D 组 · strategy_entry_draft ----
    def sed(trade, last=1500.0):
        return {"op": "strategy_entry_draft", "trade": trade, "meta": META,
                "accountID": "acc-1", "lastPrice": last}

    cs += [
        C("sed.with_qty", "strategy_entry_draft",
          sed({"direction": "buy", "qty": 300, "validity": "longTerm"}),
          {"ok": True, "draft": draft("price",
                                      {"compareUp": True, "triggerPrice": 1500.0,
                                       "baseMode": "price", "floorEnabled": False},
                                      "buy", "market", 0, 300, "longTerm")}),
        C("sed.amount_to_lots", "strategy_entry_draft",
          sed({"direction": "sell", "amount": 150000.0, "priceType": "limit",
               "offsetTicks": 3, "validity": "untilDate",
               "expiresAt": "2026-12-31T00:00:00Z"}),
          {"ok": True, "draft": dict(draft("price",
                                           {"compareUp": True, "triggerPrice": 1500.0,
                                            "baseMode": "price", "floorEnabled": False},
                                           "sell", "limit", 3, 100, "untilDate"),
                                     expiresAt="2026-12-31T00:00:00Z")}),
        C("sed.no_direction", "strategy_entry_draft", sed({"qty": 300}),
          {"ok": True, "draft": None}),
        C("sed.no_quote", "strategy_entry_draft",
          sed({"direction": "buy", "qty": 300}, last=0.0),
          {"ok": True, "draft": None}),
    ]

    # ---- F 组 · backtest_run（StrategyBacktestEngine.run 纯逻辑引擎） ----
    #
    # 期望值推导说明：本组期望值**逐条手工推得**（不是从实现输出抄回），
    # 公式型指标（annualized / maxDrawdown）按 Swift 源码里写明的公式在测试内独立表达。
    # F 组的最终权威仍是 A1 的 Swift 现状 dump（§12 backtest_golden.json）。
    BT_META = {"id": 7, "code": "600519.SH", "name": "贵州茅台"}

    def seq_dates(start_ymd, n):
        base = datetime.date(start_ymd // 10000, (start_ymd // 100) % 100, start_ymd % 100)
        return [int((base + datetime.timedelta(days=i)).strftime("%Y%m%d")) for i in range(n)]

    def flat_bars(dates, price=10.0):
        return [{"date": d, "open": price, "high": price, "low": price, "close": price}
                for d in dates]

    def bt_inp(doc, bars, hits=None, params=None, metas=None):
        return {"op": "backtest_run", "doc": doc,
                "params": params or {"days": 250, "initialCapital": 100000.0,
                                     "executeNextOpen": True, "includeEntry": True},
                "bars": bars, "pickHits": hits or {},
                "metas": {"7": BT_META} if metas is None else metas,
                "tzOffsetSeconds": 28800}

    def bt_doc(rules="", pick_body="", trade=None):
        return {"kind": "STRATEGY", "pickBody": pick_body, "pickRef": None,
                "rules": rules, "trade": trade or {}}

    def bt_trade(signal, date, kind, direction, qty, price, amount, fee, pnl, hold=None):
        return {"signalDate": signal, "date": date, "metaID": 7,
                "code": "600519.SH", "name": "贵州茅台", "ruleKind": kind,
                "direction": direction, "qty": qty, "price": price, "amount": amount,
                "fee": fee, "realizedPnL": pnl, "holdDays": hold}

    def bt_stats(initial, final, total_return, annualized, win_rate, profit_factor,
                 max_dd, trade_count, round_trips, avg_hold):
        return {"initialCapital": initial, "finalEquity": final, "totalReturn": total_return,
                "annualized": annualized, "winRate": win_rate, "profitFactor": profit_factor,
                "maxDrawdown": max_dd, "tradeCount": trade_count, "roundTrips": round_trips,
                "avgHoldDays": avg_hold}

    def bt_equity(dates, default, overrides=None):
        out = [{"date": d, "equity": default} for d in dates]
        for i, v in (overrides or {}).items():
            out[i]["equity"] = v
        return out

    BT_PARAMS_ECHO = {"days": 250, "initialCapital": 100000.0,
                      "executeNextOpen": True, "includeEntry": True}
    BT_FIXED = ["TRAILING 与 bar 内「先 high 后 low」判定属乐观假设，实际触发价可能更差",
                "实盘条件单只吃行情快照，触发必然晚于回测的逐 bar 判定"]

    # --- A：入场（次日开盘）+ 止盈止损（PCT / 成本价基准） ---
    DA = seq_dates(20260105, 30)
    BA = flat_bars(DA)
    BA[2]["low"] = 9.0                      # 跌破止损价 → 触发
    A_FINAL = 98975.74525                   # 100000 − 20000 − 5 + 19004.75 − 24.00475
    A_TRADES = [
        bt_trade(DA[0], DA[1], None, "buy", 2000, 10.0, 20000.0, 5.0, None, None),
        # 触发价 = 成本价 10.0025 × 0.95 = 9.502375；成交额 19004.75；费用 5 + 19.00475
        bt_trade(DA[2], DA[2], "STOP_LOSS", "sell", 2000, 9.502375, 19004.75, 24.00475,
                 -1024.25475, 1),
    ]
    cs += [
        C("bt.entry_then_stop_loss", "backtest_run",
          bt_inp(bt_doc(rules="STOP_LOSS(PROFIT=10, LOSS=5)"), {"7": BA},
                 hits={"7": [DA[0]]}),
          {"ok": True, "params": BT_PARAMS_ECHO,
           "stats": bt_stats(100000.0, A_FINAL, A_FINAL / 100000.0 - 1,
                             math.pow(1 + (A_FINAL / 100000.0 - 1), 252 / 30.0) - 1,
                             0.0, 0.0, 1 - A_FINAL / 100000.0, 2, 1, 1.0),
           "equity": bt_equity(DA, A_FINAL, {0: 100000.0, 1: 99995.0}),
           "maxDrawdownRange": [0, 2],
           "trades": A_TRADES,
           "scannedCount": 1, "hitCount": 1,
           "warnings": BT_FIXED,
           "skipped": []}),
    ]

    # --- B：无可参与标的（空结果） ---
    DB = seq_dates(20260105, 10)
    cs += [
        C("bt.empty_result", "backtest_run",
          bt_inp(bt_doc(), {"7": flat_bars(DB), "8": []}, metas={}),
          {"ok": True, "params": BT_PARAMS_ECHO,
           "stats": bt_stats(100000.0, 100000.0, 0, 0, 0, 0, 0, 0, 0, 0),
           "equity": [], "maxDrawdownRange": None, "trades": [],
           "scannedCount": 2, "hitCount": 0,
           "warnings": ["没有可参与回测的标的（行情缺失或不足 30 根），未产生净值曲线"] + BT_FIXED,
           "skipped": ["标 #7：行情不足 30 根（10），已跳过",
                       "标 #8：无历史行情数据，已跳过"]}),
    ]

    # --- C：未来函数 + 跳空警告（不产生任何成交） ---
    DC = seq_dates(20260105, 30)
    BC = flat_bars(DC)
    BC[20] = {"date": DC[20], "open": 12.0, "high": 12.0, "low": 12.0, "close": 12.0}
    cs += [
        C("bt.warnings_future_and_gap", "backtest_run",
          bt_inp(bt_doc(pick_body="BACKSET(C,1) > 0 AND REF(C,-1) > 0 AND ZIG(3,5)"),
                 {"7": BC}),
          {"ok": True, "params": BT_PARAMS_ECHO,
           "stats": bt_stats(100000.0, 100000.0, 0, 0, 0, 0, 0, 0, 0, 0),
           "equity": bt_equity(DC, 100000.0), "maxDrawdownRange": None, "trades": [],
           "scannedCount": 1, "hitCount": 0,
           "warnings": ["选股公式包含未来函数（BACKSET），回测结果偏乐观",
                        "选股公式包含未来函数（ZIG），回测结果偏乐观",
                        "选股公式包含未来函数（REF 负偏移），回测结果偏乐观",
                        "1 只标的出现单日跳空 > 11%，疑似除权，结果可能失真"] + BT_FIXED,
           "skipped": []}),
    ]

    # --- D：网格（下移买一档 → 上移卖一档） ---
    DD = seq_dates(20260105, 30)
    BD = flat_bars(DD)
    BD[2]["low"] = 8.5                      # 触发下移一档（目标价 9）
    D_FINAL = 100084.0                      # cash 80084 + 持仓 2000 × 10
    D_TRADES = [
        bt_trade(DD[0], DD[1], None, "buy", 2000, 10.0, 20000.0, 5.0, None, None),
        bt_trade(DD[2], DD[2], "GRID", "buy", 100, 9.0, 900.0, 5.0, None, None),
        # 上移卖出同档数量；成本价 = 20910/2100（含网格买入费用）
        bt_trade(DD[2], DD[2], "GRID", "sell", 100, 10.0, 1000.0, 6.0,
                 (10.0 - 20910.0 / 2100.0) * 100 - 6.0, 1),
    ]
    cs += [
        C("bt.grid_round_trip", "backtest_run",
          bt_inp(bt_doc(rules="GRID(BASE=10, LOW=5, HIGH=20, STEP=10, QTY=100, MULT=1)"),
                 {"7": BD}, hits={"7": [DD[0]]}),
          {"ok": True, "params": BT_PARAMS_ECHO,
           "stats": bt_stats(100000.0, D_FINAL, D_FINAL / 100000.0 - 1,
                             math.pow(1 + (D_FINAL / 100000.0 - 1), 252 / 30.0) - 1,
                             0.0, 0.0, 1 - 99995.0 / 100000.0, 3, 1, 1.0),
           "equity": bt_equity(DD, D_FINAL, {0: 100000.0, 1: 99995.0}),
           "maxDrawdownRange": [0, 1],
           "trades": D_TRADES,
           "scannedCount": 1, "hitCount": 1,
           "warnings": ["期末仍有 1 只标的未平仓，已按最后一个交易日收盘价计入净值"] + BT_FIXED,
           "skipped": []}),
    ]

    # --- E：分批（首批 9 元成交 500 股，第二批未触及） ---
    DE = seq_dates(20260105, 30)
    BE = flat_bars(DE)
    BE[2]["low"] = 8.5                      # 触发第 1 批（目标价 = 首批价 9）
    E_FINAL = 100490.0                      # cash 75490 + 持仓 2500 × 10
    E_TRADES = [
        bt_trade(DE[0], DE[1], None, "buy", 2000, 10.0, 20000.0, 5.0, None, None),
        bt_trade(DE[2], DE[2], "BATCH", "buy", 500, 9.0, 4500.0, 5.0, None, None),
    ]
    cs += [
        C("bt.batch_first_tranche", "backtest_run",
          bt_inp(bt_doc(rules="BATCH(TOTAL=1000, COUNT=2, FIRST=9, GAP=0.5)"),
                 {"7": BE}, hits={"7": [DE[0]]}),
          {"ok": True, "params": BT_PARAMS_ECHO,
           "stats": bt_stats(100000.0, E_FINAL, E_FINAL / 100000.0 - 1,
                             math.pow(1 + (E_FINAL / 100000.0 - 1), 252 / 30.0) - 1,
                             0.0, 0.0, 1 - 99995.0 / 100000.0, 2, 0, 0.0),
           "equity": bt_equity(DE, E_FINAL, {0: 100000.0, 1: 99995.0}),
           "maxDrawdownRange": [0, 1],
           "trades": E_TRADES,
           "scannedCount": 1, "hitCount": 1,
           "warnings": ["期末仍有 1 只标的未平仓，已按最后一个交易日收盘价计入净值"] + BT_FIXED,
           "skipped": []}),
    ]

    # --- F：includeEntry=false（只回测已有持仓上的规则；此处无持仓 → 全空） ---
    DF = seq_dates(20260105, 30)
    cs += [
        C("bt.no_entry", "backtest_run",
          bt_inp(bt_doc(rules="PRICE(OP=>=, VALUE=5)"), {"7": flat_bars(DF)},
                 hits={"7": [DF[0]]},
                 params={"days": 250, "initialCapital": 100000.0,
                         "executeNextOpen": True, "includeEntry": False}),
          {"ok": True,
           "params": {"days": 250, "initialCapital": 100000.0,
                      "executeNextOpen": True, "includeEntry": False},
           "stats": bt_stats(100000.0, 100000.0, 0,
                             math.pow(1.0, 252 / 30.0) - 1, 0, 0, 0, 0, 0, 0),
           "equity": bt_equity(DF, 100000.0), "maxDrawdownRange": None, "trades": [],
           "scannedCount": 1, "hitCount": 1,
           "warnings": BT_FIXED, "skipped": []}),
    ]

    # --- G：executeNextOpen=false（信号当日收盘成交） ---
    DG = seq_dates(20260105, 30)
    cs += [
        C("bt.same_bar_entry_no_drawdown", "backtest_run",
          bt_inp(bt_doc(), {"7": flat_bars(DG)}, hits={"7": [DG[0]]},
                 params={"days": 250, "initialCapital": 100000.0,
                         "executeNextOpen": False, "includeEntry": True}),
          {"ok": True,
           "params": {"days": 250, "initialCapital": 100000.0,
                      "executeNextOpen": False, "includeEntry": True},
           # 当日成交后净值恒为 99995，首点即峰值 → 最大回撤 0、区间 nil
           "stats": bt_stats(100000.0, 99995.0, 99995.0 / 100000.0 - 1,
                             math.pow(1 + (99995.0 / 100000.0 - 1), 252 / 30.0) - 1,
                             0.0, 0.0, 0.0, 1, 0, 0.0),
           "equity": bt_equity(DG, 99995.0),
           "maxDrawdownRange": None,
           "trades": [bt_trade(DG[0], DG[0], None, "buy", 2000, 10.0, 20000.0, 5.0,
                               None, None)],
           "scannedCount": 1, "hitCount": 1,
           "warnings": ["期末仍有 1 只标的未平仓，已按最后一个交易日收盘价计入净值"] + BT_FIXED,
           "skipped": []}),
    ]

    # --- H：bars 入参形状非法 → 显式报错（不静默空结果） ---
    cs += [
        C("bt.bad_bars", "backtest_run",
          {"op": "backtest_run", "doc": {}, "params": {}, "bars": []},
          {"ok": False, "error": "backtest_run 需要 bars（{metaID: [{date,open,high,low,close}...]}）"}),
        C("bt.bad_bar_key", "backtest_run",
          {"op": "backtest_run", "doc": {}, "params": {}, "bars": {"x": []}},
          {"ok": False, "error": "backtest_run 的 bars 键必须是整数 metaID：'x'"}),
    ]

    return cs


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def _run_cases(cs, tol):
    passed = 0
    failures = []
    for c in cs:
        inp = dict(c["input"])
        inp["op"] = c.get("op", inp.get("op"))
        try:
            actual = run_op(inp)
        except Exception as exc:  # noqa: BLE001
            failures.append((c["name"], ["exec 异常: %r" % exc]))
            continue
        errs = _cmp(c["expected"], actual, tol, "$")
        if errs:
            failures.append((c["name"], errs))
        else:
            passed += 1
    return passed, failures


def _report(passed, failures, total):
    for name, errs in failures:
        print("FAIL %s" % name)
        for e in errs:
            print("     %s" % e)
    print("-" * 72)
    print("用例 %d / 通过 %d / 失败 %d" % (total, passed, len(failures)))
    return 0 if not failures else 1


def _flatten_fixture(fixture):
    """把分段落 fixture 摊平成用例列表（兼容旧的扁平 {cases:[...]} 格式）。"""
    cs = []
    for key, value in fixture.items():
        if key.startswith("_") or not isinstance(value, list):
            continue
        for e in value:
            if not isinstance(e, dict) or "input" not in e:
                continue
            op = e.get("op", (e.get("input") or {}).get("op"))
            cs.append({"name": e.get("caseName", e.get("name", op)),
                       "op": op, "input": e["input"], "expected": e.get("expected")})
    return cs


def _verify_trust():
    """套件 8 信任链（PC 侧）：脚本 sha256 / 版本声明 与 fixture + Swift 常量三方一致。"""
    import hashlib
    import re as _re
    raw = open(SCRIPT, "rb").read()
    text = raw.decode("utf-8")
    sha = hashlib.sha256(raw).hexdigest()
    sv = _re.search(r"^SIM_RULES_SCRIPT_VERSION\s*=\s*(\d+)", text, _re.M)
    av = _re.search(r"^SIM_RULES_REQUIRED_API_VERSION\s*=\s*(\d+)", text, _re.M)
    if not sv or not av:
        print("FAIL sim_rules.py 缺版本声明")
        return 1
    want = {"script": "sim_rules", "sha256": sha,
            "scriptVersion": int(sv.group(1)), "requiredApiVersion": int(av.group(1))}

    fix_path = os.path.join(REPO, "KlineTests", "Fixtures", "sim_rules_trust.json")
    if not os.path.exists(fix_path):
        print("FAIL fixture 缺失：%s" % fix_path)
        return 1
    got = json.load(open(fix_path, encoding="utf-8"))
    if got != want:
        print("FAIL fixture 漂移：%s != %s" % (got, want))
        return 1

    swift_path = os.path.join(REPO, "Kline", "Python", "SimRulesTrust.swift")
    swift = open(swift_path, encoding="utf-8").read()
    for name, rx, val in (
            ("expectedScriptSHA256", r'static let expectedScriptSHA256 = "([0-9a-f]{64})"', sha),
            ("scriptVersion", r"static let scriptVersion = (\d+)", want["scriptVersion"]),
            ("requiredAPIVersion", r"static let requiredAPIVersion = (\d+)", want["requiredApiVersion"])):
        m = _re.search(rx, swift)
        if not m or m.group(1) != str(val):
            print("FAIL Swift 常量 %s：磁盘=%r 期望=%r" % (name, m.group(1) if m else None, val))
            return 1

    print("OK 信任链三方一致：sha256=%s scriptVersion=%d requiredApiVersion=%d"
          % (sha, want["scriptVersion"], want["requiredApiVersion"]))
    return 0


def main():
    if "--trust" in sys.argv:
        return _verify_trust()

    if len(sys.argv) >= 3 and sys.argv[1] == "--fixture":
        fixture = json.load(open(sys.argv[2], encoding="utf-8"))
        cs = _flatten_fixture(fixture)
        missing = [c["name"] for c in cs if c["expected"] is None]
        if missing:
            print("fixture 缺 expected（%d 条，是否忘了 dump？）：%s"
                  % (len(missing), ", ".join(missing[:5])))
            return 1
        print("fixture 差分：%s（%d 用例，逐位精确）" % (sys.argv[2], len(cs)))
        passed, failures = _run_cases(cs, FIXTURE_TOL)
        return _report(passed, failures, len(cs))

    cs = cases()
    print("A0 内置用例：%d 条（容差 rel=%g）" % (len(cs), A0_TOL))
    passed, failures = _run_cases(cs, A0_TOL)
    return _report(passed, failures, len(cs))


if __name__ == "__main__":
    sys.exit(main())

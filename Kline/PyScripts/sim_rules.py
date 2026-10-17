# -*- coding: utf-8 -*-
"""sim_rules.py — 交易判定成对下沉（Python 引擎，阶段 A）。

权威语义来源（本脚本为自包含移植，不 import 上述模块）
  - 条件单判定 / 建单校验 / 文案：Kline/Trading/SimCondRule.swift
  - 交易规则（费率 / 涨跌停 / 整手 / T+1 / 时段 / 校验）：Kline/Trading/SimTradingRules.swift
  - 结算纯推进（有效期 / 触发方向 / 委托价 / 档位批次推进 / 预警文案）：
    Kline/Trading/SimCondEngine.swift 的无副作用部分
  - 展示格式化：Kline/Trading/SimFormat.swift
  - 「仅提醒」（isAlertOnly）语义：不下单、不产生委托，数量校验整段放行（见 SimCondRule 头注释）

golden 对拍：KlineTests/Fixtures/sim_rules.json（阶段 A1 由 Swift 现状 dump 生成；
PC 侧差分脚本 scripts/verify_sim_rules.py）。

执行契约（由 Swift 桥接层包装，与 quote_parse.py / period_aggregate.py 一致）
  - 桥接注入模块全局 dict `kline_input`；本脚本产出模块级 dict `kline_result`，
    `kline_result["ok"]` 为 bool；脚本异常由包装统一捕获，输入形状非法时
    直接返回 {"ok": False, "error": ...}。
  - 不使用 IANA 时区名（iOS 沙盒无保证的 tzdata）；时间相关 op 显式接收
    `tzOffsetSeconds`（整数秒偏移）。
  - 日期一律 ISO8601 字符串（与 SimStore 落盘同口径，UTC 带 Z）。

op 一览（阶段 A 已实现 A/B/C/D/E/F 组 + sim_format）
  A 组  cond_evaluate / cond_validate_create / cond_grid_level_count / cond_text
  B 组  cond_expired_reason / cond_fire_direction / cond_execution_price
        / cond_advance / cond_repeatable_finished / cond_alert_message
  C 组  trade_validate / trade_calc
  D 组  strategy_drafts / strategy_entry_draft
  E 组  strategy_parse / strategy_rule_line / strategy_catalog / strategy_validate
        / strategy_preview / trade_parse / trade_serialize / trade_override
  F 组  backtest_run
  通用  sim_format
"""

import math
import re
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_EVEN

# --- 交易规则常量（镜像 SimTradingRules.default） ------------------------------
_LOT_SIZE = 100
_COMMISSION_RATE = 0.00025      # 佣金万 2.5
_COMMISSION_MIN = 5.0           # 最低 5 元
_STAMP_TAX_RATE = 0.001         # 卖出印花税千一
_LIMIT_PCT = 0.10               # 涨跌停 ±10%
_PRICE_TICK = 0.01              # 最小报价档位


def _err(msg):
    return {"ok": False, "error": msg}


# --- 数值与时间工具 -----------------------------------------------------------

def _swift_round(x):
    """Swift 的 round(_:)：half away from zero（Python 内建 round 是 half-even）。"""
    return math.floor(x + 0.5) if x >= 0 else math.ceil(x - 0.5)


def _iso(s):
    """ISO8601 字符串 → datetime（UTC）。容忍尾部 'Z'。"""
    if s is None:
        return None
    t = s.strip()
    if t.endswith("Z"):
        t = t[:-1] + "+00:00"
    dt = datetime.fromisoformat(t)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _local_date(dt, tz_offset_seconds):
    """本地日历日期（等价 Calendar.current.startOfDay 的比较语义）。"""
    off = timezone(timedelta(seconds=int(tz_offset_seconds or 0)))
    return dt.astimezone(off).date()


# --- SimFormat 复刻 ----------------------------------------------------------

def _group(intpart):
    """千分位分组（组 3 位；intpart 为纯数字串，不含符号）。"""
    n = len(intpart)
    out = []
    for i, ch in enumerate(intpart):
        if i > 0 and (n - i) % 3 == 0:
            out.append(",")
        out.append(ch)
    return "".join(out)


def _fixed(v, digits):
    """固定小数位 + 千分位。

    舍入口径 = **对「最短往返十进制表示」做银行家舍入**（NumberFormatter 的实际行为，
    已用 macOS Foundation 探针在 2.5 万个值上实证）：
      - 不能对二进制精确值舍入（Python `format(2.675, ".2f")` → "2.67"，而 Swift → "2.68"）；
      - 也不能按 17 位有效数字（2.675 的 17 位是 2.6749999999999998 → 又是 "2.67"）；
      - 正确做法：`Decimal(repr(v))` 取最短往返十进制（"2.675" / "0.005"）再 ROUND_HALF_EVEN。
    负号保留 Decimal 的符号（-0.0 → "-0.00"，与 NumberFormatter 一致）。
    """
    if v is None:
        return ""
    q = Decimal(repr(float(v))).quantize(Decimal(1).scaleb(-digits), rounding=ROUND_HALF_EVEN)
    s = format(q, "f")
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    ip, _, fp = s.partition(".")
    text = _group(ip)
    if digits > 0:
        text += "." + fp
    return "-" + text if neg else text


def _fmt_amount(v):
    return _fixed(v, 2)


def _fmt_amount0(v):
    return _fixed(v, 0)


def _fmt_price(v):
    return _fixed(v, 2)


def _fmt_shares(v):
    return _fixed(int(v), 0)


def _fmt_signed(v):
    return ("-" if v < 0 else "+") + _fixed(abs(v), 2)


def _fmt_signed0(v):
    return ("-" if v < 0 else "+") + _fixed(abs(v), 0)


def _fmt_pct(v):
    return ("-" if v < 0 else "+") + _fixed(abs(v), 2) + "%"


def _fmt_date(dt, tz_offset_seconds, pattern):
    """pattern ∈ {HH:mm:ss, MM-dd HH:mm, MM-dd}——用 std 库 strftime 拼装。"""
    if dt is None:
        return ""
    off = timezone(timedelta(seconds=int(tz_offset_seconds or 0)))
    d = dt.astimezone(off)
    if pattern == "HH:mm:ss":
        return "%02d:%02d:%02d" % (d.hour, d.minute, d.second)
    if pattern == "MM-dd HH:mm":
        return "%02d-%02d %02d:%02d" % (d.month, d.day, d.hour, d.minute)
    if pattern == "MM-dd":
        return "%02d-%02d" % (d.month, d.day)
    return ""


def _percent_text(v):
    return "%.1f" % v


def _number_text(v):
    return "%g" % v


# --- 模型读取（逐项兜底） -----------------------------------------------------

def _params(order):
    p = order.get("params")
    return p if isinstance(p, dict) else {}


def _directive(order):
    d = order.get("directive")
    if not isinstance(d, dict):
        d = {}
    return {
        "direction": d.get("direction", "sell"),
        "priceType": d.get("priceType", "market"),
        "offsetTicks": int(d.get("offsetTicks", 0) or 0),
        "qty": int(d.get("qty", 0) or 0),
        "alertOnly": bool(d.get("alertOnly", False)),
    }


def _runtime(order):
    r = order.get("runtime")
    if not isinstance(r, dict):
        r = {}
    return {
        "extreme": r.get("extreme"),
        "lastPrice": r.get("lastPrice"),
        "gridLevel": r.get("gridLevel"),
        "gridLastPrice": r.get("gridLastPrice"),
        "batchDone": int(r.get("batchDone", 0) or 0),
        "lastEvaluatedAt": r.get("lastEvaluatedAt"),
        "lastMessage": r.get("lastMessage", "") or "",
        "lastTriggerPrice": r.get("lastTriggerPrice"),
    }


def _rt_out(rt):
    """运行时出参：batchDone 恒在；其余非空才带。"""
    out = {"batchDone": rt.get("batchDone", 0)}
    for k in ("extreme", "lastPrice", "gridLevel", "gridLastPrice",
              "lastEvaluatedAt", "lastTriggerPrice"):
        if rt.get(k) is not None:
            out[k] = rt[k]
    if rt.get("lastMessage"):
        out["lastMessage"] = rt["lastMessage"]
    return out


def _decision_fire(qty, at):
    return {"decision": "fire", "qty": int(qty), "at": at}


def _decision_hold(rt):
    return {"decision": "hold", "runtime": _rt_out(rt)}


def _decision_abort(reason):
    return {"decision": "abort", "reason": reason}


def _decision_complete(reason):
    return {"decision": "complete", "reason": reason}


# --- 拒绝原因（中文文案逐字对齐 Swift） ---------------------------------------

_COND_REJECT_MESSAGE = {
    "accountUnavailable": lambda r: "请先选择有效的模拟账户",
    "noQuote": lambda r: "暂无该标的行情，无法创建条件单",
    "invalidQty": lambda r: "委托数量需为 %d 股的整数倍且大于 0" % r.get("lot", _LOT_SIZE),
    "noPosition": lambda r: "当前账户无可卖持仓，无法创建卖出条件单",
    "missingParam": lambda r: "%s不能为空" % r.get("name", ""),
    "invalidOCORange": lambda r: "止盈价应高于基准价，止损价应低于基准价",
    "invalidGridRange": lambda r: "网格价格区间下界需低于上界",
    "invalidGridStep": lambda r: "网格间距需大于 0",
    "invalidBatchCount": lambda r: "分批笔数需为 2 ~ 5 笔",
    "batchTooSmall": lambda r: "分批总数量不足：每批至少 1 手（%d 股）" % r.get("lot", _LOT_SIZE),
    "invalidFireDate": lambda r: "时间条件需选择未来的触发时间",
}

_ORDER_REJECT_MESSAGE = {
    "emptyAccount": lambda r: "请先选择有效的模拟账户",
    "notLotMultiple": lambda r: "委托数量需为 %d 股的整数倍" % r.get("lot", _LOT_SIZE),
    "insufficientCash": lambda r: "可用资金不足，可买 %d 股（可用 %s）"
                                  % (r.get("affordableQty", 0), _fmt_amount(r.get("available", 0))),
    "insufficientShares": lambda r: "可卖数量不足（T+1：当日买入不可卖）",
    "priceOutOfLimit": lambda r: "委托价超出涨跌停区间 %s ~ %s"
                                 % (_fmt_price(r.get("lower", 0)), _fmt_price(r.get("upper", 0))),
    "noQuote": lambda r: "暂无该标的行情，无法下单",
}


def _reject(table, code, **kw):
    r = {"code": code}
    r.update(kw)
    r["message"] = table[code](r)
    return r


# --- 交易规则（SimTradingRules） ---------------------------------------------

def _commission(amount):
    return max(amount * _COMMISSION_RATE, _COMMISSION_MIN)


def _stamp_tax(amount, direction):
    return amount * _STAMP_TAX_RATE if direction == "sell" else 0.0


def _fee(amount, direction):
    return _commission(amount) + _stamp_tax(amount, direction)


def _limit_range(prev_close):
    if prev_close is None or prev_close <= 0:
        return None
    return (prev_close * (1 - _LIMIT_PCT), prev_close * (1 + _LIMIT_PCT))


def _affordable_qty(cash, price):
    lot = max(_LOT_SIZE, 1)
    if price is None or price <= 0 or cash is None or cash <= 0:
        return 0
    by_rate = cash / (price * (1 + _COMMISSION_RATE))
    by_min = (cash - _COMMISSION_MIN) / price
    raw = int(min(by_rate, by_min))
    if raw <= 0:
        return 0
    return raw // lot * lot


def _sellable_qty(position, t_plus_1=True):
    if position is None:
        return 0
    lot = max(_LOT_SIZE, 1)
    raw = position.get("availableQty", 0) if t_plus_1 else position.get("qty", 0)
    raw = int(raw or 0)
    if raw <= 0:
        return 0
    return raw // lot * lot


def _is_trading_session(dt, tz_offset_seconds):
    off = timezone(timedelta(seconds=int(tz_offset_seconds or 0)))
    d = dt.astimezone(off)
    if d.isoweekday() > 5:      # 1=周一 … 7=周日
        return False
    minutes = d.hour * 60 + d.minute
    return (9 * 60 + 30) <= minutes <= (11 * 60 + 30) or (13 * 60) <= minutes <= (15 * 60)


# --- 条件单判定（SimCondRule.evaluate） --------------------------------------

def _batch_qty(total_qty, count, index):
    lot = max(_LOT_SIZE, 1)
    per_batch = int(total_qty) // int(count) // lot * lot
    if index >= count:
        return max(int(total_qty) - per_batch * (count - 1), 0)
    return max(per_batch, 0)


def _grid_level_count(order):
    p = _params(order)
    base, upper, lower, step = p.get("gridBase"), p.get("gridUpper"), p.get("gridLower"), p.get("gridStepPct")
    if base is None or base <= 0 or upper is None or lower is None or step is None or step <= 0:
        return 1
    unit = math.log(1 + step / 100)
    if unit <= 0:
        return 1
    up = math.log(upper / base) / unit if upper > base else 0
    down = math.log(base / lower) / unit if lower < base else 0
    return max(int(math.floor(up)) + int(math.floor(down)), 1)


def _evaluate(order, snapshot, now):
    p = _params(order)
    d = _directive(order)
    rt = _runtime(order)
    kind = order.get("kind", "price")

    price = snapshot.get("last")
    if price is None or price <= 0:
        return _decision_hold(rt)

    if kind == "price":
        trigger = p.get("triggerPrice")
        if trigger is None or trigger <= 0:
            return _decision_abort("触发价缺失")
        compare_up = p.get("compareUp")
        compare_up = True if compare_up is None else bool(compare_up)
        hit = (price >= trigger) if compare_up else (price <= trigger)
        return _decision_fire(d["qty"], trigger) if hit else _decision_hold(rt)

    if kind == "stopLoss":
        if p.get("takeProfitPrice") is None and p.get("stopLossPrice") is None:
            return _decision_abort("止盈止损参数缺失")
        stop = p.get("stopLossPrice")
        if stop is not None and price <= stop:
            return _decision_fire(d["qty"], stop)
        take = p.get("takeProfitPrice")
        if take is not None and price >= take:
            return _decision_fire(d["qty"], take)
        return _decision_hold(rt)

    if kind == "trailing":
        breakout = p.get("breakoutPrice")
        if breakout is None or breakout <= 0:
            return _decision_abort("突破价缺失")
        if p.get("floorEnabled") and p.get("floorPrice") and p.get("floorPrice") > 0 \
                and price <= p["floorPrice"]:
            return _decision_fire(d["qty"], price)
        if rt["extreme"] is None and price < breakout:
            return _decision_hold(rt)
        extreme = max(rt["extreme"] if rt["extreme"] is not None else price, price)
        rt["extreme"] = extreme
        trail_pct = p.get("trailPct")
        if trail_pct is None or trail_pct <= 0:
            return _decision_hold(rt)
        drawdown = (extreme - price) / extreme * 100 if extreme > 0 else 0
        if drawdown >= trail_pct:
            return _decision_fire(d["qty"], price)
        return _decision_hold(rt)

    if kind == "time":
        fire_date = _iso(p.get("fireDate"))
        if fire_date is None:
            return _decision_abort("触发时间缺失")
        if not (now >= fire_date):
            return _decision_hold(rt)
        at = snapshot.get("last") if snapshot.get("last") is not None else snapshot.get("prevClose")
        if at is None or at <= 0:
            return _decision_hold(rt)
        return _decision_fire(d["qty"], at)

    if kind == "changePct":
        threshold = p.get("changeThreshold")
        if threshold is None or threshold == 0:
            return _decision_abort("涨跌幅阈值缺失")
        pct = snapshot.get("changePct")
        if pct is None:
            return _decision_hold(rt)
        hit = (pct >= threshold) if threshold > 0 else (pct <= threshold)
        return _decision_fire(d["qty"], price) if hit else _decision_hold(rt)

    if kind == "maCross":
        if p.get("maPeriod") is None or p.get("maAbove") is None:
            return _decision_abort("均线参数缺失")
        ma = snapshot.get("ma")
        prev = snapshot.get("prevClose")
        if ma is None or prev is None:
            return _decision_hold(rt)
        above = bool(p.get("maAbove"))
        hit = (prev < ma and price >= ma) if above else (prev > ma and price <= ma)
        return _decision_fire(d["qty"], price) if hit else _decision_hold(rt)

    if kind == "grid":
        lower, upper, step = p.get("gridLower"), p.get("gridUpper"), p.get("gridStepPct")
        if lower is None or upper is None or step is None or step <= 0:
            return _decision_abort("网格参数不完整")
        if not d["alertOnly"]:
            per_level = p.get("gridQtyPerLevel")
            if per_level is None or per_level <= 0:
                return _decision_abort("网格参数不完整")
        if not (lower <= price <= upper):
            return _decision_complete("价格已越出网格区间")
        if rt["gridLevel"] is None:
            rt["gridLevel"] = 0
        if rt["gridLastPrice"] is None:
            rt["gridLastPrice"] = p.get("gridBase") if p.get("gridBase") is not None else price
        base_price = rt["gridLastPrice"]
        if base_price is None or base_price <= 0:
            return _decision_hold(rt)
        drop_pct = (base_price - price) / base_price * 100
        rise_pct = (price - base_price) / base_price * 100
        if not (drop_pct >= step or rise_pct >= step):
            return _decision_hold(rt)
        level = max(rt["gridLevel"] if rt["gridLevel"] is not None else 0, 0)
        multiplier = p.get("gridMultiplier")
        multiplier = 1 if multiplier is None else multiplier
        multiplier = min(max(multiplier, 1), 5)
        factor = multiplier ** min(level, 4)
        qty = int((p.get("gridQtyPerLevel") or 0) * _swift_round(factor))
        return _decision_fire(max(qty, 0), price)

    if kind == "batch":
        count, first, step_pct = p.get("batchCount"), p.get("batchFirstPrice"), p.get("batchStepPct")
        if count is None or count < 2 or first is None or first <= 0 \
                or step_pct is None or step_pct <= 0:
            return _decision_abort("分批参数不完整")
        if not d["alertOnly"]:
            total_qty = p.get("batchTotalQty")
            if total_qty is None or total_qty <= 0:
                return _decision_abort("分批参数不完整")
        done = max(rt["batchDone"], 0)
        index = done + 1
        if index > count:
            return _decision_complete("分批已全部完成")
        is_buy = d["direction"] == "buy"
        offset = step_pct / 100 * (index - 1)
        target = first * (1 - offset) if is_buy else first * (1 + offset)
        reached = (price <= target) if is_buy else (price >= target)
        if not reached:
            return _decision_hold(rt)
        qty = _batch_qty(p.get("batchTotalQty") or 0, count, index)
        return _decision_fire(qty, price)

    return _decision_abort("未知条件类型 %r" % kind)


# --- 建单校验（SimCondRule.validateCreate） -----------------------------------

def _validate_create(order, account, position, snapshot, now):
    p = _params(order)
    d = _directive(order)
    lot = max(_LOT_SIZE, 1)
    kind = order.get("kind", "price")

    if account.get("isArchived") or account.get("id") != order.get("accountID"):
        return _reject(_COND_REJECT_MESSAGE, "accountUnavailable")

    if not d["alertOnly"]:
        if kind == "grid":
            per_level = p.get("gridQtyPerLevel")
            if per_level is None or per_level <= 0 or per_level % lot != 0:
                return _reject(_COND_REJECT_MESSAGE, "invalidQty", lot=lot)
        elif kind == "batch":
            total_qty = p.get("batchTotalQty")
            if total_qty is None or total_qty <= 0 or total_qty % lot != 0:
                return _reject(_COND_REJECT_MESSAGE, "invalidQty", lot=lot)
        else:
            if d["qty"] <= 0 or d["qty"] % lot != 0:
                return _reject(_COND_REJECT_MESSAGE, "invalidQty", lot=lot)

    last = snapshot.get("last")
    if last is None or last <= 0:
        return _reject(_COND_REJECT_MESSAGE, "noQuote")

    if not d["alertOnly"] and d["direction"] == "sell":
        if _sellable_qty(position) <= 0:
            return _reject(_COND_REJECT_MESSAGE, "noPosition")

    if kind == "price":
        trigger = p.get("triggerPrice")
        if trigger is None or trigger <= 0:
            return _reject(_COND_REJECT_MESSAGE, "missingParam", name="触发价")

    elif kind == "stopLoss":
        if p.get("takeProfitPrice") is None and p.get("stopLossPrice") is None:
            return _reject(_COND_REJECT_MESSAGE, "missingParam", name="止盈价或止损价")
        if p.get("baseMode") == "price" and p.get("basePrice") and p.get("basePrice") > 0:
            base = p["basePrice"]
            take, stop = p.get("takeProfitPrice"), p.get("stopLossPrice")
            if take is not None and take <= base:
                return _reject(_COND_REJECT_MESSAGE, "invalidOCORange")
            if stop is not None and stop >= base:
                return _reject(_COND_REJECT_MESSAGE, "invalidOCORange")

    elif kind == "trailing":
        breakout = p.get("breakoutPrice")
        if breakout is None or breakout <= 0:
            return _reject(_COND_REJECT_MESSAGE, "missingParam", name="突破价")
        trail_pct = p.get("trailPct")
        if trail_pct is None or trail_pct <= 0:
            return _reject(_COND_REJECT_MESSAGE, "missingParam", name="回落幅度")
        if p.get("floorEnabled"):
            floor = p.get("floorPrice")
            if floor is None or floor <= 0:
                return _reject(_COND_REJECT_MESSAGE, "missingParam", name="保底价")

    elif kind == "time":
        fire_date = _iso(p.get("fireDate"))
        if fire_date is None:
            return _reject(_COND_REJECT_MESSAGE, "missingParam", name="触发时间")
        if fire_date <= now:
            return _reject(_COND_REJECT_MESSAGE, "invalidFireDate")

    elif kind == "changePct":
        threshold = p.get("changeThreshold")
        if threshold is None or threshold == 0:
            return _reject(_COND_REJECT_MESSAGE, "missingParam", name="涨跌幅阈值")

    elif kind == "maCross":
        period = p.get("maPeriod")
        if period is None or period not in (5, 10, 20, 60):
            return _reject(_COND_REJECT_MESSAGE, "missingParam", name="均线周期")
        if p.get("maAbove") is None:
            return _reject(_COND_REJECT_MESSAGE, "missingParam", name="穿越方向")

    elif kind == "grid":
        base = p.get("gridBase")
        if base is None or base <= 0:
            return _reject(_COND_REJECT_MESSAGE, "missingParam", name="基准价")
        lower, upper = p.get("gridLower"), p.get("gridUpper")
        if lower is None or upper is None:
            return _reject(_COND_REJECT_MESSAGE, "missingParam", name="网格价格区间")
        if upper <= lower:
            return _reject(_COND_REJECT_MESSAGE, "invalidGridRange")
        step = p.get("gridStepPct")
        if step is None or step <= 0:
            return _reject(_COND_REJECT_MESSAGE, "invalidGridStep")

    elif kind == "batch":
        count = p.get("batchCount")
        if count is None or count < 2 or count > 5:
            return _reject(_COND_REJECT_MESSAGE, "invalidBatchCount")
        first = p.get("batchFirstPrice")
        if first is None or first <= 0:
            return _reject(_COND_REJECT_MESSAGE, "missingParam", name="首批价格")
        step_pct = p.get("batchStepPct")
        if step_pct is None or step_pct <= 0:
            return _reject(_COND_REJECT_MESSAGE, "missingParam", name="每批价差")
        if not d["alertOnly"]:
            total_qty = p.get("batchTotalQty") or 0
            if total_qty < count * lot:
                return _reject(_COND_REJECT_MESSAGE, "batchTooSmall", lot=lot)

    if order.get("validity") == "untilDate" and order.get("expiresAt") is None:
        return _reject(_COND_REJECT_MESSAGE, "missingParam", name="有效期到期日")

    return None


# --- 文案（SimCondRule 的摘要族） --------------------------------------------

def _pct_suffix(value, base):
    if base is None or base <= 0:
        return ""
    return "（%s）" % _fmt_pct((value - base) / base * 100)


def _condition_summary(order, tz=0):
    p = _params(order)
    kind = order.get("kind", "price")

    if kind == "price":
        trigger = p.get("triggerPrice")
        if trigger is None:
            return "价格条件待完善"
        symbol = "≥" if (p.get("compareUp") is not False) else "≤"
        return "现价 %s %s" % (symbol, _fmt_price(trigger))

    if kind == "stopLoss":
        parts = []
        take, stop = p.get("takeProfitPrice"), p.get("stopLossPrice")
        if take is not None:
            parts.append("止盈 %s%s" % (_fmt_price(take), _pct_suffix(take, p.get("basePrice"))))
        if stop is not None:
            parts.append("止损 %s%s" % (_fmt_price(stop), _pct_suffix(stop, p.get("basePrice"))))
        return "或 ".join(parts) if parts else "止盈止损待完善"

    if kind == "trailing":
        is_sell = _directive(order)["direction"] == "sell"
        verb = "回落卖出" if is_sell else "反弹买入"
        breakout = p.get("breakoutPrice")
        if breakout is None:
            return verb
        move_word = "回落" if is_sell else "反弹"
        text = "%s · 突破 %s 后%s %s%%" % (verb, _fmt_price(breakout),
                                           move_word, _percent_text(p.get("trailPct") or 0))
        if p.get("floorEnabled") and p.get("floorPrice") is not None:
            text += " · 保底 %s" % _fmt_price(p["floorPrice"])
        return text

    if kind == "time":
        fire_date = _iso(p.get("fireDate"))
        if fire_date is None:
            return "时间条件待完善"
        return "%s 触发" % _fmt_date(fire_date, tz, "MM-dd HH:mm")

    if kind == "changePct":
        threshold = p.get("changeThreshold")
        if threshold is None:
            return "涨跌幅待完善"
        if threshold > 0:
            return "日涨幅 ≥ %s%%" % _percent_text(threshold)
        return "日跌幅 ≥ %s%%" % _percent_text(abs(threshold))

    if kind == "maCross":
        period = p.get("maPeriod") if p.get("maPeriod") is not None else 20
        return "上穿 MA%d" % period if (p.get("maAbove") is not False) else "下破 MA%d" % period

    if kind == "grid":
        lower, upper = p.get("gridLower"), p.get("gridUpper")
        if lower is None or upper is None:
            return "网格交易待完善"
        return "网格交易 · 区间 %s ~ %s · 间距 %s%%" % (
            _fmt_price(lower), _fmt_price(upper), _percent_text(p.get("gridStepPct") or 0))

    if kind == "batch":
        verb = "分批买入" if _directive(order)["direction"] == "buy" else "分批卖出"
        count = p.get("batchCount") or 0
        first = _fmt_price(p["batchFirstPrice"]) if p.get("batchFirstPrice") is not None else "—"
        return "%s %d 批 · 首批 %s · 每批 %s%%" % (verb, count, first,
                                                  _percent_text(p.get("batchStepPct") or 0))
    return ""


def _directive_core(order):
    p = _params(order)
    d = _directive(order)
    price_title = "限价" if d["priceType"] == "limit" else "市价"
    direction_title = "买入" if d["direction"] == "buy" else "卖出"
    if order.get("kind") == "grid":
        per_level = _fmt_shares(p["gridQtyPerLevel"]) if p.get("gridQtyPerLevel") is not None else "0"
        multiplier = _number_text(p.get("gridMultiplier") if p.get("gridMultiplier") is not None else 1)
        return "%s · 每格 %s 股 · 倍数 %s" % (price_title, per_level, multiplier)
    text = "%s%s" % (price_title, direction_title)
    if d["priceType"] == "limit" and d["offsetTicks"] != 0:
        sign = "+" if d["offsetTicks"] > 0 else "-"
        text += "（触发价 %s%d 档）" % (sign, abs(d["offsetTicks"]))
    text += " %s 股" % _fmt_shares(d["qty"])
    return text


def _validity_summary(order, tz=0):
    validity = order.get("validity", "longTerm")
    if validity == "day":
        return "当日有效"
    if validity == "longTerm":
        return "长期有效"
    expires = order.get("expiresAt")
    if expires is None:
        return "指定日期有效"
    return "%s 前有效" % _fmt_date(_iso(expires), tz, "MM-dd")


# --- 有效期（SimCondEngine.expiredReason） -----------------------------------

def _expired_reason(order, now, tz_offset_seconds):
    validity = order.get("validity", "longTerm")
    if validity == "longTerm":
        return None
    today = _local_date(now, tz_offset_seconds)
    if validity == "day":
        created = _iso(order.get("createdAt"))
        if created is not None and _local_date(created, tz_offset_seconds) < today:
            return "当日有效条件单已跨日失效"
        return None
    if validity == "untilDate":
        expires = _iso(order.get("expiresAt"))
        if expires is None:
            return None
        return "已超过指定有效期" if _local_date(expires, tz_offset_seconds) < today else None
    return None


# --- 结算纯推进（SimCondEngine） ---------------------------------------------

def _fire_direction(order, trigger_price):
    if order.get("kind") != "grid":
        return _directive(order)["direction"]
    rt = _runtime(order)
    p = _params(order)
    base = rt["gridLastPrice"] if rt["gridLastPrice"] is not None else p.get("gridBase")
    base = base if base is not None else trigger_price
    return "buy" if trigger_price < base else "sell"


def _execution_price(directive, trigger_price):
    d = directive if isinstance(directive, dict) else {}
    price_type = d.get("priceType", "market")
    if price_type != "limit":
        return None
    offset = int(d.get("offsetTicks", 0) or 0)
    return max(trigger_price + offset * _PRICE_TICK, 0.01)


def _advance_repeatable(order, trigger_price):
    rt = _runtime(order)
    kind = order.get("kind")
    if kind == "grid":
        rt["gridLevel"] = (rt["gridLevel"] if rt["gridLevel"] is not None else 0) + 1
        rt["gridLastPrice"] = trigger_price
    elif kind == "batch":
        rt["batchDone"] = rt["batchDone"] + 1
    return rt


def _repeatable_finished(order):
    rt = _runtime(order)
    kind = order.get("kind")
    if kind == "grid":
        level = rt["gridLevel"] if rt["gridLevel"] is not None else 0
        return level >= _grid_level_count(order)
    if kind == "batch":
        return rt["batchDone"] >= (_params(order).get("batchCount") or 0)
    return False


def _alert_message(order, trigger_price):
    p = _params(order)
    d = _directive(order)
    kind = order.get("kind", "price")
    price_text = _fmt_price(trigger_price)

    if kind == "price":
        target = p.get("triggerPrice")
        if target is None:
            return "预警：现价 %s 触发价格条件" % price_text
        verb = "上穿" if (p.get("compareUp") is not False) else "下破"
        return "预警：现价 %s %s %s" % (price_text, verb, _fmt_price(target))

    if kind == "stopLoss":
        stop = p.get("stopLossPrice")
        if stop is not None and trigger_price <= stop:
            return "预警：现价 %s 下破止损价 %s" % (price_text, _fmt_price(stop))
        take = p.get("takeProfitPrice")
        if take is not None:
            return "预警：现价 %s 上穿止盈价 %s" % (price_text, _fmt_price(take))
        return "预警：现价 %s 触发止盈止损条件" % price_text

    if kind == "trailing":
        if p.get("floorEnabled") and p.get("floorPrice") is not None and trigger_price <= p["floorPrice"]:
            return "预警：现价 %s 跌破保底价 %s" % (price_text, _fmt_price(p["floorPrice"]))
        word = "回落" if d["direction"] == "sell" else "反弹"
        return "预警：现价 %s %s达到 %.1f%%" % (price_text, word, p.get("trailPct") or 0)

    if kind == "time":
        return "预警：现价 %s 到达触发时间" % price_text

    if kind == "changePct":
        threshold = p.get("changeThreshold") or 0
        word = "涨幅" if threshold > 0 else "跌幅"
        return "预警：现价 %s 日%s达到 %.1f%%" % (price_text, word, abs(threshold))

    if kind == "maCross":
        period = p.get("maPeriod") if p.get("maPeriod") is not None else 20
        word = "上穿" if (p.get("maAbove") is not False) else "下破"
        return "预警：现价 %s %s MA%d" % (price_text, word, period)

    if kind == "grid":
        return "预警：现价 %s 触发网格档位" % price_text

    if kind == "batch":
        done = _runtime(order)["batchDone"]
        return "预警：现价 %s 触发分批第 %d 批" % (price_text, done + 1)

    return "预警：现价 %s" % price_text


# --- 交易校验（SimTradingRules.validate） ------------------------------------

def _trade_validate(draft, account, position, last_price, prev_close):
    if account.get("isArchived") or account.get("id") != draft.get("accountID"):
        return _reject(_ORDER_REJECT_MESSAGE, "emptyAccount")

    lot = max(_LOT_SIZE, 1)
    qty = int(draft.get("qty", 0) or 0)
    if qty <= 0 or qty % lot != 0:
        return _reject(_ORDER_REJECT_MESSAGE, "notLotMultiple", lot=lot)

    price_type = draft.get("priceType", "market")
    if price_type == "market":
        if last_price is None or last_price <= 0:
            return _reject(_ORDER_REJECT_MESSAGE, "noQuote")
        price = last_price
    else:
        limit = draft.get("price")
        if limit is None or limit <= 0:
            return _reject(_ORDER_REJECT_MESSAGE, "noQuote")
        price = limit

    if price_type == "limit":
        rng = _limit_range(prev_close)
        if rng is not None and not (rng[0] <= price <= rng[1]):
            return _reject(_ORDER_REJECT_MESSAGE, "priceOutOfLimit", lower=rng[0], upper=rng[1])

    cash = account.get("cash", 0.0) or 0.0
    if draft.get("direction") == "buy":
        amount = price * qty
        total = amount + _fee(amount, "buy")
        if total > cash:
            return _reject(_ORDER_REJECT_MESSAGE, "insufficientCash",
                           available=cash, affordableQty=_affordable_qty(cash, price))
    else:
        sellable = _sellable_qty(position)
        if qty > sellable:
            return _reject(_ORDER_REJECT_MESSAGE, "insufficientShares", available=sellable)

    return None


# --- op 分发 ------------------------------------------------------------------

def _op_sim_format(inp):
    fn = inp.get("fn")
    tz = inp.get("tzOffsetSeconds", 0)
    if fn in ("amount", "amount0", "signed", "signed0", "pct", "price", "shares", "percent1", "numberg"):
        v = inp.get("value")
        table = {
            "amount": _fmt_amount, "amount0": _fmt_amount0, "signed": _fmt_signed,
            "signed0": _fmt_signed0, "pct": _fmt_pct, "price": _fmt_price,
            "shares": _fmt_shares, "percent1": _percent_text, "numberg": _number_text,
        }
        return {"value": table[fn](v)}
    if fn in ("time", "dateTime", "shortDate"):
        pattern = {"time": "HH:mm:ss", "dateTime": "MM-dd HH:mm", "shortDate": "MM-dd"}[fn]
        return {"value": _fmt_date(_iso(inp.get("date")), tz, pattern)}
    return _err("sim_format 未知 fn: %r" % fn)


def _op_cond_evaluate(inp):
    order = inp.get("order") or {}
    snapshot = inp.get("snapshot") or {}
    now = _iso(inp.get("now")) or datetime.now(timezone.utc)
    return {"result": _evaluate(order, snapshot, now)}


def _op_cond_validate_create(inp):
    order = inp.get("order") or {}
    now = _iso(inp.get("now")) or datetime.now(timezone.utc)
    rej = _validate_create(order, inp.get("account") or {}, inp.get("position"),
                           inp.get("snapshot") or {}, now)
    return {"result": rej}


def _op_cond_grid_level_count(inp):
    return {"count": _grid_level_count(inp.get("order") or {})}


def _op_cond_text(inp):
    tz = int(inp.get("tzOffsetSeconds", 0) or 0)
    order = inp.get("order") or {}
    field = inp.get("field", "condition")
    if field == "condition":
        text = _condition_summary(order, tz)
    elif field == "directiveCore":
        text = _directive_core(order)
    elif field == "directive":
        text = "触发后 " + _directive_core(order)
    elif field == "validity":
        text = _validity_summary(order, tz)
    elif field == "preview":
        text = "当 %s %s 时，以 %s，%s" % (order.get("name", ""), _condition_summary(order, tz),
                                          _directive_core(order), _validity_summary(order, tz))
    else:
        return _err("cond_text 未知 field: %r" % field)
    return {"text": text}


def _op_cond_expired_reason(inp):
    order = inp.get("order") or {}
    now = _iso(inp.get("now")) or datetime.now(timezone.utc)
    return {"reason": _expired_reason(order, now, inp.get("tzOffsetSeconds", 0))}


def _op_cond_fire_direction(inp):
    return {"direction": _fire_direction(inp.get("order") or {}, inp.get("triggerPrice"))}


def _op_cond_execution_price(inp):
    return {"price": _execution_price(inp.get("directive") or {}, inp.get("triggerPrice"))}


def _op_cond_advance(inp):
    rt = _advance_repeatable(inp.get("order") or {}, inp.get("triggerPrice"))
    return {"runtime": _rt_out(rt)}


def _op_cond_repeatable_finished(inp):
    return {"finished": _repeatable_finished(inp.get("order") or {})}


def _op_cond_alert_message(inp):
    return {"message": _alert_message(inp.get("order") or {}, inp.get("triggerPrice"))}


def _op_trade_calc(inp):
    calc = inp.get("calc")
    if calc == "commission":
        return {"value": _commission(inp.get("amount"))}
    if calc == "stampTax":
        return {"value": _stamp_tax(inp.get("amount"), inp.get("direction"))}
    if calc == "fee":
        return {"value": _fee(inp.get("amount"), inp.get("direction"))}
    if calc == "limitRange":
        rng = _limit_range(inp.get("prevClose"))
        return {"range": None if rng is None else {"lower": rng[0], "upper": rng[1]}}
    if calc == "affordableQty":
        return {"value": _affordable_qty(inp.get("cash"), inp.get("price"))}
    if calc == "sellableQty":
        return {"value": _sellable_qty(inp.get("position"),
                                       bool(inp.get("tPlus1Enabled", True)))}
    if calc == "isTradingSession":
        dt = _iso(inp.get("at")) or datetime.now(timezone.utc)
        return {"value": _is_trading_session(dt, inp.get("tzOffsetSeconds", 0))}
    return _err("trade_calc 未知 calc: %r" % calc)


def _op_trade_validate(inp):
    rej = _trade_validate(inp.get("draft") or {}, inp.get("account") or {},
                          inp.get("position"), inp.get("lastPrice"), inp.get("prevClose"))
    return {"result": rej}


# =============================================================================
# 以下 E 组（策略 DSL）+ D 组（策略 → 条件单映射）
#   权威语义来源：Kline/Formula/StrategyFormula.swift（规则目录 / RULES 解析 / 校验 / 预览）
#                 Kline/Formula/StrategyTrade.swift（TRADE 段 / ORD* 覆盖键）
#                 Kline/Trading/StrategyCondGenerator.swift（drafts / entryDraft 纯映射）
#   全部为纯函数；不读全局、不落盘、不引用 SimStore。
# =============================================================================

# --- Swift 字符串 → 数值（严格对齐 Double(_:) / Int(_:)） ---------------------

# 实测边界（macOS Foundation 探针，见可行性分析 §11.9）：
#   Double：拒绝首尾空白（含 \t\n）、拒绝下划线；**接受十六进制**（"0x10"→16、"0x1p3"→8）；
#           接受 ".5" / "5." / "+.5" / "1e3" / "1E+3"；接受 nan/inf/infinity（大小写不限）；
#           溢出（"1e400"）→ inf 而非 nil。
#   Int   ：拒绝空白 / 下划线 / 十六进制 / 小数 / 指数；容忍前导 0（"007"→7）；64 位溢出 → nil。
# 注意：Python 的 float()/int() 都更宽松（" 1"、"1_0"、"٣"、"１２" 均会成功），必须先过正则闸门；
# 且 Python 的 \d 会吃 Unicode 数字，故一律写 [0-9]。
_DOUBLE_RE = re.compile(r'[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\Z')
_DOUBLE_HEX_RE = re.compile(
    r'[+-]?0[xX](?:[0-9a-fA-F]+\.?[0-9a-fA-F]*|\.[0-9a-fA-F]+)(?:[pP][+-]?[0-9]+)?\Z')
_INT_RE = re.compile(r'[+-]?[0-9]+\Z')

_DOUBLE_SPECIAL = {
    "inf": float("inf"), "+inf": float("inf"), "infinity": float("inf"),
    "+infinity": float("inf"),
    "-inf": float("-inf"), "-infinity": float("-inf"),
    "nan": float("nan"), "+nan": float("nan"), "-nan": float("nan"),
}


def _swift_double(s):
    """Swift Double(_:) 的等价解析（不合法返回 None）。"""
    if not isinstance(s, str) or s == "":
        return None
    if s != s.strip():          # Swift 拒绝首尾空白
        return None
    special = _DOUBLE_SPECIAL.get(s.lower())
    if special is not None:
        return special
    if _DOUBLE_RE.match(s):
        try:
            return float(s)
        except (ValueError, OverflowError):
            return None
    if _DOUBLE_HEX_RE.match(s):
        try:
            return float.fromhex(s)
        except (ValueError, OverflowError):
            return None
    return None


def _swift_int(s):
    """Swift Int(_:) 的等价解析（不合法 / 越界返回 None）。"""
    if not isinstance(s, str) or not _INT_RE.match(s):
        return None
    v = int(s)
    if not (-2 ** 63 <= v <= 2 ** 63 - 1):
        return None
    return v


# --- 规则目录（StrategyRuleCatalog） -----------------------------------------

_RULE_KINDS = ("PRICE", "STOP_LOSS", "TRAILING", "TIME", "CHANGE_PCT", "MA_CROSS", "GRID", "BATCH")

# StrategyRuleKind.title（校验 / 跳过原因里用）
_RULE_TITLE = {
    "PRICE": "价格条件", "STOP_LOSS": "止盈止损", "TRAILING": "回落卖出", "TIME": "时间条件",
    "CHANGE_PCT": "涨跌幅", "MA_CROSS": "均线条件", "GRID": "网格交易", "BATCH": "分批建仓",
}

# StrategyRuleKind.conditionOrderTitle（预览用）
_RULE_COND_TITLE = {
    "PRICE": "价格条件", "STOP_LOSS": "止盈止损（OCO）", "TRAILING": "回落卖出 / 反弹买入",
    "TIME": "时间条件", "CHANGE_PCT": "涨跌幅条件", "MA_CROSS": "均线条件",
    "GRID": "网格交易", "BATCH": "分批建仓 / 分批卖出",
}

# StrategyRuleKind → SimCondKind.rawValue
_SIM_KIND = {
    "PRICE": "price", "STOP_LOSS": "stopLoss", "TRAILING": "trailing", "TIME": "time",
    "CHANGE_PCT": "changePct", "MA_CROSS": "maCross", "GRID": "grid", "BATCH": "batch",
}


def _spec(key, title, type_, optional, placeholder, options=(), unit=""):
    return {"key": key, "title": title, "type": type_, "isOptional": optional,
            "placeholder": placeholder, "options": list(options), "unit": unit}


# 顺序即序列化顺序（StrategyRuleCatalog.specs）
_SPECS = {
    "PRICE": [
        _spec("OP", "比较方向", "option", False, ">=", [">=", "<="]),
        _spec("VALUE", "触发价", "number", False, "1480.00", unit="元"),
    ],
    "STOP_LOSS": [
        _spec("BASE", "基准", "option", True, "COST", ["COST", "LAST"]),
        _spec("MODE", "基准方式", "option", True, "PCT", ["PCT", "PRICE"]),
        _spec("PROFIT", "止盈", "percent", True, "10", unit="%"),
        _spec("LOSS", "止损", "percent", True, "5", unit="%"),
    ],
    "TRAILING": [
        _spec("PCT", "回落幅度", "percent", False, "3", unit="%"),
        _spec("FLOOR", "保底价", "number", True, "12.00", unit="元"),
    ],
    "TIME": [
        _spec("DATE", "日期", "text", False, "2026-10-01"),
        _spec("AT", "时刻", "text", True, "09:30"),
    ],
    "CHANGE_PCT": [
        _spec("PCT", "涨跌幅", "percent", False, "5", unit="%"),
        _spec("OP", "比较方向", "option", True, ">=", [">=", "<="]),
    ],
    "MA_CROSS": [
        _spec("PERIOD", "周期", "option", False, "20", ["5", "10", "20", "60"], unit="日"),
        _spec("DIR", "方向", "option", False, "UP", ["UP", "DOWN"]),
    ],
    "GRID": [
        _spec("BASE", "基准价", "number", False, "14.60", unit="元"),
        _spec("LOW", "区间下界", "number", False, "13.50", unit="元"),
        _spec("HIGH", "区间上界", "number", False, "15.80", unit="元"),
        _spec("STEP", "间距", "percent", False, "1.5", unit="%"),
        _spec("QTY", "每格股数", "integer", False, "300", unit="股"),
        _spec("MULT", "倍数", "number", True, "2", unit="倍"),
    ],
    "BATCH": [
        _spec("TOTAL", "总数量", "integer", False, "3000", unit="股"),
        _spec("COUNT", "批数", "integer", False, "3", unit="批"),
        _spec("FIRST", "首批价", "number", False, "14.90", unit="元"),
        _spec("GAP", "每批价差", "number", False, "0.30", unit="元"),
    ],
}
_KNOWN_KEY_SET = {k: set(s["key"] for s in v) for k, v in _SPECS.items()}


# --- TRADE 段 / ORD* 覆盖键 ---------------------------------------------------

_TRADE_RESERVED_KEYS = ["ORDDIR", "ORDQTY", "ORDAMT", "ORDPT", "ORDOFF"]
_RESERVED_KEY_SET = set(_TRADE_RESERVED_KEYS)

_DIR_TITLE = {"buy": "买入", "sell": "卖出"}
_PT_TITLE = {"limit": "限价", "market": "市价"}

# Swift 的 .newlines 集合（不含 Python splitlines 额外的 \x1c-\x1e）
_NEWLINE_RE = re.compile(r'\r\n|\r|\n|\v|\f|\x85|\u2028|\u2029')

_NORMALIZE_RULE = (("（", "("), ("）", ")"), ("，", ","), ("＝", "="), ("－", "-"), ("：", ":"))
_NORMALIZE_TRADE = (("＝", "="), ("，", ","), ("：", ":"))


def _normalize(s, pairs):
    for a, b in pairs:
        s = s.replace(a, b)
    return s


# --- 取值助手（逐项对齐 Swift 的 value / doubleValue / intValue） --------------

def _pget(params, key):
    """取参数的非空原文（不做 trim，与 Swift 的 value(_:_:) 一致）。"""
    v = params.get(key) if isinstance(params, dict) else None
    return v if isinstance(v, str) and v != "" else None


def _pnum(params, key):
    raw = _pget(params, key)
    return None if raw is None else _swift_double(raw)


def _pint(params, key):
    raw = _pget(params, key)
    return None if raw is None else _swift_int(raw)


def _upper(s):
    return s.upper() if isinstance(s, str) else None


# --- 枚举文本解析 -------------------------------------------------------------

def _direction(v):
    if not isinstance(v, str):
        return None
    t = v.strip().lower()
    return t if t in ("buy", "sell") else None


def _price_type(v):
    if not isinstance(v, str):
        return None
    t = v.strip().lower()
    return t if t in ("limit", "market") else None


def _validity_token(v):
    if not isinstance(v, str):
        return None
    t = v.strip().upper()
    if t == "DAY":
        return "day"
    if t in ("LONG", "LONGTERM"):
        return "longTerm"
    if t in ("DATE", "UNTILDATE"):
        return "untilDate"
    return None


def _validity_text(v):
    return {"day": "DAY", "longTerm": "LONG", "untilDate": "DATE"}.get(v, "")


_UUID_RE = re.compile(
    r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z')


def _uuid(s):
    """UUID(uuidString:) 的等价解析（严格 8-4-4-4-12，无花括号 / 无紧凑形式；输出大写）。"""
    return s.upper() if isinstance(s, str) and _UUID_RE.match(s) else None


# --- 日期（DateFormatter "yyyy-MM-dd" / Calendar 拼装） -----------------------

def _tz(tz_offset_seconds):
    return timezone(timedelta(seconds=int(tz_offset_seconds or 0)))


def _localize(naive, tz_offset_seconds):
    """本地壁钟 → UTC 瞬时（固定偏移；A 股无夏令时）。"""
    return naive.replace(tzinfo=_tz(tz_offset_seconds)).astimezone(timezone.utc)


def _to_iso(dt):
    """ISO8601（JSONEncoder .iso8601 口径：秒精度 + Z）。"""
    if dt is None:
        return None
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# DateFormatter(locale=en_US_POSIX, tz=本地, "yyyy-MM-dd", isLenient=false) 的实测行为：
#   接受前导 / 尾随空白；月日不补零（"2026-1-5"）；**分隔符容忍 - / . 与两侧空格**（"2026.10.01"、
#   "2026 - 10 - 01"）；日可 3 位（"2026-10-001"）；年按原样用（"26-10-01" → 年 26，不补世纪）；
#   拒绝非法月 / 日（"2026-13-01" / "2026-02-30" / "2026-10-32" / 月 0 / 日 0）、拒绝 "20261001"、
#   拒绝带时间的 "2026-10-01T00:00"。
# ICU 完整语法未复刻；边界集由 A1 dump 固定。
# ⚠️ 1901 年以前 Swift 用 Asia/Shanghai 的 LMT 偏移（+08:05:43），本实现只支持注入的固定偏移。
_DATE8_RE = re.compile(
    r'\s*([0-9]{1,4})\s*[-/.]\s*([0-9]{1,2})\s*[-/.]\s*([0-9]{1,3})\s*\Z')


def _date_from_text(text, tz_offset_seconds):
    if not isinstance(text, str):
        return None
    t = text.strip()
    if t == "":
        return None
    m = _DATE8_RE.match(t)
    if m is None:
        return None
    try:
        naive = datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError:
        return None
    return _localize(naive, tz_offset_seconds)


def _date_text(dt, tz_offset_seconds):
    d = dt.astimezone(_tz(tz_offset_seconds))
    return "%04d-%02d-%02d" % (d.year, d.month, d.day)


# Calendar(identifier:.gregorian, tz=本地).date(from:) 的实测行为：**越界一律归一化**，不返回 nil：
#   月 13 → 次年 1 月；月 0 → 上年 12 月；日 32 → 下月 1 日；日 0 → 上月最后一天；
#   时 25 → 次日 01:00；分 75 → +1h15m。非法（非数字 / 字段数不足）才 nil。
# 未复刻：年 < 1（Swift 得到 era/LMT 混合怪值）、归一化后年 > 9999（Python datetime 上限）。
def _fire_date(date_text, at_text, tz_offset_seconds):
    date_parts = (date_text.strip() if isinstance(date_text, str) else "").split("-")
    if len(date_parts) != 3:
        return None
    year, month, day = (_swift_int(x) for x in date_parts)
    if year is None or month is None or day is None:
        return None
    time_parts = (at_text.strip() if isinstance(at_text, str) else "").split(":")
    if len(time_parts) != 2:
        return None
    hour, minute = (_swift_int(x) for x in time_parts)
    if hour is None or minute is None:
        return None
    if not (1 <= year <= 9999):
        return None
    total_months = (month - 1)
    year2 = year + total_months // 12
    month2 = total_months % 12 + 1
    if not (1 <= year2 <= 9999):
        return None
    try:
        naive = datetime(year2, month2, 1) + timedelta(days=day - 1, hours=hour, minutes=minute)
    except (ValueError, OverflowError):
        return None
    try:
        return _localize(naive, tz_offset_seconds)
    except (ValueError, OverflowError):
        return None


# --- RULES 段解析（StrategyRuleParser.parse / line） -------------------------

def _rules_parse(lines_text):
    rules = []
    errors = []
    text = lines_text if isinstance(lines_text, str) else ""
    for idx, raw in enumerate(_NEWLINE_RE.split(text)):
        n = idx + 1
        trimmed = raw.strip()
        if trimmed == "" or trimmed.startswith("{"):
            continue
        normalized = _normalize(trimmed, _NORMALIZE_RULE)
        open_i = normalized.find("(")
        if open_i < 0:
            errors.append("第 %d 行：规则格式应为 KEYWORD(KEY=VAL, ...)" % n)
            continue
        if not normalized.endswith(")"):
            errors.append("第 %d 行：括号不闭合" % n)
            continue
        keyword_raw = normalized[:open_i].strip()
        keyword = keyword_raw.upper()
        if keyword not in _SPECS:
            errors.append("第 %d 行：未知规则 %s" % (n, keyword_raw if keyword_raw else trimmed))
            continue
        inner = normalized[open_i + 1:len(normalized) - 1]
        params = {}
        known = _KNOWN_KEY_SET[keyword]
        for token in inner.split(","):
            t = token.strip()
            if t == "":
                continue
            eq = t.find("=")
            if eq < 0:
                errors.append("第 %d 行：参数格式应为 KEY=VAL（%s）" % (n, t))
                continue
            key = t[:eq].strip().upper()
            val = t[eq + 1:].replace(" ", "").strip()
            if key == "":
                errors.append("第 %d 行：参数格式应为 KEY=VAL（%s）" % (n, t))
                continue
            if key not in known and key not in _RESERVED_KEY_SET:
                errors.append("第 %d 行：%s 未识别参数 %s" % (n, _RULE_TITLE[keyword], key))
                continue
            params[key] = val
        rules.append({"kind": keyword, "params": params, "raw": trimmed, "line": n})
    return rules, errors


def _rule_line(call):
    kind = call.get("kind")
    params = call.get("params") if isinstance(call.get("params"), dict) else {}
    parts = []
    for spec in _SPECS.get(kind, []):
        v = params.get(spec["key"])
        if isinstance(v, str) and v != "":
            parts.append("%s=%s" % (spec["key"], v))
    for key in _TRADE_RESERVED_KEYS:
        v = params.get(key)
        if isinstance(v, str) and v != "":
            parts.append("%s=%s" % (key, v))
    return "%s(%s)" % (kind, ", ".join(parts))


# --- TRADE 段解析 / 序列化 / 覆盖（StrategyTradeParser） ----------------------

def _empty_spec():
    return {"direction": None, "qty": None, "amount": None, "priceType": None,
            "offsetTicks": None, "validity": None, "expiresAt": None, "accountIDs": []}


def _spec_is_empty(spec):
    return (spec.get("direction") is None and spec.get("qty") is None
            and spec.get("amount") is None and spec.get("priceType") is None
            and spec.get("offsetTicks") is None and spec.get("validity") is None
            and spec.get("expiresAt") is None and not (spec.get("accountIDs") or []))


def _spec_to_json(spec):
    return {
        "direction": spec.get("direction"),
        "qty": spec.get("qty"),
        "amount": spec.get("amount"),
        "priceType": spec.get("priceType"),
        "offsetTicks": spec.get("offsetTicks"),
        "validity": spec.get("validity"),
        "expiresAt": _to_iso(spec.get("expiresAt")),
        "accountIDs": list(spec.get("accountIDs") or []),
    }


def _spec_from_json(obj):
    """入参 JSON（键名同 Swift 属性名）→ 内部 spec。"""
    spec = _empty_spec()
    if not isinstance(obj, dict):
        return spec
    d = obj.get("direction")
    spec["direction"] = d if d in ("buy", "sell") else None
    for key in ("qty", "offsetTicks"):
        v = obj.get(key)
        spec[key] = v if isinstance(v, int) and not isinstance(v, bool) else None
    a = obj.get("amount")
    spec["amount"] = float(a) if isinstance(a, (int, float)) and not isinstance(a, bool) else None
    pt = obj.get("priceType")
    spec["priceType"] = pt if pt in ("limit", "market") else None
    v = obj.get("validity")
    spec["validity"] = v if v in ("day", "untilDate", "longTerm") else None
    spec["expiresAt"] = _iso(obj.get("expiresAt")) if isinstance(obj.get("expiresAt"), str) else None
    accs = obj.get("accountIDs")
    spec["accountIDs"] = [str(x) for x in accs] if isinstance(accs, list) else []
    return spec


def _trade_lines(lines):
    if isinstance(lines, str):
        return _NEWLINE_RE.split(lines)
    if isinstance(lines, list):
        return [x if isinstance(x, str) else "" for x in lines]
    return []


def _trade_parse(lines, tz_offset_seconds):
    spec = _empty_spec()
    errors = []
    for raw in _trade_lines(lines):
        trimmed = raw.strip()
        if trimmed == "" or trimmed.startswith("{"):
            continue
        normalized = _normalize(trimmed, _NORMALIZE_TRADE)
        eq = normalized.find("=")
        if eq < 0:
            errors.append("TRADE 段格式应为 KEY=VALUE（%s）" % trimmed)
            continue
        key = normalized[:eq].strip().upper()
        val = normalized[eq + 1:].replace(" ", "").strip()
        if key == "DIRECTION":
            d = _direction(val)
            if d is None:
                errors.append("DIRECTION 只能是 BUY 或 SELL")
            else:
                spec["direction"] = d
        elif key == "QTY":
            n = _swift_int(val)
            if n is None:
                errors.append("QTY 需要填整数")
            else:
                spec["qty"] = n
        elif key == "AMOUNT":
            v = _swift_double(val)
            if v is None:
                errors.append("AMOUNT 需要填数字")
            else:
                spec["amount"] = v
        elif key == "PRICETYPE":
            pt = _price_type(val)
            if pt is None:
                errors.append("PRICETYPE 只能是 MARKET 或 LIMIT")
            else:
                spec["priceType"] = pt
        elif key == "OFFSETTICKS":
            n = _swift_int(val)
            if n is None:
                errors.append("OFFSETTICKS 需要填整数")
            else:
                spec["offsetTicks"] = n
        elif key == "VALIDITY":
            v = _validity_token(val)
            if v is None:
                errors.append("VALIDITY 只能是 DAY / LONG / DATE")
            else:
                spec["validity"] = v
        elif key == "EXPIRES":
            d = _date_from_text(val, tz_offset_seconds)
            if d is None:
                errors.append("EXPIRES 日期格式应为 YYYY-MM-DD")
            else:
                spec["expiresAt"] = d
        elif key == "ACCOUNTS":
            for token in val.split(","):
                if token == "":
                    continue
                u = _uuid(token)
                if u is None:
                    errors.append("ACCOUNTS 含非法账户 id：%s" % token)
                else:
                    spec["accountIDs"].append(u)
        else:
            errors.append("TRADE 段未识别键 %s" % key)
    return spec, errors


def _amount_text(v):
    return "%.0f" % v if v == _swift_round(v) else repr(float(v))


def _serialize_trade(spec, tz_offset_seconds):
    lines = []
    if spec.get("direction") is not None:
        lines.append("DIRECTION=%s" % spec["direction"].upper())
    if spec.get("qty") is not None:
        lines.append("QTY=%d" % spec["qty"])
    if spec.get("amount") is not None:
        lines.append("AMOUNT=%s" % _amount_text(spec["amount"]))
    if spec.get("priceType") is not None:
        lines.append("PRICETYPE=%s" % spec["priceType"].upper())
    if spec.get("offsetTicks") is not None:
        lines.append("OFFSETTICKS=%d" % spec["offsetTicks"])
    if spec.get("validity") is not None:
        lines.append("VALIDITY=%s" % _validity_text(spec["validity"]))
    if spec.get("expiresAt") is not None:
        lines.append("EXPIRES=%s" % _date_text(spec["expiresAt"], tz_offset_seconds))
    accs = spec.get("accountIDs") or []
    if accs:
        lines.append("ACCOUNTS=" + ",".join(accs))
    return "\n".join(lines)


def _override_dict(params):
    """规则行内 ORD* 覆盖（StrategyTradeParser.override）。"""
    d = _pget(params, "ORDDIR")
    q = _pget(params, "ORDQTY")
    a = _pget(params, "ORDAMT")
    pt = _pget(params, "ORDPT")
    off = _pget(params, "ORDOFF")
    return {
        "dir": _direction(d) if d is not None else None,
        "qty": _swift_int(q) if q is not None else None,
        "amount": _swift_double(a) if a is not None else None,
        "priceType": _price_type(pt) if pt is not None else None,
        "offsetTicks": _swift_int(off) if off is not None else None,
    }


def _override_is_empty(o):
    return all(o.get(k) is None for k in ("dir", "qty", "amount", "priceType", "offsetTicks"))


def _offset_text(n):
    return "+%d 档" % n if n >= 0 else "%d 档" % n


def _override_summary(o):
    if _override_is_empty(o):
        return None
    parts = []
    if o["qty"] is not None:
        qty_or_amount = "%d 股" % o["qty"]
    elif o["amount"] is not None:
        qty_or_amount = "%s 元" % _amount_text(o["amount"])
    else:
        qty_or_amount = None
    if o["dir"] is not None:
        parts.append("%s %s" % (_DIR_TITLE[o["dir"]], qty_or_amount) if qty_or_amount
                     else _DIR_TITLE[o["dir"]])
    elif qty_or_amount:
        parts.append(qty_or_amount)
    if o["priceType"] is not None:
        if o["priceType"] == "limit" and o["offsetTicks"] is not None:
            parts.append("限价 %s" % _offset_text(o["offsetTicks"]))
        else:
            parts.append("%s委托" % _PT_TITLE[o["priceType"]])
    elif o["offsetTicks"] is not None:
        parts.append(_offset_text(o["offsetTicks"]))
    return " ".join(parts) if parts else None


# --- 策略校验（StrategyValidator.validate） -----------------------------------

def _validate_strategy(doc, picker_exists, pick_syntax_error):
    errors = []
    body = (doc.get("pickBody") or "").strip() if isinstance(doc.get("pickBody"), str) else ""
    ref = (doc.get("pickRef") or "").strip() if isinstance(doc.get("pickRef"), str) else ""
    has_body = body != ""
    has_ref = ref != ""

    if not has_body and not has_ref:
        errors.append("策略需要选股条件：请填写内嵌选股公式，或引用一个选股公式")
    if has_body and has_ref:
        errors.append("PICKREF 与内嵌选股条件只能二选一，请保留其一")
    if has_ref and not picker_exists:
        errors.append("引用的选股公式已不存在，请重新选择或改用内嵌选股条件")
    if pick_syntax_error is not None:
        errors.append("内嵌选股公式语法错误：%s" % pick_syntax_error)

    rules_raw = doc.get("rules") if isinstance(doc.get("rules"), str) else ""
    if rules_raw.strip() == "":
        errors.append("策略至少需要一条交易规则")

    calls, parse_errors = _rules_parse(rules_raw)
    errors.extend(parse_errors)

    for i, c in enumerate(calls):
        if any(calls[j]["kind"] == c["kind"] for j in range(i)):
            errors.append("第 %d 行：%s 规则重复声明，请保留其一" % (c["line"], _RULE_TITLE[c["kind"]]))

    for c in calls:
        params = c["params"]
        specs = _SPECS[c["kind"]]
        for spec in specs:
            if spec["isOptional"]:
                continue
            v = params.get(spec["key"])
            v = v.strip() if isinstance(v, str) else ""
            if v == "":
                errors.append("第 %d 行：%s 缺少参数 %s"
                              % (c["line"], _RULE_TITLE[c["kind"]], spec["key"]))
        for spec in specs:
            raw = params.get(spec["key"])
            if not isinstance(raw, str) or raw == "":
                continue
            if spec["type"] in ("number", "percent"):
                if _swift_double(raw) is None:
                    errors.append("%s 需要填数字" % spec["title"])
            elif spec["type"] == "integer":
                if _swift_int(raw) is None:
                    errors.append("%s 需要填数字" % spec["title"])
        kind = c["kind"]
        if kind == "STOP_LOSS":
            profit = _pnum(params, "PROFIT")
            loss = _pnum(params, "LOSS")
            if profit is None and loss is None:
                errors.append("止盈止损至少需要设置止盈或止损之一")
            if profit is not None and profit <= 0:
                errors.append("止盈 / 止损值需大于 0")
            if loss is not None and loss <= 0:
                errors.append("止盈 / 止损值需大于 0")
        elif kind in ("TRAILING", "CHANGE_PCT"):
            v = _pnum(params, "PCT")
            if v is not None and v <= 0:
                errors.append("幅度需大于 0")
        elif kind == "MA_CROSS":
            raw = params.get("PERIOD")
            if isinstance(raw, str) and raw != "":
                period = _swift_int(raw)
                if period is None or period not in (5, 10, 20, 60):
                    errors.append("均线周期只支持 5 / 10 / 20 / 60")
        elif kind == "GRID":
            low = _pnum(params, "LOW")
            high = _pnum(params, "HIGH")
            if low is not None and high is not None and low >= high:
                errors.append("网格价格区间下界不得高于上界")
            step = _pnum(params, "STEP")
            if step is not None and step <= 0:
                errors.append("网格间距需大于 0")
            mult = _pnum(params, "MULT")
            if mult is not None and (mult < 1 or mult > 5):
                errors.append("倍数委托需在 1~5 之间")
        elif kind == "BATCH":
            n = _pint(params, "COUNT")
            if n is not None and (n < 2 or n > 5):
                errors.append("分批笔数需在 2~5 之间")

    has_grid = any(c["kind"] == "GRID" for c in calls)
    has_batch = any(c["kind"] == "BATCH" for c in calls)
    if has_grid and has_batch:
        errors.append("网格交易与分批建仓不宜同一策略并存，请保留其一")

    if doc.get("kind") == "STRATEGY":
        trade = _spec_from_json(doc.get("trade"))
        if not _spec_is_empty(trade):
            if trade["direction"] is None:
                errors.append("请选择交易方向")
            if trade["qty"] is not None and trade["amount"] is not None:
                errors.append("交易指令的数量与金额只能二选一")
            if trade["qty"] is not None and trade["qty"] % 100 != 0:
                errors.append("交易指令数量需为 100 股的整数倍")
            if trade["amount"] is not None and trade["amount"] <= 0:
                errors.append("交易指令金额需大于 0")
            if trade["priceType"] == "limit" and trade["offsetTicks"] is None:
                errors.append("限价委托需设置偏移档次（OFFSETTICKS）")
            if trade["validity"] == "untilDate" and trade["expiresAt"] is None:
                errors.append("指定日期有效期需设置到期日（EXPIRES）")
        for c in calls:
            o = _override_dict(c["params"])
            if _override_is_empty(o):
                continue
            prefix = "第 %d 行：" % c["line"] if c["line"] > 0 else ""
            if o["qty"] is not None and o["qty"] % 100 != 0:
                errors.append("%s委托数量需为 100 股的整数倍" % prefix)
            if o["qty"] is not None and o["amount"] is not None:
                errors.append("%s委托数量与金额只能二选一" % prefix)

    return errors


# --- 语义预览（StrategyPreview） ----------------------------------------------

_MINUS = "\u2212"        # Swift 源码里的 "−" 是 U+2212（不是 ASCII 连字符）


def _num(v):
    """数值文案：整数不带小数（%.0f），非整数用 %g。"""
    return "%.0f" % v if v == _swift_round(v) else "%g" % v


def _price_fmt(v):
    return "%.2f" % v


def _percent_signed(v, plus):
    magnitude = _num(abs(v))
    if v < 0:
        return "%s%s%%" % (_MINUS, magnitude)
    return "%s%s%%" % ("+" if plus else _MINUS, magnitude)


def _price_text(params, key):
    d = _pnum(params, key)
    return _price_fmt(d) if d is not None else (_pget(params, key) or "--")


def _num_text(params, key):
    d = _pnum(params, key)
    return _num(d) if d is not None else (_pget(params, key) or "--")


def _int_text(params, key):
    i = _pint(params, key)
    return "%d" % i if i is not None else (_pget(params, key) or "--")


def _trigger_text(call):
    kind = call.get("kind")
    params = call.get("params") if isinstance(call.get("params"), dict) else {}

    if kind == "PRICE":
        symbol = "≤" if _pget(params, "OP") == "<=" else "≥"
        return "现价 %s %s 时触发" % (symbol, _price_text(params, "VALUE"))

    if kind == "STOP_LOSS":
        by_price = _upper(_pget(params, "MODE")) == "PRICE"
        profit = _pnum(params, "PROFIT")
        loss = _pnum(params, "LOSS")
        parts = []
        if by_price:
            if profit is not None:
                parts.append("止盈价 %s" % _price_fmt(profit))
            if loss is not None:
                parts.append("止损价 %s" % _price_fmt(loss))
        else:
            if profit is not None:
                parts.append("止盈 %s" % _percent_signed(profit, True))
            if loss is not None:
                parts.append("止损 %s" % _percent_signed(loss, False))
        if not parts:
            return "止盈止损（未设置止盈或止损）"
        if len(parts) == 1:
            return parts[0]
        return " 或 ".join(parts) + "（先到者为准）"

    if kind == "TRAILING":
        s = "自突破后回撤 %s%% 触发" % _num_text(params, "PCT")
        floor = _pnum(params, "FLOOR")
        if floor is not None:
            s += "（保底价 %s）" % _price_fmt(floor)
        return s

    if kind == "TIME":
        date = _pget(params, "DATE") or "--"
        at = _pget(params, "AT")
        return "%s %s 触发" % (date, at) if at is not None else "%s 触发" % date

    if kind == "CHANGE_PCT":
        v = _pnum(params, "PCT")
        v = 0 if v is None else v
        symbol = "≤" if _pget(params, "OP") == "<=" else "≥"
        word = "跌幅" if v < 0 else "涨跌幅"
        return "当日%s %s %s%% 触发" % (word, symbol, _num(abs(v)))

    if kind == "MA_CROSS":
        direction = _upper(_pget(params, "DIR")) or "UP"
        head = "下破" if direction == "DOWN" else "上穿"
        return "%s MA%s 触发" % (head, _pget(params, "PERIOD") or "--")

    if kind == "GRID":
        s = "网格区间 %s ~ %s" % (_price_text(params, "LOW"), _price_text(params, "HIGH"))
        s += "，每 %s%% 一档，每档 %s 股" % (_num_text(params, "STEP"), _int_text(params, "QTY"))
        mult = _pnum(params, "MULT")
        if mult is not None:
            s += "，倍数 %s" % _num(mult)
        return s

    if kind == "BATCH":
        return "分 %s 批建仓：首批 %s，每批价差 %s" % (
            _int_text(params, "COUNT"), _price_text(params, "FIRST"), _price_text(params, "GAP"))

    return ""


def _pick_summary(doc, picker_name):
    ref = (doc.get("pickRef") or "").strip() if isinstance(doc.get("pickRef"), str) else ""
    if ref != "":
        name = picker_name if isinstance(picker_name, str) and picker_name != "" else "已删除的公式"
        return "引用选股公式：%s" % name
    body = (doc.get("pickBody") or "").strip() if isinstance(doc.get("pickBody"), str) else ""
    if body == "":
        return "内嵌选股条件：未填写"
    one_line = " ".join([x.strip() for x in _NEWLINE_RE.split(body) if x.strip() != ""])
    truncated = one_line[:24] + "…" if len(one_line) > 24 else one_line
    return "内嵌选股条件：%s" % truncated


def _trade_summary(doc, tz_offset_seconds):
    trade = _spec_from_json(doc.get("trade"))
    if _spec_is_empty(trade):
        return "未配置交易指令"
    parts = []
    if trade["qty"] is not None:
        qty_or_amount = "%d 股" % trade["qty"]
    elif trade["amount"] is not None:
        qty_or_amount = "%s 元（按最新价折算）" % _num(trade["amount"])
    else:
        qty_or_amount = None
    if trade["direction"] is not None:
        parts.append("%s %s" % (_DIR_TITLE[trade["direction"]], qty_or_amount) if qty_or_amount
                     else _DIR_TITLE[trade["direction"]])
    elif qty_or_amount:
        parts.append(qty_or_amount)
    if trade["priceType"] is not None:
        if trade["priceType"] == "limit" and trade["offsetTicks"] is not None:
            parts.append("限价委托（触发价 %s）" % _offset_text(trade["offsetTicks"]))
        else:
            parts.append("限价委托" if trade["priceType"] == "limit" else "市价委托")
    validity = trade["validity"]
    if validity is not None:
        if validity == "day":
            parts.append("当日有效")
        elif validity == "longTerm":
            parts.append("长期有效")
        elif trade["expiresAt"] is not None:
            parts.append("有效期至 %s" % _date_text(trade["expiresAt"], tz_offset_seconds))
        else:
            parts.append("指定日期有效")
    elif trade["expiresAt"] is not None:
        parts.append("有效期至 %s" % _date_text(trade["expiresAt"], tz_offset_seconds))
    if trade["accountIDs"]:
        parts.append("绑定 %d 个账户" % len(trade["accountIDs"]))
    return " · ".join(parts) if parts else "未配置交易指令"


def _preview_summary(doc, picker_name):
    pick = _pick_summary(doc, picker_name)
    calls, _ = _rules_parse(doc.get("rules") if isinstance(doc.get("rules"), str) else "")
    if not calls:
        return "对命中【%s】的标的：暂无交易规则。" % pick
    marks = ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩"]
    items = []
    for i, c in enumerate(calls):
        mark = marks[i] if i < len(marks) else "(%d)" % (i + 1)
        items.append("%s %s" % (mark, _trigger_text(c)))
    return "对命中【%s】的标的：" % pick + "；".join(items) + "。"


# --- D 组：策略 → 条件单草稿（StrategyCondGenerator 纯映射） ------------------

# SimCondParams 字段声明顺序（非可选者恒出现，其余非空才出现——同 JSONEncoder 合成编码）
_PARAMS_ORDER = (
    "compareUp", "triggerPrice", "basePrice", "baseMode", "takeProfitPrice", "stopLossPrice",
    "breakoutPrice", "trailPct", "floorEnabled", "floorPrice", "fireDate", "changeThreshold",
    "maPeriod", "maAbove", "gridBase", "gridUpper", "gridLower", "gridStepPct",
    "gridQtyPerLevel", "gridMultiplier", "batchTotalQty", "batchCount", "batchFirstPrice",
    "batchStepPct",
)
_PARAMS_DEFAULTS = {"baseMode": "price", "floorEnabled": False}


def _params_json(params):
    out = {}
    for key in _PARAMS_ORDER:
        if key in params and params[key] is not None:
            out[key] = _to_iso(params[key]) if key == "fireDate" else params[key]
        elif key in _PARAMS_DEFAULTS:
            out[key] = _PARAMS_DEFAULTS[key]
    return out


def _directive_json(direction, price_type, offset_ticks, qty):
    return {"direction": direction, "priceType": price_type,
            "offsetTicks": offset_ticks, "qty": qty}


def _lot_qty(amount, last_price):
    """金额按最新价折算为整手股数（至少 1 手）；无法折算返回 0。"""
    if amount is None or last_price is None or amount <= 0 or last_price <= 0:
        return 0
    lots = int(amount / last_price / 100)      # Swift Int() 向零截断；此处为正数
    return max(lots, 1) * 100


def _resolved_direction(sim_kind, overrides, trade):
    if overrides.get("dir") is not None:
        return overrides["dir"]
    if trade.get("direction") is not None:
        return trade["direction"]
    return "buy" if sim_kind == "batch" else "sell"


def _resolved_qty(sim_kind, params, overrides, trade, last_price):
    if sim_kind == "grid":
        return params.get("gridQtyPerLevel") or 0
    if sim_kind == "batch":
        return params.get("batchTotalQty") or 0
    if overrides.get("qty") is not None:
        return overrides["qty"]
    if overrides.get("amount") is not None:
        return _lot_qty(overrides["amount"], last_price)
    if trade.get("qty") is not None:
        return trade["qty"]
    if trade.get("amount") is not None:
        return _lot_qty(trade["amount"], last_price)
    return 0


def _build_draft(call, trade, meta, account_id, last_price, cost_price, tz_offset_seconds):
    """一条规则 → (draft, params_internal, reason)；draft 为 None 时 reason 为中文原因。"""
    kind = call["kind"]
    params = call.get("params") if isinstance(call.get("params"), dict) else {}
    overrides = _override_dict(params)
    out = {}

    if kind == "PRICE":
        value = _pnum(params, "VALUE")
        if value is None or value <= 0:
            return None, None, "价格条件缺少有效的触发价（VALUE）"
        out["compareUp"] = False if _pget(params, "OP") == "<=" else True
        out["triggerPrice"] = value

    elif kind == "STOP_LOSS":
        percent_mode = _upper(_pget(params, "MODE")) != "PRICE"
        base = last_price if _upper(_pget(params, "BASE")) == "LAST" else cost_price
        profit = _pnum(params, "PROFIT")
        loss = _pnum(params, "LOSS")
        if profit is None and loss is None:
            return None, None, "止盈止损至少需设置止盈或止损之一"
        out["baseMode"] = "percent" if percent_mode else "price"
        out["basePrice"] = base
        if percent_mode:
            if profit is not None and base is not None:
                out["takeProfitPrice"] = base * (1 + profit / 100)
            if loss is not None and base is not None:
                out["stopLossPrice"] = base * (1 - loss / 100)
        else:
            out["takeProfitPrice"] = profit
            out["stopLossPrice"] = loss

    elif kind == "TRAILING":
        pct = _pnum(params, "PCT")
        if pct is None or pct <= 0:
            return None, None, "回落卖出缺少有效的回落幅度（PCT）"
        out["trailPct"] = pct
        out["breakoutPrice"] = last_price
        floor = _pnum(params, "FLOOR")
        if floor is not None and floor > 0:
            out["floorPrice"] = floor
            out["floorEnabled"] = True

    elif kind == "TIME":
        date_text = _pget(params, "DATE")
        fire = None
        if date_text is not None:
            fire = _fire_date(date_text, _pget(params, "AT") or "09:30", tz_offset_seconds)
        if fire is None:
            return None, None, "时间条件缺少有效日期（DATE）"
        out["fireDate"] = fire

    elif kind == "CHANGE_PCT":
        pct = _pnum(params, "PCT")
        if pct is None or pct == 0:
            return None, None, "涨跌幅条件缺少有效的幅度（PCT）"
        out["changeThreshold"] = -abs(pct) if _pget(params, "OP") == "<=" else abs(pct)

    elif kind == "MA_CROSS":
        period = _pint(params, "PERIOD")
        if period is None:
            return None, None, "均线条件缺少周期（PERIOD）"
        out["maPeriod"] = period
        direction = _upper(_pget(params, "DIR"))
        if direction == "UP":
            out["maAbove"] = True
        elif direction == "DOWN":
            out["maAbove"] = False

    elif kind == "GRID":
        base = _pnum(params, "BASE")
        low = _pnum(params, "LOW")
        high = _pnum(params, "HIGH")
        step = _pnum(params, "STEP")
        qty = _pint(params, "QTY")
        if base is None or low is None or high is None or step is None or qty is None:
            return None, None, "网格交易参数不完整（BASE / LOW / HIGH / STEP / QTY）"
        out["gridBase"] = base
        out["gridLower"] = low
        out["gridUpper"] = high
        out["gridStepPct"] = step
        out["gridQtyPerLevel"] = qty
        mult = _pnum(params, "MULT")
        out["gridMultiplier"] = mult if mult is not None else 1

    elif kind == "BATCH":
        total = _pint(params, "TOTAL")
        count = _pint(params, "COUNT")
        first = _pnum(params, "FIRST")
        gap = _pnum(params, "GAP")
        if total is None or count is None or first is None or first <= 0 or gap is None:
            return None, None, "分批建仓参数不完整（TOTAL / COUNT / FIRST / GAP）"
        out["batchTotalQty"] = total
        out["batchCount"] = count
        out["batchFirstPrice"] = first
        # GAP 以「元」填写，batchStepPct 是「以首批价为基准的百分数」→ percent = GAP / 首批价 × 100
        out["batchStepPct"] = gap / first * 100

    else:
        return None, None, "未知规则类型 %s" % kind

    sim_kind = _SIM_KIND[kind]
    price_type = overrides.get("priceType") or trade.get("priceType") or "market"
    if overrides.get("offsetTicks") is not None:
        offset_ticks = overrides["offsetTicks"]
    elif trade.get("offsetTicks") is not None:
        offset_ticks = trade["offsetTicks"]
    else:
        offset_ticks = 0
    validity = trade.get("validity") or "longTerm"
    draft = {
        "accountID": account_id,
        "metaID": meta.get("id"),
        "code": meta.get("code"),
        "name": meta.get("name"),
        "kind": sim_kind,
        "params": _params_json(out),
        "directive": _directive_json(_resolved_direction(sim_kind, overrides, trade),
                                     price_type, offset_ticks,
                                     _resolved_qty(sim_kind, out, overrides, trade, last_price)),
        "validity": validity,
    }
    if validity == "untilDate" and trade.get("expiresAt") is not None:
        draft["expiresAt"] = _to_iso(trade["expiresAt"])
    return draft, out, None


def _meta_title(meta):
    return "%s %s" % (meta.get("name"), meta.get("code"))


# --- E / D 组 op -------------------------------------------------------------

def _op_strategy_parse(inp):
    rules, errors = _rules_parse(inp.get("lines"))
    return {"rules": rules, "errors": errors}


def _op_strategy_rule_line(inp):
    call = inp.get("call") or {}
    kind = call.get("kind")
    if not isinstance(kind, str) or kind not in _SPECS:
        return _err("strategy_rule_line 的 call.kind 必须是 %s 之一（实得 %r）"
                    % (" / ".join(_RULE_KINDS), kind))
    return {"line": _rule_line(call)}


def _op_strategy_catalog(inp):
    want = inp.get("kind")
    kinds = [want] if isinstance(want, str) and want in _SPECS else list(_RULE_KINDS)
    if isinstance(want, str) and want != "" and want not in _SPECS:
        return _err("strategy_catalog 未知 kind: %r" % want)
    catalog = {}
    for kind in kinds:
        catalog[kind] = {
            "title": _RULE_TITLE[kind],
            "conditionOrderTitle": _RULE_COND_TITLE[kind],
            "simCondKind": _SIM_KIND[kind],
            "specs": [dict(s) for s in _SPECS[kind]],
            "knownKeys": sorted(_KNOWN_KEY_SET[kind]),
        }
    return {"catalog": catalog}


def _op_strategy_validate(inp):
    doc = inp.get("doc") or {}
    return {"issues": _validate_strategy(doc, bool(inp.get("pickerExists")),
                                         inp.get("pickSyntaxError"))}


def _op_strategy_preview(inp):
    doc = inp.get("doc") or {}
    tz = int(inp.get("tzOffsetSeconds", 0) or 0)
    calls, _ = _rules_parse(doc.get("rules") if isinstance(doc.get("rules"), str) else "")
    return {
        "summary": _preview_summary(doc, inp.get("pickerName")),
        "pick": _pick_summary(doc, inp.get("pickerName")),
        "trade": _trade_summary(doc, tz),
        "executionNotice": "触发后的下单指令（方向 / 数量 / 报价方式）本阶段未定义，留待接入执行阶段",
        "triggers": [_trigger_text(c) for c in calls],
    }


def _op_trade_parse(inp):
    tz = int(inp.get("tzOffsetSeconds", 0) or 0)
    spec, errors = _trade_parse(inp.get("lines"), tz)
    return {"spec": _spec_to_json(spec), "errors": errors}


def _op_trade_serialize(inp):
    tz = int(inp.get("tzOffsetSeconds", 0) or 0)
    return {"text": _serialize_trade(_spec_from_json(inp.get("spec")), tz)}


def _op_trade_override(inp):
    call = inp.get("call") or {}
    o = _override_dict(call.get("params") if isinstance(call.get("params"), dict) else {})
    return {"override": o, "isEmpty": _override_is_empty(o), "summary": _override_summary(o)}


def _op_strategy_drafts(inp):
    trade = _spec_from_json(inp.get("trade"))
    meta = inp.get("meta") or {}
    tz = int(inp.get("tzOffsetSeconds", 0) or 0)
    calls, _ = _rules_parse(inp.get("rules"))
    drafts = []
    skips = []
    for call in calls:
        draft, _params, reason = _build_draft(call, trade, meta, inp.get("accountID"),
                                              inp.get("lastPrice"), inp.get("costPrice"), tz)
        if draft is not None:
            drafts.append(draft)
        else:
            skips.append({"title": "%s · %s" % (_meta_title(meta), _RULE_TITLE[call["kind"]]),
                          "reason": reason if reason is not None else "该规则无法生成条件单"})
    return {"drafts": drafts, "skips": skips}


def _op_strategy_entry_draft(inp):
    trade = _spec_from_json(inp.get("trade"))
    meta = inp.get("meta") or {}
    last_price = inp.get("lastPrice")
    direction = trade.get("direction")
    if direction is None or not isinstance(last_price, (int, float)) or isinstance(last_price, bool) \
            or last_price <= 0:
        return {"draft": None}
    last_price = float(last_price)
    out = {"compareUp": True, "triggerPrice": last_price}
    validity = trade.get("validity") or "longTerm"
    offset_ticks = trade.get("offsetTicks") if trade.get("offsetTicks") is not None else 0
    draft = {
        "accountID": inp.get("accountID"),
        "metaID": meta.get("id"),
        "code": meta.get("code"),
        "name": meta.get("name"),
        "kind": "price",
        "params": _params_json(out),
        "directive": _directive_json(direction,
                                     trade.get("priceType") or "market",
                                     offset_ticks,
                                     _resolved_qty("price", out, {}, trade, last_price)),
        "validity": validity,
    }
    if validity == "untilDate" and trade.get("expiresAt") is not None:
        draft["expiresAt"] = _to_iso(trade["expiresAt"])
    return {"draft": draft}


# =============================================================================
# F 组 · 历史回测（Kline/Backtest/StrategyBacktestEngine.swift 的纯逻辑引擎）
#   - 复用 A/B/C 组口径：费率 / 涨跌停 / 整手 / T+1 / 网格档位（log 口径）
#   - 复用 D 组映射：规则 → 条件单参数（_build_draft，逐 bar 现场重算）
#   - 纯逻辑：不取数、不落盘、无随机；所有集合遍历显式排序
# =============================================================================

# StrategyBacktestEngine 内部常量的默认口径（= SimTradingRules.default）
_BT_LOT = 100
_BT_COMMISSION_RATE = 0.00025
_BT_COMMISSION_MIN = 5.0
_BT_STAMP_TAX_RATE = 0.001
_BT_LIMIT_PCT = 0.10
_BT_PRICE_TICK = 0.01

_BT_FIXED_WARNINGS = (
    "TRAILING 与 bar 内「先 high 后 low」判定属乐观假设，实际触发价可能更差",
    "实盘条件单只吃行情快照，触发必然晚于回测的逐 bar 判定",
)

_NEG_REF_RE = re.compile(r'REF\s*\([^,()]*,\s*-', re.IGNORECASE)


def _bt_fee(amount, direction):
    commission = max(amount * _BT_COMMISSION_RATE, _BT_COMMISSION_MIN)
    tax = amount * _BT_STAMP_TAX_RATE if direction == "sell" else 0.0
    return commission + tax


def _bt_limit_range(prev_close):
    if prev_close is None or prev_close <= 0:
        return None
    return (prev_close * (1 - _BT_LIMIT_PCT), prev_close * (1 + _BT_LIMIT_PCT))


def _bt_affordable_qty(cash, price):
    """SimTradingRules.affordableQty：费率上界与最低佣金上界同时满足，取小者。"""
    if price <= 0 or cash <= 0:
        return 0
    by_rate = cash / (price * (1 + _BT_COMMISSION_RATE))
    by_min = (cash - _BT_COMMISSION_MIN) / price
    raw = int(min(by_rate, by_min))          # Swift Int() 向零截断
    if raw <= 0:
        return 0
    return raw // _BT_LOT * _BT_LOT


def _bt_grid_level_count(params):
    """SimCondRule.gridLevelCount：对数口径。"""
    base, upper, lower = params.get("gridBase"), params.get("gridUpper"), params.get("gridLower")
    step = params.get("gridStepPct")
    if base is None or base <= 0 or upper is None or lower is None or step is None or step <= 0:
        return 1
    unit = math.log(1 + step / 100)
    if unit <= 0:
        return 1
    up = math.log(upper / base) / unit if upper > base else 0.0
    down = math.log(base / lower) / unit if lower < base else 0.0
    return max(int(math.floor(up)) + int(math.floor(down)), 1)


def _bt_grid_qty(params, level, per_level):
    """网格单档数量：每格股数 × 倍数^档位（倍数额度封顶 4 档）。"""
    multiplier = params.get("gridMultiplier")
    multiplier = 1 if multiplier is None else multiplier
    multiplier = min(max(multiplier, 1), 5)
    factor = math.pow(multiplier, min(max(level, 0), 4))
    return per_level * int(_swift_round(factor))


def _bt_batch_qty(total_qty, count, index):
    """分批单批数量：均分向下取整到手，最后一批吃掉余数。"""
    per_batch = total_qty // count // _BT_LOT * _BT_LOT
    if index >= count:
        return max(total_qty - per_batch * (count - 1), 0)
    return max(per_batch, 0)


def _bt_days_between(d_from, d_to):
    """两个 YYYYMMDD 之间的自然日差（公历本地日，负数归零）。"""
    def _d(v):
        try:
            return datetime(v // 10000, (v // 100) % 100, v % 100)
        except ValueError:
            return None
    a, b = _d(d_from), _d(d_to)
    if a is None or b is None:
        return 0
    return max((b - a).days, 0)


def _bt_future_function_warnings(text):
    result = []
    upper = (text or "").upper()
    if "BACKSET" in upper:
        result.append("选股公式包含未来函数（BACKSET），回测结果偏乐观")
    if "ZIG" in upper:
        result.append("选股公式包含未来函数（ZIG），回测结果偏乐观")
    if isinstance(text, str) and _NEG_REF_RE.search(text):
        result.append("选股公式包含未来函数（REF 负偏移），回测结果偏乐观")
    return result


def _bt_meta_title(meta, meta_id):
    if not isinstance(meta, dict):
        return "标 #%d" % meta_id
    return "%s %s" % (meta.get("name") or "", meta.get("code") or "")


_BT_PLACEHOLDER_META = {"id": 0, "code": "", "name": ""}


def _run_backtest(doc, bars_by_id, hits_by_id, metas_by_id, params, tz_offset_seconds):
    warnings = []
    skipped = []

    days = params["days"]
    execute_next_open = params["executeNextOpen"]
    include_entry = params["includeEntry"]

    # --- 1. 窗口与交易日历 -----------------------------------------------
    series = {}
    windows = {}
    index_by_date = {}
    window_index_by_date = {}
    window_closes = {}
    for mid in sorted(bars_by_id.keys()):
        full = bars_by_id[mid]
        if not full:
            skipped.append("%s：无历史行情数据，已跳过" % _bt_meta_title(metas_by_id.get(mid), mid))
            continue
        if len(full) < 30:
            skipped.append("%s：行情不足 30 根（%d），已跳过"
                           % (_bt_meta_title(metas_by_id.get(mid), mid), len(full)))
            continue
        take = max(days, 1)
        win = full[max(0, len(full) - take):]
        series[mid] = full
        windows[mid] = win
        index_by_date[mid] = {bar["date"]: i for i, bar in enumerate(full)}
        window_index_by_date[mid] = {bar["date"]: i for i, bar in enumerate(win)}
        window_closes[mid] = [bar["close"] for bar in win]

    included = sorted(windows.keys())
    if not included:
        return _bt_empty_result(params, len(bars_by_id), skipped)

    calendar = sorted({bar["date"] for mid in included for bar in windows[mid]})

    # --- 1b. 未来函数静态扫描（纯文本，只提示不阻断） ---------------------
    warnings.extend(_bt_future_function_warnings(doc.get("pickBody")))

    # --- 1c. 单日跳空 > 11% 的标的数（疑似除权，去重合并成 1 条） ---------
    gap_meta_count = 0
    for mid in included:
        win = windows[mid]
        if len(win) <= 1:
            continue
        for i in range(1, len(win)):
            if win[i - 1]["close"] > 0:
                change = abs((win[i]["close"] - win[i - 1]["close"]) / win[i - 1]["close"])
                if change > 0.11:
                    gap_meta_count += 1
                    break
    if gap_meta_count > 0:
        warnings.append("%d 只标的出现单日跳空 > 11%%，疑似除权，结果可能失真" % gap_meta_count)

    # --- 2. 账本状态 -----------------------------------------------------
    cash = params["initialCapital"]
    positions = {}
    pending = []
    equity_points = []
    trades = []
    last_close = {}
    limit_up_blocks = 0
    limit_down_blocks = 0
    t1_blocks = 0

    # --- 3. 局部工具 -----------------------------------------------------

    def bar_on(mid, date):
        i = index_by_date[mid].get(date)
        if i is None:
            return None
        return series[mid][i]

    def prev_close_of(mid, bar):
        i = index_by_date[mid].get(bar["date"])
        if i is None or i <= 0:
            return bar["open"]
        return series[mid][i - 1]["close"]

    def ma_value(mid, period, index):
        closes = window_closes.get(mid)
        if period <= 0 or index < period - 1 or closes is None or index >= len(closes):
            return None
        total = 0.0
        for k in range(index - period + 1, index + 1):
            total += closes[k]
        return total / period

    def fill_price(trigger, bar):
        if trigger > bar["high"]:
            return bar["open"]
        return max(trigger, bar["low"])

    def perform_buy(meta_id, signal_date, date, rule_kind, bar, price, desired_qty):
        nonlocal cash, limit_up_blocks
        if price <= 0:
            return False
        rng = _bt_limit_range(prev_close_of(meta_id, bar))
        if rng is not None and price >= rng[1]:
            limit_up_blocks += 1
            return False
        affordable = _bt_affordable_qty(cash, price)
        qty = desired_qty if desired_qty > 0 else affordable
        qty = qty // _BT_LOT * _BT_LOT
        if qty > affordable:
            qty = affordable
        if qty <= 0:
            if len(skipped) < 200:
                skipped.append("%d %s：可用资金不足，买入跳过"
                               % (date, _bt_meta_title(metas_by_id.get(meta_id), meta_id)))
            return False
        amount = price * qty
        f = _bt_fee(amount, "buy")
        cash -= amount + f
        pos = positions.get(meta_id)
        if pos is not None and pos["qty"] > 0:
            new_qty = pos["qty"] + qty
            pos["costPrice"] = (pos["qty"] * pos["costPrice"] + amount + f) / new_qty
            pos["qty"] = new_qty            # availableQty 不变（当日买入不可卖）
        else:
            positions[meta_id] = {
                "metaID": meta_id, "qty": qty, "availableQty": 0,
                "costPrice": (amount + f) / qty, "openedDate": date,
                "gridLevel": 0, "gridBasePrice": 0.0, "gridLastPrice": 0.0,
                "gridStopped": False, "extreme": bar["high"], "batchDone": 0,
                "planRules": [],
            }
        trades.append(_bt_trade(signal_date, date, meta_id,
                                _bt_code(metas_by_id, meta_id), _bt_name(metas_by_id, meta_id),
                                rule_kind, "buy", qty, price, amount, f, None, None))
        return True

    def perform_sell(meta_id, signal_date, date, rule_kind, bar, price, desired_qty):
        nonlocal cash, limit_down_blocks, t1_blocks
        pos = positions.get(meta_id)
        if price <= 0 or pos is None or pos["qty"] <= 0:
            return 0
        rng = _bt_limit_range(prev_close_of(meta_id, bar))
        if rng is not None and price <= rng[0]:
            limit_down_blocks += 1
            return 0
        sellable = pos["availableQty"]        # tPlus1Enabled 恒为 true
        qty = desired_qty if desired_qty > 0 else sellable
        if qty > sellable:
            qty = sellable
        qty = qty // _BT_LOT * _BT_LOT
        if qty <= 0:
            t1_blocks += 1
            if len(skipped) < 200:
                skipped.append("%d %s：可卖数量不足（T+1 或已清仓），卖出跳过"
                               % (date, _bt_meta_title(metas_by_id.get(meta_id), meta_id)))
            return 0
        amount = price * qty
        f = _bt_fee(amount, "sell")
        pnl = (price - pos["costPrice"]) * qty - f
        cash += amount - f
        opened = pos["openedDate"]
        pos["qty"] -= qty
        pos["availableQty"] = max(0, pos["availableQty"] - qty)
        if pos["qty"] <= 0:
            del positions[meta_id]
        trades.append(_bt_trade(signal_date, date, meta_id,
                                _bt_code(metas_by_id, meta_id), _bt_name(metas_by_id, meta_id),
                                rule_kind, "sell", qty, price, amount, f, pnl,
                                _bt_days_between(opened, date)))
        return qty

    def entry_qty(price):
        trade = doc.get("trade") if isinstance(doc.get("trade"), dict) else {}
        t_qty = trade.get("qty")
        if isinstance(t_qty, int) and t_qty > 0:
            return t_qty // _BT_LOT * _BT_LOT
        if price <= 0:
            return 0
        t_amount = trade.get("amount")
        if isinstance(t_amount, (int, float)) and t_amount > 0:
            return max(int(t_amount / price / _BT_LOT) * _BT_LOT, _BT_LOT)
        if cash <= 0:
            return 0
        return max(int(cash * 0.2 / price / _BT_LOT) * _BT_LOT, _BT_LOT)

    def plan_rules(meta_id, cost_price, last_price):
        """复用 D 组映射：规则 → 条件单参数（逐 bar 现场重算）。"""
        meta = metas_by_id.get(meta_id) or dict(_BT_PLACEHOLDER_META, id=meta_id)
        calls, _errors = _rules_parse(doc.get("rules") if isinstance(doc.get("rules"), str) else "")
        out = []
        for call in calls:
            draft, _p, _reason = _build_draft(call, _spec_from_json(doc.get("trade")), meta,
                                              _BT_PLACEHOLDER_ACCOUNT, last_price, cost_price,
                                              tz_offset_seconds)
            if draft is None:
                continue
            out.append({"kind": draft["kind"], "params": _p,
                        "direction": draft["directive"]["direction"],
                        "qty": draft["directive"]["qty"]})
        return out

    def schedule_exit(meta_id, kind, date, bar):
        if execute_next_open:
            pending.append({"metaID": meta_id, "signalDate": date, "direction": "sell",
                            "desiredQty": 0, "priceType": "market", "offsetTicks": 0,
                            "triggerPrice": bar["close"], "ruleKind": kind})
        else:
            perform_sell(meta_id, date, date, kind, bar, bar["close"], 0)

    def evaluate_full_exit(meta_id, date, bar):
        pos = positions.get(meta_id)
        if pos is None or pos["qty"] <= 0:
            return False
        for rule in pos["planRules"]:
            kind = rule["kind"]
            if kind in ("grid", "batch"):
                continue
            p = rule["params"]

            if kind == "price":
                trigger = p.get("triggerPrice")
                if rule["direction"] != "sell" or trigger is None or trigger <= 0 \
                        or bar["low"] > trigger:
                    continue
                perform_sell(meta_id, date, date, "price", bar,
                             fill_price(trigger, bar), 0)
                return True

            elif kind == "stopLoss":
                stop = p.get("stopLossPrice")
                if stop is not None and stop > 0 and bar["low"] <= stop:
                    perform_sell(meta_id, date, date, "stopLoss", bar,
                                 fill_price(stop, bar), 0)
                    return True
                take = p.get("takeProfitPrice")
                if take is not None and take > 0 and bar["high"] >= take:
                    perform_sell(meta_id, date, date, "stopLoss", bar,
                                 fill_price(take, bar), 0)
                    return True

            elif kind == "trailing":
                floor = p.get("floorPrice")
                if p.get("floorEnabled") and floor is not None and floor > 0 \
                        and bar["low"] <= floor:
                    perform_sell(meta_id, date, date, "trailing", bar,
                                 fill_price(floor, bar), 0)
                    return True
                pct = p.get("trailPct")
                if pct is not None and pct > 0 and pos["extreme"] > 0:
                    trigger = pos["extreme"] * (1 - pct / 100)
                    if bar["low"] <= trigger:
                        perform_sell(meta_id, date, date, "trailing", bar,
                                     fill_price(trigger, bar), 0)
                        return True

            elif kind == "time":
                fire = p.get("fireDate")
                if fire is None or date < _date_int(fire, tz_offset_seconds):
                    continue
                price = bar["open"] if execute_next_open else bar["close"]
                perform_sell(meta_id, date, date, "time", bar, price, 0)
                return True

            elif kind == "changePct":
                threshold = p.get("changeThreshold")
                if threshold is None or threshold == 0:
                    continue
                prev = prev_close_of(meta_id, bar)
                if prev <= 0:
                    continue
                change_pct = (bar["close"] - prev) / prev * 100
                hit = change_pct >= threshold if threshold > 0 else change_pct <= threshold
                if not hit:
                    continue
                schedule_exit(meta_id, "changePct", date, bar)
                return True

            elif kind == "maCross":
                period = p.get("maPeriod")
                above = p.get("maAbove")
                index = window_index_by_date[meta_id].get(date)
                if period is None or above is None or index is None:
                    continue
                ma = ma_value(meta_id, period, index)
                prev_ma = ma_value(meta_id, period, index - 1)
                if ma is None or prev_ma is None:
                    continue
                prev = prev_close_of(meta_id, bar)
                if above:
                    hit = prev <= prev_ma and bar["close"] >= ma
                else:
                    hit = prev > prev_ma and bar["close"] <= ma
                if not hit:
                    continue
                schedule_exit(meta_id, "maCross", date, bar)
                return True
        return False

    def evaluate_grid(meta_id, date, bar):
        pos = positions.get(meta_id)
        if pos is None or pos["qty"] <= 0 or pos["gridStopped"]:
            return
        rule = next((r for r in pos["planRules"] if r["kind"] == "grid"), None)
        if rule is None:
            return
        p = rule["params"]
        base, lower, upper = p.get("gridBase"), p.get("gridLower"), p.get("gridUpper")
        step_pct, per_level = p.get("gridStepPct"), p.get("gridQtyPerLevel")
        if base is None or lower is None or upper is None \
                or step_pct is None or step_pct <= 0 \
                or per_level is None or per_level <= 0:
            return
        if pos["gridBasePrice"] <= 0:
            pos["gridBasePrice"] = base
            pos["gridLastPrice"] = base
            pos["gridLevel"] = 0
        if bar["high"] > upper or bar["low"] < lower:
            pos["gridStopped"] = True
            warnings.append("%d %s 价格越出网格区间 [%.2f, %.2f]，网格规则停止"
                            % (date, _bt_meta_title(metas_by_id.get(meta_id), meta_id),
                               lower, upper))
            return
        step = step_pct / 100 * pos["gridBasePrice"]
        if step <= 0:
            return
        max_levels = max(_bt_grid_level_count(p), 1)
        # 下移：买入（每档目标价 = 上次触发价 − step）
        for _ in range(max_levels):
            cur = positions.get(meta_id)
            if cur is None or cur["gridLevel"] >= max_levels:
                break
            target = cur["gridLastPrice"] - step
            if bar["low"] > target:
                break
            qty = _bt_grid_qty(p, cur["gridLevel"], per_level)
            if qty <= 0:
                break
            if not perform_buy(meta_id, date, date, "grid", bar, target, qty):
                break
            positions[meta_id]["gridLevel"] = cur["gridLevel"] + 1
            positions[meta_id]["gridLastPrice"] = target
        # 上移：卖出（卖出同档数量，受可卖限制）
        for _ in range(max_levels):
            cur = positions.get(meta_id)
            if cur is None or cur["gridLevel"] <= 0:
                break
            target = cur["gridLastPrice"] + step
            if bar["high"] < target:
                break
            qty = _bt_grid_qty(p, cur["gridLevel"] - 1, per_level)
            if qty <= 0:
                break
            filled = perform_sell(meta_id, date, date, "grid", bar, target, qty)
            if filled <= 0:
                break
            positions[meta_id]["gridLevel"] = max(cur["gridLevel"] - 1, 0)
            positions[meta_id]["gridLastPrice"] = target

    def evaluate_batch(meta_id, date, bar):
        pos = positions.get(meta_id)
        if pos is None or pos["qty"] <= 0:
            return
        rule = next((r for r in pos["planRules"] if r["kind"] == "batch"), None)
        if rule is None:
            return
        p = rule["params"]
        total_qty, count = p.get("batchTotalQty"), p.get("batchCount")
        first, step_pct = p.get("batchFirstPrice"), p.get("batchStepPct")
        if total_qty is None or total_qty <= 0 or count is None or count < 2 \
                or first is None or first <= 0 or step_pct is None or step_pct <= 0:
            return
        index = pos["batchDone"] + 1
        if index > count:
            return
        is_buy = rule["direction"] == "buy"
        offset = step_pct / 100 * (index - 1)
        target = first * (1 - offset) if is_buy else first * (1 + offset)
        if target <= 0:
            return
        reached = bar["low"] <= target if is_buy else bar["high"] >= target
        if not reached:
            return
        qty = _bt_batch_qty(total_qty, count, index)
        if qty <= 0:
            return
        if is_buy:
            if not perform_buy(meta_id, date, date, "batch", bar, target, qty):
                return
        else:
            if perform_sell(meta_id, date, date, "batch", bar, target, qty) <= 0:
                return
        positions[meta_id]["batchDone"] = index       # 成交后才推进批次

    def evaluate_price_buy(meta_id, date, bar):
        pos = positions.get(meta_id)
        if pos is None:
            return
        rule = next((r for r in pos["planRules"]
                     if r["kind"] == "price" and r["direction"] == "buy"), None)
        if rule is None:
            return
        trigger = rule["params"].get("triggerPrice")
        if trigger is None or trigger <= 0 or bar["high"] < trigger or rule["qty"] <= 0:
            return
        perform_buy(meta_id, date, date, "price", bar, fill_price(trigger, bar), rule["qty"])

    # --- 4. 逐交易日推进 -------------------------------------------------
    for date in calendar:
        # a. T+1 释放（必须早于当日成交执行）
        for mid in sorted(positions.keys()):
            if positions[mid]["openedDate"] != date:
                positions[mid]["availableQty"] = positions[mid]["qty"]

        # b. 开盘执行待成交动作（信号日当日不成交，顺延到该标的下一根 bar）
        if pending:
            rest = []
            for action in pending:
                bar = bar_on(action["metaID"], date) if date > action["signalDate"] else None
                if bar is None:
                    rest.append(action)
                    continue
                if action["priceType"] == "limit":
                    trigger = action["triggerPrice"] + action["offsetTicks"] * _BT_PRICE_TICK
                    price = fill_price(trigger, bar)
                else:
                    price = bar["open"]
                if action["direction"] == "buy":
                    perform_buy(action["metaID"], action["signalDate"], date,
                                action["ruleKind"], bar, price, action["desiredQty"])
                else:
                    perform_sell(action["metaID"], action["signalDate"], date,
                                 action["ruleKind"], bar, price, action["desiredQty"])
            pending = rest

        # c. 持仓的规则判定（整仓离场后本标的当日不再动作）
        for mid in sorted(positions.keys()):
            bar = bar_on(mid, date)
            if bar is None:
                continue
            pos = positions.get(mid)
            if pos is None or pos["qty"] <= 0:
                continue
            pos["planRules"] = plan_rules(mid, pos["costPrice"], bar["close"])
            if any(r["kind"] == "trailing" for r in pos["planRules"]):
                pos["extreme"] = max(pos["extreme"], bar["high"])
            if evaluate_full_exit(mid, date, bar):
                continue
            evaluate_grid(mid, date, bar)
            evaluate_batch(mid, date, bar)
            evaluate_price_buy(mid, date, bar)

        # d. 入场信号（选股命中且当前无持仓）
        if include_entry:
            for mid in included:
                if date not in hits_by_id.get(mid, ()) or positions.get(mid, {}).get("qty", 0) != 0:
                    continue
                bar = bar_on(mid, date)
                if bar is None:
                    continue
                qty = entry_qty(bar["close"])
                if qty <= 0:
                    continue
                trade = doc.get("trade") if isinstance(doc.get("trade"), dict) else {}
                if execute_next_open:
                    pending.append({
                        "metaID": mid, "signalDate": date, "direction": "buy",
                        "desiredQty": qty,
                        "priceType": trade.get("priceType") or "market",
                        "offsetTicks": trade.get("offsetTicks") or 0,
                        "triggerPrice": bar["close"], "ruleKind": None})
                else:
                    perform_buy(mid, date, date, None, bar, bar["close"], qty)

        # e. 收盘估值（当日无 bar 的持仓沿用上一根 close）
        equity = cash
        for mid in sorted(positions.keys()):
            pos = positions[mid]
            bar = bar_on(mid, date)
            if bar is not None:
                last_close[mid] = bar["close"]
            equity += pos["qty"] * last_close.get(mid, pos["costPrice"])
        equity_points.append({"date": date, "equity": equity})

    # --- 5. 收尾：不强制平仓，未平仓按最后交易日收盘价计入净值 -----------
    final_equity = equity_points[-1]["equity"] if equity_points else params["initialCapital"]
    if positions:
        warnings.append("期末仍有 %d 只标的未平仓，已按最后一个交易日收盘价计入净值" % len(positions))

    # --- 6. 指标 ---------------------------------------------------------
    round_trades = [t for t in trades if t["realizedPnL"] is not None]
    win_count = sum(1 for t in round_trades if t["realizedPnL"] > 0)
    gains = sum(max(t["realizedPnL"], 0.0) for t in round_trades)
    losses = sum(min(t["realizedPnL"], 0.0) for t in round_trades)
    initial = params["initialCapital"]
    total_return = final_equity / initial - 1 if initial > 0 else 0
    base = 1 + total_return
    periods = float(max(len(calendar), 1))
    annualized = math.pow(base, 252 / periods) - 1 if base > 0 else -1
    win_rate = (win_count / len(round_trades)) if round_trades else 0
    profit_factor = gains / abs(losses) if losses < 0 else 0
    hold_days = [t["holdDays"] for t in round_trades if t["holdDays"] is not None]
    avg_hold_days = (sum(hold_days) / len(hold_days)) if hold_days else 0

    max_drawdown = 0.0
    drawdown_range = None
    peak = equity_points[0]["equity"] if equity_points else initial
    peak_index = 0
    for i, point in enumerate(equity_points):
        if point["equity"] > peak:
            peak = point["equity"]
            peak_index = i
        if peak <= 0:
            continue
        drawdown = 1 - point["equity"] / peak
        if drawdown > max_drawdown:
            max_drawdown = drawdown
            drawdown_range = [peak_index, i]

    warnings.extend(_BT_FIXED_WARNINGS)
    if limit_up_blocks > 0:
        warnings.append("%d 笔买入因成交价触涨停未成交" % limit_up_blocks)
    if limit_down_blocks > 0:
        warnings.append("%d 笔卖出因成交价触跌停未成交" % limit_down_blocks)
    if t1_blocks > 0:
        warnings.append("%d 笔卖出因 T+1（当日买入不可卖）未成交" % t1_blocks)

    stats = {
        "initialCapital": initial,
        "finalEquity": final_equity,
        "totalReturn": total_return,
        "annualized": annualized,
        "winRate": win_rate,
        "profitFactor": profit_factor,
        "maxDrawdown": max_drawdown,
        "tradeCount": len(trades),
        "roundTrips": len(round_trades),
        "avgHoldDays": avg_hold_days,
    }
    hit_count = sum(1 for mid in included if hits_by_id.get(mid))
    return {
        "stats": stats,
        "equity": equity_points,
        "maxDrawdownRange": drawdown_range,
        "trades": trades,
        "scannedCount": len(bars_by_id),
        "hitCount": hit_count,
        "warnings": warnings,
        "skipped": skipped,
    }


def _bt_trade(signal_date, date, meta_id, code, name, rule_kind, direction, qty, price,
              amount, fee, realized_pnl, hold_days):
    return {"signalDate": signal_date, "date": date, "metaID": meta_id,
            "code": code, "name": name,
            "ruleKind": rule_kind, "direction": direction, "qty": qty, "price": price,
            "amount": amount, "fee": fee, "realizedPnL": realized_pnl, "holdDays": hold_days}


def _bt_code(metas_by_id, meta_id):
    meta = metas_by_id.get(meta_id)
    return (meta.get("code") or "") if isinstance(meta, dict) else ""


def _bt_name(metas_by_id, meta_id):
    meta = metas_by_id.get(meta_id)
    return (meta.get("name") or "") if isinstance(meta, dict) else ""


def _bt_empty_result(params, scanned, skipped):
    stats = {"initialCapital": params["initialCapital"], "finalEquity": params["initialCapital"],
             "totalReturn": 0, "annualized": 0, "winRate": 0, "profitFactor": 0,
             "maxDrawdown": 0, "tradeCount": 0, "roundTrips": 0, "avgHoldDays": 0}
    warnings = ["没有可参与回测的标的（行情缺失或不足 30 根），未产生净值曲线"]
    warnings.extend(_BT_FIXED_WARNINGS)
    return {"stats": stats, "equity": [], "maxDrawdownRange": None, "trades": [],
            "scannedCount": scanned, "hitCount": 0, "warnings": warnings, "skipped": skipped}


# 回测装配草稿时的占位账户 id（Swift 用固定的 BACC 占位 UUID，回测不使用账户）
_BT_PLACEHOLDER_ACCOUNT = "00000000-0000-0000-0000-00000000BACC"


def _op_backtest_run(inp):
    doc = inp.get("doc") or {}
    params = _bt_params(inp.get("params"))
    tz = int(inp.get("tzOffsetSeconds", 0) or 0)

    bars_raw = inp.get("bars")
    if not isinstance(bars_raw, dict):
        return _err("backtest_run 需要 bars（{metaID: [{date,open,high,low,close}...]}）")
    bars_by_id = {}
    for key, arr in bars_raw.items():
        mid = _bt_int_key(key)
        if mid is None:
            return _err("backtest_run 的 bars 键必须是整数 metaID：%r" % (key,))
        if not isinstance(arr, list):
            return _err("backtest_run 的 bars[%s] 必须是数组" % key)
        parsed = []
        for item in arr:
            bar = _bt_bar(item)
            if bar is None:
                return _err("backtest_run 的 bars[%s] 元素必须是行情对象" % key)
            parsed.append(bar)
        bars_by_id[mid] = parsed

    hits_by_id = {}
    hits_raw = inp.get("pickHits") or {}
    for key, arr in hits_raw.items():
        mid = _bt_int_key(key)
        if mid is None:
            return _err("backtest_run 的 pickHits 键必须是整数 metaID：%r" % (key,))
        hits_by_id[mid] = set(int(x) for x in arr) if isinstance(arr, list) else set()

    metas_by_id = {}
    metas_raw = inp.get("metas") or {}
    for key, obj in metas_raw.items():
        mid = _bt_int_key(key)
        if mid is None:
            return _err("backtest_run 的 metas 键必须是整数 metaID：%r" % (key,))
        if isinstance(obj, dict):
            metas_by_id[mid] = {"id": mid, "code": obj.get("code") or "", "name": obj.get("name") or ""}

    result = _run_backtest(doc, bars_by_id, hits_by_id, metas_by_id, params, tz)
    scanned = inp.get("scannedCount")
    if isinstance(scanned, int) and not isinstance(scanned, bool):
        result["scannedCount"] = scanned
    result["params"] = {"days": params["days"], "initialCapital": params["initialCapital"],
                        "executeNextOpen": params["executeNextOpen"],
                        "includeEntry": params["includeEntry"]}
    return result


def _bt_int_key(key):
    if isinstance(key, int) and not isinstance(key, bool):
        return key
    if isinstance(key, str):
        try:
            return int(key)
        except ValueError:
            return None
    return None


def _bt_bar(obj):
    if not isinstance(obj, dict):
        return None
    return {
        "date": int(obj.get("date") or 0),
        "open": float(obj.get("open") or 0.0),
        "high": float(obj.get("high") or 0.0),
        "low": float(obj.get("low") or 0.0),
        "close": float(obj.get("close") or 0.0),
    }


def _bt_params(params_in):
    src = params_in if isinstance(params_in, dict) else {}
    days = src.get("days")
    days = int(days) if isinstance(days, (int, float)) and not isinstance(days, bool) else 250
    cap = src.get("initialCapital")
    cap = float(cap) if isinstance(cap, (int, float)) and not isinstance(cap, bool) else 100000.0
    next_open = src.get("executeNextOpen")
    next_open = True if not isinstance(next_open, bool) else next_open
    entry = src.get("includeEntry")
    entry = True if not isinstance(entry, bool) else entry
    return {"days": days, "initialCapital": cap,
            "executeNextOpen": next_open, "includeEntry": entry}



_OPS = {
    "sim_format": _op_sim_format,
    "cond_evaluate": _op_cond_evaluate,
    "cond_validate_create": _op_cond_validate_create,
    "cond_grid_level_count": _op_cond_grid_level_count,
    "cond_text": _op_cond_text,
    "cond_expired_reason": _op_cond_expired_reason,
    "cond_fire_direction": _op_cond_fire_direction,
    "cond_execution_price": _op_cond_execution_price,
    "cond_advance": _op_cond_advance,
    "cond_repeatable_finished": _op_cond_repeatable_finished,
    "cond_alert_message": _op_cond_alert_message,
    "trade_calc": _op_trade_calc,
    "trade_validate": _op_trade_validate,
    # E 组（策略 DSL 纯解析 / 校验 / 预览）
    "strategy_parse": _op_strategy_parse,
    "strategy_rule_line": _op_strategy_rule_line,
    "strategy_catalog": _op_strategy_catalog,
    "strategy_validate": _op_strategy_validate,
    "strategy_preview": _op_strategy_preview,
    "trade_parse": _op_trade_parse,
    "trade_serialize": _op_trade_serialize,
    "trade_override": _op_trade_override,
    # D 组（策略 → 条件单草稿纯映射）
    "strategy_drafts": _op_strategy_drafts,
    "strategy_entry_draft": _op_strategy_entry_draft,
    # F 组（历史回测）
    "backtest_run": _op_backtest_run,
}


def _main():
    inp = globals().get("kline_input")
    if not isinstance(inp, dict):
        return _err("kline_input 未注入或不是对象")
    op = inp.get("op")
    handler = _OPS.get(op)
    if handler is None:
        return _err("未知 op: %r（仅支持 %s）" % (op, " / ".join(sorted(_OPS))))
    try:
        out = handler(inp)
    except Exception as exc:  # noqa: BLE001 —— 与既有脚本一致：形状非法即 ok=False
        return _err("%s 执行异常：%s" % (op, exc))
    if isinstance(out, dict) and out.get("ok") is False:
        return out
    result = {"ok": True}
    if isinstance(out, dict):
        result.update(out)
    return result


kline_result = _main()

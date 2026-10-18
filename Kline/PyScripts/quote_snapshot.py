# -*- coding: utf-8 -*-
"""quote_snapshot.py — 行情快照计算（阶段 C：拆共享枢纽）。

职责：从 K 线 bars 数组计算行情快照字段（latestPrice / prevClose / change / changePct 等），
供 Swift SimQuoteCenter / MarketRowCache 调用。Swift 侧负责从 DatabaseManager 取 bars 并传入，
Python 侧只做纯计算，不直接访问数据库（避免跨进程文件锁问题）。

契约（与 KlinePythonBridge 一致）：
  - 桥接注入模块全局 dict `kline_input`；产出模块级 dict `kline_result`，
    `kline_result["ok"]` 为 bool。
  - 输入字段：
      {
        "op": "quote_snapshot",
        "bars": [[date, open, high, low, close, volume, turnover], ...],  // 升序，旧→新
        "fields": ["latestPrice", "prevClose", "change", "changePct", ...]  // 可选，缺省全算
      }
  - 输出：{"ok": true, "result": {"latestPrice": 1452.30, "prevClose": 1448.00, ...}}
  - 空 bars 或不足 → 缺失字段为 null
  - 日期为整数（如 20261017），价格/量为数值

纯函数，无副作用，无 IO。
"""

import math


def _err(msg):
    return {"ok": False, "error": msg}


def _ok(result=None):
    r = {"ok": True}
    if result is not None:
        r["result"] = result
    return r


def _last(bars):
    return bars[-1] if bars else None


def _prev_close(bars):
    """昨收 = 倒数第二根 close；不足 2 根返回 None（通达信首日惯例：退化为 open，此处保持严格）"""
    if len(bars) >= 2:
        return bars[-2][4]  # close 索引 4
    return None


def _compute(field, bars):
    """按 MarketField 语义计算单字段（与 Swift MarketRow.compute 同口径）。"""
    last = _last(bars)
    if last is None:
        return None
    close = last[4]

    if field == "latestPrice":
        return close
    if field == "prevClose":
        return _prev_close(bars)
    if field == "open":
        return last[1]
    if field == "high":
        return last[2]
    if field == "low":
        return last[3]
    if field == "volume":
        return last[5]
    if field == "turnover":
        return last[6] if len(last) > 6 else None

    # 涨跌额 / 涨跌幅
    if field == "change":
        pc = _prev_close(bars)
        if pc is None or pc <= 0:
            return None
        return close - pc
    if field == "changePct":
        pc = _prev_close(bars)
        if pc is None or pc <= 0:
            return None
        return (close - pc) / pc * 100.0
    if field == "amplitude":
        pc = _prev_close(bars)
        if pc is None or pc <= 0:
            return None
        return (last[2] - last[3]) / pc * 100.0  # (high - low) / prevClose * 100

    # 量比
    if field == "volRatio":
        if len(bars) < 2:
            return None
        today = last[5]
        before = bars[:-1]
        base = before[-5:]  # 最近 5 日
        if not base:
            return None
        avg = sum(b[5] for b in base) / len(base)
        if avg <= 0:
            return None
        return today / avg

    # 区间涨幅 pct3d/5d/10d/20d/60d
    if field.startswith("pct") and field[3:].isdigit():
        window = int(field[3:])
        count = len(bars)
        if count < 2:
            return None
        start = max(0, count - window - 1)
        baseIdx = min(start, count - 2)
        base = bars[baseIdx][4]
        if base <= 0:
            return None
        return (close - base) / base * 100.0

    # YTD
    if field == "pctYTD":
        count = len(bars)
        if count < 2:
            return None
        last_date = last[0]
        year_of_last = last_date // 10000
        base_idx = count - 1
        for i in range(count - 1, -1, -1):
            if bars[i][0] // 10000 == year_of_last:
                base_idx = i
            else:
                break
        if base_idx > 0:
            base = bars[base_idx - 1][4]
        else:
            base = bars[base_idx][1]  # open
        if base <= 0:
            return None
        return (close - base) / base * 100.0

    # 均线 ma5/10/20/60
    if field.startswith("ma") and field[2:].isdigit():
        n = int(field[2:])
        count = len(bars)
        if count < n:
            return None
        tail = bars[-n:]
        return sum(b[4] for b in tail) / n

    return None


# ---- op 分发表 ----
_OPS = {
    "quote_snapshot": None,  # 下面单独处理
}


def _op_quote_snapshot(inp):
    bars = inp.get("bars")
    if not isinstance(bars, list):
        return _err("bars 须为数组")
    # 每根 bars 至少 7 个元素：[date, open, high, low, close, volume, turnover]
    for b in bars:
        if not isinstance(b, list) or len(b) < 5:
            return _err("每根 bars 须至少含 [date, open, high, low, close]")

    fields = inp.get("fields")
    if fields is None:
        fields = ["latestPrice", "prevClose", "change", "changePct"]
    if not isinstance(fields, list):
        return _err("fields 须为数组")

    result = {}
    for f in fields:
        if not isinstance(f, str):
            continue
        result[f] = _compute(f, bars)

    return _ok(result)


_OPS["quote_snapshot"] = _op_quote_snapshot


def run(inp):
    """桥接入口：inp 为 kline_input，含 op 字段。返回 kline_result 形状 dict。"""
    op = inp.get("op")
    fn = _OPS.get(op)
    if fn is None:
        return _err("未知 op：%s" % op)
    try:
        return fn(inp)
    except Exception as e:
        return _err("脚本异常：%s" % e)


__all__ = ["run"]

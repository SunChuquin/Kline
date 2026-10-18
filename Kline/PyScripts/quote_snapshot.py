# -*- coding: utf-8 -*-
"""quote_snapshot.py — 行情快照计算（阶段 C：拆共享枢纽）。

职责：从 K 线 bars 数组计算行情快照字段（latestPrice / prevClose / change / changePct 等），
供 Swift SimQuoteCenter / MarketRowCache 调用。Swift 侧负责从 DatabaseManager 取 bars 并传入，
Python 侧只做纯计算，不直接访问数据库（避免跨进程文件锁问题）。

契约（与 KlinePythonBridge 一致）：
  - 桥接注入模块全局 dict `kline_input`；产出模块级 dict `kline_result`，
    `kline_result["ok"]` 为 bool。
  - 单标的输入：
      {
        "op": "quote_snapshot",
        "bars": [[date, open, high, low, close, volume, turnover], ...],  // 升序，旧→新
        "fields": ["latestPrice", "prevClose", "change", "changePct", ...]  // 可选，缺省全算
      }
  - 批量多标的输入：
      {
        "op": "quote_snapshot_batch",
        "symbols": [
          {"metaID": 1, "bars": [[date, open, high, low, close, volume, turnover], ...]},
          {"metaID": 2, "bars": [...]}
        ],
        "fields": ["latestPrice", "prevClose", "change", "changePct"]  // 可选，缺省全算
      }
  - 输出：{"ok": true, "result": {"latestPrice": 1452.30, "prevClose": 1448.00, ...}}
    批量输出：{"ok": true, "result": {"1": {...}, "2": {...}}}
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


def _compute_all(bars):
    """计算所有字段，返回 dict。"""
    fields = [
        "latestPrice", "prevClose", "open", "high", "low", "volume", "turnover",
        "change", "changePct", "amplitude", "volRatio",
        "pct3d", "pct5d", "pct10d", "pct20d", "pct60d", "pctYTD",
        "ma5", "ma10", "ma20", "ma60",
    ]
    result = {}
    for f in fields:
        result[f] = _compute(f, bars)
    return result


# ---- op 分发表 ----
_OPS = {
    "quote_snapshot": None,  # 下面单独处理
    "quote_snapshot_batch": None,
}


# bar 归一化：兼容「位置数组」与「字典」两种入参形状 -------------------------------

_BAR_KEYS = ("date", "open", "high", "low", "close", "volume", "turnover")
_BAR_ALIASES = {"volume": ("volume", "vol"), "turnover": ("turnover", "amo")}


def _norm_bar(b):
    """单根 bar → 位置数组 `[date, open, high, low, close, volume, turnover]`。

    ⚠️ 本脚本原始契约是**位置数组**；但 Swift 侧（`MarketRowCache.flushPythonSnapshot` /
    `SimQuoteCenter.lastPriceAsync`）实际传的是**字典**（键 = date/open/high/low/close/
    volume/turnover）→ `_compute` 的位置索引 `last[4]` 直接抛 TypeError，
    使整条「行情快照下沉」路径在生产里**从未生效**（2026-10-19 基线实验发现）。
    这里把两种形状归一化，Swift 侧无需改动。
    """
    if isinstance(b, list):
        return b
    if not isinstance(b, dict):
        return None
    out = []
    for key in _BAR_KEYS:
        v = None
        for alias in _BAR_ALIASES.get(key, (key,)):
            if alias in b:
                v = b[alias]
                break
        out.append(v)
    return out


def _norm_bars(bars):
    return [nb for nb in (_norm_bar(b) for b in bars) if nb is not None]


def _op_quote_snapshot(inp):
    bars = inp.get("bars")
    if not isinstance(bars, list):
        return _err("bars 须为数组")
    bars = _norm_bars(bars)
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


def _op_quote_snapshot_batch(inp):
    """批量多标的快照计算。

    输入：
      {
        "symbols": [
          {"metaID": 1, "bars": [[date, open, high, low, close, volume, turnover], ...]},
          {"metaID": 2, "bars": [...]}
        ],
        "fields": ["latestPrice", "prevClose", "change", "changePct"]  // 可选，缺省全算
      }
    输出：
      {
        "ok": true,
        "result": {
          "1": {"latestPrice": 1452.3, "prevClose": 1448.0, ...},
          "2": {...}
        }
      }
    """
    symbols = inp.get("symbols")
    if not isinstance(symbols, list):
        return _err("symbols 须为数组")
    fields = inp.get("fields")
    if fields is None:
        fields = ["latestPrice", "prevClose", "change", "changePct"]
    if not isinstance(fields, list):
        return _err("fields 须为数组")

    result = {}
    for sym in symbols:
        if not isinstance(sym, dict):
            continue
        metaID = sym.get("metaID")
        bars = sym.get("bars")
        if not isinstance(bars, list):
            continue
        # 归一化（兼容 Swift 传入的字典形状）后仍要求 ≥5 元素，不足则跳过该标的的非法 bar
        bars = [b for b in _norm_bars(bars) if len(b) >= 5]
        key = str(metaID) if metaID is not None else str(id(sym))
        sym_result = {}
        for f in fields:
            if not isinstance(f, str):
                continue
            sym_result[f] = _compute(f, bars)
        result[key] = sym_result

    return _ok(result)


_OPS["quote_snapshot"] = _op_quote_snapshot
_OPS["quote_snapshot_batch"] = _op_quote_snapshot_batch


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


def _main():
    """桥接入口：`KlinePythonBridge` 以 exec 方式运行本脚本，随后读**模块级** `kline_result`。

    ⚠️ 2026-10-19 修复：本脚本此前只定义 `run(inp)` 而无模块级 `kline_result`，
    导致桥接层包装脚本报「脚本未定义 dict 类型的 kline_result」→ **生产里所有
    `quote_snapshot` / `quote_snapshot_batch` 调用都失败并静默降级**（阶段 C 首批的
    非帧快照路径实际从未生效，`MarketRowCache` 的 0.2s 防抖只是白跑）。
    """
    inp = globals().get("kline_input")
    if not isinstance(inp, dict):
        return _err("kline_input 未注入或不是对象")
    return run(inp)


kline_result = _main()

__all__ = ["run"]

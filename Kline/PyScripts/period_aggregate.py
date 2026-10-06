# -*- coding: utf-8 -*-
"""period_aggregate.py — 周期聚合权威实现（Python 引擎阶段 1 试点批 Task 2）。

契约来源
  - `.trae/specs/add-python-offload-pilot/spec.md` 候选 3（period_aggregate.py）。

对齐的权威实现（本脚本的输出必须与它们逐字段一致）
  - `src/tdx_parser.py` handle_data / period_key：主库 tdx.db 周期线口径，
    周期线 date = 该周期的第一个交易日（组内最早日线日期）。
  - `src/live_db_builder.py` aggregate_full_periods：桶内聚合规则
    （open=首行 / high=max / low=min / close=末行 / vol、amo=求和）。
  - `Kline/Infrastructure/WatchlistSyncManager.swift` mergePeriodBar：
    op="merge" 的基期 bar ⊕ 新日线语义。

执行契约（由 Swift 桥接层包装，本脚本不做文件 IO、不依赖 stdout）
  - 桥接把输入 JSON 解析后注入模块全局变量 `kline_input`（dict）；
  - 本脚本定义模块级 dict `kline_result`，`kline_result["ok"]` 为 bool；
  - 脚本异常由包装统一捕获写 error 字段，因此不 try/except 包裹主逻辑，
    但对输入形状做防御：形状非法时直接返回 {"ok": False, "error": ...}。

op = "aggregate"（全量日线 → 周期线）
  输入: {"op":"aggregate","periods":["weekly","monthly","quarterly","yearly"],
         "series":[{"file":"SH#600000","daily":[[date,open,high,low,close,vol,amo],...]},...]}
  - daily 行为 7 元素数组，date 为 YYYYMMDD 整数，可能乱序，先按 date 升序再分桶。
  - 桶键 = 周期日历起始日 YYYYMMDD 整数：
      weekly    = 该日期所在周的周一（周一为一周起点，与地区设置无关）：
                  `dt - datetime.timedelta(days=dt.weekday())`。跨年周合并到周一
                  日期键：如 20241230(周一) 的周桶同时含 20241230/31 与 20250102/03，
                  01-01 停牌 → 周线 date=20241230 一根跨年。
      monthly   = YYYYMM01；
      quarterly = ((m-1)//3)*3+1 月的 1 日（如 3 月 → 20260101）；
      yearly    = YYYY0101。
  - 每桶产出（桶内按 date 升序）：date = 组内最早日线日期（不是桶键！周一停牌则
    date 是周内首个交易日）；open = 首行 open；high = max；low = min；
    close = 末行 close；vol = Σ；amo = Σ。
  - 停牌周期（桶内无任何日线）→ 不产行。输出行按 date 升序。
  - 输出值 6 位小数规整 round(v, 6)（vol 为整数值时保持数值即可）。

op = "merge"（基期 bar ⊕ 新日线，镜像 WatchlistSyncManager.mergePeriodBar）
  输入: {"op":"merge","periods":["quarterly","yearly"],
         "targets":[{"file":"SH#600000",
                     "daily":{"date":..,"open":..,"high":..,"low":..,"close":..,"vol":..,"amo":..},
                     "bases":{"quarterly":{...}|null,"yearly":{...}|null}},...]}
  - 每个 target × 每个 period：base 为 null（或缺 key）→ 结果 = daily 原样（含 file）；
    否则 date=base.date, open=base.open, high=max(base.high,daily.high),
    low=min(base.low,daily.low), close=daily.close, vol=base.vol+daily.vol,
    amo=base.amo+daily.amo。不做任何规整。
"""

import datetime

_KNOWN_PERIODS = ("weekly", "monthly", "quarterly", "yearly")
_FIELD_ORDER = ("date", "open", "high", "low", "close", "vol", "amo")


def _err(msg):
    return {"ok": False, "error": msg}


def _as_int(v):
    """镜像"输入应为 YYYYMMDD 整数"：接受 int（拒绝 bool）；float 仅整数值时接受。"""
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return None


def _as_num(v):
    """数值字段校验：接受 int/float（拒绝 bool）。"""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return v


def _int_to_date(n):
    y, r = divmod(n, 10000)
    m, d = divmod(r, 100)
    return datetime.date(y, m, d)


def _bucket_key(date_int, period):
    """桶键 = 周期日历起始日 YYYYMMDD 整数（见模块 docstring 的桶键规则）。"""
    dt = _int_to_date(date_int)
    if period == "weekly":
        mon = dt - datetime.timedelta(days=dt.weekday())  # 周一为一周起点
        return mon.year * 10000 + mon.month * 100 + mon.day
    if period == "monthly":
        return dt.year * 10000 + dt.month * 100 + 1
    if period == "quarterly":
        qm = ((dt.month - 1) // 3) * 3 + 1
        return dt.year * 10000 + qm * 100 + 1
    return dt.year * 10000 + 101  # yearly


def _check_periods(inp):
    """校验并去重 periods（保持输入顺序）。非法返回 None。"""
    periods = inp.get("periods")
    if not isinstance(periods, list) or not periods:
        return None
    seen = []
    for p in periods:
        if p not in _KNOWN_PERIODS:
            return None
        if p not in seen:
            seen.append(p)
    return seen


def _op_aggregate(inp):
    periods = _check_periods(inp)
    if periods is None:
        return _err("aggregate: periods 必须为非空数组且取值限于 %s" % (_KNOWN_PERIODS,))
    series = inp.get("series")
    if not isinstance(series, list):
        return _err("aggregate: series 必须为数组")
    result = {}
    for s in series:
        if not isinstance(s, dict):
            return _err("aggregate: series 元素必须为对象")
        file = s.get("file")
        if not isinstance(file, str) or not file:
            return _err("aggregate: series 元素缺少合法 file 字段")
        daily = s.get("daily")
        if not isinstance(daily, list):
            return _err("aggregate: %s 缺少 daily 数组" % file)
        rows = []
        for r in daily:
            if not isinstance(r, (list, tuple)) or len(r) < 7:
                return _err("aggregate: %s 日线行必须为 7 元素数组" % file)
            d = _as_int(r[0])
            if d is None:
                return _err("aggregate: %s 日线行 date 非法: %r" % (file, r[0]))
            try:
                _int_to_date(d)
            except ValueError:
                return _err("aggregate: %s 日线行 date 非法: %r" % (file, r[0]))
            vals = []
            for v in r[1:7]:
                n = _as_num(v)
                if n is None:
                    return _err("aggregate: %s 日线行数值字段非法: %r" % (file, v))
                vals.append(n)
            rows.append((d, vals[0], vals[1], vals[2], vals[3], vals[4], vals[5]))
        rows.sort(key=lambda x: x[0])  # 输入可能乱序，统一按 date 升序处理
        out_periods = {}
        for p in periods:
            groups = {}
            for row in rows:
                groups.setdefault(_bucket_key(row[0], p), []).append(row)
            bars = []
            for key in sorted(groups):
                g = groups[key]  # rows 已升序，append 顺序即桶内 date 升序
                bars.append([
                    g[0][0],                        # date = 组内最早日线日期（非桶键）
                    round(g[0][1], 6),              # open = 首行
                    round(max(x[2] for x in g), 6),  # high = max
                    round(min(x[3] for x in g), 6),  # low = min
                    round(g[-1][4], 6),             # close = 末行
                    round(sum(x[5] for x in g), 6),  # vol = Σ
                    round(sum(x[6] for x in g), 6),  # amo = Σ
                ])
            out_periods[p] = bars
        result[file] = out_periods
    return {"ok": True, "result": result}


def _check_bar(obj, required):
    """校验 merge 的 bar 对象：required 字段齐全且类型合法。非法返回 None。

    _as_int/_as_num 对合法值 0 返回 0（非 None），故 `v is None` 仅表示
    缺失或类型错误（含 bool）。
    """
    if not isinstance(obj, dict):
        return None
    out = {}
    for k in required:
        v = _as_int(obj.get(k)) if k == "date" else _as_num(obj.get(k))
        if v is None:
            return None
        out[k] = v
    return out


def _op_merge(inp):
    periods = _check_periods(inp)
    if periods is None:
        return _err("merge: periods 必须为非空数组且取值限于 %s" % (_KNOWN_PERIODS,))
    targets = inp.get("targets")
    if not isinstance(targets, list):
        return _err("merge: targets 必须为数组")
    result = {p: [] for p in periods}
    for t in targets:
        if not isinstance(t, dict):
            return _err("merge: targets 元素必须为对象")
        file = t.get("file")
        if not isinstance(file, str) or not file:
            return _err("merge: targets 元素缺少合法 file 字段")
        daily = _check_bar(t.get("daily"), _FIELD_ORDER)
        if daily is None:
            return _err("merge: %s 缺少合法 daily 对象（date/open/high/low/close/vol/amo）" % file)
        bases = t.get("bases")
        if bases is None:
            bases = {}
        if not isinstance(bases, dict):
            return _err("merge: %s 的 bases 必须为对象或 null" % file)
        for p in periods:
            base = bases.get(p)
            if base is None:
                # base 为 null → daily 原样透传（含 file），不做规整
                bar = {"file": file}
                for k in _FIELD_ORDER:
                    bar[k] = daily[k]
            else:
                base = _check_bar(base, ("date", "open", "high", "low", "vol", "amo"))
                if base is None:
                    return _err("merge: %s/%s 的 base 缺少合法字段（date/open/high/low/vol/amo）" % (file, p))
                # 镜像 WatchlistSyncManager.mergePeriodBar
                bar = {
                    "file": file,
                    "date": base["date"],
                    "open": base["open"],
                    "high": max(base["high"], daily["high"]),
                    "low": min(base["low"], daily["low"]),
                    "close": daily["close"],
                    "vol": base["vol"] + daily["vol"],
                    "amo": base["amo"] + daily["amo"],
                }
            result[p].append(bar)
    return {"ok": True, "result": result}


def _main():
    inp = globals().get("kline_input")
    if not isinstance(inp, dict):
        return _err("kline_input 未注入或不是对象")
    op = inp.get("op")
    if op == "aggregate":
        return _op_aggregate(inp)
    if op == "merge":
        return _op_merge(inp)
    return _err("未知 op: %r（仅支持 aggregate / merge）" % (op,))


kline_result = _main()

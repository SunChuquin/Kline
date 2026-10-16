# -*- coding: utf-8 -*-
# tdx_eval.py —— TDX 公式 DSL 的 Python 求值器（首帧引擎实验，2026-10-12）
#
# 定位：Kline 首帧指标计算下沉的引擎侧。Swift 侧保留 lexer/parser（TDXFormulaEngine）
# 与样式组装，本脚本只做**数值求值**：入参为已解析语句的 AST 序列化 + K线基础序列，
# 出参为各输出行的序列值（非有限值 → null，由 Swift 解码回 NaN）。
#
# 语义必须逐条镜像 Swift Kline/Forma/FormulaEngine.swift 的 TDXEvaluator（非增量路径）：
#   - 除法分母为 0 → 0（通达信语义，缺失数据区不得变 NaN）
#   - 比较运算 NaN 参与 → 0（Swift 三目 x<y?1:0 对 NaN 为 false）
#   - and/or/not：非零为真（NaN != 0 为真，与 Swift Double.nan != 0 == true 一致）
#   - EMA/SMA/DMA：递归指标遇 NaN 跳过该根（保持前值，不播种不推进），输出该根 NaN
#   - MA/HHV/LLV/SUM(N)/STD/COUNT/AVEDEV：窗口内跳过 NaN，窗口内无有效值 → NaN
#   - SUM(X,0)：NaN 根输出 NaN 且不推进累计
#   - SAR：抛物线转向状态机，输出红/绿方向数组
#   - BARSLAST：最近一次条件为真的距离，未命中 NaN
#
# 桥接契约（KlinePythonBridge 包装脚本）：全局作用域定义 dict 类型 kline_result，
# 顶层 ok==true 才算成功。纯标准库实现——**不 import numpy**（A8 上 numpy import ~2s，
# 且 150~2000 根规模下纯循环毫秒级，更快进入稳态）。
#
# 直读库对拍（阶段1，2026-10-12）：kline_input["db"] 存在时，Python 用 sqlite3 直读
# 主库+增量库组装 bars，与 Swift 传入的 input["bars"] 逐字段对拍，差异挂
# kline_result["audit"]（日志侧观测，不阻断求值——求值输入仍是 input["bars"]）。
# 必须镜像 Swift 语义（DatabaseManager.fetchPeriodTable / runBarsQuery / LiveDataStore.slice）：
#   - 主库 tdx.db：SELECT date,open,high,low,close,vol,amo FROM <表> WHERE meta_id=? ORDER BY date DESC
#   - 增量库 tdx_live.db：SELECT ... FROM live_<表> WHERE file=? ORDER BY date DESC；vol/amo 非浮点→0
#   - 合并：增量全部行 ∪ 主库「增量没有的 date」；同 date 增量优先；整体 date 降序
#   - 增量库缺失/缺表/未覆盖该 file/无行 → 纯主库

import json
import math
import sqlite3
import traceback

_NAN = float("nan")


class TDxEvalError(Exception):
    """求值错误（语法/语义，文案与 Swift TDXEngineError 对齐便于排查）"""


def _scalar(seq):
    """参数里的序列取末值（与 Swift TDXEvaluator.scalar 一致：空序列 → 0）"""
    return seq[-1] if seq else 0.0


def _binary(op, a, b):
    """逐元素二元运算，输入均为等长序列（与 Swift TDXEvaluator.binary 一致）"""
    n = len(a)
    out = [0.0] * n
    for i in range(n):
        x = a[i]
        y = b[i]
        if op == "+":
            out[i] = x + y
        elif op == "-":
            out[i] = x - y
        elif op == "*":
            out[i] = x * y
        elif op == "/":
            # 通达信语义：除零结果为 0（否则缺失数据区会变成 NaN）
            out[i] = 0.0 if y == 0 else x / y
        elif op == "<":
            out[i] = 1.0 if x < y else 0.0
        elif op == ">":
            out[i] = 1.0 if x > y else 0.0
        elif op == "<=":
            out[i] = 1.0 if x <= y else 0.0
        elif op == ">=":
            out[i] = 1.0 if x >= y else 0.0
        elif op == "==":
            out[i] = 1.0 if x == y else 0.0
        elif op == "!=":
            out[i] = 1.0 if x != y else 0.0
        elif op == "and":
            out[i] = 1.0 if (x != 0 and y != 0) else 0.0
        elif op == "or":
            out[i] = 1.0 if (x != 0 or y != 0) else 0.0
        else:
            raise TDxEvalError("未知二元运算 '%s'" % op)
    return out


def _ma(seq, period):
    n = len(seq)
    out = [_NAN] * n
    if period <= 0:
        return out
    for i in range(n):
        start = max(0, i - period + 1)
        s = 0.0
        cnt = 0
        for j in range(start, i + 1):
            v = seq[j]
            if not math.isnan(v):
                s += v
                cnt += 1
        if cnt > 0:
            out[i] = s / cnt
    return out


def _ema(seq, period):
    # 通达信 EMA(X,N) = (2*X + (N-1)*Y')/(N+1)，平滑系数 2/(N+1)；NaN 跳过（保持前值）
    n = len(seq)
    out = [_NAN] * n
    if period <= 0:
        return out
    k = 2.0 / (period + 1.0)
    prev = None
    for i in range(n):
        v = seq[i]
        if math.isnan(v):
            continue
        if prev is None:
            out[i] = v
            prev = v
        else:
            cur = v * k + prev * (1.0 - k)
            out[i] = cur
            prev = cur
    return out


def _sma(seq, period, m):
    # SMA(X,N,M) = (M*X + (N-M)*PREV) / N；NaN 跳过
    n = len(seq)
    out = [_NAN] * n
    if period <= 0:
        return out
    prev = None
    for i in range(n):
        v = seq[i]
        if math.isnan(v):
            continue
        if prev is None:
            out[i] = v
            prev = v
        else:
            cur = (m * v + (period - m) * prev) / period
            out[i] = cur
            prev = cur
    return out


def _dma(seq, a):
    # DMA(X,A)：Y = A*X + (1-A)*Y'，A 为逐根权重序列；X 或 A 为 NaN 跳过
    n = len(seq)
    out = [_NAN] * n
    prev = None
    for i in range(n):
        v = seq[i]
        alpha = a[i]
        if math.isnan(v) or math.isnan(alpha):
            continue
        if prev is None:
            out[i] = v
            prev = v
        else:
            cur = alpha * v + (1.0 - alpha) * prev
            out[i] = cur
            prev = cur
    return out


def _ref(seq, n):
    out = [_NAN] * len(seq)
    for i in range(len(seq)):
        src = i - n
        if src >= 0:
            out[i] = seq[src]
    return out


def _rolling(seq, period, kind):
    # HHV/LLV/SUM(N)/STD/COUNT 共用：窗口内跳过 NaN，无有效值 → NaN
    n = len(seq)
    out = [_NAN] * n
    if period <= 0:
        return out
    for i in range(n):
        start = max(0, i - period + 1)
        s = 0.0
        cnt = 0
        mn = float("inf")
        mx = float("-inf")
        s2 = 0.0
        for j in range(start, i + 1):
            v = seq[j]
            if math.isnan(v):
                continue
            s += v
            cnt += 1
            s2 += v * v
            if v < mn:
                mn = v
            if v > mx:
                mx = v
        if cnt <= 0:
            continue
        if kind == "max":
            out[i] = mx
        elif kind == "min":
            out[i] = mn
        elif kind == "sum":
            out[i] = s
        elif kind == "count":
            out[i] = float(cnt)
        elif kind == "std":
            mean = s / cnt
            variance = max(0.0, s2 / cnt - mean * mean)
            out[i] = math.sqrt(variance)
    return out


def _total(seq):
    # SUM(X,0)：从第一天起的全量累计；NaN 根输出 NaN 且不推进
    out = [0.0] * len(seq)
    s = 0.0
    for i, v in enumerate(seq):
        if math.isnan(v):
            out[i] = _NAN
            continue
        s += v
        out[i] = s
    return out


def _avedev(seq, period):
    n = len(seq)
    out = [_NAN] * n
    if period <= 0:
        return out
    for i in range(n):
        start = max(0, i - period + 1)
        s = 0.0
        cnt = 0
        for j in range(start, i + 1):
            v = seq[j]
            if not math.isnan(v):
                s += v
                cnt += 1
        if cnt <= 0:
            continue
        mean = s / cnt
        dev = 0.0
        for j in range(start, i + 1):
            v = seq[j]
            if not math.isnan(v):
                dev += abs(v - mean)
        out[i] = dev / cnt
    return out


def _sar(highs, lows, step, max_step):
    # 抛物线转向 SAR，输出 (值, 红/绿方向)；镜像 Swift TDXEvaluator.sar
    count = min(len(highs), len(lows))
    out = [_NAN] * count
    up = [True] * count
    if count <= 1:
        return out, up
    is_up = True
    af = step
    extreme = highs[0]
    sar_val = lows[0]
    out[0] = sar_val
    up[0] = is_up
    for i in range(1, count):
        prev = out[i - 1]
        if is_up:
            sar_val = prev + af * (extreme - prev)
            sar_val = min(sar_val, lows[i - 1])
        else:
            sar_val = prev + af * (extreme - prev)
            sar_val = max(sar_val, highs[i - 1])
        out[i] = sar_val
        if is_up and lows[i] < sar_val:
            is_up = False
            out[i] = extreme
            extreme = lows[i]
            af = step
        elif (not is_up) and highs[i] > sar_val:
            is_up = True
            out[i] = extreme
            extreme = highs[i]
            af = step
        else:
            if is_up:
                if highs[i] > extreme:
                    extreme = highs[i]
                    af = min(af + step, max_step)
            else:
                if lows[i] < extreme:
                    extreme = lows[i]
                    af = min(af + step, max_step)
        up[i] = is_up
    return out, up


def _barslast(cond):
    n = len(cond)
    out = [_NAN] * n
    last = None
    for g in range(n):
        if cond[g] != 0:
            last = g
        out[g] = float(g - last) if last is not None else _NAN
    return out


def _cross(a, b):
    n = len(a)
    out = [0.0] * n
    for i in range(n):
        if i == 0:
            out[i] = 1.0 if a[i] > b[i] else 0.0
        else:
            out[i] = 1.0 if (a[i - 1] <= b[i - 1] and a[i] > b[i]) else 0.0
    return out


def _eval_call(fn, vals, builtins):
    """函数求值。vals 为各参数的完整序列。镜像 Swift TDXEvaluator.evalCall"""
    def need(k):
        if len(vals) < k:
            raise TDxEvalError("函数 %s 至少需要 %d 个参数" % (fn, k))

    if fn == "MA":
        need(2)
        return _ma(vals[0], int(_scalar(vals[1])))
    if fn == "EMA":
        need(2)
        return _ema(vals[0], int(_scalar(vals[1])))
    if fn == "SMA":
        need(3)
        return _sma(vals[0], int(_scalar(vals[1])), _scalar(vals[2]))
    if fn == "DMA":
        need(2)
        return _dma(vals[0], vals[1])
    if fn == "MEMA":
        # 通达信 MEMA(X,N) = (X + (N-1)*Y')/N = SMA(X,N,1)
        need(2)
        return _sma(vals[0], int(_scalar(vals[1])), 1.0)
    if fn == "REF":
        need(2)
        return _ref(vals[0], int(_scalar(vals[1])))
    if fn == "HHV":
        need(2)
        return _rolling(vals[0], int(_scalar(vals[1])), "max")
    if fn == "LLV":
        need(2)
        return _rolling(vals[0], int(_scalar(vals[1])), "min")
    if fn == "ABS":
        need(1)
        return [abs(v) for v in vals[0]]
    if fn == "MAX":
        need(2)
        return [max(x, y) for x, y in zip(vals[0], vals[1])]
    if fn == "MIN":
        need(2)
        return [min(x, y) for x, y in zip(vals[0], vals[1])]
    if fn == "SUM":
        need(2)
        period = int(_scalar(vals[1]))
        if period <= 0:
            return _total(vals[0])
        return _rolling(vals[0], period, "sum")
    if fn == "AVEDEV":
        need(2)
        return _avedev(vals[0], int(_scalar(vals[1])))
    if fn == "SAR":
        need(2)
        return _sar(builtins["H"], builtins["L"], _scalar(vals[0]), _scalar(vals[1]))
    if fn == "STD":
        need(2)
        return _rolling(vals[0], int(_scalar(vals[1])), "std")
    if fn == "COUNT":
        need(2)
        return _rolling(vals[0], int(_scalar(vals[1])), "count")
    if fn == "IF":
        need(3)
        return [a if c != 0 else b for c, a, b in zip(vals[0], vals[1], vals[2])]
    if fn == "CROSS":
        need(2)
        return _cross(vals[0], vals[1])
    if fn == "BARSLAST":
        need(1)
        return _barslast(vals[0])
    if fn == "AND":
        need(2)
        return [1.0 if (x != 0 and y != 0) else 0.0 for x, y in zip(vals[0], vals[1])]
    if fn == "OR":
        need(2)
        return [1.0 if (x != 0 or y != 0) else 0.0 for x, y in zip(vals[0], vals[1])]
    if fn == "NOT":
        need(1)
        return [0.0 if v != 0 else 1.0 for v in vals[0]]
    raise TDxEvalError("不支持的函数：'%s'" % fn)


def _eval_expr(e, vars_map, builtins, sar_box):
    """AST 求值，返回完整序列。sar_box 为单元素列表承载 SAR 方向（镜像 Swift sarDirection）"""
    t = e["t"]
    n = len(builtins["C"])
    if t == "num":
        return [float(e["v"])] * n
    if t == "var":
        key = e["n"].upper()
        if key in vars_map:
            return vars_map[key]
        if key in builtins:
            return builtins[key]
        raise TDxEvalError("未定义的变量或函数：'%s'" % e["n"])
    if t == "un":
        a = _eval_expr(e["x"], vars_map, builtins, sar_box)
        op = e["op"]
        if op == "-":
            return [-v for v in a]
        if op == "not":
            return [0.0 if v != 0 else 1.0 for v in a]
        raise TDxEvalError("未知一元运算 '%s'" % op)
    if t == "bin":
        a = _eval_expr(e["l"], vars_map, builtins, sar_box)
        b = _eval_expr(e["r"], vars_map, builtins, sar_box)
        return _binary(e["op"], a, b)
    if t == "call":
        fn = e["fn"].upper()
        vals = [_eval_expr(arg, vars_map, builtins, sar_box) for arg in e["args"]]
        r = _eval_call(fn, vals, builtins)
        if fn == "SAR":
            values, dirs = r
            sar_box[0] = dirs
            return values
        return r
    raise TDxEvalError("未知表达式节点 '%s'" % t)


def _finite_to_null(values):
    """非有限值（NaN/Inf）→ None，保证 JSON 合法（Swift 解码回 NaN）"""
    out = []
    for v in values:
        if isinstance(v, float) and not math.isfinite(v):
            out.append(None)
        else:
            out.append(float(v))
    return out


# ---- 直读库对拍（阶段1）----

_FIELDS = ("o", "h", "l", "c", "v", "a")  # bar dict 键（与输入六序列对应）


def _query_rows(conn, sql, param):
    """返回 [(date, open, high, low, close, vol, amo)]；表缺失/查询失败 → None（调用方回落）"""
    try:
        cur = conn.execute(sql, param)
        return cur.fetchall()
    except sqlite3.OperationalError:
        return None  # 多为 no such table


def _rows_to_bars(rows, live_style):
    """行 → bar dict 列表。NULL→0.0（镜像 Swift sqlite3_column_double 对 NULL 返回 0.0）；
    live_style=True 时 vol/amo 非浮点 → 0（镜像 LiveDataStore.slice）"""
    bars = []
    for r in rows:
        date, o, h, l, c, vol, amo = r
        vals = [0.0 if v is None else float(v) for v in (o, h, l, c)]
        if live_style:
            vol = vol if isinstance(vol, float) else 0.0
            amo = amo if isinstance(amo, float) else 0.0
        else:
            vol = 0.0 if vol is None else float(vol)
            amo = 0.0 if amo is None else float(amo)
        bars.append({"date": int(date), "o": vals[0], "h": vals[1], "l": vals[2],
                     "c": vals[3], "v": float(vol), "a": float(amo)})
    return bars


def _resolve_file(main_path, meta_id):
    """主库 meta 表 file ↔ meta_id 映射（file 全库唯一）；查不到 → None"""
    conn = sqlite3.connect(main_path)
    try:
        cur = conn.execute("SELECT file FROM meta WHERE id = ?", (meta_id,))
        row = cur.fetchone()
        return row[0] if row else None
    except sqlite3.OperationalError:
        return None
    finally:
        conn.close()


def load_bars_from_db(cfg):
    """按 Swift fetchPeriodTable 语义组装 bars。
    cfg: {main, live|null, meta_id, table, file|null}。返回 (bars, note)"""
    main_path = cfg["main"]
    table = cfg["table"]
    if table not in ("daily", "weekly", "monthly", "quarterly", "yearly"):
        raise TDxEvalError("非法周期表名 '%s'" % table)
    note = "main"
    # 增量库：缺失/缺表/未覆盖/无行 → 纯主库（镜像「走纯主库路径」）
    live_bars = None
    live_path = cfg.get("live")
    if live_path and cfg.get("file"):
        try:
            conn = sqlite3.connect(live_path)
            try:
                rows = _query_rows(conn, "SELECT date, open, high, low, close, vol, amo FROM live_%s "
                                         "WHERE file = ? ORDER BY date DESC" % table, (cfg["file"],))
                if rows:
                    live_bars = _rows_to_bars(rows, live_style=True)
                    note = "live+main"
            finally:
                conn.close()
        except sqlite3.Error:
            live_bars = None  # 打不开 → 纯主库

    conn = sqlite3.connect(main_path)
    try:
        rows = _query_rows(conn, "SELECT date, open, high, low, close, vol, amo FROM %s "
                                 "WHERE meta_id = ? ORDER BY date DESC" % table, (cfg["meta_id"],))
        main_bars = _rows_to_bars(rows, live_style=False) if rows else []
    finally:
        conn.close()

    if not live_bars:
        return main_bars, ("live-none" if live_bars is not None else note)
    # 合并：增量全部行 ∪ 主库「增量没有的 date」；同 date 增量优先；整体 date 降序
    live_dates = {b["date"] for b in live_bars}
    merged = live_bars + [b for b in main_bars if b["date"] not in live_dates]
    merged.sort(key=lambda b: -b["date"])
    return merged, "live+main"


def audit_bars(db_bars, swift_bars):
    """逐字段对拍（容差 1e-9）。返回 audit dict；equal=true 表示读库组装与 Swift 内存完全一致"""
    tol = 1e-9
    n = min(len(db_bars), len(swift_bars))
    first_diff = None
    for i in range(n):
        d, s = db_bars[i], swift_bars[i]
        if d["date"] != s["date"]:
            first_diff = {"idx": i, "field": "date", "db": d["date"], "swift": s["date"]}
            break
        for f in _FIELDS:
            x, y = d[f], s[f]
            if not (abs(x - y) <= tol or (math.isnan(x) and math.isnan(y))):
                first_diff = {"idx": i, "field": f, "db": x, "swift": y}
                break
        if first_diff:
            break
    equal = first_diff is None and len(db_bars) == len(swift_bars)
    if first_diff is None and len(db_bars) != len(swift_bars):
        first_diff = {"idx": n, "field": "count", "db": len(db_bars), "swift": len(swift_bars)}
    audit = {"db_rows": len(db_bars), "swift_rows": len(swift_bars), "equal": equal}
    if first_diff:
        # 值字符串化：NaN 无法过 JSONSerialization（Swift 端会整体解析失败丢日志）
        audit["first_diff"] = {"idx": first_diff["idx"], "field": first_diff["field"],
                               "db": str(first_diff["db"]), "swift": str(first_diff["swift"])}
    if db_bars:
        audit["date_span"] = [db_bars[-1]["date"], db_bars[0]["date"]]
    return audit


def _make_builtins(bars):
    """K 线基础序列 → 求值内置变量表。每调用构造一次，供本批所有单元共享
    （避免 per-unit 重复 float 化整段序列——A8 上为热路径主要开销之一）。"""
    closes = [float(x) for x in bars["c"]]
    return {
        "C": closes, "CLOSE": closes,
        "H": [float(x) for x in bars["h"]], "HIGH": [float(x) for x in bars["h"]],
        "L": [float(x) for x in bars["l"]], "LOW": [float(x) for x in bars["l"]],
        "O": [float(x) for x in bars["o"]], "OPEN": [float(x) for x in bars["o"]],
        "V": [float(x) for x in bars["v"]], "VOL": [float(x) for x in bars["v"]],
        "AMOUNT": [float(x) for x in bars["a"]],
    }


def run(kline_input):
    """桥接入口：入参 {bars, requests[, db]} → {ok, results[, audit]}。
    requests 与 results 按下标对齐；db 存在时附带读库对拍 audit（不影响求值输入）"""
    bars = kline_input["bars"]
    builtins = _make_builtins(bars)
    audit = None
    db_cfg = kline_input.get("db")
    if db_cfg:
        try:
            if not db_cfg.get("file"):
                db_cfg["file"] = _resolve_file(db_cfg["main"], db_cfg["meta_id"])
            db_bars, note = load_bars_from_db(db_cfg)
            # Swift 传入的是 calcData **切片**：按切片日期逐位对齐（不假设切片方向），
            # 库中缺失的日期（实时 bar 等）记为 diff——这正是阶段1要观测的对象
            dates = db_cfg.get("dates")
            n = len(bars["c"])
            swift_bars = [{"date": 0, "o": bars["o"][i], "h": bars["h"][i],
                           "l": bars["l"][i], "c": bars["c"][i],
                           "v": bars["v"][i], "a": bars["a"][i]}
                          for i in range(n)]
            if isinstance(dates, list) and len(dates) == n:
                # Swift sortedData 为**升序**（老→新）；db 查询为 DESC。按切片日期精确对齐，
                # 库中缺失的日期（实时 bar 等）记为 diff——这正是阶段1要观测的对象
                for i in range(n):
                    swift_bars[i]["date"] = int(dates[i])
                by_date = {b["date"]: b for b in db_bars}
                db_aligned = []
                for i in range(n):
                    d = int(dates[i])
                    db_aligned.append(by_date.get(d) or
                                      {"date": d, "o": _NAN, "h": _NAN, "l": _NAN,
                                       "c": _NAN, "v": _NAN, "a": _NAN})
                audit = audit_bars(db_aligned, swift_bars)
            else:
                audit = audit_bars(db_bars, swift_bars)
            audit["source"] = note
        except Exception as exc:  # 对拍失败不阻断求值
            audit = {"equal": None, "error": "%s: %s" % (type(exc).__name__, exc)}
    results = []
    use_bin = bool(kline_input.get("__bin__"))
    bin_out = {} if use_bin else None
    for idx, req in enumerate(kline_input["requests"]):
        try:
            vars_map = {}
            lines = []
            for st in req["stmts"]:
                sar_box = [None]
                value = _eval_expr(st["e"], vars_map, builtins, sar_box)
                vars_map[st["n"].upper()] = value
                if st.get("o"):
                    if use_bin:
                        # bin 模式：输出序列走 __bin_out__（二进制一次拷贝），行内只留键。
                        # 非有限值统一映射为 NaN（与 JSON 路径 null→NaN 语义对齐，Inf 不直传）
                        key = "r%dl%d" % (idx, len(lines))
                        bin_out[key] = [_NAN if isinstance(x, float) and not math.isfinite(x)
                                        else float(x) for x in value]
                        line = {"n": st["n"], "b": key}
                    else:
                        line = {"n": st["n"], "v": _finite_to_null(value)}
                    if st["e"]["t"] == "call" and st["e"]["fn"].upper() == "SAR" and sar_box[0] is not None:
                        line["d"] = [1 if d else 0 for d in sar_box[0]]
                    lines.append(line)
            if not lines:
                raise TDxEvalError("公式没有输出行（至少需要一行以 ':' 输出的指标）")
            results.append({"id": idx, "ok": True, "lines": lines})
        except Exception as exc:  # 单请求失败不拖垮整批
            results.append({"id": idx, "ok": False, "lines": [],
                            "error": "%s: %s" % (type(exc).__name__, exc)})
    out = {"ok": True, "results": results}
    if use_bin:
        out["__bin_out__"] = bin_out
    if audit is not None:
        out["audit"] = audit  # 阶段1对拍：只观测，不阻断求值
    return out


# ==================== 公式文本解析下沉（2026-10-16，Swift TDXLexer/TDXParser 移植） ====================
# 语义必须逐条镜像 Swift FormulaEngine.swift 的 TDXLexer/TDXParser/splitOutputUnits/stmtText/exprText：
#   - 错误文案逐字一致（Swift 编辑器直接显示 Python 解析错误）
#   - AST 按公式文本缓存（跨调用持久，挂 __main__——包装脚本每次 exec 用新命名空间，
#     但 PyRun_SimpleString 的真 __main__ 跨调用持久）
#   - text_split：公式文本 → 每输出行单元 [{name, text}]（依赖闭包 + 输出行，单元文本可独立解析求值）
#   - text_eval：单元文本 → 输出行（单元级错误隔离——单行求值失败不拖垮同公式其余行，
#     镜像 Swift 逐单元 evaluate 的占位语义）

class TDxParseError(Exception):
    """语法错误（文案与 Swift TDXEngineError.syntax 逐字一致）"""


# ---------- 词法（TDXLexer 移植） ----------

def _tokenize(src):
    """源码 → token 列表。token: (kind, value)；kind ∈
    num/id/plus/minus/star/slash/assign/assignout/semi/comma/lp/rp/lt/gt/le/ge/eq/ne"""
    chars = src
    pos = 0
    n = len(chars)
    toks = []

    def peek():
        return chars[pos] if pos < n else None

    while True:
        # skipWhitespaceAndComments
        while pos < n:
            c = chars[pos]
            if c.isspace():
                pos += 1
            elif c == "{":
                while pos < n and chars[pos] != "}":
                    pos += 1
                if pos < n:
                    pos += 1
            else:
                break
        if pos >= n:
            break
        c = chars[pos]
        # 数字（.5 也算）
        if c.isdigit() or (c == "." and pos + 1 < n and chars[pos + 1].isdigit()):
            s = ""
            while pos < n and (chars[pos].isdigit() or chars[pos] == "."):
                s += chars[pos]
                pos += 1
            try:
                toks.append(("num", float(s)))
            except ValueError:
                toks.append(("num", 0.0))  # Swift Double(s) ?? 0
            continue
        # 标识符
        if c.isalpha() or c == "_":
            s = ""
            while pos < n and (chars[pos].isalnum() or chars[pos] == "_"):
                s += chars[pos]
                pos += 1
            toks.append(("id", s))
            continue
        pos += 1
        if c == "+":
            toks.append(("plus", None))
        elif c == "-":
            toks.append(("minus", None))
        elif c == "*":
            toks.append(("star", None))
        elif c == "/":
            toks.append(("slash", None))
        elif c == ";":
            toks.append(("semi", None))
        elif c == ",":
            toks.append(("comma", None))
        elif c == "(":
            toks.append(("lp", None))
        elif c == ")":
            toks.append(("rp", None))
        elif c == "<":
            if peek() == "=":
                pos += 1
                toks.append(("le", None))
            elif peek() == ">":
                pos += 1
                toks.append(("ne", None))
            else:
                toks.append(("lt", None))
        elif c == ">":
            if peek() == "=":
                pos += 1
                toks.append(("ge", None))
            else:
                toks.append(("gt", None))
        elif c == "=":
            if peek() == "=":
                pos += 1
            toks.append(("eq", None))  # 单个 "=" 也是相等比较
        elif c == ":":
            if peek() == "=":
                pos += 1
                toks.append(("assign", None))   # :=
            else:
                toks.append(("assignout", None))  # :
        else:
            raise TDxParseError("无法识别的字符 '%s'" % c)
    return toks


# ---------- 语法（TDXParser 移植；AST 为 dict，与 _eval_expr 的 JSON 格式完全一致） ----------
# AST 节点：{"t":"num","v":..} | {"t":"var","n":..} | {"t":"un","op":..,"x":..}
#          | {"t":"bin","op":..,"l":..,"r":..} | {"t":"call","fn":..,"args":[..]}
# 语句：{"n": 名, "o": 是否输出, "e": AST, "opts": [选项]}

class _Parser:
    def __init__(self, toks):
        self.toks = toks
        self.pos = 0

    def parse(self):
        stmts = []
        while not self.at_end():
            stmts.append(self.parse_statement())
            while self.match("comma"):   # 容错：语句后孤立逗号
                pass
            self.match("semi")           # 语句间允许 0 或 1 个分号
        return stmts

    def parse_statement(self):
        name = self.consume_identifier("期望指标名称")
        if self.match("assignout"):
            expr = self.parse_expr()
            opts = []
            while self.match("comma"):
                if self.peek() and self.peek()[0] == "id":
                    opts.append(self.toks[self.pos][1])
                    self.pos += 1
                else:
                    break
            return {"n": name, "o": True, "e": expr, "opts": opts}
        if self.match("assign"):
            return {"n": name, "o": False, "e": self.parse_expr(), "opts": []}
        raise TDxParseError("指标 '%s' 后缺少 ':' 或 ':='" % name)

    def parse_expr(self):
        return self.parse_or()

    def parse_or(self):
        lhs = self.parse_and()
        while self.match_identifier("OR"):
            lhs = {"t": "bin", "op": "or", "l": lhs, "r": self.parse_and()}
        return lhs

    def parse_and(self):
        lhs = self.parse_not()
        while self.match_identifier("AND"):
            lhs = {"t": "bin", "op": "and", "l": lhs, "r": self.parse_not()}
        return lhs

    def parse_not(self):
        if self.match_identifier("NOT"):
            return {"t": "un", "op": "not", "x": self.parse_not()}
        return self.parse_comparison()

    def parse_comparison(self):
        lhs = self.parse_additive()
        while True:
            for kind, op in (("lt", "<"), ("gt", ">"), ("le", "<="),
                             ("ge", ">="), ("eq", "=="), ("ne", "!=")):
                if self.match(kind):
                    lhs = {"t": "bin", "op": op, "l": lhs, "r": self.parse_additive()}
                    break
            else:
                return lhs

    def parse_additive(self):
        lhs = self.parse_multiplicative()
        while True:
            if self.match("plus"):
                lhs = {"t": "bin", "op": "+", "l": lhs, "r": self.parse_multiplicative()}
            elif self.match("minus"):
                lhs = {"t": "bin", "op": "-", "l": lhs, "r": self.parse_multiplicative()}
            else:
                return lhs

    def parse_multiplicative(self):
        lhs = self.parse_unary()
        while True:
            if self.match("star"):
                lhs = {"t": "bin", "op": "*", "l": lhs, "r": self.parse_unary()}
            elif self.match("slash"):
                lhs = {"t": "bin", "op": "/", "l": lhs, "r": self.parse_unary()}
            elif self._implicit_mul_start():
                lhs = {"t": "bin", "op": "*", "l": lhs, "r": self.parse_unary()}  # 通达信隐式乘法
            else:
                return lhs

    def _implicit_mul_start(self):
        t = self.peek()
        if t is None:
            return False
        kind, val = t
        if kind == "id":
            up = val.upper()
            return up not in ("AND", "OR", "NOT")
        return kind in ("num", "lp")

    def parse_unary(self):
        if self.match("minus"):
            return {"t": "un", "op": "-", "x": self.parse_unary()}
        return self.parse_primary()

    def parse_primary(self):
        if self.at_end():
            raise TDxParseError("表达式不完整")
        kind, val = self.toks[self.pos]
        if kind == "num":
            self.pos += 1
            return {"t": "num", "v": val}
        if kind == "id":
            self.pos += 1
            if self.match("lp"):
                args = []
                if not self.check("rp"):
                    args.append(self.parse_expr())
                    while self.match("comma"):
                        args.append(self.parse_expr())
                self.consume("rp", "函数 '%s' 缺少右括号 ')'" % val)
                return {"t": "call", "fn": val, "args": args}
            return {"t": "var", "n": val}
        if kind == "lp":
            self.pos += 1
            e = self.parse_expr()
            self.consume("rp", "缺少右括号 ')'")
            return e
        raise TDxParseError("非法的表达式起始符")

    # ---- 工具 ----
    def at_end(self):
        return self.pos >= len(self.toks)

    def peek(self):
        return self.toks[self.pos] if self.pos < len(self.toks) else None

    def check(self, kind):
        t = self.peek()
        return t is not None and t[0] == kind

    def match(self, kind):
        if self.check(kind):
            self.pos += 1
            return True
        return False

    def match_identifier(self, name):
        t = self.peek()
        if t is not None and t[0] == "id" and t[1].upper() == name:
            self.pos += 1
            return True
        return False

    def consume(self, kind, msg):
        if not self.match(kind):
            raise TDxParseError(msg)

    def consume_identifier(self, msg):
        t = self.peek()
        if t is None or t[0] != "id":
            raise TDxParseError(msg)
        self.pos += 1
        return t[1]


# ---------- 单元拆分（splitOutputUnits 移植） ----------

def _collect_vars(e, into):
    t = e["t"]
    if t == "var":
        into.add(e["n"].upper())
    elif t == "un":
        _collect_vars(e["x"], into)
    elif t == "bin":
        _collect_vars(e["l"], into)
        _collect_vars(e["r"], into)
    elif t == "call":
        for a in e["args"]:
            _collect_vars(a, into)


def _expr_text(e):
    t = e["t"]
    if t == "num":
        v = e["v"]
        return "%.0f" % v if v == round(v) else "%g" % v
    if t == "var":
        return e["n"]
    if t == "un":
        return e["op"] + _expr_text(e["x"])
    if t == "bin":
        op = e["op"]
        sym = " AND " if op == "and" else (" OR " if op == "or" else " %s " % op)
        return "(" + _expr_text(e["l"]) + sym + _expr_text(e["r"]) + ")"
    # call
    return e["fn"] + "(" + ",".join(_expr_text(a) for a in e["args"]) + ")"


def _stmt_text(s):
    t = s["n"] + (":" if s["o"] else ":=") + _expr_text(s["e"])
    if s["o"] and s["opts"]:
        t += "," + ",".join(s["opts"])
    return t + ";"


def _parse_formula(text):
    toks = _tokenize(text)
    if not toks:
        raise TDxParseError("公式为空")
    stmts = _Parser(toks).parse()
    if not stmts:
        raise TDxParseError("公式为空")
    return stmts


def _split_units(stmts):
    stmt_map = {}
    for st in stmts:
        stmt_map[st["n"].upper()] = st
    units = []
    for st in stmts:
        if not st["o"]:
            continue
        needed = set()
        _collect_vars(st["e"], into=needed)
        queue = set(needed)
        processed = set()
        while queue:
            name = queue.pop()
            if name in processed:
                continue
            processed.add(name)
            s = stmt_map.get(name)
            if s is None:
                continue
            deps = set()
            _collect_vars(s["e"], into=deps)
            for d in deps:
                if d in stmt_map and d not in needed:
                    needed.add(d)
                    queue.add(d)
        sub = [s for s in stmts if s["n"].upper() in needed]
        sub.append(st)
        units.append({"name": st["n"], "stmts": sub, "text": "".join(_stmt_text(s) for s in sub)})
    if not units:
        raise TDxParseError("公式没有输出行（至少需要一行以 ':' 输出的指标）")
    return units


# ---------- AST 缓存（跨调用持久，挂真 __main__） ----------

def _ast_cache():
    import __main__ as _km
    try:
        return _km._ktdx_ast_cache
    except AttributeError:
        c = {}
        _km._ktdx_ast_cache = c
        return c


def _parse_cached(text):
    cache = _ast_cache()
    got = cache.get(text)
    if got is None:
        got = _parse_formula(text)
        cache[text] = got
    return got


def _split_cached(text):
    cache = _ast_cache()
    key = "\x01split\x01" + text
    got = cache.get(key)
    if got is None:
        got = _split_units(_parse_cached(text))
        cache[key] = got
    return got


# ---------- text op 分发 ----------

def _eval_unit_text(unit_stmts, builtins, bin_out=None, ridx=0, uidx=0):
    """单元语句序列求值 → 输出行（单元级错误隔离）。
    builtins 由 _run_text 每调用构造一次传入（本批所有单元共享，不再 per-unit 重建）。
    bin_out 非 None 时大数组走 __bin_out__（行内只留键 "b"），否则 JSON 内联 "v"。"""
    vars_map = {}
    lines = []
    for st in unit_stmts:
        sar_box = [None]
        value = _eval_expr(st["e"], vars_map, builtins, sar_box)
        vars_map[st["n"].upper()] = value
        if st.get("o"):
            if bin_out is not None:
                key = "r%du%dl%d" % (ridx, uidx, len(lines))
                bin_out[key] = [_NAN if isinstance(x, float) and not math.isfinite(x)
                                else float(x) for x in value]
                line = {"n": st["n"], "b": key, "opts": st.get("opts", [])}
            else:
                line = {"n": st["n"], "v": _finite_to_null(value), "opts": st.get("opts", [])}
            if st["e"]["t"] == "call" and st["e"]["fn"].upper() == "SAR" and sar_box[0] is not None:
                line["d"] = [1 if d else 0 for d in sar_box[0]]
            lines.append(line)
    return lines


def _run_text(kline_input):
    """text op 入口：kline_input["texts"] = [{"id": i, "text": s}]；kline_input["mode"] = "split"|"eval"
    split → results[i] = {id, ok, units:[{name, text}]}
    eval  → results[i] = {id, ok, units:[{name, text, ok, lines, error?}]}（单元级错误隔离）
    bars 走零拷贝（kline_input["bars"] 由包装脚本注入 ctypes 视图）。
    __bin__ 置位时 eval 的大数组走 __bin_out__ 二进制回传（省 JSON 文本化）；split 结构不变。"""
    bars = kline_input["bars"]
    mode = kline_input.get("mode", "eval")
    use_bin = bool(kline_input.get("__bin__")) and mode != "split"
    builtins = _make_builtins(bars) if mode != "split" else None
    bin_out = {} if use_bin else None
    results = []
    for req in kline_input["texts"]:
        idx = req["id"]
        text = req["text"]
        try:
            if mode == "split":
                units = [{"name": u["name"], "text": u["text"]} for u in _split_cached(text)]
                results.append({"id": idx, "ok": True, "units": units})
            else:
                out_units = []
                for ui, u in enumerate(_split_cached(text)):
                    try:
                        lines = _eval_unit_text(u["stmts"], builtins, bin_out, idx, ui)
                        out_units.append({"name": u["name"], "text": u["text"],
                                          "ok": True, "lines": lines})
                    except Exception as exc:  # 单元级错误隔离（镜像 Swift 逐单元 try?）
                        out_units.append({"name": u["name"], "text": u["text"], "ok": False,
                                          "lines": [],
                                          "error": "%s: %s" % (type(exc).__name__, exc)})
                results.append({"id": idx, "ok": True, "units": out_units})
        except Exception as exc:  # 整公式解析失败
            results.append({"id": idx, "ok": False, "units": [],
                            "error": str(exc)})
    out = {"ok": True, "results": results}
    if bin_out is not None:
        out["__bin_out__"] = bin_out
    return out


try:
    if kline_input.get("__text__"):
        kline_result = _run_text(kline_input)
    else:
        kline_result = run(kline_input)
except Exception:
    kline_result = {"ok": False, "error": traceback.format_exc()}

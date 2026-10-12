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

import json
import math
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


def run(kline_input):
    """桥接入口：入参 {bars, requests} → {ok, results}。requests 与 results 按下标对齐"""
    bars = kline_input["bars"]
    closes = [float(x) for x in bars["c"]]
    builtins = {
        "C": closes, "CLOSE": closes,
        "H": [float(x) for x in bars["h"]], "HIGH": [float(x) for x in bars["h"]],
        "L": [float(x) for x in bars["l"]], "LOW": [float(x) for x in bars["l"]],
        "O": [float(x) for x in bars["o"]], "OPEN": [float(x) for x in bars["o"]],
        "V": [float(x) for x in bars["v"]], "VOL": [float(x) for x in bars["v"]],
        "AMOUNT": [float(x) for x in bars["a"]],
    }
    results = []
    for idx, req in enumerate(kline_input["requests"]):
        try:
            vars_map = {}
            lines = []
            for st in req["stmts"]:
                sar_box = [None]
                value = _eval_expr(st["e"], vars_map, builtins, sar_box)
                vars_map[st["n"].upper()] = value
                if st.get("o"):
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
    return {"ok": True, "results": results}


try:
    kline_result = run(kline_input)
except Exception:
    kline_result = {"ok": False, "error": traceback.format_exc()}

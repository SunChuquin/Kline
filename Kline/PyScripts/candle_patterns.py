# -*- coding: utf-8 -*-
"""candle_patterns.py — K 线形态识别（TA-Lib CDL 语义 numpy 向量化移植）。

Provenance / 许可
  判定语义与默认参数逐条移植自 TA-Lib C 源码（ta_CDL*.c 判定块 +
  src/ta_common/ta_global.c 默认蜡烛参数表，参考版本 0.6.4/0.8.x，两版 CDL 逻辑一致）。

  TA-Lib Copyright (c) 1999-2024, Mario Fortier. All rights reserved.
  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions are met:
  - Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.
  - Redistributions in binary form must reproduce the above copyright notice,
    this list of conditions and the following disclaimer in the documentation
    and/or other materials provided with the distribution.
  - Neither the name of the author nor the names of its contributors may be
    used to endorse or promote products derived from this software without
    specific prior written permission.
  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
  AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.

移植范围（首批 10 个常用形态）
  hammer / invertedhammer / engulfing / doji / shootingstar / harami /
  morningstar / eveningstar / 3blackcrows / 3whitesoldiers

验证契约（scripts/verify_candle_patterns.py）
  - Mac 参考 oracle：pip 安装的 C 版 talib（talib.CDL*）。
  - 随机游走 + 独立 OHLC + 手工样例全量差分，要求零差异后才允许发布。
  - KlineTests 契约测试（PyBridgeCandlePatternTests）对 golden fixture 逐值断言。

语义要点（与 C 版严格一致，改动前先读 ta_utility.h / ta_global.c）
  - CANDLEAVERAGE(SET) = factor × (avgPeriod≠0 ? 前N根窗口和/N : 当前根range)
    [窗口 = 评估根之前的 N 根，不含评估根本身；Shadows 类型额外 ÷2]。
  - **平局逐位一致**：2 位小数真实行情下「实体 == 实体均值」的语义平局高频出现，
    C 版结果由浮点求和舍入决定。本移植用「init 左到右和 + 差分 cumsum」精确镜像
    C 累加器的每一步浮点运算（np.cumsum 严格左到右，非 pairwise），
    对每个 (setting, off, lookback) 组合独立复刻（C 各形态的累加器起点不同）。
  - 默认参数表（ta_global.c）：BodyShort=实体/10/1.0，BodyLong=实体/10/1.0，
    BodyDoji=高低幅/10/0.1，ShadowLong=实体/0/1.0（即与当前根实体比），
    ShadowVeryShort=高低幅/10/0.1，Near=高低幅/5/0.2，Far=高低幅/5/0.6。
  - 输出与 talib Python 包装同形：与输入等长的 int 数组，前 lookback 根为 0；
    命中 ±100（ENGULFING/HARAMI 端点重合约 ±80），未命中 0。
  - lookback（默认参数下）：hammer/invertedhammer/shootingstar=11，engulfing=2，
    doji=10，harami=11，morningstar/eveningstar=12，3blackcrows=13，3whitesoldiers=12。

执行契约（由 Swift 桥接层包装，本脚本不做文件 IO、不依赖 stdout；同 period_aggregate.py）
  - 桥接注入模块全局 `kline_input`（dict）；本脚本产出模块级 `kline_result`。
  - 脚本异常由包装统一捕获；输入形状非法直接返回 {"ok": False, "error": ...}。
  - 依赖 numpy（引擎包自 2026-10 起内嵌）；无 numpy 引擎 → ImportError →
    Swift 侧 scriptError 降级（设计内路径）。

op = "detect"
  输入: {"op":"detect",
         "series":[{"file":"SH#600000","bars":[[o,h,l,c],...]},...],
         "patterns":["hammer",...]        # 可选，缺省 = 全部 10 个
         "penetration":0.3}               # 可选，仅 morningstar/eveningstar 使用
  输出: {"ok":true,"result":{"SH#600000":{"hammer":[0,...,100,...],...},...}}
"""

import numpy as np

# ---------------------------------------------------------------------------
# 默认蜡烛参数表：name -> (rangeType, avgPeriod, factor)
# 逐条抄自 src/ta_common/ta_global.c TA_CandleDefaultSettings[]。
# ---------------------------------------------------------------------------
_SETTINGS = {
    "BodyLong":        ("RealBody", 10, 1.0),
    "BodyVeryLong":    ("RealBody", 10, 3.0),
    "BodyShort":       ("RealBody", 10, 1.0),
    "BodyDoji":        ("HighLow", 10, 0.1),
    "ShadowLong":      ("RealBody", 0, 1.0),
    "ShadowVeryLong":  ("RealBody", 0, 2.0),
    "ShadowShort":     ("Shadows", 10, 0.5),
    "ShadowVeryShort": ("HighLow", 10, 0.1),
    "Near":            ("HighLow", 5, 0.2),
    "Far":             ("HighLow", 5, 0.6),
    "Equal":           ("HighLow", 5, 0.05),
}

# 各形态 lookback（默认参数下的 C 版取值，见各 ta_CDL*_Lookback）
_LOOKBACK = {
    "hammer": 11, "invertedhammer": 11, "shootingstar": 11,
    "engulfing": 2, "doji": 10, "harami": 11,
    "morningstar": 12, "eveningstar": 12,
    "3blackcrows": 13, "3whitesoldiers": 12,
}


def _shift(a, k):
    """数组右移 k 位（取 i-k 的值）：浮点补 NaN、整型补 0（比较均判 False）。"""
    if k <= 0:
        return a
    n = a.shape[0]
    fill = 0 if a.dtype.kind in "iu" else np.nan
    out = np.full(n, fill, dtype=a.dtype)
    if k < n:
        out[k:] = a[: n - k]
    return out


class _Candles(object):
    """OHLC 派生量 + 蜡烛均值缓存（一个序列构建一次，全部形态复用）。

    滚动均值逐位镜像 C 累加器：对 (setting, off, lookback) 组合，
    C 的窗口和 = seq_add(r[a..a+N-1]) 起步，随后每步 += fl(r[j]-r[j-N])。
    本类用 np.cumsum（严格左到右）复刻该运算序列，平局行为与 C 逐位一致。
    其中 j0 = lookback - off（首个评估根）、a = j0 - N（首个窗口起点）。
    """

    def __init__(self, o, h, l, c):
        self.o, self.h, self.l, self.c = o, h, l, c
        self.body_top = np.maximum(o, c)          # max(O,C)
        self.body_bot = np.minimum(o, c)          # min(O,C)
        self.color = np.where(c >= o, 1, -1).astype(np.int64)  # TA_CANDLECOLOR
        self.realbody = np.abs(c - o)             # TA_REALBODY
        self.highlow = h - l                      # TA_HIGHLOWRANGE
        self.upper = h - self.body_top            # TA_UPPERSHADOW
        self.lower = self.body_bot - l            # TA_LOWERSHADOW
        self._avg_cache = {}

    def _range_of(self, rt):
        return {"RealBody": self.realbody, "HighLow": self.highlow,
                "Shadows": self.upper + self.lower}[rt]

    def _build_avg(self, setting, off, lookback):
        """A[j] = TA_CANDLEAVERAGE(setting) 在评估根 j 的值；j < j0 处 NaN（判 False）。"""
        rt, period, factor = _SETTINGS[setting]
        n = self.o.shape[0]
        rng = self._range_of(rt)
        if period == 0:
            # avgPeriod=0 → factor × 评估根自身 range（如 ShadowLong 比当前根实体）
            return factor * rng
        A = np.full(n, np.nan)
        j0 = lookback - off
        a = j0 - period
        if a < 0 or n <= j0:
            return A  # 序列过短：无完整窗口，判定恒 False
        # init：左到右顺序和 r[a..a+N-1]（镜像 C 初始化 while 循环）
        init = np.cumsum(rng[a:a + period])[-1]
        # 滚动：每步 += fl(r[j]-r[j-N])，即 [init, init+d0, init+d0+d1, ...] 的
        # 左到右累加（镜像 C 滚动 +=；d[k] 属于 j0+k → j0+k+1 的转移，首根 = init）
        d = rng[j0:n] - rng[a:a + n - j0]
        S = np.cumsum(np.concatenate(([init], d)))[: n - j0]
        avg = factor * (S / period)          # 运算顺序镜像 C 宏
        if rt == "Shadows":
            avg = avg / 2.0
        A[j0:] = avg
        return A

    def avg_at(self, setting, off, lookback):
        """在根 i 上取「评估根 = i-off」的均值（off=0 当前根 / 1 前一根 / 2 前两根）。

        lookback = 所属形态的回看根数（C 各形态累加器起点不同，平局舍入也不同）。
        """
        key = (setting, off, lookback)
        A = self._avg_cache.get(key)
        if A is None:
            A = self._build_avg(setting, off, lookback)
            self._avg_cache[key] = A
        return _shift(A, off) if off else A


def _finish(val_or_cond, value, lookback):
    """bool 掩码（或现成 int 数组）→ 定值输出 + 头部 lookback 根清零。"""
    if val_or_cond.dtype == bool:
        out = np.where(val_or_cond, value, 0).astype(np.int64)
    else:
        out = val_or_cond.astype(np.int64)
    m = min(lookback, out.shape[0])
    if m > 0:
        out[:m] = 0
    return out


# ---------------------------------------------------------------------------
# 10 个形态（判定条件逐条对照 ta_CDL*.c 的 if 块；注释标 C 源文件）
# ---------------------------------------------------------------------------

def _cdl_hammer(k, p):  # ta_CDLHAMMER.c（lookback 11）
    lb = 11
    cond = (
        (k.realbody < k.avg_at("BodyShort", 0, lb))
        & (k.lower > k.avg_at("ShadowLong", 0, lb))
        & (k.upper < k.avg_at("ShadowVeryShort", 0, lb))
        & (k.body_bot <= _shift(k.l, 1) + k.avg_at("Near", 1, lb))
    )
    return _finish(cond, 100, lb)


def _cdl_inverted_hammer(k, p):  # ta_CDLINVERTEDHAMMER.c（lookback 11）
    lb = 11
    cond = (
        (k.realbody < k.avg_at("BodyShort", 0, lb))
        & (k.upper > k.avg_at("ShadowLong", 0, lb))
        & (k.lower < k.avg_at("ShadowVeryShort", 0, lb))
        & (k.body_top < _shift(k.body_bot, 1))   # REALBODYGAPDOWN(i, i-1)
    )
    return _finish(cond, 100, lb)


def _cdl_shooting_star(k, p):  # ta_CDLSHOOTINGSTAR.c（lookback 11）
    lb = 11
    cond = (
        (k.realbody < k.avg_at("BodyShort", 0, lb))
        & (k.upper > k.avg_at("ShadowLong", 0, lb))
        & (k.lower < k.avg_at("ShadowVeryShort", 0, lb))
        & (k.body_bot > _shift(k.body_top, 1))   # REALBODYGAPUP(i, i-1)
    )
    return _finish(cond, -100, lb)


def _cdl_doji(k, p):  # ta_CDLDOJI.c（注意是 <=；lookback 10）
    cond = k.realbody <= k.avg_at("BodyDoji", 0, 10)
    return _finish(cond, 100, 10)


def _cdl_engulfing(k, p):  # ta_CDLENGULFING.c（无蜡烛均值；80 分支 = 端点重合）
    o, c, ci = k.o, k.c, k.color
    o1, c1, c1c = _shift(o, 1), _shift(c, 1), _shift(k.color, 1)
    white = (ci == 1) & (c1c == -1) & (
        ((c >= o1) & (o < c1)) | ((c > o1) & (o <= c1)))
    black = (ci == -1) & (c1c == 1) & (
        ((o >= c1) & (c < o1)) | ((o > c1) & (c <= o1)))
    eng = white | black
    strict = (o != c1) & (c != o1)
    val = np.where(eng & strict, ci * 100, np.where(eng, ci * 80, 0))
    return _finish(val, 0, 2)


def _cdl_harami(k, p):  # ta_CDLHARAMI.c（孕线；方向取前一根反色；lookback 11）
    lb = 11
    rb1 = _shift(k.realbody, 1)
    c1c = _shift(k.color, 1)
    cond = (rb1 > k.avg_at("BodyLong", 1, lb)) & (k.realbody <= k.avg_at("BodyShort", 0, lb))
    strict = (k.body_top < _shift(k.body_top, 1)) & (k.body_bot > _shift(k.body_bot, 1))
    loose = (k.body_top <= _shift(k.body_top, 1)) & (k.body_bot >= _shift(k.body_bot, 1))
    val = np.where(cond & strict, -c1c * 100, np.where(cond & loose, -c1c * 80, 0))
    return _finish(val, 0, lb)


def _cdl_morning_star(k, p):  # ta_CDLMORNINGSTAR.c（lookback 12）
    lb = 12
    rb2, rb1 = _shift(k.realbody, 2), _shift(k.realbody, 1)
    col2 = _shift(k.color, 2)
    gapdown = _shift(k.body_top, 1) < _shift(k.body_bot, 2)  # REALBODYGAPDOWN(i-1, i-2)
    cond = (
        (rb2 > k.avg_at("BodyLong", 2, lb)) & (col2 == -1)
        & (rb1 <= k.avg_at("BodyShort", 1, lb)) & gapdown
        & (k.realbody > k.avg_at("BodyShort", 0, lb)) & (k.color == 1)
        & (k.c > _shift(k.c, 2) + rb2 * p)
    )
    return _finish(cond, 100, lb)


def _cdl_evening_star(k, p):  # ta_CDLEVENINGSTAR.c（lookback 12）
    lb = 12
    rb2, rb1 = _shift(k.realbody, 2), _shift(k.realbody, 1)
    col2 = _shift(k.color, 2)
    gapup = _shift(k.body_bot, 1) > _shift(k.body_top, 2)    # REALBODYGAPUP(i-1, i-2)
    cond = (
        (rb2 > k.avg_at("BodyLong", 2, lb)) & (col2 == 1)
        & (rb1 <= k.avg_at("BodyShort", 1, lb)) & gapup
        & (k.realbody > k.avg_at("BodyShort", 0, lb)) & (k.color == -1)
        & (k.c < _shift(k.c, 2) - rb2 * p)
    )
    return _finish(cond, -100, lb)


def _cdl_3_black_crows(k, p):  # ta_CDL3BLACKCROWS.c（含前置白根 i-3，共 4 根；lookback 13）
    lb = 13
    o1, o2 = _shift(k.o, 1), _shift(k.o, 2)
    c1, c2, c3 = _shift(k.c, 1), _shift(k.c, 2), _shift(k.c, 3)
    cond = (
        (_shift(k.color, 3) == 1) & (_shift(k.color, 2) == -1)
        & (_shift(k.lower, 2) < k.avg_at("ShadowVeryShort", 2, lb))
        & (_shift(k.color, 1) == -1)
        & (_shift(k.lower, 1) < k.avg_at("ShadowVeryShort", 1, lb))
        & (k.color == -1)
        & (k.lower < k.avg_at("ShadowVeryShort", 0, lb))
        & (o1 < o2) & (o1 > c2)     # 2nd black opens within 1st black's rb
        & (k.o < o1) & (k.o > c1)   # 3rd black opens within 2nd black's rb
        & (_shift(k.h, 3) > c2)     # 1st black closes under prior candle's high
        & (c2 > c1) & (c1 > k.c)    # three declining
    )
    return _finish(cond, -100, lb)


def _cdl_3_white_soldiers(k, p):  # ta_CDL3WHITESOLDIERS.c（lookback 12）
    lb = 12
    o1, o2 = _shift(k.o, 1), _shift(k.o, 2)
    c1, c2 = _shift(k.c, 1), _shift(k.c, 2)
    rb1, rb2 = _shift(k.realbody, 1), _shift(k.realbody, 2)
    cond = (
        (_shift(k.color, 2) == 1)
        & (_shift(k.upper, 2) < k.avg_at("ShadowVeryShort", 2, lb))
        & (_shift(k.color, 1) == 1)
        & (_shift(k.upper, 1) < k.avg_at("ShadowVeryShort", 1, lb))
        & (k.color == 1)
        & (k.upper < k.avg_at("ShadowVeryShort", 0, lb))
        & (k.c > c1) & (c1 > c2)                                  # 连续更高收盘
        & (o1 > o2) & (o1 <= c2 + k.avg_at("Near", 2, lb))        # 2nd opens within/near 1st
        & (k.o > o1) & (k.o <= c1 + k.avg_at("Near", 1, lb))      # 3rd opens within/near 2nd
        & (rb1 > rb2 - k.avg_at("Far", 2, lb))                    # 2nd not far shorter
        & (k.realbody > rb1 - k.avg_at("Far", 1, lb))             # 3rd not far shorter
        & (k.realbody > k.avg_at("BodyShort", 0, lb))             # 3rd: not short real body
    )
    return _finish(cond, 100, lb)


_PATTERNS = {
    "hammer": _cdl_hammer,
    "invertedhammer": _cdl_inverted_hammer,
    "engulfing": _cdl_engulfing,
    "doji": _cdl_doji,
    "shootingstar": _cdl_shooting_star,
    "harami": _cdl_harami,
    "morningstar": _cdl_morning_star,
    "eveningstar": _cdl_evening_star,
    "3blackcrows": _cdl_3_black_crows,
    "3whitesoldiers": _cdl_3_white_soldiers,
}


def _detect_series(bars, patterns, penetration):
    """bars: [[o,h,l,c],...] → {pattern: 与 bars 等长的 int 输出数组}。"""
    result = {}
    if not bars:
        return {name: [] for name in patterns}
    o = np.array([b[0] for b in bars], dtype=np.float64)
    h = np.array([b[1] for b in bars], dtype=np.float64)
    l = np.array([b[2] for b in bars], dtype=np.float64)
    c = np.array([b[3] for b in bars], dtype=np.float64)
    k = _Candles(o, h, l, c)
    for name in patterns:
        result[name] = _PATTERNS[name](k, penetration).tolist()
    return result


def _err(msg):
    return {"ok": False, "error": msg}


def _as_num(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return v


def _op_detect(inp):
    series = inp.get("series")
    if not isinstance(series, list):
        return _err("detect: series 必须为数组")
    patterns = inp.get("patterns")
    if patterns is None:
        patterns = list(_PATTERNS.keys())
    if not isinstance(patterns, list) or not patterns:
        return _err("detect: patterns 必须为非空数组（可选值：%s）" % (sorted(_PATTERNS),))
    seen = []
    for name in patterns:
        if name not in _PATTERNS:
            return _err("detect: 未知形态 %r（可选值：%s）" % (name, sorted(_PATTERNS)))
        if name not in seen:
            seen.append(name)
    penetration = inp.get("penetration", 0.3)
    if _as_num(penetration) is None:
        return _err("detect: penetration 必须为数值")
    result = {}
    for s in series:
        if not isinstance(s, dict):
            return _err("detect: series 元素必须为对象")
        file = s.get("file")
        if not isinstance(file, str) or not file:
            return _err("detect: series 元素缺少合法 file 字段")
        bars = s.get("bars")
        if not isinstance(bars, list):
            return _err("detect: %s 缺少 bars 数组" % file)
        for r in bars:
            if not isinstance(r, (list, tuple)) or len(r) < 4:
                return _err("detect: %s 的 bar 必须为 [open,high,low,close] 数组" % file)
            for v in r[:4]:
                if _as_num(v) is None:
                    return _err("detect: %s 的 bar 数值非法: %r" % (file, v))
        result[file] = _detect_series(bars, seen, penetration)
    return {"ok": True, "result": result}


def _main():
    inp = globals().get("kline_input")
    if not isinstance(inp, dict):
        return _err("kline_input 未注入或不是对象")
    if inp.get("op") == "detect":
        return _op_detect(inp)
    return _err("未知 op: %r（仅支持 detect）" % (inp.get("op"),))


kline_result = _main()

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_candle_patterns.py — candle_patterns.py 与 C 版 talib 参考实现全量差分验证。

用法（用带 talib + numpy 的 venv 执行，如 ~/.venvs/talib-ref）：
  ~/.venvs/talib-ref/bin/python scripts/verify_candle_patterns.py            # 差分验证
  ~/.venvs/talib-ref/bin/python scripts/verify_candle_patterns.py --fixture  # 另外生成 golden fixture

验证内容
  1. fuzz 差分：随机游走 / 独立 OHLC / 跳空游走 / 退化序列 / 手工样例，
     每个形态全量逐 bar 比对移植版 vs C 版，要求零差异。
  2. 命中覆盖：每个形态在语料中至少 30 次命中、ENGULFING/HARAMI 各至少 1 次 ±80
     （保证判定分支真实被语料走到，而非恒 0 侥幸通过）。
  3. --fixture：产出 KlineTests/Fixtures/candle_patterns.json（golden 契约测试用）。
"""

import json
import os
import random
import sys
import time

import numpy as np
import talib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "Kline", "PyScripts"))
import candle_patterns as cp  # noqa: E402

PENETRATION = 0.3

# 移植形态名 → talib 包装函数名
ORACLE = {
    "hammer": "CDLHAMMER",
    "invertedhammer": "CDLINVERTEDHAMMER",
    "engulfing": "CDLENGULFING",
    "doji": "CDLDOJI",
    "shootingstar": "CDLSHOOTINGSTAR",
    "harami": "CDLHARAMI",
    "morningstar": "CDLMORNINGSTAR",
    "eveningstar": "CDLEVENINGSTAR",
    "3blackcrows": "CDL3BLACKCROWS",
    "3whitesoldiers": "CDL3WHITESOLDIERS",
}


def _to_arrays(bars):
    o = np.array([b[0] for b in bars], dtype=np.float64)
    h = np.array([b[1] for b in bars], dtype=np.float64)
    l = np.array([b[2] for b in bars], dtype=np.float64)
    c = np.array([b[3] for b in bars], dtype=np.float64)
    return o, h, l, c


def _oracle(name, bars):
    o, h, l, c = _to_arrays(bars)
    fn = getattr(talib, ORACLE[name])
    if name in ("morningstar", "eveningstar"):
        return fn(o, h, l, c, PENETRATION)
    return fn(o, h, l, c)


def _port(name, bars):
    return cp._detect_series(bars, [name], PENETRATION)[name]


# ---------------------------------------------------------------------------
# 语料生成
# ---------------------------------------------------------------------------

def _gen_walk(rng, n):
    """随机游走（2 位小数，连续收盘→开盘，无跳空）。"""
    bars = []
    price = 100.0
    for _ in range(n):
        o = price
        c = round(o + rng.uniform(-1.5, 1.5), 2)
        hi = round(max(o, c) + rng.uniform(0, 0.8), 2)
        lo = round(min(o, c) - rng.uniform(0, 0.8), 2)
        bars.append([o, hi, lo, c])
        price = c
    return bars


def _gen_indep(rng, n):
    """独立 OHLC（开盘收盘独立、影线大幅外扩——天然产生实体跳空）。"""
    bars = []
    for _ in range(n):
        o = round(rng.uniform(90, 110), 2)
        c = round(rng.uniform(90, 110), 2)
        hi = round(max(o, c) + rng.uniform(0, 3.0), 2)
        lo = round(min(o, c) - rng.uniform(0, 3.0), 2)
        bars.append([o, hi, lo, c])
    return bars


def _gen_gap_walk(rng, n):
    """跳空游走（开盘相对前收随机跳 -2..+2）。"""
    bars = []
    price = 100.0
    for _ in range(n):
        o = round(price + rng.uniform(-2.0, 2.0), 2)
        c = round(o + rng.uniform(-1.0, 1.0), 2)
        hi = round(max(o, c) + rng.uniform(0, 0.6), 2)
        lo = round(min(o, c) - rng.uniform(0, 0.6), 2)
        bars.append([o, hi, lo, c])
        price = c
    return bars


def _gen_degenerate(rng, n):
    """退化序列：平盘 / 全等 / 纯十字星混合。"""
    bars = []
    for i in range(n):
        mode = i % 4
        if mode == 0:
            v = round(100 + (i % 7) * 0.01, 2)
            bars.append([v, v, v, v])                       # 四价合一
        elif mode == 1:
            bars.append([100.0, 100.02, 99.98, 100.0])      # 纯十字星
        elif mode == 2:
            bars.append([100.0, 100.5, 99.5, 101.0])        # 光头光脚阳
        else:
            bars.append([101.0, 101.5, 100.5, 100.0])       # 光头光脚阴
    return bars


def _baseline(n, start=100.0):
    """确定性基线：白实体 1.0 / 全幅 1.2 / 上下影各 0.1（均值可手算）。"""
    bars = []
    for i in range(n):
        o = round(start + 0.01 * i, 2)
        c = round(o + 1.0, 2)
        bars.append([o, round(c + 0.1, 2), round(o - 0.1, 2), c])
    return bars


def _gen_crows_prone(rng, n=600):
    """乌鸦易发语料：随机游走中每隔 ~15 根注入一段随机化的三乌鸦模板。"""
    bars = _gen_walk(rng, n)
    i = 20
    while i + 4 < n - 5:
        p = bars[i - 1][3]
        cw = p + rng.uniform(0.2, 1.5)                       # 前置白根收盘
        bars[i] = [round(p, 2), round(cw + 0.05, 2), round(p - 0.05, 2), round(cw, 2)]
        o1 = cw - rng.uniform(0.0, 0.3)                      # 1st black：开盘在白根实体内
        c1 = o1 - rng.uniform(0.3, 1.2)
        bars[i + 1] = [round(o1, 2), round(o1 + 0.05, 2),
                       round(c1 - rng.uniform(0, 0.06), 2), round(c1, 2)]
        o2 = c1 + rng.uniform(0.05, 0.25)                    # 2nd black：开盘在 1st 实体内
        c2 = o2 - rng.uniform(0.3, 1.2)
        bars[i + 2] = [round(o2, 2), round(o2 + 0.05, 2),
                       round(c2 - rng.uniform(0, 0.06), 2), round(c2, 2)]
        o3 = c2 + rng.uniform(0.05, 0.25)                    # 3rd black
        c3 = o3 - rng.uniform(0.3, 1.2)
        bars[i + 3] = [round(o3, 2), round(o3 + 0.05, 2),
                       round(c3 - rng.uniform(0, 0.06), 2), round(c3, 2)]
        i += 15
    return bars


def _crafted():
    """手工样例：每个形态确定性命中一次（+ENGULFING/HARAMI 的 ±80 分支）。

    基线满足：avg 实体=1.0、avg 全幅=1.2、ShadowLong=当前根实体、
    Near=0.2*1.2=0.24、Far=0.6*1.2=0.72、ShadowVeryShort=0.1*1.2=0.12。
    每个样例前后各垫 ≥12 根基线，形态间用基线隔开。
    """
    series = []
    tail = 14

    def block(bars):
        return _baseline(15) + bars + _baseline(tail)

    # hammer：小实体 + 长下影 + 极短上影 + 实体贴近前低
    series.append(block([[100.00, 100.07, 97.00, 100.05]]))
    # invertedhammer：小实体 + 长上影 + 极短下影 + 实体跳空向下
    series.append(block([[98.90, 101.95, 98.88, 98.95]]))
    # shootingstar：小实体 + 长上影 + 极短下影 + 实体跳空向上
    series.append(block([[101.00, 104.00, 100.98, 101.05]]))
    # doji：实体 ≤ 0.12
    series.append(block([[100.00, 100.60, 99.40, 100.02]]))
    # engulfing：先黑后白吞没（严格 100 与端点重合 80 各一）
    series.append(block([[100.00, 100.10, 99.00, 99.00],
                         [98.50, 101.00, 98.40, 101.00]]))   # O=98.5<C前=99 且 C=101>O前=100 → +100
    series.append(block([[100.00, 100.10, 99.00, 99.00],
                         [99.00, 101.00, 98.90, 101.00]]))   # O=99=C前 → +80
    # harami：长实体孕短实体（严格 100 与端点重合 80 各一）
    series.append(block([[100.00, 102.10, 99.90, 102.00],
                         [100.20, 100.80, 100.10, 100.70]]))  # 全内含 → -100
    series.append(block([[100.00, 102.10, 99.90, 102.00],
                         [100.00, 100.80, 99.90, 100.70]]))  # 下端重合 → -80
    # morningstar：长黑 + 小实体跳空下 + 白收进长黑实体 30% 以上
    series.append(block([[102.00, 102.10, 101.90, 100.00],
                         [99.10, 99.20, 99.00, 99.10],
                         [99.30, 101.60, 99.20, 101.50]]))
    # eveningstar：长白 + 小实体跳空上 + 黑收进长黑实体 30% 以上
    series.append(block([[100.00, 100.10, 99.90, 102.00],
                         [102.50, 102.60, 102.40, 102.55],
                         [102.30, 102.40, 100.90, 101.00]]))
    # 3blackcrows：前置白根 + 三根递降黑根（每根下影极短、开盘在前根实体内）
    series.append(block([[100.00, 101.10, 99.90, 101.00],
                         [100.80, 100.90, 99.95, 100.00],
                         [100.70, 100.80, 99.15, 99.20],
                         [99.50, 99.60, 98.65, 98.70]]))
    # 3whitesoldiers：三连阳（更高收盘、开盘在前根实体附近、上影极短、实体不骤缩）
    series.append(block([[100.00, 101.05, 99.90, 101.00],
                         [100.50, 102.05, 100.40, 102.00],
                         [101.50, 103.05, 101.40, 103.00]]))
    return series


def _fuzz_corpus():
    rng = random.Random(20261012)
    corpus = []
    for i in range(30):
        corpus.append(("walk%02d" % i, _gen_walk(rng, 600)))
    for i in range(30):
        corpus.append(("indep%02d" % i, _gen_indep(rng, 600)))
    for i in range(30):
        corpus.append(("gap%02d" % i, _gen_gap_walk(rng, 600)))
    for i in range(10):
        corpus.append(("crows%02d" % i, _gen_crows_prone(rng, 600)))
    for i in range(10):
        corpus.append(("degen%02d" % i, _gen_degenerate(rng, 200)))
    for i, bars in enumerate(_crafted()):
        corpus.append(("crafted%02d" % i, bars))
    return corpus


# ---------------------------------------------------------------------------
# 差分与报告
# ---------------------------------------------------------------------------

def verify():
    corpus = _fuzz_corpus()
    total_bars = sum(len(b) for _, b in corpus)
    print("语料：%d 个序列 / %d 根 bar" % (len(corpus), total_bars))

    hits = {name: 0 for name in ORACLE}
    hits80 = {"engulfing": 0, "harami": 0}
    mismatches = []
    t_oracle = t_port = 0.0

    for fname, bars in corpus:
        for name in ORACLE:
            t0 = time.perf_counter()
            expected = _oracle(name, bars)
            t_oracle += time.perf_counter() - t0
            t0 = time.perf_counter()
            got = _port(name, bars)
            t_port += time.perf_counter() - t0
            e_list = [int(x) for x in expected.tolist()]
            g_list = [int(x) for x in got]
            if len(e_list) != len(g_list):
                mismatches.append("%s/%s: 长度 %d != %d" % (fname, name, len(e_list), len(g_list)))
                continue
            for idx, (e, g) in enumerate(zip(e_list, g_list)):
                if e != g:
                    if len(mismatches) < 20:
                        mismatches.append("%s/%s bar#%d: C=%d 移植=%d bar=%s"
                                          % (fname, name, idx, e, g, bars[idx]))
                    else:
                        mismatches.append("%s/%s bar#%d: C=%d 移植=%d"
                                          % (fname, name, idx, e, g))
            hits[name] += sum(1 for x in e_list if x != 0)
            if name in hits80:
                hits80[name] += sum(1 for x in e_list if abs(x) == 80)

    print("\n每形态命中数（C 版口径）：")
    for name in ORACLE:
        print("  %-16s %6d" % (name, hits[name]))
    print("±80 分支命中：engulfing=%d harami=%d" % (hits80["engulfing"], hits80["harami"]))
    print("耗时：C oracle %.3fs / 移植 %.3fs（%.1fx）" % (t_oracle, t_port, t_port / max(t_oracle, 1e-9)))

    fail = []
    if mismatches:
        fail.append("差分失败：%d 处不一致（前 20 处：\n%s\n）"
                    % (len(mismatches), "\n".join(mismatches[:20])))
    for name in ORACLE:
        if hits[name] < 30:
            fail.append("命中覆盖不足：%s 仅 %d 次（< 30），判定分支未被真实语料覆盖" % (name, hits[name]))
    for name, n in hits80.items():
        if n < 1:
            fail.append("%s 的 ±80 分支未被语料覆盖" % name)

    # 端到端：走 kline_input → kline_result 完整入口（镜像桥接注入路径）
    payload = {"op": "detect", "series": [{"file": "E2E", "bars": _crafted()[0]}],
               "penetration": PENETRATION}
    cp.kline_input = payload
    e2e = cp._main()
    if e2e.get("ok") is not True or "E2E" not in e2e.get("result", {}):
        fail.append("端到端入口失败：%s" % e2e)
    else:
        exp = _oracle("hammer", payload["series"][0]["bars"]).tolist()
        if e2e["result"]["E2E"]["hammer"] != [int(x) for x in exp]:
            fail.append("端到端 hammer 输出与 oracle 不一致")

    if fail:
        print("\n[FAIL]")
        for f in fail:
            print("  - %s" % f)
        return 1
    print("\n[PASS] 全量差分零差异，命中覆盖达标，端到端入口一致")
    return 0


def emit_fixture():
    """golden fixture：3 个序列（随机游走 / 独立 OHLC / 手工全形态），输出取自 C oracle。"""
    rng = random.Random(4242)
    series = [
        {"file": "WALK", "bars": _gen_walk(rng, 400)},
        {"file": "INDEP", "bars": _gen_indep(rng, 400)},
        {"file": "CRAFTED", "bars": _crafted()[0] + _crafted()[4] + _crafted()[5]
                                  + _crafted()[6] + _crafted()[7] + _crafted()[8]
                                  + _crafted()[9] + _crafted()[10]},
    ]
    expected = {}
    for s in series:
        expected[s["file"]] = {}
        for name in ORACLE:
            expected[s["file"]][name] = [int(x) for x in _oracle(name, s["bars"]).tolist()]
    fixture = {
        "series": series,
        "patterns": list(ORACLE.keys()),
        "penetration": PENETRATION,
        "expected": expected,
    }
    path = os.path.join(REPO, "KlineTests", "Fixtures", "candle_patterns.json")
    with open(path, "w") as f:
        json.dump(fixture, f, ensure_ascii=False, separators=(",", ":"))
    total_hits = sum(1 for fe in expected.values()
                     for arr in fe.values() for x in arr if x != 0)
    print("fixture 已生成：%s（%d 序列，命中 %d 处）" % (path, len(series), total_hits))


if __name__ == "__main__":
    code = verify()
    if code == 0 and "--fixture" in sys.argv:
        emit_fixture()
    sys.exit(code)

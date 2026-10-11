#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_mytt_shim.py — PyScripts/mytt.py（numpy 垫片）vs MyTT 原版（pandas）全量差分验证。

用法（用 pandas 2.2.3 的 venv 执行——golden 基准，见 mytt.py 模块 docstring）：
  /tmp/pd2env/bin/python scripts/verify_mytt_shim.py            # 差分验证
  /tmp/pd2env/bin/python scripts/verify_mytt_shim.py --fixture  # 另外生成 golden fixture

参考实现（真值源）
  - scripts/vendor/MyTT_pandas.py：MyTT V3.3 原版（pandas 依赖原样），
    取自 https://github.com/mpquant/MyTT（MIT），仅作差分 oracle，不进 App bundle。
  - golden 基准 = pandas 2.2.3：pandas 3.0.6 在 ewm α=0.5 的 mid-NaN 场景
    偏离 F 模型（如 EMA(C,3) 给 2.5 而非 2.3333，疑似 bug），不采纳。

验证内容
  1. 函数层差分：全部 67 个函数（0/1/2 级）× 随机游走 OHLCV + NaN 嵌入变体，
     NaN 位置精确一致 + 数值容差（rtol=1e-10 / atol=1e-12，rolling 聚合与
     pandas 逐窗算法差异为 ulp 级）；含 α=0.5 分歧哨兵（EMA(C,3)/DMA(C,0.5)）。
  2. op 层全链：kline_input 注入方式调 mytt op="functions"（与 Swift 桥接同构），
     输出与原版一致（$id / $id#k 引用、NaN→null 序列化、FILTER 副本保护——
     calls 表设计保证 FILTER 之后不再引用其输入序列，双侧语义等价）。
  3. --fixture：产出 KlineTests/Fixtures/mytt_functions.json（expected 取原版输出）。
"""

import argparse
import importlib.util
import json
import os
import sys

import numpy as np

np.seterr(all="ignore")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


shim = _load(os.path.join(REPO, "Kline", "PyScripts", "mytt.py"), "mytt_shim")
orig = _load(os.path.join(REPO, "scripts", "vendor", "MyTT_pandas.py"), "mytt_orig")
ORIG_TABLE = {name: getattr(orig, name) for name in shim._FN_NAMES}

RTOL, ATOL = 1e-10, 1e-12


# ---------------------------------------------------------------------------
# 语料与调用表（seed 固定，离线确定；fixture 直接复用）
# ---------------------------------------------------------------------------

def _build_spec():
    rng = np.random.default_rng(20261012)
    n = 300
    ret = rng.normal(0.0004, 0.018, n)
    c = np.round(10 * np.exp(np.cumsum(ret)), 3)
    o = np.round(c * (1 + rng.normal(0, 0.004, n)), 3)
    h = np.round(np.maximum(o, c) * (1 + np.abs(rng.normal(0, 0.006, n))), 3)
    l = np.round(np.minimum(o, c) * (1 - np.abs(rng.normal(0, 0.006, n))), 3)
    v = rng.integers(8_000, 900_000, n).astype(float)

    cn = c.copy(); cn[50] = np.nan; cn[120:123] = np.nan
    hn = h.copy(); hn[51] = np.nan; hn[200] = np.nan
    ln = l.copy(); ln[121] = np.nan
    vn = v.copy(); vn[122] = np.nan
    dc = np.concatenate(([np.nan], np.diff(c)))                  # 有正有负 + 首位 NaN
    up = (dc > 0).astype(float)                                  # 0/1 flag
    up_f = (h - l > np.median(h - l)).astype(float)              # FILTER 专用（后续不引用）
    alpha_seq = 0.05 + 0.2 * np.abs(np.sin(np.arange(n) / 7.0))  # DMA 序列平滑因子

    def lst(a):
        return [None if np.isnan(x) else float(x) for x in a]

    series = {
        "O": lst(o), "H": lst(h), "L": lst(l), "C": lst(c), "V": lst(v),
        "Cn": lst(cn), "Hn": lst(hn), "Ln": lst(ln), "Vn": lst(vn),
        "dC": lst(dc), "up": lst(up), "upF": lst(up_f), "alpha": lst(alpha_seq),
    }

    calls = [
        # ---- 0 级核心函数（含 NaN 变体）----
        {"fn": "RD", "args": ["C"]},
        {"fn": "RET", "args": ["C"]},
        {"fn": "ABS", "args": ["dC"]},
        {"fn": "LN", "args": ["C"]},
        {"fn": "POW", "args": ["C", 2]},
        {"fn": "SQRT", "args": ["C"]},
        {"fn": "SIN", "args": ["dC"]},
        {"fn": "COS", "args": ["dC"]},
        {"fn": "TAN", "args": ["dC"]},
        {"fn": "MAX", "args": ["C", "O"]},
        {"fn": "MIN", "args": ["C", "O"]},
        {"fn": "IF", "args": ["up", "C", "O"]},
        {"fn": "REF", "args": ["C", 1]},
        {"fn": "REF", "args": ["Cn", 3]},
        {"fn": "DIFF", "args": ["C", 1]},
        {"fn": "DIFF", "args": ["Cn", 2]},
        {"fn": "STD", "args": ["C", 10]},
        {"fn": "STD", "args": ["Cn", 10]},
        {"fn": "SUM", "args": ["C", 10]},
        {"fn": "SUM", "args": ["C", 0]},
        {"fn": "SUM", "args": ["Cn", 10]},
        {"fn": "CONST", "args": ["C"]},
        {"fn": "HHV", "args": ["H", 10]},
        {"fn": "HHV", "args": ["Hn", 10]},
        {"fn": "LLV", "args": ["L", 10]},
        {"fn": "LLV", "args": ["Ln", 10]},
        {"fn": "HHVBARS", "args": ["H", 10]},
        {"fn": "LLVBARS", "args": ["L", 10]},
        {"id": "ma5", "fn": "MA", "args": ["C", 5]},
        {"id": "ma10", "fn": "MA", "args": ["C", 10]},
        {"fn": "MA", "args": ["Cn", 5]},
        {"fn": "EMA", "args": ["C", 12]},
        {"fn": "EMA", "args": ["C", 3]},          # α=0.5 分歧哨兵（pandas 2.2.3 = F 模型）
        {"fn": "EMA", "args": ["Cn", 12]},        # mid-NaN F 模型
        {"fn": "EMA", "args": ["Cn", 3]},         # α=0.5 × mid-NaN 组合（pandas 3.0.6 分歧点）
        {"fn": "SMA", "args": ["C", 10, 1]},
        {"fn": "SMA", "args": ["C", 5, 3]},
        {"fn": "WMA", "args": ["C", 10]},
        {"fn": "DMA", "args": ["C", 0.5]},        # α=0.5 分歧哨兵
        {"fn": "DMA", "args": ["C", 0.3]},
        {"fn": "DMA", "args": ["C", "alpha"]},    # 序列平滑因子分支
        {"fn": "AVEDEV", "args": ["C", 10]},
        {"fn": "AVEDEV", "args": ["Cn", 10]},     # raw=False 路径 + NaN
        {"fn": "SLOPE", "args": ["C", 10]},
        {"fn": "FORCAST", "args": ["C", 10]},
        {"fn": "LAST", "args": ["up", 10, 2]},
        # ---- 1 级应用函数 ----
        {"fn": "COUNT", "args": ["up", 10]},
        {"fn": "EVERY", "args": ["up", 5]},
        {"fn": "EXIST", "args": ["up", 7]},
        {"fn": "FILTER", "args": ["upF", 5]},     # 输入序列后续不再引用（副本语义等价）
        {"fn": "BARSLAST", "args": ["up"]},
        {"fn": "BARSLASTCOUNT", "args": ["up"]},
        {"fn": "BARSSINCEN", "args": ["up", 20]},
        {"fn": "CROSS", "args": ["$ma5", "$ma10"]},
        {"fn": "LONGCROSS", "args": ["$ma5", "$ma10", 3]},
        {"fn": "VALUEWHEN", "args": ["up", "C"]},
        {"id": "llv10", "fn": "LLV", "args": ["L", 10]},
        {"id": "hhv10", "fn": "HHV", "args": ["H", 10]},
        {"fn": "BETWEEN", "args": ["C", "$llv10", "$hhv10"]},
        {"fn": "TOPRANGE", "args": ["H"]},
        {"fn": "LOWRANGE", "args": ["L"]},
        # ---- 2 级技术指标（含 NaN 变体）----
        {"fn": "MACD", "args": ["C"]},
        {"fn": "MACD", "args": ["Cn", 6, 13, 5]},
        {"id": "kdj", "fn": "KDJ", "args": ["C", "H", "L"]},
        {"fn": "KDJ", "args": ["Cn", "Hn", "Ln"]},
        {"fn": "RSI", "args": ["C"]},
        {"fn": "RSI", "args": ["Cn", 14]},
        {"fn": "WR", "args": ["C", "H", "L"]},
        {"fn": "BIAS", "args": ["C"]},
        {"fn": "BOLL", "args": ["C"]},
        {"fn": "BOLL", "args": ["Cn"]},
        {"fn": "PSY", "args": ["C"]},
        {"fn": "CCI", "args": ["C", "H", "L"]},
        {"fn": "ATR", "args": ["C", "H", "L"]},
        {"fn": "BBI", "args": ["C"]},
        {"fn": "DMI", "args": ["C", "H", "L"]},
        {"fn": "TAQ", "args": ["H", "L", 20]},
        {"fn": "KTN", "args": ["C", "H", "L"]},
        {"fn": "TRIX", "args": ["C"]},
        {"fn": "VR", "args": ["C", "V"]},
        {"fn": "CR", "args": ["C", "H", "L"]},
        {"fn": "EMV", "args": ["H", "L", "V"]},
        {"fn": "DPO", "args": ["C"]},
        {"fn": "BRAR", "args": ["O", "C", "H", "L"]},
        {"fn": "DFMA", "args": ["C"]},
        {"fn": "MTM", "args": ["C"]},
        {"fn": "MASS", "args": ["H", "L"]},
        {"fn": "ROC", "args": ["C"]},
        {"fn": "EXPMA", "args": ["C"]},
        {"fn": "OBV", "args": ["C", "V"]},
        {"fn": "MFI", "args": ["C", "H", "L", "V"]},
        {"fn": "ASI", "args": ["O", "C", "H", "L"]},
        {"fn": "XSII", "args": ["C", "H", "L"]},
        {"fn": "MA", "args": ["$kdj#0", 5]},      # $id#k 多输出列引用
    ]
    return {"op": "functions", "series": series, "calls": calls}


# ---------------------------------------------------------------------------
# 双侧执行器
# ---------------------------------------------------------------------------

def _resolve(ra, arrays, env):
    if isinstance(ra, str):
        if ra.startswith("$"):
            key = ra[1:]
            base, _, idx = key.partition("#")
            v = env[base]
            if isinstance(v, tuple):
                return np.array(v[int(idx)], copy=True)
            return np.array(v, copy=True) if isinstance(v, np.ndarray) else v
        return arrays[ra]
    return ra


def _run_calls(table, spec, copy_args):
    """函数层执行：copy_args=False 双侧对称（原版 FILTER 原位改写语义）；
    copy_args=True 镜像 op 层的副本保护。"""
    arrays = {name: np.array([float("nan") if x is None else float(x) for x in vals])
              for name, vals in spec["series"].items()}
    env = {}
    results = []
    for call in spec["calls"]:
        fn = table[call["fn"]]
        args = []
        for ra in call.get("args", []):
            a = _resolve(ra, arrays, env)
            if copy_args and isinstance(a, np.ndarray):
                a = np.array(a, copy=True)
            args.append(a)
        out = fn(*args)
        outs = out if isinstance(out, tuple) else (out,)
        results.append({"fn": call["fn"], "outputs": [shim._out_json(o) for o in outs]})
        if call.get("id"):
            env[call["id"]] = out
    return results


def _run_op(spec):
    """op 层执行：模拟 Swift 桥接注入 kline_input，与生产路径同构。"""
    shim.kline_input = spec
    res = shim._main()
    if not (isinstance(res, dict) and res.get("ok") is True):
        raise SystemExit("op 层执行失败: %r" % (res,))
    return res["result"]["results"]


# ---------------------------------------------------------------------------
# 差分
# ---------------------------------------------------------------------------

def _diff(shim_res, orig_res, label):
    issues = []
    n_points = 0
    if len(shim_res) != len(orig_res):
        raise SystemExit("%s: call 数不一致 %d vs %d" % (label, len(shim_res), len(orig_res)))
    for k, (s, o) in enumerate(zip(shim_res, orig_res)):
        if s["fn"] != o["fn"] or len(s["outputs"]) != len(o["outputs"]):
            issues.append("[%d] %s 结构不一致: %r vs %r" % (k, s["fn"], s, o))
            continue
        for ci, (sa, oa) in enumerate(zip(s["outputs"], o["outputs"])):
            sa = sa if isinstance(sa, list) else [sa]
            oa = oa if isinstance(oa, list) else [oa]
            if len(sa) != len(oa):
                issues.append("[%d] %s#%d 长度 %d vs %d" % (k, s["fn"], ci, len(sa), len(oa)))
                continue
            for i, (x, y) in enumerate(zip(sa, oa)):
                n_points += 1
                if (x is None) != (y is None):
                    issues.append("[%d] %s#%d[%d] NaN 位不一致: %r vs %r"
                                  % (k, s["fn"], ci, i, x, y))
                elif isinstance(x, bool) or isinstance(y, bool):
                    if x != y:
                        issues.append("[%d] %s#%d[%d] bool 不一致: %r vs %r"
                                      % (k, s["fn"], ci, i, x, y))
                elif x is None:
                    pass  # 双侧 NaN
                elif abs(x - y) > ATOL + RTOL * abs(y):
                    issues.append("[%d] %s#%d[%d] 超容差: %r vs %r (|diff|=%g)"
                                  % (k, s["fn"], ci, i, x, y, abs(x - y)))
                if len(issues) >= 20:
                    return issues, n_points
    return issues, n_points


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", action="store_true",
                        help="另外生成 KlineTests/Fixtures/mytt_functions.json")
    args = parser.parse_args()

    spec = _build_spec()
    print("pandas 版本: %s" % getattr(orig.pd, "__version__", "未知"))
    print("序列: %s × %d bar，calls: %d 条（覆盖 %d 个函数）"
          % (" / ".join(spec["series"]), len(spec["series"]["C"]),
             len(spec["calls"]), len(shim._FN_NAMES)))

    # 1) 函数层差分（垫片直调 vs pandas 原版直调，双侧对称无副本）
    shim_func = _run_calls(shim._FN_TABLE, spec, copy_args=False)
    orig_res = _run_calls(ORIG_TABLE, spec, copy_args=False)
    issues, pts = _diff(shim_func, orig_res, "函数层")
    print("函数层差分: %d 输出点，%d 个问题" % (pts, len(issues)))
    for msg in issues:
        print("  " + msg)
    if issues:
        sys.exit(1)

    # 2) op 层全链（kline_input 注入，与 Swift 桥接同构）
    shim_op = _run_op(spec)
    issues, pts = _diff(shim_op, orig_res, "op 层")
    print("op 层差分:   %d 输出点，%d 个问题" % (pts, len(issues)))
    for msg in issues:
        print("  " + msg)
    if issues:
        sys.exit(1)

    # 3) golden fixture（expected = pandas 2.2.3 原版输出）
    if args.fixture:
        fixture = {
            "series": spec["series"],
            "calls": spec["calls"],
            "expected": orig_res,
        }
        out = os.path.join(REPO, "KlineTests", "Fixtures", "mytt_functions.json")
        with open(out, "w", encoding="utf-8") as f:
            json.dump(fixture, f, ensure_ascii=False)
        print("fixture 已生成: %s（%d calls）" % (out, len(orig_res)))

    print("差分验证全部通过 ✔")


if __name__ == "__main__":
    main()

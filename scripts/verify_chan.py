#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_chan.py — PyScripts/chan.py（语义移植）vs chan.py 原版全量差分验证。

用法（任意带 Python3 的 venv；chan.py 原版为纯标准库 + 无第三方依赖路径）：
  python3 scripts/verify_chan.py            # 差分验证
  python3 scripts/verify_chan.py --fixture  # 另外生成 golden fixture
  CHAN_SRC=/path/to/chan.py python3 ...     # 自定义原版源码位置（默认 /tmp/chanpy）

参考实现（真值源）
  - chan.py 原版（https://github.com/Vespa314/chan.py，MIT），仅作差分 oracle，
    不进 App bundle。驱动方式：CChanConfig({}) + trigger_step=False +
    CKLine_List(K_DAY) 逐 klu add_single_klu（与移植版同构的批量路径）。

验证内容
  1. fuzz 差分：随机游走 / 独立 OHLC / 高波动 / 窄幅含一字 / 退化（单调/全等）
     五类语料，合并 K 线（dir/high/low/起止 klu/fx）与笔（起止 klc/起止值/
     起止峰值 klu/方向）全字段精确一致（数值为 bar 原值传递，无浮点容差）。
  2. --fixture：产出 KlineTests/Fixtures/chan_bi.json（expected 取原版输出）。
"""

import argparse
import importlib.util
import json
import os
import random
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHAN_SRC = os.environ.get("CHAN_SRC", "/tmp/chanpy")


def _load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


shim = _load(os.path.join(REPO, "Kline", "PyScripts", "chan.py"), "chan_shim")
sys.path.insert(0, CHAN_SRC)
from ChanConfig import CChanConfig  # noqa: E402
from Common.CEnum import KL_TYPE  # noqa: E402
from Common.CTime import CTime  # noqa: E402
from KLine.KLine_List import CKLine_List  # noqa: E402
from KLine.KLine_Unit import CKLine_Unit  # noqa: E402

FX_MAP = {"TOP": 1, "BOTTOM": -1, "UNKNOWN": 0}
DIR_MAP = {"UP": 1, "DOWN": -1}


# ---------------------------------------------------------------------------
# 语料生成（seed 固定，离线确定；fixture 直接复用）
# ---------------------------------------------------------------------------

def _gen_walk(rng, n):
    bars, p = [], 10.0
    for _ in range(n):
        o = p
        c = round(o + rng.uniform(-0.3, 0.3), 2)
        h = round(max(o, c) + rng.uniform(0, 0.15), 2)
        l = round(min(o, c) - rng.uniform(0, 0.15), 2)
        bars.append([o, h, l, c])
        p = c
    return bars


def _gen_indep(rng, n):
    bars = []
    for _ in range(n):
        o = round(rng.uniform(9, 11), 2)
        c = round(rng.uniform(9, 11), 2)
        h = round(max(o, c) + rng.uniform(0, 0.5), 2)
        l = round(min(o, c) - rng.uniform(0, 0.5), 2)
        bars.append([o, h, l, c])
    return bars


def _gen_volatile(rng, n):
    bars, p = [], 10.0
    for _ in range(n):
        o = p
        c = round(o + rng.uniform(-1.2, 1.2), 2)
        h = round(max(o, c) + rng.uniform(0, 0.6), 2)
        l = round(min(o, c) - rng.uniform(0, 0.6), 2)
        bars.append([o, h, l, c])
        p = c
    return bars


def _gen_flat(rng, n):
    """窄幅 + 大量一字/包含关系。"""
    bars, p = [], 10.0
    for i in range(n):
        if rng.random() < 0.4:
            bars.append([p, p, p, p])  # 一字
            continue
        o = p
        c = round(o + rng.uniform(-0.05, 0.05), 3)
        h = round(max(o, c) + rng.uniform(0, 0.03), 3)
        l = round(min(o, c) - rng.uniform(0, 0.03), 3)
        bars.append([o, h, l, c])
        p = c
    return bars


def _gen_monotone(rng, n):
    up = rng.random() < 0.5
    bars, p = [], 10.0
    for _ in range(n):
        o = p
        c = round(o + (0.1 if up else -0.1), 2)
        h = round(max(o, c) + 0.05, 2)
        l = round(min(o, c) - 0.05, 2)
        bars.append([o, h, l, c])
        p = c
    return bars


def _corpora():
    rng = random.Random(20261012)
    return {
        "walk300": _gen_walk(rng, 300),
        "walk800": _gen_walk(rng, 800),
        "indep400": _gen_indep(rng, 400),
        "volatile500": _gen_volatile(rng, 500),
        "flat400": _gen_flat(rng, 400),
        "monotone60": _gen_monotone(rng, 60),
    }


# ---------------------------------------------------------------------------
# 双侧执行器
# ---------------------------------------------------------------------------

def _run_shim(bars):
    """op 层执行：模拟 Swift 桥接注入 kline_input。"""
    dated = [[20240101 + i] + b for i, b in enumerate(bars)]
    shim.kline_input = {"op": "chan", "bars": dated}
    res = shim._main()
    if not (isinstance(res, dict) and res.get("ok") is True):
        raise SystemExit("移植版执行失败: %r" % (res,))
    return res["result"]


def _run_oracle(bars):
    """chan.py 原版：CChanConfig 默认 + trigger_step=False。"""
    conf = CChanConfig({})
    conf.trigger_step = False
    kls = CKLine_List(KL_TYPE.K_DAY, conf)
    for i, (o, h, l, c) in enumerate(bars):
        klu = CKLine_Unit({"time_key": CTime(2024, 1, 1, i // 60 % 24 + 1, i % 60),
                           "open": o, "high": h, "low": l, "close": c})
        klu.kl_type = KL_TYPE.K_DAY
        klu.set_idx(i)
        kls.add_single_klu(klu)
    klc = [{
        "idx": k.idx,
        "dir": DIR_MAP[k.dir.name],
        "high": k.high,
        "low": k.low,
        "fromKlu": k.lst[0].idx,
        "toKlu": k.lst[-1].idx,
        "fx": FX_MAP[k.fx.name],
    } for k in kls.lst]
    bi = []
    for b in kls.bi_list:
        bi.append({
            "idx": b.idx,
            "dir": 1 if b.is_up() else -1,
            "fromKlc": b.begin_klc.idx,
            "toKlc": b.end_klc.idx,
            "beginVal": b.get_begin_val(),
            "endVal": b.get_end_val(),
            "fromKlu": b.get_begin_klu().idx,
            "toKlu": b.get_end_klu().idx,
        })
    return {"klc": klc, "bi": bi}


# ---------------------------------------------------------------------------
# 差分（数值为 bar 原值传递，无浮点容差）
# ---------------------------------------------------------------------------

def _diff(s, o, label):
    issues = []
    for key in ("klc", "bi"):
        sa, oa = s.get(key, []), o.get(key, [])
        if len(sa) != len(oa):
            issues.append("%s.%s 数量不一致: %d vs %d" % (label, key, len(sa), len(oa)))
            continue
        for i, (x, y) in enumerate(zip(sa, oa)):
            if set(x.keys()) != set(y.keys()):
                issues.append("%s.%s[%d] 字段不一致: %r vs %r" % (label, key, i, sorted(x), sorted(y)))
                continue
            for f in y:
                if x[f] != y[f]:
                    issues.append("%s.%s[%d].%s: %r vs %r" % (label, key, i, f, x[f], y[f]))
        if len(issues) >= 10:
            break
    return issues


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", action="store_true",
                        help="另外生成 KlineTests/Fixtures/chan_bi.json")
    args = parser.parse_args()

    corpora = _corpora()
    all_issues = []
    fixture = {}
    for name, bars in corpora.items():
        s = _run_shim(bars)
        o = _run_oracle(bars)
        issues = _diff(s, o, name)
        n_klc, n_bi = len(o["klc"]), len(o["bi"])
        print("%-12s bars=%d klc=%d bi=%d  %s"
              % (name, len(bars), n_klc, n_bi, "✔ 零差异" if not issues else "✘ %d 问题" % len(issues)))
        for m in issues:
            print("  " + m)
        all_issues += issues
        fixture[name] = {
            "bars": [[20240101 + i] + b for i, b in enumerate(bars)],
            "expected": o,
        }
    if all_issues:
        sys.exit(1)

    if args.fixture:
        out = os.path.join(REPO, "KlineTests", "Fixtures", "chan_bi.json")
        with open(out, "w", encoding="utf-8") as f:
            json.dump(fixture, f, ensure_ascii=False)
        print("fixture 已生成: %s（%d 语料）" % (out, len(fixture)))

    print("差分验证全部通过 ✔")


if __name__ == "__main__":
    main()

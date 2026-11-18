#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全样本合法性扫描：尾部未确认段的笔数/相接/重叠/同向/末笔覆盖。只读。"""
import json, os, sys, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ab_test_v2 as A
import chan

STEPS = [1, 2, 5, 20, 50, 200, 500]


def segs_of(bars):
    cap = {}
    orig = chan._build_segs

    def spy(bis):
        cap.setdefault("bis", bis)
        return orig(bis)

    chan._build_segs = spy
    try:
        chan._op_chan({"op": "chan", "bars": bars, "config": dict(A.CFG)})
    finally:
        chan._build_segs = orig
    return cap["bis"], orig(cap["bis"])


def check(bars):
    bis, segs = segs_of(bars)
    tail = []
    for s in reversed(segs):
        if s.is_sure:
            break
        tail.append(s)
    tail.reverse()
    ev = {"tail_n": len(tail),
          "biCounts": [s.end_bi.idx - s.start_bi.idx + 1 for s in tail],
          "reasons": [s.reason for s in tail],
          "bi_lt3": sum(1 for s in tail if s.end_bi.idx - s.start_bi.idx + 1 < 3),
          "gap": 0, "overlap": 0, "same_dir": 0,
          "uncovered_last": 0, "eigen_none": sum(1 for s in tail if s.eigen_fx is None)}
    for i in range(len(tail) - 1):
        a, b = tail[i], tail[i + 1]
        if b.start_bi.idx <= a.end_bi.idx:
            ev["overlap"] += 1
        elif b.start_bi.idx != a.end_bi.idx + 1:
            ev["gap"] += 1
        if a.dir == b.dir:
            ev["same_dir"] += 1
    if tail and tail[-1].end_bi.idx != bis[-1].idx:
        ev["uncovered_last"] = bis[-1].idx - tail[-1].end_bi.idx
    return ev


def run(path):
    d = json.load(open(path))
    bars = A.normalize(d["bars"])
    n = len(bars)
    A.bar_hi = [b[2] for b in bars]
    A.bar_lo = [b[3] for b in bars]
    agg = collections.Counter()
    tdist = collections.Counter()
    lt3 = collections.Counter()
    max_extra = 0
    samples = 0

    def rec(sub):
        nonlocal max_extra, samples
        ev = check(sub)
        samples += 1
        tdist[ev["tail_n"]] += 1
        agg["gap"] += ev["gap"]
        agg["overlap"] += ev["overlap"]
        agg["same_dir"] += ev["same_dir"]
        agg["approx_uncovered"] += (1 if ev["uncovered_last"] else 0)
        agg["eigen_none_total"] += ev["eigen_none"]
        agg["seg_total"] += ev["tail_n"]
        lt3[ev["bi_lt3"]] += 1
        max_extra = max(max_extra, ev["tail_n"] - 1)

    rec(bars)
    for f in (0.20, 0.55, 0.85):
        n0 = int(n * f)
        for m in range(0, 201):
            rec(bars[:n0 + m])
    for f in (0.10, 0.20, 0.35, 0.50, 0.65, 0.80, 0.90):
        n0 = int(n * f)
        for m in STEPS:
            if n0 + m < n:
                rec(bars[:n0 + m])
    return {"code": d.get("code"), "name": d.get("name"), "samples": samples,
            "tail_dist": dict(sorted(tdist.items())), "max_extra_solid": max_extra,
            "sum": dict(agg), "lt3_dist": dict(sorted(lt3.items()))}


if __name__ == "__main__":
    out = [run(p) for p in sys.argv[1:]]
    for r in out:
        print("\n===== %s %s 样本=%d =====" % (r["code"], r["name"], r["samples"]))
        print(" 尾部未确认段数分布=%s" % r["tail_dist"])
        print(" 若只画末段虚线，多出的实线段最多 %d 条" % r["max_extra_solid"])
        print(" 累计：尾部段 %d 条，其中 eigen_fx=None %d 条；gap=%d overlap=%d same_dir=%d 末笔未覆盖样本=%d" % (
            r["sum"]["seg_total"], r["sum"]["eigen_none_total"], r["sum"]["gap"],
            r["sum"]["overlap"], r["sum"]["same_dir"], r["sum"]["approx_uncovered"]))
        print(" 含 biCount<3 段的样本数分布=%s" % r["lt3_dist"])
    json.dump(out, open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     "tail_legality.json"), "w"),
              ensure_ascii=False, indent=1)

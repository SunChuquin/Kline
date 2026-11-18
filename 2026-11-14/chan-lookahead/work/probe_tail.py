#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""核实尾部 >=3 个未确认段：实例字段、合法性、后续演化。只读。"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ab_test_v2 as A
import chan


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


def tail_info(bars):
    bis, segs = segs_of(bars)
    segs = [s for s in segs if s.reason != "collect_left_as_seg"]
    tail = []
    for s in reversed(segs):
        if s.is_sure:
            break
        tail.append(s)
    tail.reverse()
    return bis, segs, tail


def desc(s):
    return {
        "idx": s.idx, "dir": s.dir,
        "startBi": s.start_bi.idx, "endBi": s.end_bi.idx,
        "biCount": s.end_bi.idx - s.start_bi.idx + 1,
        "beginVal": round(s.get_begin_val(), 2), "endVal": round(s.get_end_val(), 2),
        "reason": s.reason, "confirmed": s.is_sure,
        "eigen_none": s.eigen_fx is None,
        "eigen_gap": None if s.eigen_fx is None else
        [e.gap for e in s.eigen_fx.ele if e is not None],
    }


def legality(tail, bis):
    issues = []
    for i, s in enumerate(tail):
        n = s.end_bi.idx - s.start_bi.idx + 1
        if n < 3:
            issues.append("idx%d biCount=%d <3（%s）" % (s.idx, n, s.reason))
        if s.start_bi.idx > s.end_bi.idx:
            issues.append("idx%d startBi>endBi" % s.idx)
    for i in range(len(tail) - 1):
        a, b = tail[i], tail[i + 1]
        if b.start_bi.idx <= a.end_bi.idx:
            issues.append("idx%d/%d 重叠或未右移 (%d<=%d)" % (
                a.idx, b.idx, b.start_bi.idx, a.end_bi.idx))
        elif b.start_bi.idx != a.end_bi.idx + 1:
            issues.append("idx%d/%d 不相接 gap=%d" % (
                a.idx, b.idx, b.start_bi.idx - a.end_bi.idx - 1))
        if b.dir == a.dir:
            issues.append("idx%d/%d 同向 dir=%d" % (a.idx, b.idx, a.dir))
    if tail and bis and tail[-1].end_bi.idx != bis[-1].idx:
        issues.append("末段 endBi=%d != 末笔 idx=%d" % (
            tail[-1].end_bi.idx, bis[-1].idx))
    return issues


CASES = [
    ("daily_2085.json", "999999", 3067, 1),
    ("daily_2085.json", "999999", 3067, 2),
    ("daily_3581.json", "399001", 3051, 1),
    ("daily_3581.json", "399001", 3051, 2),
    ("daily_11.json", "HSI", 909, 200),
    ("daily_2087.json", "000002", 4258, 1),
]

if __name__ == "__main__":
    out = []
    for fn, code, n0, m in CASES:
        d = json.load(open(fn))
        bars = A.normalize(d["bars"])
        A.bar_hi = [b[2] for b in bars]
        A.bar_lo = [b[3] for b in bars]
        bis, segs, tail = tail_info(bars[:n0 + m])
        rec = {"case": "%s n0=%d +%d" % (code, n0, m),
               "n_bi": len(bis), "n_seg": len(segs),
               "tail_n": len(tail), "tail": [desc(s) for s in tail],
               "issues": legality(tail, bis)}
        # 后续演化：这些尾部段在 +2/+5/+20/+50/+200 后剩几个、并到哪
        evo = []
        for dm in (1, 2, 5, 20, 50, 200):
            if n0 + m + dm > len(bars):
                continue
            _, _, t2 = tail_info(bars[:n0 + m + dm])
            evo.append({"step": "+%d" % dm, "tail_n": len(t2),
                        "tail": [(s.reason, s.start_bi.idx, s.end_bi.idx) for s in t2]})
        rec["evolution"] = evo
        out.append(rec)
        print("\n=== %s : bi=%d seg=%d tail=%d ===" % (
            rec["case"], rec["n_bi"], rec["n_seg"], rec["tail_n"]))
        for t in rec["tail"]:
            print("  " + json.dumps(t, ensure_ascii=False))
        print("  合法性：%s" % ("全部满足" if not rec["issues"] else rec["issues"]))
        for e in rec["evolution"]:
            print("  %s -> tail=%d %s" % (e["step"], e["tail_n"], e["tail"]))
    json.dump(out, open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     "tail_multi.json"), "w"),
              ensure_ascii=False, indent=1)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""统计「一次改多个中枢」的触发条件：尾部未确认段的规模 vs 中枢改写个数。"""
import json, os, sys, statistics
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ab_test_v2 as A


def tail_info(res):
    segs = res["segments"]
    sure = [s for s in segs if s.get("confirmed")]
    last_sure_end = sure[-1]["endBi"] if sure else -1
    unsure = [s for s in segs if not s.get("confirmed")]
    first_unsure_start = unsure[0]["startBi"] if unsure else None
    return {
        "last_sure_end_bi": last_sure_end,
        "unsure_n": len(unsure),
        "unsure_bi": sum(s["biCount"] for s in unsure),
        "max_unsure_bi": max([s["biCount"] for s in unsure] or [0]),
        "unsure_bars": (res["bi"][-1]["toKlu"] - res["bi"][first_unsure_start]["fromKlu"] + 1)
                       if unsure else 0,
        # 最后一段（未确认）的跨度，最能代表"尾部未定型区"
        "last_seg_bi": unsure[-1]["biCount"] if unsure else 0,
        "last_seg_bars": (res["bi"][unsure[-1]["endBi"]]["toKlu"]
                          - res["bi"][unsure[-1]["startBi"]]["fromKlu"] + 1) if unsure else 0,
    }


def cen_changes(base, new):
    ob = {c["beginLine"]: c for c in base["centers"]}
    nb = {c["beginLine"]: c for c in new["centers"]}
    gone = [k for k in ob if k not in nb]
    changed = [k for k in ob if k in nb and A.diff(ob[k], nb[k], A.CEN_FIELDS)[0]]
    return len(gone), len(changed), gone, changed


def run(path, steps=200):
    d = json.load(open(path))
    bars = A.normalize(d["bars"])
    n = len(bars)
    A.bar_hi = [b[2] for b in bars]
    A.bar_lo = [b[3] for b in bars]
    rows = []
    for f in (0.20, 0.55, 0.85):
        n0 = int(n * f)
        cur = A.run(bars[:n0])
        for m in range(1, steps + 1):
            nxt = A.run(bars[:n0 + m])
            ti = tail_info(cur)
            g, c, gone, changed = cen_changes(cur, nxt)
            ti.update({"n0": n0, "step": m, "cen_gone": g, "cen_changed": c,
                       "cen_total": g + c, "gone_lines": gone[:8], "changed_lines": changed[:8]})
            rows.append(ti)
            cur = nxt
    return {"code": d.get("code"), "name": d.get("name"), "rows": rows}


def summarize(rep):
    rows = rep["rows"]
    multi = [r for r in rows if r["cen_total"] >= 2]
    one = [r for r in rows if r["cen_total"] == 1]
    zero = [r for r in rows if r["cen_total"] == 0]
    print("\n== %s %s：%d 步逐根追加 ==" % (rep["code"], rep["name"], len(rows)))
    print(" 中枢改写 0/1/≥2 的步数：%d / %d / %d  (≥2 占 %.1f%%)" % (
        len(zero), len(one), len(multi), 100.0 * len(multi) / max(1, len(rows))))
    if multi:
        print(" ≥2 时的最后未确认段跨度：bi %s | bars %s" % (
            [r["last_seg_bi"] for r in multi][:12], [r["last_seg_bars"] for r in multi][:12]))
        print(" ≥2 时的未确认段数量：%s" % [r["unsure_n"] for r in multi][:12])
        print(" 实例：%s" % [(r["n0"], r["step"], r["last_seg_bi"], r["last_seg_bars"],
                           r["cen_total"], r["gone_lines"][:4]) for r in multi[:6]])
    if one:
        print(" =1 时的最后未确认段跨度：中位 bi=%.1f bars=%.1f" % (
            statistics.median([r["last_seg_bi"] for r in one]),
            statistics.median([r["last_seg_bars"] for r in one])))
    # 按尾段笔数分桶，看多中枢改写的条件概率
    buckets = [(0, 3), (4, 6), (7, 10), (11, 20), (21, 999)]
    for lo, hi in buckets:
        sub = [r for r in rows if lo <= r["last_seg_bi"] <= hi]
        if not sub:
            continue
        mm = sum(1 for r in sub if r["cen_total"] >= 2)
        print("  尾段 %d-%d 笔：%4d 步，多中枢改写 %3d 步（%.1f%%）" % (
            lo, hi, len(sub), mm, 100.0 * mm / len(sub)))


if __name__ == "__main__":
    outs = [run(p) for p in sys.argv[1:]]
    for o in outs:
        summarize(o)
    json.dump([{k: o[k] for k in ("code", "name")} | {"multi": [
        {kk: r[kk] for kk in ("n0", "step", "last_seg_bi", "last_seg_bars", "unsure_n",
                              "cen_total", "gone_lines", "changed_lines")}
        for r in o["rows"] if r["cen_total"] >= 2]} for o in outs],
        open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "mechanism_stats.json"), "w"),
        ensure_ascii=False, indent=1)

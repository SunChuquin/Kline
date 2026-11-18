#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""统计「同时存在的未确认段」：头部占位 vs 尾部演进，数量分布与 reason 构成。

只读分析，不改 chan.py。
"""
import json, os, sys, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ab_test_v2 as A

STEPS = [1, 2, 5, 20, 50, 200, 500]


def seg_stats(res):
    segs = res["segments"]
    flags = [bool(s.get("confirmed")) for s in segs]
    n = len(segs)
    # 头部未确认：从 0 开始连续未确认
    head = 0
    while head < n and not flags[head]:
        head += 1
    # 尾部未确认：从末尾往前连续未确认
    tail = 0
    while tail < n and not flags[n - 1 - tail]:
        tail += 1
    mid = sum(1 for i in range(head, n - tail) if not flags[i])
    return {"n_seg": n, "n_unsure": sum(1 for f in flags if not f),
            "head": head, "tail": tail, "mid": mid,
            "tail_reasons": [segs[n - 1 - i].get("reason") for i in range(tail)][::-1],
            "head_reasons": [segs[i].get("reason") for i in range(head)]}


def scan(path):
    d = json.load(open(path))
    bars = A.normalize(d["bars"])
    n = len(bars)
    A.bar_hi = [b[2] for b in bars]
    A.bar_lo = [b[3] for b in bars]
    acc = {m: {"tot": collections.Counter(), "tail": collections.Counter(),
               "max_tail": 0, "mid_bad": 0, "head_max": 0,
               "tail3_ex": []} for m in ("full", "seq", "batch")}

    def rec(res, mode, tag):
        st = seg_stats(res)
        a = acc[mode]
        a["tot"][st["n_unsure"]] += 1
        a["tail"][st["tail"]] += 1
        a["max_tail"] = max(a["max_tail"], st["tail"])
        a["head_max"] = max(a["head_max"], st["head"])
        if st["mid"]:
            a["mid_bad"] += 1
        if st["tail"] >= 3 and len(a["tail3_ex"]) < 5:
            a["tail3_ex"].append({"tag": tag, "tail": st["tail"],
                                  "reasons": st["tail_reasons"],
                                  "bi_counts": [s["biCount"] for s in res["segments"][-st["tail"]:]]})

    rec(A.run(bars), "full", "full")
    for f in (0.20, 0.55, 0.85):
        n0 = int(n * f)
        for m in range(0, 201):
            rec(A.run(bars[:n0 + m]), "seq", "seq n0=%d +%d" % (n0, m))
    for f in (0.10, 0.20, 0.35, 0.50, 0.65, 0.80, 0.90):
        n0 = int(n * f)
        for m in STEPS:
            if n0 + m < n:
                rec(A.run(bars[:n0 + m]), "batch", "batch n0=%d +%d" % (n0, m))
    return {"code": d.get("code"), "name": d.get("name"), "n": n, "acc": acc}


if __name__ == "__main__":
    work = os.path.dirname(os.path.abspath(__file__))
    res = [scan(p) for p in sys.argv[1:]]
    for r in res:
        print("\n===== %s %s n=%d =====" % (r["code"], r["name"], r["n"]))
        for mode, label in (("full", "全量"), ("seq", "逐根追加 3×201"), ("batch", "批量追加 7×7")):
            a = r["acc"][mode]
            tot = sum(a["tot"].values())
            t = a["tail"]
            le1 = t[0] + t[1]
            eq2 = t[2]
            ge3 = tot - le1 - eq2
            print(" [%s] 样本=%d 未确认段总数分布=%s" % (
                label, tot, dict(sorted(a["tot"].items()))))
            print("        尾段未确认数分布=%s | 最大尾段=%d 头部最大=%d 中间未确认异常=%d" % (
                dict(sorted(t.items())), a["max_tail"], a["head_max"], a["mid_bad"]))
            print("        尾段=2 占 %.1f%% | 尾段>=3 占 %.1f%%" % (
                100.0 * eq2 / max(1, tot), 100.0 * ge3 / max(1, tot)))
            for e in a["tail3_ex"]:
                print("        >=3 例：%s tail=%d reasons=%s biCounts=%s" % (
                    e["tag"], e["tail"], e["reasons"], e["bi_counts"]))

    # HSI n0=4094 专项
    for p in sys.argv[1:]:
        if "daily_11.json" in p:
            d = json.load(open(p))
            bars = A.normalize(d["bars"])
            A.bar_hi = [b[2] for b in bars]
            A.bar_lo = [b[3] for b in bars]
            print("\n[HSI n0=4094 -> +50 段尾部]")
            for n0 in (4094, 4144):
                segs = A.run(bars[:n0])["segments"]
                print(" bars[:%d] n_seg=%d 未确认=%d" % (
                    n0, len(segs), sum(1 for s in segs if not s["confirmed"])))
                for s in segs[-4:]:
                    print("   " + json.dumps({k: s[k] for k in (
                        "idx", "dir", "startBi", "endBi", "biCount", "confirmed",
                        "reason", "beginVal", "endVal")}, ensure_ascii=False))

    json.dump([{k: r[k] for k in ("code", "name", "n")} |
               {"acc": {m: {"tot": dict(v["tot"]), "tail": dict(v["tail"]),
                            "max_tail": v["max_tail"], "mid_bad": v["mid_bad"],
                            "head_max": v["head_max"], "tail3_ex": v["tail3_ex"]}
                        for m, v in r["acc"].items()}} for r in res],
              open(os.path.join(work, "unsure_seg_stats.json"), "w"),
              ensure_ascii=False, indent=1)

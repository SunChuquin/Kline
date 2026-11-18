#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""截断等价性大样本扫描：每个标的上百个随机截断点，统计内部项不一致的频率与影响跨度。"""
import sys, os, json, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ab_test_v2 as A


def sweep(path, nk=120, seed=3):
    d = json.load(open(path))
    bars = A.normalize(d["bars"])
    n = len(bars)
    A.bar_hi = [b[2] for b in bars]
    A.bar_lo = [b[3] for b in bars]
    full = A.run(bars)
    random.seed(seed)
    ks = sorted(random.sample(range(300, n - 2), nk))
    rows = [A.prefix_cmp(full, A.run(bars[:k + 1]), k) for k in ks]
    out = {"code": d.get("code"), "name": d.get("name"), "n": n, "nk": nk,
           "bi_mm": sum(1 for r in rows if r["bi"]["mismatch"] or r["bi"]["missing"]),
           "seg_mm": sum(1 for r in rows if r["segments"]["mismatch"] or r["segments"]["missing"]),
           "cen_mm": sum(1 for r in rows if r["centers"]["mismatch"] or r["centers"]["missing"]),
           "bi_maxdev": max([r["bi"]["max_dev"] for r in rows] or [0]),
           "seg_maxdev": max([r["segments"]["max_dev"] for r in rows] or [0]),
           "cen_maxdev": max([r["centers"]["max_dev"] for r in rows] or [0]),
           "cen_spans": [r["centers"]["affected_from_k"] for r in rows
                         if r["centers"]["affected_from_k"] is not None],
           "cen_bi_spans": [r["centers"]["affected_bi_from_tail"] for r in rows
                            if r["centers"]["affected_bi_from_tail"] is not None],
           "seg_bi_spans": [r["segments"]["affected_bi_from_tail"] for r in rows
                            if r["segments"]["affected_bi_from_tail"] is not None],
           "tail_cases": {c: sum(1 for r in rows if r["bi"]["tail"].get("case") == c)
                          for c in ("same_bi", "partial_new_bi", "lost_last_bi")},
           "gap0_extended": sum(1 for r in rows if r["bi"]["tail"].get("case") == "same_bi"
                                and r["bi"]["tail"].get("extended")),
           "gap1_start_match": sum(1 for r in rows if r["bi"]["tail"].get("case") == "partial_new_bi"
                                   and r["bi"]["tail"].get("start_match")),
           "gapm1_prev": sum(1 for r in rows if r["bi"]["tail"].get("case") == "lost_last_bi"
                             and r["bi"]["tail"].get("trunc_last_is_prev")),
           "gap0_max_extend": max([abs(r["bi"]["tail"]["extend"]["d_toKlu"]) for r in rows
                                   if r["bi"]["tail"].get("case") == "same_bi"] or [0]),
           "gap1_max_delta_klu": max([abs(r["bi"]["tail"]["partial_vs_cross_final"]["d_toKlu"]) for r in rows
                                      if r["bi"]["tail"].get("case") == "partial_new_bi"] or [0]),
           "gap1_max_delta_val": max([abs(r["bi"]["tail"]["partial_vs_cross_final"]["d_endVal"]) for r in rows
                                      if r["bi"]["tail"].get("case") == "partial_new_bi"] or [0]),
           "bad_rows": [{"k": r["k"], "bi": [r["bi"]["mismatch"], r["bi"]["missing"]],
                         "seg": [r["segments"]["mismatch"], r["segments"]["missing"]],
                         "cen": [r["centers"]["mismatch"], r["centers"]["missing"]],
                         "span": r["centers"]["affected_from_k"],
                         "span_bi": r["centers"]["affected_bi_from_tail"]}
                        for r in rows
                        if r["bi"]["mismatch"] or r["bi"]["missing"] or r["segments"]["mismatch"]
                        or r["segments"]["missing"] or r["centers"]["mismatch"] or r["centers"]["missing"]]}
    print("%s %s n=%d 扫描%d个k：笔异常组=%d 段异常组=%d 中枢异常组=%d | maxdev 笔=%.3f 段=%.3f 中枢=%.3f"
          " | 中枢影响(bar)=%s 中枢影响(bi)=%s 段影响(bi)=%s | 尾部形态=%s"
          " | gap0顺延=%d(max%d) gap+1起点一致=%d/%d(max dKlu=%d,dVal=%.2f) gap-1=前一笔=%d/%d" % (
              out["code"], out["name"], n, nk, out["bi_mm"], out["seg_mm"], out["cen_mm"],
              out["bi_maxdev"], out["seg_maxdev"], out["cen_maxdev"],
              out["cen_spans"], out["cen_bi_spans"], out["seg_bi_spans"], out["tail_cases"],
              out["gap0_extended"], out["gap0_max_extend"], out["gap1_start_match"],
              out["tail_cases"]["partial_new_bi"], out["gap1_max_delta_klu"], out["gap1_max_delta_val"],
              out["gapm1_prev"], out["tail_cases"]["lost_last_bi"]))
    for b in out["bad_rows"][:8]:
        print("   异常 k=%d bi=%s seg=%s cen=%s span(bar)=%s span(bi)=%s" % (
            b["k"], b["bi"], b["seg"], b["cen"], b["span"], b["span_bi"]))
    return out


if __name__ == "__main__":
    res = [sweep(p) for p in sys.argv[1:]]
    json.dump(res, open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "ksweep.json"), "w"),
              ensure_ascii=False, indent=1)

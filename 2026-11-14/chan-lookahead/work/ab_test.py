#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""方案 C 可行性 A/B 实测：
  问题一：全量结果中「完全落在截断点 k 之前」的笔/段/中枢，是否与 bars[0..k] 重算结果一致
          （若一致 → 可实现「全量算一次 + 按右缘裁剪渲染」，平移 O(1)）。
  问题二：追加新 bar 后，全量重算会改写多少旧结构（是否严格限制在尾部）。

用法: python3 ab_test.py <daily_*.json> [--n0 1500]
产物: report_<code>.json（同目录）
"""
import sys, json, os, argparse, random

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../..', 'Kline/PyScripts'))
import chan  # noqa: E402

CFG = {"bi_algo": "clv1", "bi_min_gap": 3, "bi_fx_check": "skip",
       "bi_end_is_peak": False, "bi_last_unconfirmed": True,
       "include_segments": True, "include_centers": True, "include_seg_centers": True}

BI_FIELDS = ["dir", "fromKlc", "toKlc", "beginVal", "endVal", "fromKlu", "toKlu"]
SEG_FIELDS = ["dir", "startBi", "endBi", "beginVal", "endVal", "biCount"]
CEN_FIELDS = ["beginLine", "endLine", "beginKlu", "endKlu", "zg", "zd", "gg", "dd", "lineCount"]


def run(bars):
    out = chan._op_chan({"op": "chan", "bars": bars, "config": dict(CFG)})
    if not out.get("ok"):
        raise RuntimeError(out.get("error"))
    return out["result"]


def normalize(raw):
    bars = []
    for i, b in enumerate(raw):
        _, o, h, l, c = b
        bars.append([i, o, max(o, h, l, c), min(o, h, l, c), c])
    return bars


def diff_items(a, b, fields):
    """返回不一致字段列表 + 数值最大绝对偏差"""
    bad, maxdev = [], 0.0
    for f in fields:
        va, vb = a.get(f), b.get(f)
        if isinstance(va, (int, float)) and isinstance(vb, (int, float)):
            d = abs(float(va) - float(vb))
            if d > 1e-9:
                bad.append((f, va, vb))
                maxdev = max(maxdev, d)
        elif va != vb:
            bad.append((f, va, vb))
    return bad, maxdev


def prefix_compare(full, trunc, k):
    """比较「完全落在 [0..k]」的结构"""
    res = {}

    # ---- 笔：toKlu <= k 视为完全落在截断点之前
    fbi = [b for b in full["bi"] if b["toKlu"] <= k]
    tbi = trunc["bi"]
    bad, maxdev, samples = 0, 0.0, []
    for i in range(min(len(fbi), len(tbi))):
        d, dev = diff_items(fbi[i], tbi[i], BI_FIELDS)
        if d:
            bad += 1
            maxdev = max(maxdev, dev)
            if len(samples) < 3:
                samples.append({"i": i, "full": fbi[i], "trunc": tbi[i], "diff": d})
    res["bi"] = {"full_in": len(fbi), "trunc_total": len(tbi), "compared": min(len(fbi), len(tbi)),
                 "mismatch": bad, "max_dev": maxdev, "samples": samples,
                 "idx_equal": [x["idx"] for x in fbi[:min(len(fbi), len(tbi))]] ==
                              [x["idx"] for x in tbi[:min(len(fbi), len(tbi))]]}

    # ---- 段：以 endBi 对应的笔 toKlu <= k 视为完全落在截断点之前
    def seg_inside(s):
        e = s["endBi"]
        return 0 <= e < len(full["bi"]) and full["bi"][e]["toKlu"] <= k
    fseg = [s for s in full["segments"] if seg_inside(s)]
    tseg = [s for s in trunc["segments"]
            if 0 <= s["endBi"] < len(trunc["bi"]) and trunc["bi"][s["endBi"]]["toKlu"] <= k]
    bad, maxdev, samples = 0, 0.0, []
    for i in range(min(len(fseg), len(tseg))):
        d, dev = diff_items(fseg[i], tseg[i], SEG_FIELDS)
        if d:
            bad += 1
            maxdev = max(maxdev, dev)
            if len(samples) < 3:
                samples.append({"i": i, "full": fseg[i], "trunc": tseg[i], "diff": d})
    res["segments"] = {"full_in": len(fseg), "trunc_in": len(tseg), "compared": min(len(fseg), len(tseg)),
                       "mismatch": bad, "max_dev": maxdev, "samples": samples}

    # ---- 中枢：endKlu <= k
    fcen = [c for c in full["centers"] if c["endKlu"] <= k]
    tcen = [c for c in trunc["centers"] if c["endKlu"] <= k]
    bad, maxdev, samples = 0, 0.0, []
    for i in range(min(len(fcen), len(tcen))):
        d, dev = diff_items(fcen[i], tcen[i], CEN_FIELDS)
        if d:
            bad += 1
            maxdev = max(maxdev, dev)
            if len(samples) < 3:
                samples.append({"i": i, "full": fcen[i], "trunc": tcen[i], "diff": d})
    res["centers"] = {"full_in": len(fcen), "trunc_in": len(tcen), "compared": min(len(fcen), len(tcen)),
                      "mismatch": bad, "max_dev": maxdev, "samples": samples}
    res["full_counts"] = {"bi": len(full["bi"]), "segments": len(full["segments"]),
                          "centers": len(full["centers"]), "segCenters": len(full.get("segCenters") or [])}
    return res


def tail_uc_rule_check(full, trunc, bars, k):
    """验证「跨右缘那笔按 UC 处理」的可预测性：
    trunc 的最后一笔若 confirmed=False，则其起点应等于前一笔终点，
    终点应为 [起点..k] 内与方向一致的极值。"""
    tb = trunc["bi"]
    if len(tb) < 2 or tb[-1].get("confirmed", True):
        return {"checked": False}
    prev, uc = tb[-2], tb[-1]
    start = prev["toKlu"]
    up = uc["dir"] > 0
    best_i, best_v = start, (float("-inf") if up else float("inf"))
    for i in range(start, k + 1):
        v = bars[i][2] if up else bars[i][3]
        if (v > best_v) if up else (v < best_v):
            best_i, best_v = i, v
    ok_start = uc["fromKlu"] == start
    ok_end = uc["toKlu"] == best_i
    ok_val = abs(uc["endVal"] - best_v) < 1e-9
    # 全量里同一笔是否被确认成不同端点
    same = next((b for b in full["bi"] if b["fromKlu"] == uc["fromKlu"]), None)
    return {"checked": True, "start_ok": ok_start, "end_idx_ok": ok_end, "end_val_ok": ok_val,
            "uc": uc, "predicted": {"toKlu": best_i, "endVal": best_v},
            "full_same_start": same, "full_differs": bool(same and (same["toKlu"] != uc["toKlu"] or
                                                                     abs(same["endVal"] - uc["endVal"]) > 1e-9))}


def append_compare(base_res, new_res):
    """追加 bar 后，旧结构被改写的范围"""
    out = {}
    for name, fields, key in (("bi", BI_FIELDS, "idx"), ("segments", SEG_FIELDS, "idx"),
                              ("centers", CEN_FIELDS, "idx")):
        old = {x[key]: x for x in base_res[name]}
        new = {x[key]: x for x in new_res[name]}
        changed, samples = [], []
        for idx, o in old.items():
            n = new.get(idx)
            if n is None:
                changed.append({"idx": idx, "state": "disappeared", "old": o})
                continue
            d, dev = diff_items(o, n, fields)
            if d:
                changed.append({"idx": idx, "state": "changed", "fields": d, "old": o, "new": n})
                if len(samples) < 3:
                    samples.append(changed[-1])
        added = [i for i in new if i not in old]
        out[name] = {"old_count": len(old), "new_count": len(new), "changed": len(changed),
                     "changed_idx": [c["idx"] for c in changed], "added_idx": added,
                     "non_last_changed": [c["idx"] for c in changed if c["idx"] != max(new or [0])],
                     "samples": samples}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("data")
    ap.add_argument("--n0", type=int, default=1500)
    args = ap.parse_args()

    d = json.load(open(args.data))
    raw = d["bars"]
    bars = normalize(raw)
    n = len(bars)
    report = {"code": d.get("code"), "name": d.get("name"), "n": n,
              "range": [raw[0][0], raw[-1][0]]}

    full = run(bars)
    ks = [int(n * 0.6), int(n * 0.8), n - 1]
    # 追加若干随机截断点，扩大样本
    random.seed(11)
    ks += random.sample(range(int(n * 0.3), n - 10), 7)
    ks = sorted(set(k for k in ks if 50 < k < n - 1))

    t1 = []
    for k in ks:
        t2 = run(bars[:k + 1])
        r = prefix_compare(full, t2, k)
        r["k"] = k
        r["tail"] = tail_uc_rule_check(full, t2, bars, k)
        t1.append(r)
    report["truncation_equivalence"] = t1

    n0 = min(args.n0, n - 60)
    base = run(bars[:n0])
    t2 = []
    for m in (1, 2, 5, 20, 50):
        nxt = run(bars[:n0 + m])
        r = append_compare(base, nxt)
        r["append"] = m
        r["n0"] = n0
        t2.append(r)
    report["append_revision"] = t2

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "report_%s.json" % d.get("code", "x"))
    json.dump(report, open(out, "w"), ensure_ascii=False, indent=1)

    print("== 截断等价性 ==")
    for r in t1:
        print("k=%d bi %d/%d mismatch=%d maxdev=%.3f | seg %d/%d mismatch=%d | cen %d/%d mismatch=%d | tail=%s" % (
            r["k"], r["bi"]["mismatch"], r["bi"]["compared"], r["bi"]["mismatch"], r["bi"]["max_dev"],
            r["segments"]["mismatch"], r["segments"]["compared"], r["segments"]["mismatch"],
            r["centers"]["mismatch"], r["centers"]["compared"], r["centers"]["mismatch"],
            "n/a" if not r["tail"].get("checked") else
            "start=%s end=%s val=%s full_differs=%s" % (r["tail"]["start_ok"], r["tail"]["end_idx_ok"],
                                                        r["tail"]["end_val_ok"], r["tail"]["full_differs"])))
    print("== 追加改写 ==")
    for r in t2:
        print("append=%2d bi %d->%d changed=%s nonlast=%s | seg %d->%d changed=%s | cen %d->%d changed=%s nonlast=%s" % (
            r["append"], r["bi"]["old_count"], r["bi"]["new_count"], r["bi"]["changed_idx"], r["bi"]["non_last_changed"],
            r["segments"]["old_count"], r["segments"]["new_count"], r["segments"]["changed_idx"],
            r["centers"]["old_count"], r["centers"]["new_count"], r["centers"]["changed_idx"],
            r["centers"]["non_last_changed"]))
    print("report ->", out)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""方案 C 可行性 A/B 实测 v2（真实行情，多标的）。

问题一：全量结果 struct 中「完全落在截断点 k 之前」的部分，是否与 bars[0..k] 重算逐项一致？
        分类为 [内部] 与 [尾部]，避免把「末笔/末段/末中枢本就未定型」误判成前缀不稳定。
问题二：追加新 bar 后，全量重算会改写哪些旧结构？改写深度是否严格限制在尾部？

用法: python3 ab_test_v2.py <daily_*.json> [...]
产物: reportv2_<code>.json（同目录）+ 控制台汇总
"""
import sys, json, os, argparse, random

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../..', 'Kline/PyScripts'))
import chan  # noqa: E402
import tdx_eval  # noqa: E402

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
    return [[i, b[1], max(b[1], b[2], b[3], b[4]), min(b[1], b[2], b[3], b[4]), b[4]]
            for i, b in enumerate(raw)]


def diff(a, b, fields):
    bad, maxdev = [], 0.0
    for f in fields:
        va, vb = a.get(f), b.get(f)
        if isinstance(va, (int, float)) and isinstance(vb, (int, float)):
            d = abs(float(va) - float(vb))
            if d > 1e-9:
                bad.append([f, va, vb])
                maxdev = max(maxdev, d)
        elif va != vb:
            bad.append([f, va, vb])
    return bad, maxdev


# ---------------------------------------------------------------- 问题一

def prefix_cmp(full, trunc, k):
    """把 full 中完全落在 [0..k] 的结构与 trunc 逐项对比。
    返回 {内部不一致, 尾部差异}。"""
    res = {"k": k}
    fbi = full["bi"]

    # ---- 笔：full 中 toKlu<=k 的数量 n_in，trunc 的笔数应恰为 n_in
    n_in = sum(1 for b in fbi if b["toKlu"] <= k)
    tbi = trunc["bi"]
    res["bi"] = {"n_in": n_in, "trunc_n": len(tbi), "count_gap": len(tbi) - n_in}
    interior_n = max(0, n_in - 1)
    # 内容键匹配（fromKlu 唯一），避免"某笔消失导致后续整体位移"被误判成大面积不一致
    tmap = {b["fromKlu"]: b for b in tbi}
    bad, missing, maxdev, samples, affected = 0, 0, 0.0, [], []
    for i in range(interior_n):
        fb = fbi[i]
        tb = tmap.get(fb["fromKlu"])
        if tb is None:
            missing += 1
            affected.append(fb["toKlu"])
            continue
        d, dev = diff(fb, tb, BI_FIELDS)
        if d:
            bad += 1
            maxdev = max(maxdev, dev)
            affected.append(fb["toKlu"])
            if len(samples) < 2:
                samples.append({"i": i, "full": fb, "trunc": tb, "diff": d})
    res["bi"].update({"interior_n": interior_n, "mismatch": bad, "missing": missing,
                      "max_dev": maxdev, "samples": samples,
                      "earliest_affected_klu": min(affected) if affected else None,
                      "affected_from_k": (k - min(affected)) if affected else None})

    # 尾部：gap = trunc笔数 - full中toKlu<=k的笔数，只有 -1/0/+1 三种可能
    tail = {"gap": len(tbi) - n_in}
    if n_in >= 1 and len(tbi) >= 1 and n_in < len(fbi) + 1:
        tb = tbi[-1]
        if tail["gap"] == 0:
            # 截断侧最后一笔 = full 第 n_in-1 笔（可能被 _clv1_last_unconfirmed 顺延）
            fb = fbi[n_in - 1]
            tail["case"] = "same_bi"
            tail["start_match"] = tb["fromKlu"] == fb["fromKlu"]
            tail["extended"] = tb["toKlu"] != fb["toKlu"]
            tail["extend"] = {"d_toKlu": tb["toKlu"] - fb["toKlu"],
                              "d_endVal": tb["endVal"] - fb["endVal"]}
            # 纯裁剪（不顺延）会产生的误差
            tail["clip_only_err"] = {"d_toKlu": -tail["extend"]["d_toKlu"],
                                     "d_endVal": -tail["extend"]["d_endVal"]}
        elif tail["gap"] == 1:
            # 截断侧多出一笔：full 的跨右缘笔（第 n_in 笔）的"半截版"
            cross = fbi[n_in]
            tail["case"] = "partial_new_bi"
            tail["start_match"] = tb["fromKlu"] == cross["fromKlu"] and tb["dir"] == cross["dir"]
            tail["cross_full"] = cross
            tail["partial_vs_cross_final"] = {"d_toKlu": tb["toKlu"] - cross["toKlu"],
                                              "d_endVal": tb["endVal"] - cross["endVal"]}
        else:  # -1：截断侧丢了 full 的最后一笔（末分型在 k 处尚未成立）
            fb = fbi[n_in - 1]
            prev = fbi[n_in - 2] if n_in >= 2 else None
            tail["case"] = "lost_last_bi"
            tail["lost"] = fb
            tail["trunc_last_is_prev"] = bool(prev and tb["fromKlu"] == prev["fromKlu"]
                                              and tb["toKlu"] == prev["toKlu"])
            tail["lost_span"] = {"toKlu": fb["toKlu"], "beginVal": fb["beginVal"],
                                 "endVal": fb["endVal"]}
        tail["trunc_tail"] = tb
    res["bi"]["tail"] = tail

    # ---- 段：full 中 endBi <= n_in-1 视为落在截断内；按 startBi 匹配
    fseg = full["segments"]
    inside = [s for s in fseg if s["endBi"] <= n_in - 1]
    tseg = trunc["segments"]
    res["segments"] = {"n_in": len(inside), "trunc_n": len(tseg), "count_gap": len(tseg) - len(inside)}
    interior_n = max(0, len(inside) - 1)
    tmap = {s["startBi"]: s for s in tseg}
    bad, missing, maxdev, samples, affected = 0, 0, 0.0, [], []
    for i in range(interior_n):
        fs = inside[i]
        ts = tmap.get(fs["startBi"])
        if ts is None:
            missing += 1
            affected.append(fs["endBi"])
            continue
        d, dev = diff(fs, ts, SEG_FIELDS)
        if d:
            bad += 1
            maxdev = max(maxdev, dev)
            affected.append(fs["endBi"])
            if len(samples) < 2:
                samples.append({"i": i, "full": fs, "trunc": ts, "diff": d})
    res["segments"].update({"interior_n": interior_n, "mismatch": bad, "missing": missing,
                            "max_dev": maxdev, "samples": samples,
                            "affected_bi_from_tail": (n_in - 1 - min(affected)) if affected else None})
    if inside and tseg:
        d, _ = diff(inside[-1], tseg[-1], SEG_FIELDS)
        res["segments"]["tail_same"] = not d
        res["segments"]["tail_diff"] = d

    # ---- 中枢：full 中 endLine <= n_in-1 视为落在截断内；按 beginLine 匹配
    fcen = full["centers"]
    inside = [c for c in fcen if c["endLine"] <= n_in - 1]
    tcen = trunc["centers"]
    res["centers"] = {"n_in": len(inside), "trunc_n": len(tcen), "count_gap": len(tcen) - len(inside)}
    interior_n = max(0, len(inside) - 1)
    tmap = {c["beginLine"]: c for c in tcen}
    bad, missing, maxdev, samples, affected, affected_line = 0, 0, 0.0, [], [], []
    for i in range(interior_n):
        fc = inside[i]
        tc = tmap.get(fc["beginLine"])
        if tc is None:
            missing += 1
            affected.append(fc["endKlu"])
            affected_line.append(fc["endLine"])
            continue
        d, dev = diff(fc, tc, CEN_FIELDS)
        if d:
            bad += 1
            maxdev = max(maxdev, dev)
            affected.append(fc["endKlu"])
            affected_line.append(fc["endLine"])
            if len(samples) < 2:
                samples.append({"i": i, "full": fc, "trunc": tc, "diff": d})
    res["centers"].update({"interior_n": interior_n, "mismatch": bad, "missing": missing,
                           "max_dev": maxdev, "samples": samples,
                           "earliest_affected_klu": min(affected) if affected else None,
                           "affected_from_k": (k - min(affected)) if affected else None,
                           "affected_bi_from_tail": (n_in - 1 - max(affected_line)) if affected_line else None})
    if inside and tcen:
        d, _ = diff(inside[-1], tcen[-1], CEN_FIELDS)
        res["centers"]["tail_same"] = not d
        res["centers"]["tail_diff"] = d
        # 末中枢在截断后是否「还没长到全量那么长」
        res["centers"]["tail_extent_gap"] = {
            "d_endLine": inside[-1]["endLine"] - tcen[-1]["endLine"],
            "d_endKlu": inside[-1]["endKlu"] - tcen[-1]["endKlu"]}
    return res


# ---------------------------------------------------------------- 问题二

def append_cmp(base, new):
    """按「内容键」匹配（避免中枢/段序号整体位移被误判成大面积改写）：
    笔=fromKlu（起点唯一）、段=startBi、中枢=beginLine。"""
    keys = {"bi": "fromKlu", "segments": "startBi", "centers": "beginLine"}
    out = {}
    for name, fields in (("bi", BI_FIELDS), ("segments", SEG_FIELDS), ("centers", CEN_FIELDS)):
        key = keys[name]
        old_list = base[name]
        old = {x[key]: (i, x) for i, x in enumerate(old_list)}
        nw = {x[key]: (i, x) for i, x in enumerate(new[name])}
        old_last_pos = len(old_list) - 1
        changed, disappeared, interior = [], [], []
        for kk, (pos, o) in old.items():
            if kk not in nw:
                disappeared.append({"pos": pos, key: kk})
                continue
            npos, n = nw[kk]
            d, _ = diff(o, n, fields)
            if d:
                changed.append({"pos": pos, "key": kk, "fields": [x[0] for x in d],
                                "old": o, "new": n})
                structural = any(f.startswith(("from", "begin", "start", "dir")) for f, _, _ in d)
                # 只改端点=顺延；改起点/结构=位移或重构；末项之外都记内部
                if pos != old_last_pos or structural:
                    interior.append(pos)
        out[name] = {"old_n": len(old), "new_n": len(nw),
                     "changed": len(changed), "disappeared": len(disappeared),
                     "added": len([kk for kk in nw if kk not in old]),
                     "changed_pos": [c["pos"] for c in changed],
                     "gone_pos": [g["pos"] for g in disappeared],
                     "interior_touched": interior,
                     "max_depth_from_tail": (old_last_pos - min(interior)) if interior else 0,
                     "samples": changed[:2]}
    return out


def sequential(bars, n0, steps):
    """从 n0 起逐根追加，记录每一步的改写范围"""
    base = run(bars[:n0])
    rows = []
    prev = base
    for m in range(1, steps + 1):
        cur = run(bars[:n0 + m])
        r = append_cmp(prev, cur)
        r["step"] = m
        rows.append(r)
        prev = cur
    return rows


# ---------------------------------------------------------------- 主流程

bar_hi, bar_lo = [], []


def analyze(path):
    d = json.load(open(path))
    raw = d["bars"]
    bars = normalize(raw)
    n = len(bars)
    global bar_hi, bar_lo
    bar_hi = [b[2] for b in bars]
    bar_lo = [b[3] for b in bars]
    full = run(bars)

    ks = [int(n * 0.6), int(n * 0.8), n - 1]
    random.seed(7)
    ks += random.sample(range(int(n * 0.35), n - 5), 12)
    ks = sorted(set(k for k in ks if 200 < k < n - 1))

    t1 = [prefix_cmp(full, run(bars[:k + 1]), k) for k in ks]

    n0s = [int(n * f) for f in (0.18, 0.30, 0.45, 0.60, 0.75, 0.88, 0.95)]
    t2 = []
    for n0 in n0s:
        base = run(bars[:n0])
        for m in (1, 2, 5, 20, 50, 200, 500):
            r = append_cmp(base, run(bars[:n0 + m]))
            r["n0"], r["append"] = n0, m
            t2.append(r)

    seq = []
    for f in (0.20, 0.55, 0.85):
        for s in sequential(bars, int(n * f), 200):
            s["n0"] = int(n * f)
            seq.append(s)

    # 缓存指纹：截断点是否被正确区分
    full_b = {"O": [b[1] for b in bars], "H": bar_hi, "L": bar_lo, "C": [b[4] for b in bars]}
    fp_full = tdx_eval._bars_fingerprint(full_b)
    fp_list = []
    for k in ks[:5]:
        cut = bars[:k + 1]
        fp_list.append({"k": k, "fp_differs": tdx_eval._bars_fingerprint(
            {"O": [b[1] for b in cut], "H": [b[2] for b in cut],
             "L": [b[3] for b in cut], "C": [b[4] for b in cut]}) != fp_full})

    rep = {"code": d.get("code"), "name": d.get("name"), "n": n,
           "range": [raw[0][0], raw[-1][0]], "full_counts": {
               "bi": len(full["bi"]), "segments": len(full["segments"]),
               "centers": len(full["centers"]), "segCenters": len(full.get("segCenters") or [])},
           "truncation_equivalence": t1, "append_revision": t2, "sequential": seq,
           "fp_truncation_distinguished": fp_list}
    out = os.path.join(os.path.dirname(os.path.abspath(path)), "reportv2_%s.json" % d.get("code", "x"))
    json.dump(rep, open(out, "w"), ensure_ascii=False, indent=1)
    return rep, out


def summary(rep):
    print("\n===== %s %s n=%d 笔%d 段%d 中枢%d =====" % (
        rep["code"], rep["name"], rep["n"], rep["full_counts"]["bi"],
        rep["full_counts"]["segments"], rep["full_counts"]["centers"]))
    print("[问题一] 截断等价性（内部项必须 0 不一致；尾部单列，gap∈{-1,0,+1}）")
    print(" k      bi(内部/截断数)      seg(内部)   cen(内部)   尾巴形态")
    for r in rep["truncation_equivalence"]:
        b, s, c = r["bi"], r["segments"], r["centers"]
        tl = b["tail"]
        case = tl.get("case", "?")
        if case == "same_bi":
            extra = "start=%s ext=%s d=%s/%s clipErr=%s/%s" % (
                tl["start_match"], tl["extended"], tl["extend"]["d_toKlu"],
                round(tl["extend"]["d_endVal"], 2), tl["clip_only_err"]["d_toKlu"],
                round(tl["clip_only_err"]["d_endVal"], 2))
        elif case == "partial_new_bi":
            extra = "start=%s 半截vs全量最终 d=%s/%s" % (
                tl["start_match"], tl["partial_vs_cross_final"]["d_toKlu"],
                round(tl["partial_vs_cross_final"]["d_endVal"], 2))
        else:
            extra = "丢末笔=%s trunc末笔=前一笔?%s" % (
                tl.get("lost_span"), tl.get("trunc_last_is_prev"))
        print(" %-6d 笔 %4d mm=%d miss=%d span=%s | 段 %3d mm=%d miss=%d span=%s | 中枢 %3d mm=%d miss=%d span=%s | %-16s %s" % (
            r["k"], b["interior_n"], b["mismatch"], b["missing"], b["affected_from_k"],
            s["interior_n"], s["mismatch"], s["missing"], s["affected_bi_from_tail"],
            c["interior_n"], c["mismatch"], c["missing"], c["affected_from_k"], case, extra))
    print("[问题二] 追加改写（汇总 %d 组 n0×追加步长）" % len(rep["append_revision"]))
    rows = rep["append_revision"]
    def mx(k, f):
        return max([r[k][f] for r in rows] or [0])
    print(" 笔：最多改写 %d 笔；出现内部(非末位)改写 %d 组；最多新增 %d 笔" % (
        mx("bi", "changed"), sum(1 for r in rows if r["bi"]["interior_touched"]), mx("bi", "added")))
    print(" 段：最多改写 %d 段；出现内部改写 %d 组（最大深度 %d）；消失 %d 组" % (
        mx("segments", "changed"), sum(1 for r in rows if r["segments"]["interior_touched"]),
        mx("segments", "max_depth_from_tail"), sum(1 for r in rows if r["segments"]["disappeared"])))
    print(" 中枢：最多改写 %d 个；出现内部改写 %d 组（最大深度 %d）；消失 %d 组" % (
        mx("centers", "changed"), sum(1 for r in rows if r["centers"]["interior_touched"]),
        mx("centers", "max_depth_from_tail"), sum(1 for r in rows if r["centers"]["disappeared"])))
    print(" 逐根追加 200 步 × 3 个起始点：")
    for n0 in sorted(set(s["n0"] for s in rep["sequential"])):
        seq = [s for s in rep["sequential"] if s["n0"] == n0]
        nz = [s for s in seq if s["bi"]["changed"] or s["bi"]["disappeared"]]
        nzs = [s for s in seq if s["segments"]["changed"] or s["segments"]["disappeared"]]
        nzc = [s for s in seq if s["centers"]["changed"] or s["centers"]["disappeared"]]
        bad = [s for s in seq if s["bi"]["interior_touched"] or s["segments"]["interior_touched"]
               or s["centers"]["interior_touched"]]
        print("  n0=%-5d 笔改写 %3d/200（改>1笔 %d 次，内部 %d 次）| 段改写 %3d/200（最大深度 %d，内部 %d 次）"
              "| 中枢改写 %2d/200（最大深度 %d，内部 %d 次）" % (
                  n0, len(nz), sum(1 for s in nz if s["bi"]["changed"] > 1),
                  sum(1 for s in seq if s["bi"]["interior_touched"]),
                  len(nzs), max([s["segments"]["max_depth_from_tail"] for s in nzs] or [0]),
                  sum(1 for s in seq if s["segments"]["interior_touched"]),
                  len(nzc), max([s["centers"]["max_depth_from_tail"] for s in nzc] or [0]),
                  sum(1 for s in seq if s["centers"]["interior_touched"])))
        for s in bad[:3]:
            print("   内部改写例 step=%d bi=%s seg=%s cen=%s" % (
                s["step"], s["bi"]["interior_touched"], s["segments"]["interior_touched"],
                s["centers"]["interior_touched"]))
    print(" 缓存指纹区分截断点：%s" % all(x["fp_differs"] for x in rep["fp_truncation_distinguished"]))


if __name__ == "__main__":
    for p in sys.argv[1:]:
        rep, out = analyze(p)
        summary(rep)
        print(" ->", out)

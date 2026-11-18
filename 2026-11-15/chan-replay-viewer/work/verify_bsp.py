#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""买卖点不变量实测 + x/det 方案差异统计。

直接从交付物 outputs/index.html 里取出内联数据，按页面完全相同的还原逻辑
（关键帧 + 增量 ops）逐时点回放，逐点比对三条不变量：

  1. 首次可判定（det）后，x / kind / price 不再变化；
  2. 一旦出现永不消失；
  3. conf 只允许 0 -> 1。

并额外校验：det 不晚于当前时点（不穿越未来）、每个点在 det 时可由结构算出、
在 det-1 时算不出（首次性）。

用法：python3 verify_bsp.py
"""
import json
import os
import sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
HTML = os.path.normpath(os.path.join(HERE, "..", "outputs", "index.html"))
sys.path.insert(0, HERE)
import build_bsp as BB  # compute_points / strength / KINDS


def load_html_data():
    s = open(HTML, encoding="utf-8").read()
    a = s.index('<script id="DATA" type="application/json">')
    a = s.index(">", a) + 1
    b = s.index("</script>", a)
    return json.loads(s[a:b])


def to_maps(kf, kp):
    return {"b": {r[0]: list(r) for r in kf[0]},
            "s": {r[0]: list(r) for r in kf[1]},
            "c": {r[0]: list(r) for r in kf[2]},
            "p": {(r[0] * 8 + r[1]): list(r) for r in (kp or [])}}


def apply_p(m, ops):
    for o in ops:
        if o[0] == 6:
            m["p"][o[1] * 8 + o[2]] = o[1:]
        elif o[0] == 7:
            m["p"].pop(o[1], None)


def apply_s(m, ops):
    for o in ops:
        t = o[0]
        if t == 0:
            m["b"][o[1]] = o[1:]
        elif t == 1:
            m["b"].pop(o[1], None)
        elif t == 2:
            m["s"][o[1]] = o[1:]
        elif t == 3:
            m["s"].pop(o[1], None)
        elif t == 4:
            m["c"][o[1]] = o[1:]
        elif t == 5:
            m["c"].pop(o[1], None)


def check_code(code, d, want_recompute=True):
    total = d["n"] - d["k0"]
    KF = d["kf"]
    res = {"code": code, "name": d["name"], "points": total, "bad": Counter()}

    # ---- 第一遍：只回放买卖点，检查三条不变量 ----
    m = to_maps([[], [], []], d["pkey"][0])
    first = {}          # key -> [i, x, kind, price, conf]
    dead = set()
    nmark = 0
    prev_keys = set(m["p"])
    for i in range(total):
        if i > 0:
            apply_p(m, d["pd"][i - 1])
        keys = set(m["p"])
        for k in prev_keys - keys:
            res["bad"]["disappear"] += 1
            dead.add(k)
        for k, rec in m["p"].items():
            if k not in first:
                first[k] = [i, rec[0], rec[1], rec[2], rec[4], rec[5]]
                nmark += 1
                if rec[3] != d["k0"] + i:
                    res["bad"]["det_ne_first_k"] += 1
                if k in dead:
                    res["bad"]["appear_again"] += 1
            else:
                f = first[k]
                if rec[0] != f[1] or rec[1] != f[2] or abs(rec[2] - f[3]) > 1e-9:
                    res["bad"]["changed"] += 1
                if rec[4] < f[4]:
                    res["bad"]["conf_back"] += 1
                if rec[4] > f[4]:
                    f[4] = rec[4]
            if rec[3] > d["k0"] + i:
                res["bad"]["future"] += 1
            if rec[0] != rec[3]:
                res["bad"]["x_ne_det"] += 1
        prev_keys = keys
    res["marks"] = nmark

    # ---- 第二遍：回放结构，校验「det 时可算出 / det-1 时算不出 / 锚点确是当时笔末端」----
    if want_recompute:
        sm = to_maps(d["key"][0], [])
        xs = sorted(first.items(), key=lambda kv: kv[1][0])
        ptr = 0
        for i in range(total):
            if i > 0:
                apply_s(sm, d["d"][i - 1])
            while ptr < len(xs) and xs[ptr][1][0] == i:
                key, f = xs[ptr]
                anchor, kind = f[5], f[2]
                akey = anchor * 8 + kind
                bis = sorted(sm["b"].values(), key=lambda r: r[0])
                cens = sorted(sm["c"].values(), key=lambda r: r[0])
                cur = BB.compute_points(bis, cens)
                if akey not in cur:
                    res["bad"]["not_computable_at_det"] += 1
                else:
                    c = cur[akey]
                    if c[0] != anchor or c[1] != kind:
                        res["bad"]["recompute_mismatch"] += 1
                if not any(b[1] == anchor for b in bis):
                    res["bad"]["anchor_not_on_bi_end"] += 1
                ptr += 1
        # 首次性：det-1 处算不出
        sm2 = to_maps(d["key"][0], [])
        by_det = defaultdict(list)
        for key, f in first.items():
            by_det[f[0]].append(f)
        for i in range(total):
            if i > 0:
                apply_s(sm2, d["d"][i - 1])
            if i + 1 in by_det:
                bis = sorted(sm2["b"].values(), key=lambda r: r[0])
                cens = sorted(sm2["c"].values(), key=lambda r: r[0])
                pre = BB.compute_points(bis, cens)
                for f in by_det[i + 1]:
                    if (f[5] * 8 + f[2]) in pre:
                        res["bad"]["computable_before_det"] += 1

    # ---- 信号滞后与价格偏离 ----
    rows = []
    for key, f in first.items():
        rec = m["p"].get(key)
        det = rec[3] if rec else d["k0"] + f[0]
        bars = d["bars"]
        anchor = f[5]
        ext = bars[anchor][3] if f[2] < 3 else bars[anchor][2]
        rows.append({"key": key, "x": f[1], "kind": BB.KINDS[f[2]], "price": f[3],
                     "det": det, "anchor": anchor, "lag": det - anchor,
                     "conf": rec[4] if rec else f[4], "extreme": ext,
                     "dev_pct": (f[3] - ext) / abs(ext) * 100 if ext else 0})
    res["rows"] = rows
    return res


def main():
    data = load_html_data()
    codes = ["600010", "999999", "399001", "000002", "HSI", "002613"]
    allbad = Counter()
    allrows = []
    total_pts = 0
    print("=" * 88)
    print("一、三条不变量逐时点检查（数据取自 outputs/index.html 内联 JSON，与页面还原逻辑一致）")
    print("=" * 88)
    hdr = ("%-7s %6s %5s | %s" % ("标的", "时点", "信号",
           "位置/类型/价格变化  消失  conf回退  x≠det  det>k  det≠首现k  重算不符  det不可算  直前可算  锚点非笔末"))
    print(hdr)
    for c in codes:
        r = check_code(c, data[c])
        total_pts += r["points"]
        allbad.update(r["bad"])
        allrows += [dict(row, code=c) for row in r["rows"]]
        b = r["bad"]
        print("%-7s %6d %5d | %14d  %4d  %8d  %4d  %5d  %8d  %8d  %8d  %8d  %8d" % (
            c, r["points"], r["marks"], b["changed"], b["disappear"],
            b["conf_back"], b["x_ne_det"], b["future"], b["det_ne_first_k"],
            b["recompute_mismatch"], b["not_computable_at_det"],
            b["computable_before_det"], b["anchor_not_on_bi_end"]))
    print("-" * 88)
    print("合计时点 %d，合计信号 %d" % (total_pts, len(allrows)))
    print("违反汇总：", dict(allbad) if allbad else "全部为 0")
    print()

    print("=" * 78)
    print("二、信号相对结构极值的滞后与价格偏离")
    print("=" * 78)
    lags = sorted(r["lag"] for r in allrows)
    n = len(lags)
    print("信号数 %d；滞后=0 的 %d 个（当根即发）" % (n, sum(1 for g in lags if g == 0)))
    print("滞后(根)：中位 %d，均值 %.1f，P90 %d，最大 %d" % (
        lags[n // 2], sum(lags) / n, lags[int(n * 0.9)], lags[-1]))
    buckets = [(1, 5), (6, 20), (21, 50), (51, 100), (101, 240), (241, 10 ** 9)]
    for lo, hi in buckets:
        c = sum(1 for g in lags if lo <= g <= hi)
        print("  %4d~%-8s %4d 个 (%.1f%%)" % (
            lo, "%d 根" % hi if hi < 10 ** 9 else "以上", c, c * 100.0 / n))
    print()
    for c in codes:
        rs = [r for r in allrows if r["code"] == c]
        g = sorted(r["lag"] for r in rs)
        print("  %-7s 信号 %3d  滞后中位 %3d  最大 %4d" % (c, len(rs), g[len(g) // 2], g[-1]))
    print()
    for grp, lab in ((lambda r: r["kind"][0] == "B", "买点"), (lambda r: r["kind"][0] == "S", "卖点")):
        a = sorted(r["dev_pct"] for r in allrows if grp(r))
        print("%s %d 个｜信号价 vs 结构极值：中位 %.2f%%，P90 %.2f%%，绝对最大 %.2f%%" % (
            lab, len(a), a[len(a) // 2], a[int(len(a) * 0.9)], max(a, key=abs)))
    print()
    for c in codes:
        rs = [r for r in allrows if r["code"] == c]
        top = max(rs, key=lambda r: r["lag"])
        print("  %s 最大滞后：%s 信号 %d(%s) 极值 %d(%s) 滞后 %d 根" % (
            c, top["kind"], top["x"], data[c]["bars"][top["x"]][0],
            top["anchor"], data[c]["bars"][top["anchor"]][0], top["lag"]))

    json.dump({"bad": dict(allbad), "rows": allrows},
              open(os.path.join(HERE, "bsp_report.json"), "w"),
              ensure_ascii=False, separators=(",", ":"))


if __name__ == "__main__":
    main()

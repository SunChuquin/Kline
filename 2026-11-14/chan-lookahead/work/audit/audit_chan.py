#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""缠论指标实战性审计：逐根真截断回放，产出四项可证伪指标。

只读分析，不改源码。产物：audit/audit_metrics.json、audit/AUDIT.md
"""
import json, os, sys, math
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.dirname(HERE)
sys.path.insert(0, WORK)
import ab_test_v2 as A          # noqa: E402
import chan                     # noqa: E402

CFG = dict(A.CFG)
CFG["include_seg_centers"] = False   # 审计不需要段中枢，省时间

BI_FIELDS = ["dir", "fromKlc", "toKlc", "beginVal", "endVal", "fromKlu", "toKlu"]
SEG_FIELDS = ["dir", "startBi", "endBi", "beginVal", "endVal", "biCount"]
CEN_FIELDS = ["beginLine", "endLine", "beginKlu", "endKlu", "zg", "zd", "gg", "dd", "lineCount"]

TOL = 1e-9


def pct(v, q):
    if not v:
        return None
    v = sorted(v)
    i = (len(v) - 1) * q
    lo = int(math.floor(i))
    hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (i - lo)


def stats(v):
    if not v:
        return {"n": 0}
    return {"n": len(v), "median": pct(v, .5), "p75": pct(v, .75),
            "p90": pct(v, .9), "max": max(v),
            "min": min(v), "mean": sum(v) / len(v)}


def calc(bars):
    out = chan._op_chan({"op": "chan", "bars": bars, "config": dict(CFG)})
    if not out.get("ok"):
        raise RuntimeError(out.get("error"))
    return out["result"]


def items(res):
    """返回 [(type, key, obj, endbar)]，key 用 bar 级身份（抗索引位移）。"""
    bi = res.get("bi") or []
    by_idx = {b["idx"]: b for b in bi}
    out = []
    for b in bi:
        out.append(("bi", ("bi", b["fromKlu"], b["dir"]), b, b["toKlu"]))
    for s in res.get("segments") or []:
        b0 = by_idx.get(s["startBi"])
        b1 = by_idx.get(s["endBi"])
        sk = b0["fromKlu"] if b0 else -1
        eb = b1["toKlu"] if b1 else -1
        out.append(("seg", ("seg", sk, s["dir"]), s, eb))
    for c in res.get("centers") or []:
        out.append(("cen", ("cen", c["beginKlu"]), c, c["endKlu"]))
    return out


def fields_of(typ, obj):
    fs = {"bi": BI_FIELDS, "seg": SEG_FIELDS, "cen": CEN_FIELDS}[typ]
    return {f: obj.get(f) for f in fs}


def fdiff(a, b):
    bad = []
    for f in a:
        va, vb = a[f], b.get(f)
        if isinstance(va, (int, float)) and isinstance(vb, (int, float)):
            if abs(float(va) - float(vb)) > TOL:
                bad.append([f, va, vb])
        elif va != vb:
            bad.append([f, va, vb])
    return bad


class Tracker:
    def __init__(self):
        self.confirmed = {}     # key -> {"k":k,"fields":{}}
        self.viol = []          # 定稿不变性违反
        self.viol_seen = set()  # (key, field) 去重
        self.delay = {"bi": [], "seg": [], "cen": []}       # (bars, days)
        self.early = []
        self.first_conf = set()

    def feed(self, k, its, dates, record_delay):
        present = {}
        for typ, key, obj, endbar in its:
            present[key] = (typ, obj, endbar)
        for typ, key, obj, endbar in its:
            if not obj.get("confirmed"):
                continue
            if key not in self.confirmed:
                self.confirmed[key] = {"k": k, "fields": fields_of(typ, obj)}
                if k < endbar:
                    self.early.append({"type": typ, "key": list(key), "k": k, "endbar": endbar})
                if record_delay:
                    self.delay[typ].append((k - endbar, dates[k] - dates[endbar]))
            else:
                d = fdiff(self.confirmed[key]["fields"], obj)
                nd = []
                for f in d:
                    sig = (key, f[0])
                    if sig not in self.viol_seen:
                        self.viol_seen.add(sig)
                        nd.append(f)
                if nd and len(self.viol) < 300:
                    self.viol.append({"type": typ, "key": list(key), "first_k": self.confirmed[key]["k"],
                                      "now_k": k, "field_diff": nd})
        for key, rec in self.confirmed.items():
            if key in present:
                typ, obj, endbar = present[key]
                if not obj.get("confirmed"):
                    sig = (key, "confirmed")
                    if sig not in self.viol_seen and len(self.viol) < 300:
                        self.viol_seen.add(sig)
                        self.viol.append({"type": typ, "key": list(key), "first_k": rec["k"],
                                          "now_k": k, "field_diff": [["confirmed", True, False]]})
            else:
                sig = (key, "disappeared")
                if sig not in self.viol_seen and len(self.viol) < 300:
                    self.viol_seen.add(sig)
                    self.viol.append({"type": key[0], "key": list(key), "first_k": rec["k"],
                                      "now_k": k, "field_diff": [["disappeared", True, None]]})


def draft_snapshot(res, k, win=500):
    its = items(res)
    segs = [(key, o, eb) for t, key, o, eb in its if t == "seg"]
    cens = [(key, o, eb) for t, key, o, eb in its if t == "cen"]
    def frac(lst):
        vis = [o for _, o, eb in lst if eb >= k - win]
        if not vis:
            return None
        return sum(1 for o in vis if not o.get("confirmed")) / len(vis)
    # 尾部连续未确认段
    seglist = res.get("segments") or []
    t = 0
    for s in reversed(seglist):
        if s.get("confirmed"):
            break
        t += 1
    return frac(segs), frac(cens), t


def replay(bars, dates, k0, step, fine, record_start, do_delay, do_draft, do_stable):
    tr = Tracker()
    draft_seg, draft_cen, tail3, tailn = [], [], 0, []
    stable_seg, stable_cen = [], []
    n = len(bars)
    ks = list(range(k0, n, step))
    for k in ks:
        res = calc(bars[:k + 1])
        tr.feed(k, items(res), dates, record_delay=do_delay and k >= record_start)
        if do_draft:
            fs, fc, t = draft_snapshot(res, k)
            if fs is not None:
                draft_seg.append(fs)
            if fc is not None:
                draft_cen.append(fc)
            tailn.append(t)
            if t >= 3:
                tail3 += 1
        if do_stable:
            its = items(res)
            se = [eb for typ, key, o, eb in its if typ == "seg" and o.get("confirmed")]
            ce = [eb for typ, key, o, eb in its if typ == "cen" and o.get("confirmed")]
            if se:
                stable_seg.append(k - max(se))
            if ce:
                stable_cen.append(k - max(ce))
    return {"tr": tr, "draft_seg": draft_seg, "draft_cen": draft_cen,
            "tail3": tail3, "tail_n": tailn, "stable_seg": stable_seg,
            "stable_cen": stable_cen, "n_k": len(ks)}


def audit_symbol(name, raw, k0, step_full, fine_len, weekly=False):
    bars = A.normalize(raw)
    dates = [datetime.strptime(str(b[0]), "%Y%m%d").toordinal() for b in raw]
    n = len(bars)
    A.bar_hi = [b[2] for b in bars]
    A.bar_lo = [b[3] for b in bars]
    k0 = max(k0, 60)

    full = replay(bars, dates, k0, step_full, False, k0, False, True, True)
    fine_start = max(k0, n - fine_len)
    fine = replay(bars, dates, max(k0, fine_start - 200), 1, True, fine_start, True, True, True)

    out = {"name": name, "n_bars": n, "k0": k0, "step_full": step_full,
           "fine_window": [fine_start, n - 1], "weekly": weekly,
           "n_samples_full": full["n_k"], "n_samples_fine": fine["n_k"]}
    # 定稿不变性（两遍合并）
    allviol = full["tr"].viol + [v for v in fine["tr"].viol if v["first_k"] >= fine_start]
    out["invariance"] = {
        "violations": len(allviol),
        "by_type": {t: sum(1 for v in allviol if v["type"] == t) for t in ("bi", "seg", "cen")},
        "field_freq": {},
        "samples": allviol[:8],
    }
    for v in allviol:
        for f in v["field_diff"]:
            key = "%s.%s" % (v["type"], f[0])
            out["invariance"]["field_freq"][key] = out["invariance"]["field_freq"].get(key, 0) + 1

    # 提前确认
    early = full["tr"].early + [e for e in fine["tr"].early if e["k"] >= fine_start]
    out["no_lookahead"] = {"early": len(early), "samples": early[:5]}

    # 延迟（只取 fine 窗口内首次确认，避免左删失）
    delay = {}
    for t in ("bi", "seg", "cen"):
        v = fine["tr"].delay[t]
        delay[t] = {"bars": stats([x[0] for x in v]),
                    "days": stats([x[1] for x in v]),
                    "zero_bars": sum(1 for x in v if x[0] == 0)}
    out["delay"] = delay

    out["stable_len"] = {"seg_based": stats(full["stable_seg"]),
                         "cen_based": stats(full["stable_cen"])}
    t3 = full["tail3"] + fine["tail3"]
    tn = full["n_k"] + fine["n_k"]
    out["draft"] = {"seg_frac": stats(full["draft_seg"]),
                    "cen_frac": stats(full["draft_cen"]),
                    "tail_ge3_samples": t3, "tail_samples": tn,
                    "tail_ge3_ratio": t3 / max(1, tn),
                    "tail_n_dist": {str(i): sum(1 for x in full["tail_n"] if x == i)
                                    for i in sorted(set(full["tail_n"]))}}
    return out


def weekly_bars(raw):
    groups = {}
    order = []
    for d, o, h, l, c in raw:
        dt = datetime.strptime(str(d), "%Y%m%d")
        y, w, _ = dt.isocalendar()
        key = (y, w)
        if key not in groups:
            groups[key] = [d, o, h, l, c]
            order.append(key)
        else:
            g = groups[key]
            g[2] = max(g[2], h)
            g[3] = min(g[3], l)
            g[4] = c
    return [groups[k] for k in order]


if __name__ == "__main__":
    files = [("daily_11.json", "HSI"), ("daily_2085.json", "999999"),
             ("daily_2087.json", "000002"), ("daily_3581.json", "399001")]
    res = []
    for fn, name in files:
        d = json.load(open(os.path.join(WORK, fn)))
        r = audit_symbol(name, d["bars"], 200, 10, 2000, weekly=False)
        res.append(r)
        print("[done] %s n=%d samples=%d+%d viol=%d delay(bi/seg/cen)=%s/%s/%s" % (
            name, r["n_bars"], r["n_samples_full"], r["n_samples_fine"],
            r["invariance"]["violations"],
            r["delay"]["bi"]["bars"].get("median"), r["delay"]["seg"]["bars"].get("median"),
            r["delay"]["cen"]["bars"].get("median")))
        sys.stdout.flush()
    # 周线：HSI
    d = json.load(open(os.path.join(WORK, "daily_11.json")))
    wb = weekly_bars(d["bars"])
    r = audit_symbol("HSI-W", wb, 60, 3, 300, weekly=True)
    res.append(r)
    print("[done] HSI-W n=%d samples=%d+%d viol=%d" % (
        r["n_bars"], r["n_samples_full"], r["n_samples_fine"], r["invariance"]["violations"]))
    json.dump(res, open(os.path.join(HERE, "audit_metrics.json"), "w"),
              ensure_ascii=False, indent=1)
    print("saved audit_metrics.json")

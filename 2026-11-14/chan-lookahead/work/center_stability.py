#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""中枢稳定性回放：未确认段变化 vs 中枢矩形，中枢自身判据的可靠性。

只读分析，不改源码。产物：center_stability.json
用法：python3 center_stability.py [symbol ...]
"""
import json, os, sys, math, sqlite3, importlib.util
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SIMDB = ("/Users/sunchukun/Library/Developer/CoreSimulator/Devices/"
         "54291852-68BE-45BF-ACC0-72CEAEF10A0B/data/Containers/Data/Application/"
         "593A5CB6-80C5-418D-80F7-4E51768DF1F8/Documents/tdx.db")


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


chan = load(os.path.join(REPO, "Kline", "PyScripts", "chan.py"), "chan_m")
te = load(os.path.join(REPO, "Kline", "PyScripts", "tdx_eval.py"), "te_m")
CFG = dict(te._CHAN_CLV1)
CFG["include_seg_centers"] = False
TOL = 1e-9
FIELDS = ("endKlu", "zg", "zd")


def pct(v, q):
    if not v:
        return None
    v = sorted(v)
    i = (len(v) - 1) * q
    lo = int(math.floor(i))
    hi = min(lo + 1, len(v) - 1)
    return round(v[lo] + (v[hi] - v[lo]) * (i - lo), 2)


def stats(v):
    if not v:
        return {"n": 0}
    return {"n": len(v), "median": pct(v, .5), "p90": pct(v, .9),
            "min": min(v), "max": max(v), "mean": round(sum(v) / len(v), 2)}


def calc(bars):
    out = chan._op_chan({"op": "chan", "bars": bars, "config": dict(CFG)})
    if not out.get("ok"):
        raise RuntimeError(out.get("error"))
    return out["result"]


def snap(res):
    bis = res.get("bi") or []
    segs = []
    for s in res.get("segments") or []:
        b0 = bis[s["startBi"]]
        b1 = bis[s["endBi"]]
        segs.append({"dir": s["dir"], "startBi": s["startBi"], "endBi": s["endBi"],
                     "startKlu": b0["fromKlu"], "endKlu": b1["toKlu"],
                     "beginVal": s["beginVal"], "endVal": s["endVal"],
                     "biCount": s["biCount"], "confirmed": s["confirmed"],
                     "reason": s.get("reason")})
    cens = []
    for c in res.get("centers") or []:
        cens.append({"beginLine": c.get("beginLine"), "endLine": c.get("endLine"),
                     "beginKlu": c.get("beginKlu"), "endKlu": c.get("endKlu"),
                     "zg": c.get("zg"), "zd": c.get("zd"),
                     "lineCount": c.get("lineCount"),
                     "confirmed": bool(c.get("confirmed")),
                     "ended": c.get("ended")})
    return {"lastBi": len(bis) - 1, "segs": segs, "cens": cens}


def same(a, b):
    for f in FIELDS:
        if abs(float(a[f]) - float(b[f])) > TOL:
            return False
    return True


def diff_fields(a, b):
    out = {}
    for f in FIELDS:
        if abs(float(a[f]) - float(b[f])) > TOL:
            out[f] = round(float(b[f]) - float(a[f]), 6)
    return out


def center_map(s):
    return {c["beginKlu"]: c for c in s["cens"]}


def seg_classify(prev_segs, cur_segs):
    """返回 (类型, 说明)。类型 ∈ extension / resplit / confirm_only / none。"""
    old_all = {(s["startKlu"], s["dir"]): s for s in prev_segs}
    new_all = {(s["startKlu"], s["dir"]): s for s in cur_segs}
    old_u = {k: s for k, s in old_all.items() if not s["confirmed"]}
    new_u = {k: s for k, s in new_all.items() if not s["confirmed"]}
    ext = [k for k in old_u if k in new_all and new_all[k]["endBi"] > old_u[k]["endBi"]]
    shrunk = [k for k in old_u if k in new_all and new_all[k]["endBi"] < old_u[k]["endBi"]]
    gone = [k for k in old_u if k not in new_all]
    newk = [k for k in new_u if k not in old_all]
    confirmed = [k for k in old_u if k in new_all and new_all[k]["confirmed"]]
    resplit = bool(shrunk or gone or newk)
    if resplit:
        return "resplit", {"shrunk": shrunk, "gone": gone, "new": newk, "ext": ext}
    if ext:
        return "extension", {"ext": ext}
    if confirmed:
        return "confirm_only", {"confirmed": confirmed}
    return "none", {}


def replay(name, raw, dates, k0=200):
    n = len(raw)
    bars = [[b[0], float(b[1]), max(float(b[1]), float(b[2]), float(b[3]), float(b[4])),
             min(float(b[1]), float(b[2]), float(b[3]), float(b[4])), float(b[4])]
            for b in raw]
    q1 = {"extension": {"trans": 0, "trans_changed": 0, "cmp": 0, "changed": 0,
                        "added": 0, "removed": 0, "d_end": [], "d_zg": [], "d_zd": [],
                        "samples": []},
          "resplit": {"trans": 0, "trans_changed": 0, "cmp": 0, "changed": 0,
                      "added": 0, "removed": 0, "d_end": [], "d_zg": [], "d_zd": [],
                      "samples": []}}
    # 每个中枢 key 的生命史：首次出现 → 首次 confirmed / 消失 / 数据末端
    hist = {}
    q3 = {"tA": 0, "viol": [], "lead": [], "never_A": 0,
          "violE": [], "leadE": [], "never_AE": 0,
          "B_true_conf_false": 0, "conf_true_B_false": 0, "centers": 0,
          "post_conf_changes": 0, "post_conf_vanished": 0}
    prev = None
    pending_ext = None

    for k in range(k0, n):
        s = snap(calc(bars[:k + 1]))
        cm = center_map(s)
        sure_ends = [x["endBi"] for x in s["segs"] if x["confirmed"]]
        last_sure_end = sure_ends[-1] if sure_ends else -1

        # ---------- Q3：A 判据（成分笔不含最后一笔 ⇒ 全部 used_to_be_sure）----------
        for c in s["cens"]:
            key = c["beginKlu"]
            rec = hist.setdefault(key, {"first": k, "last": k, "conf": None,
                                        "tA": None, "geoA": None, "changes": [],
                                        "vanished": None, "last_geo": None,
                                        "last_k": None, "confirmed_seen": False,
                                        "viol": None, "n_samples": 0,
                                        "tAE": None, "geoAE": None, "violE": None,
                                        "stable_n": 0, "tD20": None, "geoD20": None,
                                        "violD20": None, "tD40": None, "geoD40": None,
                                        "violD40": None})
            rec["last"] = k
            rec["n_samples"] += 1
            changed = rec["last_geo"] is not None and not same(rec["last_geo"], c)
            if changed:
                rec["changes"].append({"k": k, "d": diff_fields(rec["last_geo"], c)})
                if rec["conf"] is not None and k > rec["conf"]:
                    q3["post_conf_changes"] += 1
                rec["stable_n"] = 0
            elif rec["last_geo"] is not None:
                rec["stable_n"] += 1
            rec["last_geo"] = c
            rec["last_k"] = k
            if c["confirmed"]:
                rec["confirmed_seen"] = True
                if rec["conf"] is None:
                    rec["conf"] = k
            a_now = c["endLine"] is not None and c["endLine"] < s["lastBi"]
            if a_now and rec["tA"] is None:
                rec["tA"] = k
                rec["geoA"] = dict(c)
            if rec["tA"] is not None and rec["viol"] is None and k > rec["tA"]:
                if not same(rec["geoA"], c):
                    rec["viol"] = {"k": k, "type": "geometry",
                                   "d": diff_fields(rec["geoA"], c),
                                   "age": k - rec["tA"]}
            ae_now = a_now and bool(c.get("ended"))
            if ae_now and rec["tAE"] is None:
                rec["tAE"] = k
                rec["geoAE"] = dict(c)
            if rec["tAE"] is not None and rec["violE"] is None and k > rec["tAE"]:
                if not same(rec["geoAE"], c):
                    rec["violE"] = {"k": k, "type": "geometry",
                                    "d": diff_fields(rec["geoAE"], c),
                                    "age": k - rec["tAE"]}
            # B 判据：成分笔都落在最后一条已确认段内（与现行 confirmed 是否等价）
            b_now = c["endLine"] is not None and c["endLine"] <= last_sure_end
            if b_now and not c["confirmed"]:
                q3["B_true_conf_false"] += 1
            if c["confirmed"] and not b_now:
                q3["conf_true_B_false"] += 1
            # D 判据：A + 连续 N 次采样几何不变（可实现的"冷却期"）
            for nv, tk, gk, vk in ((20, "tD20", "geoD20", "violD20"),
                                   (40, "tD40", "geoD40", "violD40")):
                if a_now and rec["stable_n"] >= nv and rec[tk] is None:
                    rec[tk] = k
                    rec[gk] = dict(c)
                if rec[tk] is not None and rec[vk] is None and k > rec[tk]:
                    if not same(rec[gk], c):
                        rec[vk] = {"k": k, "type": "geometry",
                                   "d": diff_fields(rec[gk], c), "age": k - rec[tk]}
        for key, rec in hist.items():
            if rec["vanished"] is None and rec["last"] != k and key not in cm:
                rec["vanished"] = k
                if rec["tA"] is not None and rec["viol"] is None:
                    rec["viol"] = {"k": k, "type": "vanished", "d": {},
                                   "age": k - rec["tA"]}
                if rec["tAE"] is not None and rec["violE"] is None:
                    rec["violE"] = {"k": k, "type": "vanished", "d": {},
                                    "age": k - rec["tAE"]}
                for tk, vk in (("tD20", "violD20"), ("tD40", "violD40")):
                    if rec[tk] is not None and rec[vk] is None:
                        rec[vk] = {"k": k, "type": "vanished", "d": {},
                                   "age": k - rec[tk]}
                if rec["conf"] is not None:
                    q3["post_conf_vanished"] += 1

        # ---------- Q1：段事件 → 中枢矩形变化 ----------
        if prev is not None:
            typ, info = seg_classify(prev["segs"], s["segs"])
            if typ in ("extension", "resplit"):
                if typ == "extension":
                    key = info["ext"][0]
                    new_seg = [x for x in s["segs"]
                               if (x["startKlu"], x["dir"]) == key][0]
                    lo, hi = new_seg["startKlu"], new_seg["endKlu"]
                else:
                    starts = [x["startKlu"] for x in prev["segs"] if not x["confirmed"]]
                    starts += [x["startKlu"] for x in s["segs"] if not x["confirmed"]]
                    lo, hi = (min(starts) if starts else 0), max(x["endKlu"] for x in s["segs"])
                om = {kc: c for kc, c in center_map(prev).items() if lo <= kc <= hi}
                nm = {kc: c for kc, c in cm.items() if lo <= kc <= hi}
                bucket = q1[typ]
                bucket["trans"] += 1
                ch = 0
                for kc, oc in om.items():
                    if kc in nm:
                        bucket["cmp"] += 1
                        if not same(oc, nm[kc]):
                            bucket["changed"] += 1
                            ch += 1
                            d = diff_fields(oc, nm[kc])
                            if "endKlu" in d:
                                bucket["d_end"].append(abs(d["endKlu"]))
                            if "zg" in d:
                                bucket["d_zg"].append(abs(d["zg"]))
                            if "zd" in d:
                                bucket["d_zd"].append(abs(d["zd"]))
                            if len(bucket["samples"]) < 6:
                                bucket["samples"].append(
                                    {"k": k, "center": kc, "d": d,
                                     "seg": [lo, hi], "dates": [dates[lo], dates[hi]]})
                added = [kc for kc in nm if kc not in om]
                removed = [kc for kc in om if kc not in nm]
                bucket["added"] += len(added)
                bucket["removed"] += len(removed)
                if ch or added or removed:
                    bucket["trans_changed"] += 1
                    if len(bucket["samples"]) < 6 and (added or removed):
                        bucket["samples"].append({"k": k, "added": added,
                                                   "removed": removed,
                                                   "seg": [lo, hi]})
        prev = s

    # ---------- 汇总 Q2 ----------
    life = [r for r in hist.values() if r["n_samples"] >= 3]
    nn = {"0": 0, "1": 0, "2+": 0}
    for r in life:
        m = len(r["changes"])
        nn["0" if m == 0 else ("1" if m == 1 else "2+")] += 1
    field_freq = {}
    for r in life:
        for e in r["changes"]:
            for f in e["d"]:
                field_freq[f] = field_freq.get(f, 0) + 1
    never_conf = [r for r in life if not r["confirmed_seen"]]
    nc_zero = sum(1 for r in never_conf if not r["changes"])
    q2 = {"centers": len(life),
          "zero": nn["0"], "one": nn["1"], "multi": nn["2+"],
          "zero_ratio": round(nn["0"] / max(1, len(life)), 4),
          "one_ratio": round(nn["1"] / max(1, len(life)), 4),
          "multi_ratio": round(nn["2+"] / max(1, len(life)), 4),
          "field_freq": field_freq,
          "vanished_before_confirm": sum(1 for r in life if r["vanished"] and not r["confirmed_seen"]),
          "confirmed_centers": sum(1 for r in life if r["confirmed_seen"]),
          "never_confirmed": len(never_conf),
          "never_confirmed_zero_change": nc_zero,
          "never_confirmed_zero_ratio": round(nc_zero / max(1, len(never_conf)), 4)}

    # ---------- 汇总 Q3 ----------
    q3_centers = [r for r in hist.values() if r["tA"] is not None]
    q3["centers"] = len(q3_centers)
    q3["never_A"] = len(hist) - len(q3_centers)
    for r in q3_centers:
        if r["viol"]:
            q3["viol"].append({"first": r["first"], "tA": r["tA"], "tAE": r["tAE"],
                               "beginKlu": r["geoA"]["beginKlu"],
                               "d": r["viol"], "conf": r["conf"]})
        if r["conf"] is not None:
            q3["lead"].append(r["conf"] - r["tA"])
    q3e_centers = [r for r in hist.values() if r["tAE"] is not None]
    for r in q3e_centers:
        if r["violE"]:
            q3["violE"].append({"first": r["first"], "tAE": r["tAE"],
                                "beginKlu": r["geoAE"]["beginKlu"],
                                "d": r["violE"], "conf": r["conf"]})
        if r["conf"] is not None:
            q3["leadE"].append(r["conf"] - r["tAE"])
    q3["never_AE"] = len(hist) - len(q3e_centers)
    q3["centers_having_tAE"] = len(q3e_centers)
    for tag, key, vkey in (("A", "viol", "tA"), ("E", "violE", "tAE"),
                           ("D20", "violD20", "tD20"), ("D40", "violD40", "tD40")):
        rs = [r for r in hist.values() if r[key]]
        q3["%s_geo" % tag] = sum(1 for r in rs if r[key]["type"] == "geometry")
        q3["%s_van" % tag] = sum(1 for r in rs if r[key]["type"] == "vanished")
    for nv, tk, gk, vk, vlist, llist in (
            (20, "tD20", "geoD20", "violD20", "violD20", "leadD20"),
            (40, "tD40", "geoD40", "violD40", "violD40", "leadD40")):
        dd = [r for r in hist.values() if r[tk] is not None]
        q3[vlist] = []
        q3[llist] = []
        for r in dd:
            if r[vk]:
                q3[vlist].append({"t": r[tk], "beginKlu": r[gk]["beginKlu"],
                                  "d": r[vk], "conf": r["conf"]})
            if r["conf"] is not None:
                q3[llist].append(r["conf"] - r[tk])
        q3["centers_D%d" % nv] = len(dd)
        q3["never_D%d" % nv] = len(hist) - len(dd)
        q3["stat_D%d" % nv] = stats(q3[llist])

    # B 判据：成分笔都落在最后一条已确认段内 == 现行 confirmed
    # （每次采样检查等价性，统计不一致数）
    return {"name": name, "n_bars": n, "k0": k0,
            "q1": sanitize_q1(q1), "q2": q2,
            "q3": {"centers_having_tA": q3["centers"], "never_A": q3["never_A"],
                   "violations": len(q3["viol"]), "samples": q3["viol"][:8],
                   "violations_geo": q3["A_geo"], "violations_van": q3["A_van"],
                   "lead_bars": stats(q3["lead"]),
                   "centers_having_tAE": q3["centers_having_tAE"],
                   "never_AE": q3["never_AE"],
                   "violations_E": len(q3["violE"]), "samples_E": q3["violE"][:8],
                   "violations_E_geo": q3["E_geo"], "violations_E_van": q3["E_van"],
                   "lead_bars_E": stats(q3["leadE"]),
                   "centers_D20": q3["centers_D20"], "never_D20": q3["never_D20"],
                   "violations_D20": len(q3["violD20"]), "samples_D20": q3["violD20"][:8],
                   "lead_bars_D20": q3["stat_D20"],
                   "centers_D40": q3["centers_D40"], "never_D40": q3["never_D40"],
                   "violations_D40": len(q3["violD40"]), "samples_D40": q3["violD40"][:8],
                   "lead_bars_D40": q3["stat_D40"],
                   "B_true_conf_false": q3["B_true_conf_false"],
                   "conf_true_B_false": q3["conf_true_B_false"],
                   "post_conf_changes": q3["post_conf_changes"],
                   "post_conf_vanished": q3["post_conf_vanished"]},
            "hist": hist}


def sanitize_q1(q1):
    out = {}
    for typ, b in q1.items():
        out[typ] = {
            "transitions": b["trans"],
            "trans_with_any_change": b["trans_changed"],
            "trans_change_ratio": round(b["trans_changed"] / max(1, b["trans"]), 4),
            "center_cmp": b["cmp"], "center_changed": b["changed"],
            "center_change_ratio": round(b["changed"] / max(1, b["cmp"]), 4),
            "added": b["added"], "removed": b["removed"],
            "abs_d_endKlu": stats(b["d_end"]),
            "abs_d_zg": stats(b["d_zg"]),
            "abs_d_zd": stats(b["d_zd"]),
            "samples": b["samples"],
        }
    return out


def load_600010():
    conn = sqlite3.connect(SIMDB)
    rows = conn.execute("SELECT date,open,high,low,close FROM daily "
                        "WHERE meta_id=389 ORDER BY date ASC").fetchall()
    conn.close()
    raw = [[r[0], r[1], r[2], r[3], r[4]] for r in rows]
    return "600010", raw


def load_fixture(fn, name):
    d = json.load(open(os.path.join(HERE, fn)))
    return name, d["bars"]


def trace_600010(hist):
    out = []
    for key in (5954, 6008):
        r = hist.get(key)
        if not r:
            out.append({"beginKlu": key, "missing": True})
            continue
        out.append({"beginKlu": key, "first": r["first"], "conf": r["conf"],
                    "vanished": r["vanished"], "tA": r["tA"],
                    "changes": r["changes"][:20],
                    "n_samples": r["n_samples"],
                    "viol": r["viol"]})
    return out


if __name__ == "__main__":
    syms = [load_600010(),
            load_fixture("daily_11.json", "HSI"),
            load_fixture("daily_2085.json", "999999"),
            load_fixture("daily_2087.json", "000002"),
            load_fixture("daily_3581.json", "399001")]
    if len(sys.argv) > 1:
        syms = [s for s in syms if s[0] in sys.argv[1:]]
    res = []
    for name, raw in syms:
        raw = sorted(raw, key=lambda b: b[0])
        dates = [str(b[0]) for b in raw]
        r = replay(name, raw, dates, k0=200)
        hist = r.pop("hist")
        if name == "600010":
            r["trace_600010"] = trace_600010(hist)
        res.append(r)
        print("[done] %s n=%d ext=%s resplit=%s q2_zero=%s q3_viol_A=%d AE=%d D20=%d D40=%d leadA=%s leadD20=%s" % (
            name, r["n_bars"],
            r["q1"]["extension"]["trans_change_ratio"],
            r["q1"]["resplit"]["trans_change_ratio"],
            r["q2"]["zero_ratio"], r["q3"]["violations"],
            r["q3"]["violations_E"], r["q3"]["violations_D20"],
            r["q3"]["violations_D40"], r["q3"]["lead_bars"].get("median"),
            r["q3"]["lead_bars_D20"].get("median")))
        sys.stdout.flush()
    json.dump(res, open(os.path.join(HERE, "center_stability.json"), "w"),
              ensure_ascii=False, indent=1)
    print("saved center_stability.json")

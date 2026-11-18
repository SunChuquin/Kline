#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""中枢「未确认期间几何变化」明细提取（只读，判定逻辑与 center_stability.py 完全一致）。

复用 center_stability.py 的 load / same / diff_fields，逐标的回放一次并落盘
每个中枢的变更时间线：center_detail.json
"""
import json, os, sys
import center_stability as cs

HERE = os.path.dirname(os.path.abspath(__file__))
TOL = cs.TOL
FIELDS = cs.FIELDS


def replay_detail(name, raw):
    raw = sorted(raw, key=lambda b: b[0])
    dates = [str(b[0]) for b in raw]
    bars = [[b[0], float(b[1]), max(float(b[1]), float(b[2]), float(b[3]), float(b[4])),
             min(float(b[1]), float(b[2]), float(b[3]), float(b[4])), float(b[4])]
            for b in raw]
    recs = {}
    vanish_events = {}
    prev = {}
    for k in range(200, len(bars)):
        s = cs.snap(cs.calc(bars[:k + 1]))
        cm = cs.center_map(s)
        for c in s["cens"]:
            key = c["beginKlu"]
            r = recs.setdefault(key, {"beginKlu": key, "first": k, "last": k,
                                      "beginLine": c["beginLine"], "conf": None,
                                      "changes": [], "snap": dict(c),
                                      "geo0": dict(c), "vanished": None})
            r["last"] = k
            r["beginLine"] = c["beginLine"]
            if c["confirmed"] and r["conf"] is None:
                r["conf"] = k
                r["changes"].append({"k": k, "type": "confirmed",
                                     "d": {}, "before": r["snap"], "after": dict(c)})
            if not cs.same(r["snap"], c):
                r["changes"].append({"k": k, "type": "geometry",
                                     "d": cs.diff_fields(r["snap"], c),
                                     "before": {f: r["snap"][f] for f in FIELDS},
                                     "after": {f: c[f] for f in FIELDS}})
                r["snap"] = dict(c)
        for key, r in recs.items():
            if r["vanished"] is None and key not in cm and r["last"] != k:
                r["vanished"] = k
                vanish_events.setdefault(k, []).append({"beginKlu": key, "first": r["first"]})
        prev = cm

    out = []
    total = 0
    eligible = 0
    zero = 0
    changed_unconf = 0
    for key, r in recs.items():
        total += 1
        end = r["conf"] if r["conf"] is not None else (r["vanished"] or r["last"])
        geo = [e for e in r["changes"] if e["type"] == "geometry"
               and e["k"] < (r["conf"] if r["conf"] is not None else 10 ** 9)]
        life = end - r["first"] + 1
        if life >= 3:
            eligible += 1
            zero += (0 if geo else 1)
        if geo:
            changed_unconf += 1
        g0 = r["geo0"]
        out.append({
            "beginKlu": key,
            "beginDate": dates[g0["beginKlu"]],
            "endDateAtFirst": dates[g0["endKlu"]],
            "firstK": r["first"], "firstDate": dates[r["first"]],
            "lifeEndK": end, "lifeEndDate": dates[end],
            "confirmedK": r["conf"], "confirmedDate": dates[r["conf"]] if r["conf"] is not None else None,
            "vanishedK": r["vanished"], "vanishedDate": dates[r["vanished"]] if r["vanished"] is not None else None,
            "unconfirmedChanges": [{"k": e["k"], "date": dates[e["k"]], "d": e["d"],
                                    "before": e["before"], "after": e["after"]} for e in geo],
            "nSamples": end - r["first"] + 1,
        })
    # 同时消失最多的一次
    vmax = max(vanish_events.items(), key=lambda kv: len(kv[1]), default=(None, []))
    return {"name": name, "n_bars": len(bars),
            "firstDate": dates[0], "lastDate": dates[-1], "k0Date": dates[200],
            "centers": out,
            "nCenters": total, "eligible": eligible,
            "zeroRatio": round(zero / max(1, eligible), 4),
            "changedUnconfirmed": changed_unconf,
            "vanishMax": {"k": vmax[0], "date": dates[vmax[0]] if vmax[0] is not None else None,
                          "centers": vmax[1]}}


def main():
    syms = [cs.load_600010(),
            cs.load_fixture("daily_11.json", "HSI"),
            cs.load_fixture("daily_2085.json", "999999"),
            cs.load_fixture("daily_2087.json", "000002"),
            cs.load_fixture("daily_3581.json", "399001")]
    if len(sys.argv) > 1:
        syms = [s for s in syms if s[0] in sys.argv[1:]]
    res = []
    for name, raw in syms:
        d = replay_detail(name, raw)
        res.append(d)
        print("[done] %s n=%d centers=%d zeroRatio=%.4f changed=%d vanishMax=%s@%s x%d" % (
            name, d["n_bars"], d["nCenters"], d["zeroRatio"], d["changedUnconfirmed"],
            d["vanishMax"]["centers"][0]["beginKlu"] if d["vanishMax"]["centers"] else None,
            d["vanishMax"]["date"], len(d["vanishMax"]["centers"])))
        sys.stdout.flush()
    json.dump(res, open(os.path.join(HERE, "center_detail.json"), "w"),
              ensure_ascii=False, indent=1)
    print("saved center_detail.json")


if __name__ == "__main__":
    main()

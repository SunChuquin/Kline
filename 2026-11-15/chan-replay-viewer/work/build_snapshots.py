#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""逐根截断回放，落盘每个时点的笔/段/中枢快照（只看，不改源码）。

每个标的输出 work/snap_<code>.jsonl：
  第 1 行 meta：{"code","name","k0","n","bars":[[date,o,h,l,c],...]}
  其后每行：{"k":k,"b":[...],"s":[...],"c":[...]}

紧凑字段：
  笔   [fromKlu, toKlu, dir, beginVal, endVal, confirmed]
  段   [startKlu, endKlu, dir, beginVal, endVal, confirmed, reason]
  中枢 [beginKlu, endKlu, zg, zd, lineCount, confirmed, ended, reason]
  中枢的 reason 取「覆盖其 endLine 的那条段」的 reason（中枢本身不带 reason）。

用法：python3 build_snapshots.py [600010 999999 ...]
"""
import json
import os
import sqlite3
import sys
import time
import multiprocessing as mp
from importlib import util as imputil

HERE = os.path.dirname(os.path.abspath(__file__))
OLD_WORK = "/Volumes/home/repositories/Kline2/2026-11-14/chan-lookahead/work"
REPO = "/Volumes/home/repositories/Kline2"
SIMDB = ("/Users/sunchukun/Library/Developer/CoreSimulator/Devices/"
         "54291852-68BE-45BF-ACC0-72CEAEF10A0B/data/Containers/Data/Application/"
         "593A5CB6-80C5-418D-80F7-4E51768DF1F8/Documents/tdx.db")

SYMBOLS = [
    ("600010", "包钢股份"),
    ("999999", "上证指数"),
    ("399001", "深证成指"),
    ("000002", "万科A"),
    ("HSI", "恒生指数"),
    ("002613", "北玻股份"),
]
FIXTURE = {"HSI": "daily_11.json", "999999": "daily_2085.json",
           "000002": "daily_2087.json", "399001": "daily_3581.json"}
# 走模拟器主库日线的标的（其余读旧 work 下的日线 fixture）
DB_META = {"600010": 389, "002613": 3192}
K0 = 200


def _load_mod(path, name):
    spec = imputil.spec_from_file_location(name, path)
    m = imputil.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


CHAN = _load_mod(os.path.join(REPO, "Kline", "PyScripts", "chan.py"), "chan_m")
TE = _load_mod(os.path.join(REPO, "Kline", "PyScripts", "tdx_eval.py"), "te_m")
CFG = dict(TE._CHAN_CLV1)
CFG["include_seg_centers"] = False


def load_raw(code):
    if code in DB_META:
        conn = sqlite3.connect(SIMDB)
        rows = conn.execute(
            "SELECT date,open,high,low,close FROM daily "
            "WHERE meta_id=? ORDER BY date ASC", (DB_META[code],)).fetchall()
        conn.close()
        return [[int(r[0]), float(r[1]), float(r[2]), float(r[3]), float(r[4])]
                for r in rows]
    d = json.load(open(os.path.join(OLD_WORK, FIXTURE[code])))
    return [[int(b[0]), float(b[1]), float(b[2]), float(b[3]), float(b[4])]
            for b in d["bars"]]


def compact(res):
    bis = res.get("bi") or []
    segs = []
    for s in res.get("segments") or []:
        try:
            b0, b1 = bis[s["startBi"]], bis[s["endBi"]]
        except IndexError:
            continue
        segs.append([b0["fromKlu"], b1["toKlu"], s["dir"],
                     round(s["beginVal"], 4), round(s["endVal"], 4),
                     1 if s["confirmed"] else 0,
                     s.get("reason") or "normal"])
    cens = []
    for c in res.get("centers") or []:
        end_line = c.get("endLine")
        reason = "normal"
        for s in res.get("segments") or []:
            if s["startBi"] <= end_line <= s["endBi"]:
                reason = s.get("reason") or "normal"
                break
        cens.append([c["beginKlu"], c["endKlu"], round(c["zg"], 4),
                     round(c["zd"], 4), c.get("lineCount") or 0,
                     1 if c["confirmed"] else 0,
                     1 if c.get("ended") else 0, reason])
    bi = [[b["fromKlu"], b["toKlu"], b["dir"],
           round(b["beginVal"], 4), round(b["endVal"], 4),
           1 if b.get("confirmed") else 0] for b in bis]
    return bi, segs, cens


def run_one(code):
    t0 = time.time()
    raw = load_raw(code)
    raw.sort(key=lambda b: b[0])
    n = len(raw)
    bars = [[b[0], b[1], max(b[1], b[2], b[3], b[4]),
             min(b[1], b[2], b[3], b[4]), b[4]] for b in raw]
    out = os.path.join(HERE, "snap_%s.jsonl" % code)
    cnt = 0
    with open(out, "w") as f:
        f.write(json.dumps({"code": code,
                            "name": dict(SYMBOLS)[code],
                            "k0": K0, "n": n,
                            "bars": [[b[0], round(b[1], 4), round(b[2], 4),
                                      round(b[3], 4), round(b[4], 4)]
                                     for b in bars]},
                           separators=(",", ":")) + "\n")
        for k in range(K0, n):
            res = CHAN._op_chan({"op": "chan", "bars": bars[:k + 1],
                                 "config": dict(CFG)})
            if not res.get("ok"):
                raise RuntimeError("%s k=%d %s" % (code, k, res.get("error")))
            bi, segs, cens = compact(res["result"])
            f.write(json.dumps({"k": k, "b": bi, "s": segs, "c": cens},
                               separators=(",", ":")) + "\n")
            cnt += 1
            if cnt % 500 == 0:
                print("[%s] %d/%d  %.1fs" % (code, cnt, n - K0,
                                             time.time() - t0), flush=True)
    print("[done] %s n=%d snaps=%d %.1fs  %.1fMB" % (
        code, n, cnt, time.time() - t0, os.path.getsize(out) / 1e6), flush=True)
    return code, cnt


if __name__ == "__main__":
    want = sys.argv[1:] or [c for c, _ in SYMBOLS]
    jobs = [(c,) for c in want]
    with mp.Pool(processes=min(5, len(jobs))) as pool:
        for r in pool.starmap(run_one, jobs):
            print("result", r, flush=True)

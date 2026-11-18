#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""买卖点 V2：信号当根成立（x == det），逐根收线判定，不回溯。

与 V1 的唯一区别在「怎么落盘」，判据本身完全不变（见 rules_bsp.md）：

  V1：标记在笔末端 anchor，det 另存，图上会出现回溯标注；
  V2：信号在「首次满足条件的那根 K 线」发出，标记位置 x = det，
      信号价 = 该根收盘价，anchor 只作为结构极值备注保留。

去重规则（三条，全部显式）：
  R1 结构唯一：同一 (anchor, 类型) 只发一次；
  R2 同根同类型唯一：同一根 K 线上同类型只留一条，多个结构同时满足时取 anchor 最早者；
  R3 同类型冷却：同类型信号之间至少间隔 3 根 K 线，不足者永久丢弃。

逐根流程（完全依赖该时点快照，不做「先全量算再回填」）：
  for k in [k0, n-1]:
      用该时点的笔/中枢重算候选
      对每个候选按 R1/R2/R3 过滤
      通过者记 [x=k, kind, price=bars[k].close, det=k, conf, anchor]

输出（原地写回 data_<code>.json）：
  pkey 每 KF 根的全量 [[x,kind,price,det,conf,anchor],...]
  pd   与 d 同索引的增量 [6,x,kind,price,det,conf,anchor] / [7,key]
  key  = x*8+kind
"""
import json
import os
import sys
import multiprocessing as mp
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_bsp as BB   # compute_points / KINDS / apply_ops

CODES = ["600010", "999999", "399001", "000002", "HSI", "002613"]
KF = 50
COOLDOWN = 3     # R3：同类型最小间隔（根）


def build(code):
    path = os.path.join(HERE, "data_%s.json" % code)
    d = json.load(open(path))
    bars = d["bars"]
    k0 = d["k0"]
    total = d["n"] - k0
    kb, ks, kc = d["key"][0]
    st = {"b": {r[0]: list(r) for r in kb},
          "s": {r[0]: list(r) for r in ks},
          "c": {r[0]: list(r) for r in kc}}

    frozen = {}          # key -> [x,kind,price,det,conf,anchor]
    dropped = set()      # 被 R2/R3 永久丢弃的 (anchor,kind)
    last_det = {}        # kind -> 最近一次发信号的 k
    pkeyframes = []
    pd = []
    stats = []

    for i in range(total):
        k = k0 + i
        bis = sorted(st["b"].values(), key=lambda r: r[0])
        cens = sorted(st["c"].values(), key=lambda r: r[0])
        cur = BB.compute_points(bis, cens)
        ops = []

        # 候选按 anchor 升序，保证「同根多结构」时取最早锚点（R2）
        cands = sorted(cur.items(), key=lambda kv: (kv[1][0], kv[1][1]))
        for key, rec in cands:
            anchor, kind = rec[0], rec[1]
            if key in frozen:                      # R1：结构已发过
                if frozen[key][4] == 0 and rec[4] == 1:
                    frozen[key][4] = 1
                    ops.append([6] + frozen[key])
                continue
            if key in dropped:
                continue
            if last_det.get(kind) == k:            # R2：本根同类型已发
                dropped.add(key)
                continue
            if k - last_det.get(kind, -10 ** 9) < COOLDOWN:   # R3：冷却期
                dropped.add(key)
                continue
            frozen[key] = [k, kind, round(bars[k][4], 4), k,
                           1 if rec[4] else 0, anchor]
            last_det[kind] = k
            ops.append([6] + frozen[key])
            # 统计：结构极值处的价格、滞后
            ext = bars[anchor][3] if kind < 3 else bars[anchor][2]
            bi_after = len(bis) - 1 - next(
                (j for j, b in enumerate(bis) if b[1] == anchor), len(bis) - 1)
            stats.append({"code": code, "kind": BB.KINDS[kind], "x": k,
                          "anchor": anchor, "lag_bars": k - anchor,
                          "lag_bis": bi_after,
                          "price": frozen[key][2], "extreme": ext,
                          "dev_pct": (frozen[key][2] - ext) / abs(ext) * 100
                          if ext else 0.0})

        if i % KF == 0:
            pkeyframes.append([list(v) for v in frozen.values()])
        if i > 0:
            pd.append(ops)
        if i < total - 1:
            BB.apply_ops(st, d["d"][i])

    assert len(pd) == total - 1, (len(pd), total)
    d["pkey"] = pkeyframes
    d["pd"] = pd
    with open(path, "w") as f:
        json.dump(d, f, separators=(",", ":"), ensure_ascii=False)
    cnt = Counter(s["kind"] for s in stats)
    return {"code": code, "name": d["name"], "n": d["n"], "k0": k0,
            "total": total, "marks": len(frozen),
            "kinds": dict(cnt), "dropped": len(dropped),
            "mb": os.path.getsize(path) / 1e6, "stats": stats}


if __name__ == "__main__":
    want = sys.argv[1:] or CODES
    out = []
    with mp.Pool(min(6, len(want))) as pool:
        for r in pool.map(build, want):
            out.append(r)
            print("%s %s 时点%d 信号%d %s 丢弃%d %.2fMB" % (
                r["code"], r["name"], r["total"], r["marks"],
                " ".join("%s:%d" % (k, r["kinds"].get(k, 0)) for k in BB.KINDS),
                r["dropped"], r["mb"]), flush=True)
    allst = [s for r in out for s in r["stats"]]
    json.dump([{k: r[k] for k in ("code", "name", "n", "k0", "total", "marks",
                                  "kinds", "dropped")} for r in out]
              + [{"stats": allst}],
              open(os.path.join(HERE, "bsp_v2_stats.json"), "w"),
              ensure_ascii=False, separators=(",", ":"))
    print("total signals", len(allst))

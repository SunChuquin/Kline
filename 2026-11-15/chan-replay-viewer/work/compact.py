#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把逐根快照压成「关键帧 + 增量」，产出 data_<code>.json。

关键帧每 KF 根一个（全量笔/段/中枢），其余每根只存相对上一根的增删改。
还原任意 k：最近关键帧 + 逐条 applyOps，结果与原始快照逐字段一致（脚本内自检）。
流式读写，避免把上百 MB 的中间 JSONL 全量载入内存。
"""
import copy
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
KF = 50
CODES = ["600010", "999999", "399001", "000002", "HSI", "002613"]


def diff(prev, cur, typ):
    ops = []
    for key, rec in cur.items():
        if prev.get(key) != rec:
            ops.append([typ] + rec)
    for key in prev:
        if key not in cur:
            ops.append([typ + 1, key])
    return ops


def build(code):
    path = os.path.join(HERE, "snap_%s.jsonl" % code)
    f = open(path)
    meta = json.loads(f.readline())
    total = meta["n"] - meta["k0"]
    probes = sorted({0, 1, 49, 50, 51, 123, total // 3, total // 2, total - 2,
                     total - 1} | {min(total - 1, x) for x in (777, 2222, 4444, 6666)})
    pset = set(probes)
    pdata = {}

    reasons = []

    def ridx(r):
        if r not in reasons:
            reasons.append(r)
        return reasons.index(r)

    keys, deltas = [], []
    prevB, prevS, prevC = {}, {}, {}
    i = 0
    for line in f:
        rec = json.loads(line)
        if i in pset:
            pdata[i] = copy.deepcopy(rec)
        b = {r[0]: r for r in rec["b"]}
        s = {r[0]: r for r in rec["s"]}
        c = {r[0]: r for r in rec["c"]}
        for r in s.values():
            r[6] = ridx(r[6])
        for r in c.values():
            r[7] = ridx(r[7])
        deltas.append([])
        if i % KF == 0:
            keys.append([list(b.values()), list(s.values()), list(c.values())])
        # d[i] 表示「i → i+1」的增量：i-1→i 的差分写到 i-1。
        # 关键帧所在的那一步同样要写，否则跨越关键帧时会丢一次尾部更新。
        if i > 0:
            deltas[i - 1] = diff(prevB, b, 0) + diff(prevS, s, 2) + diff(prevC, c, 4)
        prevB, prevS, prevC = b, s, c
        i += 1
    f.close()
    assert i == total, (code, i, total)

    out = {"code": code, "name": meta["name"], "k0": meta["k0"], "n": meta["n"],
           "bars": meta["bars"], "reasons": reasons, "kf": KF,
           "key": keys, "d": deltas}
    dst = os.path.join(HERE, "data_%s.json" % code)
    with open(dst, "w") as fo:
        json.dump(out, fo, separators=(",", ":"), ensure_ascii=False)
    return dst, out, pdata


def apply_ops(state, ops):
    b, s, c = state
    for op in ops:
        t = op[0]
        if t == 0:
            b[op[1]] = op[1:]
        elif t == 1:
            b.pop(op[1], None)
        elif t == 2:
            s[op[1]] = op[1:]
        elif t == 3:
            s.pop(op[1], None)
        elif t == 4:
            c[op[1]] = op[1:]
        elif t == 5:
            c.pop(op[1], None)
    return state


def snap_at(out, i):
    j = i // out["kf"]
    kb, ks, kc = out["key"][j]
    st = ({r[0]: list(r) for r in kb}, {r[0]: list(r) for r in ks},
          {r[0]: list(r) for r in kc})
    for t in range(j * out["kf"], i):
        apply_ops(st, out["d"][t])
    return st


def main():
    for code in (sys.argv[1:] or CODES):
        dst, out, pdata = build(code)
        ok, bad = 0, []
        for i, rec in pdata.items():
            st = snap_at(out, i)
            got = ([st[0][k] for k in sorted(st[0])],
                   [st[1][k] for k in sorted(st[1])],
                   [st[2][k] for k in sorted(st[2])])
            orig = (rec["b"], rec["s"], rec["c"])
            for x in got[1]:
                x[6] = out["reasons"][x[6]]
            for x in got[2]:
                x[7] = out["reasons"][x[7]]
            if got == orig:
                ok += 1
            else:
                bad.append(out["k0"] + i)
        print("[%s] kf=%d keys=%d deltas=%d %.2fMB  自检 %d/%d %s" %
              (code, KF, len(out["key"]), len(out["d"]),
               os.path.getsize(dst) / 1e6, ok, len(pdata),
               ("失败 k=" + ",".join(map(str, bad))) if bad else "全对"))


if __name__ == "__main__":
    main()

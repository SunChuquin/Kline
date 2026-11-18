#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用现有压缩快照逐时点补算缠论买卖点（纯结构判据，不重跑 chan）。

规则（笔级，strength = |Δ价|/根数 近似力度）：
  B1 向下笔两连新低(e_i<e_{i-1}<e_{i-2})且 strength 衰减，且下一笔为向上笔已出现；
     标记在笔 i 末端，判定时点 = 下一向上笔末端。
  B2 B1 之后第一组「向上笔 + 回调笔」，回调低点 > B1 低点，且上冲高点 > B1 低点；
     标记在回调笔末端，判定时点 = 其后向上笔末端。
  B3 最近已结束中枢（距回调笔起点 ≤ GAP 根），向上离开（离开笔高点 > ZG）后第一次回调，
     回调低点 > ZG；标记在回调笔末端，判定 = 其后向上笔末端。
  S1/S2/S3 完全对称（创新高 / 涨幅衰减；S3 为向下离开中枢后回抽高点 < ZD）。
确认：依赖的笔（含前一向上/向下笔）与中枢全部 confirmed=1 → conf=1，否则 0。

不穿越未来：每个时点只用该时点快照里已存在的笔/中枢；det 之前的时点不显示该点。

输出：原地给 data_<code>.json 追加
  "pkey": 每 KF 根的全量买卖点 [[x,kind,price,det,conf],...]
  "pd"  : 与 "d" 同索引的增量 ops，[6,x,kind,price,det,conf] 新增/改，[7,key] 删除
  kind: 0..5 = B1,B2,B3,S1,S2,S3；key = x*8+kind
"""
import json
import os
import sys
import multiprocessing as mp

HERE = os.path.dirname(os.path.abspath(__file__))
CODES = ["600010", "999999", "399001", "000002", "HSI", "002613"]
KF = 50
GAP = 40
KINDS = ["B1", "B2", "B3", "S1", "S2", "S3"]


def strength(r):
    return abs(r[4] - r[3]) / max(1, r[1] - r[0])


def pkey(x, kind):
    return x * 8 + kind


def apply_ops(st, arr):
    for o in arr:
        t = o[0]
        if t == 0:
            st['b'][o[1]] = o[1:]
        elif t == 1:
            st['b'].pop(o[1], None)
        elif t == 2:
            st['s'][o[1]] = o[1:]
        elif t == 3:
            st['s'].pop(o[1], None)
        elif t == 4:
            st['c'][o[1]] = o[1:]
        elif t == 5:
            st['c'].pop(o[1], None)


def compute_points(bis, cens):
    """bis/cens 已按起始 k 升序；返回 {key: [x,kind,price,det,conf]}"""
    n = len(bis)
    out = {}
    # 第一遍：B1/S1 结构判定
    b1 = [False] * n
    s1 = [False] * n
    hist = {1: [], -1: []}
    for i, r in enumerate(bis):
        d = r[2]
        h = hist[d]
        if len(h) >= 2 and i + 1 < n and bis[i + 1][2] == -d:
            p, p2 = h[-1], h[-2]
            if d == -1 and p2[4] > p[4] > r[4] and strength(r) < strength(p):
                b1[i] = True
            elif d == 1 and p2[4] < p[4] < r[4] and strength(r) < strength(p):
                s1[i] = True
        h.append(r)

    def put(x, kind, price, det, conf):
        out[pkey(x, kind)] = [x, kind, price, det, 1 if conf else 0]

    # 第二遍：B1/S1、B2/S2
    for i in range(n):
        r = bis[i]
        if i + 1 < n and bis[i + 1][2] == -r[2]:
            nx = bis[i + 1]
            if b1[i]:
                put(r[1], 0, r[4], nx[1], r[5] and nx[5])
            if s1[i]:
                put(r[1], 3, r[4], nx[1], r[5] and nx[5])
        if i >= 2 and i + 1 < n and r[2] == -1 and bis[i - 1][2] == 1 \
                and bis[i - 2][2] == -1 and b1[i - 2]:
            a, b, nx = bis[i - 2], bis[i - 1], bis[i + 1]
            if nx[2] == 1 and r[4] > a[4] and b[4] > a[4]:
                put(r[1], 1, r[4], nx[1], r[5] and b[5] and a[5] and nx[5])
        if i >= 2 and i + 1 < n and r[2] == 1 and bis[i - 1][2] == -1 \
                and bis[i - 2][2] == 1 and s1[i - 2]:
            a, b, nx = bis[i - 2], bis[i - 1], bis[i + 1]
            if nx[2] == -1 and r[4] < a[4] and b[4] < a[4]:
                put(r[1], 4, r[4], nx[1], r[5] and b[5] and a[5] and nx[5])

    # 第三遍：B3/S3（回抽不回中枢）
    ends = sorted([(c[1], c) for c in cens])
    ekeys = [e[0] for e in ends]
    for i in range(1, n - 1):
        r, prev, nx = bis[i], bis[i - 1], bis[i + 1]
        # 手写二分，避免 import bisect 开销
        l, h = 0, len(ekeys)
        while l < h:
            m = (l + h) // 2
            if ekeys[m] <= r[0]:
                l = m + 1
            else:
                h = m
        j = l - 1
        if j < 0:
            continue
        ek, c = ends[j]
        if r[0] - ek > GAP:
            continue
        zg, zd, cconf = c[2], c[3], c[5]
        if r[2] == -1 and nx[2] == 1 and prev[4] > zg and r[4] > zg:
            put(r[1], 2, r[4], nx[1], r[5] and prev[5] and nx[5] and cconf)
        elif r[2] == 1 and nx[2] == -1 and prev[4] < zd and r[4] < zd:
            put(r[1], 5, r[4], nx[1], r[5] and prev[5] and nx[5] and cconf)
    return out


def diff(prev, cur):
    ops = []
    for key, rec in cur.items():
        if prev.get(key) != rec:
            ops.append([6] + list(rec))
    for key in prev:
        if key not in cur:
            ops.append([7, key])
    return ops


def build(code):
    path = os.path.join(HERE, "data_%s.json" % code)
    d = json.load(open(path))
    kb, ks, kc = d['key'][0]
    st = {'b': {r[0]: list(r) for r in kb},
          's': {r[0]: list(r) for r in ks},
          'c': {r[0]: list(r) for r in kc}}
    total = d['n'] - d['k0']
    pd = []
    pkeyframes = []
    # 冻结口径：买卖点一旦判定就保留（不再因后续笔/中枢修订而消失），
    # 只允许未确认 → 已确认的单向升级，保证标注位置与类型稳定。
    frozen = {}
    for i in range(total):
        bis = sorted(st['b'].values(), key=lambda r: r[0])
        cens = sorted(st['c'].values(), key=lambda r: r[0])
        cur = compute_points(bis, cens)
        ops = []
        for key, rec in cur.items():
            if key not in frozen:
                frozen[key] = list(rec)
                # det 取「首次可判定时点」= 当前 k（可能晚于标记的笔末端，属回溯标注）
                frozen[key][3] = d['k0'] + i
                ops.append([6] + frozen[key])
            elif frozen[key][4] == 0 and rec[4] == 1:
                frozen[key][4] = 1
                ops.append([6] + frozen[key])
        if i % KF == 0:
            pkeyframes.append([list(v) for v in frozen.values()])
        if i > 0:
            pd.append(ops)
        if i < total - 1:
            apply_ops(st, d['d'][i])
    assert len(pd) == total - 1, (len(pd), total)
    d['pkey'] = pkeyframes
    d['pd'] = pd
    with open(path, 'w') as f:
        json.dump(d, f, separators=(",", ":"), ensure_ascii=False)
    last = list(frozen.values())
    from collections import Counter
    cnt = Counter(KINDS[r[1]] for r in last)
    return code, d['name'], total, len(last), cnt, os.path.getsize(path) / 1e6


if __name__ == "__main__":
    want = sys.argv[1:] or CODES
    with mp.Pool(min(6, len(want))) as pool:
        for code, name, total, npts, cnt, mb in pool.map(build, want):
            print("%s %s 时点%d 末时点买卖点%d(%s) %.2fMB" % (
                code, name, total, npts,
                " ".join("%s:%d" % (k, cnt.get(k, 0)) for k in KINDS), mb),
                flush=True)

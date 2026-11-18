#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""导出 V2 买卖点信号实例：信号根、信号价、锚点、涉及的笔/中枢。

用法：
  python3 dump_example.py 600010                 # 列出该标的最近 12 个信号
  python3 dump_example.py 600010 5894 0          # x=5894 kind=0 (B1)
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from verify_bsp import to_maps, apply_s, apply_p
import build_bsp as BB


def load(code):
    return json.load(open(os.path.join(HERE, "data_%s.json" % code)))


def last_state(d):
    m = to_maps([[], [], []], d["pkey"][0])
    for i in range(1, d["n"] - d["k0"]):
        apply_p(m, d["pd"][i - 1])
    return m


def main():
    code = sys.argv[1]
    d = load(code)
    if len(sys.argv) < 4:
        m = last_state(d)
        rows = sorted(m["p"].values(), key=lambda r: r[0])[-12:]
        for r in rows:
            x, kind, price, det, conf, anchor = r
            print("%-3s 信号 %4d(%s) 价 %-8.4f 确认%d | 极值 %4d(%s) 滞后 %3d 根" % (
                BB.KINDS[kind], x, d["bars"][x][0], price, conf, anchor,
                d["bars"][anchor][0], x - anchor))
        return
    x = int(sys.argv[2])
    kind = int(sys.argv[3])
    key = x * 8 + kind
    m = last_state(d)
    if key not in m["p"]:
        print("该标的没有这个信号")
        return
    x, kind, price, det, conf, anchor = m["p"][key]
    print("== %s %s  %s  信号根 %s(k=%d)  信号价=收盘 %.4f  conf=%d ==" % (
        code, d["name"], BB.KINDS[kind], d["bars"][x][0], x, price, conf))
    sm = to_maps(d["key"][0], [])
    for i in range(1, x - d["k0"] + 1):
        apply_s(sm, d["d"][i - 1])
    bis = sorted(sm["b"].values(), key=lambda r: r[0])
    cens = sorted(sm["c"].values(), key=lambda r: r[0])
    j = next((t for t, b in enumerate(bis) if b[1] == anchor), None)
    print("-- 结构锚点 %s(k=%d)，信号滞后 %d 根 --" % (
        d["bars"][anchor][0], anchor, x - anchor))
    if j is None:
        print("  锚点笔已不在当前结构里（被后续修订合并）")
        return
    for t in range(max(0, j - 3), min(len(bis), j + 2)):
        b = bis[t]
        mark = "*" if t == j else " "
        print("%s[%2d] %s→%s dir=%+d %.4f→%.4f %d根 strength=%.5f conf=%d" % (
            mark, t, d["bars"][b[0]][0], d["bars"][b[1]][0], b[2],
            b[3], b[4], b[1] - b[0], BB.strength(b), b[5]))
    if kind in (2, 5):
        ends = sorted([c for c in cens if c[1] <= bis[j][0]], key=lambda c: c[1])
        if ends:
            c = ends[-1]
            print("-- 依赖中枢 %s→%s ZG=%.4f ZD=%.4f 笔数=%d conf=%d，距回抽笔起点 %d 根 --" % (
                d["bars"][c[0]][0], d["bars"][c[1]][0], c[2], c[3], c[4], c[5],
                bis[j][0] - c[1]))
    print("-- 信号根 K 线 O/H/L/C = %.4f/%.4f/%.4f/%.4f --" % tuple(d["bars"][x][1:5]))


if __name__ == "__main__":
    main()

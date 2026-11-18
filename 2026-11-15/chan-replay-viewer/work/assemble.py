#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 5 个标的的压缩数据内联进 template.html，产出单文件 index.html。"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "outputs"))
CODES = ["600010", "999999", "399001", "000002", "HSI", "002613"]


def main():
    codes = sys.argv[1:] or CODES
    tpl = open(os.path.join(HERE, "template.html")).read()
    bundle = {}
    total = 0
    for c in codes:
        p = os.path.join(HERE, "data_%s.json" % c)
        d = json.load(open(p))
        total += os.path.getsize(p)
        # 买卖点已从页面移除：不把 pkey / pd 内联进交付物（work/ 下的原始数据文件保持不动）
        d.pop("pkey", None)
        d.pop("pd", None)
        bundle[c] = d
    blob = json.dumps(bundle, separators=(",", ":"), ensure_ascii=False)
    html = tpl.replace("__DATA__", blob)
    os.makedirs(OUT, exist_ok=True)
    dst = os.path.join(OUT, "index.html")
    with open(dst, "w") as f:
        f.write(html)
    print("data %.2fMB -> index.html %.2fMB" %
          (total / 1e6, os.path.getsize(dst) / 1e6))


if __name__ == "__main__":
    main()

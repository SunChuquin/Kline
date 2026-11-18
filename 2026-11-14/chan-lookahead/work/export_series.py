#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从模拟器 App 的 tdx.db 导出日线到 JSON（供 ab_test_v2.py 使用）"""
import sqlite3, json, sys, os

DB = ("/Users/sunchukun/Library/Developer/CoreSimulator/Devices/"
      "54291852-68BE-45BF-ACC0-72CEAEF10A0B/data/Containers/Data/Application/"
      "D8480395-793A-45EB-9830-EFA718A7AEBF/Documents/tdx.db")
HERE = os.path.dirname(os.path.abspath(__file__))


def dump(meta_id):
    con = sqlite3.connect(DB)
    row = con.execute("select code,name from meta where id=?", (meta_id,)).fetchone()
    bars = con.execute(
        "select date,open,high,low,close from daily where meta_id=? order by date",
        (meta_id,)).fetchall()
    con.close()
    d = {"code": row[0], "name": row[1], "bars": [list(x) for x in bars]}
    out = os.path.join(HERE, "daily_%d.json" % meta_id)
    json.dump(d, open(out, "w"), ensure_ascii=False)
    print(out, d["code"], d["name"], len(bars), bars[0][0], bars[-1][0])


if __name__ == "__main__":
    for a in sys.argv[1:]:
        dump(int(a))

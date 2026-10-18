#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""db_write.py — 数据层「写路径」下沉（《Python引擎下沉可行性分析.md》§9.9 S5）。

分工（S5 单写者原则）：
  · 读路径（图表 / 指标 / 预取每帧查询）**留在 Swift**（§9.6 阶段 D 红线）；
  · 写路径（主库合并 / 增量库行级写）下沉到本脚本 —— Swift 侧退化为「取数 + 内存比对 + 调 op」。
  · 引擎未就绪时的写库降级：用户 2026-10-18 拍板「先不管降级」——op 拿不到引擎即跳过并记日志
    （无引擎构建本就不写库）。

口径：与 Swift 侧原实现逐字段对齐；**原实现保留为单测对拍 oracle**（生产不再调用），
由 `KlineTests/DbWriteParityTests.swift` 在相同临时库上双跑比对。

op:
  · main_db_merge —— 增量快照 → 主库：单事务 INSERT OR REPLACE + 回写 meta.last_date
    （镜像 `MainDBMerger.mergeLocked`）。

IO 契约：注入 `kline_input`（含 op），脚本末尾置 `kline_result`。
"""

import json
import os
import sqlite3
import sys

MAIN_TABLES = ("daily", "weekly", "monthly", "quarterly", "yearly")

_SQL_INSERT = ("INSERT OR REPLACE INTO %s(meta_id,date,open,high,low,close,vol,amo) "
               "VALUES(?,?,?,?,?,?,?,?)")


def _err(msg):
    return {"ok": False, "error": msg}


def _ok(**kv):
    return {"ok": True, **kv}


def _num(v):
    return float(v or 0)


def _int(v):
    return int(v or 0)


def _op_main_db_merge(inp):
    """增量快照 → 主库（单事务）。

    输入：{"op": "main_db_merge", "dbPath": "...",
           "snapshot": {"daily": [{file,date,open,high,low,close,vol,amo}], "weekly": [...], ...}}
    输出：{"ok": true, "result": {ok, dailyRows, weeklyRows, monthlyRows, quarterlyRows,
                                  yearlyRows, hitSymbols, skippedNoFile, latestDate, message}}
    语义（逐条对齐 MainDBMerger.mergeLocked）：
      · file → meta_id 取 `SELECT id,file FROM meta ORDER BY id ASC` 的**首个**命中；
      · 只对**主库实际存在**的周期表写入；主库 meta 为空 / 无周期表 → ok=false（不写）；
      · 单事务（BEGIN IMMEDIATE）；任一行失败 → ROLLBACK 且计数全部归零；
      · 成功后回写 `meta.last_date`（该 meta_id 在增量里的最大 date）。
    """
    db_path = inp.get("dbPath")
    snap = inp.get("snapshot") or {}
    if not db_path:
        return _err("dbPath 缺失")
    if not os.path.exists(db_path):
        return _err("主库不存在：%s" % db_path)

    groups = [(t, snap.get(t) or []) for t in MAIN_TABLES]
    if not any(rows for _, rows in groups):
        return _err("增量快照为空")

    conn = sqlite3.connect(db_path, timeout=30.0)
    try:
        conn.isolation_level = None          # 自行控制事务（与 Swift 的 BEGIN IMMEDIATE 对齐）
        cur = conn.cursor()

        files = {}
        for row in cur.execute("SELECT id, file FROM meta ORDER BY id ASC"):
            f = row[1]
            if f is not None and f not in files:
                files[f] = _int(row[0])
        if not files:
            return _ok(result={"ok": False, "message": "主库 meta 为空，无法合并"})

        present = []
        for table in MAIN_TABLES:
            hit = cur.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                              (table,)).fetchone()
            if hit:
                present.append(table)
        if not present:
            return _ok(result={"ok": False, "message": "主库缺少周期表，无法合并"})

        counts = {t: 0 for t in MAIN_TABLES}
        hit_ids = set()
        max_date_by_id = {}
        latest = 0
        skipped = 0
        failed = None

        cur.execute("BEGIN IMMEDIATE")
        try:
            for table, rows in groups:
                if table not in present:
                    continue
                for row in rows:
                    meta_id = files.get(row.get("file"))
                    if meta_id is None:
                        skipped += 1
                        continue
                    date = _int(row.get("date"))
                    cur.execute(_SQL_INSERT % table,
                                (meta_id, date, _num(row.get("open")), _num(row.get("high")),
                                 _num(row.get("low")), _num(row.get("close")),
                                 _num(row.get("vol")), _num(row.get("amo"))))
                    counts[table] += 1
                    hit_ids.add(meta_id)
                    if date > latest:
                        latest = date
                    if date > max_date_by_id.get(meta_id, 0):
                        max_date_by_id[meta_id] = date
            for meta_id, date in max_date_by_id.items():
                cur.execute("UPDATE meta SET last_date = ? WHERE id = ?", (date, meta_id))
            cur.execute("COMMIT")
        except Exception as exc:  # noqa: BLE001 —— 与 Swift 的 failed 分支同口径
            try:
                cur.execute("ROLLBACK")
            except Exception:  # noqa: BLE001
                pass
            failed = str(exc)

        if failed is not None:
            return _ok(result={"ok": False,
                               "dailyRows": 0, "weeklyRows": 0, "monthlyRows": 0,
                               "quarterlyRows": 0, "yearlyRows": 0,
                               "hitSymbols": 0, "skippedNoFile": 0, "latestDate": 0,
                               "message": "合并失败（已回滚）：%s" % failed})

        message = ("已合并 %d 行（日%d/周%d/月%d/季%d/年%d） · 覆盖 %d 只 · 最新 %d"
                   % (sum(counts.values()), counts["daily"], counts["weekly"], counts["monthly"],
                      counts["quarterly"], counts["yearly"], len(hit_ids), latest))
        return _ok(result={"ok": True,
                           "dailyRows": counts["daily"], "weeklyRows": counts["weekly"],
                           "monthlyRows": counts["monthly"], "quarterlyRows": counts["quarterly"],
                           "yearlyRows": counts["yearly"],
                           "hitSymbols": len(hit_ids), "skippedNoFile": skipped,
                           "latestDate": latest, "message": message})
    finally:
        conn.close()


_OPS = {
    "main_db_merge": _op_main_db_merge,
}


def _main():
    inp = globals().get("kline_input")
    if not isinstance(inp, dict):
        return _err("kline_input 未注入或不是对象")
    op = inp.get("op")
    handler = _OPS.get(op)
    if handler is None:
        return _err("未知 op: %r（仅支持 %s）" % (op, " / ".join(sorted(_OPS))))
    try:
        out = handler(inp)
    except Exception as exc:  # noqa: BLE001 —— 形状非法即 ok=False
        return _err("%s 执行异常：%s" % (op, exc))
    if isinstance(out, dict) and out.get("ok") is False:
        return out
    result = {"ok": True}
    if isinstance(out, dict):
        result.update(out)
    return result


kline_result = _main()

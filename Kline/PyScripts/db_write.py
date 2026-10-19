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


_SQL_INSERT_LIVE_META = ("INSERT OR IGNORE INTO live_meta(file,code,name,type,updated_at) "
                         "VALUES(?,?,?,?,?)")
_SQL_BAR = "INSERT OR REPLACE INTO %s(file,date,open,high,low,close,vol,amo) VALUES(?,?,?,?,?,?,?,?)"


def _write_bars(cur, table, rows):
    """按 (file,date) UPSERT 一组 bar，返回本次 changes 行数。"""
    n = 0
    for b in rows:
        before = cur.connection.total_changes
        cur.execute(_SQL_BAR % table,
                    (b.get("file"), _int(b.get("date")), _num(b.get("open")), _num(b.get("high")),
                     _num(b.get("low")), _num(b.get("close")), _num(b.get("vol")),
                     _num(b.get("amo"))))
        n += cur.connection.total_changes - before
    return n


def _live_row_identical(cur, table, bar):
    """某表是否已有该 (file,date) 且 6 个数值字段与传入值一致（容差 1e-6，镜像 Swift）。
    无该行 / 值不同 / 查询失败 → False（视为需要写入）。"""
    try:
        row = cur.execute("SELECT open,high,low,close,vol,amo FROM %s WHERE file = ? AND date = ?"
                          % table, (bar.get("file"), _int(bar.get("date")))).fetchone()
    except Exception:  # noqa: BLE001
        return False
    if row is None:
        return False
    return all(abs(a - b) < 1e-6 for a, b
               in zip(row, (_num(bar.get("open")), _num(bar.get("high")), _num(bar.get("low")),
                            _num(bar.get("close")), _num(bar.get("vol")), _num(bar.get("amo")))))


def _live_meta_exists(cur, file):
    try:
        return cur.execute("SELECT 1 FROM live_meta WHERE file = ? LIMIT 1", (file,)).fetchone() \
            is not None
    except Exception:  # noqa: BLE001
        return False


def _live_table_name(cur, table):
    """镜像 `_localTableNameLocked`：`live_<t>` 优先，回落旧版无前缀 `<t>`，都没有 → None。"""
    for name in ("live_" + table, table):
        hit = cur.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                          (name,)).fetchone()
        if hit:
            return name
    return None


def _op_live_upsert_daily(inp):
    """增量库行级写（清单日更 / 补缺口的结果落 `tdx_live.db`）。

    ⚠️ 边界（§11.34）：**写前比对与末梢写语句都在引擎内**——
    「哪些行需要写」（`SELECT` + 1e-6 容差比对 / `live_meta` 存在性 / 表名解析）与
    `INSERT OR IGNORE` / `INSERT OR REPLACE` 一并承接；Swift 只负责打开连接、保证 schema
    （v3 迁移）与结果投影。
    ⚠️ 仍是读侧的：**打开连接 / schema 保证 / 周期日历口径**（`LiveDataStore._trimBoundsLocked`）。

    输入：{"dbPath", "metaUpdatedAt", "metas":[{file,code,name,type}],
           "bars":[bar], "periodBars":{"quarterly":[bar], "yearly":[bar]}}
    输出：{"ok", "metaRows", "dailyRows", "quarterlyRows", "yearlyRows", "coveredFiles", "message"}
    """
    db_path = inp.get("dbPath")
    metas = inp.get("metas") or []
    bars = inp.get("bars") or []
    period_bars = inp.get("periodBars") or {}
    meta_updated_at = _int(inp.get("metaUpdatedAt"))
    period_row_count = sum(len(v or []) for v in period_bars.values())

    out = {"ok": False, "metaRows": 0, "dailyRows": 0, "quarterlyRows": 0,
           "yearlyRows": 0, "coveredFiles": 0, "message": "无数据可写入"}
    if not metas and not bars and not period_bars:
        return _ok(result=out)
    if not db_path or not os.path.exists(db_path):
        out["message"] = "本地增量库不可写（打开失败）"
        return _ok(result=out)

    conn = sqlite3.connect(db_path, timeout=30.0)
    try:
        conn.isolation_level = None
        cur = conn.cursor()

        # ① 写前判定：只保留「库里没有该 (file,date)」或「任一字段不同」的日线、
        #    live_meta 尚不存在的标的，以及库内不一致的当期季/年 bar。
        changed_bars = [b for b in bars if not _live_row_identical(cur, "live_daily", b)]
        new_metas = [m for m in metas if not _live_meta_exists(cur, m.get("file"))]
        changed_period = []          # [(table, rows)]
        for period in ("quarterly", "yearly"):
            rows = period_bars.get(period) or []
            if not rows:
                continue
            table = _live_table_name(cur, period)
            if table is None:
                continue
            changed = [b for b in rows if not _live_row_identical(cur, table, b)]
            if changed:
                changed_period.append((table, changed))

        if not changed_bars and not new_metas and not changed_period:
            out["ok"] = True
            out["coveredFiles"] = cur.execute("SELECT COUNT(*) FROM live_meta;").fetchone()[0]
            out["message"] = ("无变化：日线 %d 行 / meta %d 条 / 当期季年 %d 行均与库内一致 → 跳过写入"
                              % (len(bars), len(metas), period_row_count))
            return _ok(result=out)

        # ② 单事务写（至此与 Swift oracle 的写语句块同源）
        try:
            cur.execute("BEGIN IMMEDIATE")
        except Exception as exc:  # noqa: BLE001
            out["message"] = "开启事务失败：%s" % exc
            return _ok(result=out)

        failed = None
        try:
            for m in new_metas:
                before = conn.total_changes
                cur.execute(_SQL_INSERT_LIVE_META,
                            (m.get("file"), m.get("code"), m.get("name"), m.get("type"),
                             meta_updated_at))
                out["metaRows"] += conn.total_changes - before
            if changed_bars:
                out["dailyRows"] = _write_bars(cur, "live_daily", changed_bars)
            for table, rows in changed_period:
                n = _write_bars(cur, table, rows)
                if table.endswith("quarterly"):
                    out["quarterlyRows"] = n
                else:
                    out["yearlyRows"] = n
            cur.execute("COMMIT")
        except Exception as exc:  # noqa: BLE001
            failed = str(exc)
            try:
                cur.execute("ROLLBACK")
            except Exception:  # noqa: BLE001
                pass

        if failed is not None:
            out["metaRows"] = out["dailyRows"] = 0
            out["quarterlyRows"] = out["yearlyRows"] = 0
            out["coveredFiles"] = 0
            out["message"] = "写入失败（已回滚）%s" % failed
            return _ok(result=out)

        out["ok"] = True
        out["coveredFiles"] = cur.execute("SELECT COUNT(*) FROM live_meta;").fetchone()[0]
        out["message"] = ("写入完成 meta新增=%d 条 / daily变化=%d 行 / 季%d行·年%d行"
                          "（传入 meta %d 条 / 日线 %d 行 / 当期季年 %d 行，其余与库内一致已跳过）覆盖=%d只"
                          % (out["metaRows"], out["dailyRows"], out["quarterlyRows"],
                             out["yearlyRows"], len(metas), len(bars), period_row_count,
                             out["coveredFiles"]))
        return _ok(result=out)
    finally:
        conn.close()


def _op_live_trim(inp):
    """增量库裁剪（DELETE）：**边界由 Swift 算**（周/月/季/年的「当期日历起始」依赖
    `KlinePeriod.periodDateRange`，属读侧口径，留 Swift），本 op 只执行删除语句。

    输入：{"dbPath", "beforeDate", "items":[{"table","bound","inclusive":bool}]}
    输出：{"ok", "deletedRows", "message"}
    """
    db_path = inp.get("dbPath")
    before_date = _int(inp.get("beforeDate"))
    items = inp.get("items") or []
    if not db_path or not os.path.exists(db_path) or before_date <= 0:
        return _ok(result={"ok": True, "deletedRows": 0, "message": "无需裁剪"})

    conn = sqlite3.connect(db_path, timeout=30.0)
    try:
        conn.isolation_level = None
        cur = conn.cursor()
        try:
            cur.execute("BEGIN IMMEDIATE")
        except Exception as exc:  # noqa: BLE001
            return _ok(result={"ok": False, "deletedRows": 0,
                               "message": "开启事务失败：%s" % exc})

        total = 0
        for item in items:
            table = item.get("table")
            if not table:
                continue
            op = "<=" if item.get("inclusive") else "<"
            try:
                before = conn.total_changes
                cur.execute("DELETE FROM %s WHERE date %s ?" % (table, op),
                            (_int(item.get("bound")),))
                total += conn.total_changes - before
            except Exception as exc:  # noqa: BLE001
                try:
                    cur.execute("ROLLBACK")
                except Exception:  # noqa: BLE001
                    pass
                return _ok(result={"ok": False, "deletedRows": 0,
                                   "message": "裁剪 %s 失败（已回滚）：%s" % (table, exc)})
        try:
            cur.execute("COMMIT")
        except Exception as exc:  # noqa: BLE001
            try:
                cur.execute("ROLLBACK")
            except Exception:  # noqa: BLE001
                pass
            return _ok(result={"ok": False, "deletedRows": 0,
                               "message": "裁剪提交失败（已回滚）：%s" % exc})
        return _ok(result={"ok": True, "deletedRows": total,
                           "message": "裁剪完成：删除 %d 行（日线 date <= %d；"
                                      "周/月/季/年 < 主库最新日 %d 所在周期桶起始）"
                                      % (total, before_date, before_date)})
    finally:
        conn.close()


_SQL_BARS = ("SELECT date, open, high, low, close, vol, amo FROM %s WHERE meta_id = ? "
             "ORDER BY date DESC")


def _bars_for(cur, table, meta_id, limit):
    """取某只标的的主库原始行（DESC）；表不存在 / prepare 失败 → 空数组（非错误）。

    口径逐字对齐 Swift `DatabaseManager.runBarsQuery`：
      · `vol` / `amo` **只有 REAL 类型才取列值，其余（含 INTEGER / NULL）取 0**。
    """
    sql = _SQL_BARS % table
    args = [meta_id]
    if limit is not None:
        sql += " LIMIT ?"
        args.append(max(1, _int(limit)))
    rows = []
    for r in cur.execute(sql, args):
        def _real(i):
            v = r[i]
            return float(v) if isinstance(v, float) else 0.0
        rows.append([_int(r[0]), _real(1), _real(2), _real(3), _real(4), _real(5), _real(6)])
    return rows


def _op_db_query_batch(inp):
    """主库 K 线**按批读**（§11.42 按批摊薄；§11.45 出参改走 **bin 通道**）。

    动机：单只读每次 ~12ms（固定传输开销，SQL 只占极小部分）→ 按批摊薄；
    按批后单批 4000 行的**出参 JSON 编码**又成了引擎耗时大头 → 出参改二进制
    （`__bin_out__`，键 = metaID，值 = 行扁平化的 double 序列，Swift 按 7 个一组切回行）。

    ⚠️ 摊薄的是**传输**，不是改变口径：SQL / `vol|amo` 的 REAL 判定 / 缺表返回空与逐只读逐字一致。

    输入：{"dbPath", "table", "symbols": [{"metaID": 1, "limit": 80|None}, ...]}
    输出：{"ok": true, "__bin_out__": {"<metaID>": [date,open,high,low,close,vol,amo, <下一行>…]}}
          每个被请求的 metaID 都出现（无行 → 空序列）。
    """
    db_path = inp.get("dbPath")
    table = inp.get("table")
    if not db_path or not os.path.exists(db_path) or not table:
        return _err("dbPath / table 缺失或库不存在")
    symbols = inp.get("symbols")
    if not isinstance(symbols, list):
        return _err("symbols 须为数组")

    conn = sqlite3.connect(db_path, timeout=30.0)
    try:
        cur = conn.cursor()
        out = {}
        for sym in symbols:
            if not isinstance(sym, dict):
                continue
            meta_id = sym.get("metaID")
            if meta_id is None:
                continue
            key = str(_int(meta_id))
            try:
                rows = _bars_for(cur, table, _int(meta_id), sym.get("limit"))
            except Exception:  # noqa: BLE001 —— 与逐只读的「prepare 失败返回空」同口径
                rows = []
            flat = []
            for r in rows:
                flat.extend(r)          # 每行 7 个数：date,open,high,low,close,vol,amo
            out[key] = flat
        return {"ok": True, "__bin_out__": out}
    finally:
        conn.close()


_OPS = {
    "main_db_merge": _op_main_db_merge,
    "live_upsert_daily": _op_live_upsert_daily,
    "live_trim": _op_live_trim,
    "db_query_batch": _op_db_query_batch,
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

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Kline「txt 直出差分」出包器：**新 txt 目录 + 基线库** → `patch_<seq>.db`，**不重建任何库**。

为什么要有它（spec: `.trae/specs/apply-patch-into-main-db/`）
----------------------------------------------------------------
旧路线 `新 txt --导入--> 重建 tdx.db(实测 585.1s) --差分--> 补丁` 与「只改差异」相反，且 1 分钟
内不可能完成。新路线直接把**基线库**当作旧值真相源，逐文件比对，只产出**真正不同或新增**的行：

    新 txt --与基线库逐行比对--> patch_<seq>.db --推--> 设备主库（行级 UPSERT）

本脚本是 Task 2。Task 0 的只读原型 `build_logs/_proto_task0.py` 实测 A+B+C = 31.5s、
产出 842,816 行 / 76.2 MB，本脚本沿用其已验证的解析/分类/聚合/比对逻辑，补上参数、日志、
manifest、自检与只读安全机制。

txt 结构与两个关键事实（实测，**改错会全部误判**）
--------------------------------------------------
· 文件 = 表头行 / 列名行 / 数据行 `date;open;high;low;close;vol;amo` / 页脚行
  `#数据来源:通达信\\r\\n`（GBK，**恰 18 字节**）。新数据追加在**页脚之前**，所以旧文件最后
  18 字节必然与同位置的新文件不同 → **判定「纯追加」必须排除末尾 18 字节**（否则 append 3440 → 0）。
  解析追加文件时：`seek(旧长度-18)` → `readline()` 丢掉页脚行 → 其余即新增数据行。
· 197 个 rewrite 是**真全历史改写**（92.7% 日线行变化，最早追溯到 1994）→ 76MB 补丁是真实必需。

分类：复用 Task 1（`src/txt_changes.py`）的成果
----------------------------------------------
`txt_changes.classify_kind(old_path, new_path)` 是**全项目唯一一份**分类实现（三处采样、口径见其
docstring）。但它自己会开 2 次句柄，若先调用它再另开一次解析 = 每文件 3 次打开，违反「每文件
打开次数 ≤ 2」的性能红线。故本脚本按 Task 2 允许的方式**自行融合**：`classify_and_read()` 在同一
个「新文件句柄」内先按 `classify_kind` 的**同一口径**采样判 kind，再就地读尾部/整文件解析 ——
每文件恰好 **2 次句柄**（旧 1 次采样、新 1 次采样+解析）。采样长度与页脚长度直接复用
`txt_changes._FOOTER_LEN` / `_SAMPLE_LEN`，保证只有一份常量。

三条路径
--------
· `append`：只解析尾部新增行，**全部日线行直接进包**（不做行级比对，因为文件前 `旧长度-18`
  字节与旧 txt 逐字节一致 ⇒ 其历史行与库内必然相同）。周/月/季/年线用**增量合并**：开局
  **一次性**由基线最大交易日推出当期四个周期（候选集），并用 **4 条批量查询**把四张周期表的
  「当期 bar」整表捞出（`{meta_id: bar}`）；每个标的**只对被新数据触及的周期**与该 bar 合并
  （基线无该周期 bar → 直接用新数据聚合）。**不再逐标的探查基线**（性能红线 3）。
  基线可能在**未完成周期**处截断（实测基线止于 20260828，20260831 仍在 8 月 → 8 月月线要更新）。
· `rewrite`：整文件解析 → 聚合 → 与基线**全部**行比对 → 只发真正不同/新增的（整只标的全量重算）。
· `new`（仅新目录有）：整文件解析 → 全部行进包；meta 从 txt 表头解析 code/name。

周/月/季/年线聚合口径（**照抄 `tdx_parser.py:493-551 period_key/handle_data`，不得另发明**）
---------------------------------------------------------------------------------------------
同一周期内：`open` 取该周期**第一行**、`high = max`、`low = min`、`close` 取**最后一行**、
`vol`/`amo` **累加**；周期 `date` = **该周期第一个交易日**（周线 = 该周首个交易日、月线 = 该月
首个交易日、季线 = 该季首个交易日、年线 = 该年首个交易日）。分组键与 `tdx_parser.period_key`
一致：周 = 该周周一、月 = `YYYYMM`、季 = `YYYYQ`（`year*10+(month-1)//3+1`）、年 = `YYYY`。
与 `live_db_builder.py` 的分片口径一致。

性能红线（Task 0 实测，缺一条就超时）
--------------------------------------
1. 分类与解析**融合**，每文件**只开 2 次句柄**。
2. **周一映射必须缓存**（每行构造 `datetime` 会让 B 段从 10s 涨到 20s）。
3. append 的周期合并**只做 4 条批量查询**：开局一次性把四张周期表的「当期 bar」整表捞出
   （`load_current_bars`，`WHERE date BETWEEN 周期起始 AND 周期结束`）→ `{meta_id: bar}`，
   每个标的直接查字典合并。**禁止逐标的探查基线**（3611 只 × 4 周期 ≈ 14k 次随机探查，
   每次进 4 张大表约 3ms → A 段从 ~12s 退化到 ~60s）。

安全与只读（硬约束）
--------------------
基线库以 `file:...?mode=ro` **只读打开**，连接上再加 `PRAGMA query_only=1` 双保险；脚本里
**不存在任何写基线库的代码路径**。跑完用 `(st_size, st_mtime_ns)` 复核基线库未被修改
（**不算 sha256** —— 用户明确不接受 1.4GB 级全量读，只读打开本身已是机制保证）。

正确性硬门槛（`--self-check N`）
--------------------------------
用**独立的全量重算**交叉验证（不复用出包时的逻辑）：随机抽 N 个文件（约一半 append + 一半
rewrite），对每个文件**完整解析整个新 txt**（不走 append 尾部捷径）→ 自行聚合全部周/月行 →
与基线库该 file 的**全部**行比对得到「真差异集合」→ 断言补丁里该 file 的行**恰好等于**真差异
集合（不多不少）。「不多」尤其重要：补丁里不得出现与基线值完全相同的行。

用法
----
    python src/txt_patch_builder.py --old-txt-dir C:\\Users\\sunck\\home\\tdx_data_old \\
                                    --new-txt-dir C:\\Users\\sunck\\home\\tdx_data
    python src/txt_patch_builder.py --old-txt-dir <旧> --new-txt-dir <新> --dry-run
    python src/txt_patch_builder.py --old-txt-dir <旧> --new-txt-dir <新> --self-check 200
"""

import argparse
import datetime
import multiprocessing
import os
import random
import sqlite3
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import live_db_builder as L        # noqa: E402  只读 URI / 日期口径 / 分片落盘（表结构契约）
import txt_changes as TC           # noqa: E402  变更分类（全项目唯一一份，Task 1）

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

# 常量：页脚长度与采样长度直接复用 txt_changes，保证只有一份
FOOTER = TC._FOOTER_LEN            # 18（页脚 `#数据来源:通达信\r\n`）
SAMPLE = TC._SAMPLE_LEN            # 4096（单处采样长度）
FLOAT_TOL = 1e-6                   # 浮点容差（与 diff_live_patch.py 同口径）
FIELDS = ("open", "high", "low", "close", "vol", "amo")
PATCH_PREFIX = "patch_"
DEFAULT_BASE_DB = r"C:\Users\sunck\home\tdx_baseline.db"
DEFAULT_OUT = r"c:\Users\sunck\home\projects\ios\Kline\build_logs\patches"
TXT_EXT = ".txt"
# 补丁携带的五张周期表（**分片契约仍是三张**，只有补丁走这里）
PATCH_PERIODS = ("daily", "weekly", "monthly", "quarterly", "yearly")
# append 时按周期把「基线当期 bar」批量预取 → 与新日线合并（Task 1.3）
MERGE_PERIODS = ("weekly", "monthly", "quarterly", "yearly")


# ---------------------------------------------------------------------------
# 周期键 / 聚合（口径照抄 tdx_parser.handle_data，见模块 docstring）
# ---------------------------------------------------------------------------

_MON = {}                          # 周一映射缓存（性能红线 2）
_KEYS = {}                         # 日期 → 周/月/季/年四个分组键的缓存（性能红线 2）


def monday_key(date_int):
    """YYYYMMDD → 所在周周一（YYYYMMDD）。**必须缓存**，否则 B 段从 10s 涨到 20s。"""
    v = _MON.get(date_int)
    if v is None:
        d = datetime.date(date_int // 10000, date_int // 100 % 100, date_int % 100)
        v = L.date_to_int(d - datetime.timedelta(days=d.weekday()))
        _MON[date_int] = v
    return v


def month_key(date_int):
    """YYYYMMDD → YYYYMM（与 tdx_parser.period_key 的 year*100+month 等价）。"""
    return date_int // 100


def month_first(date_int):
    """该日期所在自然月的 1 号（YYYYMMDD）。"""
    return date_int // 100 * 100 + 1


def quarter_key(date_int):
    """YYYYMMDD → YYYYQ（Q=1~4），**口径照抄 `tdx_parser.period_key`**。"""
    y, m = date_int // 10000, date_int // 100 % 100
    return y * 10 + (m - 1) // 3 + 1


def year_key(date_int):
    """YYYYMMDD → YYYY，**口径照抄 `tdx_parser.period_key`**。"""
    return date_int // 10000


def quarter_first(date_int):
    """该日期所在季度的日历起始（YYYYMMDD，季首月 1 号）。"""
    y, m = date_int // 10000, date_int // 100 % 100
    return y * 10000 + (((m - 1) // 3) * 3 + 1) * 100 + 1


def year_first(date_int):
    """该日期所在年份的日历起始（YYYYMMDD，1 月 1 号）。"""
    return date_int // 10000 * 10000 + 101


def period_start(date_int, period):
    """该周期行的「日历起始日」：周=周一、月=当月 1 号、季=季首月 1 号、年=1 月 1 号。"""
    if period == "weekly":
        return monday_key(date_int)
    if period == "monthly":
        return month_first(date_int)
    if period == "quarterly":
        return quarter_first(date_int)
    return year_first(date_int)


def period_cal_end(cal_start, period):
    """周期日历起始日 → 该周期日历结束日（YYYYMMDD）。用于「索引范围查询基线那一根 bar」。"""
    d = datetime.date(cal_start // 10000, cal_start // 100 % 100, cal_start % 100)
    if period == "weekly":
        return L.date_to_int(d + datetime.timedelta(days=6))
    span = {"monthly": 32, "quarterly": 93, "yearly": 366}[period]
    nxt = (d + datetime.timedelta(days=span)).replace(day=1)     # 该周期结束月之后的 1 号
    return L.date_to_int(nxt - datetime.timedelta(days=1))


def agg_all_periods(rows):
    """**一趟**聚合出周/月/季/年四张周期表（照抄 tdx_parser.handle_data 的语义）。

    rows 为**按日期升序**的 `(date, open, high, low, close, vol, amo)`；同一周期内
    open 取第一行、high=max、low=min、close 取最后一行、vol/amo 累加；周期 date 取该周期首个交易日。
    返回 `{period: [(date,open,high,low,close,vol,amo), ...]}`。

    性能（rewrite 路径的红线）：四个分组键按**日期**缓存（`_KEYS`，全市场仅 ~8000 个交易日），
    避免每行重复做 `//10000`/`//100` 之类的除法——实测 4 趟独立聚合 6.0s → 一趟 3.7s。
    """
    out = {p: [] for p in MERGE_PERIODS}
    last = {p: None for p in MERGE_PERIODS}
    get = _KEYS.get
    for r in rows:
        d = r[0]
        ks = get(d)
        if ks is None:
            ks = (monday_key(d), month_key(d), quarter_key(d), year_key(d))
            _KEYS[d] = ks
        for p, k in zip(MERGE_PERIODS, ks):
            cur = out[p]
            if k != last[p]:
                cur.append([d, r[1], r[2], r[3], r[4], r[5], r[6]])
                last[p] = k
            else:
                c = cur[-1]
                if r[2] > c[2]:
                    c[2] = r[2]              # high
                if r[3] < c[3]:
                    c[3] = r[3]              # low
                c[4] = r[4]                  # close
                c[5] += r[5]                 # vol
                c[6] += r[6]                 # amo
    return {p: [tuple(x) for x in out[p]] for p in MERGE_PERIODS}


# ---------------------------------------------------------------------------
# 增量合并（append 路径）：基线该周期那一根 bar ⊕ 新日线（Task 1.2 / 1.3）
# ---------------------------------------------------------------------------

def load_current_bars(base, period, lo):
    """开局**一次性**把该周期「当期 bar」整表捞出 → `{meta_id: (date,o,h,l,c,v,a)}`。

    周期 `date` = 该周期首个交易日，必落在 `[lo, period_cal_end(lo)]` 内 → 一条范围查询就能
    拿到**所有标的**的当期 bar，**取代逐标的的 14k 次索引探查**（这是 A 段性能红线的关键）。
    """
    ce = period_cal_end(lo, period)
    out = {}
    for r in base.execute(
            "SELECT meta_id,date,open,high,low,close,vol,amo FROM %s "
            "WHERE date>=? AND date<=?" % period, (lo, ce)):
        out[int(r[0])] = (int(r[1]), r[2], r[3], r[4], r[5], r[6] or 0.0, r[7] or 0.0)
    return out


def merge_period_bar(new_rows, base_bar):
    """新日线（升序，同一周期）与基线该周期 bar 合并；基线无 bar → 直接用新数据聚合。

    口径与整周期重算**逐字段等价**（新数据必在基线之后，故 close 取新末行、open 取基线首行）：
    open 取周期首行、high/low 取极值、close 取末行、vol/amo 累加；date = 该周期首个交易日。
    """
    hi = max(r[2] for r in new_rows)
    lo = min(r[3] for r in new_rows)
    vol = sum(r[5] for r in new_rows)
    amo = sum(r[6] for r in new_rows)
    if base_bar is None:
        return (new_rows[0][0], new_rows[0][1], hi, lo, new_rows[-1][4], vol, amo)
    return (base_bar[0], base_bar[1], max(base_bar[2], hi), min(base_bar[3], lo),
            new_rows[-1][4], base_bar[5] + vol, base_bar[6] + amo)


def merge_period_rows(new_daily, period, lo, cur_bar):
    """对某周期，按「被新数据触及的周期」分组 → 与基线**当期 bar** 合并（增量合并）。

    · `cur_bar` = 该标的基线**当期** bar（`load_current_bars` 批量预取）或 None。
      只有 `cs == lo` 的周期才可能在基线里有 bar；`cs > lo` 的周期起始于 dmax 之后，
      基线必然没有 → 直接用新数据聚合（**不回查基线**，Task 1.3 / 细节 3）。
    · 守卫：日历起始 < lo 的周期直接跳过（与旧实现一致；基线若未截断到该周期，`min()` 会取到
      上一周期而产出**局部**周期行——被跳过的周期不受新数据影响，其基线行本就正确）。
    · 返回升序的周期行 `(date,open,high,low,close,vol,amo)`。
    """
    groups = {}
    for r in new_daily:
        groups.setdefault(period_start(r[0], period), []).append(r)
    out = []
    for cs in sorted(groups):
        if cs < lo:
            continue
        rs = sorted(groups[cs], key=lambda x: x[0])
        out.append(merge_period_bar(rs, cur_bar if cs == lo else None))
    return out


def diff_period_append(cand, period, lo, cur_bar, tol):
    """append 的周期比对：只有当期（`cs==lo`）在基线里有 bar 可比，其余是新周期 → 直接发。

    取代原先「逐标的 `ORDER BY date DESC LIMIT 8`」的两次探查（细节 1）。
    """
    out = []
    for r in cand:
        if period_start(r[0], period) == lo and cur_bar is not None:
            if not _same6(r[1:], cur_bar[1:], tol):
                out.append(r)
        else:
            out.append(r)
    return out


# ---------------------------------------------------------------------------
# 解析 / 分类（融合，每文件 ≤ 2 次句柄）
# ---------------------------------------------------------------------------

def parse_daily(lines):
    """数据行 → `(date, open, high, low, close, vol, amo)`；非法行（表头/列名/残缺）直接跳过。"""
    out = []
    for line in lines:
        p = line.split(";")
        if len(p) < 7:
            continue
        p[-1] = p[-1].strip()
        try:
            d = int(p[0])
            if d <= 19000101:            # 无效日期（防御性；正常数据行不会出现）
                continue
            out.append((d, float(p[1]), float(p[2]), float(p[3]), float(p[4]),
                        float(p[5]) if p[5] else 0.0, float(p[6]) if p[6] else 0.0))
        except (ValueError, IndexError):
            continue
    return out


def classify_and_read(old_path, new_path, force_full=False):
    """一次拿齐：变更类型 + 候选日线。**每文件最多开 2 次句柄**（旧 1、新 1）。

    返回 `(kind, daily_rows, header_line_or_None)`：
      · kind ∈ {"append","rewrite","new"}，判定口径与 `txt_changes.classify_kind` **完全一致**
        （三处采样：头 4096 / 旧长度-18 的一半处 / 旧尾 4096，三处全一致 ⇒ append，任一不同 ⇒
        rewrite；新文件更小、旧文件去页脚后长度 ≤ 0、或任何异常 ⇒ rewrite「拿不准一律 rewrite」）。
      · `force_full=True` 时无论 kind 都读整文件（基线里没有这个 file 时全部行都算新增，
        只读尾部会漏掉整段历史）。
      · `append` 且未 force_full 时只在**已打开的新文件句柄**上 `seek(旧长度-18)` 读余下；
        `rewrite`/`new` 时读整文件。避免为解析再开一次句柄。
      · `new`（旧文件不存在）时额外返回首行（表头），供解析 code/name。

    ⚠ **尾部偏移的正确性（实测修正 Task 0 原型的 bug）**：旧文件 = `数据区 + 页脚(18B)`，
    新文件 = `同一数据区 + 新增数据 + 页脚`，所以新数据**恰好从 `旧长度-18` 开始**。
    原型在此处又调了一次 `readline()` 想"丢掉页脚行"，实际丢的是**第一条新增数据行**
    （实测每个 append 文件少 1 根日线 → 全量少 ~3440 行，且末周/月末周期行的 date 被推后）。
    正确做法：`seek(旧长度-18)` 后直接读完，页脚行不含 `;`，由 `parse_daily` 自然跳过。
    """
    if not os.path.exists(old_path):
        with open(new_path, "rb") as fn:
            text = fn.read().decode("gbk", "replace")
        lines = text.splitlines()
        header = lines[0] if lines else None
        return "new", parse_daily(lines), header

    o_sz = os.path.getsize(old_path)
    n_sz = os.path.getsize(new_path)
    lim = o_sz - FOOTER
    kind = "rewrite"                      # 默认/兜底：多干活，绝不漏
    with open(old_path, "rb") as fo, open(new_path, "rb") as fn:
        if n_sz >= o_sz and lim > 0:
            kind = "append"
            for off in (0, max(0, lim // 2 - SAMPLE // 2), max(0, lim - SAMPLE)):
                fo.seek(off)
                fn.seek(off)
                if fo.read(SAMPLE) != fn.read(SAMPLE):
                    kind = "rewrite"
                    break
        if kind == "append" and not force_full:
            fn.seek(max(0, o_sz - FOOTER))   # 新数据起点；页脚行由 parse_daily 跳过
            data = fn.read()
        else:
            fn.seek(0)
            data = fn.read()
    return kind, parse_daily(data.decode("gbk", "replace").splitlines()), None


def parse_header(line):
    """txt 表头行 → `(code, name)`（口径照抄 `tdx_parser.py:599-603`）。

    例 `600519 贵州茅台 日线 前复权` → `("600519", "贵州茅台")`（尾部 `前复权`/`日线` 两段丢弃）。
    """
    parts = line.strip().split()
    if not parts:
        return None, None
    code = parts.pop(0)
    if len(parts) >= 2:
        parts.pop(-1)
        parts.pop(-1)
    return code, " ".join(parts)


def guess_type(file_str):
    """基线里没有的 file（新上市）按 `tdx_parser.py:632-634` 的口径猜 type。"""
    prefix = file_str.split("#", 1)[0]
    if prefix in ("SH", "SZ"):
        return "沪深京指数" if file_str[:6] in ("SZ#399", "SH#000", "SH#999") else "沪深主板"
    return "扩展行情指数"


def diff_rows(cand, have, tol):
    """cand 中与 `have`（{date: (open,...,amo)}）不同或 `have` 里没有的行。"""
    out = []
    for r in cand:
        o = have.get(r[0])
        if o is None or any(abs((r[i] or 0.0) - (o[i - 1] or 0.0)) > tol for i in range(1, 7)):
            out.append(r)
    return out


def _have_all(base, mid, period):
    """基线该 file 某周期的**全部**行 → {date: (open,...,amo)}（rewrite 比对用）。"""
    return {int(r[0]): r[1:] for r in base.execute(
        "SELECT date,open,high,low,close,vol,amo FROM %s WHERE meta_id=?" % period, (mid,))}


def _emit(rows, file_str, period, cand):
    """把候选行写入 `rows[period]`（补丁行格式：file,date,open,high,low,close,vol,amo）。"""
    for r in cand:
        rows[period].append((file_str, r[0], r[1], r[2], r[3], r[4], r[5], r[6]))


# ---------------------------------------------------------------------------
# 正确性硬门槛：独立全量重算交叉验证（**不复用出包逻辑**）
# ---------------------------------------------------------------------------

def indep_parse(text):
    """独立解析（与出包路径实现分开写，仅**口径**一致）：整文件所有数据行。"""
    out = []
    for line in text.splitlines():
        parts = line.split(";")
        if len(parts) < 7:
            continue
        parts[-1] = parts[-1].strip()
        try:
            d = int(parts[0])
            if d <= 19000101:
                continue
            out.append((d, float(parts[1]), float(parts[2]), float(parts[3]),
                        float(parts[4]), float(parts[5]) if parts[5] else 0.0,
                        float(parts[6]) if parts[6] else 0.0))
        except (ValueError, IndexError):
            continue
    return out


def indep_group(daily, period):
    """独立聚合（dict 分组，与出包路径的流式聚合实现不同、口径相同）。"""
    key_fn = {"weekly": monday_key, "monthly": month_key,
              "quarterly": quarter_key, "yearly": year_key}[period]
    groups, order = {}, []
    for r in daily:
        k = key_fn(r[0])
        if k not in groups:
            groups[k] = list(r)
            order.append(k)
        else:
            c = groups[k]
            c[2] = max(c[2], r[2])
            c[3] = min(c[3], r[3])
            c[4] = r[4]
            c[5] += r[5]
            c[6] += r[6]
    return [tuple(groups[k]) for k in order]


def _same6(a, b, tol):
    return all(abs((a[i] or 0.0) - (b[i] or 0.0)) <= tol for i in range(6))


def run_selfcheck(base, idmap, rows, old_dir, new_dir, kind_map, n, tol, seed):
    """随机抽 n 个文件（约一半 append + 一半 rewrite）做全量重算交叉验证。

    断言：补丁里该 file 的每个周期的行集合**恰好等于**「真差异集合」（不多不少）。
    返回 (per_file_match, per_file_mismatch, per_period_checks, per_period_bad)。
    """
    rnd = random.Random(seed)
    apps = sorted(f for f, k in kind_map.items() if k == "append")
    rews = sorted(f for f, k in kind_map.items() if k == "rewrite")
    half = n // 2
    pick = (rnd.sample(apps, min(len(apps), half))
            + rnd.sample(rews, min(len(rews), n - half)))
    pick_set = set(pick)
    print("交叉验证：随机抽 %d 个文件（append %d + rewrite %d），seed=%d，容差 %g"
          % (len(pick), sum(1 for f in pick if f in set(apps)),
             sum(1 for f in pick if f in set(rews)), seed, tol))

    # 补丁索引：{period: {file: {date: (open..amo)}}}
    pk = {p: {} for p in PATCH_PERIODS}
    for period in PATCH_PERIODS:
        for row in rows[period]:
            if row[0] in pick_set:
                pk[period].setdefault(row[0], {})[row[1]] = row[2:]

    ok_files = bad_files = 0
    checks = bad = 0
    details = []
    for f in pick:
        path = os.path.join(new_dir, f + TXT_EXT)
        with open(path, "rb") as fh:
            text = fh.read().decode("gbk", "replace")      # 完整解析整个新 txt（不走尾部捷径）
        cands = {"daily": indep_parse(text)}
        for p in MERGE_PERIODS:
            cands[p] = indep_group(cands["daily"], p)
        mid = idmap.get(f)
        file_bad = []
        for period in PATCH_PERIODS:
            checks += 1
            have = {}
            if mid is not None:
                for r in base.execute(
                        "SELECT date,open,high,low,close,vol,amo FROM %s WHERE meta_id=?" % period,
                        (mid,)):
                    have[int(r[0])] = (r[1], r[2], r[3], r[4], r[5], r[6])
            true_diff = {r[0]: r[1:] for r in cands[period]
                         if (r[0] not in have) or (not _same6(r[1:], have[r[0]], tol))}
            got = pk[period].get(f, {})
            extra = sorted(set(got) - set(true_diff))          # 补丁多发的（含「与基线值相同」）
            missing = sorted(set(true_diff) - set(got))        # 补丁漏发的
            wrong = sorted(d for d in (set(got) & set(true_diff))
                           if not _same6(got[d], true_diff[d], tol))
            if extra or missing or wrong:
                bad += 1
                file_bad.append("%s 多%d 漏%d 值错%d" % (period, len(extra), len(missing), len(wrong)))
                for tag, ds in (("多", extra), ("漏", missing), ("值错", wrong)):
                    for d in ds[:5]:
                        details.append("  [%s] %s %s %s  补丁=%s 真差异=%s"
                                       % (tag, f, period, d,
                                          got.get(d), true_diff.get(d)))
        if file_bad:
            bad_files += 1
            print("  ❌ %s：%s" % (f, "；".join(file_bad)))
        else:
            ok_files += 1
    print("交叉验证结果：文件级 匹配 %d / 不一致 %d（共 %d）  ·  周期级 匹配 %d / 不一致 %d"
          % (ok_files, bad_files, len(pick), checks - bad, bad))
    if details:
        print("不一致明细（最多 40 条）：")
        for line in details[:40]:
            print(line)
    return ok_files, bad_files, checks, bad


# ---------------------------------------------------------------------------
# 报告 / 序号 / 主流程
# ---------------------------------------------------------------------------

def next_seq(out_dir):
    """扫描输出目录里已有的 patch_<seq>.db，返回下一个可用序号（同 diff_live_patch.py）。"""
    seqs = []
    if os.path.isdir(out_dir):
        for name in os.listdir(out_dir):
            if name.startswith(PATCH_PREFIX) and name.endswith(".db"):
                body = name[len(PATCH_PREFIX):-len(".db")]
                if body.isdigit():
                    seqs.append(int(body))
    return max(seqs) + 1 if seqs else 1


def write_patch_report(path, header_lines, columns, per_file):
    """落一份可复查的「受影响 file 清单」（UTF-8，TAB 分隔，风格同 diff_live_patch.py）。"""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        for line in header_lines:
            fh.write("# %s\n" % line)
        fh.write("# 列: seq\tfile\t%s\n" % "\t".join(columns))
        for i, f in enumerate(sorted(per_file), 1):
            rec = per_file[f]
            fh.write("%d\t%s\t%s\n" % (i, f, "\t".join(str(int(rec.get(c, 0))) for c in columns)))
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def db_state(path):
    """基线库状态快照（只比 size + mtime_ns，**不算 sha256**）。"""
    st = os.stat(path)
    return (st.st_size, st.st_mtime_ns)


# ---------------------------------------------------------------------------
# 核心处理（单包与分片共用同一份实现，避免两套口径漂移）
# ---------------------------------------------------------------------------

def process_files(base, names, old_dir, new_dir, tol):
    """给定一批 txt 文件名，完成「分类+解析 → 合并/聚合 → 比对 → 汇总」。

    `base` 是**调用方持有的只读连接**（单包 = 主连接；分片 = worker 自己的连接）。
    返回不含 sqlite 连接的 dict：rows / per_file / kind_map / idmap / 计数 / A·B 耗时
    / dmax·LO·当期 bar 数量（供调用方打印）。

    ⚠ 本函数是单包与分片的**唯一**实现：`--shards 1` 与每片的行数口径因此天然一致。
    """
    idmap = {f: i for i, f in base.execute("SELECT id, file FROM meta")}
    meta_src = {r[0]: r for r in base.execute("SELECT file, code, name, type FROM meta")}

    # 开局**一次性**：由基线最大交易日 dmax 推出「当期」周/月/季/年四个周期（可能不完整的
    # 候选集）。每个标的的增量合并直接复用这组 lo，**不在标的循环里重复判断当期**（Task 1.2）。
    # dmax 取 `meta.last_date`（每只标的的最大日线日期，tdx_parser 写入）的 MAX：
    # 与 `SELECT MAX(date) FROM daily` **口径等价**（实测 3611/3611 完全一致），但只扫 3611 行，
    # 比全表扫 daily（14M 行，冷缓存 >2s）快三个数量级（性能红线 3）。
    dmax = base.execute("SELECT MAX(last_date) FROM meta").fetchone()[0]
    LO = {p: period_start(int(dmax), p) for p in MERGE_PERIODS}
    # 开局**一次性**把四张周期表的「当期 bar」整表捞出（4 条批量查询取代逐标的的 14k 次探查）
    CUR_BAR = {p: load_current_bars(base, p, LO[p]) for p in MERGE_PERIODS}

    rows = {"meta": [], "daily": [], "weekly": [], "monthly": [],
            "quarterly": [], "yearly": []}
    per_file = {}
    kind_map = {}
    n_app = n_rew = n_new = 0
    skipped_no_meta = []
    t_a = t_b = 0.0
    t0_all = time.time()

    for nm in names:
        f = os.path.splitext(nm)[0]
        mid = idmap.get(f)
        t0 = time.time()
        # 基线主库里没有这个 file → **直接跳过，不进包**。
        # 理由：设备侧 apply-patch 是 `INSERT OR REPLACE ... SELECT ... JOIN main.meta ON m.file=b.file`，
        # 主库 meta 里没有的 file 会被 JOIN 丢弃 —— 打进去纯属浪费（实测 30 个 file 的整段历史 ≈ 4.5MB）。
        # 实测这 30 个 = 26 个「旧 txt 有但 tdx_parser 从未导入」（42#/46#/12# 前缀、62#H11014/62#931265
        # 等被条件过滤）+ 4 个新上市；它们**无法**通过补丁进入主库（要进得先插 meta 行，超出本流程范围）。
        if mid is None:
            skipped_no_meta.append(f)
            continue
        kind, new_daily, header = classify_and_read(
            os.path.join(old_dir, nm), os.path.join(new_dir, nm))
        kind_map[f] = kind
        n_app += kind == "append"
        n_rew += kind == "rewrite"
        n_new += kind == "new"

        if kind == "append":
            # 只解析尾部新增行（全部日线直接进包）；周/月/季/年**只对被新数据触及的周期**与
            # 基线**当期 bar**（开局批量预取）**合并**（不整周期重算、不再逐标的查基线）。
            dailies = new_daily
            if new_daily:
                wk = merge_period_rows(new_daily, "weekly", LO["weekly"], CUR_BAR["weekly"].get(mid))
                mo = merge_period_rows(new_daily, "monthly", LO["monthly"], CUR_BAR["monthly"].get(mid))
                qt = merge_period_rows(new_daily, "quarterly", LO["quarterly"], CUR_BAR["quarterly"].get(mid))
                yr = merge_period_rows(new_daily, "yearly", LO["yearly"], CUR_BAR["yearly"].get(mid))
            else:
                # 停牌标的（新数据为空）→ 不产生任何 bar（Task 1.5）
                wk, mo, qt, yr = [], [], [], []
        else:
            # rewrite（整文件解析）→ 整只标的所有周期**全量重算** → 与基线全部行比对
            per = agg_all_periods(new_daily)
            wk, mo = per["weekly"], per["monthly"]
            qt, yr = per["quarterly"], per["yearly"]
            dailies = None
        t_a += time.time() - t0

        t0 = time.time()
        if dailies is not None:
            # append / 基线缺失：日线全部直接进包（append 不做行级比对）
            ddiff = dailies
            if kind == "append":
                # 周/月/季/年：当期与预取的基线当期 bar 比，其余（新周期）直接发（无逐标查询）
                wdiff = diff_period_append(wk, "weekly", LO["weekly"], CUR_BAR["weekly"].get(mid), tol)
                mdiff = diff_period_append(mo, "monthly", LO["monthly"], CUR_BAR["monthly"].get(mid), tol)
                qdiff = diff_period_append(qt, "quarterly", LO["quarterly"], CUR_BAR["quarterly"].get(mid), tol)
                ydiff = diff_period_append(yr, "yearly", LO["yearly"], CUR_BAR["yearly"].get(mid), tol)
            else:
                wdiff, mdiff, qdiff, ydiff = wk, mo, qt, yr
        else:
            # rewrite：与基线**全部**行比对，只发真正不同/新增的
            ddiff = diff_rows(new_daily, _have_all(base, mid, "daily"), tol)
            wdiff = diff_rows(wk, _have_all(base, mid, "weekly"), tol)
            mdiff = diff_rows(mo, _have_all(base, mid, "monthly"), tol)
            qdiff = diff_rows(qt, _have_all(base, mid, "quarterly"), tol)
            ydiff = diff_rows(yr, _have_all(base, mid, "yearly"), tol)
        _emit(rows, f, "daily", ddiff)
        _emit(rows, f, "weekly", wdiff)
        _emit(rows, f, "monthly", mdiff)
        _emit(rows, f, "quarterly", qdiff)
        _emit(rows, f, "yearly", ydiff)

        rec = {"daily": len(ddiff), "weekly": len(wdiff), "monthly": len(mdiff),
               "quarterly": len(qdiff), "yearly": len(ydiff)}
        if any(rec.get(p) for p in PATCH_PERIODS):
            per_file[f] = rec
            m = meta_src.get(f)
            if m:
                rows["meta"].append((f, m[1], m[2], m[3]))
            elif header:                       # 基线没有的 file（新上市）：从 txt 表头解析
                code, name = parse_header(header)
                rows["meta"].append((f, code or f.split("#")[-1], name or "", guess_type(f)))
            else:
                rows["meta"].append((f, f.split("#")[-1], "", guess_type(f)))
        t_b += time.time() - t0

    return {"rows": rows, "per_file": per_file, "kind_map": kind_map, "idmap": idmap,
            "n_app": n_app, "n_rew": n_rew, "n_new": n_new,
            "skipped_no_meta": skipped_no_meta, "t_a": t_a, "t_b": t_b,
            "t_loop": time.time() - t0_all,
            "dmax": dmax, "lo": LO,
            "cur_counts": {p: len(CUR_BAR[p]) for p in MERGE_PERIODS}}


def report_ordered(per_file, size, total_rows):
    """受影响 file 清单的累计列（cum_rows / cum_bytes_est）。单包与每片各自调用。"""
    avg_row = size / float(total_rows) if total_rows else 0.0
    recs = {}
    for f in per_file:
        rec = dict(per_file[f])
        rec["rows"] = sum(rec.get(p, 0) for p in PATCH_PERIODS)
        recs[f] = rec
    cum, ordered = 0, {}
    for f in sorted(recs):
        rec = recs[f]
        cum += rec["rows"]
        rec["cum_rows"] = cum
        rec["cum_bytes_est"] = int(cum * avg_row)
        ordered[f] = rec
    return ordered, avg_row


def report_header(old_dir, new_dir, base_db, tol, rows, total_rows,
                  out_path, size, sha, updated_at, max_date, shard=None):
    """清单 txt 的头部（单包与每片共用，保证格式一致）。shard=(i,N) 时标注分片。"""
    head = [
        "Kline txt 直出差分补丁包 · 受影响 file 清单",
        "生成时间: %s" % datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "旧 txt : %s" % old_dir,
        "新 txt : %s" % new_dir,
        "基线库 : %s（只读，跑完 size+mtime 未变）" % base_db,
    ]
    if shard is not None:
        head.append("分片   : 第 %d/%d 片（file 稳定分组 index %% N）" % (shard[0], shard[1]))
    head += [
        "容差   : abs(a-b) > %g（字段 %s 任一变化即计入）" % (tol, "/".join(FIELDS)),
        "包内最新日期: %s   updated_at(UTC epoch)=%d" % (max_date, updated_at),
        "包文件 : %s   bytes=%d   sha256=%s" % (out_path, size, sha),
        "包内行数: %s 合计=%d"
        % (" ".join("%s=%d" % (p, len(rows[p])) for p in PATCH_PERIODS), total_rows),
        "平均每行约 %.1f B；cum_bytes_est = 累计行数 × 平均行字节（SQLite 单文件无法按 file 精确归因）"
        % (size / float(total_rows) if total_rows else 0.0),
    ]
    return head


# ---------------------------------------------------------------------------
# 分片：稳定分组 / 全局 updated_at / multiprocessing worker
# ---------------------------------------------------------------------------

def last_date_in_txt(path):
    """新 txt 里最后一根日线的日期（文件按日期升序 → 末条数据行即该 file 的最大日期）。

    只读文件尾部 4KB 并反向找第一条数据行 —— 用于**开局一次性**算出全局最大日期，
    避免为了 `updated_at` 把 3611 个文件再完整解析一遍（实测 1.3s）。
    """
    try:
        sz = os.path.getsize(path)
    except OSError:
        return None
    if sz <= 0:
        return None
    with open(path, "rb") as fh:
        fh.seek(max(0, sz - 4096))
        buf = fh.read().decode("gbk", "replace")
    for line in reversed(buf.splitlines()):
        if ";" not in line:
            continue
        parts = line.split(";")
        if len(parts) < 7:
            continue
        try:
            d = int(parts[0])
        except ValueError:
            continue
        if d > 19000101:
            return d
    return None


def global_max_date(new_dir, names):
    """全局最大交易日：`updated_at` 的口径（取全局最大 date）。

    必须在**全量待处理标的**上算（不是按片算），否则各片 `bkt_meta.updated_at` 会不一致、
    `--only-shard i` 单独调用也会与整跑不一致。
    """
    mx = 0
    for nm in names:
        d = last_date_in_txt(os.path.join(new_dir, nm))
        if d and d > mx:
            mx = d
    return mx


def shard_pending(pending, n_shards):
    """把待处理标的按 **file 稳定分组**：排序后「index % N」 → 两两不交、并集 = 全集。

    只依赖「全局排序列表 + i + N」，所以 `--only-shard i` 单独跑得到的片与整跑的第 i 片**逐字相同**。
    """
    s = sorted(pending)
    return [s[i::n_shards] for i in range(n_shards)]


def _shard_worker(payload):
    """multiprocessing worker：**独立**完成自己那一份的 A+B+C（自己开只读连接、自己出包）。

    只回传**轻量摘要**（行数 / meta file 列表 / 路径 / 字节 / sha256 / 各段耗时 / 自检结论），
    **不回传 rows** —— 20 万级元组过 IPC 会把并行的收益吃掉。
    """
    (idx, files, old_dir, new_dir, base_db, tol, out_dir, seq, n_shards,
     updated_at, max_date, dry_run, sc_n, sc_seed) = payload
    res = {"index": idx, "n_files": len(files), "path": None, "bytes": 0, "sha256": None,
           "n_rows": {p: 0 for p in PATCH_PERIODS}, "total": 0,
           "a": 0.0, "b": 0.0, "c": 0.0, "wall": 0.0,
           "meta_files": [], "skipped": [], "n_app": 0, "n_rew": 0, "n_new": 0,
           "dmax": None, "lo": None, "cur_counts": {}, "selfcheck": None}
    t_wall = time.time()
    base = sqlite3.connect(L.ro_uri(base_db), uri=True)     # 每个 worker 自己的只读连接
    base.execute("PRAGMA query_only=1")
    try:
        r = process_files(base, files, old_dir, new_dir, tol)
        rows, per_file = r["rows"], r["per_file"]
        n_rows = {p: len(rows[p]) for p in PATCH_PERIODS}
        res.update({"n_rows": n_rows, "total": sum(n_rows.values()),
                    "a": r["t_a"], "b": r["t_b"], "n_files": len(per_file),
                    "meta_files": [m[0] for m in rows["meta"]],
                    "skipped": r["skipped_no_meta"], "n_app": r["n_app"],
                    "n_rew": r["n_rew"], "n_new": r["n_new"], "dmax": r["dmax"],
                    "lo": r["lo"], "cur_counts": r["cur_counts"]})
        if res["total"] == 0:
            res["wall"] = time.time() - t_wall
            return res

        if not dry_run:
            os.makedirs(out_dir, exist_ok=True)
            out_path = os.path.join(out_dir, "%s%d_s%d.db" % (PATCH_PREFIX, seq, idx))
            tmp_path = out_path + ".tmp"
            t0 = time.time()
            # 表结构 / 字段顺序逐字沿用 live_db_builder.build_bucket_file（五张表）
            L.build_bucket_file(tmp_path, rows, updated_at, periods=PATCH_PERIODS)
            chk = sqlite3.connect(L.ro_uri(tmp_path), uri=True)
            try:
                got = chk.execute("SELECT COUNT(*) FROM bkt_meta").fetchone()[0]
                assert got == len(rows["meta"]), \
                    "bkt_meta 行数不一致: %d/%d" % (got, len(rows["meta"]))
                for period in PATCH_PERIODS:
                    cnt = chk.execute("SELECT COUNT(*) FROM bkt_%s" % period).fetchone()[0]
                    assert cnt == n_rows[period], \
                        "bkt_%s 行数不一致: %d/%d" % (period, cnt, n_rows[period])
            finally:
                chk.close()
            os.replace(tmp_path, out_path)              # 原子替换：编排器按 size 稳定发现
            res["c"] = time.time() - t0
            res["path"] = out_path
            res["bytes"] = os.path.getsize(out_path)
            res["sha256"] = L.sha256_file(out_path)

            ordered, _avg = report_ordered(per_file, res["bytes"], res["total"])
            report_path = os.path.join(out_dir, "%s%d_s%d_files.txt" % (PATCH_PREFIX, seq, idx))
            write_patch_report(
                report_path,
                report_header(old_dir, new_dir, base_db, tol, rows, res["total"],
                              out_path, res["bytes"], res["sha256"], updated_at,
                              max_date, shard=(idx, n_shards)),
                list(PATCH_PERIODS) + ["rows", "cum_rows", "cum_bytes_est"], ordered)
            res["report"] = report_path

        # 自检：每片各自抽样（总抽样数按片分配），结论并入整跑
        if sc_n > 0:
            res["selfcheck"] = run_selfcheck(base, r["idmap"], rows, old_dir, new_dir,
                                             r["kind_map"], sc_n, tol, sc_seed)
        res["wall"] = time.time() - t_wall
        return res
    finally:
        base.close()


def run_sharded(args, out_dir, before_base, t_all):
    """`--shards N > 1`：N 片由 W 个 worker **并行**独立出包（每个 worker 全流程自包含）。"""
    n_shards = args.shards
    workers = min(max(1, args.workers), n_shards)
    names = sorted(n for n in os.listdir(args.new_txt_dir) if n.endswith(TXT_EXT))

    # 待处理标的 = 新目录里有、且**基线 meta 里有**（否则设备侧 JOIN 会丢弃、进不了包）
    pbase = sqlite3.connect(L.ro_uri(args.base_db), uri=True)
    pbase.execute("PRAGMA query_only=1")
    idmap = {f for _, f in pbase.execute("SELECT id, file FROM meta")}
    pbase.close()
    pending = sorted(os.path.splitext(n)[0] for n in names if os.path.splitext(n)[0] in idmap)
    groups = shard_pending(pending, n_shards)
    print("待处理标的: %d（新目录 txt %d 个，基线无 meta 跳过 %d）→ 分 %d 片"
          % (len(pending), len(names), len(names) - len(pending), n_shards))
    print("分片策略: file 排序后 index %% %d（两两不交、并集 = 全集）；"
          "worker 数 = min(%d, %d) = %d；仅出第 %s 片"
          % (n_shards, args.workers, n_shards, workers,
             args.only_shard if args.only_shard is not None else "全部"))

    # updated_at 取**全局**最大 date（在全量待处理标的上算）→ 各片一致、--only-shard 单独跑也一致
    max_date = global_max_date(args.new_txt_dir, [f + TXT_EXT for f in pending])
    if max_date == 0:
        raise SystemExit("新目录取不到任何有效日期，放弃生成")
    updated_at = L.date_int_to_epoch_utc(max_date)
    print("全局最大日期: %s   updated_at(UTC epoch)=%d" % (max_date, updated_at))

    seq = args.seq if args.seq is not None else next_seq(out_dir)
    idxs = [args.only_shard] if args.only_shard is not None else list(range(n_shards))
    n_sc = args.self_check
    sc_by_shard = {i: (n_sc // n_shards + (1 if i < n_sc % n_shards else 0))
                   for i in range(n_shards)}

    payloads = [(i, [f + TXT_EXT for f in groups[i]], args.old_txt_dir, args.new_txt_dir,
                 args.base_db, args.tol, out_dir, seq, n_shards, updated_at, max_date,
                 args.dry_run, sc_by_shard[i], args.self_check_seed) for i in idxs]

    print("-" * 78)
    t0 = time.time()
    if workers == 1 or len(payloads) == 1:
        results = [_shard_worker(p) for p in payloads]        # 单进程：便于对照耗时
    else:
        with multiprocessing.Pool(processes=workers) as pool:
            results = pool.map(_shard_worker, payloads)
    t_build = time.time() - t0
    results.sort(key=lambda r: r["index"])

    # ---- 逐片汇总 ----
    print("-" * 78)
    print("%-6s %-8s %s %s" % ("片", "file数", " ".join("%-10s" % p for p in PATCH_PERIODS),
                               "合计 / 体积 / 耗时(A+B+C)"))
    sum_rows = {p: 0 for p in PATCH_PERIODS}
    for r in results:
        sum_rows = {p: sum_rows[p] + r["n_rows"][p] for p in PATCH_PERIODS}
        print("%-6d %-8d %s %-8d %8.1f MB  A %.1f + B %.1f + C %.1f"
              % (r["index"], r["n_files"],
                 " ".join("%-10d" % r["n_rows"][p] for p in PATCH_PERIODS),
                 r["total"], r["bytes"] / 1048576.0, r["a"], r["b"], r["c"]))
    print("各片行数之和: %s 合计=%d"
          % (" ".join("%s=%d" % (p, sum_rows[p]) for p in PATCH_PERIODS),
             sum(sum_rows.values())))
    print("出包总耗时 %.1fs（%d 片，%d 个 worker，墙钟；各片 A+B+C 之和 %.1fs）"
          % (t_build, len(results), workers, sum(r["a"] + r["b"] + r["c"] for r in results)))

    # ---- 并集 / 交集自检（bkt_meta.file）----
    # 每片先做最强的一句断言：**产出集 == 分配集**（`groups[i]`）。因为 groups 本身是对 pending
    # 的划分（两两不交、并集 = 全集），这一句在整跑与 `--only-shard` 两种模式下都成立且充分。
    produced = {r["index"]: set(r["meta_files"]) for r in results}
    bad_shards = sorted(i for i in produced if produced[i] != set(groups[i]))
    sets = list(produced.values())
    pair_inter = sum(len(sets[a] & sets[b])
                     for a in range(len(sets)) for b in range(a + 1, len(sets)))
    full_run = args.only_shard is None
    union = set().union(*sets) if sets else set()
    ok_union = (len(union) == len(pending)) if full_run else True
    ok_inter = (pair_inter == 0) if len(sets) > 1 else True
    ok_sum = all(sum_rows[p] == sum(r["n_rows"][p] for r in results) for p in PATCH_PERIODS)
    print("-" * 78)
    print("自检: 每片「产出集 = 分配集」 %s（%s）   ·   各片行数之和与逐片一致 %s"
          % ("✅" if not bad_shards else "❌ 片 %s" % bad_shards,
             "分配按 file 排序 index%N 划分 → 两两不交、并集 = 全集" if full_run
             else "分配集来自全量划分，故与整跑的第 %d 片逐字相同" % args.only_shard,
             "✅" if ok_sum else "❌"))
    if full_run:
        print("      并集 %d / 待处理 %d %s   ·   两两交集 %d %s"
              % (len(union), len(pending), "✅" if ok_union else "❌",
                 pair_inter, "✅" if ok_inter else "❌"))
    if bad_shards or not (ok_union and ok_inter and ok_sum):
        print("❌ 分片自检失败：不重不漏被破坏！")

    sk = sorted({f for r in results for f in r["skipped"]})
    if sk:
        print("跳过 %d 个「主库无此标的」的 txt（不进包）: %s"
              % (len(sk), ", ".join(sk[:12]) + (" …" if len(sk) > 12 else "")))
    if args.dry_run:
        print("--dry-run：不落盘（本应写入 %s%d_s0..%d.db）"
              % (os.path.join(out_dir, PATCH_PREFIX), seq, n_shards - 1))

    # ---- 自检结论（各片独立抽样，汇总）----
    sc = [r["selfcheck"] for r in results if r.get("selfcheck")]
    if sc:
        okf = sum(x[0] for x in sc)
        badf = sum(x[1] for x in sc)
        ck = sum(x[2] for x in sc)
        bc = sum(x[3] for x in sc)
        print("分片交叉验证汇总：文件级 匹配 %d / 不一致 %d  ·  周期级 匹配 %d / 不一致 %d"
              % (okf, badf, ck - bc, bc))

    after_base = db_state(args.base_db)
    print("-" * 78)
    print("基线库完整性（mode=size+mtime）: before=%s after=%s  %s"
          % (before_base, after_base, "✅ 未被修改" if after_base == before_base else "❌ 被修改了！"))
    print("总耗时 %.1fs" % (time.time() - t_all))
    return 0 if (not bad_shards and ok_union and ok_inter and ok_sum) else 1


def run_single(args, out_dir, before_base, t_all):
    """`--shards 1`（默认）：单进程单包 —— 行为与耗时与既有实现**等价**（走同一条路径）。"""
    base = sqlite3.connect(L.ro_uri(args.base_db), uri=True)   # 只读打开
    base.execute("PRAGMA query_only=1")                        # 双保险：本连接任何写操作都被拒绝
    try:
        names = sorted(n for n in os.listdir(args.new_txt_dir) if n.endswith(TXT_EXT))
        print("新目录 txt 文件数: %d；基线 meta: %d 只"
              % (len(names), base.execute("SELECT COUNT(*) FROM meta").fetchone()[0]))

        r = process_files(base, names, args.old_txt_dir, args.new_txt_dir, args.tol)
        rows, per_file, kind_map = r["rows"], r["per_file"], r["kind_map"]
        print("基线最大交易日 dmax=%s → 当期日历起始: weekly=%s monthly=%s quarterly=%s yearly=%s"
              % (r["dmax"], r["lo"]["weekly"], r["lo"]["monthly"],
                 r["lo"]["quarterly"], r["lo"]["yearly"]))
        print("当期 bar 批量预取: %s（各 1 条范围查询）"
              % " ".join("%s=%d" % (p, r["cur_counts"][p]) for p in MERGE_PERIODS))

        total_rows = sum(len(rows[p]) for p in PATCH_PERIODS)
        t_a, t_b = r["t_a"], r["t_b"]
        print("-" * 78)
        print("分类: append=%d rewrite=%d new=%d（合计 %d）"
              % (r["n_app"], r["n_rew"], r["n_new"], len(names)))
        if r["skipped_no_meta"]:
            print("跳过 %d 个「主库无此标的」的 txt（不进包，设备侧会被 JOIN 丢弃）: %s"
                  % (len(r["skipped_no_meta"]),
                     ", ".join(sorted(r["skipped_no_meta"])[:12])
                     + (" …" if len(r["skipped_no_meta"]) > 12 else "")))
        print("阶段 A（分类+解析，融合，2 次句柄/文件）  %.1fs" % t_a)
        print("阶段 B（比对/聚合/汇总）               %.1fs" % t_b)
        print("受影响 file 数: %d（bkt_meta）" % len(rows["meta"]))
        print("补丁行数: %s 合计=%d"
              % (" ".join("%s=%d" % (p, len(rows[p])) for p in PATCH_PERIODS), total_rows))
        print("（逐文件主循环总耗时 %.1fs）" % r["t_loop"])

        if total_rows == 0:
            print("无差异：不产出空补丁包。")
            base.close()
            print("基线库完整性: %s  %s" % (db_state(args.base_db),
                  "✅ 未被修改" if db_state(args.base_db) == before_base else "❌ 被修改!"))
            return 0

        max_date = max(x[1] for p in PATCH_PERIODS for x in rows[p])
        updated_at = L.date_int_to_epoch_utc(max_date)
        print("包内最新日期: %s   updated_at(UTC epoch)=%d" % (max_date, updated_at))

        seq = args.seq if args.seq is not None else next_seq(out_dir)
        out_path = os.path.join(out_dir, "%s%d.db" % (PATCH_PREFIX, seq))
        report_path = os.path.join(out_dir, "%s%d_files.txt" % (PATCH_PREFIX, seq))
        size = sha = None
        t_c = 0.0

        if args.dry_run:
            print("--dry-run：不落盘（本应写入 %s）" % out_path)
        else:
            os.makedirs(out_dir, exist_ok=True)
            tmp_path = out_path + ".tmp"
            t0 = time.time()
            # 表结构 / 字段顺序逐字沿用 live_db_builder.build_bucket_file；补丁携带**五张表**
            L.build_bucket_file(tmp_path, rows, updated_at, periods=PATCH_PERIODS)
            # 写后轻量自检：各表行数与内存 rows 一致、bkt_meta 无重复
            chk = sqlite3.connect(L.ro_uri(tmp_path), uri=True)
            try:
                got = chk.execute("SELECT COUNT(*) FROM bkt_meta").fetchone()[0]
                assert got == len(rows["meta"]), \
                    "bkt_meta 行数不一致: %d/%d" % (got, len(rows["meta"]))
                for period in PATCH_PERIODS:
                    cnt = chk.execute("SELECT COUNT(*) FROM bkt_%s" % period).fetchone()[0]
                    assert cnt == len(rows[period]), \
                        "bkt_%s 行数不一致: %d/%d" % (period, cnt, len(rows[period]))
            finally:
                chk.close()
            os.replace(tmp_path, out_path)
            size = os.path.getsize(out_path)
            sha = L.sha256_file(out_path)
            t_c = time.time() - t0
            print("阶段 C（出包）                        %.1fs  →  %d B (%.1f MB)  sha256=%s…"
                  % (t_c, size, size / 1048576.0, sha[:16]))
            print("补丁包: %s" % out_path)

            # 受影响 file 清单（file / 序号 / 各周期行数 / 累计 rows 与累计 bytes 估计）
            ordered, avg_row = report_ordered(per_file, size, total_rows)
            header = report_header(args.old_txt_dir, args.new_txt_dir, args.base_db, args.tol,
                                   rows, total_rows, out_path, size, sha, updated_at, max_date)
            header.insert(5, "分类   : append=%d rewrite=%d new=%d" % (r["n_app"], r["n_rew"], r["n_new"]))
            write_patch_report(report_path, header,
                               list(PATCH_PERIODS) + ["rows", "cum_rows", "cum_bytes_est"], ordered)
            print("受影响 file 清单: %s（%d 个 file）" % (report_path, len(ordered)))
        if not args.dry_run:
            print("PC 侧 A+B+C = %.1fs（A %.1fs + B %.1fs + C %.1fs）"
                  % (t_a + t_b + t_c, t_a, t_b, t_c))

        # ---- 正确性硬门槛：独立全量重算交叉验证 ----
        if args.self_check > 0:
            run_selfcheck(base, r["idmap"], rows, args.old_txt_dir, args.new_txt_dir,
                          kind_map, args.self_check, args.tol, args.self_check_seed)
    finally:
        base.close()
    after_base = db_state(args.base_db)
    print("-" * 78)
    print("基线库完整性（mode=size+mtime）: before=%s after=%s  %s"
          % (before_base, after_base, "✅ 未被修改" if after_base == before_base else "❌ 被修改了！"))
    print("总耗时 %.1fs" % (time.time() - t_all))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Kline「txt 直出差分」出包器：新 txt 目录 + 基线库 → patch_<seq>.db（不重建库，基线只读）")
    ap.add_argument("--old-txt-dir", dest="old_txt_dir", required=True,
                    help="旧 txt 目录（分类与 append 定位的参照）")
    ap.add_argument("--new-txt-dir", dest="new_txt_dir", required=True, help="新 txt 目录（差异来源）")
    ap.add_argument("--base-db", dest="base_db", default=DEFAULT_BASE_DB,
                    help="基线库（**只读打开**，默认 %s）" % DEFAULT_BASE_DB)
    ap.add_argument("--out", default=DEFAULT_OUT,
                    help="输出目录（默认 %s，放 patch_<seq>.db 与清单 txt）" % DEFAULT_OUT)
    ap.add_argument("--seq", type=int, default=None,
                    help="补丁序号，命名 patch_<seq>.db（默认取输出目录里已有序号 +1）")
    ap.add_argument("--dry-run", dest="dry_run", action="store_true",
                    help="只统计不落盘（不产出 patch_<seq>.db，也不写清单 txt）")
    ap.add_argument("--tol", type=float, default=FLOAT_TOL,
                    help="浮点容差，判定 abs(a-b)>tol 为变化（默认 %g）" % FLOAT_TOL)
    ap.add_argument("--self-check", dest="self_check", type=int, default=0, metavar="N",
                    help="出包后用**独立全量重算**交叉验证 N 个文件（0=关闭；建议 200）")
    ap.add_argument("--self-check-seed", dest="self_check_seed", type=int, default=20260923,
                    help="交叉验证抽样种子（默认 20260923，便于复现）")
    ap.add_argument("--shards", type=int, default=1, metavar="N",
                    help="把待处理标的按 file 稳定分组切成 N 片，各出 patch_<seq>_s<i>.db"
                         "（默认 1 = 单包，行为与耗时与既有实现等价）")
    ap.add_argument("--workers", type=int, default=1, metavar="W",
                    help="分片出包的并行进程数（默认 1；仅 --shards > 1 时有意义，"
                         "上限 min(W, N)，用 multiprocessing 绕过 GIL）")
    ap.add_argument("--only-shard", dest="only_shard", type=int, default=None, metavar="i",
                    help="只出第 i 片（0-based），单进程。分组与 updated_at 仍按**全量**算，"
                         "故单独调用与整跑的第 i 片逐字相同（编排器逐片调用用）")
    args = ap.parse_args(argv)

    t_all = time.time()
    if not os.path.isdir(args.old_txt_dir):
        raise SystemExit("旧 txt 目录不存在: %s" % args.old_txt_dir)
    if not os.path.isdir(args.new_txt_dir):
        raise SystemExit("新 txt 目录不存在: %s" % args.new_txt_dir)
    if not os.path.exists(args.base_db):
        raise SystemExit("基线库不存在: %s" % args.base_db)
    if args.shards < 1:
        raise SystemExit("--shards 必须 ≥ 1，当前 %d" % args.shards)
    if args.workers < 1:
        raise SystemExit("--workers 必须 ≥ 1，当前 %d" % args.workers)
    if args.only_shard is not None and not (0 <= args.only_shard < args.shards):
        raise SystemExit("--only-shard 必须在 0..%d，当前 %d" % (args.shards - 1, args.only_shard))

    out_dir = os.path.abspath(args.out)
    print("旧 txt : %s" % args.old_txt_dir)
    print("新 txt : %s" % args.new_txt_dir)
    print("基线库 : %s（只读）" % args.base_db)
    print("输出   : %s%s" % (out_dir, "（--dry-run：不落盘）" if args.dry_run else ""))

    before_base = db_state(args.base_db)

    if args.shards == 1 and args.only_shard is None:
        return run_single(args, out_dir, before_base, t_all)
    return run_sharded(args, out_dir, before_base, t_all)


if __name__ == "__main__":
    sys.exit(main())

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
  字节与旧 txt 逐字节一致 ⇒ 其历史行与库内必然相同）。周/月线**必须重算被触及的周期**：
  基线可能在**未完成周期**处截断（实测基线止于 20260828，20260831 仍在 8 月 → 8 月月线要更新）。
· `rewrite`：整文件解析 → 聚合 → 与基线**全部**行比对 → 只发真正不同/新增的。
· `new`（仅新目录有）：整文件解析 → 全部行进包；meta 从 txt 表头解析 code/name。

周/月线聚合口径（**照抄 `tdx_parser.py:508-551 handle_data`，不得另发明**）
--------------------------------------------------------------------------
同一周期内：`open` 取该周期**第一行**、`high = max`、`low = min`、`close` 取**最后一行**、
`vol`/`amo` **累加**；周期 `date` = **该周期第一个交易日**（周线 = 该周首个交易日、月线 = 该月
首个交易日）。与 `live_db_builder.py` 的分片口径一致。

性能红线（Task 0 实测，缺一条就超时）
--------------------------------------
1. 分类与解析**融合**，每文件**只开 2 次句柄**。
2. **周一映射必须缓存**（每行构造 `datetime` 会让 B 段从 10s 涨到 20s）。
3. append 文件的基线周/月**只取最后 8 行**比对（`ORDER BY date DESC LIMIT 8`）——
   若取整段历史，3440 只 × ~1200 行会白取，B 段多花约 50s。

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
TAIL_PERIOD_ROWS = 8               # append 文件只比基线周/月最后 8 行（性能红线 3）
TXT_EXT = ".txt"


# ---------------------------------------------------------------------------
# 周期键 / 聚合（口径照抄 tdx_parser.handle_data，见模块 docstring）
# ---------------------------------------------------------------------------

_MON = {}                          # 周一映射缓存（性能红线 2）


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


def agg_rows(rows, key_fn):
    """流式聚合（照抄 tdx_parser.handle_data 的语义）。

    rows 为**按日期升序**的 `(date, open, high, low, close, vol, amo)`；同一周期内
    open 取第一行、high=max、low=min、close 取最后一行、vol/amo 累加；周期 date 取该周期首个交易日。
    返回同结构的元组列表（周期内首个交易日的 date）。
    """
    out, last = [], None
    for r in rows:
        k = key_fn(r[0])
        if k != last:
            out.append([r[0], r[1], r[2], r[3], r[4], r[5], r[6]])
            last = k
        else:
            c = out[-1]
            c[2] = max(c[2], r[2])       # high
            c[3] = min(c[3], r[3])       # low
            c[4] = r[4]                  # close
            c[5] += r[5]                 # vol
            c[6] += r[6]                 # amo
    return [tuple(x) for x in out]


def period_start(date_int, period):
    """该周期行的「日历起始日」：周=周一，月=当月 1 号。"""
    return monday_key(date_int) if period == "weekly" else month_first(date_int)


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
    groups, order = {}, []
    for r in daily:
        k = monday_key(r[0]) if period == "weekly" else month_key(r[0])
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
    pk = {p: {} for p in L.PERIODS}
    for period in L.PERIODS:
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
        cands["weekly"] = indep_group(cands["daily"], "weekly")
        cands["monthly"] = indep_group(cands["daily"], "monthly")
        mid = idmap.get(f)
        file_bad = []
        for period in L.PERIODS:
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
    args = ap.parse_args(argv)

    t_all = time.time()
    if not os.path.isdir(args.old_txt_dir):
        raise SystemExit("旧 txt 目录不存在: %s" % args.old_txt_dir)
    if not os.path.isdir(args.new_txt_dir):
        raise SystemExit("新 txt 目录不存在: %s" % args.new_txt_dir)
    if not os.path.exists(args.base_db):
        raise SystemExit("基线库不存在: %s" % args.base_db)

    out_dir = os.path.abspath(args.out)
    print("旧 txt : %s" % args.old_txt_dir)
    print("新 txt : %s" % args.new_txt_dir)
    print("基线库 : %s（只读）" % args.base_db)
    print("输出   : %s%s" % (out_dir, "（--dry-run：不落盘）" if args.dry_run else ""))

    before_base = db_state(args.base_db)

    base = sqlite3.connect(L.ro_uri(args.base_db), uri=True)   # 只读打开
    base.execute("PRAGMA query_only=1")                        # 双保险：本连接任何写操作都被拒绝
    idmap = {f: i for i, f in base.execute("SELECT id, file FROM meta")}
    meta_src = {r[0]: r for r in base.execute("SELECT file, code, name, type FROM meta")}

    names = sorted(n for n in os.listdir(args.new_txt_dir) if n.endswith(TXT_EXT))
    print("新目录 txt 文件数: %d；基线 meta: %d 只" % (len(names), len(idmap)))

    rows = {"meta": [], "daily": [], "weekly": [], "monthly": []}
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
            os.path.join(args.old_txt_dir, nm), os.path.join(args.new_txt_dir, nm))
        kind_map[f] = kind
        n_app += kind == "append"
        n_rew += kind == "rewrite"
        n_new += kind == "new"

        if kind == "append":
            # 只解析尾部新增行（全部日线直接进包）；周/月线重算被触及的周期
            dailies = new_daily
            if new_daily:
                d0 = new_daily[0][0]
                lo = min(monday_key(d0), month_first(d0))
                tail = [(int(r[0]), r[1], r[2], r[3], r[4], r[5] or 0.0, r[6] or 0.0)
                        for r in base.execute(
                            "SELECT date,open,high,low,close,vol,amo FROM daily "
                            "WHERE meta_id=? AND date>=? ORDER BY date", (mid, lo))]
                merged = tail + new_daily
                wk = agg_rows(merged, monday_key)
                mo = agg_rows(merged, month_key)
                # 只保留「日历起始 >= lo」的周期行：lo 落在上一月/上一周时会产出**局部**周期行，
                # 那既非真差异、值也是错的（min() 取到上一月时该月只剩几天）。被跳过的周期不受
                # 新增数据影响，其基线行本来就是对的，故不发。
                wk = [r for r in wk if period_start(r[0], "weekly") >= lo]
                mo = [r for r in mo if period_start(r[0], "monthly") >= lo]
            else:
                wk, mo = [], []
        else:
            # rewrite（整文件解析）→ 聚合 → 与基线全部行比对
            wk = agg_rows(new_daily, monday_key)
            mo = agg_rows(new_daily, month_key)
            dailies = None
        t_a += time.time() - t0

        t0 = time.time()
        if dailies is not None:
            # append / 基线缺失：日线全部直接进包（append 不做行级比对）
            ddiff, wdiff, mdiff = dailies, wk, mo
            if kind == "append":
                # 周/月：只与基线**最后 8 行**比对（性能红线 3）
                have_w = {int(r[0]): r[1:] for r in base.execute(
                    "SELECT date,open,high,low,close,vol,amo FROM weekly WHERE meta_id=? "
                    "ORDER BY date DESC LIMIT %d" % TAIL_PERIOD_ROWS, (mid,))}
                have_m = {int(r[0]): r[1:] for r in base.execute(
                    "SELECT date,open,high,low,close,vol,amo FROM monthly WHERE meta_id=? "
                    "ORDER BY date DESC LIMIT %d" % TAIL_PERIOD_ROWS, (mid,))}
                wdiff = diff_rows(wk, have_w, args.tol)
                mdiff = diff_rows(mo, have_m, args.tol)
        else:
            # rewrite：与基线**全部**行比对，只发真正不同/新增的
            have_d = {int(r[0]): r[1:] for r in base.execute(
                "SELECT date,open,high,low,close,vol,amo FROM daily WHERE meta_id=?", (mid,))}
            have_w = {int(r[0]): r[1:] for r in base.execute(
                "SELECT date,open,high,low,close,vol,amo FROM weekly WHERE meta_id=?", (mid,))}
            have_m = {int(r[0]): r[1:] for r in base.execute(
                "SELECT date,open,high,low,close,vol,amo FROM monthly WHERE meta_id=?", (mid,))}
            ddiff = diff_rows(new_daily, have_d, args.tol)
            wdiff = diff_rows(wk, have_w, args.tol)
            mdiff = diff_rows(mo, have_m, args.tol)
        _emit(rows, f, "daily", ddiff)
        _emit(rows, f, "weekly", wdiff)
        _emit(rows, f, "monthly", mdiff)

        rec = {"daily": len(ddiff), "weekly": len(wdiff), "monthly": len(mdiff)}
        if any(rec.get(p) for p in L.PERIODS):
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

    t_loop = time.time() - t0_all
    n_daily, n_weekly, n_monthly = (len(rows["daily"]), len(rows["weekly"]), len(rows["monthly"]))
    total_rows = n_daily + n_weekly + n_monthly
    print("-" * 78)
    print("分类: append=%d rewrite=%d new=%d（合计 %d）" % (n_app, n_rew, n_new, len(names)))
    if skipped_no_meta:
        print("跳过 %d 个「主库无此标的」的 txt（不进包，设备侧会被 JOIN 丢弃）: %s"
              % (len(skipped_no_meta), ", ".join(sorted(skipped_no_meta)[:12])
                 + (" …" if len(skipped_no_meta) > 12 else "")))
    print("阶段 A（分类+解析，融合，2 次句柄/文件）  %.1fs" % t_a)
    print("阶段 B（比对/聚合/汇总）               %.1fs" % t_b)
    print("受影响 file 数: %d（bkt_meta）" % len(rows["meta"]))
    print("补丁行数: daily=%d weekly=%d monthly=%d 合计=%d" % (n_daily, n_weekly, n_monthly, total_rows))
    print("（逐文件主循环总耗时 %.1fs）" % t_loop)

    if total_rows == 0:
        print("无差异：不产出空补丁包。")
        base.close()
        print("基线库完整性: %s  %s" % (db_state(args.base_db),
                                       "✅ 未被修改" if db_state(args.base_db) == before_base else "❌ 被修改!"))
        return 0

    max_date = max(r[1] for p in L.PERIODS for r in rows[p])
    updated_at = L.date_int_to_epoch_utc(max_date)
    print("包内最新日期: %s   updated_at(UTC epoch)=%d" % (max_date, updated_at))

    seq = args.seq if args.seq is not None else next_seq(out_dir)
    out_path = os.path.join(out_dir, "%s%d.db" % (PATCH_PREFIX, seq))
    report_path = os.path.join(out_dir, "%s%d_files.txt" % (PATCH_PREFIX, seq))
    size = sha = None

    if args.dry_run:
        print("--dry-run：不落盘（本应写入 %s）" % out_path)
    else:
        os.makedirs(out_dir, exist_ok=True)
        tmp_path = out_path + ".tmp"
        t0 = time.time()
        # 表结构 / 字段顺序逐字沿用 live_db_builder.build_bucket_file（bkt_meta/daily/weekly/monthly）
        L.build_bucket_file(tmp_path, rows, updated_at)
        # 写后轻量自检：各表行数与内存 rows 一致、bkt_meta 无重复
        chk = sqlite3.connect(L.ro_uri(tmp_path), uri=True)
        try:
            got = chk.execute("SELECT COUNT(*) FROM bkt_meta").fetchone()[0]
            assert got == len(rows["meta"]), "bkt_meta 行数不一致: %d/%d" % (got, len(rows["meta"]))
            for period in L.PERIODS:
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
        avg_row = size / float(total_rows)
        columns = ["daily", "weekly", "monthly", "rows", "cum_rows", "cum_bytes_est"]
        cum_r = 0
        per_file_report = {}
        for f in per_file:
            rec = dict(per_file[f])
            rec["rows"] = sum(rec.get(p, 0) for p in L.PERIODS)
            per_file_report[f] = rec
        cum_r = 0
        ordered = {}
        for f in sorted(per_file_report):
            rec = per_file_report[f]
            cum_r += rec["rows"]
            rec["cum_rows"] = cum_r
            rec["cum_bytes_est"] = int(cum_r * avg_row)
            ordered[f] = rec
        header = [
            "Kline txt 直出差分补丁包 · 受影响 file 清单",
            "生成时间: %s" % datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "旧 txt : %s" % args.old_txt_dir,
            "新 txt : %s" % args.new_txt_dir,
            "基线库 : %s（只读，跑完 size+mtime 未变）" % args.base_db,
            "分类   : append=%d rewrite=%d new=%d" % (n_app, n_rew, n_new),
            "容差   : abs(a-b) > %g（字段 %s 任一变化即计入）" % (args.tol, "/".join(FIELDS)),
            "包内最新日期: %s   updated_at(UTC epoch)=%d" % (max_date, updated_at),
            "包文件 : %s   bytes=%d   sha256=%s" % (out_path, size, sha),
            "包内行数: daily=%d weekly=%d monthly=%d 合计=%d" % (n_daily, n_weekly, n_monthly, total_rows),
            "平均每行约 %.1f B；cum_bytes_est = 累计行数 × 平均行字节（SQLite 单文件无法按 file 精确归因）"
            % avg_row,
        ]
        write_patch_report(report_path, header, columns, ordered)
        print("受影响 file 清单: %s（%d 个 file）" % (report_path, len(ordered)))
    if not args.dry_run:
        print("PC 侧 A+B+C = %.1fs（A %.1fs + B %.1fs + C %.1fs）"
              % (t_a + t_b + t_c, t_a, t_b, t_c))

    # ---- 正确性硬门槛：独立全量重算交叉验证 ----
    if args.self_check > 0:
        run_selfcheck(base, idmap, rows, args.old_txt_dir, args.new_txt_dir,
                      kind_map, args.self_check, args.tol, args.self_check_seed)

    base.close()
    after_base = db_state(args.base_db)
    print("-" * 78)
    print("基线库完整性（mode=size+mtime）: before=%s after=%s  %s"
          % (before_base, after_base, "✅ 未被修改" if after_base == before_base else "❌ 被修改了！"))
    print("总耗时 %.1fs" % (time.time() - t_all))
    return 0


if __name__ == "__main__":
    sys.exit(main())

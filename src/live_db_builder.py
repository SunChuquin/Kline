#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tdx_live 日分片增量库生成器 · **云端兜底生产者**（仅 Python 标准库，不依赖第三方包）

背景与定位
----------
Kline 主库 Documents/tdx.db 是 1.4GB 的全市场历史K线（实测 meta 3611 行 / daily 1400 万行），
App 侧不自动改动。它目前停在 2026-08-28，导致打开任何一只标的看到的都还是 08-28。

增量库改为「**按交易日分片**」发布：一天一片，保留最近 30 片（≈6 周），设备按自身缺口
只下载相交的那几片（典型 1 片 ≈0.5MB），合并进本地增量库；用户还能在 App 里把它合并回主库。

生产者有两个，**产出同一份分片格式，谁跑谁生效**：
  1. 电脑侧（首选）`TrollRestore/build_live_buckets_pc.py`：只读本机 tdx.db 最近 N 天 → 出片。
     零网络、秒级，且**唯一能覆盖 299 只扩展行情指数**（27#/62#/102# 前缀，公开接口无对应）。
  2. 云端（兜底）= 本脚本：读 `src/data/universe.txt` 里可映射的 3312 只 → 批量快照出
     "当天那一片"。覆盖不到那 299 只，覆盖率会如实反映。

本脚本**不再**做全市场枚举，也**不再**逐标的历史补齐（v2 的做法已废弃）：每档只拉一次
批量快照（secid 每批 ≤100 → 3312 只约 34 次请求，秒级），只写/更新当天那一片。

产出
----
    <out>/manifest.json        manifest schema 3
    <out>/bucket_<id>.db       一天一片，自包含（只含该交易日的行）
    <out>/.changed             本次是否有变化（"1"/"0"），workflow 据此决定是否 push

发布位置是 data 分支的 `live/` 目录（manifest.json + bucket_<id>.db）。**文件名与表名是两端契约，不要改。**

分片 id（两端必须一致）
----------------------
    bucket_id = (date(y,m,d) - date(1970,1,1)).days      # UTC 日序，不看本机时区
    例：20260922 → 20718（所以文件名是 bucket_20718.db）

主库口径（实测 tdx.db 得到，务必遵守，否则合并回主库会写错行）
--------------------------------------------------------
1. **键用 `file`（如 SH#600000 / SZ#000995 / 27#HSI），不用 `code`**：
   实测 meta 3611 行里 code 只有 3556 个 distinct（55 处重复：指数与股票同码，例如
   62#000995 全指公用 vs SZ#000995 皇台酒业），file 则 3611/3611 唯一。
2. **市场由 file 前缀判定，不从 6 位 code 猜**：SH#→`1.`，SZ#/BJ#→`0.`。
   这正是 SH#000009（上证380 指数）与 SZ#000009（中国宝安）能正确消歧的原因。
3. **周/月线的 `date` = 该周期的第一个交易日**（不是最后一个！），实测：
   SH#600000 的周线 20260824 覆盖 0824~0828（=该周全部日线聚合），月线 20260803 覆盖
   0803~0828；周线日期一律是"该 ISO 周内该标的的第一个交易日"，月线是"该月第一个交易日"。
   —— 这条如果搞反（用周期末日做 date），合并回主库时会因为 (meta_id,date) 主键对不上
   而**多插一行重复的周/月线**，污染主库。**不要再改回"周期末日"。**
4. 主库**也发"进行中"的周期**（8 月没走完，月线 20260803 就已存在）。但本增量库按 spec
   只发"周期首日落在发布窗口内"的行 —— 完整周期与**进行中的周/月**都发（见
   `aggregate_full_periods` 注释；周期首日在窗口起点之前的才不发）。
5. 分片 id 与日期一一对应，所以 `min_date == max_date == 该片日期`；周/月线因为 date 是
   周期首日，会落到"周期首日所在的那一片"（通常是本周一那片），因此一次运行可能同时更新
   1~3 片（当天片 + 本周首日片 + 本月首日片）——这是与主库日期键保持一致所必需的。

设计取舍
--------
1. 字段顺序：东财 kline 接口 fields2=f51..f57 的顺序是 **日期,开,收,高,低,量,额**
   （开/收/高/低，不是 OHLC）。批量快照 ulist 的 f17/f15/f16/f2 才是 开/高/低/收，见
   `_snapshot_from_diff()`，两处顺序不同，别抄混。
2. 交易日以行情源为准（防K线污染）：当天的 date 取快照 f124（秒级 epoch）按**北京时间
   (UTC+8)** 换算的日期；f124 缺失时退化为"现有分片里的最新交易日"。**绝不用本机日期**
   —— 否则国庆等非交易日被 cron 触发时会凭空写出一根假K线。
3. 覆盖率 < 0.85 判失败（保留上一版）。分母是 universe 的 3611：云端结构上最多只能覆盖
   3312 只（0.917），再乘上停牌/退市标的的存活率，实测 ~0.86，所以 0.85 是"能发布"与
   "大面积拉取失败要果断拦住"之间的分界。`--symbols` 小清单模式保持严格（缺任一即失败）。
4. `bkt_meta.updated_at` 用该片日期的 UTC 零点 epoch（= bucket_id × 86400），**刻意不用
   墙钟**：同内容分片必须字节完全一致，才能实现"只回写变化的分片"与空跑检测。
5. 原子写入：先写 `<out>/bucket_<id>.db.tmp`，校验通过后 os.replace；内容未变的分片不重写；
   超出 30 片的旧片从输出目录删除。任一步失败都不会覆盖已有产物。
6. 不做历史补齐（spec 明确）：本机主库自身就停在 08-28，缺口只能靠"先在通达信客户端补一次
   导出"或电脑侧生产；云端只负责从今天起每天往前滚。

用法
----
    python src/live_db_builder.py --out dist --prev prev/live        # 云端兜底（默认）
    python src/live_db_builder.py --out dist --symbols src/data/symbols.txt   # 小清单调试
    python src/live_db_builder.py --out dist --offline               # 合成数据，无需联网
    python src/live_db_builder.py --out dist --check                 # 只读校验报告
    python src/live_db_builder.py --out dist --now-date 20261001     # 模拟假期那天跑批
"""

import argparse
import concurrent.futures
import datetime
import glob
import hashlib
import json
import os
import shutil
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.request

# Windows 控制台默认 GBK，中文可能报 UnicodeEncodeError，尽量切到 UTF-8
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")

KEEP_BUCKETS = 30               # 保留最近 30 个交易日分片（≈6 周）
EPOCH_DATE = datetime.date(1970, 1, 1)
PERIODS = ("daily", "weekly", "monthly")     # 只发三张表（季/年无法被有限窗口完整覆盖）
BUCKET_PREFIX = "bucket_"
MANIFEST_NAME = "manifest.json"
CHANGED_FLAG_NAME = ".changed"
MANIFEST_SCHEMA = 3
UNIVERSE_PATH = os.path.join("src", "data", "universe.txt")

MIN_COVERAGE = 0.85             # 全市场模式最低覆盖率，低于则判失败、保留上一版
ULIST_BATCH = 100               # 批量快照每批 secid 数（3312 只 → 约 34 次请求）

MIN_REQUEST_INTERVAL = 0.25     # 限速：任两次请求最小间隔(秒) -> 全局约 4 请求/秒
REQUEST_RETRIES = 4             # 含首次共 4 次尝试（≥3 次重试）
REQUEST_TIMEOUT = 20
_last_request_ts = 0.0
_rate_lock = threading.Lock()   # 回补走并发，限速必须线程安全

# 一次性回补（--backfill-days）的默认参数
BACKFILL_WORKERS_DEFAULT = 4
BACKFILL_WORKERS_MAX = 8        # 上限：再高也快不了（总速率被 MIN_REQUEST_INTERVAL 压住）
BACKFILL_PROGRESS_EVERY = 300   # 每完成多少只打印一次进度

# 日线接口（一次性回补用）。fqt=1 前复权，与主库（通达信前复权）口径一致。
# 字段顺序见 _parse_kline_line()：**开,收,高,低**，不是 OHLC。
KLINE_URL = ("https://push2his.eastmoney.com/api/qt/stock/kline/get"
             "?secid={secid}&klt=101&fqt=1&lmt={lmt}&end=20500101"
             "&fields1=f1,f2,f3,f4,f5,f6&fields2=f51,f52,f53,f54,f55,f56,f57")

# f124 = 东财行情时间戳（秒级 epoch）：判断"真实交易日"的唯一权威来源，绝不用本机日期。
SNAPSHOT_ULIST_URL = ("https://push2.eastmoney.com/api/qt/ulist.np/get"
                      "?fltt=2&invt=2&np=1"
                      "&fields=f12,f13,f14,f2,f5,f6,f15,f16,f17,f18,f124"
                      "&secids={secids}")

BEIJING_TZ = datetime.timezone(datetime.timedelta(hours=8))


# ---------------------------------------------------------------------------
# 分片 id / 日期工具（**全程不依赖本机时区**）
# ---------------------------------------------------------------------------

def date_to_int(d):
    """datetime.date -> YYYYMMDD 整数。"""
    return d.year * 10000 + d.month * 100 + d.day


def int_to_date(v):
    """YYYYMMDD 整数 -> datetime.date。"""
    v = int(v)
    return datetime.date(v // 10000, v // 100 % 100, v % 100)


def unix_days(date_int):
    """UTC 日序：从 1970-01-01 起算的整数天数。

    用 date 差值而不是 timestamp —— mktime/fromtimestamp 会引入本机时区，
    导致同一 date 在不同机器落到不同分片 id。这是两端契约的根。
    """
    return (int_to_date(date_int) - EPOCH_DATE).days


def bucket_id_for_date(date_int):
    """分片 id = UTC 日序（一个交易日一片）。20260922 → 20718。"""
    return unix_days(date_int)


def date_for_bucket(bucket_id):
    """分片 id -> 该片对应的日期（YYYYMMDD 整数）。"""
    return date_to_int(EPOCH_DATE + datetime.timedelta(days=int(bucket_id)))


def bucket_file_name(bucket_id):
    return "%s%d.db" % (BUCKET_PREFIX, bucket_id)


def date_int_to_epoch_utc(date_int):
    """YYYYMMDD -> 该日 UTC 零点 epoch 秒（确定性，见 docstring 取舍 4）。"""
    return unix_days(date_int) * 86400


def ro_uri(path):
    """sqlite 只读 URI（绝不以可写方式打开主库）。"""
    return "file:%s?mode=ro" % path.replace("\\", "/").replace("?", "%3f").replace("#", "%23")


# ---------------------------------------------------------------------------
# 周期（周/月）聚合 —— 周期线 date 取"该周期第一个交易日"，与主库口径一致
# ---------------------------------------------------------------------------

def period_bounds(date_int, period):
    """返回该日期所属周期的 (日历起始日, 日历结束日)，均为 YYYYMMDD 整数。
    周 = ISO 周（周一~周日）；月 = 自然月。"""
    dt = int_to_date(date_int)
    if period == "weekly":
        mon = dt - datetime.timedelta(days=dt.weekday())
        return date_to_int(mon), date_to_int(mon + datetime.timedelta(days=6))
    first = dt.replace(day=1)
    last = (first + datetime.timedelta(days=32)).replace(day=1) - datetime.timedelta(days=1)
    return date_to_int(first), date_to_int(last)


def period_key(date_int, period):
    """周期的分组键：周 = (ISO 年, ISO 周)，月 = (年, 月)。"""
    dt = int_to_date(date_int)
    if period == "weekly":
        iso = dt.isocalendar()
        return (iso[0], iso[1])
    return (dt.year, dt.month)


def period_first_candidate(date_int):
    """从某日向后跳过**纯周末**，返回"该周期最早的候选交易日"。

    用途见 `aggregate_full_periods`：判断一个周期是否有交易日落在窗口之前。
    例：8 月的日历起始 20260801 是周六 → 跳到 20260803（周一）。
    只跳周末、不打节假日表：遇到"周期开头是连续工作日假日"的情形会保守地把它当成
    可能的交易日（于是该周期不发）——**宁可少发，不可发错**（发错会把 (meta_id,date)
    键写歪，合并回主库就多一根重复的周/月线）。
    """
    dt = int_to_date(date_int)
    while dt.weekday() >= 5:
        dt += datetime.timedelta(days=1)
    return date_to_int(dt)


def aggregate_full_periods(bars, period, window_start, window_end, diag=None):
    """由窗口内日线聚合出周/月线。**只要周期的「首日」落在窗口内就发**（含进行中的周/月）。

    bars: 某只标的的日线（含 date/open/high/low/close/vol/amo 的 dict 列表，窗口内）。
    diag: 可选计数字典，统计被跳过的周期（skip_start=周期首日落在窗口起点之前），供调用方打印。
    返回 [{date, open, high, low, close, vol, amo}, ...]，其中：

      · `date` = **该周期的第一个交易日**（组内最早日线日期）。这是与主库 tdx.db 对齐的**口径**，
        实测：SH#600000 周线 `20260824` 覆盖 0824~0828（周首日=周一）、月线 `20260803` 覆盖
        0803~0828（月首日=当月首个交易日）；27#HSCEI / 62#000995 / 27#HSI 等也一致。
        ⚠ 若改用"周期末日"做 date，(meta_id,date) 主键对不上，合并回主库会**多插一行重复的
        周/月线**。**不要再改回"周期末日"。**

      · 发出的条件只有一条：**周期的「首日」落在窗口起始日之后或正好是它**，其中"首日"取
        `period_bounds()` 给出的日历起始日、**并向后跳过纯周末**（见 `period_first_candidate`）。
        窗口起始日本身是一个交易日（某片分片的日期），所以这条等价于"该周期不可能有任何一个
        交易日落在窗口之前"。
        - 完整周期：聚合值 = 该周期全部日线的聚合，与主库口径**逐字段一致**；
        - **进行中的周期也发**（例如本周从 20260921 开始、窗口内只有 21~22 两天，就发一根
          date=20260921 的周线，聚合从 21 日起算）—— 这正是通达信盘中显示"本周这根K线"的语义，
          也让周/月线视图的最新一根不再滞后一个周期；
        - 举例：窗口 20260803~20260828 时，8 月的日历起始是 0801（周六），跳过周末后候选首日
          = 0803 = 窗口起始日 → **发**（date=20260803）；而同窗口里 0727 那周（首日 0727 在
          窗口之前）**不发**。
      · **候选首日在窗口起点之前 → 不发**：那时我们拿不到该周期更早的日线，既算不出真正的
        "周期第一个交易日"（date 会错、合并回主库会插重复行），聚合值也只是局部——用它去覆盖
        主库已有的正确周/月线就是污染。窗口起点兜住了这一条，所以"窗口第一周"永远不发。
        （保守方向：若周期起始的连续工作日恰是法定假日，会被一并跳过——宁可少发，不可发错。）
    """
    groups = {}
    for b in bars:
        if not (window_start <= b["date"] <= window_end):
            continue
        groups.setdefault(period_key(b["date"], period), []).append(b)
    out = []
    for key in sorted(groups):
        bs = sorted(groups[key], key=lambda x: x["date"])
        cal_start, _cal_end = period_bounds(bs[0]["date"], period)
        if period_first_candidate(cal_start) < window_start:
            if diag is not None:
                diag["skip_start"] = diag.get("skip_start", 0) + 1
            continue        # 候选首日落在窗口起点之前 -> 不发（见 docstring 最后一段）
        out.append({
            "date": bs[0]["date"],                  # 周期第一个交易日（与主库一致）
            "open": bs[0]["open"],
            "high": max(x["high"] for x in bs),
            "low": min(x["low"] for x in bs),
            "close": bs[-1]["close"],
            "vol": sum(x["vol"] for x in bs),
            "amo": sum(x["amo"] for x in bs),
        })
    return out


# ---------------------------------------------------------------------------
# 清单：universe.txt（生产） / symbols（调试）
# ---------------------------------------------------------------------------

# 通达信特有的伪代码 -> 行情源 secid：前缀规则推不出来，必须显式列出。
# 实测扫描 universe.txt 3611 行，**只有这一条**属于此类（其余 SH#/SZ# 都能用前缀规则直接映射）。
SPECIAL_FILE_SECID = {
    "SH#999999": "1.000001",     # 上证指数：通达信记为 999999，东财 secid 是 1.000001
}


def secid_for_file(file_str, code):
    """file 前缀 → 行情源 secid。**用 file 前缀判定市场**，不从 6 位 code 猜。

    SH#→`1.`、SZ#/BJ#→`0.`；其余前缀（27#/62#/102# 等扩展行情：恒生、行业/主题指数）
    公开行情接口无对应 → 返回 None，云端跳过、计入 missing_sample 与 coverage。
    通达信的伪代码（如 SH#999999=上证指数）走 SPECIAL_FILE_SECID 特例表。
    """
    if file_str in SPECIAL_FILE_SECID:
        return SPECIAL_FILE_SECID[file_str]
    prefix = file_str.split("#", 1)[0].upper()
    if prefix == "SH":
        return "1." + code
    if prefix in ("SZ", "BJ"):
        return "0." + code
    return None


def parse_universe(path):
    """解析 universe.txt（TAB 分隔：file / code / name / type）。

    返回全部条目的列表 [{file, code, name, type, secid}]，`secid=None` 表示不可映射
    （扩展行情指数，只有电脑侧能生产）。`#` 开头为注释行。
    """
    if not os.path.exists(path):
        raise SystemExit("清单文件不存在: %s" % path)
    out, seen = [], set()
    # utf-8-sig：兼容 Windows 编辑器写入的 UTF-8 BOM
    with open(path, "r", encoding="utf-8-sig") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip("\n").rstrip("\r")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = [p.strip() for p in line.split("\t")]
            if len(parts) < 2:
                print("[warn] 第 %d 行字段不足（需 TAB 分隔的 file/code/name/type），忽略: %r"
                      % (lineno, line[:60]), file=sys.stderr)
                continue
            file_str, code = parts[0], parts[1]
            name = parts[2] if len(parts) > 2 else ""
            typ = parts[3] if len(parts) > 3 else ""
            if "#" not in file_str:
                print("[warn] 第 %d 行 file 缺少 '前缀#' 形式，忽略: %r" % (lineno, file_str),
                      file=sys.stderr)
                continue
            if file_str in seen:
                print("[warn] 第 %d 行重复 file %s，已忽略" % (lineno, file_str), file=sys.stderr)
                continue
            seen.add(file_str)
            out.append({"file": file_str, "code": code, "name": name, "type": typ,
                        "secid": secid_for_file(file_str, code)})
    if not out:
        raise SystemExit("清单为空: %s" % path)
    return out


def parse_symbols(path):
    """解析调试用小清单，**统一到 file 语义**：
      · 含 `#` 的 token 直接当 file（如 SH#600000 / 27#HSI）；
      · 纯 6 位代码按市场前缀补成 file（6/5/9 开头 → SH#，其余 → SZ#），保持旧文件仍可用。
    返回结构与 parse_universe 相同。
    """
    if not os.path.exists(path):
        raise SystemExit("清单文件不存在: %s" % path)
    out, seen = [], set()
    with open(path, "r", encoding="utf-8-sig") as fh:
        for lineno, raw in enumerate(fh, 1):
            # file 本身含 '#'，所以行内不能用 '#' 追加备注；取第一个空白分隔 token 作条目
            body = raw.strip()
            if not body or body.startswith("#"):
                continue
            token = body.split()[0]
            if "#" in token:
                file_str = token
                code = file_str.split("#", 1)[1]
            elif len(token) == 6 and token.isdigit():
                code = token
                file_str = ("SH#" if code[0] in ("6", "5", "9") else "SZ#") + code
            else:
                print("[warn] 第 %d 行忽略非法条目: %r" % (lineno, token), file=sys.stderr)
                continue
            if file_str in seen:
                print("[warn] 第 %d 行重复 file %s，已忽略" % (lineno, file_str), file=sys.stderr)
                continue
            seen.add(file_str)
            out.append({"file": file_str, "code": code, "name": code, "type": "",
                        "secid": secid_for_file(file_str, code)})
    if not out:
        raise SystemExit("清单为空: %s" % path)
    return out


# ---------------------------------------------------------------------------
# HTTP：限速 + 指数退避重试
# ---------------------------------------------------------------------------

def _throttle():
    """全局限速（**线程安全**）：任意两次请求之间至少间隔 MIN_REQUEST_INTERVAL。

    0.25s 间隔 ≈ 4 请求/秒。实现用"预约时间槽"：在锁里把 `_last_request_ts` 往后推一个间隔、
    拿到属于自己的出发时刻，**真正的 sleep 放在锁外** —— 这样并发 worker 不会互相堵在锁里
    （不会退化成串行），但总速率仍被全局压住，属礼貌爬取。
    """
    global _last_request_ts
    with _rate_lock:
        due = max(time.monotonic(), _last_request_ts + MIN_REQUEST_INTERVAL)
        _last_request_ts = due
    delay = due - time.monotonic()
    if delay > 0:
        time.sleep(delay)


def http_get_json(url):
    """带 UA / 限速 / 指数退避重试的 GET。失败抛最后一次异常。"""
    last_err = None
    for attempt in range(REQUEST_RETRIES):
        _throttle()
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": UA,
                "Accept": "application/json, text/plain, */*",
                "Referer": "https://quote.eastmoney.com/",
            })
            with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
                raw = resp.read()
            return json.loads(raw.decode("utf-8", "replace"))
        except Exception as exc:      # URLError/HTTPError/超时/JSON 解析失败统一重试
            last_err = exc
            if attempt < REQUEST_RETRIES - 1:
                time.sleep(0.5 * (2 ** attempt))
    raise last_err


def _num(v):
    """东财非交易时段/停牌会返回 '-'，统一转成 None。"""
    if v is None:
        return None
    if isinstance(v, str):
        v = v.strip()
        if v in ("", "-", "--"):
            return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def beijing_date_from_ts(ts):
    """快照 f124（秒级 epoch）按**北京时间(UTC+8)** 换算成 YYYYMMDD 整数。

    显式 UTC+8，不依赖跑批机器时区。ts 缺失/为 '-'/非正数 → None（由调用方兜底）。
    """
    try:
        ts = int(float(ts))
    except (TypeError, ValueError):
        return None
    if ts <= 0:
        return None
    return int(datetime.datetime.fromtimestamp(ts, BEIJING_TZ).strftime("%Y%m%d"))


# ---------------------------------------------------------------------------
# 取数：批量快照（当天那根K线）
# ---------------------------------------------------------------------------

def _snapshot_from_diff(diff):
    """ulist 返回体 -> {secid: 当日行情}。

    ⚠ 字段顺序：f17=开、f15=高、f16=低、f2=收、f5=量、f6=额（与 kline 接口的
    开,收,高,低 顺序不同，别抄混）。
    """
    res = {}
    for it in diff or []:
        f12, f13 = it.get("f12"), it.get("f13")
        if f12 is None or f13 is None:
            continue
        res["%s.%s" % (f13, f12)] = {
            "secid": "%s.%s" % (f13, f12),
            "code": str(f12),
            "name": (it.get("f14") or "").strip(),
            "open": _num(it.get("f17")), "high": _num(it.get("f15")),
            "low": _num(it.get("f16")), "close": _num(it.get("f2")),
            "vol": _num(it.get("f5")), "amo": _num(it.get("f6")),
            "ts": _num(it.get("f124")),
        }
    return res


def fetch_snapshot(secids, progress_every=10):
    """批量快照：ulist.np/get 一次可覆盖多个 secid，按 ULIST_BATCH 分批。

    返回 {secid: 当日行情}；个别批次失败只告警不中断（停牌/退市标的本来就没有报价）。
    每 progress_every 批打印一次进度与耗时，便于在 cron 日志里看清"多少请求、多久"。
    """
    uniq = list(dict.fromkeys(secids))
    result = {}
    if not uniq:
        return result
    total = (len(uniq) + ULIST_BATCH - 1) // ULIST_BATCH
    t0 = time.time()
    for i in range(0, len(uniq), ULIST_BATCH):
        chunk = uniq[i:i + ULIST_BATCH]
        idx = i // ULIST_BATCH + 1
        try:
            data = http_get_json(SNAPSHOT_ULIST_URL.format(secids=",".join(chunk)))
            result.update(_snapshot_from_diff((data.get("data") or {}).get("diff")))
        except Exception as exc:
            print("[warn] 批量快照第 %d/%d 批失败: %s" % (idx, total, exc), file=sys.stderr)
        if idx % progress_every == 0 or idx == total:
            print("  [快照] %d/%d 批  已命中 %d/%d 只  用时 %.1fs"
                  % (idx, total, len(result), len(uniq), time.time() - t0))
    return result


# ---------------------------------------------------------------------------
# 一次性缺口回补（--backfill-days）：逐标的拉最近 N 根日线
# ---------------------------------------------------------------------------

def _parse_kline_line(line):
    """解析 '2026-09-22,开,收,高,低,量,额' -> dict。

    ⚠ 东财 kline 接口 fields2=f51..f57 的顺序是 **日期,开,收,高,低,量,额**
      （即 开/收/高/低，**不是** OHLC）；批量快照 ulist 的 f17/f15/f16/f2 才是
      开/高/低/收。两处顺序不同，别抄混。
    """
    p = line.split(",")
    if len(p) < 7:
        return None
    try:
        date = int(p[0].replace("-", ""))
    except ValueError:
        return None
    bar = {
        "date": date,
        "open": _num(p[1]), "close": _num(p[2]),
        "high": _num(p[3]), "low": _num(p[4]),
        "vol": _num(p[5]), "amo": _num(p[6]),
    }
    # 前复权老数据可能出现负价/0 价，属无效数据，直接丢弃
    if None in (bar["open"], bar["high"], bar["low"], bar["close"]) or bar["close"] <= 0:
        return None
    return bar


def fetch_kline_recent(secid, limit):
    """拉某标的最近 limit 根日线（一次性回补用）。返回升序 bar 列表。

    停牌/退市标的接口不返回 klines -> 返回 []（由调用方计入失败，不抛异常）。
    重试交给 http_get_json（4 次尝试 + 指数退避），且每次尝试都走全局限速。
    """
    data = http_get_json(KLINE_URL.format(secid=secid, lmt=limit))
    bars = []
    for line in (data.get("data") or {}).get("klines") or []:
        bar = _parse_kline_line(line)
        if bar:
            bars.append(bar)
    bars.sort(key=lambda b: b["date"])
    return bars[-limit:]


def backfill_mappable(entries, days, workers, limit_symbols=None):
    """并发回补 `entries` 中**可映射**标的（SH#/SZ#/BJ#）的最近 days 根日线。

    · 礼貌并发：ThreadPoolExecutor(workers)，但总速率由全局 `_throttle()` 压在 ~4 请求/秒，
      所以 workers 再大也不会把请求速率抬上去（workers 只影响"等待时是否空转"）。
    · 每只失败只记入 failed、不中断整体；每 BACKFILL_PROGRESS_EVERY 只打印一次进度。
    · 返回 {"daily": {file: {date: bar}}, "ok": [...], "failed": [...], "elapsed": 秒}
    """
    targets = [e for e in entries if e["secid"]]
    if limit_symbols:
        targets = targets[:limit_symbols]
    total = len(targets)
    daily, ok, failed = {}, [], []
    t0 = time.time()
    print("回补: 目标 %d 只可映射标的 × 最近 %d 根日线，workers=%d，全局速率约 %.0f 请求/秒"
          % (total, days, workers, 1.0 / MIN_REQUEST_INTERVAL))
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futs = {pool.submit(fetch_kline_recent, e["secid"], days): e for e in targets}
        for fut in concurrent.futures.as_completed(futs):
            e = futs[fut]
            done += 1
            try:
                bars = fut.result()
            except Exception as exc:
                bars = []
                if len(failed) < 5:
                    print("[warn] 回补 %s(%s) 失败: %s" % (e["file"], e["secid"], exc),
                          file=sys.stderr)
            if bars:
                daily[e["file"]] = {b["date"]: b for b in bars}
                ok.append(e["file"])
            else:
                failed.append(e["file"])
            if done % BACKFILL_PROGRESS_EVERY == 0 or done == total:
                el = time.time() - t0
                print("  [回补] %d/%d · 成功 %d / 失败 %d · 已耗时 %.1fs · 预计剩余 %.1fs"
                      % (done, total, len(ok), len(failed), el, el / done * (total - done)))
    return {"daily": daily, "ok": ok, "failed": failed, "elapsed": time.time() - t0}


# ---------------------------------------------------------------------------
# 本地合成数据（--offline，仅联调/结构校验）
# ---------------------------------------------------------------------------

def _prng(seed_text):
    """由 hashlib 派生的确定性伪随机数发生器（64bit LCG），保证离线结果可复现。"""
    state = int.from_bytes(hashlib.sha256(seed_text.encode("utf-8")).digest()[:8], "big")

    def nxt():
        nonlocal state
        state = (state * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        return state

    return nxt


def synth_daily(file_str, count, end_date):
    """按 file 生成确定性的合成日线（跳过周末），价格量级与标的是否指数大致相符。"""
    rnd = _prng("kline-live:" + file_str)
    is_index = ("指数" in file_str) or file_str.startswith(("SH#000", "27#", "62#", "102#"))
    price = (3000.0 if is_index else 10.0) + (rnd() % 500) / 10.0
    dates, d = [], end_date
    while len(dates) < count:
        if d.weekday() < 5:
            dates.append(d)
        d -= datetime.timedelta(days=1)
    dates.reverse()
    bars = {}
    for dt in dates:
        change = ((rnd() % 2001) - 1000) / 10000.0        # ±10%
        prev = price
        price = max(0.5, round(prev * (1 + change), 2))
        o, c = round(prev, 2), round(price, 2)
        h = round(max(o, c) * (1 + (rnd() % 100) / 5000.0), 2)
        l = round(min(o, c) * (1 - (rnd() % 100) / 5000.0), 2)
        vol = float(100000 + rnd() % 5000000)
        bars[date_to_int(dt)] = {"date": date_to_int(dt), "open": o, "high": h, "low": l,
                                 "close": c, "vol": vol, "amo": round(vol * c, 2)}
    return bars


# ---------------------------------------------------------------------------
# 读上一版分片（滚动基线）
# ---------------------------------------------------------------------------

def read_prev_buckets(prev_dir):
    """读上一版分片目录，拼出窗口内的日线。

    返回:
      {"daily": {file: {date: bar}}, "ids": set(bucket_id),
       "files": {bucket_id: path}, "shas": {bucket_id: sha256}, "manifest": {...}|None}

    只读 bkt_daily（周/月线一律由窗口日线重算，不需要读回，避免两套口径漂移）。
    prev_dir 为空/不存在/无分片 → daily={} → 走"首次发布"分支。
    目录容错：分片可能直接在 prev/ 下，也可能在 prev/live/ 下（data 分支布局）。
    """
    res = {"daily": {}, "ids": set(), "files": {}, "shas": {}, "manifest": None}
    if not prev_dir:
        return res
    for cand in (prev_dir, os.path.join(prev_dir, "live")):
        if glob.glob(os.path.join(cand, BUCKET_PREFIX + "*.db")):
            paths = sorted(glob.glob(os.path.join(cand, BUCKET_PREFIX + "*.db")))
            break
    else:
        paths = []
    for mf in (os.path.join(prev_dir, MANIFEST_NAME), os.path.join(prev_dir, "live", MANIFEST_NAME)):
        if os.path.exists(mf):
            try:
                with open(mf, "r", encoding="utf-8") as fh:
                    res["manifest"] = json.load(fh)
            except Exception as exc:
                print("[warn] 上一版 manifest 解析失败（忽略）: %s" % exc, file=sys.stderr)
            break
    declared = {}
    for item in (res["manifest"] or {}).get("buckets") or []:
        if isinstance(item, dict) and item.get("id") is not None and item.get("sha256"):
            declared[int(item["id"])] = item["sha256"]

    for path in paths:
        base = os.path.basename(path)
        try:
            bucket_id = int(base[len(BUCKET_PREFIX):-len(".db")])
        except ValueError:
            continue
        res["ids"].add(bucket_id)
        res["files"][bucket_id] = path
        res["shas"][bucket_id] = declared.get(bucket_id) or sha256_file(path)
        conn = sqlite3.connect(ro_uri(path), uri=True)
        try:
            for f, date, o, h, l, c, v, a in conn.execute(
                    "SELECT file,date,open,high,low,close,vol,amo FROM bkt_daily"):
                res["daily"].setdefault(f, {})[int(date)] = {
                    "date": int(date), "open": float(o), "high": float(h), "low": float(l),
                    "close": float(c), "vol": float(v or 0), "amo": float(a or 0)}
        finally:
            conn.close()
    if res["ids"]:
        print("上一版分片: %s（%d 片，覆盖 %d 个 file）"
              % (prev_dir, len(res["ids"]), len(res["daily"])))
    return res


# ---------------------------------------------------------------------------
# 写分片 + 校验（临时文件 -> 原子替换）
# ---------------------------------------------------------------------------

BUCKET_DDL = """
CREATE TABLE {tbl}(file TEXT, date INTEGER, open REAL, high REAL, low REAL,
                   close REAL, vol REAL, amo REAL, PRIMARY KEY(file, date));
"""


def build_bucket_file(tmp_path, rows, updated_at):
    """写一个分片到临时文件。表名/字段名是两端契约，不要改。"""
    if os.path.exists(tmp_path):
        os.remove(tmp_path)
    conn = sqlite3.connect(tmp_path)
    try:
        conn.execute("PRAGMA journal_mode=DELETE;")
        conn.execute("CREATE TABLE bkt_meta(file TEXT PRIMARY KEY, code TEXT, name TEXT, "
                     "type TEXT, updated_at INTEGER);")
        for period in PERIODS:
            conn.execute(BUCKET_DDL.format(tbl="bkt_" + period))
        conn.executemany("INSERT OR REPLACE INTO bkt_meta(file,code,name,type,updated_at) "
                         "VALUES(?,?,?,?,?)",
                         [(f, c, n, t, updated_at) for (f, c, n, t) in rows.get("meta") or []])
        for period in PERIODS:
            data = rows.get(period) or []
            if data:
                conn.executemany(
                    "INSERT OR REPLACE INTO bkt_%s(file,date,open,high,low,close,vol,amo)"
                    " VALUES(?,?,?,?,?,?,?,?)" % period, data)
        conn.commit()
    finally:
        conn.close()


def validate_bucket(path, bucket_id, rows):
    """写入前硬校验（失败抛 AssertionError，调用方丢弃临时文件、绝不覆盖产物）：
      · bkt_meta 行数 = 去重后的 file 数；
      · 三张表每行 date 必须 == 本片日期（一天一片 => min_date == max_date，且分片间不重叠）；
      · 各表实际行数与内存 rows 一致。
    """
    day = date_for_bucket(bucket_id)
    conn = sqlite3.connect(ro_uri(path), uri=True)
    try:
        problems = []
        meta_rows = rows.get("meta") or []
        files = [f for (f, _, _, _) in meta_rows]
        if len(set(files)) != len(files):
            problems.append("bkt_meta 存在重复 file")
        got = conn.execute("SELECT COUNT(*) FROM bkt_meta").fetchone()[0]
        if got != len(set(files)):
            problems.append("bkt_meta 行数不一致: 实际 %d / 应为 %d" % (got, len(set(files))))
        for period in PERIODS:
            bad = conn.execute("SELECT file,date FROM bkt_%s WHERE date<>? LIMIT 1" % period,
                               (day,)).fetchone()
            if bad:
                problems.append("bkt_%s 有非本片日期的行 file=%s date=%s（本片应为 %s）"
                                % (period, bad[0], bad[1], day))
            cnt = conn.execute("SELECT COUNT(*) FROM bkt_%s" % period).fetchone()[0]
            if cnt != len(rows.get(period) or []):
                problems.append("bkt_%s 行数不一致: 实际 %d / 声明 %d"
                                % (period, cnt, len(rows.get(period) or [])))
        if problems:
            raise AssertionError("分片 bucket_%d 校验失败:\n  - %s"
                                 % (bucket_id, "\n  - ".join(problems)))
    finally:
        conn.close()


def bucket_file_stats(path, day):
    """从分片文件读出权威统计（行数 + min/max 日期），用于 manifest。"""
    conn = sqlite3.connect(ro_uri(path), uri=True)
    try:
        rows = {"meta": conn.execute("SELECT COUNT(*) FROM bkt_meta").fetchone()[0]}
        for period in PERIODS:
            rows[period] = conn.execute("SELECT COUNT(*) FROM bkt_%s" % period).fetchone()[0]
        mn, mx = conn.execute("SELECT MIN(date), MAX(date) FROM bkt_daily").fetchone()
    finally:
        conn.close()
    if mn is None:
        mn = mx = day
    return rows, mn, mx


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def write_manifest_atomic(manifest_path, payload):
    tmp = manifest_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, manifest_path)


# ---------------------------------------------------------------------------
# 切分与落盘（两个生产者共用，避免两套口径漂移）
# ---------------------------------------------------------------------------

def build_slots(daily_by_file, kept_ids, meta_rows, window_start, window_end):
    """把窗口内日线切进各个**日分片**。

    · daily 行按自己的 date 落片（一天一片，天然不重叠）；
    · weekly/monthly 由窗口内日线聚合（周期首日在窗口内就发，含进行中的周/月，见
      `aggregate_full_periods`），按**周期首日**落片 —— 与主库 tdx.db 的日期口径一致。
      副作用：周/月线通常落在"本周一/本月首日"那一片上，所以一次运行可能同时更新
      当天片与本周/本月首日片（这是合并回主库时不写重行的前提）。

    meta 行进**每一片**（分片自包含，App 单独下载任意一片都能拿到 file→code/name/type）。
    返回 {bucket_id: {"meta": [...], "daily": [...], "weekly": [...], "monthly": [...]}}，
    只包含至少有一条日线的分片。
    """
    kept_set = set(kept_ids)
    slots = {bid: {"meta": meta_rows, "daily": [], "weekly": [], "monthly": []} for bid in kept_ids}
    diag = {}
    for f, bars in daily_by_file.items():
        for bar in bars.values():
            bid = bucket_id_for_date(bar["date"])
            if bid in kept_set:
                slots[bid]["daily"].append(
                    (f, bar["date"], bar["open"], bar["high"], bar["low"], bar["close"],
                     bar["vol"], bar["amo"]))
        window_bars = [b for b in bars.values() if window_start <= b["date"] <= window_end]
        if not window_bars:
            continue
        for period in ("weekly", "monthly"):
            for row in aggregate_full_periods(window_bars, period, window_start, window_end, diag):
                bid = bucket_id_for_date(row["date"])
                if bid in kept_set:
                    slots[bid][period].append(
                        (f, row["date"], row["open"], row["high"], row["low"], row["close"],
                         row["vol"], row["amo"]))
    if diag:
        # 让"周期首日在窗口起点之前不发"这条规则在日志里可见（被跳过的多半就是窗口第一周/第一月）。
        print("  [周期聚合] 完整周期与进行中的周/月都发；跳过「周期首日在窗口起点之前」%d 个周期"
              "（file×period 计数）" % diag.get("skip_start", 0))
    return {bid: rows for bid, rows in slots.items() if rows["daily"]}


def emit_buckets(out_dir, slots, kept_ids, prev_files, prev_shas):
    """逐片写临时文件 -> 校验 -> **只回写变化的分片**；并删除超出保留范围的旧分片。

    未变的分片不重写（沿用上一版字节 / 保留输出目录里已有的同名文件，mtime 不变），
    这样才能做到"空跑不产生任何字节变化"。校验失败会丢弃临时文件、绝不覆盖已有产物。
    返回 {"buckets": [manifest 分片项], "changed": bool, "rewritten": [id], "removed": [文件名]}
    """
    manifest_buckets, changed, rewritten = [], False, []
    for bucket_id in sorted(kept_ids, reverse=True):
        rows = slots[bucket_id]
        day = date_for_bucket(bucket_id)
        tmp_path = os.path.join(out_dir, bucket_file_name(bucket_id) + ".tmp")
        out_path = os.path.join(out_dir, bucket_file_name(bucket_id))
        build_bucket_file(tmp_path, rows, date_int_to_epoch_utc(day))
        try:
            validate_bucket(tmp_path, bucket_id, rows)
        except Exception:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)         # 校验失败：丢弃临时文件，绝不覆盖已有产物
            raise
        new_sha = sha256_file(tmp_path)
        prev_sha = prev_shas.get(bucket_id)
        prev_path = prev_files.get(bucket_id)
        if not (prev_path and prev_sha == new_sha):
            changed = True
        if os.path.exists(out_path) and sha256_file(out_path) == new_sha:
            os.remove(tmp_path)             # 输出目录里已有同内容文件：不重写，保留 mtime
            action = "未变(保留)"
        elif prev_path and prev_sha == new_sha:
            shutil.copyfile(prev_path, out_path)     # 与上一版字节一致：直接沿用
            os.remove(tmp_path)
            action = "未变(沿用)"
        else:
            os.replace(tmp_path, out_path)
            action = "已更新"
            rewritten.append(bucket_id)
        stats, mn, mx = bucket_file_stats(out_path, day)
        manifest_buckets.append({
            "file": bucket_file_name(bucket_id), "id": bucket_id,
            "min_date": mn, "max_date": mx,
            "bytes": os.path.getsize(out_path), "sha256": new_sha, "rows": stats,
        })
        print("  %-18s id=%-8d %s daily=%-5d weekly=%-5d monthly=%-5d meta=%-5d %10d B  %s"
              % (bucket_file_name(bucket_id), bucket_id, day, stats["daily"], stats["weekly"],
                 stats["monthly"], stats["meta"], os.path.getsize(out_path), action))

    keep_files = {b["file"] for b in manifest_buckets}
    removed = []
    for path in sorted(glob.glob(os.path.join(out_dir, BUCKET_PREFIX + "*.db"))):
        if os.path.basename(path) not in keep_files:
            os.remove(path)
            removed.append(os.path.basename(path))
    if removed:
        print("已删除超出保留范围的旧分片: %s" % ", ".join(removed))
        changed = True
    return {"buckets": manifest_buckets, "changed": changed,
            "rewritten": rewritten, "removed": removed}


# ---------------------------------------------------------------------------
# --check 校验报告（v3）
# ---------------------------------------------------------------------------

def run_check(out_dir):
    """校验 manifest 与分片逐项一致，并做结构检查：
    schema=3 / 片数≤30 / 每片 rows·bytes·sha256 / 片内 min_date==max_date==分片日期 /
    分片间日期不重叠 / 最新片含 trade_date / 输出目录无多余分片；打印每片体积与总字节。
    """
    mf_path = os.path.join(out_dir, MANIFEST_NAME)
    print("=" * 78)
    print("tdx_live 日分片增量库校验报告（v3）")
    print("=" * 78)
    print("输出目录 : %s" % out_dir)
    if not os.path.exists(mf_path):
        raise SystemExit("未找到 manifest: %s" % mf_path)
    with open(mf_path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)
    print("manifest : %s (schema=%s source=%s trade_date=%s)"
          % (mf_path, manifest.get("schema"), manifest.get("source"),
             manifest.get("trade_date")))
    print("universe : %s   covered: %s   coverage: %.4f   keep_buckets: %s   latest_bucket: %s"
          % (manifest.get("universe"), manifest.get("covered"), manifest.get("coverage") or 0.0,
             manifest.get("keep_buckets"), manifest.get("latest_bucket")))
    miss = manifest.get("missing_sample") or []
    print("missing_sample(%d): %s" % (len(miss), ", ".join(miss) or "无"))

    problems = []
    if manifest.get("schema") != MANIFEST_SCHEMA:
        problems.append("schema 期望 %d，实际 %s" % (MANIFEST_SCHEMA, manifest.get("schema")))
    if manifest.get("keep_buckets") != KEEP_BUCKETS:
        problems.append("keep_buckets 期望 %d，实际 %s" % (KEEP_BUCKETS, manifest.get("keep_buckets")))
    buckets = manifest.get("buckets") or []
    if not buckets:
        problems.append("manifest.buckets 为空")
    if len(buckets) > KEEP_BUCKETS:
        problems.append("保留分片数 %d 超过上限 %d" % (len(buckets), KEEP_BUCKETS))
    ids = [int(b["id"]) for b in buckets]
    if ids != sorted(ids, reverse=True):
        problems.append("buckets 未按 id 从新到旧排序")
    if len(set(ids)) != len(ids):
        problems.append("存在重复的分片 id（分片间日期重叠）")
    trade_date = manifest.get("trade_date")

    print("-" * 78)
    print("%-18s %-8s %-10s %-9s %-8s %-8s %-6s %10s"
          % ("文件", "id", "日期", "daily", "weekly", "monthly", "meta", "bytes"))
    total_bytes, declared, seen_dates = 0, set(), {}
    for item in buckets:
        path = os.path.join(out_dir, item["file"])
        declared.add(item["file"])
        if not os.path.exists(path):
            problems.append("分片文件缺失: %s" % item["file"])
            continue
        bucket_id = int(item["id"])
        day = date_for_bucket(bucket_id)
        size = os.path.getsize(path)
        total_bytes += size
        if size != item.get("bytes"):
            problems.append("%s bytes 不一致: 实际 %d / 声明 %s"
                            % (item["file"], size, item.get("bytes")))
        digest = sha256_file(path)
        if digest != item.get("sha256"):
            problems.append("%s sha256 不匹配" % item["file"])
        try:
            rows, mn, mx = bucket_file_stats(path, day)
        except Exception as exc:
            problems.append("%s 读取失败: %s" % (item["file"], exc))
            continue
        for key in ("daily", "weekly", "monthly", "meta"):
            if rows[key] != (item.get("rows") or {}).get(key):
                problems.append("%s rows.%s 不一致: 实际 %s / 声明 %s"
                                % (item["file"], key, rows[key], (item.get("rows") or {}).get(key)))
        if rows["daily"] and (mn != day or mx != day):
            problems.append("%s 片内 min_date/max_date 应都为 %s，实际 %s~%s"
                            % (item["file"], day, mn, mx))
        if not (item.get("min_date") == mn and item.get("max_date") == mx):
            problems.append("%s 日期范围与声明不一致: 实际 %s~%s / 声明 %s~%s"
                            % (item["file"], mn, mx, item.get("min_date"), item.get("max_date")))
        if day in seen_dates:
            problems.append("分片日期重叠: bucket_%d 与 bucket_%d 都是 %s"
                            % (seen_dates[day], bucket_id, day))
        seen_dates[day] = bucket_id
        print("%-18s %-8d %-10s %-9d %-8d %-8d %-6d %10d"
              % (item["file"], bucket_id, day, rows["daily"], rows["weekly"],
                 rows["monthly"], rows["meta"], size))

    if buckets and trade_date:
        latest_id = int(buckets[0]["id"])
        if latest_id != bucket_id_for_date(trade_date):
            problems.append("最新分片 %d 与 trade_date %s 不符（应为 %d）"
                            % (latest_id, trade_date, bucket_id_for_date(trade_date)))
        else:
            print("trade_date: %s 落在最新分片 bucket_%d ✓" % (trade_date, latest_id))
    if seen_dates:
        ds = sorted(seen_dates)
        # 一眼看出"覆盖到哪段"：MIN/MAX 分片日期 + 片数（是否连续见上方的 id/重叠检查）
        print("分片日期: MIN=%s  MAX=%s  片数=%d（= %d 个交易日）"
              % (ds[0], ds[-1], len(ds), len(ds)))

    stray = sorted({os.path.basename(p)
                    for p in glob.glob(os.path.join(out_dir, BUCKET_PREFIX + "*.db"))} - declared)
    if stray:
        problems.append("输出目录存在 manifest 未声明的分片: %s" % ", ".join(stray))
    print("-" * 78)
    print("总字节数 : %d (%.3f MB)   平均每片 %.1f KB"
          % (total_bytes, total_bytes / 1048576.0, total_bytes / max(1, len(declared)) / 1024.0))
    print("=" * 78)
    print("结论: %s" % ("全部校验通过" if not problems
                        else "发现 %d 个问题:\n  - %s" % (len(problems), "\n  - ".join(problems))))
    return 0 if not problems else 1


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def _offline_daily(entries, now_date, days):
    """--offline：为清单里全部条目（含不可映射的扩展行情指数）合成日线，用于结构联调。"""
    return {e["file"]: synth_daily(e["file"], days, now_date) for e in entries}


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="生成 tdx_live 日分片增量库（云端兜底生产者，仅标准库）")
    parser.add_argument("--universe", default=UNIVERSE_PATH,
                        help="全市场清单（默认 %s，TAB 分隔 file/code/name/type）" % UNIVERSE_PATH)
    parser.add_argument("--symbols", default=None, metavar="PATH",
                        help="调试用小清单：只处理清单内标的（严格模式，缺任一即失败）；"
                             "统一按 file 语义解析（含 '#' 当 file，纯 6 位代码自动补前缀）")
    parser.add_argument("--out", default=".", help="输出目录（含全部分片 + manifest）")
    parser.add_argument("--prev", default=None, metavar="DIR",
                        help="上一版分片目录（workflow 会把 data 分支 checkout 到这里）；"
                             "为空/无分片则视为首次发布")
    parser.add_argument("--force", action="store_true",
                        help="即使判定'无变化'也强制重写 manifest 与 .changed（本地调试用）")
    parser.add_argument("--offline", action="store_true",
                        help="不联网，用内置合成数据（manifest.source=offline）")
    parser.add_argument("--backfill-days", dest="backfill_days", type=int, default=0, metavar="N",
                        help="【一次性缺口回补】为可映射标的（SH#/SZ#/BJ#）逐只拉最近 N 根日线，"
                             "补出这些天的日分片（与日常分片同构）；0=关闭（默认）。"
                             "**这不是日常路径**：只用于补齐主库停更造成的历史缺口，手动跑一次即可。")
    parser.add_argument("--workers", type=int, default=BACKFILL_WORKERS_DEFAULT,
                        help="回补并发数（默认 %d，上限 %d）。总速率仍由全局限速压在约 %.0f 请求/秒，"
                             "并发只影响等待时是否空转"
                             % (BACKFILL_WORKERS_DEFAULT, BACKFILL_WORKERS_MAX, 1.0 / MIN_REQUEST_INTERVAL))
    parser.add_argument("--limit-symbols", dest="limit_symbols", type=int, default=None, metavar="N",
                        help="【仅调试用】回补时只处理前 N 只可映射标的，生产不要传")
    parser.add_argument("--check", action="store_true",
                        help="只读产物并打印校验报告，不重新生成")
    parser.add_argument("--now-date", dest="now_date", default=None, metavar="YYYYMMDD",
                        help="覆盖\"本机当天\"的认知（仅测试/手动补跑）。它只影响 --offline 的"
                             "日期标签与取数窗口；**不能伪造交易日**：联网写入的当日K线日期"
                             "始终取自行情源的 f124（北京时间）")
    args = parser.parse_args(argv)

    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)

    if args.check:
        return run_check(out_dir)

    if args.now_date:
        try:
            now_date = datetime.datetime.strptime(args.now_date.strip(), "%Y%m%d").date()
        except ValueError:
            raise SystemExit("--now-date 格式应为 YYYYMMDD，例如 --now-date 20261001")
    else:
        now_date = datetime.date.today()
    print("本机日期(now_date)=%s  输出目录=%s" % (now_date.strftime("%Y%m%d"), out_dir))

    # 残留临时文件先清掉（上次异常中断可能留下）
    for stale in glob.glob(os.path.join(out_dir, BUCKET_PREFIX + "*.db.tmp")):
        os.remove(stale)

    if args.symbols:
        entries = parse_symbols(args.symbols)
        print("小清单模式(调试): %s -> %d 个 file" % (args.symbols, len(entries)))
    else:
        entries = parse_universe(args.universe)
        unmappable = [e for e in entries if not e["secid"]]
        print("清单: %s -> %d 个 file（可映射 %d，扩展行情等不可映射 %d）"
              % (args.universe, len(entries), len(entries) - len(unmappable), len(unmappable)))
    universe = len(entries)
    meta_rows = [(e["file"], e["code"], e["name"], e["type"]) for e in entries]

    prev = read_prev_buckets(args.prev)
    prev_max_date = max((d for bars in prev["daily"].values() for d in bars), default=None)

    # ---- 取得日线（三条互斥路径：回补 / offline / 日常快照）----
    workers = min(max(1, args.workers), BACKFILL_WORKERS_MAX)
    fetched_failed, applied, session_dates, today_bar = [], [], [], {}
    extra_ids = set()          # 本次运行"新产出"的日期分片（日常只有当天；回补/offline 多天）
    if args.backfill_days > 0 and not args.offline:
        # ---- 一次性缺口回补（**不是日常路径**，只在补历史缺口时手动跑一次）----
        source = "eastmoney_backfill"
        bf = backfill_mappable(entries, args.backfill_days, workers, args.limit_symbols)
        # 与 --prev 的旧分片合并：同 file+date 以回补到的新数据为准
        daily_by_file = {f: dict(bars) for f, bars in prev["daily"].items()}
        added = updated = 0
        for f, bars in bf["daily"].items():
            tgt = daily_by_file.setdefault(f, {})
            for d, bar in bars.items():
                if d in tgt:
                    updated += 1
                else:
                    added += 1
                tgt[d] = bar
        fetched_failed = bf["failed"]
        all_dates = {d for bars in daily_by_file.values() for d in bars}
        if not all_dates:
            raise SystemExit("回补未取到任何日线，放弃生成（保留上一版产物）")
        trade_date = max(all_dates)
        covered_files = sorted(bf["daily"])
        extra_ids = {bucket_id_for_date(d) for bars in bf["daily"].values() for d in bars}
        print("缺口回补完成: 新增 %d 根K线 / 覆盖同 file+date %d 根，耗时 %.1fs（实际约 %.2f 请求/秒，"
              "成功 %d / 失败 %d）；补出的交易日 %s ~ %s"
              % (added, updated, bf["elapsed"],
                 (len(bf["ok"]) + len(bf["failed"])) / max(0.001, bf["elapsed"]),
                 len(bf["ok"]), len(bf["failed"]),
                 min(d for bars in bf["daily"].values() for d in bars),
                 max(d for bars in bf["daily"].values() for d in bars)))
    elif args.offline:
        daily_by_file = _offline_daily(entries, now_date, KEEP_BUCKETS)
        trade_date = date_to_int(now_date)
        source = "offline"
        covered_files = sorted(daily_by_file)
        # offline 额外把合成的每个交易日各自成片，模拟"已经按天积累了 N 片"，
        # 便于在无网络时联调多分片结构 / 30 片保留 / 周期聚合。
        extra_ids = {bucket_id_for_date(d) for bars in daily_by_file.values() for d in bars}
        print("[info] offline：合成 %d 个交易日的日线（每只 %d 根）" % (KEEP_BUCKETS, KEEP_BUCKETS))
    else:
        source = "eastmoney"
        secids = [e["secid"] for e in entries if e["secid"]]
        print("批量快照: 请求 %d 个 secid（每批 %d -> 约 %d 次请求）"
              % (len(secids), ULIST_BATCH, (len(secids) + ULIST_BATCH - 1) // ULIST_BATCH))
        snapshot = fetch_snapshot(secids)
        print("批量快照: 命中 %d 只" % len(snapshot))
        # 从上一版分片继承日线窗口（滚动增量的基线）
        daily_by_file = {f: dict(bars) for f, bars in prev["daily"].items()}
        if prev_max_date is None:
            print("[info] 首次发布：窗口内暂无历史分片，仅产出当天这一片")
        for e in entries:
            if not e["secid"]:
                continue        # 不可映射（27#/62#/102#）→ 计入 coverage/missing_sample
            snap = snapshot.get(e["secid"])
            if not snap or snap.get("close") is None:
                fetched_failed.append(e["file"])
                continue
            if None in (snap["open"], snap["high"], snap["low"]):
                fetched_failed.append(e["file"])          # 停牌/非交易时段返回 '-'
                continue
            # 交易日判定：① 快照 f124 的北京时间日期 → ② 现有分片里的最新交易日
            sess = beijing_date_from_ts(snap.get("ts")) or prev_max_date
            if sess is None:
                fetched_failed.append(e["file"])
                continue
            bar = {"date": sess, "open": snap["open"], "high": snap["high"], "low": snap["low"],
                   "close": snap["close"], "vol": snap["vol"] or 0.0, "amo": snap["amo"] or 0.0}
            bars = daily_by_file.setdefault(e["file"], {})
            last = max(bars) if bars else None
            if last is not None and sess < last:
                # 快照比已有历史还旧（延迟/停牌残留），忽略，避免回填陈旧数值
                fetched_failed.append(e["file"])
                continue
            bars[sess] = bar
            applied.append(e["file"])
            session_dates.append(sess)
            today_bar[e["file"]] = bar
        if not applied:
            raise SystemExit("批量快照未取到任何可用K线，放弃生成（保留上一版产物）")
        trade_date = max(session_dates)
        covered_files = sorted(today_bar)
        extra_ids = {bucket_id_for_date(trade_date)}       # 日常路径只产出"当天那一片"
        print("交易日(trade_date)=%s  取到当日K线的 file=%d" % (trade_date, len(applied)))

    # ---- 覆盖率：分母是 universe 全量（含云端结构上覆盖不到的扩展行情指数）----
    uncovered = [e for e in entries if e["file"] not in set(covered_files)]
    unmappable = [e["file"] for e in entries if not e["secid"]]
    missing_sample = fetched_failed[:20]
    if len(missing_sample) < 20:
        missing_sample += [f for f in unmappable if f not in missing_sample][:20 - len(missing_sample)]
    coverage = len(covered_files) / float(universe)
    print("覆盖率: %d/%d = %.4f   （取数失败 %d 只、不可映射(扩展行情) %d 只）"
          % (len(covered_files), universe, coverage, len(fetched_failed), len(unmappable)))
    if unmappable or fetched_failed:
        print("  未覆盖样例: %s" % (", ".join(missing_sample[:12]) or "无"))
    if unmappable:
        # 这 299 只在公开行情接口里没有对应 secid，**云端任何模式都补不上**（含 --backfill-days）
        print("  [说明] %d 只扩展行情指数（27#/62#/102# 前缀：恒生/行业/主题指数）云端无法覆盖，"
              "需由电脑侧生产者 build_live_buckets_pc.py 覆盖" % len(unmappable))
    if args.symbols and uncovered:
        # 小清单模式（调试）保持严格：缺任一即失败
        raise SystemExit("小清单模式取数不完整，放弃生成（保留原有产物）。缺失: %s"
                         % ", ".join(e["file"] for e in uncovered))
    if args.limit_symbols:
        # 调试开关：只处理了前 N 只，覆盖率必然很低，此时跳过门槛（生产不要传这个参数）
        print("  [调试] 已用 --limit-symbols=%d 限制标的数，跳过覆盖率门槛（%.4f < %.2f）"
              % (args.limit_symbols, coverage, MIN_COVERAGE))
    elif coverage < MIN_COVERAGE:
        raise SystemExit("覆盖率 %.4f < %.2f，放弃生成（保留上一版分片）"
                         % (coverage, MIN_COVERAGE))

    # ---- 保留最近 30 片（按日期新→旧）----
    # extra_ids = 本次运行新产出的日期分片：日常路径只有"当天那一片"；
    # --backfill-days / --offline 会一次产出多天（回补本来就是多天），仍按最新 30 片裁剪。
    ids = set(prev["ids"]) | extra_ids
    kept = sorted(ids, reverse=True)[:KEEP_BUCKETS]
    window_start = date_for_bucket(min(kept))
    window_end = trade_date
    print("保留分片: %s（共 %d 片）  窗口 %s ~ %s"
          % (", ".join(str(b) for b in kept), len(kept), window_start, window_end))

    # ---- 切分 + 逐片落盘（周/月线按"周期首日"落片，见 build_slots 注释）----
    slots = build_slots(daily_by_file, kept, meta_rows, window_start, window_end)
    kept = [bid for bid in kept if bid in slots]
    if not kept:
        raise SystemExit("没有任何非空分片，放弃生成（保留原有产物）")
    generated_at = int(time.time())
    emitted = emit_buckets(out_dir, slots, kept, prev["files"], prev["shas"])
    manifest_buckets, rewritten = emitted["buckets"], emitted["rewritten"]
    changed = (prev["manifest"] is None) or emitted["changed"]

    manifest = {
        "schema": MANIFEST_SCHEMA,
        "generated_at": generated_at,
        "trade_date": trade_date,
        "source": source,
        "universe": universe,
        "covered": len(covered_files),
        "coverage": round(coverage, 6),
        "missing_sample": missing_sample,
        "latest_bucket": bucket_id_for_date(trade_date),
        "keep_buckets": KEEP_BUCKETS,
        "buckets": manifest_buckets,                 # 已按 id 从新到旧
    }
    mf_path = os.path.join(out_dir, MANIFEST_NAME)

    # ---- 空跑检测：无新增K线且逐片 sha256 与上一版一致 -> 跳过发布（退出码 0）----
    no_change = (not changed) and not args.force
    if no_change:
        if not os.path.exists(mf_path) and prev["manifest"]:
            for cand in (args.prev or "", os.path.join(args.prev or "", "live")):
                pm = os.path.join(cand, MANIFEST_NAME)
                if os.path.exists(pm):
                    shutil.copyfile(pm, mf_path)
                    break
        print("无变化，跳过发布（%d 片内容与上一版逐片 sha256 一致）" % len(manifest_buckets))
    else:
        write_manifest_atomic(mf_path, manifest)
        print("已生成: %s (schema=%d source=%s trade_date=%s)"
              % (mf_path, MANIFEST_SCHEMA, source, trade_date))

    flag_path = os.path.join(out_dir, CHANGED_FLAG_NAME)
    with open(flag_path, "w", encoding="utf-8") as fh:
        fh.write("1\n" if (changed or args.force) else "0\n")

    total_bytes = sum(b["bytes"] for b in manifest_buckets)
    print("分片数=%d  总字节=%d (%.3f MB)  平均每片 %.1f KB  重写 %d 片"
          % (len(manifest_buckets), total_bytes, total_bytes / 1048576.0,
             total_bytes / max(1, len(manifest_buckets)) / 1024.0, len(rewritten)))
    print("覆盖率=%d/%d=%.4f  变化标记=%s"
          % (len(covered_files), universe, coverage,
             "1（需发布）" if (changed or args.force) else "0（无变化）"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
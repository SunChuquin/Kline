#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tdx_live 增量库生成器（仅 Python 标准库，不依赖任何第三方包）

背景
----
Kline 主库 Documents/tdx.db 体积巨大（1GB+，全市场历史K线），App 侧不允许改动。
"自动盯盘"改为另建增量库 Documents/tdx_live.db：只收录关注清单（并集）内标的的
最近 N 根多周期K线，每日由云端/电脑产出后推给 App 热加载叠加读取。

产出
----
    <out>/tdx_live.db            增量库（6 张表，以 code 为键，与主库自增 meta_id 解耦）
    <out>/tdx_live.manifest.json 清单（版本、行数、日期范围、sha256）

设计取舍（重点）
----------------
1. 字段顺序：东财 kline 接口 fields2=f51..f57 返回的顺序是
   **日期, 开, 收, 高, 低, 成交量, 成交额**（即 开/收/高/低，不是常见的 OHLC）。
   本脚本在 `_parse_kline_line()` 里按此顺序映射，切勿按 OHLC 写。
2. secid：沪市 6/5/9 开头 = `1.<code>`，深市 0/3/1 开头 = `0.<code>`；
   指数需内置表修正（如 999999 -> 1.000001）。清单中显式 `secid=` 优先级最高。
3. 批量取数：本应避免逐标的数千次请求。实测 `clist/get?...&pz=100`
   仅返回按代码排序的 100 行（且分页上限约 100 行/页），无法命中自定义的小清单；
   因此主快照改用东财 **批量报价接口 `ulist.np/get?secids=a,b,c`**，一次请求即可
   覆盖整份清单（含指数）。`clist/get` 保留为兜底实现（见 `fetch_snapshot`）。
   注意：ulist 返回体里指数 999999 的 f12='000001'、f13=1，与深市平安银行
   (f13=0,f12='000001') 冲突，故快照结果一律以 **`f13.f12`（secid）为键**。
4. 限速与重试：全局最小请求间隔 0.25s，失败按 0.5s 起的指数退避重试 4 次（≥3）。
5. 周期聚合：日线来自接口；周/月/季/年线由日线**本地聚合**
   （周=ISO 周、月=自然月、季=自然季、年=自然年）。
   每根周期K线：open=首根 open、high=最大 high、low=最小 low、close=末根 close、
   vol/amo=求和、date=该周期**最后一根日线的日期**。
   —— 需要注意：周期线只由"最近 N 根日线"聚合而来，是滚动窗口而非全历史。
6. 原子写入：db 与 manifest 都先写临时文件，校验通过后再 os.replace，
   任一步失败都不会覆盖已有产物。主库只读打开（uri `mode=ro`），绝不写入。

用法
----
    python src/live_db_builder.py --out <dir>
    python src/live_db_builder.py --out <dir> --check
    python src/live_db_builder.py --out <dir> --offline          # 合成数据，无需联网
    python src/live_db_builder.py --out <dir> --from-master-db tdx.db
"""

import argparse
import datetime
import hashlib
import json
import os
import sqlite3
import sys
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

SNAPSHOT_ULIST_URL = ("https://push2.eastmoney.com/api/qt/ulist.np/get"
                      "?fltt=2&invt=2&np=1&fields=f12,f13,f14,f2,f5,f6,f15,f16,f17,f18"
                      "&secids={secids}")
# 兜底用：任务给定的全市场批量接口（实测每页约 100 行、需分页，故仅作兜底）
SNAPSHOT_CLIST_URL = ("https://push2.eastmoney.com/api/qt/clist/get"
                      "?pn=1&pz=100&po=1&np=1&fltt=2&invt=2&fid=f12"
                      "&fs={fs}&fields=f12,f13,f14,f2,f5,f6,f15,f16,f17,f18")
CLIST_FS_DEFAULT = "m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23"   # 深A/创业板/沪A/科创板
CLIST_FS_INDEX = "m:1+s:2,m:0+s:2"                       # 沪深指数

KLINE_URL = ("https://push2his.eastmoney.com/api/qt/stock/kline/get"
             "?secid={secid}&klt=101&fqt=1&beg={beg}&end=20500101&lmt={lmt}"
             "&fields1=f1,f2,f3,f4,f5,f6&fields2=f51,f52,f53,f54,f55,f56,f57")
# fqt=1 前复权：与 App 主库(通达信前复权)口径一致；老数据可能出现负价，见下。

# 内置指数 secid 表（清单未显式写 secid= 时优先命中本表）
INDEX_SECID = {
    "999999": "1.000001",   # 上证指数（通达信口径 999999 == 东财 000001.SH）
    "399001": "0.399001",   # 深证成指
    "399006": "0.399006",   # 创业板指
    "399005": "0.399005",   # 中小100
    "000300": "1.000300",   # 沪深300
    "000905": "1.000905",   # 中证500
    "000016": "1.000016",   # 上证50
}

PERIODS = ("daily", "weekly", "monthly", "quarterly", "yearly")
DB_NAME = "tdx_live.db"
MANIFEST_NAME = "tdx_live.manifest.json"

MIN_REQUEST_INTERVAL = 0.25   # 限速：任两次请求最小间隔(秒)
REQUEST_RETRIES = 4           # 含首次共 4 次尝试（≥3 次重试要求满足）
REQUEST_TIMEOUT = 20

_last_request_ts = 0.0


# ---------------------------------------------------------------------------
# 清单解析
# ---------------------------------------------------------------------------

def parse_symbols(path):
    """解析关注清单。返回 [{code, secid, note}]，保持文件内顺序并去重。"""
    if not os.path.exists(path):
        raise SystemExit("清单文件不存在: %s" % path)
    out, seen = [], set()
    # utf-8-sig：兼容 Windows 编辑器写入的 UTF-8 BOM，否则首个代码会被读成 '\ufeff600519'
    with open(path, "r", encoding="utf-8-sig") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            # 允许行内以 # 追加备注
            body = line.split("#", 1)[0].strip()
            if not body:
                continue
            tokens = body.split()
            code = tokens[0]
            if not (len(code) == 6 and code.isdigit()):
                print("[warn] 第 %d 行忽略非法代码: %r" % (lineno, code), file=sys.stderr)
                continue
            explicit = None
            note = ""
            for tok in tokens[1:]:
                if tok.startswith("secid="):
                    explicit = tok.split("=", 1)[1].strip()
                elif not note:
                    note = tok
            if code in seen:
                print("[warn] 第 %d 行重复代码 %s，已忽略" % (lineno, code), file=sys.stderr)
                continue
            seen.add(code)
            out.append({"code": code, "secid": resolve_secid(code, explicit), "note": note})
    if not out:
        raise SystemExit("清单为空: %s" % path)
    return out


def resolve_secid(code, explicit=None):
    """secid 推导：显式 > 内置指数表 > 市场前缀规则。"""
    if explicit:
        return explicit
    if code in INDEX_SECID:
        return INDEX_SECID[code]
    if code[0] in ("6", "5", "9"):
        return "1." + code          # 沪市
    return "0." + code              # 深市（0/3/1 开头）


def symbol_type(code, raw_type=None, name=None):
    """归类写库用的 type 文案：'指数' / '股票'。"""
    if raw_type and "指数" in str(raw_type):
        return "指数"
    if code in INDEX_SECID:
        return "指数"
    if name and ("指数" in name or "指" == name[-1:]):
        return "指数"
    return "股票"


# ---------------------------------------------------------------------------
# HTTP：限速 + 指数退避重试
# ---------------------------------------------------------------------------

def _throttle():
    global _last_request_ts
    delta = time.monotonic() - _last_request_ts
    if delta < MIN_REQUEST_INTERVAL:
        time.sleep(MIN_REQUEST_INTERVAL - delta)
    _last_request_ts = time.monotonic()


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


# ---------------------------------------------------------------------------
# 取数：批量快照（当日这根K线）
# ---------------------------------------------------------------------------

def _snapshot_from_diff(diff):
    res = {}
    for it in diff or []:
        f12, f13 = it.get("f12"), it.get("f13")
        if not f12 or f13 is None:
            continue
        o, h, l, c = (_num(it.get("f17")), _num(it.get("f15")),
                      _num(it.get("f16")), _num(it.get("f2")))
        res["%s.%s" % (f13, f12)] = {
            "secid": "%s.%s" % (f13, f12),
            "code": f12,
            "name": (it.get("f14") or "").strip(),
            "open": o, "high": h, "low": l, "close": c,
            "vol": _num(it.get("f5")), "amo": _num(it.get("f6")),
        }
    return res


def fetch_snapshot(secids):
    """批量快照。主路径 ulist.np/get（一次请求覆盖整份清单，含指数）；
    缺失项再用任务给定的 clist/get 兜底。返回 {secid: 1根日线字段}。"""
    secids = list(dict.fromkeys(secids))
    result = {}
    if not secids:
        return result
    try:
        data = http_get_json(SNAPSHOT_ULIST_URL.format(secids=",".join(secids)))
        result.update(_snapshot_from_diff((data.get("data") or {}).get("diff")))
    except Exception as exc:
        print("[warn] ulist 批量快照失败，转 clist 兜底: %s" % exc, file=sys.stderr)

    missing = [s for s in secids if s not in result]
    # 兜底仅在 ulist 整体不可用时启用：clist 是"全市场按页拉取"(实测约 100 行/页，
    # 需翻页数十次) 且无法按代码定向查询，对个别标的缺失无能为力，逐页扫描得不偿失。
    if missing and not result:
        print("[warn] ulist 无任何返回，启用 clist 兜底分页拉取", file=sys.stderr)
        try:
            for fs in (CLIST_FS_DEFAULT, CLIST_FS_INDEX):
                for pn in range(1, 61):
                    url = SNAPSHOT_CLIST_URL.format(fs=fs, pn=pn)
                    data = http_get_json(url)
                    diff = (data.get("data") or {}).get("diff") or []
                    if not diff:
                        break
                    result.update(_snapshot_from_diff(diff))
                    # 注意：fid=f12 升序分页，diff 内代码不连续，只能扫完整组
                if all(s in result for s in secids):
                    break
        except Exception as exc:
            print("[warn] clist 兜底快照失败: %s" % exc, file=sys.stderr)
    return result


# ---------------------------------------------------------------------------
# 取数：单标的日线历史
# ---------------------------------------------------------------------------

def _parse_kline_line(line):
    """解析 '2026-09-22,开,收,高,低,量,额' -> dict。
    ⚠ 东财顺序是 开,收,高,低（不是 OHLC），见模块 docstring。"""
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


def fetch_daily_history(secid, limit):
    """拉取最近 limit 根日线。beg 取足够宽的日历窗口，再按需截断。"""
    days_back = max(120, limit * 3 + 60)
    beg = (datetime.date.today() - datetime.timedelta(days=days_back)).strftime("%Y%m%d")
    data = http_get_json(KLINE_URL.format(secid=secid, beg=beg, lmt=limit))
    payload = data.get("data") or {}
    bars = []
    for line in payload.get("klines") or []:
        bar = _parse_kline_line(line)
        if bar:
            bars.append(bar)
    bars.sort(key=lambda b: b["date"])
    return (payload.get("name") or "").strip(), bars[-limit:]


# ---------------------------------------------------------------------------
# 本地合成数据（--offline，仅用于联调/CI 结构校验）
# ---------------------------------------------------------------------------

def _prng(seed_text):
    """由 hashlib 派生的确定性伪随机数发生器（64bit LCG），保证离线结果可复现。"""
    state = int.from_bytes(hashlib.sha256(seed_text.encode("utf-8")).digest()[:8], "big")

    def nxt():
        nonlocal state
        state = (state * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        return state

    return nxt


def synth_daily(code, limit, trade_date):
    """按 code 生成确定性的合成日线（含周末跳过），价格量级与标的类型大致相符。"""
    rnd = _prng("kline-live:" + code)
    is_index = code in INDEX_SECID
    price = (3000.0 if is_index else 10.0) + (rnd() % 500) / 10.0
    # 先排出最近 limit 个"交易日"（简单跳过周末，不打节假日表）
    if isinstance(trade_date, int):
        trade_date = datetime.date(trade_date // 10000, trade_date // 100 % 100,
                                   trade_date % 100)
    dates, d = [], trade_date
    while len(dates) < limit:
        if d.weekday() < 5:
            dates.append(d)
        d -= datetime.timedelta(days=1)
    dates.reverse()
    bars = []
    for dt in dates:
        change = ((rnd() % 2001) - 1000) / 10000.0        # ±10%
        prev = price
        price = max(0.5, round(prev * (1 + change), 2))
        o = round(prev, 2)
        c = round(price, 2)
        h = round(max(o, c) * (1 + (rnd() % 100) / 5000.0), 2)
        l = round(min(o, c) * (1 - (rnd() % 100) / 5000.0), 2)
        vol = float(100000 + rnd() % 5000000)
        bars.append({"date": int(dt.strftime("%Y%m%d")), "open": o, "high": h,
                     "low": l, "close": c, "vol": vol, "amo": round(vol * c, 2)})
    return bars


# ---------------------------------------------------------------------------
# 周期聚合
# ---------------------------------------------------------------------------

def _period_key(date_int, period):
    y, m, d = date_int // 10000, date_int // 100 % 100, date_int % 100
    dt = datetime.date(y, m, d)
    if period == "weekly":
        iso = dt.isocalendar()
        return (iso[0], iso[1])          # ISO 年 + ISO 周
    if period == "monthly":
        return (y, m)                    # 自然月
    if period == "quarterly":
        return (y, (m - 1) // 3 + 1)     # 自然季
    return (y,)                          # 自然年


def aggregate(daily_bars, period):
    """由升序日线聚合出周期K线。date 取该周期最后一根日线的日期。"""
    groups = {}
    order = []
    for b in sorted(daily_bars, key=lambda x: x["date"]):
        key = _period_key(b["date"], period)
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(b)
    out = []
    for key in order:
        bs = groups[key]
        out.append({
            "date": bs[-1]["date"],
            "open": bs[0]["open"],
            "high": max(x["high"] for x in bs),
            "low": min(x["low"] for x in bs),
            "close": bs[-1]["close"],
            "vol": sum(x["vol"] for x in bs),
            "amo": sum(x["amo"] for x in bs),
        })
    return out


# ---------------------------------------------------------------------------
# 数据源：主库（只读兜底）
# ---------------------------------------------------------------------------

def load_from_master_db(master_path, symbols, limit, trade_date):
    """从本地主库 tdx.db 抽取清单内标的的最近 limit 根日线。
    主库以只读方式打开（uri mode=ro），绝不写入。
    注意：主库是 WAL 日志模式，即便只读打开，SQLite 也可能在主库旁生成
    `tdx.db-shm` / `tdx.db-wal`（空 wal + 共享内存索引）；这是读侧副作用，
    主库文件本身不会被改写（实测 sha256 与 mtime 均不变）。"""
    if not os.path.exists(master_path):
        raise SystemExit("主库不存在: %s" % master_path)
    uri = "file:%s?mode=ro" % master_path.replace("\\", "/").replace("?", "%3f").replace("#", "%23")
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row
    records = []
    try:
        for sym in symbols:
            row = conn.execute(
                "SELECT id, code, name, type FROM meta WHERE code=? ORDER BY last_date DESC LIMIT 1",
                (sym["code"],)).fetchone()
            if row is None:
                print("[warn] 主库无此代码，跳过: %s" % sym["code"], file=sys.stderr)
                continue
            bars = []
            for r in conn.execute(
                    "SELECT date, open, high, low, close, vol, amo FROM daily "
                    "WHERE meta_id=? ORDER BY date DESC LIMIT ?", (row["id"], limit)):
                bars.append({"date": int(r["date"]), "open": float(r["open"]),
                             "high": float(r["high"]), "low": float(r["low"]),
                             "close": float(r["close"]), "vol": float(r["vol"] or 0),
                             "amo": float(r["amo"] or 0)})
            bars.reverse()
            if not bars:
                print("[warn] 主库标的无日线，跳过: %s" % sym["code"], file=sys.stderr)
                continue
            records.append({
                "code": sym["code"], "secid": sym["secid"],
                "name": row["name"] or sym["code"],
                "type": symbol_type(sym["code"], row["type"], row["name"]),
                "bars": bars,
            })
    finally:
        conn.close()
    return records


# ---------------------------------------------------------------------------
# 组装记录
# ---------------------------------------------------------------------------

def collect_records(args, symbols, trade_date):
    """返回 [{code,name,type,bars(daily,升序)}]，source 由 args 决定。"""
    if args.from_master_db:
        return load_from_master_db(args.from_master_db, symbols, args.limit, trade_date), "master_db"

    if args.offline:
        recs = []
        for sym in symbols:
            bars = synth_daily(sym["code"], args.limit, trade_date)
            recs.append({"code": sym["code"], "secid": sym["secid"], "name": sym["code"],
                         "type": symbol_type(sym["code"], None, None), "bars": bars})
        return recs, "offline"

    # 联网：先批量快照拿到"当日这根K线"与名称，再逐标的补齐历史
    snapshot = fetch_snapshot([s["secid"] for s in symbols])
    recs, missing = [], []
    for sym in symbols:
        try:
            name, bars = fetch_daily_history(sym["secid"], args.limit)
        except Exception as exc:
            print("[warn] %s(%s) 日线拉取失败: %s" % (sym["code"], sym["secid"], exc), file=sys.stderr)
            bars, name = [], ""
        snap = snapshot.get(sym["secid"])
        if snap and snap.get("close") is not None:
            today_bar = {"date": int(trade_date), "open": snap["open"], "high": snap["high"],
                         "low": snap["low"], "close": snap["close"],
                         "vol": snap["vol"] or 0.0, "amo": snap["amo"] or 0.0}
            # 与历史里同一天的行做覆盖（快照为盘中最新值），保证当日只有一根
            bars = [b for b in bars if b["date"] != today_bar["date"]]
            if None not in (today_bar["open"], today_bar["high"], today_bar["low"]):
                bars.append(today_bar)
                bars.sort(key=lambda b: b["date"])
            bars = bars[-args.limit:]
        if not bars:
            print("[warn] %s(%s) 无可用日线" % (sym["code"], sym["secid"]), file=sys.stderr)
            missing.append(sym["code"])
            continue
        final_name = (snap or {}).get("name") or name or sym["code"]
        recs.append({"code": sym["code"], "secid": sym["secid"], "name": final_name,
                     "type": symbol_type(sym["code"], None, final_name), "bars": bars})
    # 生产路径（联网）要求 100% 覆盖：清单内任一标的取不到数据即整体失败，
    # 不产出一个"悄悄缺标的"的增量库。--offline / --from-master-db 属联调与
    # 电脑兜底场景，主库本身可能只含部分标的，故只告警不阻断。
    if missing:
        raise SystemExit("联网取数不完整，放弃生成（保留原有产物）。缺失: %s" % ", ".join(missing))
    return recs, "eastmoney"


# ---------------------------------------------------------------------------
# 写库 + 校验（临时文件 -> 原子替换）
# ---------------------------------------------------------------------------

DDL = """
CREATE TABLE {tbl}(code TEXT, date INTEGER, open REAL, high REAL, low REAL,
                   close REAL, vol REAL, amo REAL, PRIMARY KEY(code, date));
"""


def build_db(tmp_db_path, records, trade_date, generated_at):
    """写临时库文件。返回 {table: row_count} 与统计信息。"""
    if os.path.exists(tmp_db_path):
        os.remove(tmp_db_path)
    conn = sqlite3.connect(tmp_db_path)
    try:
        conn.execute("PRAGMA journal_mode=DELETE;")
        conn.execute("""CREATE TABLE live_meta(code TEXT PRIMARY KEY, name TEXT,
                        type TEXT, updated_at INTEGER);""")
        for tbl in PERIODS:
            conn.execute(DDL.format(tbl="live_" + tbl))

        rows = {p: 0 for p in PERIODS}
        all_dates = []
        for rec in records:
            conn.execute("INSERT OR REPLACE INTO live_meta(code,name,type,updated_at) "
                         "VALUES(?,?,?,?)",
                         (rec["code"], rec["name"], rec["type"], generated_at))
            for period in PERIODS:
                bars = rec["bars"] if period == "daily" else aggregate(rec["bars"], period)
                if bars:
                    conn.executemany(
                        "INSERT OR REPLACE INTO live_%s(code,date,open,high,low,close,vol,amo)"
                        " VALUES(?,?,?,?,?,?,?,?)" % period,
                        [(rec["code"], b["date"], b["open"], b["high"], b["low"],
                          b["close"], b["vol"], b["amo"]) for b in bars])
                rows[period] += len(bars)
                if period == "daily":
                    all_dates.extend(b["date"] for b in bars)
        conn.commit()
    finally:
        conn.close()

    stats = {
        "rows": rows,
        "symbols": len(records),
        "min_date": min(all_dates) if all_dates else None,
        "max_date": max(all_dates) if all_dates else None,
    }
    return stats


def validate_db(db_path, records, stats):
    """写入前的硬校验：清单内每个 code 都在 live_meta 且至少 1 根日线；
    各周期表行数与真实 count 一致；manifest 声明与实际一致。失败即抛异常。"""
    conn = sqlite3.connect("file:%s?mode=ro" % db_path.replace("\\", "/"), uri=True)
    try:
        codes_in_db = {r[0] for r in conn.execute("SELECT code FROM live_meta")}
        problems = []
        for rec in records:
            if rec["code"] not in codes_in_db:
                problems.append("live_meta 缺少 code=%s" % rec["code"])
                continue
            n = conn.execute("SELECT COUNT(*) FROM live_daily WHERE code=?",
                             (rec["code"],)).fetchone()[0]
            if n < 1:
                problems.append("live_daily 缺少 code=%s 的日线" % rec["code"])
        real_counts = {}
        for period in PERIODS:
            real_counts[period] = conn.execute(
                "SELECT COUNT(*) FROM live_%s" % period).fetchone()[0]
        for period in PERIODS:
            if real_counts[period] != stats["rows"][period]:
                problems.append("live_%s 行数不一致: 实际 %d / 声明 %d"
                                % (period, real_counts[period], stats["rows"][period]))
        real_min, real_max = conn.execute(
            "SELECT MIN(date), MAX(date) FROM live_daily").fetchone()
        if real_min != stats["min_date"] or real_max != stats["max_date"]:
            problems.append("日期范围不一致: 实际 %s~%s / 声明 %s~%s"
                            % (real_min, real_max, stats["min_date"], stats["max_date"]))
        if problems:
            raise AssertionError("增量库校验失败:\n  - " + "\n  - ".join(problems))
    finally:
        conn.close()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def next_version(manifest_path):
    """version 每次生成自增：同名 manifest 已存在则 +1，否则 1。"""
    if os.path.exists(manifest_path):
        try:
            with open(manifest_path, "r", encoding="utf-8") as fh:
                return int(json.load(fh).get("version", 0)) + 1
        except Exception:
            return 1
    return 1


def write_manifest_atomic(manifest_path, payload):
    tmp = manifest_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, manifest_path)


# ---------------------------------------------------------------------------
# --check 校验报告
# ---------------------------------------------------------------------------

def run_check(out_dir, symbols_path):
    db_path = os.path.join(out_dir, DB_NAME)
    mf_path = os.path.join(out_dir, MANIFEST_NAME)
    if not os.path.exists(db_path):
        raise SystemExit("未找到产物: %s" % db_path)
    print("=" * 74)
    print("tdx_live 增量库校验报告")
    print("=" * 74)
    print("库文件   : %s" % db_path)
    print("文件体积 : %d 字节 (%.1f KB)" % (os.path.getsize(db_path),
                                            os.path.getsize(db_path) / 1024.0))

    manifest = None
    if os.path.exists(mf_path):
        with open(mf_path, "r", encoding="utf-8") as fh:
            manifest = json.load(fh)
        print("manifest : %s (version=%s, source=%s)" % (mf_path, manifest.get("version"),
                                                         manifest.get("source")))
    else:
        print("manifest : 缺失!")

    conn = sqlite3.connect("file:%s?mode=ro" % db_path.replace("\\", "/"), uri=True)
    try:
        print("-" * 74)
        print("各表行数:")
        counts = {}
        for tbl in ("live_meta",) + tuple("live_" + p for p in PERIODS):
            counts[tbl] = conn.execute("SELECT COUNT(*) FROM %s" % tbl).fetchone()[0]
            print("  %-16s %6d" % (tbl, counts[tbl]))

        print("-" * 74)
        print("每标的 min/max 日期 (daily):")
        codes = [r[0] for r in conn.execute("SELECT code FROM live_meta ORDER BY code")]
        for code in codes:
            mn, mx, n = conn.execute(
                "SELECT MIN(date), MAX(date), COUNT(*) FROM live_daily WHERE code=?",
                (code,)).fetchone()
            name = conn.execute("SELECT name FROM live_meta WHERE code=?", (code,)).fetchone()[0]
            print("  %-8s %-10s n=%-3d %s ~ %s" % (code, (name or "")[:10], n, mn, mx))

        coverage_ok = True
        if manifest:
            print("-" * 74)
            print("manifest 一致性:")
            declared = manifest.get("rows") or {}
            for period in PERIODS:
                actual = counts["live_" + period]
                want = declared.get(period)
                ok = (want == actual)
                coverage_ok &= ok
                print("  rows.%-10s 声明=%-6s 实际=%-6d %s"
                      % (period, want, actual, "OK" if ok else "不一致!"))
            sym_ok = manifest.get("symbols") == counts["live_meta"]
            coverage_ok &= sym_ok
            print("  symbols      声明=%-6s 实际=%-6d %s"
                  % (manifest.get("symbols"), counts["live_meta"], "OK" if sym_ok else "不一致!"))
            mn, mx = conn.execute("SELECT MIN(date), MAX(date) FROM live_daily").fetchone()
            print("  min_date     声明=%-8s 实际=%-8s %s"
                  % (manifest.get("min_date"), mn, "OK" if manifest.get("min_date") == mn else "不一致!"))
            print("  max_date     声明=%-8s 实际=%-8s %s"
                  % (manifest.get("max_date"), mx, "OK" if manifest.get("max_date") == mx else "不一致!"))
            digest = sha256_file(db_path)
            sha_ok = (digest == manifest.get("sha256"))
            coverage_ok &= sha_ok
            print("  sha256       %s %s" % (digest[:16] + "...", "OK" if sha_ok else "不匹配!"))

        if symbols_path and os.path.exists(symbols_path):
            print("-" * 74)
            print("清单覆盖率 (vs %s):" % symbols_path)
            want = [s["code"] for s in parse_symbols(symbols_path)]
            have = set(codes)
            miss = [c for c in want if c not in have]
            hit = sum(1 for c in want if c in have)
            print("  清单标的数 = %d，已入库 = %d，覆盖率 = %.1f%%"
                  % (len(want), hit, 100.0 * hit / max(1, len(want))))
            # 覆盖率不足只作告警：--from-master-db / --offline 的兜底场景下
            # 数据源本身可能只含部分标的，此时库与 manifest 依然是自洽的。
            if miss:
                print("  [warn] 未入库: %s" % ", ".join(miss))
    finally:
        conn.close()

    print("=" * 74)
    print("结论: %s" % ("全部校验通过" if coverage_ok
                        else "manifest 与库内容不一致，请检查上面标记"))
    return 0 if coverage_ok else 1


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="生成 tdx_live.db 增量库（仅标准库）")
    parser.add_argument("--symbols", default=os.path.join("src", "data", "symbols.txt"),
                        help="关注清单路径（默认 src/data/symbols.txt）")
    parser.add_argument("--out", default=".", help="输出目录（默认当前目录）")
    parser.add_argument("--limit", type=int, default=30, help="每标的保留的最近日线根数（默认 30）")
    parser.add_argument("--offline", action="store_true",
                        help="不联网，用内置合成数据（manifest.source=offline）")
    parser.add_argument("--from-master-db", dest="from_master_db", default=None,
                        help="从本地主库 tdx.db 抽取（只读），不联网")
    parser.add_argument("--check", action="store_true",
                        help="只读产物并打印校验报告，不重新生成")
    args = parser.parse_args(argv)

    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)

    if args.check:
        return run_check(out_dir, args.symbols)

    if args.limit < 1:
        raise SystemExit("--limit 必须 >= 1")

    # trade_date：优先取当日（YYYYMMDD）。联网时若历史/快照都无当日数据，
    # 仍以当日作为快照日期标签；离线路径用它生成合成日期。
    today = datetime.date.today()
    trade_date = int(today.strftime("%Y%m%d"))

    symbols = parse_symbols(args.symbols)
    print("清单: %s -> %d 个标的" % (args.symbols, len(symbols)))

    records, source = collect_records(args, symbols, trade_date)
    if not records:
        raise SystemExit("没有任何标的取到数据，放弃生成（保留原有产物）")

    generated_at = int(time.time())
    db_path = os.path.join(out_dir, DB_NAME)
    mf_path = os.path.join(out_dir, MANIFEST_NAME)
    tmp_db = db_path + ".tmp"

    version = next_version(mf_path)
    stats = build_db(tmp_db, records, trade_date, generated_at)
    try:
        validate_db(tmp_db, records, stats)
    except Exception:
        if os.path.exists(tmp_db):
            os.remove(tmp_db)      # 校验失败：丢弃临时文件，不覆盖已有产物
        raise

    digest = sha256_file(tmp_db)
    manifest = {
        "version": version,
        "generated_at": generated_at,
        "trade_date": trade_date,
        "source": source,
        "symbols": stats["symbols"],
        "min_date": stats["min_date"],
        "max_date": stats["max_date"],
        "rows": stats["rows"],
        "sha256": digest,
    }
    # 两个产物都先落临时文件，再原子替换
    os.replace(tmp_db, db_path)
    write_manifest_atomic(mf_path, manifest)

    print("已生成: %s (%d 字节)" % (db_path, os.path.getsize(db_path)))
    print("已生成: %s (version=%d, source=%s)" % (mf_path, version, source))
    print("标的数=%d  日期范围=%s~%s" % (stats["symbols"], stats["min_date"], stats["max_date"]))
    print("行数: " + "  ".join("%s=%d" % (p, stats["rows"][p]) for p in PERIODS))
    print("sha256: %s" % digest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
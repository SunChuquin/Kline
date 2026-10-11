# -*- coding: utf-8 -*-
"""quote_parse.py — 多源取数口径解析（Python 引擎候选 4，阶段 A：口径层下沉）。

权威语义来源（本脚本为自包含移植，不 import 上述模块）
  - 东财批量快照：src/live_db_builder.py `_snapshot_from_diff` + `beijing_date_from_ts`
    + `_num`（'-'/'--'/'' → None）。
  - 腾讯 newfqkline：src/contract_golden.py `parse_tencent_golden`（镜像
    GapBackfill.fetchSourceBars 的三段兜底 day→qfqday→任意 *day 与行解析
    GapBackfill.parseTencentRow）。
  - 自校准 calibrate：src/contract_golden.py `calibrate`（镜像
    GapBackfill.calibrate 的判定顺序：价格逐字段相等 → priceOnly → 源停牌 →
    量比吸附 → 额比哨兵 → 缺口行折算）。
  - secid 映射：src/live_db_builder.py `secid_for_file` + `SPECIAL_FILE_SECID`
    （27#/62#/102# 等扩展行情前缀返回 None 属 PC/设备有意分工，设备侧覆盖表留 Swift）。

golden 对拍：KlineTests/Fixtures/quote_parsing.json 与 secid_mapping.json
（src/contract_golden.py 产出；PyBridgeQuoteParsingTests 对拍同一 fixture）。

执行契约（由 Swift 桥接层包装，与 period_aggregate.py / candle_patterns.py 一致）
  - 桥接注入模块全局 dict `kline_input`；本脚本产出模块级 dict `kline_result`，
    `kline_result["ok"]` 为 bool；脚本异常由包装统一捕获，输入形状非法时
    直接返回 {"ok": False, "error": ...}。

op = "em_snapshot"（东财 ulist 批量快照响应文本 → {secid: 当日行情}）
  输入: {"op":"em_snapshot","raw":"<响应 JSON 文本>"}
  输出: result = {secid: {"secid","code","name","open","high","low","close",
                          "vol","amo","ts","tradeDate"}}
  - 字段序号 ⚠：f17=开、f15=高、f16=低、f2=收、f5=量、f6=额（与 kline 接口的
    开,收,高,低 顺序不同）；secid = f13.f12（同码消歧天然成立）。
  - 非交易时段/停牌字段为 '-' → None；ts = f124（秒级 epoch）。
  - tradeDate = ts 按北京时间(UTC+8) 换算 YYYYMMDD；ts 缺失/非正 → None。

op = "tencent_kline"（腾讯 newfqkline(bfq) 响应文本 → SourceBar 行数组）
  输入: {"op":"tencent_kline","raw":"<响应 JSON 文本>","marketCode":"sh600000"}
  输出: result = {"rows":[{"date","open","close","high","low","vol","amo"},...]}
  - ⚠ 行内价格顺序 开-收-高-低（r[1]开 r[2]收 r[3]高 r[4]低），r[5]=量(手)、
    r[8]=额(万元)，date 去 '-' 转 YYYYMMDD 整数。
  - 行解析失败（字段缺失/非数）跳过该行；响应 code!=0 / 缺 data.<marketCode> /
    无任何 *day 数组 → ok=False 带 error（镜像 fetchSourceBars 错误分支）。

op = "calibrate"（自校准 + 缺口行生成，与取数来源无关）
  输入: {"op":"calibrate",
         "base":{"open","high","low","close","vol","amo"},   # 主库锚点 bar
         "sourceRows":[[腾讯 wire 行],...],                    # 先经 tencent 行解析
         "mainLatest":20260828}
  输出: result = {"outcome":"gap"|"upToDate"|"suspended"|"anchorMissing"|"anomaly",
                  ...}——gap 带 volRatio/priceOnly/amoScale/bars，anomaly 带 reason。
  - 价格容差 1e-5（相对）；量比吸附带 1/100/1e-4/1e-7；额比哨兵 2%。
  - 量折算：volRatio<1 的折算类为整数舍入口径 → round；amoScale：volRatio≥1
    → 10000（源万元→元），否则 0.01（指数折算类，PC 实测精确）。

op = "secid"（file 前缀 → 东财 secid，PC 权威口径）
  输入: {"op":"secid","files":["SH#600000","27#..."]}
  输出: result = {file: secid 或 null}——SH#→1.、SZ#/BJ#→0.（用 file 前缀判定，
    不从 6 位 code 猜）；SH#999999 走特例表 → 1.000001；其余前缀 → null
    （公开行情接口无对应，云端/PC 不产分片；设备侧由覆盖表补齐，属有意分工）。
"""

import datetime
import json

_BEIJING_TZ = datetime.timezone(datetime.timedelta(hours=8))

# --- calibrate 常量（镜像 GapBackfill / contract_golden） ---
_PRICE_TOLERANCE = 1e-5
_VOL_RATIO_BANDS = (              # (下限, 上限, 吸附值) —— 判定顺序即吸附优先级
    (0.5, 2.0, 1.0),              # volRatioBand1：指数/主库本来就按手
    (50.0, 200.0, 100.0),         # volRatioBand100：个股 主库股 vs 源手
    (0.00005, 0.0002, 0.0001),    # volRatioBand0_0001：中证/国证指数
    (8e-8, 1.25e-7, 1e-7),        # volRatioBand1e_7：恒生系
)
_AMO_RATIO_TOLERANCE = 0.02

_SPECIAL_FILE_SECID = {
    "SH#999999": "1.000001",      # 上证指数：通达信记为 999999，东财 secid 是 1.000001
}


def _err(msg):
    return {"ok": False, "error": msg}


def _num6(x):
    """浮点统一 round 到 6 位；整值规整为 int（避免平台浮点/表示差异）。None 原样保留。"""
    if x is None:
        return None
    f = round(float(x), 6)
    if f == 0:
        f = 0.0                   # 归一 -0.0
    i = int(f)
    return i if f == i else f


def _swift_num(v):
    """镜像 GapBackfill.num：数字（含 bool→1/0）→ float、字符串 → float(s)，其余 None。"""
    if isinstance(v, bool):
        return float(v)
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            return float(v)
        except ValueError:
            return None
    return None


def _em_num(v):
    """镜像 live_db_builder._num：东财非交易时段/停牌会返回 '-'，统一转 None。"""
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


def _beijing_date_from_ts(ts):
    """秒级 epoch 按北京时间(UTC+8) 换算 YYYYMMDD；缺失/非正 → None。"""
    if ts is None:
        return None
    try:
        ts = int(float(ts))
    except (TypeError, ValueError):
        return None
    if ts <= 0:
        return None
    return int(datetime.datetime.fromtimestamp(ts, _BEIJING_TZ).strftime("%Y%m%d"))


# --- op 实现 ------------------------------------------------------------------


def _op_em_snapshot(inp):
    raw = inp.get("raw")
    if not isinstance(raw, str) or not raw:
        return _err("em_snapshot: raw 必须为非空字符串（响应 JSON 文本）")
    try:
        data = json.loads(raw)
    except ValueError as exc:
        return _err("em_snapshot: 响应非 JSON: %s" % exc)
    diff = (data.get("data") or {}).get("diff") if isinstance(data, dict) else None
    if not isinstance(diff, list):
        return _err("em_snapshot: 响应缺 data.diff")
    result = {}
    for it in diff:
        if not isinstance(it, dict):
            continue
        f12, f13 = it.get("f12"), it.get("f13")
        if f12 is None or f13 is None:
            continue
        secid = "%s.%s" % (f13, f12)
        ts = _em_num(it.get("f124"))
        result[secid] = {
            "secid": secid,
            "code": str(f12),
            "name": (it.get("f14") or "").strip() if isinstance(it.get("f14"), str) else "",
            "open": _em_num(it.get("f17")), "high": _em_num(it.get("f15")),
            "low": _em_num(it.get("f16")), "close": _em_num(it.get("f2")),
            "vol": _em_num(it.get("f5")), "amo": _em_num(it.get("f6")),
            "ts": ts, "tradeDate": _beijing_date_from_ts(ts),
        }
    return {"ok": True, "result": result}


def _parse_tencent_row(r):
    """镜像 GapBackfill.parseTencentRow：11 字段行 [0]日期 [1]开 [2]收 [3]高 [4]低
    [5]量(手) [8]额(万元)；解析失败返回 None。"""
    if not isinstance(r, (list, tuple)) or len(r) < 9 or not isinstance(r[0], str):
        return None
    try:
        date = int(r[0].replace("-", ""))
    except ValueError:
        return None
    o, c, h, lo = (_swift_num(r[1]), _swift_num(r[2]), _swift_num(r[3]), _swift_num(r[4]))
    vol, amo = _swift_num(r[5]), _swift_num(r[8])
    if None in (o, c, h, lo, vol, amo):
        return None
    return {"date": date, "open": o, "close": c, "high": h, "low": lo,
            "vol": vol, "amo": amo}


def _op_tencent_kline(inp):
    raw = inp.get("raw")
    market = inp.get("marketCode")
    if not isinstance(raw, str) or not raw:
        return _err("tencent_kline: raw 必须为非空字符串（响应 JSON 文本）")
    if not isinstance(market, str) or not market:
        return _err("tencent_kline: marketCode 必须为非空字符串（如 sh600000）")
    try:
        root = json.loads(raw)
    except ValueError as exc:
        return _err("tencent_kline: 响应非 JSON: %s" % exc)
    if not isinstance(root, dict):
        return _err("tencent_kline: 响应顶层不是 JSON object")
    code = root.get("code")
    if isinstance(code, (int, float)) and int(code) != 0:
        return _err("tencent_kline: 接口 code=%s %s" % (int(code), root.get("msg") or ""))
    container = (root.get("data") or {}).get(market) if isinstance(root.get("data"), dict) else None
    if not isinstance(container, dict):
        return _err("tencent_kline: 响应无 data.%s" % market)
    # `bfq` → `day`；万一接口换版返回复权键，兜底取任一 *day（价格会对不上，由自校准拦下）
    rows = container.get("day")
    if rows is None:
        rows = container.get("qfqday")
    if rows is None:
        for key, value in container.items():
            if isinstance(key, str) and key.endswith("day") and isinstance(value, list):
                rows = value
                break
    if not isinstance(rows, list):
        return _err("tencent_kline: 响应无 K 线数组")
    out = []
    for r in rows:
        bar = _parse_tencent_row(r)
        if bar is not None:
            out.append(bar)
    return {"ok": True, "result": {"rows": out}}


def _near(a, b):
    """镜像 GapBackfill.near：相对容差价格逐字段相等。"""
    scale = max(abs(a), abs(b), 1)
    return abs(a - b) / scale <= _PRICE_TOLERANCE


def _gap_bar(row, vol_ratio, amo_scale, round_vol):
    """镜像 calibrate ⑤：量按 volRatio（折算类主库整数舍入口径 → round 对齐）、额按 amoScale。"""
    vol = row["vol"] * vol_ratio
    if round_vol:
        vol = float(round(vol))
    return {"date": row["date"], "open": _num6(row["open"]), "high": _num6(row["high"]),
            "low": _num6(row["low"]), "close": _num6(row["close"]),
            "vol": _num6(vol), "amo": _num6(row["amo"] * amo_scale)}


def _op_calibrate(inp):
    base = inp.get("base")
    source_rows = inp.get("sourceRows")
    main_latest = inp.get("mainLatest")
    if not isinstance(base, dict):
        return _err("calibrate: base 必须为对象（主库锚点 bar）")
    if not isinstance(source_rows, list):
        return _err("calibrate: sourceRows 必须为数组（腾讯 wire 行）")
    if not isinstance(main_latest, int) or isinstance(main_latest, bool):
        return _err("calibrate: mainLatest 必须为 YYYYMMDD 整数")
    fields = ("open", "high", "low", "close", "vol", "amo")
    b = {}
    for k in fields:
        v = base.get(k)
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            return _err("calibrate: base.%s 必须为数值" % k)
        b[k] = float(v)
    rows = []
    for (i, r) in enumerate(source_rows):
        bar = _parse_tencent_row(r)
        if bar is None:
            return _err("calibrate: sourceRows[%d] 解析失败（字段缺失/非数）" % i)
        rows.append(bar)

    result = _calibrate(b, rows, main_latest)
    return {"ok": True, "result": result}


def _calibrate(base, rows, main_latest):
    """镜像 GapBackfill.calibrate 的判定顺序与折算（权威：contract_golden.calibrate）。"""
    anchor = None
    for r in rows:
        if r["date"] == main_latest:
            anchor = r
            break
    if anchor is None:
        return {"outcome": "anchorMissing"}
    if not (_near(base["open"], anchor["open"]) and _near(base["high"], anchor["high"])
            and _near(base["low"], anchor["low"]) and _near(base["close"], anchor["close"])):
        return {"outcome": "anomaly",
                "reason": "价格不符 主库 %.3f/%.3f/%.3f/%.3f 源 %.3f/%.3f/%.3f/%.3f"
                          % (base["open"], base["high"], base["low"], base["close"],
                             anchor["open"], anchor["high"], anchor["low"], anchor["close"])}
    # 主库锚点无量额口径（如部分定制指数官方不发布）→ 只补价格，vol/amo 写 0
    if base["vol"] <= 0:
        bars = [_gap_bar(r, 0.0, 0.0, False) for r in rows if r["date"] > main_latest]
        if not bars:
            return {"outcome": "upToDate"}
        return {"outcome": "gap", "priceOnly": True, "volRatio": 1.0,
                "amoScale": 10000.0, "bars": bars}
    # 源侧锚点量为 0 → 真实停牌，无从折算
    if anchor["vol"] <= 0:
        return {"outcome": "suspended"}
    raw_vol = base["vol"] / anchor["vol"]
    vol_ratio = None
    for lo, hi, val in _VOL_RATIO_BANDS:
        if lo <= raw_vol <= hi:
            vol_ratio = val
            break
    if vol_ratio is None:
        return {"outcome": "anomaly",
                "reason": "量比异常 %.3g（既不像 1/100/1e-4/1e-7）" % raw_vol}
    # 额比哨兵：rawAmo = 主库 / (源[万]×10000)。个股/普通指数 ≈1（主库元）；
    # 指数折算类（volRatio<1）主库额 = 源×0.01（PC 实测精确）→ rawAmo ≈1e-6
    if anchor["amo"] > 0 and base["amo"] > 0:
        expected = 1.0 if vol_ratio >= 1 else 1e-6
        raw_amo = base["amo"] / (anchor["amo"] * 10000)
        if abs(raw_amo - expected) / expected > _AMO_RATIO_TOLERANCE:
            return {"outcome": "anomaly", "reason": "额比异常 %.4g" % raw_amo}
    amo_scale = 10000.0 if vol_ratio >= 1 else 0.01
    bars = [_gap_bar(r, vol_ratio, amo_scale, vol_ratio < 1)
            for r in rows if r["date"] > main_latest]
    if not bars:
        return {"outcome": "upToDate"}
    return {"outcome": "gap", "priceOnly": False, "volRatio": vol_ratio,
            "amoScale": amo_scale, "bars": bars}


def _op_secid(inp):
    files = inp.get("files")
    if not isinstance(files, list) or not files:
        return _err("secid: files 必须为非空数组")
    result = {}
    for (i, f) in enumerate(files):
        if not isinstance(f, str) or not f:
            return _err("secid: files[%d] 必须为非空字符串" % i)
        result[f] = _secid_for_file(f)
    return {"ok": True, "result": result}


def _secid_for_file(file_str):
    """镜像 live_db_builder.secid_for_file：用 file 前缀判定市场，不从 6 位 code 猜。
    其余前缀（27#/62#/102# 等扩展行情）→ None（设备侧由覆盖表补齐，有意分工）。"""
    if file_str in _SPECIAL_FILE_SECID:
        return _SPECIAL_FILE_SECID[file_str]
    prefix = file_str.split("#", 1)[0].upper()
    code = file_str.split("#", 1)[1] if "#" in file_str else ""
    if prefix == "SH":
        return "1." + code
    if prefix in ("SZ", "BJ"):
        return "0." + code
    return None


# --- 分发 ---------------------------------------------------------------------

_OPS = {
    "em_snapshot": _op_em_snapshot,
    "tencent_kline": _op_tencent_kline,
    "calibrate": _op_calibrate,
    "secid": _op_secid,
}


def _main():
    inp = globals().get("kline_input")
    if not isinstance(inp, dict):
        return _err("kline_input 未注入或不是对象")
    op = inp.get("op")
    handler = _OPS.get(op)
    if handler is None:
        return _err("未知 op: %r（仅支持 %s）" % (op, " / ".join(sorted(_OPS))))
    return handler(inp)


kline_result = _main()

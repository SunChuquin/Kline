#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
contract_golden.py —— PC 侧契约 golden 生成器（纯标准库 · 无网络 · 无随机 · 输出确定）

用途
----
「周期聚合、取数口径、模板解析」三处口径在 PC Python 与 App Swift 各有一份实现。
本脚本复用 PC 侧既有实现产出确定性 golden JSON，供 Swift 单元测试断言同值。
输出（UTF-8、indent=2、ensure_ascii=False、键序固定、浮点统一 round 到 6 位并规整整值）：

    KlineTests/Fixtures/period_aggregation.json
    KlineTests/Fixtures/quote_parsing.json
    KlineTests/Fixtures/secid_mapping.json
    KlineTests/Fixtures/indicator_templates.json

用法
----
    cd <仓库根目录>
    python src/contract_golden.py        # Windows 环境（无 python3 命令）

运行时绝不发网络请求：真实抓包样本以常量内置（EMSNAPSHOT_RAW / TENCENT_*_RAW）。

重新生成时机
------------
以下任一口径改动后重跑本脚本，并连同对应 Swift 断言一起评审提交：
  · 周期聚合口径（src/tdx_parser.py period_key/handle_data、
    src/live_db_builder.py aggregate_full_periods/period_bounds/period_key）
  · secid 映射（src/live_db_builder.py secid_for_file / SPECIAL_FILE_SECID、
    Kline/Resources/universe_secids.txt 覆盖表）
  · 行情解析与自校准（Kline/Infrastructure/GapBackfill.swift 的行解析、calibrate 常量）
  · 指标模板解析（check_indicators.py parse_tdx、SystemIndicatorStore.parse）

四个 fixtures 与被测 Swift 函数
------------------------------
  period_aggregation.json
      → LiveDataStore.rebuildGapPeriods / WatchlistSyncManager.mergePeriodBar
        口径：周期 bar 的 date = 周期内首个交易日；停牌周期不产 bar。
        golden 由主库权威实现 src/tdx_parser.TDXDataGenerator.handle_data 计算（周/月/季/年四周期），
        并用 live_db_builder.aggregate_full_periods（全窗口）对 weekly/monthly 做逐字段交叉自检，
        两路不一致立即失败——确保「主库 tdx.db 口径」与「增量库口径」在同一份 golden 上闭合。
  quote_parsing.json
      · eastmoneySnapshot → EastmoneyQuoteFetcher.decodeChunk + beijingDate(fromEpoch:)
        golden 用 live_db_builder._snapshot_from_diff + beijing_date_from_ts 计算
        （f17开/f15高/f16低/f2收/f5量/f6额、f124 按 UTC+8 换算 tradeDate）。
      · tencentKline → GapBackfill.fetchSourceBars
        行数组 11 字段：[0]日期 [1]开 [2]收 [3]高 [4]低 [5]量(手) [6]{} [7]换手% [8]额(万元)
        （价格顺序开-收-高-低，与快照的开-高-低-收不同）。Python 侧无既有实现，
        本脚本按 GapBackfill.fetchSourceBars(:699-709) 的取数语义解析。
      · calibration → GapBackfill.calibrate
        ⚠ 校准无 Python 侧实现：本脚本按 GapBackfill.calibrate(:584-639) 的常量与判定顺序
        镜像实现（价格逐字段相等 → 量比吸附 1/100/1e-4/1e-7 → 额比哨兵 2% → 折算缺口行），
        属唯一非 import 复用段，口径改动须 PC/Swift 双侧同步。
  secid_mapping.json
      → EastmoneyQuoteFetcher.secid(forFile:)（对拍 PC live_db_builder.secid_for_file）
  indicator_templates.json
      → SystemIndicatorStore.parse(content:id:)
        KIND= 缺失（本 corpus 全部如此）或 KIND=TECH → accepted；出现 KIND= 且取值非
        TECH（SELECT/TRADE/未知）→ rejected。formulaTemplate 与 Swift 一致为 '\n' join 串。

样本来源
--------
真实抓包（2026-10-04，与 App 生产请求同 URL / 同 UA / 同 Referer）：
  · 东财批量快照 ulist.np/get：1.600000 / 0.000001 / 1.000001 / 0.300750 / 1.601398
    （2026-09-30 收盘快照；含 0.000001 平安银行 与 1.000001 上证指数 的同码消歧样本）
  · 腾讯 newfqkline：sh600000、sh000001，2026-09 全月（bfq 不复权）
需要新样本时重新抓取并整体替换常量，脚本仍保持离线。

确定性
------
无 random、无网络。唯一的「当前时间」依赖是 TDXDataGenerator.precompute_monday_cache_by_range()
以 datetime.now() 为缓存上界——只影响缓存覆盖范围；fixtures 日期固定在 2024~2026-09，
golden 输出与运行时刻无关。连续运行两次输出字节级一致。
"""

import datetime
import glob
import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(REPO_ROOT, "src")
OUT_DIR = os.path.join(REPO_ROOT, "KlineTests", "Fixtures")

sys.path.insert(0, SRC_DIR)
sys.path.insert(0, REPO_ROOT)

import live_db_builder as ldb            # noqa: E402  复用：aggregate_full_periods / secid_for_file
import tdx_parser                        # noqa: E402  复用：TDXDataGenerator.period_key / handle_data
import check_indicators                  # noqa: E402  复用：parse_tdx


# ---------------------------------------------------------------------------
# 真实抓包样本（原样内置；运行时不发任何请求）
# ---------------------------------------------------------------------------

EMSNAPSHOT_RAW = r"""{"rc":0,"rt":11,"svr":177622159,"lt":2,"full":1,"dlmkts":"8,10,128","dsc":"0","data":{"total":5,"diff":[{"f2":9.48,"f5":1474848,"f6":1386209937.0,"f12":"600000","f13":1,"f14":"浦发银行","f15":9.49,"f16":9.16,"f17":9.22,"f18":9.18,"f124":1790755897},{"f2":11.57,"f5":1045357,"f6":1205814857.64,"f12":"000001","f13":0,"f14":"平安银行","f15":11.65,"f16":11.33,"f17":11.36,"f18":11.35,"f124":1790753694},{"f2":3842.19,"f5":414560247,"f6":679398992444.8,"f12":"000001","f13":1,"f14":"上证指数","f15":3851.22,"f16":3833.09,"f17":3839.25,"f18":3830.45,"f124":1790755920},{"f2":291.11,"f5":296995,"f6":8613929784.25,"f12":"300750","f13":0,"f14":"宁德时代","f15":292.7,"f16":285.8,"f17":290.0,"f18":286.8,"f124":1790753658},{"f2":8.28,"f5":2931711,"f6":2417869721.0,"f12":"601398","f13":1,"f14":"工商银行","f15":8.3,"f16":8.15,"f17":8.17,"f18":8.16,"f124":1790755918}]}}"""

TENCENT_SH600000_RAW = r"""{"code":0,"msg":"","data":{"sh600000":{"day":[["2026-09-02","9.35","9.28","9.43","9.25","670365.00",{},"0.20","62537.48","0.00","0.00"],["2026-09-03","9.24","9.27","9.47","9.22","898172.00",{},"0.27","84197.29","0.00","0.00"],["2026-09-04","9.27","9.43","9.45","9.26","757660.00",{},"0.23","71227.10","0.00","0.00"],["2026-09-07","9.43","9.23","9.46","9.19","867113.00",{},"0.26","80632.62","0.00","0.00"],["2026-09-08","9.21","9.28","9.34","9.21","403779.00",{},"0.12","37476.32","0.00","0.00"],["2026-09-09","9.25","9.23","9.29","9.21","505325.00",{},"0.15","46754.99","0.00","0.00"],["2026-09-10","9.22","9.35","9.36","9.19","597743.00",{},"0.18","55588.22","0.00","0.00"],["2026-09-11","9.35","9.26","9.35","9.22","653273.00",{},"0.20","60462.59","0.00","0.00"],["2026-09-14","9.28","9.40","9.43","9.24","771871.00",{},"0.23","72230.74","0.00","0.00"],["2026-09-15","9.39","9.18","9.42","9.16","893562.00",{},"0.27","82377.39","0.00","0.00"],["2026-09-16","9.17","9.10","9.20","9.00","723404.00",{},"0.22","65634.81","0.00","0.00"],["2026-09-17","9.10","9.06","9.14","9.03","456711.00",{},"0.14","41488.71","0.00","0.00"],["2026-09-18","9.05","9.07","9.15","9.00","517593.00",{},"0.16","46996.94","0.00","0.00"],["2026-09-21","9.04","9.01","9.06","8.91","659062.00",{},"0.20","59349.22","0.00","0.00"],["2026-09-22","9.03","9.04","9.07","8.97","532667.00",{},"0.16","48079.57","0.00","0.00"],["2026-09-23","9.02","8.98","9.05","8.95","511244.00",{},"0.15","45895.22","0.00","0.00"],["2026-09-24","8.99","9.00","9.05","8.97","528364.00",{},"0.16","47596.49","0.00","0.00"],["2026-09-28","9.03","9.16","9.18","9.00","1184853.00",{},"0.36","108084.68","0.00","0.00"],["2026-09-29","9.15","9.18","9.25","9.09","805097.00",{},"0.24","73974.10","0.00","0.00"],["2026-09-30","9.22","9.48","9.49","9.16","1474848.00",{},"0.44","138620.99","0.00","0.00"]],"qt":{"sh600000":["1","\u6d66\u53d1\u94f6\u884c","600000","9.48","9.18","9.22","1474848","986826","488022","9.47","1698","9.46","3703","9.45","2708","9.44","729","9.43","1244","9.48","10808","9.49","29728","9.50","39954","9.51","18403","9.52","11369","","20260930161454","0.30","3.27","9.49","9.16","9.48\/1474848\/1386209937","1474848","138621","0.44","6.16","","9.49","9.16","3.59","3157.39","3157.39","0.42","10.10","8.26","2.07","-100180","9.40","5.10","6.31","","","-0.00","138620.9937","42.1860","445","   A","GP-A","-21.13","4.87","4.43","6.14","0.50","13.11","8.07","3.27","1.39","11.92","33305838300","33305838300","-83.24","-16.84","33305838300","","","-17.42","0.11","","CNY","0","___D__F__N","9.55","-7366",""],"market":["2026-10-04 12:06:52|HK_close_\u5df2\u4f11\u5e02|SH_close_\u56fd\u5e86\u8282\u4f11\u5e02|SZ_close_\u56fd\u5e86\u8282\u4f11\u5e02|US_close_\u5df2\u4f11\u5e02|SQ_close_\u5df2\u4f11\u5e02|DS_close_\u5df2\u4f11\u5e02|ZS_close_\u5df2\u4f11\u5e02|NEWSH_close_\u56fd\u5e86\u8282\u4f11\u5e02|NEWSZ_close_\u56fd\u5e86\u8282\u4f11\u5e02|NEWHK_close_\u5df2\u4f11\u5e02|NEWUS_close_\u5df2\u4f11\u5e02|REPO_close_\u56fd\u5e86\u8282\u4f11\u5e02|UK_close_\u5df2\u4f11\u5e02|KCB_close_\u56fd\u5e86\u8282\u4f11\u5e02|HSZB_close_\u56fd\u5e86\u8282\u4f11\u5e02|IT_close_\u5df2\u4f11\u5e02|MY_close_\u5df2\u4f11\u5e02|EU_close_\u5df2\u4f11\u5e02|AH_close_\u5df2\u4f11\u5e02|DE_close_\u5df2\u4f11\u5e02|JW_close_\u56fd\u5e86\u8282\u4f11\u5e02|CYB_close_\u56fd\u5e86\u8282\u4f11\u5e02|USA_close_\u5df2\u4f11\u5e02|USB_close_\u5df2\u4f11\u5e02|ZQ_close_\u56fd\u5e86\u8282\u4f11\u5e02"]},"mx_price":{"mx":[],"price":[]},"prec":"9.35","fsStartDate":"20201009","version":"16"}}}"""

TENCENT_SH000001_RAW = r"""{"code":0,"msg":"","data":{"sh000001":{"day":[["2026-09-02","3963.07","3941.39","3965.81","3932.25","516472775.00",{},"1.07","83536775.59","0.00","0.00"],["2026-09-03","3952.79","3942.09","3968.11","3930.45","496990189.00",{},"1.03","81988235.04","0.00","0.00"],["2026-09-04","3955.55","3930.12","3980.20","3915.22","537286161.00",{},"1.11","93825518.72","0.00","0.00"],["2026-09-07","3942.51","3932.70","3948.42","3916.49","477375261.00",{},"0.98","89790401.49","0.00","0.00"],["2026-09-08","3935.55","3940.55","3951.32","3925.72","529992688.00",{},"1.09","91556623.89","0.00","0.00"],["2026-09-09","3943.92","3951.51","3958.12","3933.47","517504311.00",{},"1.07","87373489.71","0.00","0.00"],["2026-09-10","3939.09","3934.40","3949.25","3927.35","484675114.00",{},"1.00","77967269.23","0.00","0.00"],["2026-09-11","3910.92","3888.11","3912.32","3852.03","579123145.00",{},"1.19","95818633.70","0.00","0.00"],["2026-09-14","3867.02","3885.33","3895.51","3867.02","458888916.00",{},"0.95","77928124.65","0.00","0.00"],["2026-09-15","3879.73","3864.28","3891.62","3858.15","440907766.00",{},"0.91","76398290.00","0.00","0.00"],["2026-09-16","3861.75","3891.60","3894.66","3842.72","459125108.00",{},"0.95","87114134.69","0.00","0.00"],["2026-09-17","3877.00","3875.60","3898.84","3866.89","452886464.00",{},"0.93","86877306.69","0.00","0.00"],["2026-09-18","3891.96","3911.87","3919.67","3888.50","485712507.00",{},"1.00","99416945.02","0.00","0.00"],["2026-09-21","3920.27","3949.91","3950.94","3918.13","502354877.00",{},"1.04","94681912.43","0.00","0.00"],["2026-09-22","3963.81","3952.13","3967.68","3945.42","506148369.00",{},"1.04","100799561.09","0.00","0.00"],["2026-09-23","3951.37","3936.52","3951.52","3934.46","466913933.00",{},"0.96","83413286.30","0.00","0.00"],["2026-09-24","3925.32","3888.37","3930.50","3888.37","438530412.00",{},"0.90","78361300.14","0.00","0.00"],["2026-09-28","3878.41","3823.62","3878.41","3806.67","452350675.00",{},"0.93","80454370.47","0.00","0.00"],["2026-09-29","3816.15","3830.45","3843.84","3810.81","399473391.00",{},"0.82","66170429.28","0.00","0.00"],["2026-09-30","3839.25","3842.19","3851.22","3833.09","414560247.00",{},"0.85","67939899.24","0.00","0.00"]],"qt":{"sh000001":["1","\u4e0a\u8bc1\u6307\u6570","000001","3842.19","3830.45","3839.25","414560247","0","0","0.00","0","0.00","0","0.00","0","0.00","0","0.00","0","0.00","0","0.00","0","0.00","0","0.00","0","0.00","0","","20260930161500","11.74","0.31","3851.22","3833.09","3842.19\/414560247\/679398992445","414560247","67939899","0.85","16.76","","3851.22","3833.09","0.47","602370.78","682245.82","0.00","-1","-1","0.92","0","3842.53","","","","","","67939899.2445","0.0000","0"," ","ZS","-3.19","-2.78","","","","4258.86","3741.11","-0.57","-3.46","-3.71","4858320758781","","-9.37","-4.50","4858320758781","","","-1.05","-0.02","","CNY","0","","0.00","0",""],"market":["2026-10-04 12:06:52|HK_close_\u5df2\u4f11\u5e02|SH_close_\u56fd\u5e86\u8282\u4f11\u5e02|SZ_close_\u56fd\u5e86\u8282\u4f11\u5e02|US_close_\u5df2\u4f11\u5e02|SQ_close_\u5df2\u4f11\u5e02|DS_close_\u5df2\u4f11\u5e02|ZS_close_\u5df2\u4f11\u5e02|NEWSH_close_\u56fd\u5e86\u8282\u4f11\u5e02|NEWSZ_close_\u56fd\u5e86\u8282\u4f11\u5e02|NEWHK_close_\u5df2\u4f11\u5e02|NEWUS_close_\u5df2\u4f11\u5e02|REPO_close_\u56fd\u5e86\u8282\u4f11\u5e02|UK_close_\u5df2\u4f11\u5e02|KCB_close_\u56fd\u5e86\u8282\u4f11\u5e02|HSZB_close_\u56fd\u5e86\u8282\u4f11\u5e02|IT_close_\u5df2\u4f11\u5e02|MY_close_\u5df2\u4f11\u5e02|EU_close_\u5df2\u4f11\u5e02|AH_close_\u5df2\u4f11\u5e02|DE_close_\u5df2\u4f11\u5e02|JW_close_\u56fd\u5e86\u8282\u4f11\u5e02|CYB_close_\u56fd\u5e86\u8282\u4f11\u5e02|USA_close_\u5df2\u4f11\u5e02|USB_close_\u5df2\u4f11\u5e02|ZQ_close_\u56fd\u5e86\u8282\u4f11\u5e02"],"zhishu":["","","1199","68","1053","","","","","","","","",""]},"introduce":"\u4e0a\u8bc1\u7efc\u5408\u6307\u6570\u7531\u5728\u4e0a\u6d77\u8bc1\u5238\u4ea4\u6613\u6240\u4e0a\u5e02\u7684\u7b26\u5408\u6761\u4ef6\u7684\u80a1\u7968\u4e0e\u5b58\u6258\u51ed\u8bc1\u7ec4\u6210\u6837\u672c\uff0c\u53cd\u6620\u4e0a\u6d77\u8bc1\u5238\u4ea4\u6613\u6240\u4e0a\u5e02\u516c\u53f8\u7684\u6574\u4f53\u8868\u73b0\u3002","mx_price":{"mx":[],"price":[]},"prec":"3979.89","fsStartDate":"20201009","version":"16"}}}"""


# ---------------------------------------------------------------------------
# 通用工具
# ---------------------------------------------------------------------------

def num6(x):
    """浮点统一 round 到 6 位；整值规整为 int（避免平台浮点/表示差异）。None 原样保留。"""
    if x is None:
        return None
    f = round(float(x), 6)
    if f == 0:
        f = 0.0                      # 归一 -0.0
    i = int(f)
    return i if f == i else f


def write_json(name, payload):
    path = os.path.join(OUT_DIR, name)
    text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    return path


# ---------------------------------------------------------------------------
# ① period_aggregation.json —— 周期聚合 golden
#    复用：tdx_parser.TDXDataGenerator.handle_data（主库权威口径）
#          live_db_builder.aggregate_full_periods（交叉自检）
# ---------------------------------------------------------------------------

def _make_tdx_instance():
    """构造不带任何依赖的 TDXDataGenerator 实例（绕过 __init__，不连库、不落文件），
    只初始化周期分组所需的 date_cache（复用既有实现，周一=周桶键）。"""
    db = tdx_parser.TDXDataGenerator.__new__(tdx_parser.TDXDataGenerator)
    db.date_cache = {}
    db.precompute_monday_cache_by_range()
    return db


def _trading_days(start_ymd, end_ymd, holidays, keep):
    """[start, end] 内的工作日（weekday<5）序列，YYYYMMDD 整数、升序。
    holidays：手工停牌/节假日集合；keep：只保留这些日期（构造单日月）。"""
    d0 = datetime.date(int(start_ymd[0:4]), int(start_ymd[4:6]), int(start_ymd[6:8]))
    d1 = datetime.date(int(end_ymd[0:4]), int(end_ymd[4:6]), int(end_ymd[6:8]))
    d, out = d0, []
    while d <= d1:
        key = "%04d%02d%02d" % (d.year, d.month, d.day)
        if d.weekday() < 5 and (keep is None or key in keep) \
                and (holidays is None or key not in holidays):
            out.append(int(key))
        d += datetime.timedelta(days=1)
    return out


def _synth_daily(dates, base_price):
    """确定性合成日线：[date, open, high, low, close, vol, amo]，恒满足 high>=max(o,c)、low<=min(o,c)。"""
    bars = []
    for i, date in enumerate(dates):
        o = round(base_price + 0.37 * i, 2)
        c = round(o + 0.21, 2)
        h = round(o + 0.50, 2)
        lo = round(o - 0.40, 2)
        vol = 100000 + 1111 * i
        amo = round(vol * c, 2)
        bars.append([date, o, h, lo, c, vol, amo])
    return bars


def _period_golden(db, daily):
    """handle_data 输出 [meta,date,o,h,l,c,vol,amo]，剥掉 meta_id → [date,o,h,l,c,vol,amo]。"""
    lines = ["%d;%s;%s;%s;%s;%s;%s" % (b[0], b[1], b[2], b[3], b[4], b[5], b[6])
             for b in daily]
    result = db.handle_data(1, lines, {})
    golden = {}
    for period, rows in zip(("weekly", "monthly", "quarterly", "yearly"), result[1:]):
        golden[period] = [[num6(v) for v in row[1:]] for row in rows]
    # 交叉自检：weekly/monthly 必须与增量库口径（全窗口）逐字段一致
    dict_bars = [dict(zip(("date", "open", "high", "low", "close", "vol", "amo"), b))
                 for b in daily]
    for period in ("weekly", "monthly"):
        via_ldb = ldb.aggregate_full_periods(dict_bars, period, 19900101, 20991231)
        expect = [[num6(b["date"]), num6(b["open"]), num6(b["high"]), num6(b["low"]),
                   num6(b["close"]), num6(b["vol"]), num6(b["amo"])] for b in via_ldb]
        if expect != golden[period]:
            raise SystemExit("[contract_golden] 交叉自检失败(%s)：handle_data 与 "
                             "aggregate_full_periods 口径不一致" % period)
    return golden


PERIOD_CASES = [
    {
        "caseName": "crossYearWeek",
        "description": "跨年：20241230 周桶同时含 2024-12-30/31 与 2025-01-02/03（01-01 停牌），"
                       "周线 date=20241230 一根跨年；月/季/年桶在此拆成 2024 与 2025 各一根",
        "start": "20241223", "end": "20250110", "holidays": {"20250101"}, "keep": None,
        "basePrice": 10.0,
    },
    {
        "caseName": "leapFeb29",
        "description": "闰年：2024-02-29（周四）是 2 月末最后交易日；0226 周桶跨 2 月→3 月；"
                       "月线 202402 的 date=20240201、202403 的 date=20240301",
        "start": "20240129", "end": "20240304", "holidays": set(), "keep": None,
        "basePrice": 11.0,
    },
    {
        "caseName": "quarterSwitch",
        "description": "季切换 Q1→Q2：2026-03-31 是 Q1 最后一根，2026-04-01 起 Q2；"
                       "月线 202603/202604 各一根，20260330 周桶跨月",
        "start": "20260323", "end": "20260408", "holidays": set(), "keep": None,
        "basePrice": 12.0,
    },
    {
        "caseName": "yearEndMonthEnd",
        "description": "月末/年末最后交易日：2025 年最后一根日线=2025-12-31（周三）；"
                       "2026-01-01/02 停牌，周桶 20251229 只含 12 月末三天，2026 年线 date=20260105",
        "start": "20251222", "end": "20260107", "holidays": {"20260101", "20260102"}, "keep": None,
        "basePrice": 13.0,
    },
    {
        "caseName": "suspensionGaps",
        "description": "停牌空档：周内停牌 2 日（06-06/06-07）+ 整周停牌（06-17~06-21，该周无周线）；"
                       "月线 202406 仍为一根（date=20240603），0603 周桶停牌后仍只发一根",
        "start": "20240603", "end": "20240628",
        "holidays": {"20240606", "20240607", "20240617", "20240618", "20240619",
                     "20240620", "20240621"},
        "keep": None,
        "basePrice": 14.0,
    },
    {
        "caseName": "singleDayWeek",
        "description": "单日周：01-27~01-30 停牌，本周只剩 2025-01-31 一根日线 → 周线仅一根；"
                       "当月月线正常（6 根）",
        "start": "20250120", "end": "20250131",
        "holidays": {"20250127", "20250128", "20250129", "20250130"},
        "keep": None,
        "basePrice": 15.0,
    },
    {
        "caseName": "singleDayMonth",
        "description": "单日月：整月只在 2025-10-09 交易一天（节后复牌即再停牌）→ 周线/月线/季线/年线"
                       "各仅一根，且 date=20251009 ≠ 日历月初（停牌周期不产 bar 的对偶：单日周期）",
        "start": "20251001", "end": "20251031", "holidays": None, "keep": {"20251009"},
        "basePrice": 16.0,
    },
]


def build_period_aggregation():
    db = _make_tdx_instance()
    cases = []
    for spec in PERIOD_CASES:
        dates = _trading_days(spec["start"], spec["end"], spec["holidays"], spec["keep"])
        daily = _synth_daily(dates, spec["basePrice"])
        cases.append({
            "caseName": spec["caseName"],
            "description": spec["description"],
            "daily": [[num6(v) for v in b] for b in daily],
            "golden": _period_golden(db, daily),
        })
    return {
        "notes": "周期聚合契约：周期 bar 的 date = 该周期内第一个交易日（组内最早日线日期），"
                 "open=首日开 / high=max / low=min / close=末日收 / vol=Σ / amo=Σ；停牌周期不产 bar。"
                 "golden 由 src/tdx_parser.TDXDataGenerator.handle_data（主库权威实现）计算，"
                 "weekly/monthly 另经 live_db_builder.aggregate_full_periods 全窗口交叉自检。"
                 "日线与周期 bar 字段序均为 [date,open,high,low,close,vol,amo]，date 为 YYYYMMDD 整数。",
        "cases": cases,
    }


# ---------------------------------------------------------------------------
# ② quote_parsing.json —— 行情解析 golden
# ---------------------------------------------------------------------------

def swift_num(v):
    """镜像 GapBackfill.num(:796)：NSNumber → double、String → Double(s)，其余 nil。"""
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


def parse_tencent_golden(raw, market_code):
    """镜像 GapBackfill.fetchSourceBars(:679-709) 的行解析语义：
    data.<code>.day（bfq），行内 [1]开[2]收[3]高[4]低[5]量(手)[8]额(万元)，date 去 '-' 转整。"""
    root = json.loads(raw)
    if root.get("code") != 0:
        raise SystemExit("[contract_golden] 腾讯样本 code!=0: %s" % market_code)
    container = (root.get("data") or {}).get(market_code)
    if not isinstance(container, dict):
        raise SystemExit("[contract_golden] 腾讯样本缺 data.%s" % market_code)
    rows = container.get("day")
    if rows is None:
        rows = container.get("qfqday")
    out = []
    for r in rows or []:
        if not isinstance(r, list) or len(r) < 9 or not isinstance(r[0], str):
            continue
        try:
            date = int(r[0].replace("-", ""))
        except ValueError:
            continue
        o, c, h, lo, vol, amo = (swift_num(r[1]), swift_num(r[2]), swift_num(r[3]),
                                 swift_num(r[4]), swift_num(r[5]), swift_num(r[8]))
        if None in (o, c, h, lo, vol, amo):
            continue
        out.append({"date": date, "open": num6(o), "close": num6(c), "high": num6(h),
                    "low": num6(lo), "vol": num6(vol), "amo": num6(amo)})
    return out


def build_eastmoney_golden():
    """复用 live_db_builder._snapshot_from_diff + beijing_date_from_ts。"""
    data = json.loads(EMSNAPSHOT_RAW)
    snap = ldb._snapshot_from_diff((data.get("data") or {}).get("diff"))
    golden = []
    for secid in sorted(snap):
        s = snap[secid]
        golden.append({
            "secid": s["secid"],
            "code": s["code"],
            "name": s["name"],
            "open": num6(s["open"]),
            "high": num6(s["high"]),
            "low": num6(s["low"]),
            "close": num6(s["close"]),
            "vol": num6(s["vol"]),
            "amo": num6(s["amo"]),
            "tradeDate": ldb.beijing_date_from_ts(s["ts"]),
        })
    return golden


# --- calibration：镜像 GapBackfill.calibrate(:584-639) -----------------------

PRICE_TOLERANCE = 1e-5          # GapBackfill.priceTolerance
VOL_RATIO_BANDS = (             # (下限, 上限, 吸附值) —— 判定顺序即吸附优先级
    (0.5, 2.0, 1.0),            # volRatioBand1：指数/主库本来就按手
    (50.0, 200.0, 100.0),       # volRatioBand100：个股 主库股 vs 源手
    (0.00005, 0.0002, 0.0001),  # volRatioBand0_0001：中证/国证指数
    (8e-8, 1.25e-7, 1e-7),      # volRatioBand1e_7：恒生系
)
AMO_RATIO_TOLERANCE = 0.02      # GapBackfill.amoRatioTolerance


def _near(a, b):
    """镜像 GapBackfill.near(:790)：相对容差价格逐字段相等。"""
    scale = max(abs(a), abs(b), 1)
    return abs(a - b) / scale <= PRICE_TOLERANCE


def calibrate(base, rows, main_latest):
    """镜像 GapBackfill.calibrate(:584-639) 的判定顺序与折算：
    价格逐字段相等 → priceOnly → 源停牌 → 量比吸附 → 额比哨兵 → 缺口行折算。"""
    anchor = None
    for r in rows:
        if r["date"] == main_latest:
            anchor = r
            break
    if anchor is None:
        return {"outcome": "anchorMissing", "expectedReject": False}
    if not (_near(base["open"], anchor["open"]) and _near(base["high"], anchor["high"])
            and _near(base["low"], anchor["low"]) and _near(base["close"], anchor["close"])):
        return {"outcome": "anomaly", "reason": "价格不符", "expectedReject": True}
    if base["vol"] <= 0:
        bars = [_gap_bar(r, 0.0, 0.0, False) for r in rows if r["date"] > main_latest]
        if not bars:
            return {"outcome": "upToDate", "expectedReject": False}
        return {"outcome": "gap", "priceOnly": True, "volRatio": 1.0, "amoScale": 10000.0,
                "bars": bars, "expectedReject": False}
    if anchor["vol"] <= 0:
        return {"outcome": "suspended", "expectedReject": False}
    raw_vol = base["vol"] / anchor["vol"]
    vol_ratio = None
    for lo, hi, val in VOL_RATIO_BANDS:
        if lo <= raw_vol <= hi:
            vol_ratio = val
            break
    if vol_ratio is None:
        return {"outcome": "anomaly", "reason": "量比异常（既不像 1/100/1e-4/1e-7）",
                "volRatioRaw": num6(raw_vol), "expectedReject": True}
    if anchor["amo"] > 0 and base["amo"] > 0:
        expected = 1.0 if vol_ratio >= 1 else 1e-6
        raw_amo = base["amo"] / (anchor["amo"] * 10000)
        if abs(raw_amo - expected) / expected > AMO_RATIO_TOLERANCE:
            return {"outcome": "anomaly", "reason": "额比异常", "amoRatioRaw": num6(raw_amo),
                    "expectedReject": True}
    amo_scale = 10000.0 if vol_ratio >= 1 else 0.01
    bars = [_gap_bar(r, vol_ratio, amo_scale, vol_ratio < 1)
            for r in rows if r["date"] > main_latest]
    if not bars:
        return {"outcome": "upToDate", "expectedReject": False}
    return {"outcome": "gap", "priceOnly": False, "volRatio": vol_ratio,
            "amoScale": amo_scale, "bars": bars, "expectedReject": False}


def _gap_bar(row, vol_ratio, amo_scale, round_vol):
    """镜像 calibrate ⑤：量按 volRatio（折算类主库整数舍入口径 → round 对齐）、额按 amoScale。"""
    vol = row["vol"] * vol_ratio
    if round_vol:
        vol = float(round(vol))
    return {"date": row["date"], "open": num6(row["open"]), "high": num6(row["high"]),
            "low": num6(row["low"]), "close": num6(row["close"]),
            "vol": num6(vol), "amo": num6(row["amo"] * amo_scale)}


def _tx_row(date8, o, c, h, l, vol, turnover, amo):
    """构造腾讯 wire 风格 11 字段行：[0]日期 [1]开 [2]收 [3]高 [4]低 [5]量(手) [6]{} [7]换手% [8]额(万元)。"""
    return ["%04d-%02d-%02d" % (date8 // 10000, date8 // 100 % 100, date8 % 100),
            "%.2f" % o, "%.2f" % c, "%.2f" % h, "%.2f" % l,
            "%.2f" % vol, {}, "%.2f" % turnover, "%.2f" % amo, "0.00", "0.00"]


def _parse_rows_to_source(rows):
    """sourceRows（腾讯行数组）→ calibrate 入参（date/open/high/low/close/vol/amo dict）。"""
    out = []
    for r in rows:
        o, c, h, lo, vol, amo = (swift_num(r[1]), swift_num(r[2]), swift_num(r[3]),
                                 swift_num(r[4]), swift_num(r[5]), swift_num(r[8]))
        out.append({"date": int(r[0].replace("-", "")), "open": o, "high": h,
                    "low": lo, "close": c, "vol": vol, "amo": amo})
    return out


def build_calibration_cases():
    def base_row(o, h, l, c, vol, amo):
        return {"open": o, "high": h, "low": l, "close": c, "vol": vol, "amo": amo}

    anchor = _tx_row(20260828, 10.00, 10.20, 10.30, 9.90, 12345.00, 0.44, 1234.50)
    gap1 = _tx_row(20260831, 10.25, 10.41, 10.50, 10.10, 11111.00, 0.40, 1500.00)
    gap2 = _tx_row(20260901, 10.40, 10.55, 10.60, 10.30, 12222.00, 0.43, 1600.00)

    anchor_idx = _tx_row(20260828, 3839.25, 3842.19, 3851.22, 3833.09,
                         414560247.00, 0.85, 67939899.00)
    gap_idx = _tx_row(20260831, 3844.10, 3823.62, 3855.00, 3810.00,
                      452350675.00, 0.93, 80454370.00)

    specs = [
        ("stockVolRatio100", "个股：主库 vol=股、源=手 → 量比吸附 100；额=源(万)×10000 折算成元",
         20260828, base_row(10.0, 10.3, 9.9, 10.2, 1234500, 12345000.0),
         [anchor, gap1, gap2]),
        ("indexVolRatio1", "指数：主库本来就按手 → 量比吸附 1；额比 ≈1（源万×10000=主库元）",
         20260828, base_row(3839.25, 3851.22, 3833.09, 3842.19, 414560247, 679398990000.0),
         [anchor_idx, gap_idx]),
        ("priceMismatchReject", "价格不逐字段相等（open 差 0.05）→ 判口径异常丢弃，绝不开写",
         20260828, base_row(10.05, 10.3, 9.9, 10.2, 1234500, 12345000.0),
         [anchor, gap1, gap2]),
        ("amoRatioReject", "额比异常（主库额比预期高 10%）→ 量比虽吸附 100 仍被额比哨兵拦下",
         20260828, base_row(10.0, 10.3, 9.9, 10.2, 1234500, 13579500.0),
         [anchor, gap1, gap2]),
        ("volRatioReject", "量比异常（主库/源=10，既不像 1 也不像 100）→ 判口径异常丢弃",
         20260828, base_row(10.0, 10.3, 9.9, 10.2, 123450, 12345000.0),
         [anchor, gap1, gap2]),
        ("suspendedAnchorVol0", "源侧锚点量为 0（真实停牌）→ 无从折算，跳过该只",
         20260828, base_row(10.0, 10.3, 9.9, 10.2, 500000, 12345000.0),
         [_tx_row(20260828, 10.00, 10.20, 10.30, 9.90, 0.00, 0.00, 0.00), gap1, gap2]),
        ("anchorMissing", "源侧没有主库最新日那根（长期停牌、无重叠校准日）→ 安全跳过，非口径异常",
         20260828, base_row(10.0, 10.3, 9.9, 10.2, 1234500, 12345000.0),
         [gap1, gap2]),
        ("priceOnlyVol0", "主库锚点 vol=0（无量额口径，如部分定制指数）→ 只补价格，vol/amo 写 0",
         20260828, base_row(10.0, 10.3, 9.9, 10.2, 0, 0.0),
         [anchor, gap1, gap2]),
        ("upToDateNoGap", "源侧只有锚点日一根、其后再无日线 → upToDate（无缺口可补）",
         20260828, base_row(10.0, 10.3, 9.9, 10.2, 1234500, 12345000.0),
         [anchor]),
    ]

    cases = []
    for name, desc, main_latest, base, rows in specs:
        parsed = _parse_rows_to_source(rows)
        cases.append({
            "caseName": name,
            "description": desc,
            "mainLatest": main_latest,
            "base": {k: num6(v) for k, v in base.items()},
            "sourceRows": rows,
            "golden": calibrate(base, parsed, main_latest),
        })
    return cases


def build_quote_parsing():
    return {
        "notes": "行情解析契约。eastmoneySnapshot：ulist 批量快照，f17开/f15高/f16低/f2收/f5量/f6额，"
                 "tradeDate 由 f124（秒级 epoch）按北京时间 UTC+8 换算（golden 由 "
                 "live_db_builder._snapshot_from_diff + beijing_date_from_ts 计算）。"
                 "tencentKline：newfqkline(bfq) 行数组 11 字段，价格顺序开-收-高-低（与快照不同），"
                 "vol=手、amo=万元，date 去 '-' 转 YYYYMMDD 整数。"
                 "calibration：基准行=主库锚点（个股 vol=股/amo=元；指数 vol=手），源行=腾讯 wire 行数组；"
                 "golden 为 GapBackfill.calibrate 语义的期望输出（本脚本镜像实现，无 Python 侧既有实现）。",
        "eastmoneySnapshot": {
            "raw": EMSNAPSHOT_RAW,
            "golden": build_eastmoney_golden(),
        },
        "tencentKline": [
            {"marketCode": "sh600000", "raw": TENCENT_SH600000_RAW,
             "golden": parse_tencent_golden(TENCENT_SH600000_RAW, "sh600000")},
            {"marketCode": "sh000001", "raw": TENCENT_SH000001_RAW,
             "golden": parse_tencent_golden(TENCENT_SH000001_RAW, "sh000001")},
        ],
        "calibration": build_calibration_cases(),
    }


# ---------------------------------------------------------------------------
# ③ secid_mapping.json —— file → secid 映射 golden
#    复用：live_db_builder.secid_for_file / SPECIAL_FILE_SECID
# ---------------------------------------------------------------------------

def build_secid_mapping():
    txt_path = os.path.join(REPO_ROOT, "Kline", "Resources", "universe_secids.txt")
    entries, override = [], {}
    with open(txt_path, "r", encoding="utf-8-sig") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p for p in re.split(r"[ \t]+", line) if p]
            if len(parts) < 2 or "#" not in parts[0]:
                continue
            file_str, secid_override = parts[0], parts[1]
            code = file_str.split("#", 1)[1]
            py_secid = ldb.secid_for_file(file_str, code)
            if file_str in ldb.SPECIAL_FILE_SECID:
                rule = "special"
            elif py_secid is not None:
                rule = "prefix"
            else:
                rule = "override"       # 27#/62#/102#：Python 无映射，Swift 查覆盖表
            entries.append({"file": file_str, "code": code, "secid": py_secid, "rule": rule})
            override[file_str] = secid_override

    # Swift 侧 secid(forFile:)：① 特例表 → ② 前缀规则(SH/SZ/BJ) → ③ 覆盖表
    divergent = []
    for e in entries:
        f = e["file"]
        if f in ldb.SPECIAL_FILE_SECID:
            swift_secid = ldb.SPECIAL_FILE_SECID[f]
        elif e["rule"] == "prefix":
            swift_secid = e["secid"]
        else:
            swift_secid = override.get(f)
        if swift_secid != e["secid"]:
            divergent.append({"file": f, "python": e["secid"], "swift": swift_secid})

    return {
        "notes": "file → 东财 secid 映射契约。Python 权威实现 live_db_builder.secid_for_file(:302)："
                 "用 file 前缀判定市场（SH#→1.*、SZ#/BJ#→0.*，不从 6 位 code 猜），"
                 "SH#999999 走 SPECIAL_FILE_SECID 特例 → 1.000001；"
                 "其余前缀（27#/62#/102# 扩展行情指数，含恒生系与 930/931/97x/98x 定制指数）返回 None "
                 "—— 云端/PC 结构上不产这些标的的分片。Swift EastmoneyQuoteFetcher.secid(forFile:)"
                 "(:149-162) 在前缀规则之后追加 Bundle 覆盖表 universe_secids.txt（东财接口其实有数据），"
                 "读不到表时降级为仅前缀规则。两侧对 27#/62#/102# 语义不同属有意为之，"
                 "见 knownDivergence（不硬凑一致）。本表无 hk# 前缀条目；恒生系以 27# 出现"
                 "（27#HSI→100.HSI，其余→124.*）。universe_secids.txt 本身即 Swift 覆盖表原文。",
        "specialFileSecid": dict(ldb.SPECIAL_FILE_SECID),
        "entries": entries,
        "swiftOverrideTable": override,
        "knownDivergence": {
            "reason": "Python secid_for_file 对非 SH#/SZ#/BJ# 前缀一律返回 None（云端跳过、"
                      "计入 missing_sample/coverage）；Swift 对同一条目查覆盖表得到 secid 并正常取数。"
                      "同一 file 两侧映射结果不同，是生产端分工（PC 独占扩展行情指数）而非口径漂移。",
            "entries": divergent,
        },
    }


# ---------------------------------------------------------------------------
# ④ indicator_templates.json —— 指标模板解析 golden
#    复用：check_indicators.parse_tdx（与 SystemIndicatorStore.parse 同规则）
# ---------------------------------------------------------------------------

def build_indicator_templates():
    folder = os.path.join(REPO_ROOT, "Kline", "Indicators")
    templates = []
    for path in sorted(glob.glob(os.path.join(folder, "*.tdx"))):
        fid = os.path.splitext(os.path.basename(path))[0]
        with open(path, "r", encoding="utf-8-sig") as fh:
            content = fh.read()
        name, scope, group, template = check_indicators.parse_tdx(content, fid)
        kind = None
        for raw in content.splitlines():
            line = raw.strip()
            if line.startswith("KIND="):
                kind = line[5:].strip().upper()
                break
        # SystemIndicatorStore.parse(:65-73)：KIND 缺失 → 通过；KIND=TECH → 通过；其余 → 拒载
        expected = "accepted" if (kind is None or kind == "TECH") else "rejected"
        templates.append({
            "fileName": os.path.basename(path),
            "kind": kind,
            "name": name,
            "scope": scope,
            "group": group,
            "formulaTemplate": "\n".join(template),
            "swiftExpected": expected,
        })
    return {
        "notes": "指标模板解析契约。name/scope/group/formulaTemplate 由 check_indicators.parse_tdx"
                 "（与 SystemIndicatorStore.parse 同规则）计算：SCOPE=MAIN/主图 → main 否则 sub；"
                 "formulaTemplate 为 FORMULA: 后各行以 '\\n' join（与 Swift formulaTemplate 一致）。"
                 "kind 从内容中提取 KIND= 行（本 corpus 全部缺失 → null）。swiftExpected：KIND 缺失或"
                 " TECH → accepted；出现 KIND= 且非 TECH → rejected（头部预扫描，含未知取值）。",
        "templates": templates,
    }


# ---------------------------------------------------------------------------

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    fixtures = [
        ("period_aggregation.json", build_period_aggregation()),
        ("quote_parsing.json", build_quote_parsing()),
        ("secid_mapping.json", build_secid_mapping()),
        ("indicator_templates.json", build_indicator_templates()),
    ]
    for name, payload in fixtures:
        path = write_json(name, payload)
        print("✅ %-28s %7d bytes" % (name, os.path.getsize(path)))
    cases = fixtures[0][1]["cases"]
    quote = fixtures[1][1]
    secid = fixtures[2][1]
    ind = fixtures[3][1]
    print("   周期用例 %d 组（%s）" % (len(cases), ", ".join(c["caseName"] for c in cases)))
    print("   东财快照 %d 标的 / 腾讯K线 %s 根 / 校准用例 %d 组"
          % (len(quote["eastmoneySnapshot"]["golden"]),
             "/".join(str(len(t["golden"])) for t in quote["tencentKline"]),
             len(quote["calibration"])))
    print("   secid 条目 %d（分歧 %d）/ 指标模板 %d 份"
          % (len(secid["entries"]), len(secid["knownDivergence"]["entries"]),
             len(ind["templates"])))


if __name__ == "__main__":
    main()

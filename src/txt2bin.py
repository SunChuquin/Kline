# -*- coding: utf-8 -*-
"""txt2bin.py — 通达信日线 txt(GBK) → Kline 二进制(klnb) 转换器

背景：Kline 数据源改版，iPad 直读二进制行情文件（Documents/tdx_data/*.bin）。
txt 只有日线；周/月/季/年线由 App 在设备端从日线实时聚合（语义对齐 tdx_parser.handle_data）。

bin 格式契约（Swift 侧 Kline/Kline/Data/BinFormat.swift 为权威定义，两者必须一致）：
  文件头 128B 小端:
    magic "KLNB"(4) | version UInt8(1) | recordSize UInt8(1)
    | code ASCII(16) | type UTF8(32) | name UTF8(64) | reserve(10)
    ⚠️ type 字段 2026-09-18 由 16 字节加宽到 32：最长取值「扩展行情指数」
      UTF-8 占 18 字节，按旧 16 字节写会被截成残缺 UTF-8（Swift 侧整段解码
      失败 → type 空串 → 行情/自选按 type 过滤全落空，表呈空）。
  数据区: N × recordSize 定长记录，小端
    Slim(36B)   : date UInt32(4) | open/high/low/close Float32(16) | vol UInt64(8) | amo Float64(8)
    Precise(52B): date UInt32(4) | open/high/low/close Float64(32) | vol UInt64(8) | amo Float64(8)
  count = (fileSize - 128) / recordSize，最后一条不完整记录忽略（append 中断安全）。

用法：
  python txt2bin.py --txd-data <dir> --outdir <dir> [--record float32|float64] [--subset N]
  python txt2bin.py --verify --db <tdx.db> --outdir <dir> [--sample N]  # 对照 tdx.db 校验一致性
"""

import argparse
import os
import re
import sqlite3
import struct
import sys
from datetime import datetime, timedelta

if hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except Exception:
        pass

MAGIC = b'KLNB'
VERSION = 1
HEADER_SIZE = 128
REC_SLIM = 36      # Float32 价格
REC_PRECISE = 52   # Float64 价格
PRICE_EPS = 1e-6

# 与 tdx_parser 相同的过滤规则
FILTER_PREFIX = ('42', '46', '12')
FILTER_FILES = {'62#H11014', '62#931265'}

HEADER_FMT = '<4sBB16s32s64s10s'          # 128B
SLIM_FMT = '<I4fQd'                        # 36B
PRECISE_FMT = '<I4dQd'                     # 52B


def windows_sort_key(filename: str):
    def convert(text: str):
        return int(text) if text.isdigit() else text.lower()
    return [convert(p) for p in re.split(r'(\d+)', filename)]


def gbk_lines(path: str):
    """按行读 GBK 文件到 List[str]，兼容增量场景的"去尾注释行"语义。"""
    with open(path, 'r', encoding='gbk') as fp:
        return fp.readlines()


def strip_footer(raw: list) -> list:
    """剥掉行首空白与尾部空行/注释行，只保留数据行。"""
    lines = []
    for ln in raw:
        s = ln.strip()
        if s and not s.startswith('#'):
            lines.append(s.replace('\r', ''))
    return lines


def parse_daily_lines(lines: list) -> list:
    """lines: 完整文件行（含头两行）→ [(date:int, o,h,l,c:float, vol:float|None, amo:float|None)]，按时间升序。"""
    rows = []
    for ln in lines[2:]:  # 跳过 <code> <name> 日线 前复权 与 列头行
        if not ln:
            continue
        parts = ln.split(';')
        if len(parts) < 7:
            continue
        try:
            date = int(parts[0])
            o, h, l, c = (float(parts[1]), float(parts[2]), float(parts[3]), float(parts[4]))
            vol = float(parts[5]) if parts[5] else None
            amo = float(parts[6]) if parts[6] else None
        except (ValueError, IndexError):
            continue
        rows.append((date, o, h, l, c, vol, amo))
    rows.sort(key=lambda r: r[0])  # 按日期升序（防御：文件内乱序）
    return rows


def classify_type(file_name: str) -> str:
    """与 tdx_parser._process_file 相同：file_name 不含 .txt 后缀。"""
    if file_name.split('#')[0] in ('SH', 'SZ'):
        return '沪深京指数' if file_name[:6] in ('SZ#399', 'SH#000', 'SH#999') else '沪深主板'
    return '扩展行情指数'


def make_header(code: str, name: str, ftype: str, record_size: int) -> bytes:
    def pad(s: bytes, n: int) -> bytes:
        return s[:n].ljust(n, b'\x00')

    # code：文件头存 ASCII/UTF-8（代码段本就半角）
    record = struct.pack(
        HEADER_FMT,
        MAGIC, VERSION, record_size,
        pad(code.encode('ascii', 'ignore'), 16),
        pad(ftype.encode('utf-8'), 32),
        pad(name.encode('utf-8'), 64),
        b'\x00' * 10,
    )
    assert len(record) == HEADER_SIZE, len(record)
    return record


def encode_record(rec, record_kind: str) -> bytes:
    date, o, h, l, c, vol, amo = rec
    vol_u = int(vol) if vol is not None else 0
    amo_f = float(amo) if amo is not None else 0.0
    if record_kind == 'float32':
        return struct.pack(SLIM_FMT, date, o, h, l, c, vol_u, amo_f)
    return struct.pack(PRECISE_FMT, date, o, h, l, c, vol_u, amo_f)


def decode_record(buf: bytes, record_kind: str) -> tuple:
    if record_kind == 'float32':
        date, o, h, l, c, vol, amo = struct.unpack(SLIM_FMT, buf)
    else:
        date, o, h, l, c, vol, amo = struct.unpack(PRECISE_FMT, buf)
    return date, o, h, l, c, float(vol), amo


def convert_file(src_txt: str, out_bin: str, record_kind: str) -> dict:
    """单文件转换，返回结果信息（含过滤原因）。"""
    raw = gbk_lines(src_txt)
    lines = strip_footer(raw)
    if len(lines) < 3:
        return {'skipped': True, 'reason': '条件过滤', 'detail': '文件过短'}

    first = lines[0]
    info_parts = re.split(r'\s+', first.strip())
    code = info_parts.pop(0) if info_parts else ''
    # 去掉尾部 "日线 前复权" 两个词
    if len(info_parts) >= 2:
        info_parts = info_parts[:-2]
    name = ' '.join(info_parts)

    base = os.path.basename(src_txt)[:-4]
    if '债' in name or base.split('#')[0] in FILTER_PREFIX or base in FILTER_FILES:
        return {'skipped': True, 'reason': '条件过滤', 'detail': base}

    rows = parse_daily_lines(lines)
    if not rows:
        return {'skipped': True, 'reason': '条件过滤', 'detail': '无数据行'}

    ftype = classify_type(base)
    header = make_header(code, name, ftype, REC_SLIM if record_kind == 'float32' else REC_PRECISE)
    with open(out_bin, 'wb') as fp:
        fp.write(header)
        for rec in rows:
            fp.write(encode_record(rec, record_kind))
    return {'skipped': False, 'base': base, 'code': code, 'name': name,
            'type': ftype, 'rows': len(rows),
            'first': rows[0][0], 'last': rows[-1][0]}


def convert_all(txd_data: str, outdir: str, record_kind: str, subset: int = 0):
    os.makedirs(outdir, exist_ok=True)
    files = sorted(os.listdir(txd_data), key=windows_sort_key)
    files = [f for f in files if f.lower().endswith('.txt')]
    if subset > 0:
        files = files[:subset]

    ok, skipped, total_rows = 0, [], 0
    for i, f in enumerate(files, 1):
        src = os.path.join(txd_data, f)
        base = f[:-4]
        r = convert_file(src, os.path.join(outdir, base + '.bin'), record_kind)
        if r['skipped']:
            skipped.append(f)
        else:
            ok += 1
            total_rows += r['rows']
        if i % 500 == 0 or i == len(files):
            pct = i * 100 // max(len(files), 1)
            sys.stdout.write(f'\r  进度: {i}/{len(files)} ({pct}%) {f[:24]}')
            sys.stdout.flush()
    print()
    print(f'✅ 完成: 生成 {ok} 个 .bin（跳过滤除 {len(skipped)} 个），日线记录总数 {total_rows}')
    if skipped:
        print(f'   过滤示例: {skipped[:5]}')


# ---------------------------------------------------------------- 校验(对照 tdx.db)

def load_db_meta(db: sqlite3.Connection):
    cur = db.execute('SELECT file, id, first_date, last_date FROM meta ORDER BY id')
    return {r[0]: (r[1], r[2], r[3]) for r in cur.fetchall()}


def db_daily(db: sqlite3.Connection, meta_id: int):
    cur = db.execute('SELECT date, open, high, low, close, vol, amo FROM daily WHERE meta_id=? ORDER BY date', (meta_id,))
    return cur.fetchall()


def db_period(db: sqlite3.Connection, meta_id: int, table: str):
    cur = db.execute(
        f'SELECT date, open, high, low, close, vol, amo FROM {table} WHERE meta_id=? ORDER BY date', (meta_id,))
    return cur.fetchall()


def aggregate_periods(rows):
    """移植 tdx_parser.handle_data 的周/月/季/年聚合语义。

    rows: [(date,o,h,l,c,vol,amo), ...] 升序，vol/amo 允许 None。
    返回 {period: [(date,o,h,l,c,vol,amo), ...]}，date 为该周期桶内首个交易日。
    """
    date_cache = {}

    def monday(d):
        if d in date_cache:
            return date_cache[d]
        dt = datetime.strptime(str(d), '%Y%m%d')
        md = (dt - timedelta(days=dt.weekday())).strftime('%Y%m%d')
        date_cache[d] = int(md)
        return date_cache[d]

    def period_key(d, period):
        s = str(d)
        y = int(s[:4]); m = int(s[4:6])
        if period == 'weekly':
            return monday(d)
        if period == 'monthly':
            return y * 100 + m
        if period == 'quarterly':
            return y * 10 + (m - 1) // 3 + 1
        return y

    out = {p: [] for p in ('weekly', 'monthly', 'quarterly', 'yearly')}
    cur = {p: None for p in out}      # 当前桶 [date,o,h,l,c,vol,amo]
    last_key = {p: None for p in out}
    for (d, o, h, l, c, vol, amo) in rows:
        v0 = vol if vol is not None else 0.0
        a0 = amo if amo is not None else 0.0
        for p in out:
            k = period_key(d, p)
            bucket = cur[p]
            if bucket is None:
                cur[p] = [d, o, h, l, c, v0, a0]
            elif k != last_key[p]:
                out[p].append(tuple(bucket))       # 封桶进结果
                cur[p] = [d, o, h, l, c, v0, a0]
            else:
                bucket[2] = max(bucket[2], h)      # high
                bucket[3] = min(bucket[3], l)      # low
                bucket[4] = c                      # close = 桶内最后一根收盘
                bucket[5] += v0
                bucket[6] += a0
            last_key[p] = k
    for p in out:
        if cur[p] is not None:
            out[p].append(tuple(cur[p]))
    return out


def rows_to_bin_rows(rows, record_kind):
    """DataFrame-like：txt 行 → 按 bin 解码后数值（用 encode+decode 模拟设备端 Float 截断）。"""
    out = []
    for r in rows:
        raw = encode_record(r, record_kind)
        out.append(decode_record(raw, record_kind))
    return out


def close_enough(a, b, eps=1e-3):
    return abs(a - b) <= max(eps, abs(b) * 1e-4)


def verify_dir(outdir: str, db_path: str, record_kind: str, sample: int = 0):
    db = sqlite3.connect(f'file:{db_path}?mode=ro', uri=True)
    meta = load_db_meta(db)
    bins = sorted([f for f in os.listdir(outdir) if f.endswith('.bin')], key=windows_sort_key)
    if sample > 0:
        bins = bins[:sample]

    daily_bad, period_bad, n = [], [], 0
    for b in bins:
        base = b[:-4]
        if base not in meta:
            continue
        meta_id = meta[base][0]
        with open(os.path.join(outdir, b), 'rb') as fp:
            buf = fp.read()
        date, o, h, l, c, vol, amo = decode_record(buf[HEADER_SIZE:HEADER_SIZE + (REC_SLIM if record_kind == 'float32' else REC_PRECISE)], record_kind)
        n += 1
        # bin 日线 → 聚合（与设备端同语义），再与 db 周期表比对
        rows = []
        rec_size = REC_SLIM if record_kind == 'float32' else REC_PRECISE
        cnt = (len(buf) - HEADER_SIZE) // rec_size
        for i in range(cnt):
            start = HEADER_SIZE + i * rec_size
            rows.append(decode_record(buf[start:start + rec_size], record_kind))
        agg = aggregate_periods(rows)

        db_rows = db_daily(db, meta_id)
        if len(db_rows) != len(rows):
            daily_bad.append((base, 'daily count', len(db_rows), len(rows)))
            continue
        for (dr, br) in zip(db_rows, rows):
            if not (dr[0] == br[0]
                    and close_enough(dr[1], br[1]) and close_enough(dr[2], br[2])
                    and close_enough(dr[3], br[3]) and close_enough(dr[4], br[4])):
                daily_bad.append((base, 'daily value', dr[0], br[0]))
                break

        for p, table in [('weekly', 'weekly'), ('monthly', 'monthly'),
                         ('quarterly', 'quarterly'), ('yearly', 'yearly')]:
            dbr = db_period(db, meta_id, table)
            br = agg[p]
            if len(dbr) != len(br):
                period_bad.append((base, table, 'count', len(dbr), len(br)))
                continue
            for (a, b2) in zip(dbr, br):
                if not (int(a[0]) == int(b2[0])
                        and close_enough(a[1], b2[1]) and close_enough(a[2], b2[2])
                        and close_enough(a[3], b2[3]) and close_enough(a[4], b2[4])
                        and int(a[5] or 0) == int(b2[5]) and close_enough(a[6] or 0, b2[6], 1.0)):
                    period_bad.append((base, table, 'value', a[0], b2[0]))
                    break
        if n % 200 == 0:
            print(f'  ... 已校验 {n}/{len(bins)}')
    db.close()
    print(f'✅ 校验: 样本 {n}，日线不一致 {len(daily_bad)}，周期表不一致 {len(period_bad)}')
    if daily_bad:
        print('   日线不一致示例:', daily_bad[:5])
    if period_bad:
        print('   周期不一致示例:', period_bad[:5])
    return not daily_bad and not period_bad


def main():
    ap = argparse.ArgumentParser(description='通达信日线 txt → Kline .bin')
    ap.add_argument('--txd-data', default=r'C:\Users\sunck\home\tdx_data', help='txt 源目录')
    ap.add_argument('--outdir', default=r'C:\Users\sunck\home\tdx_bin', help='bin 输出目录')
    ap.add_argument('--record', choices=['float32', 'float64'], default='float32',
                    help='价格精度（float32=Slim 36B，float64=Precise 52B）')
    ap.add_argument('--subset', type=int, default=0, help='仅转换前 N 个文件（种子测试用）')
    ap.add_argument('--verify', action='store_true', help='校验模式：对照 tdx.db 检查一致性')
    ap.add_argument('--db', default=r'C:\Users\sunck\home\tdx.db', help='校验用的 tdx.db 路径')
    ap.add_argument('--sample', type=int, default=0, help='校验样本数（0=全部）')
    args = ap.parse_args()

    if args.verify:
        ok = verify_dir(args.outdir, args.db, args.record, args.sample)
        sys.exit(0 if ok else 1)
    convert_all(args.txd_data, args.outdir, args.record, args.subset)


if __name__ == '__main__':
    main()
# 脚本名称: tdx_parser2.py

import sqlite3, os, re, sys, time, threading
from datetime import datetime, date, timedelta
from typing import List, Dict, Any, Optional, Tuple
from tdx_parser import TDXDatabase, sort_like_windows


# 强制以 UTF-8 输出/读取，避免 Windows 控制台中文乱码
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stdin.reconfigure(encoding='utf-8')


class TDXDataGenerator2:
    def __init__(self, is_del: bool = False, is_demo: bool = False):
        self.db = './tdx.db'
        self.base_path = '../../tdx_data/'
        self.skipped_files = {'无变更': [], '条件过滤': [], '编码错误': [], '未知异常': []}
        self.date_cache = {}
        self.is_demo = is_demo

        print(f"{'全量更新' if is_del else '增量更新'}")
        if os.path.exists(self.db):
            if is_del:
                os.remove(self.db)
                print(f"\n已删除旧数据库: {self.db}")
        else:
            is_del = True

        self.conn = sqlite3.connect(self.db)
        self.conn.execute("PRAGMA journal_mode=WAL;")
        self.conn.execute("PRAGMA synchronous=NORMAL;")
        self.cursor = self.conn.cursor()
        if is_del:
            self.create_empty_db()

        self.create_db_data()
        self.show()

        self.conn.commit()
        self.conn.close()

    def create_empty_db(self):
        self.cursor.execute("""
            CREATE TABLE meta (
                id INTEGER PRIMARY KEY,
                file TEXT COLLATE BINARY UNIQUE,
                code TEXT,
                name TEXT,
                type TEXT,
                first_date INTEGER COLLATE BINARY,
                last_date INTEGER COLLATE BINARY,
                last_size INTEGER
            )
        """)
        self.cursor.execute("""
            CREATE TABLE daily (
                meta_id INTEGER,
                date INTEGER COLLATE BINARY,
                open REAL,
                high REAL,
                low REAL,
                close REAL,
                vol REAL,
                amo REAL,
                PRIMARY KEY (meta_id, date),
                FOREIGN KEY (meta_id) REFERENCES meta(id)
            )
        """)
        self.cursor.execute("""
            CREATE TABLE weekly (
                meta_id INTEGER,
                date INTEGER COLLATE BINARY,
                open REAL,
                high REAL,
                low REAL,
                close REAL,
                vol REAL,
                amo REAL,
                PRIMARY KEY (meta_id, date),
                FOREIGN KEY (meta_id) REFERENCES meta(id)
            )
        """)
        self.cursor.execute("""
            CREATE TABLE monthly (
                meta_id INTEGER,
                date INTEGER COLLATE BINARY,
                open REAL,
                high REAL,
                low REAL,
                close REAL,
                vol REAL,
                amo REAL,
                PRIMARY KEY (meta_id, date),
                FOREIGN KEY (meta_id) REFERENCES meta(id)
            )
        """)
        print(f"✅ 空数据库创建成功: {self.db}")
        print("   包含表: daily, weekly, monthly, meta")

    def precompute_monday_cache_by_range(self):
        start_date = datetime(1990, 1, 1)
        end_date = datetime.now()
        current = start_date

        while current <= end_date:
            date_int = int(current.strftime('%Y%m%d'))
            if current.weekday() < 7:
                monday = current - timedelta(days=current.weekday())
                self.date_cache[date_int] = int(monday.strftime('%Y%m%d'))
            current += timedelta(days=1)

        print(f"✅ 日期映射表预计算完成，共 {len(self.date_cache)} 个交易日。")

    def handle_data(self, meta_id, content, last_monday, weekly_groups, last_month, monthly_groups):
        daily_rows = []

        for line in content:
            parts = line.split(';')
            parts[-1] = parts[-1].strip()
            row = [
                meta_id,
                int(parts[0]),
                float(parts[1]),
                float(parts[2]),
                float(parts[3]),
                float(parts[4]),
                float(parts[5]) if parts[5] else None,
                float(parts[6]) if parts[6] else None
            ]
            daily_rows.append(row)

            date_int = row[1]
            if last_monday is None:
                last_monday = self.date_cache[date_int]
                weekly_groups[last_monday] = row.copy()
            else:
                current_monday = self.date_cache[date_int]
                if current_monday == last_monday:
                    cur = weekly_groups[current_monday]
                    cur[3] = max(cur[3], row[3])
                    cur[4] = min(cur[4], row[4])
                    cur[5] = row[5]
                    cur[6] += row[6]
                    cur[7] += row[7]
                else:
                    weekly_groups[current_monday] = row.copy()
                    last_monday = current_monday

            if last_month is None:
                last_month = self.date_cache[date_int]
                monthly_groups[last_month] = row.copy()
            else:
                current_month = self.date_cache[date_int]
                if current_month == last_month:
                    cur = monthly_groups[current_month]
                    cur[3] = max(cur[3], row[3])
                    cur[4] = min(cur[4], row[4])
                    cur[5] = row[5]
                    cur[6] += row[6]
                    cur[7] += row[7]
                else:
                    monthly_groups[current_month] = row.copy()
                    last_month = current_month
        return [daily_rows, list(weekly_groups.values()), list(monthly_groups.values())]

    def _process_file(self, file, meta_id, exist_meta, exist_weekly, exist_monthly, exist_file):
        result = {
            'skipped': False,
            'skip_reason': None,
            'skip_detail': None,
            'meta_value': None,
            'daily_rows': None,
            'weekly_rows': None,
            'monthly_rows': None,
            'file': file,
            'meta_id': meta_id,
        }

        try:
            file_name = file[:-4]
            kline_fields = ['meta_id', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo']
            weekly_fields = ['meta_id', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo']
            monthly_fields = ['meta_id', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo']

            last_size = exist_meta[file_name]['last_size'] if file_name in exist_meta else 0
            if last_size > 0:
                if os.path.getsize(os.path.join(self.base_path, file)) == last_size:
                    result['skipped'] = True
                    result['skip_reason'] = '无变更'
                    return result
                last_size -= 18

            with open(os.path.join(self.base_path, file), 'r', encoding='gbk') as fp:
                fp.seek(last_size)
                content = fp.readlines()

                if last_size == 0:
                    info_parts = re.split(r'\s+', content.pop(0).strip())
                    code = info_parts.pop(0)
                    info_parts.pop(-1)
                    info_parts.pop(-1)
                    name = ' '.join(info_parts)
                    if '债' in name:
                        result['skipped'] = True
                        result['skip_reason'] = '条件过滤'
                        return result
                    content.pop(0)
                content.pop(-1)

                if not len(content) or file.split('#')[0] in ['42', '46', '12'] or file_name in ['62#H11014', '62#931265']:
                    result['skipped'] = True
                    result['skip_reason'] = '条件过滤'
                    return result

                if file_name in exist_file:
                    file_type = exist_meta[file_name]['type']
                    first_date = exist_meta[file_name]['first_date']
                    last_date = content[-1][:8]
                    last_monday = self.date_cache[exist_weekly[meta_id]['last_date']]
                    weekly_groups = exist_weekly[meta_id].copy()
                    weekly_groups.pop('last_date')
                    weekly_groups = {last_monday: [weekly_groups[item] for item in weekly_fields]}
                    last_month = int(str(exist_monthly[meta_id]['last_date'])[:6]) if meta_id in exist_monthly else None
                    monthly_groups = exist_monthly[meta_id].copy() if meta_id in exist_monthly else {}
                    if meta_id in exist_monthly:
                        monthly_groups.pop('last_date')
                        monthly_groups = {last_month: [monthly_groups[item] for item in monthly_fields]}
                    else:
                        monthly_groups = {}
                    meta_value = [file_name, code, name, file_type, first_date, last_date, fp.tell()]
                else:
                    file_type = '扩展行情指数'
                    if file_name.split('#')[0] in ['SH', 'SZ']:
                        file_type = '沪深京指数' if file_name[:6] in ['SZ#399', 'SH#000', 'SH#999'] else '沪深主板'
                    first_date = content[0][:8]
                    last_date = content[-1][:8]
                    meta_value = [file_name, code, name, file_type, first_date, last_date, fp.tell()]
                    last_monday = None
                    weekly_groups = {}
                    last_month = None
                    monthly_groups = {}

                daily_rows, weekly_rows, monthly_rows = self.handle_data(meta_id, content, last_monday, weekly_groups, last_month, monthly_groups)

                result['meta_value'] = meta_value
                result['daily_rows'] = daily_rows
                result['weekly_rows'] = weekly_rows
                result['monthly_rows'] = monthly_rows

        except UnicodeDecodeError as e:
            result['skipped'] = True
            result['skip_reason'] = '编码错误'
            result['skip_detail'] = [file, f'{str(e)[:30]}']
        except Exception as e:
            result['skipped'] = True
            result['skip_reason'] = '未知异常'
            result['skip_detail'] = [file, f'{str(e)[:50]}']

        return result

    def create_db_data(self):
        self.precompute_monday_cache_by_range()

        meta_fields = ['file', 'code', 'name', 'type', 'first_date', 'last_date', 'last_size']
        kline_fields = ['meta_id', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo']
        weekly_fields = ['meta_id', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo']
        monthly_fields = ['meta_id', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo']
        if self.is_demo:
            file_list = ["c:\\Users\\sunck\\home\\export\\data\\SH#999999.txt"]
        else:
            file_list = sort_like_windows(os.listdir(self.base_path))
        total_files = len(file_list)
        processed = 0

        print(f"\n📁 开始导入数据（日线 + 周线同步生成），共 {total_files} 个文件...")
        with TDXDatabase(self.db) as db:
            exist_meta = db.query("SELECT id, file, code, name, first_date, last_size, type FROM meta ORDER BY id;")
            exist_weekly = db.query("SELECT meta_id, date, open, high, low, close, vol, amo, MAX(date) AS last_date FROM weekly GROUP BY meta_id;")
            exist_monthly = db.query("SELECT meta_id, date, open, high, low, close, vol, amo, MAX(date) AS last_date FROM monthly GROUP BY meta_id;")

            exist_meta = {item['file']: item for item in exist_meta}
            exist_weekly = {item['meta_id']: item for item in exist_weekly}
            exist_monthly = {item['meta_id']: item for item in exist_monthly}
            exist_file = exist_meta.keys()

            next_id = len(exist_meta) + 1
            file_id_map = {}
            for file in file_list:
                file_name = file[:-4]
                if file_name in exist_meta:
                    file_id_map[file] = exist_meta[file_name]['id']
                else:
                    file_id_map[file] = next_id
                    next_id += 1

            for i in range(0, total_files, 2):
                file1 = file_list[i]
                file2 = file_list[i + 1] if i + 1 < total_files else None

                meta_id1 = file_id_map[file1]
                meta_id2 = file_id_map[file2] if file2 else None

                results = [None, None]

                def worker(idx, file, meta_id):
                    if file is None:
                        return
                    results[idx] = self._process_file(
                        file, meta_id, exist_meta, exist_weekly, exist_monthly, exist_file
                    )

                t1 = threading.Thread(target=worker, args=(0, file1, meta_id1))
                threads = [t1]
                if file2:
                    t2 = threading.Thread(target=worker, args=(1, file2, meta_id2))
                    threads.append(t2)

                for t in threads:
                    t.start()
                for t in threads:
                    t.join()

                for result in results:
                    if result is None:
                        continue
                    if result['skipped']:
                        if result['skip_reason'] == '无变更':
                            self.skipped_files['无变更'].append(result['file'])
                        elif result['skip_reason'] == '条件过滤':
                            self.skipped_files['条件过滤'].append(result['file'])
                        elif result['skip_reason'] == '编码错误':
                            self.skipped_files['编码错误'].append(result['skip_detail'])
                        elif result['skip_reason'] == '未知异常':
                            self.skipped_files['未知异常'].append(result['skip_detail'])
                    else:
                        db.insert_tables({
                            'meta': [meta_fields, [result['meta_value']]],
                            'daily': [kline_fields, result['daily_rows']],
                            'weekly': [weekly_fields, result['weekly_rows']],
                            'monthly': [monthly_fields, result['monthly_rows']],
                        })

                processed += len([r for r in results if r is not None])
                progress = (processed / total_files) * 100 if total_files > 0 else 0
                if processed % 10 == 0 or processed == total_files:
                    bar_length = 30
                    filled = int(bar_length * processed // total_files) if total_files > 0 else 0
                    bar = '█' * filled + '░' * (bar_length - filled)
                    current_file = file2 if file2 else file1
                    sys.stdout.write(f'\r  进度: [{bar}] {progress:.1f}% ({processed}/{total_files}) 当前文件: {current_file[:20]}')
                    sys.stdout.flush()

        print(f"✅ 数据导入完成！共处理 {total_files} 个文件")
        if self.skipped_files:
            a = len(self.skipped_files['无变更'])
            b = len(self.skipped_files['条件过滤'])
            c = len(self.skipped_files['编码错误'])
            d = len(self.skipped_files['未知异常'])
            print(f"\n⚠️ 无变更{a}个文件, 条件过滤{b}个文件, 编码错误{c}个文件, 未知异常{d}个文件")
            for i in range(c):
                print(f"编码错误: {self.skipped_files['编码错误'][i]}")
            for i in range(d):
                print(f"未知异常: {self.skipped_files['未知异常'][i]}")
        else:
            print("✅ 所有文件均成功导入，无跳过记录。")

    def show(self):
        pass


if __name__ == "__main__":
    param = input('是否默认使用增量更新？如果是，请直接回车, 否则请输入任意字符再回车, 进行全量更新 > ')
    param = False if param == '' else True

    print(f"\n开始时间: {time.strftime('%Y.%m.%d   %H:%M:%S')}")
    time0 = time.time()
    tdx = TDXDataGenerator2(param)
    #tdx = TDXDataGenerator2(param, is_demo=True)
    time1 = time.time()
    print(f"结束时间: {time.strftime('%Y.%m.%d   %H:%M:%S')}")

    _ = round((time1 - time0), 4)
    if int(_ // 60):
        print(f'run time:{int(_ // 60)}分{int(_ % 60)}秒')
    else:
        print(f'run time:{int(_ % 60)}秒')
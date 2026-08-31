# 脚本名称: tdx_parser2.py

import sqlite3, os, re, sys, time, threading, platform
from datetime import datetime, date, timedelta
from typing import List, Dict, Any, Optional, Tuple


# 强制以 UTF-8 输出/读取，避免 Windows 控制台中文乱码
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stdin.reconfigure(encoding='utf-8')

class TDXDatabase:
    """
    通达信数据库操作封装类
    用于访问和操作 tdx.db 中的 daily, weekly, meta, concept, index 表
    """

    # 定义允许操作的表名和对应的字段，防止 SQL 注入和非法操作
    TABLE_SCHEMA = {
        'daily': ['file', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo'],
        'weekly': ['file', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo'],
        'monthly': ['file', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo'],
        'quarterly': ['file', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo'],
        'yearly': ['file', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo'],
        'meta': ['file', 'name', 'type', 'code'],
    }

    def __init__(self, db_path: str):
        """
        初始化数据库连接

        Args:
            db_path: SQLite 数据库文件的路径
        """
        self.db_path = db_path
        self.conn = None
        self.cursor = None

        # 检查文件是否存在，如果不存在则尝试创建空数据库
        if not os.path.exists(db_path):
            print(f"警告: 数据库文件 {db_path} 不存在，将创建新文件")
            # 创建目录（如果路径包含文件夹）
            os.makedirs(os.path.dirname(db_path), exist_ok=True)

        self._connect()

    def _connect(self):
        """建立数据库连接"""
        try:
            self.conn = sqlite3.connect(self.db_path)
            self.conn.row_factory = sqlite3.Row  # 使查询结果可以通过列名访问
            self.cursor = self.conn.cursor()
            # 开启外键约束（如果需要）
            # self.cursor.execute("PRAGMA foreign_keys = ON;")
            print(f"成功连接到数据库: {self.db_path}")
        except sqlite3.Error as e:
            print(f"连接数据库失败: {e}")
            raise

    def close(self):
        """关闭数据库连接"""
        if self.conn:
            self.conn.close()
            print("数据库连接已关闭")

    def __enter__(self):
        """支持 with 语句"""
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """退出 with 语句时自动关闭连接"""
        self.close()

    def _validate_table_and_fields(self, table: str, fields: List[str]) -> None:
        """
        校验表名和字段是否合法

        Args:
            table: 表名
            fields: 字段列表

        Raises:
            ValueError: 如果表名或字段不合法
        """
        if table not in self.TABLE_SCHEMA:
            raise ValueError(f"非法表名: {table}，允许的表名: {list(self.TABLE_SCHEMA.keys())}")

        valid_fields = self.TABLE_SCHEMA[table]
        for field in fields:
            if field not in valid_fields:
                raise ValueError(f"表 {table} 中不存在字段: {field}，合法字段: {valid_fields}")

    def insert(self, table: str, data: Dict[str, Any]) -> int:
        """
        插入一行数据

        Args:
            table: 表名
            data: 字段名 -> 值的字典

        Returns:
            int: 插入的行ID (lastrowid)
        """
        fields = list(data.keys())
        self._validate_table_and_fields(table, fields)

        placeholders = ','.join(['?' for _ in fields])
        field_names = ','.join(fields)
        values = [data[field] for field in fields]

        sql = f"INSERT OR REPLACE INTO {table} ({field_names}) VALUES ({placeholders})"

        try:
            self.cursor.execute(sql, values)
            self.conn.commit()
            return self.cursor.lastrowid
        except sqlite3.Error as e:
            self.conn.rollback()
            print(f"插入数据失败: {e}")
            raise

    def insert_bulk(self, table: str, fields: List[Any], values_list: List[List[Any]]) -> int:
        """
        批量插入数据 (高效)

        Args:
            table: 表名
            fields: 列表，每个代表一行字段
            values_list: 列表，每个代表一行数据

        Returns:
            int: 受影响的行数
        """
        placeholders = ','.join(['?' for _ in fields])
        field_names = ','.join(fields)

        sql = f"INSERT OR REPLACE INTO {table} ({field_names}) VALUES ({placeholders})"

        try:
            self.cursor.executemany(sql, values_list)
            self.conn.commit()
            return self.cursor.rowcount
        except sqlite3.Error as e:
            self.conn.rollback()
            print(f"批量插入失败: {e}")
            raise

    def insert_tables(self, data: Dict) -> int:
        """
        批量插入多张表的数据 (高效)

        :param data:

        Returns:
            int: 受影响的行数
        """
        is_commit = False
        try:
            for table in data.keys():
                fields = data[table][0]
                values_list = data[table][1]
                if len(values_list) == 0 or values_list[0] is None:
                    continue
                is_commit = True

                placeholders = ','.join(['?' for _ in fields])
                field_names = ','.join(fields)

                sql = f"INSERT OR REPLACE INTO {table} ({field_names}) VALUES ({placeholders})"

                self.cursor.executemany(sql, values_list)
        except sqlite3.Error as e:
            self.conn.rollback()
            print(f"批量插入失败: {e}")
            raise
        if is_commit:
            self.conn.commit()
        return self.cursor.rowcount

    def query(self, sql: str, params: Tuple = ()) -> List[Dict[str, Any]]:
        """
        执行自定义查询 SQL，返回结果列表

        Args:
            sql: SQL 查询语句
            params: 参数元组，用于参数化查询

        Returns:
            List[Dict]: 查询结果列表，每行是一个字典
        """
        try:
            self.cursor.execute(sql, params)
            rows = self.cursor.fetchall()
            return [dict(row) for row in rows]
        except sqlite3.Error as e:
            print(f"查询失败: {e}")
            raise

    def query_one(self, sql: str, params: Tuple = ()) -> Optional[Dict[str, Any]]:
        """
        执行查询，返回第一条结果

        Args:
            sql: SQL 查询语句
            params: 参数元组

        Returns:
            Dict or None: 第一条结果，如果没有结果则返回 None
        """
        try:
            self.cursor.execute(sql, params)
            row = self.cursor.fetchone()
            return dict(row) if row else None
        except sqlite3.Error as e:
            print(f"查询失败: {e}")
            raise

    def select(
            self,
            table: str,
            fields: List[str] = None,
            where: str = None,
            where_params: Tuple = (),
            order_by: str = None,
            limit: int = None,
            offset: int = None
    ) -> List[Dict[str, Any]]:
        """
        便捷查询方法：从指定表中选择数据

        Args:
            table: 表名
            fields: 要查询的字段列表，默认查询所有字段 ('*')
            where: WHERE 子句 (不含 'WHERE' 关键字)，如 'file = ? AND date > ?'
            where_params: WHERE 子句的参数
            order_by: ORDER BY 子句 (不含 'ORDER BY' 关键字)
            limit: LIMIT 数量
            offset: OFFSET 数量

        Returns:
            List[Dict]: 查询结果列表
        """
        if table not in self.TABLE_SCHEMA:
            raise ValueError(f"非法表名: {table}")

        field_str = '*' if fields is None else ','.join(fields)
        sql = f"SELECT {field_str} FROM {table}"

        if where:
            sql += f" WHERE {where}"
        if order_by:
            sql += f" ORDER BY {order_by}"
        if limit is not None:
            sql += f" LIMIT {limit}"
        if offset is not None:
            sql += f" OFFSET {offset}"

        return self.query(sql, where_params)

    def update(
            self,
            table: str,
            data: Dict[str, Any],
            where: str,
            where_params: Tuple = ()
    ) -> int:
        """
        更新数据

        Args:
            table: 表名
            data: 要更新的字段名 -> 值字典
            where: WHERE 子句 (不含 'WHERE' 关键字)
            where_params: WHERE 子句的参数

        Returns:
            int: 受影响的行数
        """
        fields = list(data.keys())
        self._validate_table_and_fields(table, fields)

        set_clause = ','.join([f"{field}=?" for field in fields])
        values = [data[field] for field in fields] + list(where_params)

        sql = f"UPDATE {table} SET {set_clause} WHERE {where}"

        try:
            self.cursor.execute(sql, values)
            self.conn.commit()
            return self.cursor.rowcount
        except sqlite3.Error as e:
            self.conn.rollback()
            print(f"更新失败: {e}")
            raise

    def delete(self, table: str, where: str, where_params: Tuple = ()) -> int:
        """
        删除数据

        Args:
            table: 表名
            where: WHERE 子句 (不含 'WHERE' 关键字)
            where_params: WHERE 子句的参数

        Returns:
            int: 受影响的行数
        """
        if table not in self.TABLE_SCHEMA:
            raise ValueError(f"非法表名: {table}")

        sql = f"DELETE FROM {table} WHERE {where}"

        try:
            self.cursor.execute(sql, where_params)
            self.conn.commit()
            return self.cursor.rowcount
        except sqlite3.Error as e:
            self.conn.rollback()
            print(f"删除失败: {e}")
            raise

def is_today(date_string):
    return datetime.strptime(date_string, '%Y%m%d').date() == date.today()

def windows_sort_key(filename):
    """
    模拟 Windows 资源管理器的排序规则
    """

    def convert(text):
        # 将数字转换为整数，文本转为小写
        return int(text) if text.isdigit() else text.lower()

    # 拆分数字和文本
    parts = re.split(r'(\d+)', filename)
    return [convert(part) for part in parts]

def sort_like_windows(file_list):
    """按 Windows 风格排序"""
    return sorted(file_list, key=windows_sort_key)


class TDXDataGenerator:
    def __init__(self, is_del: bool = False, is_demo: bool = False):
        self.db = '../../tdx.db' if platform.system() != 'Windows' else '../../../../tdx.db'
        self.base_path = '../../tdx_data/' if platform.system() != 'Windows' else '../../../../tdx_data/'
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
        self.cursor.execute("""
            CREATE TABLE quarterly (
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
            CREATE TABLE yearly (
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
        print("   包含表: daily, weekly, monthly, quarterly, yearly, meta")

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

    def period_key(self, date_int, period):
        """按周期将交易日 YYYYMMDD 归到对应的分组键"""
        s = str(date_int)
        year = int(s[:4])
        month = int(s[4:6])
        if period == 'weekly':
            return self.date_cache[date_int]      # 所在周的周一
        if period == 'monthly':
            return year * 100 + month             # YYYYMM
        if period == 'quarterly':
            return year * 10 + (month - 1) // 3 + 1  # YYYYQ, Q=1~4
        if period == 'yearly':
            return year                           # YYYY
        raise ValueError(f"未知周期: {period}")

    def handle_data(self, meta_id, content, init_states):
        daily_rows = []
        periods = ['weekly', 'monthly', 'quarterly', 'yearly']
        state = {}
        for p in periods:
            last_key, groups = init_states.get(p, (None, {}))
            state[p] = [last_key, groups]

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

            for p in periods:
                key = self.period_key(row[1], p)
                last_key, groups = state[p]
                if key != last_key:
                    groups[key] = row.copy()
                    state[p][0] = key
                else:
                    cur = groups[key]
                    cur[3] = max(cur[3], row[3])
                    cur[4] = min(cur[4], row[4])
                    cur[5] = row[5]
                    cur[6] += row[6]
                    cur[7] += row[7]

        return [
            daily_rows,
            list(state['weekly'][1].values()),
            list(state['monthly'][1].values()),
            list(state['quarterly'][1].values()),
            list(state['yearly'][1].values()),
        ]

    def _process_file(self, file, meta_id, exist_meta, exist_periods, exist_file):
        result = {
            'skipped': False,
            'skip_reason': None,
            'skip_detail': None,
            'meta_value': None,
            'daily_rows': None,
            'weekly_rows': None,
            'monthly_rows': None,
            'quarterly_rows': None,
            'yearly_rows': None,
            'file': file,
            'meta_id': meta_id,
        }

        try:
            file_name = file[:-4]
            kline_fields = ['meta_id', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo']
            period_fields = ['date', 'open', 'high', 'low', 'close', 'vol', 'amo']

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

                init_states = {}
                if file_name in exist_file:
                    file_type = exist_meta[file_name]['type']
                    first_date = exist_meta[file_name]['first_date']
                    last_date = content[-1][:8]
                    meta_value = [meta_id, file_name, code, name, file_type, first_date, last_date, fp.tell()]
                    for p in exist_periods:
                        emap = exist_periods[p]
                        if meta_id in emap:
                            last_date_int = emap[meta_id]['last_date']
                            key = self.period_key(last_date_int, p)
                            row = [meta_id] + [emap[meta_id][f] for f in period_fields]
                            init_states[p] = (key, {key: row})
                else:
                    file_type = '扩展行情指数'
                    if file_name.split('#')[0] in ['SH', 'SZ']:
                        file_type = '沪深京指数' if file_name[:6] in ['SZ#399', 'SH#000', 'SH#999'] else '沪深主板'
                    first_date = content[0][:8]
                    last_date = content[-1][:8]
                    meta_value = [meta_id, file_name, code, name, file_type, first_date, last_date, fp.tell()]

                daily_rows, weekly_rows, monthly_rows, quarterly_rows, yearly_rows = self.handle_data(meta_id, content, init_states)

                result['meta_value'] = meta_value
                result['daily_rows'] = daily_rows
                result['weekly_rows'] = weekly_rows
                result['monthly_rows'] = monthly_rows
                result['quarterly_rows'] = quarterly_rows
                result['yearly_rows'] = yearly_rows

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

        meta_fields = ['id', 'file', 'code', 'name', 'type', 'first_date', 'last_date', 'last_size']
        kline_fields = ['meta_id', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo']
        weekly_fields = ['meta_id', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo']
        monthly_fields = ['meta_id', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo']
        quarterly_fields = ['meta_id', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo']
        yearly_fields = ['meta_id', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo']
        if self.is_demo:
            file_list = ["c:\\Users\\sunck\\home\\export\\data\\SH#999999.txt"]
        else:
            file_list = sort_like_windows(os.listdir(self.base_path))
        total_files = len(file_list)
        processed = 0

        print(f"\n -> 开始导入数据（日线 + 周线 + 月线 + 季线 + 年线同步生成），共 {total_files} 个文件...")
        with TDXDatabase(self.db) as db:
            exist_meta = db.query("SELECT id, file, code, name, first_date, last_size, type FROM meta ORDER BY id;")
            exist_periods = {}
            for period, tbl in [('weekly', 'weekly'), ('monthly', 'monthly'), ('quarterly', 'quarterly'), ('yearly', 'yearly')]:
                exist_periods[period] = db.query(
                    f"SELECT meta_id, date, open, high, low, close, vol, amo, MAX(date) AS last_date FROM {tbl} GROUP BY meta_id;"
                )

            exist_meta = {item['file']: item for item in exist_meta}
            for period in exist_periods:
                exist_periods[period] = {item['meta_id']: item for item in exist_periods[period]}
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
                        file, meta_id, exist_meta, exist_periods, exist_file
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
                            'quarterly': [quarterly_fields, result['quarterly_rows']],
                            'yearly': [yearly_fields, result['yearly_rows']],
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
    tdx = TDXDataGenerator(param)
    #tdx = TDXDataGenerator(param, is_demo=True)
    time1 = time.time()
    print(f"结束时间: {time.strftime('%Y.%m.%d   %H:%M:%S')}")

    _ = round((time1 - time0), 4)
    if int(_ // 60):
        print(f'run time:{int(_ // 60)}分{int(_ % 60)}秒')
    else:
        print(f'run time:{int(_ % 60)}秒')
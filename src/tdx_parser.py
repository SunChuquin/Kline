# 脚本名称: tdx_parser.py

import sqlite3, os, re, sys, time
from datetime import datetime, date, timedelta
from typing import List, Dict, Any, Optional, Tuple

class TDXDatabase:
    """
    通达信数据库操作封装类
    用于访问和操作 tdx.db 中的 daily, weekly, meta, concept, index 表
    """

    # 定义允许操作的表名和对应的字段，防止 SQL 注入和非法操作
    TABLE_SCHEMA = {
        'daily': ['file', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo'],
        'weekly': ['file', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo'],
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
            self.cursor.execute("PRAGMA foreign_keys = ON;")
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
    def __init__(self, is_del: bool = False):
        self.db = './tdx.db'
        self.base_path = '../../tdx_data/'
        self.skipped_files = {'无变更': [], '条件过滤': [], '编码错误': [], '未知异常': []}  # ✅ 新增：记录被跳过的文件
        self.date_cache = {}

        # 1.删除旧数据库
        print(f"{'全量更新' if is_del else '增量更新'}")
        if os.path.exists(self.db):
            if is_del:
                os.remove(self.db)
                print(f"\n已删除旧数据库: {self.db}")
        else:
            is_del = True

        # 2.连接数据库（文件不存在时会自动创建）
        self.conn = sqlite3.connect(self.db)
        self.cursor = self.conn.cursor()
        if is_del:
            self.create_empty_db()

        # 4.解析并导入所有表数据
        self.create_db_data()
        self.show()

        # 5.提交事务并关闭连接
        self.conn.commit()
        self.conn.close()

    def create_empty_db(self):
        """
        创建一个空的数据库。
        如果文件已存在，会先删除再重建。
        """

        # ----- 开启外键约束（为了数据完整性）-----
        self.cursor.execute("PRAGMA foreign_keys = ON;")

        # ----- 1. 创建 meta 表（股票/指数/概念的身份信息）-----
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

        # ----- 2. 创建 daily 表（日线数据）-----
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

        # ----- 3. 创建 weekly 表（周线数据）-----
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

        print(f"✅ 空数据库创建成功: {self.db}")
        print("   包含表: daily, weekly, meta")

    def precompute_monday_cache_by_range(self):
        """
        直接按日期范围预计算所有可能的交易日
        """
        start_date = datetime(1990, 1, 1)
        end_date = datetime.now()
        current = start_date

        while current <= end_date:
            date_int = int(current.strftime('%Y%m%d'))
            # 跳过非交易日（周末）
            if current.weekday() < 7:  # 0=周一, 4=周五
                monday = current - timedelta(days=current.weekday())
                self.date_cache[date_int] = int(monday.strftime('%Y%m%d'))
            current += timedelta(days=1)

        print(f"✅ 日期映射表预计算完成，共 {len(self.date_cache)} 个交易日。")

    def handle_data(self, meta_id: int, content: List[str], last_monday: int, weekly_groups: Dict) -> List:
        # 记录上一根K线的日期和周一
        daily_rows = []

        for line in content:
            # 日表处理
            parts = line.strip().split(';')
            row = [
                meta_id,
                int(parts[0]),  # date
                float(parts[1]),  # open
                float(parts[2]),  # high
                float(parts[3]),  # low
                float(parts[4]),  # close
                float(parts[5]) if parts[5] else None,  # vol
                float(parts[6]) if parts[6] else None  # amo
            ]
            daily_rows.append(row)

            # 周表处理
            date_int = row[1]
            if last_monday is None:
                last_monday = self.date_cache[date_int]
                weekly_groups[last_monday] = row.copy()
                continue

            current_monday = self.date_cache[date_int]
            if current_monday == last_monday:
                # 同一周，直接更新
                cur = weekly_groups[current_monday]
                # cur[1] = row[1]  # 开启则表示周线使用最后一天的日期，否则为周一
                cur[3] = max(cur[3], row[3])
                cur[4] = min(cur[4], row[4])
                cur[5] = row[5]
                cur[6] += row[6]
                cur[7] += row[7]
                continue

            # 跨周了（当前K线属于新的一周）
            weekly_groups[current_monday] = row.copy()
            last_monday = current_monday
        return [daily_rows, list(weekly_groups.values())]

    def create_db_data(self):
        """
        解析 data 目录下的所有 TXT 文件，导入 daily 和 meta 表，并同时生成周线数据
        """
        self.precompute_monday_cache_by_range()

        meta_fields = ['file', 'code', 'name', 'type', 'first_date', 'last_date', 'last_size']
        kline_fields = ['meta_id', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo']
        weekly_fields = ['meta_id', 'date', 'open', 'high', 'low', 'close', 'vol', 'amo']
        file_list = sort_like_windows(os.listdir(self.base_path))
        total_files = len(file_list)
        processed = 0

        print(f"\n📁 开始导入数据（日线 + 周线同步生成），共 {total_files} 个文件...")
        with TDXDatabase(self.db) as db:
            exist_meta = db.query("SELECT id, file, code, name, first_date, last_date, last_size, type FROM meta ORDER BY id;")
            exist_weekly = db.query("SELECT meta_id, date, open, high, low, close, vol, amo, MAX(date) AS last_date FROM weekly GROUP BY meta_id;")

            exist_meta = {item['file']: item for item in exist_meta}
            exist_weekly = {item['meta_id']: item for item in exist_weekly}
            exist_file = exist_meta.keys()
            next_id = len(exist_meta) + 1
            for file in file_list:
                try:
                    # if file != 'SZ#002613.txt':
                    #     continue

                    file_name = file[:-4]

                    # 减去18，是为了过滤掉末尾的 "#数据来源:通达信"
                    last_size = exist_meta[file_name]['last_size'] if file_name in exist_file else 0
                    if last_size > 0:
                        if os.path.getsize(self.base_path + file) == last_size:
                            self.skipped_files['无变更'].append(file)
                            processed += 1
                            continue
                        last_size -= 18

                    with open(self.base_path + file, 'r', encoding='gbk') as fp:
                        fp.seek(last_size)
                        content = fp.readlines()

                        if last_size == 0:
                            info_parts = re.split(r'\s+', content.pop(0).strip())
                            code = info_parts[0]
                            name = info_parts[1]
                            if '债' in name:
                                self.skipped_files['条件过滤'].append(file)
                                processed += 1
                                continue
                            content.pop(0)
                        content.pop(-1)

                        # 条件过滤：“空行”、“指定文件”
                        if not len(content) or file.split('#')[0] in ['42', '46', '12'] or file_name in ['62#H11014', '62#931265']:
                            self.skipped_files['条件过滤'].append(file)
                            processed += 1
                            continue

                        # 构建数据
                        if file_name in exist_file:
                            meta_id = exist_meta[file_name]['id']
                            first_date = exist_meta[file_name]['first_date']
                            last_date = exist_meta[file_name]['last_date']
                            last_monday = self.date_cache[exist_weekly[meta_id]['last_date']]
                            weekly_groups = exist_weekly[meta_id]
                            weekly_groups.pop('last_date')
                            weekly_groups = {last_monday: [weekly_groups[item] for item in weekly_fields]}
                            meta_value = [file_name, code, name, file_type, first_date, last_date, fp.tell()]
                        else:
                            file_type = '扩展行情指数'
                            if file_name.split('#')[0] in ['SH', 'SZ']:
                                file_type = '沪深京指数' if file_name[:6] in ['SZ#399', 'SH#000', 'SH#999'] else '沪深主板'
                            first_date = content[0][:8]
                            last_date = content[-1][:8]
                            meta_value = [file_name, code, name, file_type, first_date, last_date, fp.tell()]
                            meta_id = next_id
                            next_id += 1
                            last_monday = None
                            weekly_groups = {}
                        daily_rows, weekly_rows = self.handle_data(meta_id, content, last_monday, weekly_groups)

                        # 写入数据
                        db.insert_tables({
                            'meta': [meta_fields, [meta_value]],
                            'daily': [kline_fields, daily_rows],
                            'weekly': [weekly_fields, weekly_rows],
                        })
                except UnicodeDecodeError as e:
                    self.skipped_files['编码错误'].append([file, f'{str(e)[:30]}'])
                except Exception as e:
                    self.skipped_files['未知异常'].append([file, f'{str(e)[:50]}'])

                # 更新进度条
                bar_length = 30
                processed += 1
                progress = (processed / total_files) * 100 if total_files > 0 else 0
                filled = int(bar_length * processed // total_files) if total_files > 0 else 0
                bar = '█' * filled + '░' * (bar_length - filled)
                sys.stdout.write(f'\r  进度: [{bar}] {progress:.1f}% ({processed}/{total_files}) 当前文件: {file[:20]}')
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
    """
    通达信高级导出：
    1.沪深主板
    2.ETF跟踪指数
    """

    ##########################
    param = input('是否默认使用增量更新？如果是，请直接回车, 否则请输入任意字符再回车, 进行全量更新 > ')
    param = False if param == '' else True
    ##########################

    print(f"\n开始时间: {time.strftime('%Y.%m.%d   %H:%M:%S')}")
    time0 = time.time()
    tdx = TDXDataGenerator(param)
    time1 = time.time()
    print(f"结束时间: {time.strftime('%Y.%m.%d   %H:%M:%S')}")

    _ = round((time1 - time0), 4)
    if int(_//60):
        print(f'run time:{int(_//60)}分{int(_%60)}秒')
    else:
        print(f'run time:{int(_%60)}秒')

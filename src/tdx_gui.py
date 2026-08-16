# tdx_gui.py
import sys
import sqlite3

from PySide2.QtSql import QSqlDatabase
from PySide2.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QTableView, QPushButton, QLineEdit, QLabel, QSplitter,
    QHeaderView, QMessageBox, QStatusBar, QFrame, QComboBox,
    QAbstractItemView, QMenu, QShortcut
)
from PySide2.QtCore import Qt, QSortFilterProxyModel, QAbstractTableModel, QTimer, QItemSelectionModel, QModelIndex
from PySide2.QtGui import QKeySequence


# ============ 自定义 Meta 模型：直接用 sqlite3 加载全部数据 ============
class MetaTableModel(QAbstractTableModel):
    """一次性加载所有 meta 数据到内存，不使用 QSqlQueryModel"""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._data = []
        self._headers = ["id", "文件", "code", "名称", "类型", "首日", "末日", "文件大小"]
        self.load_all_data()

    def load_all_data(self):
        """一次性从数据库加载所有数据"""
        try:
            conn = sqlite3.connect('./tdx.db')
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute("SELECT id, file, code, name, type, first_date, last_date, last_size FROM meta ORDER BY id")
            self._data = cursor.fetchall()
            conn.close()
        except Exception as e:
            print(f"加载 meta 数据失败: {e}")
            self._data = []

    def rowCount(self, parent):
        return len(self._data)

    def columnCount(self, parent):
        return len(self._headers)

    def data(self, index, role=Qt.DisplayRole):
        if role == Qt.DisplayRole:
            val = self._data[index.row()][index.column()]
            if val is None:
                return ""
            if isinstance(val, float):
                return f"{val:.2f}"
            return str(val)
        if role == Qt.TextAlignmentRole:
            return Qt.AlignCenter
        return None

    def headerData(self, section, orientation, role):
        if orientation == Qt.Horizontal and role == Qt.DisplayRole:
            return self._headers[section]
        return None


class MetaSortFilterProxyModel(QSortFilterProxyModel):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setDynamicSortFilter(True)
        self._filter_conditions = []
        self._global_text = ""
        self._col_map = None  # 动态列映射

    def setColumnMap(self, col_map):
        """设置动态列映射（用于查询结果）"""
        self._col_map = col_map

    def setFilterText(self, text):
        """解析搜索文本，支持多条件组合"""
        text = text.strip()
        if not text:
            self._filter_conditions = []
            self._global_text = ""
            self.invalidateFilter()
            return

        import re

        conditions = []
        global_parts = []

        parts = text.split()

        for part in parts:
            match = re.match(r'^(\w+):(.+)$', part)
            if match:
                col_name = match.group(1).lower()
                col_value = match.group(2).strip()
                # 检查列是否有效
                if self._col_map is not None:
                    # 查询结果模式：检查列名是否在 headers 中
                    if col_name not in self._col_map:
                        # 如果不是有效列，当作全局搜索
                        global_parts.append(part.lower())
                        continue
                else:
                    # 原始 meta 模式
                    valid_cols = ['file', 'code', 'name', 'type', 'first_date', 'last_date']
                    if col_name not in valid_cols:
                        global_parts.append(part.lower())
                        continue

                if col_value.startswith('!'):
                    conditions.append({
                        'col': col_name,
                        'value': col_value[1:].lower(),
                        'negate': True,
                        'multi': False
                    })
                elif '|' in col_value:
                    values = [v.strip().lower() for v in col_value.split('|') if v.strip()]
                    conditions.append({
                        'col': col_name,
                        'value': values,
                        'negate': False,
                        'multi': True
                    })
                else:
                    conditions.append({
                        'col': col_name,
                        'value': col_value.lower(),
                        'negate': False,
                        'multi': False
                    })
                continue

            if part.strip():
                global_parts.append(part.lower())

        self._filter_conditions = conditions
        self._global_text = ' '.join(global_parts) if global_parts else ""
        self.invalidateFilter()

    def get_col_index(self, col_name):
        """获取列索引"""
        if self._col_map is not None:
            # 查询结果模式
            return self._col_map.get(col_name)
        else:
            # 原始 meta 模式
            col_map = {
                'file': 1,
                'code': 2,
                'name': 3,
                'type': 4,
                'first_date': 5,
                'last_date': 6
            }
            return col_map.get(col_name)

    def filterAcceptsRow(self, source_row, source_parent):
        if not self._filter_conditions and not self._global_text:
            return True

        source_model = self.sourceModel()
        if not source_model:
            return True

        try:
            col_count = source_model.columnCount(QModelIndex())
        except Exception:
            try:
                col_count = source_model.columnCount()
            except Exception:
                col_count = 10

        # 1. 检查全局搜索文本（在 file, name, type 列中搜索）
        if self._global_text:
            for col in [1, 3, 4]:
                if col >= col_count:
                    continue
                index = source_model.index(source_row, col)
                value = source_model.data(index, Qt.DisplayRole)
                if value is None:
                    continue
                if self._global_text in str(value).lower():
                    if not self._filter_conditions:
                        return True
                    break
            else:
                return False

        # 2. 检查列条件
        if self._filter_conditions:
            for cond in self._filter_conditions:
                col_name = cond['col']
                value = cond['value']
                negate = cond.get('negate', False)
                multi = cond.get('multi', False)

                col_index = self.get_col_index(col_name)
                if col_index is None or col_index >= col_count:
                    continue

                index = source_model.index(source_row, col_index)
                cell_value = source_model.data(index, Qt.DisplayRole)
                if cell_value is None:
                    cell_value = ""

                cell_str = str(cell_value).lower()

                if multi:
                    matched = any(v in cell_str for v in value)
                else:
                    matched = value in cell_str

                if negate:
                    matched = not matched

                if not matched:
                    return False

        return True

    def lessThan(self, left, right):
        left_val = left.data(Qt.DisplayRole)
        right_val = right.data(Qt.DisplayRole)

        if left_val is None:
            return True
        if right_val is None:
            return False

        try:
            if isinstance(left_val, (int, float)) or isinstance(right_val, (int, float)):
                return float(left_val) < float(right_val)
        except:
            pass

        return str(left_val).lower() < str(right_val).lower()


class SortableTableModel(QSortFilterProxyModel):
    def __init__(self, source_model, parent=None):
        super().__init__(parent)
        self.setSourceModel(source_model)
        self.setDynamicSortFilter(True)

    def lessThan(self, left, right):
        left_val = left.data(Qt.DisplayRole)
        right_val = right.data(Qt.DisplayRole)

        if left_val is None:
            return True
        if right_val is None:
            return False

        try:
            if isinstance(left_val, (int, float)) or isinstance(right_val, (int, float)):
                return float(left_val) < float(right_val)
        except:
            pass

        return str(left_val).lower() < str(right_val).lower()


class DailyTableModel(QAbstractTableModel):
    def __init__(self, data, headers, parent=None):
        super().__init__(parent)
        self._data = data
        self._headers = headers

    def rowCount(self, parent):
        return len(self._data)

    def columnCount(self, parent):
        return len(self._headers)

    def data(self, index, role=Qt.DisplayRole):
        if role == Qt.DisplayRole:
            val = self._data[index.row()][index.column()]
            if isinstance(val, float):
                return f"{val:.2f}"
            if val is None:
                return ""
            return str(val)
        if role == Qt.TextAlignmentRole:
            return Qt.AlignCenter
        return None

    def headerData(self, section, orientation, role):
        if orientation == Qt.Horizontal and role == Qt.DisplayRole:
            return self._headers[section]
        return None


class WeeklyTableModel(QAbstractTableModel):
    def __init__(self, data, headers, parent=None):
        super().__init__(parent)
        self._data = data
        self._headers = headers

    def rowCount(self, parent):
        return len(self._data)

    def columnCount(self, parent):
        return len(self._headers)

    def data(self, index, role=Qt.DisplayRole):
        if role == Qt.DisplayRole:
            val = self._data[index.row()][index.column()]
            if isinstance(val, float):
                return f"{val:.2f}"
            if val is None:
                return ""
            return str(val)
        if role == Qt.TextAlignmentRole:
            return Qt.AlignCenter
        return None

    def headerData(self, section, orientation, role):
        if orientation == Qt.Horizontal and role == Qt.DisplayRole:
            return self._headers[section]
        return None


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("📊 时光实验室 - 数据库工具")
        self.setGeometry(100, 100, 1600, 900)

        self.init_db()
        self.current_meta_id = None
        self.current_sort_column = -1
        self.current_sort_order = Qt.AscendingOrder

        # 保存原始 meta 模型和代理，用于刷新恢复
        self.original_source_model = None
        self.original_proxy_model = None

        self.setup_ui()
        self.load_meta_table()
        self.status_bar.showMessage("就绪")

        # 设置键盘快捷键
        self.setup_shortcuts()

        # 启动后光标聚焦到搜索栏
        self.search_input.setFocus()

    def init_db(self):
        self.db = QSqlDatabase.addDatabase("QSQLITE")
        self.db.setDatabaseName("./tdx.db")
        if not self.db.open():
            QMessageBox.critical(self, "错误", f"无法打开数据库: {self.db.lastError().text()}")
            sys.exit(1)

    def setup_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        main_layout = QVBoxLayout(central)
        main_layout.setContentsMargins(5, 5, 5, 5)
        main_layout.setSpacing(3)

        toolbar = QHBoxLayout()
        toolbar.setSpacing(10)
        self.stats_label = QLabel("📈 加载中...")
        self.stats_label.setStyleSheet("font-size: 13px; font-weight: bold;")
        toolbar.addWidget(self.stats_label)
        toolbar.addStretch()

        toolbar.addWidget(QLabel("快捷查询:"))
        self.quick_query_combo = QComboBox()
        self.quick_query_combo.addItem("-- 选择查询 --")
        self.quick_query_combo.addItem("📊 日线数据不是最新的")
        self.quick_query_combo.addItem("📊 日线数据是最新的")
        self.quick_query_combo.currentIndexChanged.connect(self.on_quick_query)
        toolbar.addWidget(self.quick_query_combo)

        self.query_btn = QPushButton("▶ 执行")
        self.query_btn.setFixedWidth(60)
        self.query_btn.clicked.connect(self.execute_quick_query)
        toolbar.addWidget(self.query_btn)

        refresh_btn = QPushButton("🔄 刷新")
        refresh_btn.setFixedWidth(60)
        refresh_btn.clicked.connect(self.refresh_all)
        toolbar.addWidget(refresh_btn)

        main_layout.addLayout(toolbar)

        line = QFrame()
        line.setFrameShape(QFrame.HLine)
        line.setFrameShadow(QFrame.Sunken)
        main_layout.addWidget(line)

        splitter = QSplitter(Qt.Horizontal)
        splitter.setHandleWidth(5)

        left_widget = self.create_meta_panel()
        splitter.addWidget(left_widget)

        middle_widget = self.create_daily_panel()
        splitter.addWidget(middle_widget)

        right_widget = self.create_weekly_panel()
        splitter.addWidget(right_widget)

        splitter.setSizes([350, 350, 350])
        main_layout.addWidget(splitter)

        self.status_bar = QStatusBar()
        self.setStatusBar(self.status_bar)
        self.status_bar.showMessage("就绪 | 点击左侧标的查看详情")

    def select_first_row(self):
        """默认选中 meta 表第一行，加载对应的日线和周线数据"""
        proxy = self.meta_view.model()
        if not proxy:
            return

        row_count = proxy.rowCount()
        if row_count <= 0:
            self.clear_data_display()
            return

        # 获取第一行的索引
        first_index = proxy.index(0, 1)
        if not first_index.isValid():
            return

        # 模拟点击：选中行并触发点击事件
        self.meta_view.setCurrentIndex(first_index)
        self.meta_view.selectionModel().clear()
        self.meta_view.selectionModel().select(first_index, QItemSelectionModel.Select | QItemSelectionModel.Rows)
        self.meta_view.scrollTo(first_index, QAbstractItemView.EnsureVisible)

        # 调用点击事件，加载日线和周线数据
        self.on_meta_row_clicked(first_index)

    def resize_columns_to_fit(self, view):
        """直接计算列宽，比 ResizeToContents 快得多"""
        header = view.horizontalHeader()
        model = view.model()
        if not model:
            return

        # 获取可见列
        visible_columns = []
        for i in range(header.count()):
            if not view.isColumnHidden(i):
                visible_columns.append(i)

        if not visible_columns:
            return

        # 获取视图宽度
        view_width = view.viewport().width()
        if view_width <= 0:
            return

        # 计算每列的最大宽度
        col_widths = {}
        font_metrics = view.fontMetrics()

        # 1. 表头宽度
        for col in visible_columns:
            header_text = model.headerData(col, Qt.Horizontal, Qt.DisplayRole)
            if header_text:
                width = font_metrics.horizontalAdvance(str(header_text)) + 25
            else:
                width = 60
            col_widths[col] = width

        # 2. 数据行宽度（只取前 500 行）
        row_count = min(model.rowCount(QModelIndex()), 500)
        for row in range(row_count):
            for col in visible_columns:
                index = model.index(row, col)
                if not index.isValid():
                    continue
                val = model.data(index, Qt.DisplayRole)
                if val is None:
                    continue
                width = font_metrics.horizontalAdvance(str(val)) + 20
                if width > col_widths.get(col, 0):
                    col_widths[col] = width

        # 3. 限制列宽范围
        for col in visible_columns:
            col_widths[col] = max(col_widths[col], 50)
            col_widths[col] = min(col_widths[col], 450)

        # 4. 计算总宽度，如果小于视图宽度则平均分配
        total_content_width = sum(col_widths[col] for col in visible_columns)
        if total_content_width < view_width:
            extra = view_width - total_content_width
            extra_per_col = extra // len(visible_columns)
            remainder = extra % len(visible_columns)
            for i, col in enumerate(visible_columns):
                col_widths[col] += extra_per_col
                if i < remainder:
                    col_widths[col] += 1

        # 5. 一次性设置所有列宽
        for col, width in col_widths.items():
            header.setSectionResizeMode(col, QHeaderView.Interactive)
            header.resizeSection(col, int(width))

    def resizeEvent(self, event):
        super().resizeEvent(event)
        QTimer.singleShot(10, lambda: self.resize_columns_to_fit(self.meta_view))
        QTimer.singleShot(10, lambda: self.resize_columns_to_fit(self.daily_view))
        QTimer.singleShot(10, lambda: self.resize_columns_to_fit(self.weekly_view))

    def show_header_context_menu(self, pos):
        """显示表头右键菜单"""
        header = self.meta_view.horizontalHeader()
        logical_index = header.logicalIndexAt(pos)
        if logical_index < 0:
            return

        # ✅ 列名映射（只包含可见列）
        col_names = {
            1: 'file',
            3: 'name',
            4: 'type',
        }

        col_name = col_names.get(logical_index)
        if not col_name:
            return

        # 获取当前列的选中值（如果有选中行）
        current_value = ""
        proxy = self.meta_view.model()
        if proxy and proxy.rowCount() > 0:
            current_index = self.meta_view.currentIndex()
            if current_index.isValid():
                source_index = proxy.mapToSource(current_index) if hasattr(proxy, 'mapToSource') else current_index
                source_model = proxy.sourceModel() if hasattr(proxy, 'sourceModel') else proxy
                if source_model:
                    val = source_model.data(source_model.index(source_index.row(), logical_index), Qt.DisplayRole)
                    if val:
                        current_value = str(val)

        # 创建菜单
        menu = QMenu(self)

        # 筛选动作
        if current_value:
            filter_action = menu.addAction(f"筛选: {col_name} = '{current_value}'")
            filter_action.triggered.connect(lambda: self.apply_column_filter(col_name, current_value))

        # 筛选（包含输入值）
        menu.addAction("筛选（输入值）...").triggered.connect(lambda: self.show_filter_dialog(col_name))

        menu.addSeparator()

        # 取消筛选
        clear_action = menu.addAction(f"清除 {col_name} 筛选")
        clear_action.triggered.connect(lambda: self.clear_column_filter(col_name))

        menu.addSeparator()

        # 复制列名到搜索框
        copy_action = menu.addAction(f"输入 '{col_name}:' 到搜索框")
        copy_action.triggered.connect(lambda: self.insert_column_prefix(col_name))

        menu.exec_(header.mapToGlobal(pos))

    def apply_column_filter(self, col_name, value):
        """应用列筛选"""
        self.search_input.setText(f"{col_name}:{value}")
        self.filter_meta_table()

    def show_filter_dialog(self, col_name):
        """显示筛选输入对话框"""
        from PySide2.QtWidgets import QInputDialog
        value, ok = QInputDialog.getText(self, f"筛选 {col_name}", f"输入 {col_name} 包含的内容:")
        if ok and value:
            self.search_input.setText(f"{col_name}:{value}")
            self.filter_meta_table()

    def clear_column_filter(self, col_name):
        """清除指定列的筛选"""
        # 保留其他条件，移除该列的条件
        current_text = self.search_input.text()
        # 移除 col_name:xxx 部分
        import re
        new_text = re.sub(rf'{col_name}:[^\s]+', '', current_text).strip()
        self.search_input.setText(new_text)
        self.filter_meta_table()

    def insert_column_prefix(self, col_name):
        """在搜索框插入列名前缀"""
        current_text = self.search_input.text()
        # 如果已有内容，在后面加空格
        if current_text and not current_text.endswith(' '):
            self.search_input.setText(f"{current_text} {col_name}:")
        else:
            self.search_input.setText(f"{current_text}{col_name}:")
        self.search_input.setFocus()
        # 将光标移到冒号后面
        cursor = self.search_input.cursorPosition()
        self.search_input.setCursorPosition(cursor + 1)

    def create_meta_panel(self):
        widget = QWidget()
        layout = QVBoxLayout(widget)
        layout.setContentsMargins(0, 0, 5, 0)
        layout.setSpacing(5)

        title = QLabel("📋 标的列表")
        title.setStyleSheet("font-weight: bold; font-size: 13px;")
        layout.addWidget(title)

        search_layout = QHBoxLayout()
        search_layout.setSpacing(5)
        search_label = QLabel("搜索:")
        search_label.setFixedWidth(35)
        search_layout.addWidget(search_label)
        self.search_input = QLineEdit()
        self.search_input.setPlaceholderText("搜索 或 列名:值 (如 type:沪深主板)")
        self.search_input.textChanged.connect(self.filter_meta_table)
        search_layout.addWidget(self.search_input)
        layout.addLayout(search_layout)

        self.meta_view = QTableView()
        self.meta_view.setAlternatingRowColors(True)
        self.meta_view.setSelectionBehavior(QTableView.SelectRows)
        self.meta_view.setSelectionMode(QTableView.SingleSelection)
        self.meta_view.verticalHeader().setVisible(False)
        self.meta_view.setSortingEnabled(True)
        self.meta_view.horizontalHeader().setSortIndicatorShown(True)
        self.meta_view.horizontalHeader().sectionClicked.connect(self.on_header_clicked)
        self.meta_view.clicked.connect(self.on_meta_row_clicked)

        # 启用表头右键菜单
        self.meta_view.horizontalHeader().setContextMenuPolicy(Qt.CustomContextMenu)
        self.meta_view.horizontalHeader().customContextMenuRequested.connect(self.show_header_context_menu)

        # 选中行高亮样式
        self.meta_view.setStyleSheet("""
            QTableView::item:selected {
                background-color: #2a82da;
                color: white;
            }
            QTableView::item:selected:!active {
                background-color: #2a82da;
                color: white;
            }
        """)

        layout.addWidget(self.meta_view)

        return widget

    def create_daily_panel(self):
        widget = QWidget()
        layout = QVBoxLayout(widget)
        layout.setContentsMargins(5, 0, 5, 0)
        layout.setSpacing(5)

        header_layout = QHBoxLayout()
        header_layout.setSpacing(10)
        title = QLabel("📊 日线数据")
        title.setStyleSheet("font-weight: bold; font-size: 13px;")
        header_layout.addWidget(title)
        self.daily_info_label = QLabel("请选择标的")
        self.daily_info_label.setStyleSheet("color: #666; font-size: 12px;")
        header_layout.addWidget(self.daily_info_label)
        header_layout.addStretch()
        layout.addLayout(header_layout)

        self.daily_view = QTableView()
        self.daily_view.setAlternatingRowColors(True)
        self.daily_view.setSortingEnabled(True)
        self.daily_view.verticalHeader().setVisible(False)
        self.daily_view.horizontalHeader().setSortIndicatorShown(True)
        layout.addWidget(self.daily_view)

        return widget

    def create_weekly_panel(self):
        widget = QWidget()
        layout = QVBoxLayout(widget)
        layout.setContentsMargins(5, 0, 0, 0)
        layout.setSpacing(5)

        header_layout = QHBoxLayout()
        header_layout.setSpacing(10)
        title = QLabel("📈 周线数据")
        title.setStyleSheet("font-weight: bold; font-size: 13px;")
        header_layout.addWidget(title)
        self.weekly_info_label = QLabel("请选择标的")
        self.weekly_info_label.setStyleSheet("color: #666; font-size: 12px;")
        header_layout.addWidget(self.weekly_info_label)
        header_layout.addStretch()
        layout.addLayout(header_layout)

        self.weekly_view = QTableView()
        self.weekly_view.setAlternatingRowColors(True)
        self.weekly_view.setSortingEnabled(True)
        self.weekly_view.verticalHeader().setVisible(False)
        self.weekly_view.horizontalHeader().setSortIndicatorShown(True)
        layout.addWidget(self.weekly_view)

        return widget

    def on_header_clicked(self, logical_index):
        proxy = self.meta_view.model()
        if not proxy:
            return

        if self.current_sort_column == logical_index:
            self.current_sort_order = Qt.DescendingOrder if self.current_sort_order == Qt.AscendingOrder else Qt.AscendingOrder
        else:
            self.current_sort_column = logical_index
            self.current_sort_order = Qt.AscendingOrder

        self.meta_view.horizontalHeader().setSortIndicator(logical_index, self.current_sort_order)
        proxy.sort(logical_index, self.current_sort_order)

    def load_meta_table(self):
        """加载 meta 表（原始数据）"""
        source_model = MetaTableModel(self)

        proxy_model = MetaSortFilterProxyModel(self)
        proxy_model.setSourceModel(source_model)

        # 保存原始模型
        self.original_source_model = source_model
        self.original_proxy_model = proxy_model

        self.meta_view.setModel(proxy_model)

        # ✅ 隐藏不需要显示的列: id, code, first_date, last_date, last_size
        self.meta_view.hideColumn(0)  # id
        self.meta_view.hideColumn(2)  # code
        self.meta_view.hideColumn(5)  # first_date
        self.meta_view.hideColumn(6)  # last_date
        self.meta_view.hideColumn(7)  # last_size

        self.meta_view.horizontalHeader().setSortIndicator(1, Qt.AscendingOrder)
        proxy_model.sort(1, Qt.AscendingOrder)

        # 使用统一的重新连接方法
        self._reconnect_click_event()

        self.update_stats()
        self.status_bar.showMessage("加载完成")

        QTimer.singleShot(100, lambda: self.resize_columns_to_fit(self.meta_view))
        QTimer.singleShot(200, self.select_first_row)

    def update_stats(self):
        try:
            conn = sqlite3.connect('./tdx.db')
            cursor = conn.cursor()
            cursor.execute("SELECT COUNT(*) FROM meta")
            meta_count = cursor.fetchone()[0]
            cursor.execute("SELECT COUNT(*) FROM daily")
            daily_count = cursor.fetchone()[0]
            cursor.execute("SELECT COUNT(*) FROM weekly")
            weekly_count = cursor.fetchone()[0]
            conn.close()
            self.stats_label.setText(
                f"📁 标的: {meta_count}  |  📊 日线: {daily_count:,}  |  📈 周线: {weekly_count:,}"
            )
        except Exception as e:
            self.stats_label.setText(f"统计加载失败: {e}")

    def filter_meta_table(self):
        """根据搜索框内容过滤 meta 视图（支持原始 meta 和查询结果）"""
        search_text = self.search_input.text().strip()
        proxy = self.meta_view.model()
        if not proxy:
            return

        # 检查是否是查询结果模型（有 setFilterText 方法）
        if hasattr(proxy, 'setFilterText'):
            # 先断开点击事件，避免在过滤过程中触发
            try:
                self.meta_view.clicked.disconnect()
            except:
                pass

            proxy.setFilterText(search_text)

            # 重新连接点击事件
            self._reconnect_click_event()

            # 获取过滤后的行数
            row_count = proxy.rowCount()

            if row_count > 0:
                # 有搜索结果，选中第一行并加载数据
                QTimer.singleShot(50, lambda: self.select_filtered_first_row())
                self.status_bar.showMessage(f"搜索完成，找到 {row_count} 条结果")
            else:
                # 搜索结果为空，清空日线和周线
                self.clear_data_display()
                self.status_bar.showMessage("搜索无结果")

            QTimer.singleShot(50, lambda: self.resize_columns_to_fit(self.meta_view))
            return

        # 如果是 SortableTableModel 包装的查询结果，需要获取其源模型
        if hasattr(proxy, 'sourceModel'):
            source = proxy.sourceModel()
            if hasattr(source, 'setFilterText'):
                # 断开点击事件
                try:
                    self.meta_view.clicked.disconnect()
                except:
                    pass

                source.setFilterText(search_text)

                # 重新连接点击事件
                self._reconnect_click_event()

                # 获取过滤后的行数
                row_count = proxy.rowCount()

                if row_count > 0:
                    QTimer.singleShot(50, lambda: self.select_filtered_first_row())
                    self.status_bar.showMessage(f"搜索完成，找到 {row_count} 条结果")
                else:
                    self.clear_data_display()
                    self.status_bar.showMessage("搜索无结果")

                QTimer.singleShot(50, lambda: self.resize_columns_to_fit(self.meta_view))
                return

        self.status_bar.showMessage("当前视图不支持搜索")

    def select_filtered_first_row(self):
        """选中过滤/搜索后的第一行，并加载对应的日线和周线数据"""
        proxy = self.meta_view.model()
        if not proxy:
            return

        row_count = proxy.rowCount()
        if row_count <= 0:
            self.clear_data_display()
            return

        # 获取第一行的索引（使用第一列）
        first_index = proxy.index(0, 0)
        if not first_index.isValid():
            return

        # 选中第一行
        self.meta_view.clearSelection()
        self.meta_view.setCurrentIndex(first_index)
        self.meta_view.selectRow(0)
        self.meta_view.scrollTo(first_index, QAbstractItemView.EnsureVisible)

        # 根据当前模式调用对应的点击处理方法
        # 检查当前模型是否有 _raw_data 属性（查询结果模型的特征）
        source_model = proxy.sourceModel() if hasattr(proxy, 'sourceModel') else proxy
        is_query_result = hasattr(source_model, '_raw_data')

        # 先确保点击事件已正确连接
        self._reconnect_click_event()

        if is_query_result:
            # 查询结果模式：使用 on_query_row_clicked
            QTimer.singleShot(50, lambda: self.on_query_row_clicked(first_index))
        else:
            # 原始 meta 模式：使用 on_meta_row_clicked
            QTimer.singleShot(50, lambda: self.on_meta_row_clicked(first_index))

    def _reconnect_click_event(self):
        """根据当前模型类型，重新连接点击事件"""
        proxy = self.meta_view.model()
        if not proxy:
            return

        # 检查是否是查询结果模型（有 _raw_data 属性）
        source_model = proxy.sourceModel() if hasattr(proxy, 'sourceModel') else proxy
        is_query_result = hasattr(source_model, '_raw_data')

        # 断开旧连接
        try:
            self.meta_view.clicked.disconnect()
        except:
            pass

        # 根据模式连接对应的事件处理函数
        if is_query_result:
            self.meta_view.clicked.connect(self.on_query_row_clicked)
        else:
            self.meta_view.clicked.connect(self.on_meta_row_clicked)

    def on_meta_row_clicked(self, index):
        proxy = self.meta_view.model()
        if not proxy:
            return

        # 获取源模型的数据
        source_index = proxy.mapToSource(index)
        source_model = proxy.sourceModel()
        if not source_model:
            return

        meta_id = source_model.data(source_model.index(source_index.row(), 0), Qt.DisplayRole)
        file_name = source_model.data(source_model.index(source_index.row(), 1), Qt.DisplayRole)
        code = source_model.data(source_model.index(source_index.row(), 2), Qt.DisplayRole)

        self.current_meta_id = int(meta_id) if meta_id else None
        self.status_bar.showMessage(f"已选择: {file_name} ({code})")

        self.load_daily_data(meta_id, file_name, code)
        self.load_weekly_data(meta_id, file_name, code)

    def load_daily_data(self, meta_id, file_name, code):
        self.daily_info_label.setText(f"{file_name} ({code}) - 全部")

        try:
            conn = sqlite3.connect('./tdx.db')
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute(
                "SELECT date, open, high, low, close, vol, amo FROM daily WHERE meta_id = ? ORDER BY date DESC",
                (meta_id,)
            )
            rows = cursor.fetchall()
            conn.close()
            self.display_daily_data(rows)
        except Exception as e:
            self.daily_info_label.setText(f"❌ {e}")

    def display_daily_data(self, rows):
        if not rows:
            self.daily_info_label.setText("暂无日线数据")
            self.daily_view.setModel(None)
            return

        headers = ["日期", "开盘", "最高", "最低", "收盘", "成交量", "成交额"]
        source_model = DailyTableModel(rows, headers, self)

        proxy_model = SortableTableModel(source_model, self)
        self.daily_view.setModel(proxy_model)

        self.daily_view.horizontalHeader().setSortIndicator(0, Qt.DescendingOrder)
        self.daily_info_label.setText(f"共 {len(rows)} 条")

        QTimer.singleShot(50, lambda: self.resize_columns_to_fit(self.daily_view))

    def display_query_result(self, rows, title):
        """在 meta 视图显示查询结果"""
        # 如果查询结果为空，清空日线和周线显示
        if not rows:
            self.clear_data_display()
            self.status_bar.showMessage(f"查询完成: {title} 返回 0 行")
            self._reconnect_click_event()
            return

        from PySide2.QtCore import QAbstractTableModel

        class QueryResultModel(QAbstractTableModel):
            def __init__(self, data, headers, parent=None):
                super().__init__(parent)
                self._data = data
                self._headers = headers
                self._raw_data = None
                self._meta_id_index = -1

            def rowCount(self, parent):
                return len(self._data)

            def columnCount(self, parent):
                return len(self._headers)

            def data(self, index, role=Qt.DisplayRole):
                if role == Qt.DisplayRole:
                    val = self._data[index.row()][index.column()]
                    if isinstance(val, float):
                        return f"{val:.2f}"
                    if val is None:
                        return ""
                    return str(val)
                if role == Qt.TextAlignmentRole:
                    return Qt.AlignCenter
                return None

            def headerData(self, section, orientation, role):
                if orientation == Qt.Horizontal and role == Qt.DisplayRole:
                    return self._headers[section]
                return None

        if rows:
            if hasattr(rows[0], 'keys'):
                all_headers = list(rows[0].keys())
            else:
                all_headers = [f"列{i}" for i in range(len(rows[0]))]
        else:
            all_headers = []

        # 排除显示列：code, last_date, max_date, meta_id（不显示）
        exclude_columns = ['code', 'last_date', 'max_date', 'meta_id']
        filtered_headers = []
        filtered_indices = []
        meta_id_index = -1

        for i, header in enumerate(all_headers):
            if header.lower() == 'meta_id':
                meta_id_index = i
            if header.lower() not in exclude_columns:
                filtered_headers.append(header)
                filtered_indices.append(i)

        filtered_data = []
        for row in rows:
            if hasattr(row, 'keys'):
                filtered_row = [row[header] for header in filtered_headers]
            else:
                filtered_row = [row[i] for i in filtered_indices]
            filtered_data.append(filtered_row)

        query_model = QueryResultModel(filtered_data, filtered_headers, self)
        query_model._raw_data = rows
        query_model._meta_id_index = meta_id_index

        searchable_proxy = MetaSortFilterProxyModel(self)
        searchable_proxy.setSourceModel(query_model)
        searchable_proxy.setColumnMap({header: i for i, header in enumerate(filtered_headers)})

        self._query_model = query_model
        self._query_proxy = searchable_proxy

        self.meta_view.setModel(searchable_proxy)

        for i in range(len(filtered_headers)):
            self.meta_view.showColumn(i)

        self.meta_view.horizontalHeader().setSortIndicator(0, Qt.AscendingOrder)

        # 使用统一的重新连接方法
        self._reconnect_click_event()

        self.meta_view.setSortingEnabled(True)

        QTimer.singleShot(50, lambda: self.resize_columns_to_fit(self.meta_view))
        self.daily_info_label.setText(f"📊 查询: {title} (共 {len(rows)} 条)")
        self.status_bar.showMessage(f"查询完成: {title} 返回 {len(rows)} 行")

        # 选中第一行并加载数据
        QTimer.singleShot(100, self.select_query_first_row)

    def select_query_first_row(self):
        """选中查询结果的第一行，并加载对应的日线和周线数据"""
        proxy = self.meta_view.model()
        if not proxy:
            return

        row_count = proxy.rowCount()
        if row_count <= 0:
            self.clear_data_display()
            return

        first_index = proxy.index(0, 0)
        if not first_index.isValid():
            return

        # 选中第一行
        self.meta_view.clearSelection()
        self.meta_view.setCurrentIndex(first_index)
        self.meta_view.selectRow(0)
        self.meta_view.scrollTo(first_index, QAbstractItemView.EnsureVisible)

        # 加载第一行的日线和周线数据
        QTimer.singleShot(50, lambda: self.on_query_row_clicked(first_index))

    def on_query_row_clicked(self, index):
        """点击查询结果行时加载日线和周线"""
        proxy = self.meta_view.model()
        if not proxy:
            return

        source_model = proxy.sourceModel() if hasattr(proxy, 'sourceModel') else proxy
        source_index = proxy.mapToSource(index) if hasattr(proxy, 'mapToSource') else index

        row = source_index.row()
        meta_id = None
        file_name = None
        code = None

        # 从原始数据中获取 meta_id
        if hasattr(source_model, '_raw_data') and row < len(source_model._raw_data):
            raw_row = source_model._raw_data[row]
            if hasattr(raw_row, 'keys'):
                for key in raw_row.keys():
                    key_lower = key.lower()
                    if key_lower == 'meta_id':
                        meta_id = int(raw_row[key]) if raw_row[key] else None
                    elif key_lower == 'file':
                        file_name = raw_row[key]
                    elif key_lower == 'code':
                        code = raw_row[key]

        # 如果从原始数据获取失败，尝试从显示数据获取
        if meta_id is None:
            for col in range(source_model.columnCount()):
                header = source_model.headerData(col, Qt.Horizontal, Qt.DisplayRole)
                val = source_model.data(source_model.index(row, col), Qt.DisplayRole)
                if header:
                    header_lower = header.lower()
                    if header_lower in ['meta_id', 'id']:
                        if val and str(val).isdigit():
                            meta_id = int(val)
                    elif header_lower == 'file':
                        file_name = val
                    elif header_lower == 'code':
                        code = val

        if meta_id:
            self.current_meta_id = meta_id
            self.status_bar.showMessage(f"已选择: {file_name or meta_id} ({code or ''})")
            self.load_daily_data(meta_id, file_name or str(meta_id), code or '')
            self.load_weekly_data(meta_id, file_name or str(meta_id), code or '')
        else:
            # 如果无法获取 meta_id，清空日线和周线
            self.status_bar.showMessage("无法获取标的 ID，清空数据显示")
            self.clear_data_display()

    def clear_data_display(self):
        """清空日线和周线显示"""
        self.daily_view.setModel(None)
        self.daily_info_label.setText("无数据")
        self.weekly_view.setModel(None)
        self.weekly_info_label.setText("无数据")
        self.current_meta_id = None

    def on_quick_query(self, index):
        if index > 0:
            self.execute_quick_query()

    def execute_quick_query(self):
        """执行快捷查询，结果显示在左侧 meta 视图"""
        query_name = self.quick_query_combo.currentText()
        if query_name == "-- 选择查询 --":
            return

        self.status_bar.showMessage(f"执行查询: {query_name}")
        sql = self.get_quick_query_sql(query_name)

        if not sql:
            self.status_bar.showMessage("查询未定义")
            return

        try:
            conn = sqlite3.connect('./tdx.db')
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute(sql)
            rows = cursor.fetchall()
            conn.close()
            self.display_query_result(rows, query_name)
        except Exception as e:
            QMessageBox.warning(self, "查询错误", f"执行失败: {e}")
            self.status_bar.showMessage(f"查询失败: {e}")

    def load_weekly_data(self, meta_id, file_name, code):
        self.weekly_info_label.setText(f"{file_name} ({code}) - 全部")

        try:
            conn = sqlite3.connect('./tdx.db')
            conn.row_factory = sqlite3.Row
            cursor = conn.cursor()
            cursor.execute(
                "SELECT date, open, high, low, close, vol, amo FROM weekly WHERE meta_id = ? ORDER BY date DESC",
                (meta_id,)
            )
            rows = cursor.fetchall()
            conn.close()
            self.display_weekly_data(rows)
        except Exception as e:
            self.weekly_info_label.setText(f"❌ {e}")

    def display_weekly_data(self, rows):
        if not rows:
            self.weekly_info_label.setText("暂无周线数据")
            self.weekly_view.setModel(None)
            return

        headers = ["日期", "开盘", "最高", "最低", "收盘", "成交量", "成交额"]
        source_model = WeeklyTableModel(rows, headers, self)

        proxy_model = SortableTableModel(source_model, self)
        self.weekly_view.setModel(proxy_model)

        self.weekly_view.horizontalHeader().setSortIndicator(0, Qt.DescendingOrder)
        self.weekly_info_label.setText(f"共 {len(rows)} 条")

        QTimer.singleShot(50, lambda: self.resize_columns_to_fit(self.weekly_view))

    def get_quick_query_sql(self, query_name):
        """根据查询名称返回对应的 SQL"""
        # 直接使用 meta 表中的 last_date 字段
        queries = {
            "📊 日线数据不是最新的": """
                SELECT
                    m.id AS meta_id,
                    m.file,
                    m.code,
                    m.name,
                    m.type,
                    m.last_date
                FROM meta m
                WHERE m.last_date IS NOT NULL
                ORDER BY m.last_date ASC
                LIMIT 500
            """,
            "📊 日线数据是最新的": """
                SELECT
                    m.id AS meta_id,
                    m.file,
                    m.code,
                    m.name,
                    m.type,
                    m.last_date
                FROM meta m
                WHERE m.last_date IS NOT NULL
                ORDER BY m.last_date DESC
                LIMIT 1000
            """
        }
        return queries.get(query_name, "")

    def refresh_all(self):
        """刷新所有数据，恢复原始 meta 表"""
        if self.original_source_model and self.original_proxy_model:
            self.meta_view.setModel(self.original_proxy_model)

            # ✅ 隐藏不需要显示的列: id, code, first_date, last_date, last_size
            self.meta_view.hideColumn(0)  # id
            self.meta_view.hideColumn(2)  # code
            self.meta_view.hideColumn(5)  # first_date
            self.meta_view.hideColumn(6)  # last_date
            self.meta_view.hideColumn(7)  # last_size

            self.meta_view.horizontalHeader().setSortIndicator(1, Qt.AscendingOrder)
            self.original_proxy_model.sort(1, Qt.AscendingOrder)

            # 断开旧的连接，重新连接
            self._reconnect_click_event()

            QTimer.singleShot(100, lambda: self.resize_columns_to_fit(self.meta_view))
            QTimer.singleShot(200, self.select_first_row)

            self.update_stats()
            self.status_bar.showMessage("已刷新，恢复原始数据")
        else:
            self.load_meta_table()
            self.status_bar.showMessage("已刷新")

    def setup_shortcuts(self):
        """设置键盘快捷键"""
        # Ctrl+F: 聚焦到搜索栏
        ctrl_f_shortcut = QShortcut(QKeySequence("Ctrl+F"), self)
        ctrl_f_shortcut.activated.connect(self.focus_search_input)

        # Ctrl+Shift+F: 聚焦到搜索栏并清空
        ctrl_shift_f_shortcut = QShortcut(QKeySequence("Ctrl+Shift+F"), self)
        ctrl_shift_f_shortcut.activated.connect(self.clear_and_focus_search)

        # Escape: 清空搜索框或回到第一个标的
        escape_shortcut = QShortcut(QKeySequence("Escape"), self)
        escape_shortcut.activated.connect(self.escape_search)

    def focus_search_input(self):
        """聚焦到搜索栏"""
        self.search_input.setFocus()
        # 选中搜索框中的所有文本，方便直接替换
        self.search_input.selectAll()
        self.status_bar.showMessage("已聚焦到搜索栏 (Ctrl+F)")

    def clear_and_focus_search(self):
        """清空搜索框并聚焦"""
        self.search_input.clear()
        self.search_input.setFocus()
        self.status_bar.showMessage("搜索栏已清空")

    def escape_search(self):
        """按 Escape 键：清空搜索并恢复原始数据"""
        if self.search_input.text():
            # 如果有搜索内容，清空搜索
            self.search_input.clear()
            self.status_bar.showMessage("已清空搜索")
        else:
            # 如果搜索框为空，聚焦到第一个标的
            self.select_first_row()
            self.status_bar.showMessage("已回到第一个标的")


def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    window = MainWindow()
    window.show()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()

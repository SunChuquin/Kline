# Tasks

## 阶段一：figma 原型画廊（设计稿先行，用户看稿定方案）

- [x] Task 1: 新建 `figma/favorites-market-ui-proposals.html` 骨架 + 自选页 4 档屏
  - [x] SubTask 1.1: 复用 `figma/trading-ui-proposals.html` 的画廊骨架（`:root` 变量、`.bezel` 设备框、`.screen-wrap` 573×430 + `.screen` 1024×768 `scale(.55957)`、`.switcher`/`.seg`、`.marker` 标注、`.ncard` 标注栏、`.cmp` 对比表、`#shot=` 单屏定位），不引入任何外链依赖
  - [x] SubTask 1.2: 自选页 4 屏：A 经典表格式（照现状复刻：标题栏 + 分组 Tab 条 + 吸顶表头 + 表格行）、B 分组侧栏 + 表格工作区、C 自选卡片流（含卡片/表格切换按钮）、D 分组看板 + 紧凑表格
  - [x] SubTask 1.3: 每屏配编号标注 + 标注栏（描述 / 布局标注 / 优势 / 代价），并在 `SCREENS` 表里登记 `cap`/`desc`/`ann`/`pro`/`con`

- [x] Task 2: 行情页 4 档屏 + 个人中心演示屏 + 对比表
  - [x] SubTask 2.1: 行情页 4 屏：A 经典表格式（照现状复刻：一级菜单 + 上下箭头 + 二级胶囊 + 表格）、B 分类侧栏 + 表格、C 磁贴卡片网格（含磁贴/表格切换）、D 概览 + 紧凑表格
  - [x] SubTask 2.2: 个人中心演示屏：五行设置行（主题 / 快捷面板布局 / 模拟页布局 / 自选页布局 / 行情页布局）+ 四选项选择面板（210pt 宽、蓝色 checkmark、底部「完成」）
  - [x] SubTask 2.3: 方案对比表：8 档按「信息密度 / 横屏利用 / 首屏信息量 / 操作步数 / 实现复杂度 / 适配场景」横向对比

- [x] Task 3: 截图与自检交付
  - [x] SubTask 3.1: 用无头浏览器按 `#shot=<屏 id>` 逐屏截图，输出到 `figma/_shots/`（命名 `fav_A.png`…`mkt_D.png`、`profile_layouts.png`）
  - [x] SubTask 3.2: 自检：每屏无溢出 / 无文字截断 / 无重叠、编号标注与标注栏条目一一对应、设备框尺寸与既有画廊一致
  - [x] SubTask 3.3: 交付说明（画廊路径 + 截图路径 + 8 档一览），等用户定档

## 阶段二：骨架 + 个人中心入口（A 档行为零变化）

- [x] Task 4: 布局偏好仓库 `Kline/App/PageLayoutStore.swift`
  - [x] SubTask 4.1: `FavoritesLayoutStyle`（a `classic` / b `sidebar` / c `cards` / d `board`）与 `MarketLayoutStyle`（a `classic` / b `sidebar` / c `tiles` / d `overview`），各带 `rawValue` / `title`（如「A · 经典表格式（现有）」）/ `shortTitle` / `CaseIterable` / `Identifiable`
  - [x] SubTask 4.2: `PageLayoutStore: ObservableObject` 单例，`@Published var favoritesLayout` / `marketLayout`，`didSet` 写 UserDefaults（key `kline.favoritesLayout` / `kline.marketLayout`），`private init()` 读回并回退 `.a`
  - [x] SubTask 4.3: 写法对齐 [TradingLayoutStore](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Trading/TradingLayoutStore.swift#L62-L85) 与 [KlineThemeStore](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/KlineTheme.swift)，不引入新范式

- [x] Task 5: 个人中心两行新设置
  - [x] SubTask 5.1: 把 `TradingLayoutDropdownButton` / `TradingLayoutOptionsPanel` 改名为 `LayoutDropdownButton` / `LayoutOptionsPanel`（同文件内改名并更新既有两处引用），保持样式参数逐项不变
  - [x] SubTask 5.2: 新增 `FavoritesLayoutSettingRow` / `MarketLayoutSettingRow`（标题 16pt + 右侧下拉按钮，`frame(minHeight: 36)`），与既有两行同构
  - [x] SubTask 5.3: 在 [ProfileDetailView](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/ProfileDetailView.swift#L44-L96) 的 ScrollView 中、模拟页布局行下方插入两行，并各配一个容器层 overlay（`black 25%` 遮罩 + 居中面板 + `.transition(.opacity)` + `zIndex(1000)`）
  - [x] SubTask 5.4: 把互斥 `onChange` 链由 4 项扩为 6 项（主题 / 快捷面板 / 模拟页 / 自选页 / 行情页 / 公式中心）

- [x] Task 6: 自选页分发容器 + 共享骨架 `Kline/Favorites/FavoritesPageKit.swift`
  - [x] SubTask 6.1: 先按 `.trae/skills/swiftui-large-file-split` 做 recon（结构清单 / 状态使用矩阵 / 调用方普查），确认可搬移边界
  - [x] SubTask 6.2: 抽共享子视图：`FavoritesToolbar`（标题 + 编辑 / 表头设置 / 分组管理 / 新建）、`FavoritesGroupTabs`（横向分组 Tab 条）、`FavoritesTableBody`（吸顶表头 + 行 + 冻结列横向滚动 + 边线覆盖层 + 下拉刷新）、`FavoritesEmptyStates`、`FavoritesSheets`（四个 sheet + 公式编辑浮层）
  - [x] SubTask 6.3: 抽共享状态与动作：分组 Tab 列表、当前分组 / 当前标的、`sortedRows` 快照、`frozenCount` / `maxHOffset` / 横向拖拽手势、编辑模式与手动组重排落盘、公式分组刷新进度
  - [x] SubTask 6.4: 新增 `FavoritesLayoutAView`，把现有 `FavoritesView` 的 body 等价搬入（呈现与交互零变化，`favorites.title` 标识保留）
  - [x] SubTask 6.5: [FavoritesView](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesView.swift#L63-L118) 改为按 `PageLayoutStore.shared.favoritesLayout` 分发的容器（B/C/D 先临时回落到 A 档视图）

- [x] Task 7: 行情页分发容器 + 共享骨架 `Kline/Market/MarketPageKit.swift`
  - [x] SubTask 7.1: 先做 recon（同上），确认一级 / 二级菜单、横向滚动、边线调节、字段筛选快照的可搬移边界
  - [x] SubTask 7.2: 抽共享子视图：`MarketHeaderBar`（一级菜单 + 上下箭头图标 + 左设置 / 右公式、搜索）、`MarketSecondLevelBar`（二级胶囊）、`MarketTableBody`（吸顶表头 + 行 + 横向滚动 + `ColumnResizeOverlay` + 下拉刷新）、`MarketSheets`
  - [x] SubTask 7.3: 抽共享状态与动作：`displayRows` 快照与 `scheduleRefresh()`、`hScrollOffset` / `maxHOffset` / 横向拖拽、`edgeAdjust`、字段筛选防抖、`DetailRouter.open(meta, in:)` 上下文
  - [x] SubTask 7.4: 新增 `MarketLayoutAView`，把现有 `MarketView` 的 body 等价搬入（`market.topMenu.*` / `market.rowCard` 标识保留）
  - [x] SubTask 7.5: [MarketView](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketView.swift#L167-L214) 改为按 `PageLayoutStore.shared.marketLayout` 分发的容器（B/C/D 先临时回落到 A 档视图）
  - [x] SubTask 7.6: [MarketRow](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketRow.swift#L18-L22) 增加只读访问器 `recentCloses: [Double]`（由 `recentBars` 派生，不改缓存与既有字段）

- [x] Task 8: 阶段二闭环
  - [x] SubTask 8.1: 编码自查（`Color.opacity` 入参 Double、勿遮蔽同名参数、`@Published` 同值赋值加守卫、避免在 `body` 内重计算、只改本阶段相关文件）
  - [x] SubTask 8.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(page-layout): 自选/行情页布局仓库与个人中心入口 + A 档等价搬运"`（run=35546651518，退出码 6 构建成功）
  - [x] SubTask 8.3: 交付说明（build 号 / 改动与理由 / 真机验证路径：个人中心新增两行可切 4 档，A 档下两页行为与改造前一致）

## 阶段三：自选页 B / C / D

- [x] Task 9: 自选页 B（分组侧栏 + 表格工作区）
  - [x] SubTask 9.1: 新增 `FavoritesLayoutBView` + `FavoritesGroupSidebar`（216pt：分组行图标 + 名称 + 数量，选中高亮；底部「新建分组 / 管理分组」；公式分组带刷新按钮与进度）
  - [x] SubTask 9.2: 右侧工作区：当前分组名 + 计数 + 工具条（表头设置 / 编辑）+ `FavoritesTableBody` 复用

- [x] Task 10: 自选页 C（自选卡片流）
  - [x] SubTask 10.1: 新增 `FavoritesLayoutCView` + `FavoritesStockCard`（72pt：名称/代码双行、`MarketRow.recentCloses` 迷你走势、现价、涨跌幅胶囊），并接入 `FavoritesGroupTabs`
  - [x] SubTask 10.2: 「卡片 / 表格」切换：表格式复用 `FavoritesTableBody`；卡片式下拉刷新、长按菜单、左滑菜单与 A 档一致
  - [x] SubTask 10.3: 编辑模式在卡片式下沿用 `List` + `onMove`（同现有手动组重排机制）

- [x] Task 11: 自选页 D（分组看板 + 紧凑表格）
  - [x] SubTask 11.1: `FavoritesGroupBoard`（横向滚动分组卡：组名 / 标的数 / 涨跌家数 / 组内平均涨跌幅）+ 统计条（总数 / 涨跌平家数 / 平均涨跌幅），统计在数据快照阶段算好写入 `@State`
  - [x] SubTask 11.2: 紧凑表格（行高 34、字号 15）复用 `FavoritesTableBody`（行高与字号做成可配参数，默认沿用 A 档 45 / 18）

- [x] Task 12: 阶段三闭环
  - [x] SubTask 12.1: B/C/D 三档互切自测（分组联动、卡片↔表格切换、看板统计与表格一致、空态与加载态）
  - [x] SubTask 12.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(page-layout): 自选页 B/C/D 三套布局"`（与阶段四合并为一次构建：首次 run=35547737370 因 D 档缺 `import Combine` 失败，补导入后 run=35547825436 退出码 6 构建成功）
  - [x] SubTask 12.3: 交付说明，等待真机验收

## 阶段四：行情页 B / C / D

- [x] Task 13: 行情页 B（分类侧栏 + 表格）
  - [x] SubTask 13.1: 新增 `MarketLayoutBView` + `MarketCategorySidebar`（200pt：一级分区标题 + 二级条目 + 数量角标，选中高亮；一级项复用 `market.topMenu.*` 标识）
  - [x] SubTask 13.2: 右侧：当前分类名 + 工具条（表头设置 / 边线调整 / 搜索 / 公式）+ `MarketTableBody` 复用

- [x] Task 14: 行情页 C（磁贴卡片网格）
  - [x] SubTask 14.1: 新增 `MarketLayoutCView` + `MarketTileCard`（108pt：名称/代码、大字现价、涨跌幅胶囊、迷你走势、右上角自选星标切换），列数按可用宽度自适应（≥960 三列 / ≥640 两列 / 否则一列）
  - [x] SubTask 14.2: 每格带 `market.rowCard` 标识，点击按当前分类列表上下文打开 K 线详情；长按菜单与 A 档一致
  - [x] SubTask 14.3: 「磁贴 / 表格」切换：表格式复用 `MarketTableBody`

- [x] Task 15: 行情页 D（概览 + 紧凑表格）
  - [x] SubTask 15.1: `MarketOverviewBar`（涨/跌/平家数、涨停/跌停数、总成交额），在 `scheduleRefresh()` 里对当前分类快照一次性统计后写入 `@State`
  - [x] SubTask 15.2: 紧凑表格复用 `MarketTableBody`（行高 34、字号 15 参数化），保留二级胶囊与工具条

- [x] Task 16: 阶段四闭环
  - [x] SubTask 16.1: B/C/D 三档互切自测（分类联动、磁贴↔表格切换、概览统计与表格一致、空态与加载态）
  - [x] SubTask 16.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(page-layout): 行情页 B/C/D 三套布局"`（与阶段三合并为一次构建，run=35547825436 退出码 6）
  - [x] SubTask 16.3: 交付说明，等待真机验收

## 阶段五：验收

- [ ] Task 17: 逐档核验 checklist（8 档 + 个人中心 + 工程项），失败的条目回填 tasks 修复后重验
- [ ] Task 18: 最终交付说明（各阶段 build 号、8 档一览、真机验证路径与回归点、`git status` 无遗留改动）

# Task Dependencies

- Task 2 依赖 Task 1（同一 HTML 文件、共用画廊骨架与 `SCREENS` 表）
- Task 3 依赖 Task 1、Task 2
- Task 5 依赖 Task 4
- Task 6 与 Task 7 可并行（互不改文件；Task 7.6 改 `MarketRow` 只被 Task 7 使用）
- Task 6 依赖 Task 4；Task 7 依赖 Task 4
- Task 8 依赖 Task 5、Task 6、Task 7
- Task 9 / 10 / 11 依赖 Task 6、Task 8
- Task 13 / 14 / 15 依赖 Task 7、Task 8
- Task 12 依赖 Task 9、Task 10、Task 11；Task 16 依赖 Task 13、Task 14、Task 15
- Task 17 / 18 依赖 Task 12、Task 16
- 阶段一与阶段二可并行（figma 原型不改 Swift 代码）

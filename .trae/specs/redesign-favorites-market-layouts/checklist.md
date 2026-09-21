# Checklist

> 核验方式：逐条对照实现代码（静态核验，文件 + 行号）与原型文件。标 ⏳ 的为纯视觉/交互项，需真机确认。

## figma 原型画廊

- [x] `figma/favorites-market-ui-proposals.html` 为自包含单文件，无外链依赖（无 CDN / 无远程字体 / 无远程图片）—— 全文仅 `xmlns` 命名空间与 data-URI favicon，无 `http(s)://` 资源引用、无 `@import url(`
- [x] 设备框与既有画廊一致（iPad mini 4 横屏 1024×768，等比缩放至 573×430，`.bezel` 深色外壳）—— `.screen-wrap` 573×430 + `.screen` 1024×768 `scale(.55957)`，与 `trading-ui-proposals.html` 同参数
- [x] 自选页 4 屏齐全且可切换：A 经典表格式（照现状复刻）/ B 分组侧栏 + 表格工作区 / C 自选卡片流 / D 分组看板 + 紧凑表格 —— `#scr-favA`/`#scr-favB`/`#scr-favC`/`#scr-favD`（HTML:352/372/399/417）
- [x] 行情页 4 屏齐全且可切换：A 经典表格式（照现状复刻）/ B 分类侧栏 + 表格 / C 磁贴卡片网格 / D 概览 + 紧凑表格 —— `#scr-mktA`/`#scr-mktB`/`#scr-mktC`/`#scr-mktD`（HTML:475/501/524/549）
- [x] 个人中心演示屏展示五行设置行（主题 / 快捷面板 / 模拟页 / 自选页 / 行情页）与四选项选择面板 —— `#scr-profileLayouts`（HTML:619）；截图 `figma/_shots/profile_layouts.png` 已逐项复核
- [x] 每屏有编号标注，且与右侧标注栏条目一一对应（描述 / 布局标注 / 优势 / 代价）—— 每屏 5–6 个 `.marker`，`SCREENS` 表（HTML:888 起）逐屏登记 `cap/desc/ann/pro/con`，编号与 `ann` 顺序一致
- [x] 跨方案对比表覆盖 8 档，维度含信息密度 / 横屏利用 / 首屏信息量 / 操作步数 / 实现复杂度 / 适配场景 —— HTML:672 表头六项齐备，673–682 共 8 档数据行
- [x] 支持 `#shot=<屏 id>` 单屏定位，无头浏览器截图时无多余区块干扰 —— `body.shot` 隐藏 hero / 区块标题 / 切换器 / 标注栏 / 对比表（CSS:282 + JS:1051-1060）；9 张截图均只呈现目标设备框
- [x] 逐屏截图已输出到 `figma/_shots/`（`fav_A`…`mkt_D`、`profile_layouts`），每屏无溢出 / 无文字截断 / 无元素重叠 —— 9 张 PNG 已逐张目视复核（设备框完整、表格列与文案无截断、看板卡未横向截断）

## 布局偏好与个人中心

- [x] `PageLayoutStore` 为单例 `ObservableObject`，两个布局字段写入 UserDefaults（key `kline.favoritesLayout` / `kline.marketLayout`），默认值均为 A —— `PageLayoutStore.swift:66-91`
- [x] 存储值非法或缺失时回退 A 且不崩溃 —— `PageLayoutStore.swift:85,88`（`?? .a`，读回失败即回退默认）
- [x] 个人中心出现两行新设置「自选页布局」「行情页布局」，右侧下拉按钮显示当前档名（字号 12 / 高 28 / `.plain` / 蓝色前景）—— `TradingLayoutSettings.swift:135,151`（两行）+ `LayoutDropdownButton`（同文件 `:19-38`：字号 12 / `.frame(height: 28)` / `.buttonStyle(.plain)` / `.foregroundColor(.blue)`）
- [x] 两个新选择面板样式与 `KlineThemeOptionsPanel` 逐项一致（210pt 宽、行内 padding、蓝色 checkmark、底部「完成」、圆角 12、阴影 black 20% radius 12 y 4）—— `TradingLayoutSettings.swift:45-97`，四个布局行共用同一泛型面板
- [x] 两个新浮层挂在页面容器层 overlay（`black 25%` 遮罩 + 居中 + `.transition(.opacity)` + `zIndex(1000)`），不被 ScrollView 裁剪 —— `ProfileDetailView.swift:164-193`
- [x] 六个浮层（主题 / 快捷面板 / 模拟页 / 自选页 / 行情页 / 公式中心）互斥，同时只呈现一个 —— `ProfileDetailView.swift:204-221`（6 个 `onChange`，任一置 true 时清其余 5 项）
- [x] 泛型组件改名后既有两行（快捷面板 / 模拟页）样式与交互无变化 —— 全项目 Grep `TradingLayoutDropdownButton|TradingLayoutOptionsPanel` 无匹配；`TradingLayoutSettings.swift:100-132` 两行仅按钮类型名变化，参数逐项未动
- [x] 切换布局无需重启即生效；重启后仍保持所选档位 —— `@Published` + `didSet` 写 UserDefaults；`FavoritesView.swift:19`、`MarketView.swift:50` 均 `@ObservedObject layoutStore`

## 自选页四档

- [x] `FavoritesView` 按 `favoritesLayout` 分发 A/B/C/D 四档 —— `FavoritesView.swift:30-39`
- [x] A 档即改造前实现（工具条 + 分组 Tab 条 + 吸顶表头 + 表格行 + 长按菜单 + 下拉刷新 + 编辑模式重排），`favorites.title` 标识保留 —— `FavoritesLayoutAView.swift:16-24` 组合 `FavoritesToolbar`/`FavoritesGroupTabs`/`FavoritesTableBody`；标识在 `FavoritesPageKit.swift:210`
- [x] B 档：216pt 分组侧栏（图标 + 名称 + 数量、选中高亮、底部「新建分组 / 管理分组」、公式分组刷新入口）与右侧工作区联动 —— `FavoritesLayoutBView.swift:131`（`width = 216`）、152-160（列表）、231-238（底部按钮）、208-227（公式行刷新）；点击写 `fav.selectedGroupID`（197）
- [x] C 档：卡片式每标的 72pt 卡片（名称/代码、迷你走势、现价、涨跌幅胶囊），「卡片 / 表格」可切换，切到表格式后与 A 档能力一致 —— `FavoritesLayoutCView.swift:154`（`frame(height: 72)`）、166-232（名称/走势/统计/价格块）、48-59（分段切换）、113（表格形态复用 `FavoritesTableBody`）
- [x] C 档：下拉刷新、长按菜单（取消自选 / 加入分组 / 移动分组）、编辑模式重排（`List` + `onMove`）与 A 档行为一致 —— `FavoritesLayoutCView.swift:126-128`（refreshable）、160-162（contextMenu 复用 `favoritesRowMenuContent`）、105-107（编辑态复用 `FavoritesManualEditingList`）
- [x] D 档：分组看板卡（组名 / 标的数 / 涨跌家数 / 组内平均涨跌幅）与统计条数值与该分组实际数据一致 —— `FavoritesLayoutDView.swift:33-47`（`compute(rows:)` 单一口径）、145-184（看板卡）、188-207（统计条）；看板与统计条读同一份 `groupStats`
- [x] D 档：紧凑表格行高 34、字号 15，表头吸顶、冻结列横向滚动正常 —— `FavoritesLayoutDView.swift:84`（`rowHeight: 34, fontSize: 15`）→ `FavoritesPageKit.swift:365-367` 透传 → `MarketTableRow.swift:122-124` 落到行内部
- [x] 四档共用同一套 `FavoritesStore` / `MarketConfigStore` / `MarketRowCache`，切换布局不丢失当前分组、排序与筛选配置 —— 分组/排序/筛选分别挂在 `FavoritesStore.selectedGroupID`、`MarketConfigStore`（按 `.favorites` 页面）；`FavoritesPageModel` 由容器 `@StateObject` 持有，切档不重建
- [x] 四档的表头设置、冻结列横向滚动、边线拖改、表头排序、字段筛选、长按菜单、下拉刷新、空态、加载态均可用 —— 前七项统一由 `FavoritesTableBody` 承载（A/B/D 直接渲染，C 的「表格」形态渲染），空态/加载态在 `FavoritesPageKit.swift:369-381` 与 C 档 97-103；5 个 sheet/overlay 经 `favoritesSheets(model:)` 挂容器层，四档共用
- [x] 四档均使用语义化颜色，深色模式可读（无写死白底）—— 全部背景为 `Color(.systemBackground)` / `.secondarySystemBackground` / `.systemGray6`；`.white` 仅作彩色胶囊与蓝色按钮上的文字色（`FavoritesLayoutCView.swift:226`、`FavoritesPageKit.swift:458`）
- [ ] ⏳ 可点击元素命中区 ≥ 44×44pt；行高固定，状态切换不抖动 —— 代码层已核（工具条图标 44×44、分组行 44pt、分段按钮 36+4×2=44、卡片「更多」44×44、侧栏底部按钮 44），实际手感需真机确认

## 行情页四档

- [x] `MarketView` 按 `marketLayout` 分发 A/B/C/D 四档 —— `MarketView.swift:106-115`
- [x] A 档即改造前实现（一级菜单 + 上下箭头图标 + 二级胶囊 + 左设置 / 右公式、搜索 + 表格），`market.topMenu.*` 与 `market.rowCard` 标识保留 —— `MarketLayoutAView.swift:17-30`；标识在 `MarketPageKit.swift:413` 与 `:667`
- [x] B 档：200pt 分类侧栏（一级分区 + 二级条目 + 数量角标、选中高亮），点条目右侧表格即时切换 —— `MarketLayoutBView.swift:58`（`width = 200`）、93-121（条目行 + 角标）、95-97（点击走 `setSidebarSelection`）
- [x] C 档：磁贴列数按可用宽度自适应（≥960 三列 / ≥640 两列 / 否则一列），每格带 `market.rowCard` 标识，点击按当前分类上下文打开 K 线详情 —— `MarketLayoutCView.swift:76-86`（`gridColumns(for:)`）、175（标识）、176-178（`DetailRouter.shared.open(meta, in: model.displayRows.map { $0.meta })`）
- [x] C 档：磁贴右上角自选星标可切换加/取消自选；「磁贴 / 表格」可切换，切到表格式后与 A 档能力一致 —— `MarketLayoutCView.swift:154-163`（星标 44×44，`fav.toggleFavorite`）、223-249（分段切换）、47（表格形态复用 `MarketTableBody`）
- [x] D 档：概览条涨/跌/平家数、涨停/跌停数、总成交额与当前分类实际数据一致，且统计在快照阶段预计算（`body` 内无全表重计算）—— 口径集中在 `MarketPageKit.swift:301`（`makeOverview`），由 `scheduleRefresh()` 在 filtered 快照上调用（`:292`）；`MarketLayoutDView.swift:70-128` 只读 `model.overview`，无遍历
- [x] D 档：紧凑表格行高 34、字号 15，二级胶囊与工具条保留 —— `MarketLayoutDView.swift:20`（`compactMetrics` = 32/34/15）、28-38（胶囊 + 工具条）、54（紧凑表）
- [x] 四档共用同一套分类、排序与筛选配置，切换布局不丢失当前一级 / 二级分类与排序筛选 —— 分类状态在 `MarketPageModel`（容器 `@StateObject` 持有，切档不重建），排序/筛选在 `MarketConfigStore`（按 `.marketBoard` 页面）
- [x] 四档的表头设置、边线调节、冻结列横向滚动、排序、字段筛选、长按菜单、下拉刷新、搜索页、公式入口、空态、加载态均可用 —— 表格能力由 `MarketTableBody` 承载（A/B/D 直接渲染，C 的「表格」形态渲染，含 `ColumnResizeOverlay` 与 `horizontalDragGesture`）；4 个 sheet/overlay 经 `marketSheets(model:)` 挂容器层，四档共用；搜索与公式入口在 A/C 的 `MarketHeaderBar`、B/D 的 `MarketToolBar`
- [x] 四档均使用语义化颜色，深色模式可读（无写死白底）—— 全部背景为 `Color(.systemBackground)` / `.secondarySystemBackground` / `.systemGray6`；`.white` 仅作涨跌幅胶囊文字色（`MarketLayoutCView.swift:139`）
- [ ] ⏳ 可点击元素命中区 ≥ 44×44pt；行高固定，状态切换不抖动 —— 代码层已核（侧栏分区与条目 44pt、工具条胶囊 28 撑到 44、星标 44×44、分段 36+8=44），实际手感需真机确认

## 共享骨架与数据

- [x] `FavoritesPageKit.swift` / `MarketPageKit.swift` 承载工具条、导航、表格主体、卡片 / 磁贴、概览条与全部 sheet / overlay，各档布局视图只做组合，无业务逻辑复制 —— `FavoritesPageKit.swift`（`FavoritesPageModel` + Toolbar/GroupTabs/TableBody/ManualEditingList/Sheets，578 行）、`MarketPageKit.swift`（`MarketPageModel` + HeaderBar/SecondLevelBar/TableBody/ToolBar/Overview/Sheets，700 行）；四档布局视图均只做组合（`FavoritesLayoutA/B/C/DView` 30/261/303/254 行，`MarketLayoutA/B/C/DView` 41/175/253/131 行）
- [x] 布局拆分过程遵循 `.trae/skills/swiftui-large-file-split`（recon → 计划 → 执行 → 验证）—— 阶段二子任务按 recon → 抽共享骨架 → 等价搬运 → 容器化推进（tasks.md Task 6.1 / 7.1）
- [x] `MarketRow.recentCloses` 为只读派生访问器，既有字段、缓存与格式化行为无变化 —— `MarketRow.swift:24-25`（`(recentBars ?? []).map(\.close)`，纯只读计算属性，未触碰 `cache` / `textCache` / `setBars`）
- [x] 未新增数据源、未改任何持久化文件结构（`favorites.json` / `market_columns.json` / `sim.json` 不变）—— `git diff` 对 `Kline/Data`、`FavoritesStore.swift`、`MarketConfigStore.swift`、`SimStore.swift` 无任何改动

## 工程与交付

- [x] 新增文件全部位于 `Kline/` 目录树内，无需手工改 `project.pbxproj`（依赖 `PBXFileSystemSynchronizedRootGroup`）—— 四次提交的 `--name-only` 清单中均未出现 `project.pbxproj`
- [x] 阶段二 / 三 / 四闭环命令均返回 0 / 6 / 7，构建通过 —— 阶段二 run=35546651518（退出码 6）；阶段三 + 四 run=35547825436（退出码 6，首次 35547737370 因缺 `import Combine` 失败已修复）；B 档侧栏占位修正 run=35548018420
- [x] 交付说明包含各阶段 build 号、8 档一览与真机验证路径；`git status` 无遗留未提交改动 —— 见最终交付说明；spec 三件套随最后一次闭环命令一并提交
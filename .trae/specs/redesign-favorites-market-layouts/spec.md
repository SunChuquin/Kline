# 自选页 / 行情页 多布局重设计 Spec

## Why

用户要求用 figma 原型（沿用项目既有的 `figma/` 原型画廊做法）为「自选页」与「行情页」重新设计，各至少给出三种新方案；加上现有实现共 4 档，并在个人中心可**独立**选择。

现状落差：两个页面各自只有**一套**表格式布局，且布局代码与业务逻辑全部耦合在两个大文件里（[FavoritesView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesView.swift) 843 行、[MarketView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketView.swift) 543 行），既无法切换，也没有可复用的页面骨架。

## What Changes

- 新增 figma 原型画廊 `figma/favorites-market-ui-proposals.html`：自选页 4 档 + 行情页 4 档 + 「个人中心布局切换」演示屏，含 iPad 设备框、方案切换器、编号标注、优缺点卡与方案对比表；逐屏截图存 `figma/_shots/`（沿用既有命名与「不纳入提交」惯例）。
- 新增布局偏好仓库 `Kline/App/PageLayoutStore.swift`：`FavoritesLayoutStyle`（A/B/C/D）与 `MarketLayoutStyle`（A/B/C/D）+ `UserDefaults` 持久化（key `kline.favoritesLayout` / `kline.marketLayout`），默认均为 A。
- 个人中心新增两行设置「自选页布局」「行情页布局」，复用既有下拉按钮与选择面板（两个泛型组件去掉 `Trading` 前缀改名，4 行设置共用），弹窗样式与互斥规则与既有主题弹窗完全一致。
- 自选页 / 行情页改造为**按布局分发的容器**（对齐 [SimulationView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Simulation/SimulationView.swift) 的分发惯例）；现有实现**等价搬进 A 档视图**，A 档行为零变化；B/C/D 为新增视图。
- 抽出共享组件与共享状态：`Kline/Favorites/FavoritesPageKit.swift`、`Kline/Market/MarketPageKit.swift`（工具条 / 分组导航 / 表格主体 / 卡片行 / 磁贴 / 概览条 / 全部 sheet 与 overlay），各档布局只做组合，不复制业务逻辑。
- [MarketRow.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketRow.swift#L18-L22) 增加只读访问器 `recentCloses`（供迷你走势 sparkline 取近 N 日收盘），不改既有字段与缓存行为。
- **BREAKING**：无。仅新增文件、新增枚举与仓库字段，以及把两个页面的既有 body 等价搬进 A 档视图。

## Impact

- Affected specs: `add-trading-layout-options`（个人中心设置行新增两行、弹窗互斥链由 4 项扩为 6 项、下拉组件改名）
- Affected code:
  - 修改 [FavoritesView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesView.swift)（改分发容器，现有 body 搬进 A 档视图）
  - 修改 [MarketView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketView.swift)（同上）
  - 修改 [ProfileDetailView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/ProfileDetailView.swift#L44-L96)（加两行设置 + 两个浮层 + 互斥）
  - 修改 [TradingLayoutSettings.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/TradingLayoutSettings.swift)（泛型组件改名，新增两个设置行）
  - 修改 [MarketRow.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketRow.swift)（加只读访问器）
  - 新增 `Kline/App/PageLayoutStore.swift`、`Kline/Favorites/FavoritesPageKit.swift` + 4 个自选页布局视图、`Kline/Market/MarketPageKit.swift` + 4 个行情页布局视图
  - 新增 `figma/favorites-market-ui-proposals.html`
  - 工程文件无需改动：`Kline.xcodeproj` 使用 `PBXFileSystemSynchronizedRootGroup`，新增目录自动纳入编译

## 交付分期

- **阶段一（设计稿）**：Task 1–3。产出 figma 原型画廊 + 逐屏截图，用户先看稿定方案。
- **阶段二（骨架 + 入口）**：Task 4–8。布局仓库、个人中心两行、两页分发容器（A 档等价搬运），独立可编译可真机验收。
- **阶段三（自选页 B/C/D）**：Task 9–12。
- **阶段四（行情页 B/C/D）**：Task 13–16。
- **阶段五（验收）**：Task 17–18。

***

## 设计档位（本次要落地的 4×2 档）

### 自选页

| 档 | 名称 | 信息架构要点 |
|---|---|---|
| A | 经典表格式（**现有实现**） | 标题栏（自选 + 编辑 / 表头设置 / 分组管理 / 新建）+ 横向分组 Tab 条 + 吸顶表头 + 表格行 |
| B | 分组侧栏 + 表格工作区 | 左 216pt 分组侧栏（图标 + 名称 + 数量、选中高亮，底部「新建分组 / 管理分组」，公式分组带刷新与状态点）+ 右侧工作区（当前分组名 + 计数 + 工具条 + 吸顶表头 + 表格行） |
| C | 自选卡片流 | 分组胶囊条 + 「卡片 / 表格」切换；卡片式每标的 72pt 卡片（名称/代码双行、近 20 日迷你走势、现价、涨跌幅胶囊），左滑 / 长按出既有菜单；表格式复用 A 的表格主体 |
| D | 分组看板 + 紧凑表格 | 顶部横向分组看板卡（组名、标的数、涨/跌家数、组内平均涨跌幅）+ 统计条（自选总数、涨/跌/平家数、平均涨跌幅）+ 下部紧凑表格（行高 34、字号 15） |

### 行情页

| 档 | 名称 | 信息架构要点 |
|---|---|---|
| A | 经典表格式（**现有实现**） | 一级菜单（市场/选股/自选 + 上下箭头）+ 左设置、右公式/搜索 + 二级胶囊栏 + 吸顶表头 + 表格行 |
| B | 分类侧栏 + 表格 | 左 200pt 侧栏（三个一级分区，二级项为条目，选中高亮 + 数量角标）+ 右侧工具条（当前分类名 + 表头设置 / 边线调整 / 搜索 / 公式）+ 表头 + 表格行 |
| C | 磁贴卡片网格 | 一级菜单 + 二级胶囊 + 「磁贴 / 表格」切换；磁贴式按宽度自适应列数（≥960pt 三列 / ≥640pt 两列 / 否则一列），每格 108pt（名称/代码、大字现价、涨跌幅胶囊、迷你走势、右上角自选星标）；表格式复用 A 的表格主体 |
| D | 概览 + 紧凑表格 | 顶部概览条（涨/跌/平家数、涨停/跌停数、总成交额）+ 二级胶囊 + 工具条 + 下部紧凑表格（行高 34、字号 15） |

### 通用约束（8 档全部适用）

- 复用既有数据源与配置，不新增数据源、不改持久化结构：`FavoritesStore`、`DatabaseManager.metaList`、`MarketRowCache`、`MarketConfigStore`、`DetailRouter`。
- 全部使用语义化颜色（`Color(.systemBackground)` / `.primary` / `.secondarySystemBackground` 等），深色模式可读；禁止写死白底。
- 所有可点击元素命中区 ≥ 44×44pt；行高固定，状态切换不抖动。
- 概览 / 看板类统计（行情 D、自选 D）在数据快照阶段一次性算好写入 `@State`，**禁止在 `body` 内做全表重计算**。
- 迷你走势取 `MarketRow.recentCloses`，缺数据时该区块留空不占位错位。

## ADDED Requirements

### Requirement: 页面布局偏好持久化

系统 SHALL 提供 `PageLayoutStore`（`ObservableObject` 单例，`UserDefaults` 持久化），分别保存自选页布局与行情页布局，取值域各为 A / B / C / D，默认均为 A；选择变更后对应页面 SHALL 立即生效，且 App 重启后保持。

#### Scenario: 切换后立即生效并持久化

- **WHEN** 用户在个人中心把「自选页布局」从 A 改为 C
- **THEN** 自选页立刻呈现 C 档，且杀掉 App 重启后仍是 C

#### Scenario: 非法/缺失存储值回退默认

- **WHEN** `UserDefaults` 中该 key 为空或不是 A/B/C/D
- **THEN** 该布局回退为 A，不崩溃

### Requirement: 个人中心两行布局下拉

系统 SHALL 在个人中心新增两行设置「自选页布局」「行情页布局」，每行右侧为显示当前档名的下拉触发按钮（字号 12 / 高 28 / `.plain` / 蓝色前景），点击后在页面容器层居中弹出四选项选择面板（210pt 宽、行内 `padding(.horizontal,12)/.vertical,10)` + `Divider`、蓝色 checkmark 选中态、底部「完成」、`systemBackground` + `cornerRadius(12)` + `shadow(black 20%, radius 12, y 4)`），与既有主题弹窗逐项一致。

#### Scenario: 打开与关闭选择面板

- **WHEN** 用户点击「行情页布局」右侧按钮
- **THEN** 弹出四选项面板（A / B / C / D），当前项带蓝色 checkmark；点选项即切换，点「完成」或遮罩关闭

#### Scenario: 六个浮层两两互斥

- **WHEN** 用户先打开主题弹窗、关闭后再打开布局弹窗；或任一弹窗打开时点另一行的按钮
- **THEN** 每次只呈现一个浮层，无叠层错位

### Requirement: 自选页四档布局

系统 SHALL 让自选页按 `PageLayoutStore.favoritesLayout` 呈现 A / B / C / D 四档之一，四档共享同一套分组数据、当前分组、排序与筛选配置。

#### Scenario: A 档行为零变化

- **WHEN** 布局为 A
- **THEN** 自选页与改造前的呈现、交互、无障碍标识（`favorites.title` 等）完全一致

#### Scenario: 分组切换与内容联动

- **WHEN** 在 B 档点侧栏某分组（或在 D 档点分组看板卡）
- **THEN** 右侧 / 下方内容区立即切到该分组数据，选中态与计数同步

#### Scenario: C 档卡片与表格切换

- **WHEN** 在 C 档点「表格」切换按钮
- **THEN** 呈现与 A 档一致的表格主体（同分组、同数据、同列配置），表格能力零缺失；再点回卡片式恢复卡片流

#### Scenario: D 档看板统计正确

- **WHEN** 自选分组内标的行情就绪
- **THEN** 分组看板卡与统计条的标的数、涨/跌家数、平均涨跌幅与该分组实际数据一致

#### Scenario: 表格能力不丢失

- **WHEN** 在任一档布局下使用表头设置面板、冻结列横向滚动、边线拖改、表头排序、字段筛选、长按菜单、下拉刷新
- **THEN** 行为与 A 档一致（卡片 / 磁贴档通过「表格」切换获得同一套能力）

### Requirement: 行情页四档布局

系统 SHALL 让行情页按 `PageLayoutStore.marketLayout` 呈现 A / B / C / D 四档之一，四档共享同一套分类（一级 / 二级）、排序与筛选配置。

#### Scenario: A 档行为零变化

- **WHEN** 布局为 A
- **THEN** 行情页与改造前的呈现、交互、无障碍标识（`market.topMenu.*`、`market.rowCard` 等）完全一致

#### Scenario: B 档侧栏切换分类

- **WHEN** 在 B 档侧栏点「ETF指数」（或「选股 → 趋势」等）
- **THEN** 右侧表格立即切到该分类数据，侧栏选中态同步

#### Scenario: C 档磁贴自适应列数与打开详情

- **WHEN** 在 C 档以横屏 iPad 宽度呈现
- **THEN** 磁贴为三列；点任一磁贴按当前分类列表上下文打开 K 线详情页

#### Scenario: D 档概览统计正确

- **WHEN** 当前分类行情数据就绪
- **THEN** 概览条的涨/跌/平家数、涨停/跌停数、总成交额与当前分类实际数据一致

#### Scenario: 无障碍标识保留

- **WHEN** 在 A / B / D 档运行既有 UITest 冒烟用例（`market.rowCard` 点击进入详情）
- **THEN** 用例通过；C 档磁贴同样带 `market.rowCard` 标识，点击进入详情

### Requirement: figma 原型画廊交付

系统交付 SHALL 包含一个自包含的 `figma/favorites-market-ui-proposals.html`（无外链依赖），按既有 `figma/trading-ui-proposals.html` 的画廊形态组织：iPad mini 4 横屏设备框（1024×768，等比缩放至 573×430）、区块内方案切换器、屏内编号标注与右侧标注栏（描述 / 布局标注 / 优势 / 代价）、以及一张跨方案对比表；并支持 `#shot=<屏 id>` 直接定位单屏，供无头浏览器逐屏截图到 `figma/_shots/`。

#### Scenario: 单屏定位可截图

- **WHEN** 用无头浏览器打开 `figma/favorites-market-ui-proposals.html#shot=favB`
- **THEN** 页面直接呈现自选页 B 档那一屏，无多余区块干扰截图

#### Scenario: 画廊覆盖全部档位

- **WHEN** 打开画廊
- **THEN** 自选页 4 档与行情页 4 档均可切换查看，个人中心演示屏展示两行新设置与四选项面板

### Requirement: 真机验证闭环

系统 SHALL 按项目既定闭环交付：Windows 下执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<提交描述>"`，退出码 0 / 6 / 7 视为构建通过；每次交付说明本轮 build 号、改动内容与真机验证路径。

#### Scenario: 阶段构建通过

- **WHEN** 阶段二 / 三 / 四编码完成
- **THEN** 闭环命令返回 0 / 6 / 7，且 `git status` 无遗留未提交改动

## MODIFIED Requirements

### Requirement: 个人中心设置行与浮层互斥

个人中心 SHALL 呈现五行设置行（Kline 显示主题 / 快捷面板布局 / 模拟页布局 / 自选页布局 / 行情页布局）+ 公式管理入口 + 本地更新面板；任一行触发的浮层（主题、三个布局选择面板、公式管理中心）SHALL 同时只呈现一个。

（原 `add-trading-layout-options` 中「个人中心两个布局下拉按钮」的要求扩展为四个布局下拉按钮：快捷面板 / 模拟页 / 自选页 / 行情页。）

## REMOVED Requirements

无。

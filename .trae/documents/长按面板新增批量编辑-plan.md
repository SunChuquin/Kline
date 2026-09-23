# 长按面板新增「批量编辑」— 实施计划

## Context（为什么做）

自选页与行情页长按标的弹出的操作面板里，目前没有进入「批量编辑」的入口 —— 自选页只能点工具栏的「编辑」按钮，行情页则**完全没有**批量编辑能力。

本次要让两个页面都能「长按标的 → 批量编辑」进入多选批量操作态。

现状差异（决定了工作量不对称）：

| | 自选页 | 行情页 |
|---|---|---|
| 编辑态多选 | 已有（`showEditingMode` + `batchSelection`） | **无** |
| 底部批量条 | 已有（`FavoritesBatchBar`，10 项） | **无** |
| 进入入口 | 工具栏「编辑」按钮 | 无 |
| 行控件 | `MarketTableRow`（放进 `List(selection:)`） | 手写表格（冻结列 + 横向 offset） |

已与用户确认的决策：
1. 行情页批量动作 = **行情页适用子集**：加自选/取消自选、固顶/取消固顶、设置备注/清除备注、设置预警/取消预警、全选/取消全选（**不做**「移出/移到分组」这类分组专属动作）。
2. 长按进入批量编辑时**自动选中被长按的那只标的**。
3. 行情页批量编辑的列表形态 = **换成简易多选列表**（勾选圈 + 名称/代码/现价/涨跌幅）+ 底部批量条，不动现有表格的列宽/冻结/横向滚动几何。
4. 退出入口 = 底部批量条左侧固定一个**「完成」**按钮。

---

## 一、长按面板新增入口项

### 1.1 动作枚举
[FavoritesRowMenu.swift](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesRowMenu.swift#L31-L42) 的 `FavoritesRowMenuAction` 新增 `case batchEdit`。

### 1.2 行情页 / 搜索页共用的 `MetaRowMenuKit`
`MetaRowMenuKit` 目前被**行情页与搜索页共用**（[SearchPageView.swift:97-99](file:///Volumes/home/repositories/Kline2/Kline/Home/SearchPageView.swift#L97-L99)），而搜索页没有批量态 —— 直接加项会让搜索页出现一个点了没用的入口。因此：

- `items(for:includeBatchEdit:)` 新增参数，**默认 `false`**（搜索页不传 → 不出现）。
- 该项插在「加入其它分组」之后、「备注…」之前 —— 保证不用滚动就能看到（面板高度超 320 会进滚动容器，见 [FavoritesRowMenu.swift:106-107](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesRowMenu.swift#L106-L107)）。
- `MetaRowMenuKit.Outcome` 新增 `.batchEdit(Int)`（携带 metaID，供调用方预选），`perform` 返回它。
- 已在批量态时不显示该项（冗余）：由调用方传 `includeBatchEdit: !batchMode`。

### 1.3 三个调用方
- [MarketPageModel.rowMenuItems](file:///Volumes/home/repositories/Kline2/Kline/Market/MarketPageKit.swift#L407-L409) → 传 `includeBatchEdit: !batchMode`；`performRowMenu`（[412-422](file:///Volumes/home/repositories/Kline2/Kline/Market/MarketPageKit.swift#L412-L422)）新增 `case .batchEdit(let id): enterBatchMode(preselect: id)`。
- [SearchPageModel.performRowMenu](file:///Volumes/home/repositories/Kline2/Kline/Home/SearchPageView.swift#L101-L111) → 补 `case .batchEdit: break`（防御性忽略，与 [FavoritesRowMenu.swift:679-682](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesRowMenu.swift#L679-L682) 同风格），否则 switch 不穷尽编译不过。
- [FavoritesPageModel.rowMenuItems](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesPageKit.swift#L271-L349) → 传 `includeBatchEdit: !showEditingMode`；`performRowMenu`（[352-377](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesPageKit.swift#L352-L377)）→ `enterEditingMode(preselect: meta.id)`。

---

## 二、自选页（小改）

`FavoritesPageModel` 新增 `enterEditingMode(preselect: Int?)`：置 `showEditingMode = true`，并把 `batchSelection` 设为 `preselect` 的单元素集合（nil → 空集）。既有 `toggleEditingMode()`（[385-392](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesPageKit.swift#L385-L392)）保持不动，工具栏按钮行为零变化。

编辑态列表 `FavoritesManualEditingList`（[939-1006](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesPageKit.swift#L939-L1006)）与批量条**完全不动**。

---

## 三、行情页（新建批量编辑）

### 3.1 模型状态与方法（`MarketPageModel`）
新增状态：`batchMode: Bool`、`batchSelection: Set<Int>`、`batchNoteTarget: BatchNoteTarget?`。
预警**复用已有** `alertSheetTargets: [MetaItem]`（[MarketPageKit.swift:106](file:///Volumes/home/repositories/Kline2/Kline/Market/MarketPageKit.swift#L106) + 呈现层 [800-812](file:///Volumes/home/repositories/Kline2/Kline/Market/MarketPageKit.swift#L800-L812) 已经是 `FavoritesBatchAlertSheet(metas:)`，天然支持 N 只），不新增载体。

新增方法（对齐 `FavoritesPageModel` 同名实现 [379-542](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesPageKit.swift#L379-L542)）：
`enterBatchMode(preselect:)` / `exitBatchMode()` / `setBatchSelection(_:)` / `batchSelectedMetas()`（按 `displayRows` 显示顺序快照）/ `batchBarItems()` / `performBatch(_:)` / `finishBatch()`（只清空选择、保持批量态）/ `applyBatchNote(_:)`。

**动作必须方向化**（关键坑）：`FavoritesStore.toggleFavorite` 是纯 toggle，裸调「加自选」会把已自选的删掉。照 [setBatchPinned](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesPageKit.swift#L527-L537) 的「先判方向」写法：
- 加自选 = `!isFavorited` 才 toggle；取消自选 = `isFavorited` 才 toggle
- 固顶 = `!isPinned` 才 `pin`；取消固顶 = `isPinned` 才 `unpin`（走全局 API [FavoritesStore.swift:644-656](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesStore.swift#L644-L656)）

新枚举 `MarketBatchAction`（10 项，与自选页同款「两个独立项」风格）：`addFavorite / removeFavorite / pin / unpin / setNote / clearNote / setAlert / cancelAlert / selectAll / deselectAll`。

### 3.2 状态清理订阅
`init()` 里订阅 `$selectedTab`、`$topMenu`、`$pickerSeg`、`$favSeg`、`$showsTileMode`、`PageLayoutStore.shared.$marketLayout` → `setBatchSelection([])`（**清空选择、保持批量态**，与自选页 [83-92](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesPageKit.swift#L83-L92) 口径一致）。

**补一个自选页没有的坑**：切到无标的分类时四档渲染 `MarketEmptyStateView`，批量列表与「完成」会一起消失 → 卡死无出口。故订阅 `$displayRows`，为空时 `exitBatchMode()`。

### 3.3 新视图
`MarketBatchList`：`ScrollView + LazyVStack`（**不用 `List(selection:)`** —— 见下方「已排除方案」）+ 自绘勾选圈（`circle` / `checkmark.circle.fill`）+ 名称/代码 + 现价 + 涨跌幅，整行 tap 切换选中；底部挂 `MarketBatchBar`。数值与颜色直接复用 `rowCache.textFor(metaID, field)` / `rowCache.colorFor(metaID, field)`（[MarketTableRow.swift:268-269](file:///Volumes/home/repositories/Kline2/Kline/Market/MarketTableRow.swift#L268-L269) 同款口径），字段用 `MarketField.latestPrice` / `.changePct`。

### 3.4 插入点
- [MarketTableBody.body](file:///Volumes/home/repositories/Kline2/Kline/Market/MarketPageKit.swift#L646-L685) **最外层**加分支：`if model.batchMode { MarketBatchList } else { 现有 ZStack 原样 }`。这一处即覆盖 A / B / C-表格 / D 四档。放在最外层而非内层，是为了连表头一起去掉（批量态下排序无意义，且简易行与列网格不对齐会误导）。
- C 档磁贴态在 [MarketLayoutCView.content](file:///Volumes/home/repositories/Kline2/Kline/Market/MarketLayoutCView.swift#L39-L56) 另加一条 `batchMode` 分支。
- 横向拖动手势条件补 `|| model.batchMode`（[MarketPageKit.swift:665-666](file:///Volumes/home/repositories/Kline2/Kline/Market/MarketPageKit.swift#L665-L666)），语义明确 + 防御。

---

## 四、底部批量条抽通用件

把 [FavoritesBatchBar](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesRowMenu.swift#L482-L551) 的**纯展示部分**抽成 `BatchActionBar`（`entries: [BatchBarEntry]` + `countText` + `showsDone`/`onDone` + `onSelect`），避免行情页再抄一份视觉造成漂移；`FavoritesBatchBar` 变成薄适配层，**对外 API 与调用点（[FavoritesPageKit.swift:985](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesPageKit.swift#L985)）零改动**；新增 `MarketBatchBar`（`showsDone: true` → 「完成」按钮调 `exitBatchMode()`）。

抽取时必须**逐字保留**的渲染细节（否则自选页会位移）：
- 外层 `VStack(spacing: 0)` → `Divider()` → reason 行（`HStack(spacing: 0)`、11pt `.secondary`、`lineLimit(1)`、`padding(.horizontal, 12)`、`frame(height: 20)`，只取 `compactMap { $0.reason }.first`）
- 主行 `HStack(spacing: 10)`：计数 13pt monospaced `.secondary` `lineLimit(1)` `frame(width: 86, alignment: .leading)` → `Divider().frame(height: 22)` → `ScrollView(.horizontal, showsIndicators: false)` 内 `HStack(spacing: 6)` + `.padding(.trailing, 12)`；外层 `.padding(.leading, 12).frame(height: 56)`
- 按钮：`HStack(spacing: 5)`、icon 12 medium、文字 12 medium `lineLimit(1)`、`enabled ? .blue : Color(.tertiaryLabel)`、`padding(.horizontal, 10)`、`frame(height: 28)`、`Color(.systemGray6)`、`cornerRadius(7)`、`frame(height: 44)`、`contentShape(Rectangle())`、`.buttonStyle(.plain)`、`.disabled(!enabled)`、`.fixedSize()`
- 计数文案「未选择 / 已选 N 只」
- 「完成」槽位放在计数**左侧**，且必须是空 ViewBuilder 槽（`showsDone == false` 时不留占位、不占 spacing）

---

## 已排除的方案（及原因）

**行情页批量列表不用 `List(selection:)` + `editMode`。** 自选页编辑态把 `MarketTableRow` 放进 `List(selection:)` 且照常传 `onOpen` 打开详情（[FavoritesPageKit.swift:992-994](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesPageKit.swift#L992-L994)），而 `MarketTableRow` 在整行挂了 `.onTapGesture`（[190-194](file:///Volumes/home/repositories/Kline2/Kline/Market/MarketTableRow.swift#L190-L194)）—— 二者谁抢到 tap 由 UIKit 触碰管线决定，静态无法判定，且该行为在真机上从未被验证过。手写 `ScrollView + LazyVStack` + 自绘勾选圈的语义是 100% 确定的，同时避免 `List` 行内缩进破坏列对齐。**不改动共用行控件 `MarketTableRow`**，5 处调用点零风险。

---

## 验收清单

**构建**
- `bash scripts/kline_deploy_mac.sh "<描述>"`（前台阻塞，禁止后台）构建通过 + 安装启动到 iPad mini 5 模拟器。

**UI 测试（新增，元素定位一律用 accessibilityIdentifier）**
- 行情页：长按行 → 面板出现「批量编辑」→ 点击 → 进入批量态（勾选圈可见、底部条「完成」可见、**被长按的那只已勾选**）→ 点「全选」→ 计数变「已选 N 只」→ 点「完成」→ 退出批量态、恢复表格。
- 自选页：长按行 → 面板出现「批量编辑」→ 点击 → 进入编辑态且预选该只；工具栏「完成」仍可用（既有路径未回归）。
- 搜索页：长按行 → 面板**不出现**「批量编辑」。
- 回归：`test01` / `test02` / `test93` / `test95` 全绿。
- 新增标识：`market.batchRow`、`market.batchBar.done`、`market.rowMenu.batchEdit`。

**人工复核（用户）**
- 自选页批量条外观与改动前一致（抽取 `BatchActionBar` 的回归点）。
- 行情页四档（A/B/C 表格/C 磁贴/D）都能进入批量编辑；切换一级/二级菜单、切布局、切磁贴态后选择被清空但仍在批量态；切到无标的分类自动退出批量态（不会卡死）。
- 批量动作方向正确：对已自选/已固顶的标的点「加自选/固顶」不应反向取消。

---

## Critical Files

| 文件 | 改动 |
|---|---|
| [FavoritesRowMenu.swift](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesRowMenu.swift) | `FavoritesRowMenuAction` + `.batchEdit`；`MetaRowMenuKit.items/Outcome/perform`；抽出 `BatchBarEntry` / `BatchActionBar`；`FavoritesBatchBar` 改薄适配 |
| [MarketPageKit.swift](file:///Volumes/home/repositories/Kline2/Kline/Market/MarketPageKit.swift) | `MarketPageModel` 批量态状态/方法/订阅；`MarketBatchAction`；`MarketBatchList`；`MarketBatchBar`；`MarketTableBody` 分支 |
| [MarketLayoutCView.swift](file:///Volumes/home/repositories/Kline2/Kline/Market/MarketLayoutCView.swift) | 磁贴态批量分支 |
| [FavoritesPageKit.swift](file:///Volumes/home/repositories/Kline2/Kline/Favorites/FavoritesPageKit.swift) | `enterEditingMode(preselect:)`；`rowMenuItems` / `performRowMenu` 接 `.batchEdit` |
| [SearchPageView.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/SearchPageView.swift) | `performRowMenu` 补 `case .batchEdit: break` |
| [KlineUITests.swift](file:///Volumes/home/repositories/Kline2/KlineUITests/KlineUITests.swift) | 新增批量编辑用例 |

**不动**：`MarketTableRow.swift`（共用行控件，零改动）、`FavoritesManualEditingList`、`FavoritesStore`。

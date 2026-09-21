# 自选操作增强 Spec（固顶 / 移动 / 批量 / 备注 / 预警 + 长按菜单修复）

## Why

自选相关的 7 类操作（添加自选、固顶、移到最前、移到最后、批量编辑、分组、备注）现状残缺：**固顶与备注数据层都没有字段**、`moveInGroup` 写了但**全项目零调用**、批量编辑只有「手动分组拖排序」、预警更是空白。

更关键的是交互问题：用户对**表格形态**的长按菜单不满意 —— 「长按菜单会让表格的那一行变形，好丑」。根因已定位（见下），不是样式问题而是**用了系统 `contextMenu`**：它会走 `UIContextMenuInteraction` 的抬升/快照管线，把行**换宿主重新排版**，而行内是「`GeometryReader` 实测可视宽 + 常量列宽 + `offset(x:)` 横向滚动 + 三层 `clipped()`」的结构，换宿主后提案宽度变化 → 列错位/被裁；同时 `ScrollView` 上挂着 `simultaneousGesture(horizontalDragGesture)`（`minimumDistance: 8`），长按期间的轻微位移会同时改 `hScrollOffset`，进一步「看起来变形」。

用户已确认的口径：
- 表格形态**只要长按菜单**（不加行内星标、不加左滑），但菜单必须**不再让行变形**；卡片形态（自选页 C 档卡片、行情页磁贴）已有的操作要保留，**卡片形态缺的操作一并补齐**。
- 固顶：**分组内**固顶（每组各自一份顺序），且优先于排序规则。
- 备注：**全局**（一只票一条），**仅在弹窗里查看与编辑**（行内不展示，行高列宽不变）。
- 批量：移出/取消自选、移到分组、固顶/取消固顶、设置/清除备注、**设置/取消预警**。
- 预警：**复用现有条件单**，**不在 App 内弹窗**，而是**专门一个页面查看与管理预警记录**。

## 现状对照（侦察结论，带行号）

| 操作 | 表格形态 | 卡片形态 | 数据层 |
|---|---|---|---|
| 添加自选 | 自选页表格内**无入口**（仅空态引导 `FavoritesPageKit.swift:380`）；行情页表格靠行长按菜单「加自选」（`MarketPageKit.swift:683-685`） | 行情页磁贴右上 44×44 星标（`MarketLayoutCView.swift:154-163`） | 已实现 `toggleFavorite`（`FavoritesStore.swift:327`）、`addToGroup`（:309） |
| 固顶 | 无 | 无 | **无字段、无方法** |
| 移到最前 / 最后 | 无（仅编辑态拖拽 `FavoritesPageKit.swift:544-548`） | 无 | `moveInGroup`（`FavoritesStore.swift:343`）**零调用**；实际落盘走 `saveManualOrder`（`FavoritesPageKit.swift:158-163`，靠 `renameGroup` 同名技巧） |
| 批量编辑 | 仅「手动分组」可拖排序（`FavoritesPageKit.swift:394-401`、`509-552`）；无多选、无批量动作 | 复用同一编辑列表（`FavoritesLayoutCView.swift:105-107`） | 部分（`saveManualOrder`） |
| 分组 | 已实现（`FavoritesPageKit.swift:486-503` 菜单 + `AddToGroupSheet` + `FavManageSheet`） | 同左（共用菜单与 sheets） | 已实现（`addGroup`/`removeGroup`/`renameGroup`/`moveGroup`/`toggleHidden`） |
| 备注 | 无 | 无 | **无字段** |
| 预警 | 无（条件单页有 monitoring/triggered 分段，但**没有「仅提醒」形态**：`SimCondDirective`（`SimConditionModels.swift:125-134`）无 alertOnly，引擎触发分支无条件 `submit(draft)`（`SimCondEngine.swift:145-155`）） | 无 | 部分（`SimCondOrder.triggeredAt`（:279）只记单次类型；无多次触发历史） |

其他必须遵守的既有约束：
- 排序规则**按页面**存（`MarketConfigStore.swift:91,166-167`），没有分组级排序 → 有排序规则时手动顺序被完全覆盖（`FavoritesPageKit.swift:101-107`）。
- `saveManualOrder` 用 `items()` 的 `compactMap` 结果整组覆写（`FavoritesStore.swift:358-360` 会丢掉不在 `metaList` 的 id）→ **「移到最前/最后」不能复用它**，需要只重排不过滤的专用 API。
- 「全部」是虚拟分组（`FavoritesStore.swift:88-101`，不在 `groups` 里）→ 重排/移除对其 no-op（:310/:320/:344）。
- `FavoritesGroup` **无自定义 `init(from:)`**：新增非可选字段会让旧档 decode 失败 → 整档丢（`FavoritesStore.swift:199-202`），故新字段必须可选 + `decodeIfPresent`，并提升 `currentSchema`（:105）挂幂等迁移（同 `migrateFormulaGroupsIfNeeded` 范式 :134）。

## What Changes

- **长按菜单改为自绘操作面板**（表格与卡片两形态统一）：表格行/卡片不再使用系统 `contextMenu`，改为 `onLongPressGesture`（0.5s）+ 容器层 overlay 面板（25% 遮罩 + 居中卡片 + `.transition(.opacity)` + `zIndex(1000)`），长按期间行**零缩放、零位移、零重排**；长按期间屏蔽 `horizontalDragGesture`（复用行情页 `edgeAdjust ? nil :` 范式 `MarketPageKit.swift:626`）。行情页表格行长按同样改用该面板（加自选/取消自选/加入分组/备注/预警）。
- **分组内固顶**：`FavoritesGroup` 新增可选字段 `pinnedMetaIDs: [Int]?`（顺序即固顶顺序，可多只）；`sortedRows` 在排序规则排序**之后**做一次稳定分区（固顶优先），因此**固顶恒有效，不受排序规则影响**。
- **移到最前 / 移到最后**：新增 `FavoritesStore.moveToFirst/moveToLast(groupID:metaID:)`（只重排 `manualMetaIDs`、不做 `compactMap` 过滤）；仅手动分组且当前**没有**页面级排序规则时可用，否则菜单项置灰并显示原因。
- **备注（全局）**：`FavoritesRoot` 新增 `notes: [String: String]?`（key = metaID 字符串，Swift 字典 JSON key 必须 String）；仅弹窗查看/编辑（空备注显示「添加备注」，已有备注直接展示全文 + 编辑）。
- **批量编辑**：编辑态由 `List + onMove`（仅排序）升级为 `List(selection:)` 多选 + 底部批量工具栏：移出当前分组/取消自选、移到分组、固顶/取消固顶、设置/清除备注、设置/取消预警、全选/取消全选；拖拽排序保留。
- **预警（复用条件单）**：给 `SimCondDirective` 新增可选 `alertOnly: Bool`（默认 false，解码兜底）—— 为 true 时引擎触发**不下单**、只记 `triggeredAt` / `lastTriggerPrice` / `lastMessage` 并**追加一条预警记录**；数量与持仓校验对 alertOnly 跳过。单只「设置预警」打开既有条件单编辑器并预置 `alertOnly = true`；批量「设置预警」用轻量弹窗对所选标的套用同一规则（价格上穿/下穿 + 数值）。
- **预警记录页**（新页面 `AlertRecordView`）：列出每次触发记录（时间 / 标的 / 触发价 / 文案），支持单条删除、清空全部、点记录打开该标的 K 线详情；入口放在**条件单页导航栏**（`SimCondListView`）。预警**不做** App 内弹窗。
- **卡片形态补齐**：自选页 C 档卡片、行情页磁贴的「更多」菜单与长按统一走新面板，补齐固顶/移前移后/备注/预警（行情页贴图的星标保留）。
- **BREAKING**：无。`favorites.json` schema 2→3、`sim.json` schema 2→3，均为**新增可选字段 + 幂等迁移**，旧档不丢数据。

## Impact

- Affected specs: `redesign-favorites-market-layouts`（其 A/B/C/D 四档的表格主体、行菜单、编辑态被本 spec 改造；其中「左滑菜单」在实现里从未存在，本 spec 明确以长按面板为唯一菜单入口）
- Affected code:
  - 修改 [FavoritesStore.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesStore.swift)（`pinnedMetaIDs`、`notes`、`togglePin`、`moveToFirst/moveToLast`、`setNote`、schema 3 迁移）
  - 修改 [FavoritesPageKit.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesPageKit.swift)（`sortedRows` 固顶优先、行菜单改面板、编辑态多选 + 批量条）
  - 新增 `Kline/Favorites/FavoritesRowMenu.swift`（长按操作面板 + 备注弹窗 + 批量预警弹窗）
  - 修改 [FavoritesLayoutAView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesLayoutAView.swift) / [BView](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesLayoutBView.swift) / [CView](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesLayoutCView.swift) / [DView](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesLayoutDView.swift)（接线同一面板与批量条）
  - 修改 [MarketPageKit.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketPageKit.swift)（行情页表格行长按改同一面板 + 备注/预警菜单项）
  - 修改 [MarketLayoutCView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketLayoutCView.swift)（磁贴「更多」与长按走同一面板）
  - 修改 [SimConditionModels.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Trading/SimConditionModels.swift)（`alertOnly` + `SimAlertRecord`）
  - 修改 [SimCondEngine.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Trading/SimCondEngine.swift)（alertOnly 触发分支：不下单、记记录与消息）
  - 修改 [SimStore.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Trading/SimStore.swift)（`alertRecords` 追加/删除/清空 + schema 3）
  - 修改 [SimCondEditorView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Simulation/SimCondEditorView.swift)（「仅提醒（不下单）」开关）
  - 修改 [SimCondListView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Simulation/SimCondListView.swift)（导航栏「预警记录」入口）
  - 新增 `Kline/Simulation/AlertRecordView.swift`（预警记录页）
  - 新增 `figma/favorites-ops-proposals.html`（3 屏：长按操作面板 / 批量编辑条 / 预警记录页 + 备注弹窗）
  - 工程文件无需改动：`Kline.xcodeproj` 使用 `PBXFileSystemSynchronizedRootGroup`

## 交付分期

- **阶段一（设计稿）**：Task 1–3。figma 原型（面板 / 批量条 / 预警记录页）与截图，用户先看稿。
- **阶段二（数据层）**：Task 4–6。`favorites.json` 固顶/备注/移前移后 + schema 3 迁移；`sim.json` alertOnly + 预警记录 + schema 3。独立可编译，无 UI 变化。
- **阶段三（长按面板修复 + 菜单补齐）**：Task 7–9。表格与卡片统一自绘面板、消灭变形、补齐菜单项。
- **阶段四（批量编辑）**：Task 10–11。
- **阶段五（预警闭环）**：Task 12–13。条件单编辑器开关、预警记录页与入口。
- **阶段六（验收）**：Task 14–15。

***

## 交互规范：长按操作面板（唯一菜单入口）

- **触发**：行长按 0.5s（`onLongPressGesture(minimumDuration: 0.5)`）；卡片同左键（原系统 `contextMenu` 移除）。卡片右上「更多」按钮点击也打开同一面板。
- **不变形保证（本 spec 的核心验收点）**：
  - 长按期间行/卡片**不做**任何 `scaleEffect`、`offset`、描边或背景变化；仅面板出现；
  - 长按期间 `horizontalDragGesture` 置 nil（避免位移改 `hScrollOffset`）；
  - 面板消失后，行的 frame（高度 / 列宽 / 横向 offset）与长按前**逐值相同**。
- **面板样式**（对齐既有弹窗规范）：容器层 overlay + `Color.black.opacity(0.25)` 遮罩（点击关闭）+ 居中卡片（`Color(.systemBackground)`、`cornerRadius(12)`、`shadow(black 20%, radius 12, y 4)`、宽 260）+ 每项行高 44（`padding(.horizontal,12)`、`Divider`）+ 底部「取消」（15 semibold 蓝、`padding(.vertical,11)`）+ `.transition(.opacity)` + `zIndex(1000)`；标题行为「标的名称 + 代码」（13pt `.secondary`）。
- **面板项顺序**（按当前分组类型动态裁剪，见下表）：
  1. 固顶 / 取消固顶（`pin` 图标）
  2. 移到最前（`arrow.up.to.line`）
  3. 移到最后（`arrow.down.to.line`）
  4. 加入其它分组（`folder.badge.plus`）
  5. 备注…（`text.bubble`；有备注时显示「备注…」并在副标题显示首行摘要）
  6. 设置预警 / 取消预警（`bell.badge`）
  7. 取消自选（`star.slash`，`role: .destructive`）
- **行情页表格/磁贴面板**：加自选 / 取消自选、加入其它分组、备注…、设置预警 / 取消预警（无固顶与移前移后，因为行情页没有分组视图）。

## 操作可用性矩阵（按分组类型）

| 操作 | 手动分组 | 公式分组 | 「全部」虚拟组 | 行情页 |
|---|---|---|---|---|
| 固顶 / 取消固顶 | ✅ | ✅（仅影响显示顺序） | ❌（无实体，隐藏该项） | ❌ |
| 移到最前 / 最后 | ✅（且当前无排序规则时可用） | ❌（顺序由计算得，置灰 + 一行说明） | ❌ | ❌ |
| 加入其它分组 / 移动分组 | ✅ | ✅（只加不排） | ✅ | ✅ |
| 备注（全局） | ✅ | ✅ | ✅ | ✅ |
| 设置 / 取消预警 | ✅ | ✅ | ✅ | ✅ |
| 取消自选 / 移出分组 | ✅ | ❌（显示层无意义，置灰） | ✅（= 取消自选） | ✅（取消自选） |
| 批量多选 | ✅ | ✅（仅固顶/备注/预警可用） | ✅（仅取消自选/备注/预警可用） | ❌（行情页不做批量） |

## 批量编辑规范

- 编辑态 = `List(selection:)` 多选（保留 `onMove` 拖拽排序）；手动分组、公式分组、「全部」组**都可进编辑态**（上一版公式组切编辑无效的问题一并修掉）。
- 底部批量条（固定高度，不随选择数抖动）：`已选 N 只` + 横向可滚动的动作按钮（44pt 命中区）：移出/取消自选、移到分组、固顶、取消固顶、设置备注、清除备注、设置预警、取消预警、全选、取消全选；无选择时按钮置灰。
- 批量动作语义：对所选标的逐个套用同一参数（批量移组 = 加入目标分组并从当前分组移除；批量预警 = 为每只创建一条 `alertOnly = true` 的条件单，规则相同）。
- 位移语义明确：批量固顶按**当前选中顺序**追加到固顶列表尾部。

## 数据模型变更（含迁移口径）

1. `FavoritesGroup` 新增 `pinnedMetaIDs: [Int]?`（可选；顺序 = 固顶顺序）。
2. `FavoritesRoot` 新增 `notes: [String: String]?`（key = `String(metaID)`；**不要用 `[Int: String]`**，Swift 对非 String key 的字典会编码成交替数组，破坏可读性与既有工具链假设）。
3. `FavoritesRoot.currentSchema` 2 → 3；新增幂等迁移 `migrateItemOpsIfNeeded()`（初始化读档后调用，写档前再兜底回写，范式照 `migrateFormulaGroupsIfNeeded`）。
4. `SimCondDirective` 新增 `alertOnly: Bool?`（`CodingKeys` + `init(from:)` 兜底为 `false`）。
5. 新增 `SimAlertRecord: Codable, Identifiable`（`id` / `condID` / `metaID` / `code` / `name` / `price: Double?` / `message: String` / `occurredAt: Date`），`SimRoot` 新增 `alertRecords: [SimAlertRecord]?`，`SimRoot.schemaVersion` 2 → 3（既有逐项 `try?` 兜底范式已保证旧档不炸）。
6. 预警触发：`alertOnly == true` 时**不** `submit(draft)`、**不**校验数量与持仓，写 `triggeredAt`/`lastTriggerPrice`/`lastMessage` 并 append 一条 `SimAlertRecord`（多触发类型同样每次 append）。
7. 记录上限：`alertRecords` 保留最近 200 条（超出丢最旧），避免长期运行无限增长。

## ADDED Requirements

### Requirement: 长按操作面板（表格与卡片统一，行长按不变形）

系统 SHALL 在自选页（A/B/C/D 四档）与行情页（表格行与磁贴）以**自绘长按操作面板**替代系统 `contextMenu`，面板项按「操作可用性矩阵」动态裁剪，且 SHALL 保证长按期间与面板关闭后行/卡片的布局逐值不变。

#### Scenario: 长按不再让表格行变形

- **WHEN** 在自选页表格任一档（A/B/D）长按某一行 0.5s 并关闭面板
- **THEN** 该行的高度、各列宽度、横向滚动位置与长按前完全一致，无缩放 / 位移 / 列错位 / 被裁切

#### Scenario: 长按期间横向滚动不联动

- **WHEN** 长按并在手指轻微移动（< 8pt）后松手
- **THEN** 表格横向偏移不变，仅出现/关闭操作面板

#### Scenario: 卡片形态菜单一致

- **WHEN** 在自选页 C 档卡片或行情页磁贴长按（或点右上「更多」）
- **THEN** 呈现与表格同一套面板与同一套菜单项（行情页额外含「加自选 / 取消自选」；贴纸星标保留）

### Requirement: 分组内固顶

系统 SHALL 支持在分组内固顶标的（可多只，顺序即固顶顺序），固顶项在该分组列表里**恒排最前**，且**优先于页面级排序规则**；固顶状态 SHALL 持久化（`favorites.json` schema 3）。

#### Scenario: 固顶优先于排序规则

- **WHEN** 某手动分组固顶 2 只标的，并把自选页排序规则设为「涨跌幅降序」
- **THEN** 这 2 只标的仍排在最前（按固顶顺序），其余标的按涨跌幅降序排列

#### Scenario: 取消固顶

- **WHEN** 对已固顶标的执行「取消固顶」
- **THEN** 该项立即回到常规排序位置，持久化后重启仍保持

#### Scenario: 公式分组的固顶

- **WHEN** 在公式分组内固顶一只标的
- **THEN** 该标的排在该公式分组列表最前，其余仍按公式计算结果顺序；分组重新刷新选股后固顶仍保持

### Requirement: 移到最前 / 移到最后

系统 SHALL 提供「移到最前 / 移到最后」，仅调整该手动分组的手动顺序（不改动成员集合、不删除任何成员）；当前存在页面级排序规则或非手动分组时 SHALL 不可用并给出原因说明。

#### Scenario: 手动顺序模式下生效

- **WHEN** 自选页未设置排序规则，在手动分组里把某行「移到最后」
- **THEN** 该行移动到该分组末尾并落盘，重启后顺序保持

#### Scenario: 有排序规则时置灰

- **WHEN** 自选页已设置排序规则（如按涨跌幅）
- **THEN** 面板中「移到最前 / 移到最后」置灰，并显示一行说明「当前按 XX 排序，暂不可手动定位」

#### Scenario: 不丢成员

- **WHEN** 分组内含有不在当前数据库 `metaList` 里的历史标的 id
- **THEN** 执行移动后这些 id 仍保留在分组中（不得被整组覆写丢弃）

### Requirement: 备注（全局，弹窗查看与编辑）

系统 SHALL 支持为标的维护一条**全局备注**（所有分组与「全部」共享），并在长按面板的「备注…」弹窗中查看与编辑；表格与卡片行内 SHALL 不展示备注内容（保持行高与列宽不变）。

#### Scenario: 编辑与查看

- **WHEN** 对某标的点「备注…」输入文字并保存
- **THEN** 再次打开该弹窗能看到全文并可修改；在其它分组、以及「全部」里打开同一标的的备注弹窗内容一致

#### Scenario: 清空备注

- **WHEN** 在弹窗内清空文字并保存
- **THEN** 备注被移除（落盘后不再存在该 key），面板项恢复为「备注…」无摘要状态

#### Scenario: 行内不变

- **WHEN** 任一行设置了备注
- **THEN** 表格行高、列宽与卡片高度均不变（备注不在行内渲染）

### Requirement: 批量编辑

系统 SHALL 提供多选批量编辑：手动分组、公式分组、「全部」虚拟组均可进入编辑态；底部批量条 SHALL 提供移出/取消自选、移到分组、固顶/取消固顶、设置/清除备注、设置/取消预警，并保留拖拽排序（仅手动分组）。

#### Scenario: 批量动作生效

- **WHEN** 在多选状态下点「固顶」
- **THEN** 所选标的按当前选择顺序追加到该分组固顶列表尾部，列表即时重排

#### Scenario: 公式分组下的批量可用项

- **WHEN** 在公式分组下进入编辑态并多选
- **THEN** 固顶/备注/预警可用，「移出/取消自选」「移到分组」「拖拽排序」不可用（置灰 + 原因）

#### Scenario: 「全部」组下的批量

- **WHEN** 在「全部」组下多选并点「取消自选」
- **THEN** 所选标的从所有手动分组移除并取消自选；固顶/移动类动作不出现

### Requirement: 预警（复用条件单「仅提醒」）

系统 SHALL 支持把条件单标记为**仅提醒（不下单）**（`alertOnly`），其触发 SHALL **不下单、不校验数量与持仓**，只记录触发时间 / 触发价 / 文案并追加一条预警记录；系统 SHALL **不在 App 内弹窗**提示预警。

#### Scenario: 仅提醒条件单触发不下单

- **WHEN** 一条 `alertOnly = true` 的条件单满足触发条件（含无持仓、数量为 0 的标的）
- **THEN** 不产生委托/成交，`triggeredAt`、`lastTriggerPrice`、`lastMessage` 被写入，并新增一条预警记录

#### Scenario: 普通条件单行为不变

- **WHEN** 一条 `alertOnly = false`（默认）的条件单触发
- **THEN** 行为与改造前完全一致（照旧下单、照旧校验数量与持仓）

#### Scenario: 自选页设置与取消预警

- **WHEN** 在长按面板点「设置预警」并填写规则
- **THEN** 打开条件单编辑器且预置「仅提醒」；保存后该标的出现预警状态，菜单项变为「取消预警」；点「取消预警」删除对应的提醒型条件单

#### Scenario: 批量设置预警

- **WHEN** 多选 N 只标的并执行「设置预警」（选择上穿/下穿与数值）
- **THEN** 为这 N 只各创建一条同规则的 `alertOnly` 条件单

### Requirement: 预警记录页

系统 SHALL 提供独立的**预警记录页**（`AlertRecordView`）：按时间倒序列出每次预警触发记录（时间 / 标的名称与代码 / 触发价 / 文案），支持单条删除、清空全部、点记录打开该标的 K 线详情；入口位于条件单页导航栏。

#### Scenario: 查看与管理记录

- **WHEN** 有若干条预警触发后打开预警记录页
- **THEN** 按时间倒序看到记录；删除单条后仅该条消失；点「清空全部」后列表为空（均已落盘）

#### Scenario: 记录上限

- **WHEN** 记录超过 200 条
- **THEN** 仅保留最近 200 条（丢弃最旧），页面不出现卡顿

## MODIFIED Requirements

### Requirement: 表格/卡片行操作入口

自选页与行情页的行/卡片操作入口 SHALL **统一为长按操作面板**（卡片另保留右上「更多」按钮打开同一面板），**不再使用系统 `contextMenu`**（会抬升预览并重排版行，导致列错位与横向偏移串动）。`redesign-favorites-market-layouts` 中「卡片式左滑菜单」的表述随之作废：实现层面从未存在左滑菜单，本 spec 明确以长按面板为唯一入口。

#### Scenario: 既有能力不丢失

- **WHEN** 使用改造后的面板
- **THEN** 原有的「取消自选 / 加入其它分组 / 移动到分组」三项能力全部保留（位置见面板项顺序），行情页原有的「加自选 / 取消自选 / 加入指定分组」同样保留

### Requirement: 自选页编辑态

自选页编辑态 SHALL 由「仅手动分组可拖排序」升级为「三类分组均可多选 + 批量动作」，且 SHALL 修掉「公式分组切编辑态回退只读列表」的旧行为。

#### Scenario: 编辑态与横向滚动互斥

- **WHEN** 进入编辑态
- **THEN** 表格横向滚动手势被禁用（与行情页 `edgeAdjust` 的互斥写法一致），退出编辑态后恢复

## REMOVED Requirements

无。
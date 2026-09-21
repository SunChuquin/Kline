# Checklist

> 核验方式：静态核验（文件 + 行号）为主；标 ⏳ 的为观感/手感/时序项，需真机确认。核验命令统一用项目既定闭环：`python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<提交描述>"`（退出码 0 / 6 / 7 视为构建通过）。
>
> 本轮核验结论：静态项全部通过；⏳ 项共 6 条待真机确认（与既有惯例一致，保留未勾选）。期间修复 1 处编译错误（见「工程与交付」）。

## figma 原型（阶段一）

- [x] `figma/favorites-ops-proposals.html` 为自包含单文件（712 行），无外链依赖（全文仅 `xmlns` 命名空间与 data-URI favicon）
- [x] 设备框与既有画廊一致（`.screen-wrap` 573×430 + `.screen` 1024×768 `scale(.55957)`，`.bezel` 深色外壳）
- [x] 3 屏齐全且可切换：`opsRowMenu`（长按前后同一行对照 + 旧/新实现对照小图）/ `opsBatch`（多选 + 批量条 + 公式分组能力说明）/ `opsAlert`（记录页 + 备注弹窗两态）
- [x] 每屏编号标注与右侧标注栏条目一一对应（7/6/7 条）；`MARKS` 与 `SCREENS` 登记齐备
- [x] 页头写明本次解决的 6 件事（长按变形修复 / 固顶 / 移前移后 / 批量编辑 / 备注 / 预警）
- [x] 支持 `#shot=<屏 id>` 单屏定位，截图中无 hero / 切换器 / 标注栏干扰
- [x] 逐屏截图输出到 `figma/_shots/`（`ops_rowmenu.png` 93.5KB / `ops_batch.png` 74.2KB / `ops_alert.png` 49.8KB，均 700×560，与既有截图同尺寸），无溢出 / 截断 / 重叠 —— 屏 1 左右两块表格由**同一串 HTML**渲染（同一 `colgroup` 与 CSS 类），行高列宽逐值一致

## 长按操作面板与「行变形」修复（本次核心）

- [x] 自选页表格行、自选页 C 档卡片、行情页表格行、行情页磁贴**四处**的真实 `.contextMenu` 全部移除 —— 全项目 Grep `.contextMenu` 只命中 5 个文件的**注释**（`FavoritesRowMenu.swift:6-7`、`FavoritesPageKit.swift:10,230,807`、`FavoritesLayoutCView.swift:159`、`MarketPageKit.swift:392,736`、`MarketLayoutCView.swift:180`），无任何真实调用；旧函数 `favoritesRowMenuContent` / `marketRowMenuContent` 已删除
- [x] 长按统一用 `onLongPressGesture(minimumDuration: 0.5)`（`FavoritesPageKit.swift:809,920`、`FavoritesLayoutCView.swift:160`、行情页两处同理）；卡片「更多」按钮改为打开**同一**面板（`FavoritesLayoutCView.swift:245`）
- [x] 长按期间行/卡片**无** `scaleEffect` / `offset` / 描边 / 背景变化 —— 面板是容器层 overlay（`FavoritesOverlayCard`：25% 遮罩 + `.transition(.opacity)` + `zIndex(1000)`），行自身样式零改动
- [x] 面板打开期间 `horizontalDragGesture` 被禁用 —— `FavoritesPageKit.swift:785`、行情页 `MarketPageKit.swift:691-693`（写法对齐 `edgeAdjust ? nil :`）
- [x] 面板样式与既有弹窗规范逐项一致：宽 260、`systemBackground`、`cornerRadius(12)`、`shadow(black 20%, radius 12, y 4)`、项行高 44 + `Divider`、底部「取消」15 semibold 蓝、项多时 `ScrollView.frame(maxHeight: 320)`
- [x] 面板项顺序与 spec 一致（固顶 / 移到最前 / 移到最后 / 加入其它分组 / 备注… / 设置·取消预警 / 取消自选），并按上下文裁剪（矩阵见 Task 9 报告与 `FavoritesPageKit.swift` 的 `rowMenuItems`）
- [x] 每个面板项命中区 ≥ 44×44pt；不可用项置灰 + 一行 11pt `.secondary` 原因说明
- [ ] ⏳ 真机观感：长按 0.5s 出现面板、松手后行高度 / 列宽 / 横向偏移与长按前**目视完全一致**（重点回归项）
- [ ] ⏳ 真机观感：面板出现与关闭不闪、不残留高亮；点击行本体仍能打开 K 线详情（长按与点击不冲突）

## 固顶（分组内）

- [x] `FavoritesGroup.pinnedMetaIDs: [Int]?` 为**可选**字段（`FavoritesStore.swift:46`），顺序即固顶顺序，可多只
- [x] `isPinned` / `pinnedIDs` / `togglePin` 齐备（`:398 / :405 / :416`）；写入带同值守卫（`:427`）并落盘
- [x] `sortedRows` 在排序规则排序**之后**做稳定分区（`FavoritesPageKit.swift:107-126`）→ 固顶**优先于排序规则**
- [x] 公式分组内固顶可用（固顶集合在分组上，不依赖 `cachedMatches`）；迁移只对固顶列表去重、**不按成员过滤**（`FavoritesStore.swift:187-194`，避免公式分组固顶被误清）
- [x] 「全部」虚拟组不出现固顶项（无实体）
- [ ] ⏳ 真机：设置排序规则（如涨跌幅降序）后固顶项仍排最前；杀 App 重启后固顶与顺序保持

## 移到最前 / 移到最后

- [x] `moveToFirst` / `moveToLast`（`FavoritesStore.swift:435 / :440` → `reorderMember`）只在 `manualMetaIDs` 上 `remove + insert`，**不**用 `resolveMetaItems` 的 `compactMap` 结果整组覆写 → 历史无效 id 不丢
- [x] 仅手动分组可用；公式分组置灰（原因「顺序由公式计算得到」）；「全部」组不出现该项
- [x] 存在页面级排序规则时置灰并说明原因（「当前按 X 降序排序，暂不可手动定位」）；已在最前/最后时也置灰（避免无反应点击）

## 备注（全局，弹窗查看与编辑）

- [x] `FavoritesRoot.notes: [String: String]?`（`FavoritesStore.swift:76`）+ `@Published notes`（`:93`），key 为 `String(metaID)`（`noteKey` `:472`），**未使用 `[Int: String]`**
- [x] `note(for:)` / `setNote(metaID:text:)` 齐备；**空串即 `removeValue`**（`:487`）
- [x] 备注为全局：无分组维度，同一标的在任何分组/行情页打开内容一致
- [x] 备注弹窗：已有备注展示全文并可编辑；空备注有占位；清空 / 取消 / 保存三态；`ignoresSafeArea(.keyboard)`
- [x] 表格行高、列宽、卡片高度在设置备注前后不变（备注不在行内渲染；面板项仅显示首行摘要）
- [ ] ⏳ 真机：备注弹窗键盘弹出时不挤压面板；再次打开内容一致

## 批量编辑

- [x] 编辑态改 `List(selection:)`（SelectionValue = `metaID`，`FavoritesPageKit.swift:886` + `.tag`），`onMove` 拖拽排序保留（仅手动实体分组提供拖动手柄 `:871,887`）
- [x] 手动分组 / 公式分组 /「全部」虚拟组**三类都可进入编辑态**（去掉旧的 `kind == .manual` gate）
- [x] 批量条 `FavoritesBatchBar`（`FavoritesRowMenu.swift:482`）含 10 项动作（移出、移到分组、固顶、取消固顶、设置备注、清除备注、设置预警、取消预警、全选、取消全选）
- [x] 批量条高度固定（56 + 1pt 分隔线，计数固定宽 86 不抖动）；按钮 gray6 胶囊、44pt 命中区、超宽横向可滚
- [x] 批量语义正确：移组 = `addToGroup` + 当前组 `removeFromGroup`；固顶按**显示顺序**逐个 `togglePin`（追加到固顶尾部）；「全部」组取消自选 = `toggleFavorite`
- [x] 可用性矩阵生效：公式组下「移出」「移到分组」置灰 + 条上一行说明；「全部」组只保留取消自选 / 备注 / 预警 / 全选系
- [x] 编辑态与横向滚动互斥（编辑态用 `List`，不挂横向手势）
- [x] 四档接线一致：共用 `FavoritesEditToggleButton`（`FavoritesPageKit.swift:543`）接进 A（`:629`）/ B（`FavoritesLayoutBView.swift:58`）/ C（`FavoritesLayoutCView.swift:37`）/ D（`FavoritesLayoutDView.swift:103`）；切分组与切档清空多选
- [ ] ⏳ 真机：多选勾选手感、批量动作执行后列表刷新与落盘（重启后保持）

## 预警（复用条件单「仅提醒」）

- [x] `SimCondDirective.alertOnly: Bool?` 可选 + `CodingKeys` + `init(from:)` 兜底；`isAlertOnly` 计算属性
- [x] 引擎对提醒单**不** `submit`、不产生委托/成交 —— `SimCondEngine.swift:144` 早退到 `fireAlertOnly(:209)`；校验放行（`validateCreate` 数量 / 可卖持仓 / `batchTooSmall`、`evaluate` 数量缺省）全部由 `isAlertOnly` 门控
- [x] 触发写入 `triggeredAt` / `lastTriggerPrice` / `lastMessage`（文案形如「预警：现价 1512.30 上穿 1500.00」）并 append 记录；多触发类型每次触发都 append
- [x] 引擎**不做**任何 App 内弹窗/横幅
- [x] `SimAlertRecord` 字段齐备（在 `SimConditionModels.swift:341`）；`SimRoot.alertRecords` 可选 + `currentSchema` 2→3
- [x] 记录上限 200 条（`SimStore.alertRecordLimit`）超出丢最旧；`appendAlertRecord` / `deleteAlertRecord` / `clearAlertRecords` / `alertRecordsSorted` / `alertRecordCount` 齐备
- [x] 单只「设置预警」走轻量预警弹窗（`FavoritesBatchAlertSheet`，`alertOnly = true`）——**有意偏差**：不打开条件单编辑器（避免创建到会下单的普通单），见 Task 12.2
- [x] 批量设置预警：为所选 N 只各创建一条同规则提醒单；批量取消预警删除对应提醒型条件单
- [x] 条件单编辑器新增「仅提醒（不下单）」开关（`SimCondEditorView.swift:417-441`，默认关、编辑既有提醒单预填为开）；开启时**置灰但保留**下单相关字段（不隐藏 → 布局不跳动）；普通单写 `alertOnly = nil` → JSON 与改造前逐字一致（`:899`）
- [ ] ⏳ 真机：开启「仅提醒」后保存、在条件单页「立即检查」触发，确认**没有**新委托/成交且记录页出现记录

## 预警记录页

- [x] 新增 `Kline/Simulation/AlertRecordView.swift`（201 行），数据源 `store.alertRecordsSorted`（`:99`，不再二次排序）
- [x] 行内容：时间（`MM-dd HH:mm`，等宽 76）/ 「名称 代码」/ 触发价（按来源条件单方向着色）/ 一行文案；行高固定 56；空态 `bell.slash` + 两行说明
- [x] 单条删除按钮 44×44 → `deleteAlertRecord`；「清空全部」`confirmationDialog`（destructive，无记录时置灰）→ `clearAlertRecords()`（`:41-43`）
- [x] 点记录打开该标的 K 线详情 —— `DetailRouter.shared.open(meta, in: [meta])`（`:199`），`metaList` 反查不到则不响应
- [x] 入口在条件单页导航栏（`SimCondListView.swift:173`，`bell.badge`，44×44，走 `fullScreenCover` 的 `case .alerts`）；条件单卡片带「提醒」标记（`:284-286`）
- [x] 页内无任何自动弹窗 / 横幅
- [ ] ⏳ 真机：记录页时间 / 触发价显示正确；删除与清空后重启仍生效

## 数据迁移与兼容

- [x] `favorites.json`：`currentSchema` 2 → 3（`FavoritesStore.swift:118`）+ 幂等 `migrateItemOpsIfNeeded()`（`:187`，读档后 `:129` 与写档前 `:248` 各调用一次，写出的 `schemaVersion` 恒为 3）；新字段全为可选（可选属性由 synthesized Codable 自动走 `decodeIfPresent`）
- [x] `sim.json`：`currentSchema` 2 → 3（`SimStore.swift:96`）+ `alertRecords` 严格 `try?` 兜底（`:64`）→ 旧档读入后账户 / 持仓 / 委托 / 成交 / 条件单全部保留（schema 号随下次落盘升级）
- [x] 迁移只做「补默认值 / 重写 schema 号 / 固顶去重」，不改既有字段语义、不重排或过滤成员
- [ ] ⏳ 真机：用改造前留下的 `favorites.json` / `sim.json` 首次启动，确认分组、成员顺序、公式分组引用、模拟账户与条件单全部保留

## 工程与交付

- [x] 新增文件全部位于 `Kline/` 目录树内，无需手工改 `project.pbxproj` —— 本功能 4 次提交的文件清单中均无 `project.pbxproj`
- [x] **未新增数据源**：只扩展既有 `favorites.json` / `sim.json` 字段与 API；`market_columns.json` 与 `Kline/Data/` 无改动
- [x] 未改动 A/B/C/D 档位定义与个人中心布局设置（`PageLayoutStore.swift` 无改动）
- [x] 各阶段闭环命令返回 0 / 6 / 7 —— 数据层 run=35569544624（0，v1.0.2 (351)）；阶段三首次 run=35572722753 **失败**（`FavoritesRowMenu.swift:421` 的 `dialogButton` 缺 `bold` 默认值）→ 修复后 run=35572879428（0，v1.0.2 (353)）；预警闭环 run=35574303002（0，v1.0.2 (354)）
- [x] `git status` 无遗留未提交改动（4 个提交：3b8b4e2 / d34bcd4 / e959614 / 1fe0e28）
- [x] 既有冒烟用例不受影响：`KlineUITests.swift` **未改动**（`favorites.title` / `market.rowCard` / `home.page` 判定均与本次改造无冲突——行点击与长按是不同手势，`market.rowCard` 标识与行结构未变）
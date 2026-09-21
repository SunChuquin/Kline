# Checklist

> 核验方式：静态核验（文件 + 行号）为主；标 ⏳ 的为观感/手感/时序项，需真机确认。核验命令统一用项目既定闭环：`python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<提交描述>"`（退出码 0 / 6 / 7 视为构建通过）。

## figma 原型（阶段一）

- [ ] `figma/favorites-ops-proposals.html` 为自包含单文件，无外链依赖（无 CDN / 远程字体 / 远程图片）
- [ ] 设备框与既有画廊一致（iPad mini 4 横屏 1024×768 等比缩放至 573×430，`.bezel` 深色外壳）
- [ ] 3 屏齐全且可切换：`opsRowMenu`（长按操作面板，含「长按前后同一行对照」与「旧实现列错位」对照小图）/ `opsBatch`（编辑态多选 + 底部批量条）/ `opsAlert`（预警记录页 + 备注弹窗两态）
- [ ] 每屏编号标注与右侧标注栏条目一一对应；`MARKS` 与 `SCREENS` 登记齐备
- [ ] 页头写明本次解决的 6 件事（长按变形修复 / 固顶 / 移前移后 / 批量编辑 / 备注 / 预警）
- [ ] 支持 `#shot=<屏 id>` 单屏定位，截图中无 hero / 切换器 / 标注栏干扰
- [ ] 逐屏截图输出到 `figma/_shots/`（`ops_rowmenu.png` / `ops_batch.png` / `ops_alert.png`，700×560，与既有截图同尺寸），每屏无溢出 / 截断 / 重叠

## 长按操作面板与「行变形」修复（本次核心）

- [ ] 自选页表格行、自选页 C 档卡片、行情页表格行、行情页磁贴**四处**的 `.contextMenu` 全部移除 —— 全项目 Grep `.contextMenu` 在 `Kline/Favorites/`、`Kline/Market/` 零命中
- [ ] 长按统一用 `onLongPressGesture(minimumDuration: 0.5)`；卡片右上「更多」按钮点击打开**同一**面板（同一实现、同一菜单项集合）
- [ ] 长按期间行/卡片**无** `scaleEffect` / `offset` / 描边 / 背景变化（面板是容器层 overlay，不改变行自身样式）
- [ ] 长按期间与面板打开期间 `horizontalDragGesture` 被禁用（写法对齐 `MarketPageKit` 的 `edgeAdjust ? nil :`），表格横向偏移不被轻微位移串动
- [ ] 面板样式与既有弹窗规范逐项一致：25% 黑遮罩（可点关闭）+ 居中卡片宽 260 + `systemBackground` + `cornerRadius(12)` + `shadow(black 20%, radius 12, y 4)` + 行高 44 + 底部「取消」（15 semibold 蓝）+ `.transition(.opacity)` + `zIndex(1000)`
- [ ] 面板项顺序与 spec 一致（固顶 / 移到最前 / 移到最后 / 加入其它分组 / 备注… / 设置预警 / 取消自选），并按分组类型裁剪
- [ ] 每个面板项命中区 ≥ 44×44pt；项数多时面板可滚动（`frame(maxHeight: 320)`）
- [ ] ⏳ 真机观感：长按 0.5s 出现面板、松手后行高度 / 列宽 / 横向偏移与长按前**目视完全一致**（重点回归项）
- [ ] ⏳ 真机观感：面板出现与关闭不闪、不残留高亮；点击行本体仍能打开 K 线详情（长按与点击不冲突）

## 固顶（分组内）

- [ ] `FavoritesGroup.pinnedMetaIDs: [Int]?` 为**可选**字段，顺序即固顶顺序，可多只 —— `FavoritesStore.swift` 对应字段 + `decodeIfPresent` 兜底
- [ ] `togglePin` / `isPinned` / `pinnedIDs` 三个 API 齐备；固顶/取消固顶立即落盘（`saveToDisk`）
- [ ] `sortedRows` 在**页面级排序规则排序之后**做稳定分区，固顶项恒在最前 —— 因此固顶**优先于排序规则**
- [ ] 公式分组内固顶可用，且分组重新刷新选股（`refreshFormulaGroup`）后固顶仍保持（固顶集合存在分组上，不依赖 `cachedMatches` 顺序）
- [ ] 「全部」虚拟组不出现固顶项（无实体，避免 no-op 造成点击无反应）
- [ ] ⏳ 真机：设置排序规则（如涨跌幅降序）后固顶项仍排最前；杀 App 重启后固顶与顺序保持

## 移到最前 / 移到最后

- [ ] 新增 `moveToFirst` / `moveToLast`：**只重排** `manualMetaIDs`，不使用 `resolveMetaItems` 的 `compactMap` 结果整组覆写 —— 分组内不在 `metaList` 的历史 id 仍保留（构造一个含无效 id 的分组做静态推演或真机验证）
- [ ] 仅手动分组可用；公式分组置灰并给原因（「顺序由公式计算得到」）；「全部」组不出现该项
- [ ] 存在页面级排序规则时置灰并说明原因（「当前按 XX 排序，暂不可手动定位」）；清除排序规则后立即可用
- [ ] 菜单项文案随当前状态切换（「移到最前」在已是最前时置灰或隐藏，避免无反应点击）

## 备注（全局，弹窗查看与编辑）

- [ ] `FavoritesRoot.notes: [String: String]?`，key 为 `String(metaID)`（**未使用 `[Int: String]`**，避免 `JSONEncoder` 编成交替数组）
- [ ] `note(for:)` / `setNote(metaID:text:)` 齐备；**空串即删除该 key**（清空备注后落盘文件中不再存在该条目）
- [ ] 备注为全局：同一标的在手动分组 / 公式分组 / 「全部」/ 行情页打开备注弹窗内容一致
- [ ] 备注弹窗：已有备注展示全文并可编辑；空备注显示「添加备注」占位；保存 / 清空 / 取消三态可用；键盘弹出不挤压面板
- [ ] 表格行高、列宽、卡片高度在设置备注前后**完全不变**（备注不在行内渲染）
- [ ] 面板项在有备注时可显示首行摘要；无备注时为「备注…」

## 批量编辑

- [ ] 编辑态由 `List + onMove` 升级为 `List(selection:)` 多选，且**保留**拖拽排序（仅手动分组）
- [ ] 手动分组 / 公式分组 / 「全部」虚拟组**三类都可进入编辑态**（旧行为「公式组切编辑回退只读列表」已修掉）
- [ ] 底部批量条含 10 个动作：移出/取消自选、移到分组、固顶、取消固顶、设置备注、清除备注、设置预警、取消预警、全选、取消全选；无选择时全部置灰
- [ ] 批量条高度固定，不随选择数量 / 文案长度抖动；按钮命中区 ≥44pt，超宽时横向可滚
- [ ] 批量语义正确：批量移组 = 加入目标组并从当前组移除；批量固顶 = 按**当前选择顺序**追加到固顶列表尾部；批量取消自选 = 从所有分组移除并取消自选
- [ ] 按分组类型的可用性矩阵生效：公式组下「移出/取消自选」「移到分组」「拖拽排序」置灰并给原因；「全部」组下只保留取消自选 / 备注 / 预警
- [ ] 编辑态与横向滚动互斥（进入编辑态横向手势被禁用，退出恢复）
- [ ] 四档接线一致：A 工具条「编辑」/ B 侧栏「编辑」/ C 顶栏 / D 紧凑表 进入同一编辑态，选中态与文案一致
- [ ] ⏳ 真机：多选勾选手感、批量动作执行后列表刷新与落盘（重启后保持）

## 预警（复用条件单「仅提醒」）

- [ ] `SimCondDirective.alertOnly: Bool?` 为可选字段（`CodingKeys` + `init(from:)` 兜底 `false`），旧 `sim.json` 可正常读入
- [ ] 引擎对 `isAlertOnly` 的条件单：**不** `submit(draft)`、**不**产生委托/成交、**不**校验数量与可卖持仓（对照普通分支逐项核对，普通条件单行为零变化）
- [ ] 触发时写入 `triggeredAt` / `lastTriggerPrice` / `lastMessage`（文案含「预警」与实际价），并**追加一条 `SimAlertRecord`**
- [ ] 多触发类型（网格 / 批量）每次触发都追加记录（不是只留最近一次）
- [ ] 引擎**不做**任何 App 内弹窗 / 横幅 / 提示（本次明确口径：只在记录页查看）
- [ ] `SimAlertRecord` 字段齐备（`id` / `condID` / `metaID` / `code` / `name` / `price` / `message` / `occurredAt`）；`SimRoot.alertRecords` 可选 + `schemaVersion` 2 → 3
- [ ] 记录上限 200 条生效（超出丢最旧），写入沿用「先比较再赋值」惯例
- [ ] 自选页长按面板「设置预警」打开既有条件单编辑器并预置「仅提醒」开启、带入当前标的（未复制第二套表单）
- [ ] 批量设置预警：为所选 N 只各创建一条同规则 `alertOnly` 条件单；批量取消预警删除对应的提醒型条件单
- [ ] 条件单编辑器新增「仅提醒（不下单）」开关（默认关）；开启后与下单相关的字段（方向 / 数量 / 价格类型）隐藏或置灰，保存后条件单卡片显示「提醒」标记

## 预警记录页

- [ ] 新增 `Kline/Simulation/AlertRecordView.swift`，按 `occurredAt` **倒序**列出：时间 / 标的名称与代码 / 触发价 / 文案
- [ ] 空态显示「暂无预警记录」；有数据时行高固定、语义化颜色
- [ ] 支持单条删除（命中区 ≥44pt）与顶部「清空全部」（二次确认）；两者均落盘（重启后保持）
- [ ] 点记录打开该标的 K 线详情（`DetailRouter.open`）
- [ ] 入口在条件单页（`SimCondListView`）导航栏，可进入 / 返回；页内不出现任何自动弹窗
- [ ] ⏳ 真机：条件单页「立即检查」触发一条提醒型条件单后，记录页出现新记录且时间 / 价格正确

## 数据迁移与兼容

- [ ] `favorites.json`：`currentSchema` 2 → 3，新增 `migrateItemOpsIfNeeded()`（幂等；读档后调用 + 写档前兜底回写），新字段全为可选 —— 用一份 **schema 2 的旧 `favorites.json`** 验证：分组、成员、顺序、公式分组引用全部保留，不出现「整档丢失回退默认分组」
- [ ] `sim.json`：`schemaVersion` 2 → 3，`alertRecords` 可选；旧档读入后账户 / 持仓 / 委托 / 成交 / 条件单全部保留
- [ ] 迁移只做「补默认值 / 重写 schema 号」，不改既有字段语义、不做破坏性重排

## 工程与交付

- [ ] 新增文件全部位于 `Kline/` 目录树内，无需手工改 `project.pbxproj`（依赖 `PBXFileSystemSynchronizedRootGroup`）
- [ ] **未新增数据源**：只扩展既有 `favorites.json` / `sim.json` 的字段与 API，不引入新文件存储、不改 `market_columns.json`
- [ ] 未改动 A/B/C/D 的档位定义与个人中心布局设置（`PageLayoutStore` 无改动）
- [ ] 各阶段闭环命令返回 0 / 6 / 7；`git status` 无遗留未提交改动
- [ ] 既有冒烟用例不受影响（`KlineUITests` 的 `favorites.title`、`market.rowCard`、`home.page` 判定仍成立；如因长按改面板而必须调整用例，需在交付说明中写明）
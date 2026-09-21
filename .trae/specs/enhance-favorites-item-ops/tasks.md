# Tasks

## 阶段一：figma 原型（设计稿先行，用户看稿定面板形态）

- [x] Task 1: 新建 `figma/favorites-ops-proposals.html`（3 屏）
  - [x] SubTask 1.1: 复用 `figma/favorites-market-ui-proposals.html` 的画廊骨架（`:root` 变量、`.bezel` + `.screen-wrap` 573×430 + `.screen` 1024×768 `scale(.55957)`、`.switcher`/`.seg`、`.marker`、`.ncard` 标注栏、`#shot=` 单屏定位），无外链依赖
  - [x] SubTask 1.2: 屏 `opsRowMenu`（长按操作面板）：左「长按前的表格行」、右「长按后的同一行 + 居中操作面板」，用编号标注明确标出「行高 / 列宽 / 横向偏移三者逐值不变」，并给一条「旧实现：系统菜单抬升预览 → 列错位」的对照小图
  - [x] SubTask 1.3: 屏 `opsBatch`（批量编辑）：编辑态多选（勾选圈 + 已选高亮）+ 底部批量条（已选 N 只 + 10 个 44pt 动作按钮），并标注「公式分组 / 全部组下的按钮置灰与原因文案」
  - [x] SubTask 1.4: 屏 `opsAlert`（预警记录页 + 备注弹窗）：预警记录列表（时间 / 名称代码 / 触发价 / 文案 + 单条删除 + 顶部「清空全部」）+ 叠一张备注编辑弹窗（含「已有备注」与「空备注」两态）
  - [x] SubTask 1.5: 每屏配编号标注 + 标注栏（描述 / 布局标注 / 优势 / 代价）与 `SCREENS`/`MARKS` 登记；页头写清「本次要解决的 6 件事（变形修复 / 固顶 / 移前移后 / 批量 / 备注 / 预警）」

- [x] Task 2: 逐屏截图与交付说明
  - [x] SubTask 2.1: 按 `#shot=<屏 id>` 逐屏截图到 `figma/_shots/`（`ops_rowmenu.png` / `ops_batch.png` / `ops_alert.png`，窗口与既有截图一致 700×560）
  - [x] SubTask 2.2: 自检：无溢出 / 截断 / 重叠、编号与标注一一对应、设备框尺寸与既有画廊一致（屏 1 左/右两块表格由同一串 HTML 渲染，行高列宽逐值一致）
  - [x] SubTask 2.3: 交付说明（画廊路径 + 3 张截图 + 面板项与批量项一览），等用户定稿

## 阶段二：数据层（无 UI 变化，独立可编译）

- [ ] Task 3: `FavoritesStore` 升级到 schema 3：固顶 + 备注 + 移前移后
  - [ ] SubTask 3.1: `FavoritesGroup` 新增 `pinnedMetaIDs: [Int]?`（可选；顺序即固顶顺序）；`FavoritesRoot` 新增 `notes: [String: String]?`（key = `String(metaID)`，**禁止用 `[Int: String]`**，非 String key 的字典会被 `JSONEncoder` 编码成交替数组）
  - [ ] SubTask 3.2: `currentSchema` 2 → 3，新增幂等迁移 `migrateItemOpsIfNeeded()`（初始化读档后调用 + 写档前兜底回写，范式照 `migrateFormulaGroupsIfNeeded`）；`FavoritesGroup` / `FavoritesRoot` 的新字段一律可选 + `decodeIfPresent`（无自定义 `init(from:)` 时加非可选字段会让旧档 decode 失败 → 整档丢）
  - [ ] SubTask 3.3: 新增 API：`togglePin(groupID:metaID:)`、`isPinned(groupID:metaID:)`、`pinnedIDs(groupID:)`、`moveToFirst(groupID:metaID:)`、`moveToLast(groupID:metaID:)`（**只重排 `manualMetaIDs`，不得用 `compactMap` 后的结果整组覆写**，否则会丢不在 `metaList` 的历史 id）、`note(for:)` / `setNote(metaID:text:)`（空串 = 删除 key）
  - [ ] SubTask 3.4: 公式分组与「全部」虚拟组的语义守卫：固顶允许（显示层）、移前移后拒绝（`kind != .manual` 或 allGroupID 时 no-op），写得直白并加注释
  - [ ] SubTask 3.5: 编码自查：`@Published` 同值不写（沿用既有 `saveToDisk` 前的差异比较惯例）、`Color.opacity` 入参 Double、不遮蔽同名参数

- [ ] Task 4: 条件单新增「仅提醒」形态（`alertOnly`）
  - [ ] SubTask 4.1: `SimCondDirective` 新增 `alertOnly: Bool?`（`CodingKeys` + `init(from:)` 兜底 `false`，旧档不炸）；对外暴露 `isAlertOnly` 计算属性（`alertOnly ?? false`）
  - [ ] SubTask 4.2: `SimCondEngine` 触发分支：`isAlertOnly` 为真时**不** `submit(draft)`、**不**校验数量与持仓，写 `triggeredAt` / `lastTriggerPrice` / `lastMessage`（文案如「预警：现价 12.34 上穿 12.00」），并 append 一条 `SimAlertRecord`；普通条件单分支保持逐行等价
  - [ ] SubTask 4.3: `SimTradingRules` / 引擎校验：`alertOnly` 跳过 qty 与可卖持仓校验（现有 `validate` 会把 qty ≤ 0 视为拒绝，需显式放行）
  - [ ] SubTask 4.4: 编码自查：不改变普通条件单的任何行为（对照改造前后的分支逐项核对），日志与触发次数统计口径不变

- [ ] Task 5: `SimStore` 预警记录存储
  - [ ] SubTask 5.1: 新增 `SimAlertRecord: Codable, Identifiable`（`id` / `condID` / `metaID` / `code` / `name` / `price: Double?` / `message` / `occurredAt`）；`SimRoot` 新增 `alertRecords: [SimAlertRecord]?`，`schemaVersion` 2 → 3（沿用逐项 `try?` 兜底）
  - [ ] SubTask 5.2: 新增 API：`appendAlertRecord(_:)`（落盘 + 超 200 条丢最旧）、`deleteAlertRecord(id:)`、`clearAlertRecords()`；写入沿用「先比较再赋值」惯例
  - [ ] SubTask 5.3: 只读派生：`alertRecordsSorted`（按 `occurredAt` 倒序）、`alertRecordCount`

- [ ] Task 6: 阶段二闭环
  - [ ] SubTask 6.1: 编码自查（数据层无 UI 改动；`favorites.json` / `sim.json` 旧档能正常读入且不丢分组）
  - [ ] SubTask 6.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(favorites-ops): 自选固顶/备注/移前移后与条件单仅提醒数据层（schema 3）"`
  - [ ] SubTask 6.3: 交付说明（build 号 / 数据层改动 / 迁移口径），此时 UI 无变化、可先验收旧档兼容

## 阶段三：长按操作面板 + 批量编辑（UI 改造，消灭行变形）

- [ ] Task 7: 新增共享组件 `Kline/Favorites/FavoritesRowMenu.swift`
  - [ ] SubTask 7.1: `FavoritesRowMenuTarget`（标的 + 所在分组上下文 + 是否行情页）与容器层 `overlay` 承载：`Color.black.opacity(0.25)` 遮罩（点击关闭）+ 居中卡片（宽 260、`systemBackground`、`cornerRadius(12)`、`shadow(black 20%, radius 12, y 4)`）+ 标题行（名称 + 代码 13pt `.secondary`）+ 每项行高 44（`padding(.horizontal,12)` + `Divider`）+ 底部「取消」（15 semibold 蓝）+ `.transition(.opacity)` + `zIndex(1000)`
  - [ ] SubTask 7.2: 面板项与可用性矩阵：固顶/取消固顶、移到最前、移到最后、加入其它分组、备注…、设置/取消预警、取消自选；按「手动 / 公式 / 全部 / 行情页」裁剪与置灰（置灰项带一行原因说明；有排序规则时移前移后置灰）
  - [ ] SubTask 7.3: 备注弹窗：已有备注直接展示全文（可编辑）+ 空态「添加备注」；保存 / 清空 / 取消；`ignoresSafeArea(.keyboard)`（避免键盘挤压）
  - [ ] SubTask 7.4: 批量预警弹窗：上穿 / 下穿 + 数值 + 可选文案 + 「应用到 N 只」；校验数值合法性与「已存在提醒型条件单」的覆盖确认
  - [ ] SubTask 7.5: 无障碍与命中区：面板每项 ≥44pt、`contentShape(Rectangle())`、遮罩可点、面板可滚动（项多时 `ScrollView.frame(maxHeight: 320)`）

- [ ] Task 8: 自选页表格接入新面板（A/B/D 档共用 `FavoritesTableBody`）
  - [ ] SubTask 8.1: 移除 `rowCard` 的 `.contextMenu`，改 `onLongPressGesture(minimumDuration: 0.5)` 写 `rowMenuTarget`；长按期间**不做**任何 `scaleEffect` / `offset` / 描边 / 背景变化
  - [ ] SubTask 8.2: 长按期间与面板打开期间把 `horizontalDragGesture` 置 nil（复用行情页 `edgeAdjust ? nil :` 写法），避免轻微位移改 `hScrollOffset` 造成「变形」
  - [ ] SubTask 8.3: `sortedRows` 增加「固顶优先」稳定分区（在页面级排序规则排序**之后**执行），固顶集合读当前分组的 `pinnedMetaIDs`
  - [ ] SubTask 8.4: 编辑态列表（`FavoritesManualEditingList`）里的 `.contextMenu` 一并换成新面板；确认编辑态与横向手势仍互斥

- [ ] Task 9: 卡片形态与行情页接入同一面板
  - [ ] SubTask 9.1: 自选页 C 档卡片：移除 `.contextMenu`，长按（与右上「更多」按钮）打开同一面板；卡片不作任何缩放/位移
  - [ ] SubTask 9.2: 行情页表格行（`MarketPageKit` `rowCard`）：`.contextMenu` → 新面板，项为 加自选/取消自选、加入指定分组、备注…、设置/取消预警（无固顶与移前移后）
  - [ ] SubTask 9.3: 行情页磁贴（`MarketLayoutCView`）：长按与「更多」走同一面板，右上 44×44 星标保留不变
  - [ ] SubTask 9.4: 三档互切自测：A/B/C/D 与行情页长按行为一致、面板项按上下文正确裁剪、备注与预警入口可用

- [ ] Task 10: 批量编辑（多选 + 批量条）
  - [ ] SubTask 10.1: 编辑态改 `List(selection:)` 多选（保留 `onMove` 拖拽排序），手动 / 公式 /「全部」三类分组均可进入编辑态（修掉「公式组切编辑回退只读」的旧行为）
  - [ ] SubTask 10.2: 底部批量条：`已选 N 只` + 横向可滚动作按钮（移出/取消自选、移到分组、固顶、取消固顶、设置备注、清除备注、设置预警、取消预警、全选、取消全选），无选择时置灰；条高固定不随选择数抖动
  - [ ] SubTask 10.3: 批量动作实现：批量移出/取消自选、批量加入到目标分组（复用 `AddToGroupSheet`）、批量固顶（按选择顺序追加到固顶尾部）、批量备注（设置同一句 / 清除）、批量预警（N 条同规则 `alertOnly` 条件单）/ 批量取消预警
  - [ ] SubTask 10.4: 四档接线（A 工具条「编辑」/ B 侧栏「编辑」/ C 顶栏 / D 紧凑表）：按钮文案与选中态一致，切档不丢选择（或切档清空选择并给提示，二者取一写清）

- [ ] Task 11: 阶段三闭环
  - [ ] SubTask 11.1: 编码自查（无 `contextMenu` 残留：全项目 Grep `.contextMenu` 应只剩行情页 `marketRowMenuContent` 之外无引用；`body` 内无全表遍历；同值守卫）
  - [ ] SubTask 11.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(favorites-ops): 长按操作面板（消灭行变形）+ 固顶/移动/备注/批量编辑"`
  - [ ] SubTask 11.3: 交付说明（重点请用户验收：长按不再变形、固顶优先于排序规则、批量动作正确），等待真机验收

## 阶段四：预警闭环（编辑器开关 + 预警记录页）

- [ ] Task 12: 条件单编辑器与入口
  - [ ] SubTask 12.1: `SimCondEditorView` 新增「仅提醒（不下单）」开关（默认关），保存时写入 `alertOnly`；开关开启时隐藏/置灰与下单相关的字段（方向、数量、价格类型）
  - [ ] SubTask 12.2: 自选页长按面板「设置预警」→ 复用条件单编辑器并预置「仅提醒」开启 + 带入标的（不复制表单）
  - [ ] SubTask 12.3: `SimCondListView` 导航栏新增「预警记录」入口（跳全屏 `AlertRecordView`）；条件单卡片上对 `isAlertOnly` 显示「提醒」标记，便于区分

- [ ] Task 13: 新增 `Kline/Simulation/AlertRecordView.swift`（预警记录页）
  - [ ] SubTask 13.1: 列表按 `occurredAt` 倒序：时间（含日期与时分）/ 标的名称与代码 / 触发价 / 文案；空态「暂无预警记录」
  - [ ] SubTask 13.2: 单条左滑或行内按钮删除（先做行内删除按钮，命中区 ≥44pt）、顶部「清空全部」（二次确认）；点记录打开该标的 K 线详情（`DetailRouter.open`）
  - [ ] SubTask 13.3: 使用语义化颜色、固定行高；不改 App 内任何弹窗/横幅提示（预警不弹窗是本次明确口径）

- [ ] Task 14: 阶段四闭环
  - [ ] SubTask 14.1: 编码自查（普通条件单行为零变化、预警触发不下单、记录落盘与上限生效）
  - [ ] SubTask 14.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(favorites-ops): 条件单仅提醒模式与预警记录页"`
  - [ ] SubTask 14.3: 交付说明，等待真机验收

## 阶段五：验收

- [ ] Task 15: 逐条核验 checklist（含真机手工验收清单），失败条目回填 tasks 修复后重验
- [ ] Task 16: 最终交付说明（各阶段 build 号、操作矩阵一览、真机验证路径与回归点、`git status` 无遗留改动）

# Task Dependencies

- Task 1 → Task 2（同一 HTML 文件）
- Task 3 / Task 4 / Task 5 相互独立，可并行（不同文件）；三者都依赖 Task 1 的稿（可并行开展，不必等定稿）
- Task 6 依赖 Task 3、Task 4、Task 5
- Task 7 依赖 Task 3（面板要调用固顶/备注/预警 API）、Task 5（预警记录写入）
- Task 8 / Task 9 依赖 Task 7；Task 10 依赖 Task 8（编辑态在同一文件）
- Task 11 依赖 Task 8、Task 9、Task 10
- Task 12 依赖 Task 4、Task 7；Task 13 依赖 Task 5；Task 14 依赖 Task 12、Task 13
- Task 15 / Task 16 依赖 Task 2、Task 11、Task 14
- 阶段一（figma）与阶段二（数据层）可并行
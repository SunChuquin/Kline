# Checklist

> 验证方式：本机（Windows）无 Swift 编译器，故采用「静态代码核查 + 云端构建 + 用户真机验收」三层。
> 构建证据：run=35503751366（阶段一+二）、run=35504207749（阶段三）、run=35504609575（阶段四修复，构建成功）。
> 静态核查逐条给出文件与行号证据；标「待真机确认」的条目已确认代码路径成立。

## 模型与持久化

- [x] `SimCondKind` / `SimCondStatus` / `SimCondValidity` / `SimCondDirective` / `SimCondParams` / `SimCondRuntime` / `SimCondOrder` 全部实现为 `Codable, Hashable` 值类型，参数为扁平原生可选字段（无带载荷枚举）｜证据：SimConditionModels.swift:17,51,75,124,148,227,260；SimCondParams 全为 Double?/Int?/Bool? 扁平字段
- [x] `sim.json` 根结构含 `conditionalOrders` 且 `schemaVersion = 2`；解码逐项兜底，旧的 schemaVersion 1 档案能无损读出六类既有数据｜证据：SimStore.swift:26,87,178-186（写档）、48-59（逐项 `try? … ?? []` 兜底）、162（读档 assign）
- [x] 首次播种包含示例条件单（止盈止损 / 回落卖出 / 网格）｜证据：SimStore.swift:449-530，实际播 4 张（多一张已触发的价格条件，让「已触发」分段非空，为超集）
- [x] 条件单创建后杀进程重启，列表内容与运行时进度与关闭前一致｜证据：写档 SimStore.swift:185、读档 162；SimCondOrder 自定义 decode 覆盖全部字段含 runtime（SimConditionModels.swift:288-308），SimCondRuntime 的 extreme/gridLevel/gridLastPrice/batchDone/lastMessage 均在 CodingKeys（237-240），encode 为合成，往返无丢字段 —— 代码路径已成立，待真机确认
- [x] `SimStore` 所有条件单写入都走「值未变不写」守卫｜证据：SimStore.swift:224-226 唯一写入口带比较；upsert/cancel/delete 均经 assignConditionalOrders；引擎 hold 分支先比 runtime（SimCondEngine.swift:89-93 附近）

## 评估与引擎

- [x] `SimCondRule.evaluate` 为纯函数，不写任何数据、不触发落盘｜证据：SimCondRule.swift:87-194 只读入参与局部 runtime 副本，无 store、无 IO；取数隔离在 SimCondSnapshotCenter（431-454，只读）
- [x] 判定三态齐全：`fire` / `hold` / `abort`，且 `abort` 携带可直接展示的中文原因｜证据：SimCondRule.swift:29-33；中文原因如「触发价缺失」(93)、「网格参数不完整」(160)（另有第四态 `complete`，见「阶段四修复」）
- [x] 行情快照缺失（last 或 prevClose 为 nil）时判定为 `hold`，不误触发｜证据：SimCondRule.swift:89 `guard let price = snapshot.last, price > 0 else { .hold }`；均线另需 prevClose（147）、涨跌幅缺 changePct（141）同样 hold
- [x] 止盈止损双边 OCO：先触发腿生效，另一腿随之失效｜证据：SimCondRule.swift:103-108 先判止损腿再判止盈腿，双命中取止损（风控优先）；触发后非多触发类型置 triggered（SimCondEngine.swift:157-158 附近），下轮被 `status == .monitoring` 过滤（55）不再可评估
- [x] 均线条件区分「首次穿越」与「持续满足」，后者不重复触发｜证据：SimCondRule.swift:147-152 要求 `prev < ma && price >= ma`（下破同理），bar 对 bar 判定，同日内幂等
- [x] 触发后统一走 `SimStore.submit`，生成的 `SimOrder.originCondID` 指向条件单｜证据：SimCondEngine.swift:131-142 组装草稿后 `draft.originCondID = order.id` 并 submit；SimTradingRules.swift:24 草稿字段；SimStore.swift:683 落到 SimOrder.originCondID（SimModels.swift:159）
- [x] 单次触发类型下单被拒后置「已拒绝」且不重试；多触发类型失败保持「监控中」并记因｜证据：SimCondEngine.swift:167-178 附近，`!repeatable` 才置 `.rejected`，多触发保持原状态并写 lastMessage
- [x] `SimCondEngine.sweep` 有重入保护；`MarketRowCache.rows` 连续变化时只结算一次｜证据：SimCondEngine.swift:51-53 `condSweepInFlight`；SimStore.swift:257-265 `condSweepScheduled` 守卫 + 1.5s 合并窗口，订阅 sink 内只排队不同步结算
- [x] 一次结算只落盘一次（不是每张条件单各落一次盘）｜引擎自身满足（SimCondEngine.swift:127-131 整轮只写一次）；触发路径因必须复用 `submit` 而带出它的写盘（SimStore.swift:721），故实际为 N+1 次 —— **已在 spec「关键约束与取舍」第 6 条声明为取舍**

## 有效期

- [x] 当日有效条件单跨自然日后进入「已失效」｜证据：SimCondEngine.swift:189-190 `startOfDay(createdAt) < today`；日切触发点 SimStore.swift:905（refreshTPlus1IfNeeded，含每日一次守卫 892-893）
- [x] 指定日期到期后进入「已失效」｜证据：SimCondEngine.swift:191-193；且建单时缺到期日被拒（SimCondRule.swift:308-310）
- [x] 长期有效不因时间失效｜证据：SimCondEngine.swift:187-188 直接返回 nil
- [x] 撤销后即便条件成立也不再生成委托｜证据：SimStore.swift:1000-1014 置 `.cancelled`（仅 monitoring 可撤）；引擎只取 `.monitoring`（SimCondEngine.swift:55）

## 管理页

- [x] 导航栏为 关闭 / 条件单 / 新建 三段结构｜证据：SimCondListView.swift:154-188（关闭 155-163、标题 overlay 居中 179-183、＋新建 167-174）
- [x] 概览条展示 监控中 / 已触发 / 已失效 三段计数｜证据：SimCondListView.swift:111-113 → SimStore.swift:977-982；渲染 SimCondKit.swift:100-121（56pt）
- [x] 分段切换互斥，切到「已触发」时不出现监控中与已失效的行｜证据：SimCondListView.swift:143-145,192-202；SimConditionModels.swift:318-324 三段互斥（triggered + completed 归已触发）
- [x] 列表行含 标的名 + 代码、状态标签、类型 chip、条件摘要、委托指令摘要、有效期、行内操作｜证据：SimCondListView.swift:258-265（名+代码）、267（状态标签）、275（类型 chip）、276（条件摘要）、284（指令+有效期）、268-271（编辑/撤销）
- [x] 多触发类型行展示「N/M 档」进度与进度条｜证据：SimCondListView.swift:290-295（unit 档/批）；SimCondKit.swift:61-90 文案「N/M 档 · 已成交 K 笔」+ 3pt 条
- [x] 空态含引导文案与新建入口｜证据：SimCondListView.swift:223-251
- [x] 底部常驻「行情刷新与手动检查时评估，非实时盯盘」提示与「立即检查」按钮｜证据：SimCondListView.swift:330-364（52pt 固定条，文案 332）
- [x] 「立即检查」就地反馈本次结果（触发笔数 / 无触发），列表同步刷新｜证据：SimCondListView.swift:419-422 调 sweepConditions 后 showToast(result.message)；toast 388-414（1.6s 淡出）；@ObservedObject store 驱动刷新

## 编辑器

- [x] 结构完整：标的头卡 → 方向大分段 → 类型 chips（8 种）→ 类型参数卡 → 委托指令卡 → 有效性 → 预览摘要 → 提交｜证据：SimCondEditorView.swift:107-120 依序挂 headerCard/directionSection/kindChips/paramCard/directiveCard/validityCard/previewCard/submitFooter
- [x] 切换类型时方向 / 委托指令 / 有效性保持不变，仅类型参数重置｜证据：SimCondEditorView.swift:937-946 selectKind 只重置 params + 止盈止损开关 + errorText，未触碰 direction/priceType/offsetTicks/validity/expiresAt
- [x] 8 种类型的参数面板均可正常填写并提交成功｜证据：SimCondEditorView.swift:252-261 switch 覆盖 8 分支；SimCondRule.swift:222-310 逐类型放行校验
- [x] 网格与分批能给出档位数 / 笔数分布预估｜证据：SimCondEditorView.swift:378 调 SimCondRule.gridLevelCount；分批 793-806 batchPreviewText 算每批股数与末批目标价
- [x] 预览摘要为一句话自然语言，与提交后的列表摘要一致｜证据：SimCondEditorView.swift:468 用 SimCondRule.previewSentence（404），内部复用 conditionSummary/directiveCore/validitySummary，与 SimCondListView.swift:276/284 同源
- [x] 非法参数（网格区间倒挂、数量非整手、缺行情等）被拦截并就地展示中文原因，不弹 alert｜证据：SimCondEditorView.swift:495-502 提交按钮下方红字 errorText；全文件无 .alert；校验 SimCondRule.swift:222-310
- [x] 卖出方向止盈止损默认基准价为持仓成本价；无持仓时禁止保存并说明原因｜证据：SimCondEditorView.swift:915 `params.basePrice = position?.costPrice`；SimCondRule.swift:250-252 卖出且 sellableQty ≤ 0 → `.noPosition`

## 入口

- [x] 模拟页 A / B / C 三个布局工具栏都有「条件单」按钮，且带监控中数量角标｜证据：A:289,308-329；B:98,61-83；C:216,232-253；角标取 condCounts(...).monitoring
- [x] 全屏下单页 `full` 形态的「条件单」入口带入当前方向 / 价格 / 数量｜证据：TradeTicketView.swift:304 仅 fullBody；335-345 传 direction/qty/initialPrice；函数体无 onSubmit 调用
- [x] 持仓表行内「条件单」按钮带入方向卖出、基准价成本价、数量可卖整手｜证据：SimSharedViews.swift:560 onCondition；A:428-439（B:706-、C:436- 同）initialKind .stopLoss、direction .sell、qty sellableQty、initialPrice costPrice
- [x] 入口按钮命中区不小于 44×44pt｜工具栏（A:325 等）、编辑器 / 列表 / 详情页新增按钮均 ≥44pt；**持仓行「条件单」沿用共享组件 SimInlineButton 的 22pt 高度**（SimSharedViews.swift:110-121），与同行「买/卖」一致，加高会波及布局 C 在途委托行 —— **已在 spec 取舍第 8 条声明为已知偏差**

## 记录与追溯

- [x] `ActionModule.condition` 存在于操作日志类型筛选，且筛选后只出条件单记录｜证据：SimModels.swift:100；SimSharedViews.swift:297-298 筛选条含 .condition；415-417 `filter { $0.module == filter }`
- [x] 日志文案含标的 / 类型 / 触发结果，失败时含拒绝原因｜证据：SimCondEngine.swift:77-79、102-107、116-118、162-165、174-177 附近，content 带 name + kind.title，result 为状态，被拒附 rejection.message
- [x] 条件单详情展示条件定义、委托指令、有效期、创建时间、触发记录｜证据：SimCondDetailView.swift:37-55 五段卡；359 创建时间；52-54 触发记录
- [x] 已触发条件单可跳转到其生成的委托｜证据：SimCondDetailView.swift:145-188 originOrderID → relatedOrder，可点展开委托明细（含成交均价与费用）

## 规范一致性

- [x] 全部界面使用语义色，深色模式下无白底黑字残留｜证据：新增条件单文件仅 SimCondEditorView.swift:486 用 Color.white 作实心按钮**文字**色；`git diff` 新增行无 white/black 用作底色
- [x] 买入红 / 卖出绿与既有下单组件一致｜证据：SimCondEditorView.swift:743 dirColor；SimCondDetailView.swift:204-205,339-340
- [x] 未引入 Table / Chart / NavigationStack / `@Observable`，保持 iOS 15 兼容｜证据：全库 grep 仅命中注释；分段控件复用 TradeSegmentedRow
- [x] 新增主文件体积受控，纯展示原子件拆到 `SimCondKit.swift`｜证据：SimCondKit 111 行；Models 291 / Rule 398 / Engine 215 / ListView 399 / DetailView 404 / Editor 881（最大，仍 <1000）

## 阶段四修复复核（静态验证发现的缺陷）

- [x] 网格价格越界与分批走完置「已完成」而非「已失效」｜证据：SimCondRule.swift:33 新增 `case complete(String)`（与 abort 区分正常完成 / 异常失效）、162、186；SimCondEngine.swift:108-118 新增 `.complete` 分支置 `.completed` 并写「条件单完成」日志、31,114 计入 `result.completed`
- [x] `triggeredCount` 仅在下单成功时自增｜证据：SimCondEngine.swift:157 已从 submit 之前移入 `case .success` 分支，failure 分支不自增
- [x] `validity == .untilDate` 缺 `expiresAt` 时建单被拒｜证据：SimCondRule.swift:308-310 `return .missingParam("有效期到期日")`，复用既有中文文案
- [x] 条件单详情的触发记录按 id 精确匹配，同标的多单不再串日志｜证据：SimModels.swift:198 `ActionLog.condID: UUID? = nil`（带默认值，合成 Codable 走 decodeIfPresent，旧档兼容）；SimCondEngine.swift:258 conditionLog 补 condID；SimCondDetailView.swift:234 改为 `$0.condID == order.id`；SimStore.swift:1012 撤销日志也带回链

## 设备验证（待用户真机验收）

- [ ] 阶段一真机验收通过（示例条件单可见 / 立即检查有结果 / 可触发并生成委托 / 可撤销）
- [ ] 阶段二真机验收通过（三处入口可用 / 8 种类型可创建 / 非法参数被拦截 / 深色模式正常）
- [ ] 阶段三真机验收通过（行情就绪自动结算 / 跨日失效 / 触发记录可追溯）
- [ ] 回归点确认：既有手动下单、撤单、改价、一键平仓、T+1 刷新行为未受影响
- [ ] 呈现链真机确认：管理页「新建 → 选择标的 → 编辑器」连续弹层在 iOS 15 上表现正常
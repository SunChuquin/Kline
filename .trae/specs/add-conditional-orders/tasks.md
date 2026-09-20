# Tasks

## 阶段一：数据与引擎骨架（可独立编译、可真机演示）

- [ ] Task 1: 条件单模型与持久化
  - [ ] SubTask 1.1: 新建 `Kline/Trading/SimConditionModels.swift`，定义 `SimCondKind` / `SimCondStatus` / `SimCondValidity` / `SimCondDirective` / `SimCondParams` / `SimCondRuntime` / `SimCondOrder`，全部 `Codable, Hashable`，参数用扁平原生可选字段，不用带载荷枚举
  - [ ] SubTask 1.2: `SimModels.swift` 的 `ActionModule` 新增 `case condition`（标题「条件单」）；`SimOrder` 新增 `var originCondID: UUID?`（可选字段，Swift 合成解码走 `decodeIfPresent`，旧档兼容）
  - [ ] SubTask 1.3: `SimStore.swift` 的 `SimRoot` 新增 `conditionalOrders`，`currentSchema` 升为 2，解码逐项兜底、编码带 `sortedKeys`
  - [ ] SubTask 1.4: `SimStore` 新增 `@Published private(set) var conditionalOrders` 与 `assignConditionalOrders` 值比较守卫；新增查询（按账户 / 按分段 / 单条）、`upsert`、`cancelCond`、`deleteCond`
  - [ ] SubTask 1.5: 首次播种新增 3 张示例条件单（止盈止损 / 回落卖出 / 网格），与既有播种数据同批写入；存档后重启验证读回一致

- [ ] Task 2: 评估纯函数与触发引擎
  - [ ] SubTask 2.1: 新建 `Kline/Trading/SimCondRule.swift`：`SimCondSnapshot`（last / prevClose / high / low / changePct / ma）、`SimCondDecision`（fire / hold / abort）、8 种类型的 `evaluate(order:snapshot:)` 纯函数（无副作用、不写数据）
  - [ ] SubTask 2.2: 同文件实现 `validateCreate(...) -> SimCondRejection?`，含中文拒绝文案（缺行情 / 参数非法 / 卖出无持仓 / 数量非整手 / 网格区间倒挂等）
  - [ ] SubTask 2.3: 新建 `Kline/Trading/SimCondEngine.swift`：`sweep(trigger:)` 统一结算入口，评估互斥（`isSweeping` 重入保护）+ 短窗口合并，先判有效期、再取快照、再判定、再下发
  - [ ] SubTask 2.4: 触发后组装 `SimOrderDraft` 走既有 `SimStore.submit`；单次触发成功置 `triggered`、失败置 `rejected` 并记录原因；多触发失败保持 `monitoring` 并记因
  - [ ] SubTask 2.5: 结算结束统一 `saveToDisk()` 一次；写 `ActionModule.condition` 日志；手动检查返回本次结果（触发笔数 / 无触发）

**阶段一真机验收**：模拟页可见 3 张示例条件单；点「立即检查」能得到结果提示；构造一张必然满足的价格条件单能生成委托；撤销后刷新列表状态正确。

## 阶段二：管理页与编辑器（可独立编译、可真机演示）

- [ ] Task 3: 条件单管理页 `SimCondListView`
  - [ ] SubTask 3.1: 新建 `Kline/Simulation/SimCondListView.swift`：导航栏（关闭 / 条件单 / 新建）、概览条三段计数、分段控件（监控中 / 已触发 / 已失效）
  - [ ] SubTask 3.2: 列表行卡片：标的名 + 代码、状态标签（复用 `SimStatusTag` 样式）、类型 chip、条件摘要、委托指令摘要、有效期、行内操作（撤销 / 编辑）
  - [ ] SubTask 3.3: 多触发类型行展示「N/M 档」进度 + 细进度条；空态引导
  - [ ] SubTask 3.4: 底部固定条：「行情刷新与手动检查时评估，非实时盯盘」+「立即检查」按钮（就地 toast 反馈结果）
  - [ ] SubTask 3.5: 新建 `Kline/Trading/SimCondKit.swift` 存放纯展示原子件（类型 chip、条件摘要构造函数、进度条、概览格子），避免主文件超长

- [ ] Task 4: 条件单编辑器 `SimCondEditorView`
  - [ ] SubTask 4.1: 新建 `Kline/Simulation/SimCondEditorView.swift`：标的头卡 → 方向大分段（复用 `TradeBigDirSegment`）→ 类型 chips 横滑 → 类型参数卡 → 委托指令卡 → 有效性 → 预览摘要 → 提交
  - [ ] SubTask 4.2: 8 种类型参数面板，复用 `TradeLineRow` / `TradeSegmentedRow` / `TradeStepperButton` / `TradePosChips`；切换类型保留方向 / 指令 / 有效性，只重置类型参数
  - [ ] SubTask 4.3: 网格与分批的参数联动预估（区间内档位数预估、分批笔数分布预览）
  - [ ] SubTask 4.4: 预览摘要一句话自然语言构造；校验失败就地红字（不弹 alert）；卖出止盈止损默认基准价取持仓成本价，无持仓禁止保存

- [ ] Task 5: 三处入口接线
  - [ ] SubTask 5.1: `SimulationLayoutAView` / `BView` / `CView` 工具栏新增「条件单」按钮（带监控中数量角标），`.fullScreenCover` 打开管理页
  - [ ] SubTask 5.2: `TradeTicketView` 的 `full` 形态新增「条件单」入口，带入当前方向 / 价格 / 数量打开编辑器
  - [ ] SubTask 5.3: `SimSharedViews.swift` 持仓表行内新增「条件单」按钮，直达卖出方向止盈止损编辑器（基准价 = 成本价、数量 = 可卖整手）

**阶段二真机验收**：三处入口都能打开条件单；8 种类型都能创建成功并在管理页看到正确摘要；非法参数被拦截且有中文提示；深色模式下两页显示正常。

## 阶段三：自动触发与追溯（可独立编译、可真机演示）

- [ ] Task 6: 自动触发源接线
  - [ ] SubTask 6.1: `SimStore.prepareQuotes()` 末尾触发一次结算；`DatabaseManager.isLoaded` 首次就绪触发一次
  - [ ] SubTask 6.2: 订阅 `MarketRowCache.rows` 变化，经引擎的合并窗口节流后结算（禁止逐条结算）
  - [ ] SubTask 6.3: 跨日失效检查（当日有效/指定日期到期置 `expired`），与既有 `refreshTPlus1IfNeeded` 同批执行

- [ ] Task 7: 触发记录与操作日志
  - [ ] SubTask 7.1: 操作日志表支持「条件单」类型筛选；日志文案含标的 / 类型 / 触发结果 / 失败原因
  - [ ] SubTask 7.2: 条件单详情（条件定义 / 委托指令 / 有效期 / 创建时间 / 触发记录），已触发行可跳转到对应委托
  - [ ] SubTask 7.3: 多触发类型的档位推进与完成态（到达档位上限或价格越界置 `completed`）

# 阶段交付节奏

每个阶段收尾都执行一次闭环命令并暂停等真机验收：

- **Windows（公司）**：`python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<阶段描述>"`
- **macOS（家里）**：`bash scripts/kline_deploy_mac.sh "<阶段描述>"`

未获用户确认前不进入下一阶段。

# Task Dependencies

- Task 2 依赖 Task 1（模型与持久化）
- Task 3 依赖 Task 1、Task 2（列表行需要状态与运行时进度）
- Task 4 依赖 Task 1、Task 2（编辑器提交需要校验与写入）
- Task 5 依赖 Task 3、Task 4（入口要能打开两个页面）
- Task 6 依赖 Task 2、Task 3（自动结算结果需要在管理页可见）
- Task 7 依赖 Task 2、Task 4（触发记录来自引擎，详情入口在编辑器/列表）
- Task 3 与 Task 4 在 Task 1、Task 2 完成后可并行
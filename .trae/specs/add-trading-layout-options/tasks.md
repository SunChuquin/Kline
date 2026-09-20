# Tasks

## 阶段一：数据骨架 + 两处 A 方案

- [x] Task 1: 建立布局偏好仓库 `Kline/Trading/TradingLayoutStore.swift`
  - [ ] SubTask 1.1: 定义 `QuickPanelLayoutStyle`（A `contextual` / B `paged` / C `bolt`）与 `SimulationLayoutStyle`（A `sidebar` / B `cards` / C `classic`），各带 `rawValue`、`title`（如「A · 上下文自适应交易卡」）与 `CaseIterable`/`Identifiable`
  - [ ] SubTask 1.2: 定义 `TradingLayoutStore: ObservableObject` 单例，`@Published var panelLayout` / `simulationLayout`，`didSet` 写入 UserDefaults（key `kline.quickPanelLayout` / `kline.simulationLayout`），`private init()` 读回并回退默认 `.a`
  - [ ] SubTask 1.3: 参照 [KlineThemeStore](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/KlineTheme.swift#L46-L60) 的写法保持同惯例（不引入新范式）

- [x] Task 2: 个人中心两个布局下拉按钮
  - [ ] SubTask 2.1: 新增 `Kline/Profile/TradingLayoutSettings.swift`：`TradingLayoutDropdownButton`（对齐 [KlineThemeDropdownButton](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/KlineTheme.swift#L65-L85) 的字号 12 / 高 28 / `.plain` / 蓝色前景）
  - [ ] SubTask 2.2: 新增 `TradingLayoutOptionsPanel`：210pt 宽、行内 `padding(.horizontal,12)/.vertical,10)` + `Divider`、蓝色 checkmark 选中态、`ScrollView.frame(maxHeight: 320)`、底部「完成」按钮（15 semibold 蓝 / `padding(.vertical,11)`）、`systemBackground` + `cornerRadius(12)` + `shadow(black 20%, radius 12, y 4)`
  - [ ] SubTask 2.3: 新增 `TradingLayoutSettingRow`（标题 + 右侧下拉按钮），做成可复用的两处实例
  - [ ] SubTask 2.4: 在 [ProfileDetailView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/ProfileDetailView.swift#L44-L92) 的 ScrollView 中、主题行下方插入两行（快捷面板布局 / 模拟页布局），并各配一个容器层 overlay 浮层（`black 25%` 遮罩 + 居中面板 + `.transition(.opacity)` + `zIndex(1000)`）

- [x] Task 3: 模拟交易领域模型与交易规则
  - [ ] SubTask 3.1: 新增 `Kline/Trading/SimModels.swift`：`SimAccount`（id / name / badge 单字 / colorHex / initialCapital / cash / createdAt / isArchived）、`SimPosition`（accountID / metaID / code / name / qty / availableQty / costPrice）、`SimOrder`（accountID / metaID / code / name / direction / priceType / price / qty / filledQty / status / createdAt）、`SimFill`（orderID / 成交价量额 / fee / tradedAt / contractNo）、`LedgerEntry`（kind / note / signed amount / balanceAfter / occurredAt）、`ActionLog`（accountID / module / content / result / occurredAt）；全部 `Codable` + `Identifiable`
  - [ ] SubTask 3.2: 新增 `Kline/Trading/SimTradingRules.swift`：`SimTradingRules` 结构（T+1、lotSize 100、佣金万 2.5 最低 5 元、卖出印花税千一、最小报价档位、涨跌停幅度），提供 `commission(amount:)` / `stampTax(amount:)` / `isTradingSession(at:)` / `validate(draft:account:position:quote:) -> SimOrderRejection?`
  - [ ] SubTask 3.3: 新增 `Kline/Trading/SimFormat.swift`：金额（千分位 + 两位小数）、带符号金额、股数、百分比、时间的统一格式化，供面板 / 模拟页 / 下单组件共用

- [x] Task 4: `SimStore` 持久化仓库与业务动作
  - [ ] SubTask 4.1: 新增 `Kline/Trading/SimStore.swift`：`@MainActor final class SimStore: ObservableObject` 单例，`@Published` 六类数组 + `selectedAccountID`；读写 `Documents/Simulation/sim.json`（含 `schemaVersion`，参照 [FavoritesStore](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesStore.swift#L108-L120) 的读档/存档与容错）
  - [ ] SubTask 4.2: 账户 CRUD：`createAccount(name:initialCapital:)` / `rename` / `archive` / `reset` / `deposit` / `withdraw`，全部追加 `ActionLog`
  - [ ] SubTask 4.3: 交易动作：`submit(_ draft:)`（走 `SimTradingRules` 校验 → 成交或待报 → 更新持仓/资金 → 写 `SimFill`/`LedgerEntry`/`ActionLog`）、`cancelOrder(id:)`、`amendOrderPrice(id:newPrice:)`、`cancelAll(accountID:)`、`closeAll(accountID:metaID:)`
  - [ ] SubTask 4.4: 聚合查询：`positions/orders/fills/ledger/logs(accountID:filter:)`（`accountID == nil` 或 `.all` 时聚合全部）、`summary(accountID:)`（总资产 / 可用 / 市值 / 仓位 / 当日盈亏 / 累计盈亏），市值与浮盈取 [MarketRowCache](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketRowCache.swift#L16) 最新价，`metaID → MetaItem` 经 [DatabaseManager.metaList](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Data/DatabaseManager.swift#L23) 反查
  - [ ] SubTask 4.5: 首次播种（仅 `sim.json` 不存在时）：3 个示例账户（主策略 / 打板 / 低吸）+ 示例持仓 / 委托 / 成交 / 资金流水 / 操作日志，数值对齐原型
  - [ ] SubTask 4.6: T+1 跨日刷新：日期变更时把 `availableQty` 同步为 `qty`（启动与模拟页出现时各调一次）

- [x] Task 5: 共享下单组件 `Kline/Trading/TradeTicketView.swift`
  - [ ] SubTask 5.1: 定义形态枚举 `TradeTicketStyle { panel, bolt, full }` 与入参（账户、标的、初始方向、初始报价类型、初始数量）
  - [ ] SubTask 5.2: 共用内核：方向分段（红买绿卖）、报价类型（限价 / 市价）、委托价步进器（步长按最小报价档位）、数量步进器（100 股）、1/4 · 1/3 · 半仓 · 全仓快捷填入、可买/可卖股数、预计金额与费用预览
  - [ ] SubTask 5.3: 提交走 `SimStore.submit`，失败时展示拒绝原因（资金不足 / T+1 / 非整手 / 涨跌停），成功时回调关闭
  - [ ] SubTask 5.4: 三形态的视觉差异：`panel` 紧凑（行高约 36–40pt）、`bolt` 大字号数量 + 两个大按钮、`full` 全屏卡片（含五档报价条 / 费用明细块）

- [x] Task 6: 快捷面板方案 A（上下文自适应交易卡）
  - [ ] SubTask 6.1: 把 [FloatingAccessoryPanel](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/FloatingAccessory.swift#L214-L260) 改为分发容器：读 `TradingLayoutStore.shared.panelLayout`，按方案取高度（A ≈0.67 / B ≈0.60 / C ≈0.35，上限 660），保留头部标题与 `accessory.close` 标识、保留「贪婪 frame(alignment:.bottom) + ignoresSafeArea(edges:.bottom)」贴底做法
  - [ ] SubTask 6.2: 新增 `Kline/App/QuickPanelLayouts.swift`，内含 `QuickPanelAView` 与共享子块（账户条、行情头、在途委托块、自选迷你行）
  - [ ] SubTask 6.3: `QuickPanelAView` 详情页态：读 `DetailRouter.shared.item` 带入标的 → 账户条（可切换账户 / 可用资金 / 交易时段）+ 行情头 + 下单卡 + 该股持仓内联 + 快捷动作（全仓 / 一键撤单 / 一键清仓，卖出类二次确认）+ 主操作按钮
  - [ ] SubTask 6.4: `QuickPanelAView` 列表态（`DetailRouter.shared.item == nil`）：账户摘要卡 + 四个快捷入口（闪电买 / 闪电卖 / 一键撤单 / 资金）+ 自选迷你列表（取 [FavoritesStore.allGroup](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesStore.swift#L79-L91) 前若干条，行内「买 / 卖」）+ 在途委托直达撤单；点行内买卖在面板内原地切到下单卡（不跳页、不关闭面板）

- [x] Task 7: 模拟页方案 A（账户侧栏 + 工作区）
  - [ ] SubTask 7.1: 改 [SimulationView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Simulation/SimulationView.swift) 为分发容器，按 `TradingLayoutStore.shared.simulationLayout` 渲染 A/B/C；**必须保留 `simulation.subtitle` 标识**
  - [ ] SubTask 7.2: 新增 `Kline/Simulation/SimSharedViews.swift`：`SimSummaryBand`（六项资产指标 + 近 30 日净值折线）、`SimModuleTable`（持仓 / 当日委托 / 当日成交 / 资金流水 / 操作日志五张表）、`SimBottomActionBar`（常驻买入 / 卖出）、`SimFullScreenTicket`（`fullScreenCover` 包 `TradeTicketView(style:.full)`）、状态标签 / 方向标签 / 行内操作按钮等共用原子视图
  - [ ] SubTask 7.3: 新增 `Kline/Simulation/SimulationLayoutAView.swift`：216pt 账户侧栏（含「全部账户汇总」「新建账户」「交易规则设置 / 账户管理」页脚）+ 右侧资产总览 + 五模块分段（操作日志页额外显示日期范围 / 类型 / 关键词 / 导出工具条）+ 底部常驻买卖条
  - [ ] SubTask 7.4: 持仓表行内「买 / 卖」→ 打开全屏下单页并带入标的与方向；委托表在途行提供「撤单 / 改价」

- [x] Task 8: 阶段一闭环
  - [x] SubTask 8.1: 编码自查（`Color.opacity` 入参 Double、勿遮蔽同名参数、`@Published` 同值赋值加守卫、避免在 `body` 内做重计算）
  - [x] SubTask 8.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(trading): 模拟交易数据内核 + 布局切换入口 + 快捷面板/模拟页 A 方案"`（run=35499989076，退出码 6 构建成功）
  - [x] SubTask 8.3: 交付说明（本轮 build 号 / 改了什么为什么 / 真机验证路径与回归点），等待用户真机验收

## 阶段二：其余四套布局

- [x] Task 9: 快捷面板方案 B（分页式面板）
  - [ ] SubTask 9.1: `QuickPanelBView`：交易 / 持仓 / 委托三个分段 + 角标数量，复用 `TradeTicketView(style:.panel)` 与共享子块
  - [ ] SubTask 9.2: 持仓页行内「卖」切到交易页并填好数量；委托页提供「撤单 / 全部撤单」

- [x] Task 10: 快捷面板方案 C（闪电下单条）
  - [ ] SubTask 10.1: `QuickPanelCView`：标的行情头 + 账户条 + 大字号数量控件（步进 100 股）+ 买入 / 卖出两个大按钮（默认市价）
  - [ ] SubTask 10.2: 「展开」切换到完整下单卡（复用 `TradeTicketView(style:.panel)` 或 `.bolt` 展开态）；卖出走二次确认

- [x] Task 11: 模拟页方案 B（账户卡片 + 模块宫格）
  - [ ] SubTask 11.1: 新增 `Kline/Simulation/SimulationLayoutBView.swift`：顶部账户卡片横排（含迷你净值折线 + 新建账户卡）+ 2×2 模块摘要卡（持仓 / 当日委托 / 当日成交 / 历史中心）+ 底部买卖条
  - [ ] SubTask 11.2: 模块卡「查看全部 →」进入全屏明细列表（复用 `SimModuleTable`）

- [x] Task 12: 模拟页方案 C（券商经典顶栏式）
  - [ ] SubTask 12.1: 新增 `Kline/Simulation/SimulationLayoutCView.swift`：顶部账户下拉 + 一行资产指标（含在途委托数）+ 全宽大表 + 在途委托 / 当日成交两个小卡 + 底部买卖条
  - [ ] SubTask 12.2: 账户下拉切换复用同一账户模型，表格随账户过滤

- [x] Task 13: 阶段二闭环
  - [x] SubTask 13.1: 三套面板布局与三套模拟页布局互切自测（高度、贴底、遮罩、按钮隐藏时序）
  - [x] SubTask 13.2: 执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "feat(trading): 补齐快捷面板与模拟页 B/C 两套布局"`（run=35500609739，退出码 6 构建成功）
  - [x] SubTask 13.3: 交付说明，等待用户真机验收

# Task Dependencies

- Task 2 依赖 Task 1（下拉按钮需要枚举与仓库）
- Task 4 依赖 Task 3（模型与规则）
- Task 5 依赖 Task 4（下单走 `SimStore`）
- Task 6 依赖 Task 1、Task 5
- Task 7 依赖 Task 4、Task 5
- Task 9 / Task 10 依赖 Task 6、Task 5
- Task 11 / Task 12 依赖 Task 7
- Task 3 与 Task 2 可并行；Task 6 与 Task 7 可并行

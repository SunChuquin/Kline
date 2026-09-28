# K 线单人训练 Spec

## Why
当前从底部导航「自选 / 行情」进入标的，K 线页固定以该标的最新库日期为右缘，无法用于「从历史某一天开始、逐根揭示后续行情、并像实盘一样下单」的自我训练；训练过程与结果也无处留存、无处查看。

## What Changes
- 首页快捷入口新增「单人训练」；点击弹出训练设置窗（分类 / 标的 / 起始日期）。
- K 线详情页新增「训练态」：右缘锁定在训练日，只能看到训练日及之前**已显现**的行情。
- 训练态只改变「右缘上界」这一件事，其余 K 线页能力**与正常模式一致**：
  - 保留：副图一（`.top`）水平滑动切周期、K 线设置面板「行情周期」、联动多图、十字光标功能及其全部手势、辅助触控转圈、主图左右拖动与双指缩放。
  - 屏蔽：**切换标的**的全部入口 —— 副图二（`.bottom`）的 🔍 搜索按钮、副图二水平滑动切标的（单图与联动每格同样处理）。
- 训练态「单击新辅助触控按钮的中心圆」不再平移窗口，改为让训练日推进一根；其余辅助触控手势不变。
- 训练态复用悬浮按钮打开的「快捷面板」下单：成交价取**训练日收盘价**，成交只写入训练记录，不改动模拟账户 / 持仓 / 资金 / 流水。
- 新增沙盒内独立 sqlite 训练库：**训练开始即建会话落库，每笔交易即时落库**（不是等训练结束才持久化）。
- 训练结束（左上角返回，或训练日推进到该标最新库日期）时写入结束日期。
- 模拟页（A/B/C 三档）新增「训练记录」入口 → 管理页可查看每个会话及其每笔交易明细、删除单条、清空全部。
- 不改造既有联动复盘（`ReplayAsOfModel`）与数据查询层。

## Impact
- Affected specs：新增能力，无既有 spec 被修改 / 移除。
- Affected code：
  - 首页入口：[HomePageKit.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomePageKit.swift)、[HomeView.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeView.swift)、[HomeLayoutBView.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeLayoutBView.swift)、[HomeLayoutCView.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeLayoutCView.swift)、[HomeLayoutDView.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeLayoutDView.swift)
  - K 线页：[KlineDetailView.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/KlineDetailView.swift)、[KlineChartView.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/KlineChartView.swift)、[ChartGestureHandlers.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/ChartGestureHandlers.swift)、[ChartLegendKit.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/ChartLegendKit.swift)、[LinkedKlineTile.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/LinkedKlineTile.swift)
  - 快捷面板与下单票：[FloatingAccessory.swift](file:///Volumes/home/repositories/Kline2/Kline/App/FloatingAccessory.swift)、[QuickPanelLayouts.swift](file:///Volumes/home/repositories/Kline2/Kline/App/QuickPanelLayouts.swift)、[QuickPanelLayoutsBC.swift](file:///Volumes/home/repositories/Kline2/Kline/App/QuickPanelLayoutsBC.swift)、[TradeTicketView.swift](file:///Volumes/home/repositories/Kline2/Kline/Trading/TradeTicketView.swift)
  - 根呈现与悬浮按钮：[ContentView.swift](file:///Volumes/home/repositories/Kline2/Kline/App/ContentView.swift)
  - 模拟页：[SimSharedViews.swift](file:///Volumes/home/repositories/Kline2/Kline/Simulation/SimSharedViews.swift)、[SimulationLayoutAView.swift](file:///Volumes/home/repositories/Kline2/Kline/Simulation/SimulationLayoutAView.swift)、[SimulationLayoutBView.swift](file:///Volumes/home/repositories/Kline2/Kline/Simulation/SimulationLayoutBView.swift)、[SimulationLayoutCView.swift](file:///Volumes/home/repositories/Kline2/Kline/Simulation/SimulationLayoutCView.swift)
  - 新增模块 `Kline/Training/`（模型、sqlite 仓库、会话控制器、设置窗、管理页）
  - 新文件由 pbxproj 的 `PBXFileSystemSynchronizedRootGroup` 自动纳入 target，无需手改工程文件；不新增第三方依赖

## ADDED Requirements

### Requirement: 训练设置窗
系统 SHALL 提供训练设置窗，允许用户指定标的与训练起始日期，并校验该标的历史数据是否足够。

#### Scenario: 随机抽取标的与起始日
- **WHEN** 用户选择分类并点击「随机抽取」
- **THEN** 系统从该分类内、且存在「最新库日期 − 65 天」之前 K 线的标的中随机选取一只，并把起始日期随机落在 [该标最早 K 线日期, 该标最新库日期 − 65 天] 区间内的某个交易日

#### Scenario: 分类口径
- **WHEN** 用户选择分类
- **THEN** 提供五个分类：全部（主库全部标的）、沪深主板（`meta.type == "沪深主板"`）、ETF 指数（`meta.type` 为「沪深京指数」或「扩展行情指数」，与行情页 ETF 指数分类同口径）、自选（全部手工分组标的去重并集）、我的分组（再选择一个具体分组后的该分组标的）

#### Scenario: 手动指定标的与日期
- **WHEN** 用户在设置窗通过搜索选中一只标的
- **THEN** 窗内显示该标的最新库日期与可选起始区间；用户用日期选择器指定起始日期，取值超出区间时被钳制到区间边界

#### Scenario: 历史数据不足
- **WHEN** 选中标的不存在「最新库日期 − 65 天」之前的 K 线
- **THEN** 「开始训练」不可用，并给出中文提示；随机抽取时该标的不会被抽中

### Requirement: 训练态 K 线页
系统 SHALL 以训练起始日作为图表右缘打开 K 线页，并把右缘上界锁定在训练日。

#### Scenario: 打开训练
- **WHEN** 用户点击「开始训练」
- **THEN** 打开该标的 K 线详情页，右缘停在训练起始日对应的那根 K 线，图中不出现该日之后的任何 K 线

#### Scenario: 只能查看已显现区间
- **WHEN** 用户在训练态下左右拖动主图、双指缩放，或使用辅助触控转圈
- **THEN** 右缘不会越过当前训练日，仍不能看到更晚的 K 线（可自由向左查看更早历史）

#### Scenario: 推进一根
- **WHEN** 用户单击新辅助触控按钮的中心圆
- **THEN** 训练日推进一根（日线一根 = 一个交易日），所有可见 K 线视图的右缘自动跟进到新的训练日，新交易日显现；该动作不产生窗口平移

#### Scenario: 保留正常模式的周期与联动能力
- **WHEN** 处于训练态
- **THEN** 副图一水平滑动切换周期、K 线设置面板「行情周期」、联动多图、十字光标及其全部手势、辅助触控转圈均与正常模式表现一致；联动多图中各视图按其自身周期，同样把右缘钳制到「日期 ≤ 训练日」的最后一根

#### Scenario: 禁止切换标的
- **WHEN** 处于训练态
- **THEN** 切换标的的入口全部不可用：副图二的 🔍 搜索按钮不显示，副图二水平滑动不切换标的且不显示滑动提示；联动多图的每一格同样遵守（各格保留其训练开始时的标的与周期，仅右缘受训练日钳制）

#### Scenario: 训练指示
- **WHEN** 处于训练态
- **THEN** 页面顶部显示训练指示条：标的名称与代码、起始日期、当前训练日、本会话已交易笔数

### Requirement: 训练下单
系统 SHALL 在训练态复用悬浮快捷面板下单，成交价取训练日收盘价，成交只写入训练记录。

#### Scenario: 下单成交
- **WHEN** 训练态下用户在快捷面板输入数量并点击「买入」或「卖出」
- **THEN** 以当前训练日收盘价成交一笔，写入训练交易记录（方向、K 线日期、价格、数量、成交额、手续费、盈亏、备注）

#### Scenario: 不污染模拟账户
- **WHEN** 训练态下产生成交
- **THEN** 模拟账户的账户、持仓、资金流水、委托与成交列表均不发生变化

#### Scenario: 训练持仓与浮动盈亏
- **WHEN** 训练态下任意时刻
- **THEN** 面板显示当前训练持仓数量、持仓均价，以及按当前训练日收盘价计算的浮动盈亏

#### Scenario: 卖出超过持仓
- **WHEN** 卖出数量大于当前训练持仓可卖数量
- **THEN** 拒绝该笔交易并给出中文提示（训练不支持做空）

### Requirement: 训练数据持久化
系统 SHALL 把训练会话与每笔交易持久化到沙盒内独立 sqlite 数据库。

#### Scenario: 即时落库
- **WHEN** 训练开始 / 每产生一笔交易 / 训练结束
- **THEN** 分别在 `Documents/Training/training.db` 的 `train_session` 与 `train_trade` 表即时写入或更新；中途强杀 App 后重新打开，管理页仍能看到该会话与已产生的交易

#### Scenario: 会话字段
- **WHEN** 一次训练会话被写入
- **THEN** 记录包含：标的 id / code / name、开始日期（= **开始训练那根 K 线日期**，不是第一笔交易日期）、结束日期、交易次数、创建时间、更新时间、状态

### Requirement: 结束训练
系统 SHALL 在用户返回或训练日到达最新库日期时结束训练。

#### Scenario: 手动返回结束
- **WHEN** 用户点击左上角返回按钮
- **THEN** 会话以「当前训练日」为结束日期落库并结束，K 线页关闭

#### Scenario: 推进到最新日期结束
- **WHEN** 训练日推进到该标的最新库日期
- **THEN** 会话以该最新日期为结束日期落库，页面提示「训练已完成」，用户仍可继续浏览至返回

### Requirement: 训练记录管理页
系统 SHALL 在模拟页提供入口，打开训练记录管理页以查看与删除。

#### Scenario: 查看
- **WHEN** 用户在模拟页点击「训练记录」
- **THEN** 打开管理页，列出全部训练会话（标的、起止日期、交易次数、创建时间），并可进入查看该会话的每笔交易明细

#### Scenario: 删除
- **WHEN** 用户点击会话行的删除按钮并确认
- **THEN** 该会话及其全部交易明细从数据库删除；「清空全部」在二次确认后删除所有会话与明细

#### Scenario: 空态
- **WHEN** 数据库中没有训练会话
- **THEN** 管理页显示空态文案

## MODIFIED Requirements
无（当前无既有 spec 覆盖该能力）。

## REMOVED Requirements
无。

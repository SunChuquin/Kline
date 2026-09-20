# 交易功能三套布局实现 Spec

## Why

`figma/trading-ui-proposals.html` 为「快捷面板」与「模拟页」各给出三套布局方案，用户希望**全部实现**，并在个人中心用两个下拉按钮分别切换两块区域的布局。

现状与目标的落差：

* [FloatingAccessory.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/FloatingAccessory.swift#L219-L260) 的 `FloatingAccessoryPanel` 只有头部，内容区是 `Spacer`，高度固定 0.5。

* [SimulationView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Simulation/SimulationView.swift) 只有「模拟 / 模拟交易功能」两行占位文字。

* 项目**没有任何模拟交易数据模型**（无账户 / 持仓 / 委托 / 成交 / 资金流水 / 操作日志）。三套方案共享同一套功能内核，因此必须先补齐数据内核，再在其上做布局变体。

## What Changes

* **新增交易领域层** `Kline/Trading/`：6 类实体模型、交易规则与费用校验、`SimStore` 持久化仓库（多账户隔离 + 聚合视图）、共享下单组件 `TradeTicketView`（面板紧凑态 / 闪电条 / 全屏三形态复用）、布局偏好仓库 `TradingLayoutStore`。

* **快捷面板**：`FloatingAccessoryPanel` 改为按布局偏好分发的容器，新增 A/B/C 三套布局视图；面板可感知当前详情页标的（详情页态）或无标的（列表页态）。

* **模拟页**：`SimulationView` 改为按布局偏好分发的容器，新增 A/B/C 三套布局视图；**保留** **`simulation.subtitle`** **无障碍标识**（UITest `test02` 依赖）。

* **个人中心**：新增两个下拉按钮（快捷面板布局 / 模拟页布局），样式与交互对齐现有 `KlineThemeSettingRow` + `KlineThemeOptionsPanel`。

* **BREAKING**：无。仅新增文件与替换两个空壳视图的内部实现。

## Impact

* Affected specs: `add-second-floating-accessory`（快捷面板容器与悬浮按钮的呈现时序）

* Affected code:

  * 修改 [FloatingAccessory.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/App/FloatingAccessory.swift#L214-L260)（面板改分发器）

  * 修改 [SimulationView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Simulation/SimulationView.swift)（改分发器）

  * 修改 [ProfileDetailView.swift](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Profile/ProfileDetailView.swift#L44-L92)（加两行设置 + 两个浮层）

  * 新增 `Kline/Trading/`（6 个文件）、`Kline/App/QuickPanelLayouts.swift`、`Kline/Simulation/` 下 4 个文件、`Kline/Profile/TradingLayoutSettings.swift`

  * 依赖既有：[MarketRowCache](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Market/MarketRowCache.swift#L16)（取最新价）、[DatabaseManager](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Data/DatabaseManager.swift#L23)（metaList 反查 MetaItem）、[FavoritesStore](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Favorites/FavoritesStore.swift#L64)（面板列表态的自选池）、[DetailRouter](file:///c:/Users/sunck/home/projects/ios/Kline/Kline/Chart/KlineDetailView.swift#L80-L109)（详情页标的）

  * 工程文件无需改动：`Kline.xcodeproj` 使用 `PBXFileSystemSynchronizedRootGroup`，新增目录自动纳入编译

## 交付分期

* **阶段一（数据骨架 + 两处 A 方案）**：Task 1–8。独立可编译、可真机验收。

* **阶段二（其余四套布局）**：Task 9–13。独立可编译、可真机验收。

***

## ADDED Requirements

### Requirement: 布局偏好持久化

系统 SHALL 提供 `TradingLayoutStore`（`ObservableObject` 单例，`UserDefaults` 持久化），分别保存快捷面板布局与模拟页布局的选择，取值域为 A / B / C，默认均为 A；选择变更后两处界面 SHALL 立即生效，且 App 重启后保持。

#### Scenario: 切换后立即生效并持久化

* **WHEN** 用户在个人中心把「快捷面板布局」从 A 改为 C

* **THEN** 下次打开快捷面板直接呈现 C 方案，且杀掉 App 重启后仍是 C

#### Scenario: 非法/缺失存储值回退默认

* **WHEN** `UserDefaults` 中该 key 为空或不是 A/B/C

* **THEN** 该布局回退为 A，不崩溃

### Requirement: 个人中心两个布局下拉按钮

系统 SHALL 在个人中心新增两行设置：「快捷面板布局」「模拟页布局」，每行右侧为一个下拉触发按钮（显示当前方案名），点击后在页面容器层居中弹出选择面板（210pt 宽、选项行 + 蓝色 checkmark、底部「完成」），样式与现有 `KlineThemeSettingRow` / `KlineThemeOptionsPanel` 完全一致。

#### Scenario: 打开与关闭选择面板

* **WHEN** 用户点击「快捷面板布局」右侧按钮

* **THEN** 弹出三选项面板（A / B / C），当前项带蓝色 checkmark；点选项即切换，点「完成」或遮罩关闭

#### Scenario: 与主题弹窗互不干扰

* **WHEN** 用户先打开主题弹窗、关闭后再打开布局弹窗

* **THEN** 每次只呈现一个弹窗，无叠层错位

### Requirement: 模拟交易领域模型与持久化

系统 SHALL 提供 `SimAccount` / `SimPosition` / `SimOrder` / `SimFill` / `LedgerEntry` / `ActionLog` 六类实体，以及 `SimStore`（`@MainActor` `ObservableObject` 单例）统一持久化到 `Documents/Simulation/sim.json`（含 `schemaVersion`）。账户之间资金、持仓、委托完全隔离；「全部账户」为只读聚合视图。

#### Scenario: 首次启动播种示例数据

* **WHEN** App 首次启动且 `sim.json` 不存在

* **THEN** 播种 3 个示例账户（主策略 / 打板 / 低吸）与对应持仓、委托、成交、资金流水、操作日志，界面上数据完整可读

#### Scenario: 不覆盖用户数据

* **WHEN** `sim.json` 已存在

* **THEN** 直接读档，绝不重新播种或清空用户改动

#### Scenario: 账户隔离

* **WHEN** 在「打板账户」下买入某标的

* **THEN** 「主策略账户」的可用资金与持仓不变，「全部账户汇总」的合计值同步变化

### Requirement: 交易规则校验与费用计算

系统 SHALL 在下单时校验：100 股整数倍、买入可用资金充足、卖出可用股数充足（T+1：当日买入次日才可卖）、价格在涨跌停区间内且符合最小报价档位；并按佣金万 2.5（最低 5 元）、卖出印花税千一计算费用。校验失败 SHALL 拒绝下单并给出明确原因文案，不产生任何数据写入。

#### Scenario: 资金不足

* **WHEN** 买入金额超过账户可用资金

* **THEN** 提交被拒绝，提示可用资金不足与可买股数，持仓与资金不变

#### Scenario: T+1 不可卖

* **WHEN** 当日买入的股票在当日提交卖出

* **THEN** 提交被拒绝，提示「可卖数量不足（T+1：当日买入不可卖）」

#### Scenario: 盘后委托待报

* **WHEN** 在非交易时段提交委托

* **THEN** 委托状态为「待报」，并记入操作日志

### Requirement: 共享下单组件

系统 SHALL 提供单一 `TradeTicketView`，支持 `panel`（面板紧凑态）、`bolt`（闪电条）、`full`（全屏）三种形态，共用同一套方向 / 报价类型 / 价格 / 数量 / 仓位 / 费用预览内核；所有下单入口 SHALL 走同一套 `SimStore` 校验与写入路径。

#### Scenario: 面板下单写入模拟账户

* **WHEN** 在快捷面板（详情页态）点「买入下单」

* **THEN** 该笔委托出现在模拟页「当日委托」，持仓与资金流水同步更新

#### Scenario: 一键撤单

* **WHEN** 在面板或模拟页点「一键撤单」

* **THEN** 该账户所有在途委托变为「已撤」，并各追加一条操作日志

### Requirement: 快捷面板三套布局

系统 SHALL 让 `FloatingAccessoryPanel` 按 `TradingLayoutStore.panelLayout` 呈现三套布局之一，且都兼容两种打开上下文：

* **A · 上下文自适应交易卡**：详情页有标的时直接给完整快捷下单卡（账户条 / 行情头 / 买卖分段 / 价格数量步进 / 仓位快捷 / 该股持仓内联 / 快捷动作 / 主操作按钮）；列表页无标的时上半区为账户摘要与四个快捷入口、下半区为自选行内「买 / 卖」与在途委托，点行内买卖在面板内原地切到下单卡。

* **B · 分页式面板**：交易 / 持仓 / 委托三个分段，角标显示数量。

* **C · 闪电下单条**：只留标的、大字号数量控件与买入 / 卖出两个大按钮，默认市价；「展开」进入完整下单卡。

#### Scenario: 详情页上下文自动带入标的

* **WHEN** 从自选/行情进入 K 线详情页后打开快捷面板

* **THEN** 面板显示当前详情页标的的名称、代码与最新价，下单记入当前选中模拟账户

#### Scenario: 列表页上下文无标的

* **WHEN** 在自选/行情列表页（未进详情）打开快捷面板

* **THEN** 面板走列表态：显示账户摘要与快捷入口，自选行内「买 / 卖」可原地切到下单卡，不跳页

#### Scenario: 面板高度随方案变化且不超上限

* **WHEN** 切换 A / B / C 三套面板布局

* **THEN** 面板高度分别约为屏高 0.67 / 0.60 / 0.35，且都不超过 660pt；面板底边贴物理屏幕底边、无灰色缝隙

#### Scenario: 面板呈现期间按钮隐藏

* **WHEN** 快捷面板已呈现

* **THEN** 两个悬浮按钮隐藏且不响应命中；关闭后原位恢复

### Requirement: 模拟页三套布局

系统 SHALL 让 `SimulationView` 按 `TradingLayoutStore.simulationLayout` 呈现三套布局之一，三套都提供完整的多账户、下单与历史能力：

* **A · 账户侧栏 + 工作区**：左侧 216pt 账户侧栏（含「全部账户汇总」与「新建账户」）+ 右侧资产总览（总资产 / 可用 / 市值 / 仓位 / 当日盈亏 / 累计盈亏 / 近 30 日净值）+ 五模块分段（持仓 / 当日委托 / 当日成交 / 资金流水 / 操作日志）+ 底部常驻买卖条。

* **B · 账户卡片 + 模块宫格**：顶部一排账户卡片（含新建卡）+ 2×2 模块摘要卡（持仓 / 当日委托 / 当日成交 / 历史中心），明细进二级全屏列表。

* **C · 券商经典顶栏式**：顶部下拉切账户 + 一行资产指标 + 全宽大表 + 在途委托 / 当日成交两个小卡。

#### Scenario: 侧栏切换账户即时过滤

* **WHEN** 在方案 A 侧栏点「打板账户」

* **THEN** 资产总览与五张表格立即只显示该账户数据；点「全部账户汇总」显示全部并合计

#### Scenario: 五模块切换

* **WHEN** 在方案 A 点「操作日志」

* **THEN** 表格切到全量操作日志，并显示日期范围 / 类型 / 关键词筛选与导出入口

#### Scenario: 底部买卖条打开全屏下单页

* **WHEN** 在任一模拟页布局点底部「买入」

* **THEN** 全屏下单页出现，方向为买入，提交后写入当前账户

#### Scenario: 保留 UITest 标识

* **WHEN** 运行既有 UITest `test02`

* **THEN** `simulation.subtitle` 元素仍存在，用例通过

### Requirement: 真机验证闭环

系统 SHALL 按项目既定闭环交付：Windows 下执行 `python c:/Users/sunck/home/projects/ios/TrollRestore/build_and_deploy.py "<提交描述>"`，退出码 0 / 6 / 7 视为构建通过；每次交付说明本轮 build 号、改动内容与真机验证路径。

#### Scenario: 阶段构建通过

* **WHEN** 阶段一编码完成

* **THEN** 闭环命令返回 0 / 6 / 7，且 `git status` 无遗留未提交改动


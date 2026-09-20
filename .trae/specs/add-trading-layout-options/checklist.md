# Checklist

> 核验方式：逐条对照实现代码（静态核验，文件 + 行号）。标 ⏳ 的为纯视觉/交互项，需真机确认。

## 布局偏好与个人中心

- [x] `TradingLayoutStore` 为单例 `ObservableObject`，两个布局字段写入 UserDefaults（key `kline.quickPanelLayout` / `kline.simulationLayout`），默认值均为 A —— `TradingLayoutStore.swift:62-85`
- [x] 存储值非法或缺失时回退 A 且不崩溃 —— `TradingLayoutStore.swift:80-84`（`?? .a`）
- [x] 个人中心出现两行设置：「快捷面板布局」「模拟页布局」，右侧为显示当前方案名的下拉按钮 —— `ProfileDetailView.swift:73,79`
- [x] 两个选择面板样式与 `KlineThemeOptionsPanel` 一致（210pt 宽、行内 padding、蓝色 checkmark、底部「完成」、圆角 12、阴影 black 20% radius 12 y 4）—— `TradingLayoutSettings.swift:65,82-94`
- [x] 两个弹窗都挂在页面容器层 overlay（`black 25%` 遮罩 + 居中 + `.transition(.opacity)` + `zIndex(1000)`），不被 ScrollView 裁剪，且同时只呈现一个 —— `ProfileDetailView.swift:95-149`（含 `onChange` 互斥）
- [x] 切换布局后无需重启即生效；重启后仍保持所选方案 —— `@Published` + `didSet`，三处视图均 `@ObservedObject`

## 模拟交易数据内核

- [x] `SimModels.swift` 定义 `SimAccount` / `SimPosition` / `SimOrder` / `SimFill` / `LedgerEntry` / `ActionLog` 六类实体，均 `Codable` + `Identifiable` —— `SimModels.swift:117-194`
- [x] `SimTradingRules.swift` 实现 T+1、100 股整手、佣金万 2.5 最低 5 元、卖出印花税千一、最小报价档位、涨跌停校验，并提供可复用的费用计算 —— `SimTradingRules.swift:59-84,136-182`
- [x] `SimStore` 持久化到 `Documents/Simulation/sim.json`，含 `schemaVersion`；`sim.json` 已存在时不重新播种、不清空用户数据 —— `SimStore.swift:92-99,115-122,239-241`
- [x] 首次启动播种 3 个示例账户（主策略 / 打板 / 低吸）与示例持仓、委托、成交、资金流水、操作日志 —— `SimStore.swift:244-394`
- [x] 账户之间资金与持仓完全隔离，「全部账户汇总」为只读聚合视图 —— 查询按 `accountID` 过滤；下单强制具体账户（`SimStore.swift:513`）
- [x] 下单校验：资金不足 / 可卖不足（T+1）/ 非 100 股整数倍 / 超出涨跌停 均被拒绝且不产生任何数据写入，提示文案明确 —— `SimStore.swift:521-525` 提前 return，未 assign/save；文案 `SimTradingRules.swift:37-52`
- [x] 交易时段外的委托状态为「待报」—— `SimStore.swift:571-574`
- [x] 撤单、改价、一键撤单、一键清仓都会更新持仓与资金并追加操作日志 —— `cancelOrder:657` / `amendOrderPrice:672` / `cancelAll:692` / `closeAll:717`（撤单与改价只改委托状态：本模型下单不冻结资金，故无资金/持仓变动，属设计取舍）
- [x] 账户汇总的总资产 / 可用 / 市值 / 仓位 / 当日盈亏 / 累计盈亏数值与持仓表一致（市值取 `MarketRowCache` 最新价）—— `SimStore.swift:841-848` 与 `snapshot:875-884` 同取 `lastPrice`
- [x] 跨日后当日买入股份变为可卖（`availableQty` 同步为 `qty`）—— `SimStore.swift:748-761`

## 共享下单组件

- [x] `TradeTicketView` 支持 `panel` / `bolt` / `full` 三种形态，共用同一套方向、报价类型、价格、数量、仓位、费用预览内核 —— `TradeTicketView.swift:18-22,97-104`
- [x] 面板、模拟页底部买卖条、全屏下单页三处入口都走同一套 `SimStore` 校验与写入路径 —— `TradeTicketView.swift:590`（唯一提交点）、`QuickPanelLayouts.swift:665`、`SimSharedViews.swift:769`
- [x] 仓位快捷（1/4、1/3、半仓、全仓）按可用数量换算为 100 股整数倍 —— `TradeTicketView.swift:564-568`、`TradeTicketKit.swift:144-146`
- [x] 提交成功后回调关闭；提交失败展示拒绝原因且界面停留在下单态 —— `TradeTicketView.swift:590-595`

## 快捷面板

- [x] `FloatingAccessoryPanel` 按 `panelLayout` 分发 A/B/C 三套布局 —— `FloatingAccessory.swift:277-286`
- [x] 面板高度：A ≈ 屏高 0.67、B ≈ 0.60、C ≈ 0.35，均不超过 660pt —— `FloatingAccessory.swift:227-233,261`
- [x] 面板底边贴物理屏幕底边，底部无灰色缝隙（保留贪婪 `frame(alignment:.bottom)` + `ignoresSafeArea(edges:.bottom)`）—— 组合已保留于 `FloatingAccessory.swift:268-269`；⏳ 缝隙本身需真机确认
- [x] 面板呈现期间两个悬浮按钮隐藏且不响应命中，关闭后原位恢复 —— `ContentView.swift:112-113,120-121`
- [x] 详情页态（`DetailRouter.shared.item != nil`）自动带入当前标的的名称 / 代码 / 最新价 —— `QuickPanelLayouts.swift:53-54,185-208`
- [x] 列表页态（无标的）显示账户摘要与四个快捷入口，自选行内「买 / 卖」可在面板内原地切到下单卡，不跳页、不关闭面板 —— `QuickPanelLayouts.swift:272-281,343-361,488-532`
- [x] 面板内下单后，模拟页「当日委托」「持仓」「资金流水」同步出现该笔记录 —— 共用 `SimStore` 的 `@Published`
- [x] 卖出类操作（一键清仓等）有二次确认 —— `QuickPanelLayouts.swift:63-68`、`TradeTicketView.swift:114-119`
- [x] `accessory.close` 无障碍标识保留，遮罩点击与「关闭」按钮都能关闭面板 —— `FloatingAccessory.swift:240,248,251`
- [x] 方案 B 三个分段（交易 / 持仓 / 委托）可切换且角标数量正确 —— `QuickPanelLayoutsBC.swift:326-336`
- [x] 方案 C 默认市价、大字号数量控件步进 100 股，「展开」可进入完整下单卡 —— `QuickPanelLayoutsBC.swift:611-621`、`TradeTicketView.swift:190,203`

## 模拟页

- [x] `SimulationView` 按 `simulationLayout` 分发 A/B/C 三套布局 —— `SimulationView.swift:34-43`（B/C 已接真实实现，非占位）
- [x] `simulation.subtitle` 无障碍标识仍存在（既有 UITest `test02` 通过）—— `SimulationView.swift:20-23`，挂在可见 `Text` 上
- [x] 方案 A：216pt 账户侧栏含「全部账户汇总」与「新建账户」；点账户后资产总览与五张表格即时过滤 —— `SimulationLayoutAView.swift:37,113-152,196-210`
- [x] 方案 A：五模块（持仓 / 当日委托 / 当日成交 / 资金流水 / 操作日志）可切换；操作日志页显示日期范围 / 类型 / 关键词 / 导出工具条 —— `SimulationLayoutAView.swift:276-317`
- [x] 方案 A：持仓表行内「买 / 卖」打开全屏下单页并带入标的与方向；委托表在途行可撤单 / 改价 —— `SimulationLayoutAView.swift:246-256`、`SimSharedViews.swift:505-508,529-535`
- [x] 方案 B：账户卡片横排（含迷你净值 + 新建卡）+ 2×2 模块摘要卡，模块卡「查看全部 →」进入全屏明细 —— `SimulationLayoutBView.swift:115-134,167,215,278-289,350-353`
- [x] 方案 C：顶部下拉可切账户，一行资产指标 + 全宽大表 + 在途委托 / 当日成交两个小卡 —— `SimulationLayoutCView.swift:109-130,150-177,47-58,251-297`
- [x] 三套布局底部都有常驻买入 / 卖出条，点开全屏下单页 —— A:`258` / B:`43` / C:`60`，均用 `SimBottomActionBar`
- [x] 模拟页所有元素使用语义化颜色（`Color(.systemBackground)` / `.primary` / `.secondarySystemBackground`），深色模式下可读 —— 无写死页面/卡片背景；`Color.white` 仅用于方案 B 彩色账户卡上的文字（允许例外，`SimulationLayoutBView.swift:194-215`）

## 工程与交付

- [x] 新增文件全部位于 `Kline/` 目录树内，无需手工改 `project.pbxproj`（依赖 `PBXFileSystemSynchronizedRootGroup`）—— 两次提交的 diff 均未含 `project.pbxproj`
- [x] 阶段一闭环命令返回 0 / 6 / 7，构建通过 —— run 35499989076，退出码 6
- [x] 阶段二闭环命令返回 0 / 6 / 7，构建通过 —— run 35500609739，退出码 6
- [x] 交付说明包含本轮 build 号、改动内容与真机验证路径；`git status` 无遗留未提交改动 —— 见最终交付说明；`figma/_shots/` 为本次开工前即存在的原型渲染临时截图（25 张约 5MB），未纳入提交

# Checklist

## 布局偏好与个人中心

* [ ] `TradingLayoutStore` 为单例 `ObservableObject`，两个布局字段写入 UserDefaults（key `kline.quickPanelLayout` / `kline.simulationLayout`），默认值均为 A

* [ ] 存储值非法或缺失时回退 A 且不崩溃

* [ ] 个人中心出现两行设置：「快捷面板布局」「模拟页布局」，右侧为显示当前方案名的下拉按钮

* [ ] 两个选择面板样式与 `KlineThemeOptionsPanel` 一致（210pt 宽、行内 padding、蓝色 checkmark、底部「完成」、圆角 12、阴影 black 20% radius 12 y 4）

* [ ] 两个弹窗都挂在页面容器层 overlay（`black 25%` 遮罩 + 居中 + `.transition(.opacity)` + `zIndex(1000)`），不被 ScrollView 裁剪，且同时只呈现一个

* [ ] 切换布局后无需重启即生效；重启后仍保持所选方案

## 模拟交易数据内核

* [ ] `SimModels.swift` 定义 `SimAccount` / `SimPosition` / `SimOrder` / `SimFill` / `LedgerEntry` / `ActionLog` 六类实体，均 `Codable` + `Identifiable`

* [ ] `SimTradingRules.swift` 实现 T+1、100 股整手、佣金万 2.5 最低 5 元、卖出印花税千一、最小报价档位、涨跌停校验，并提供可复用的费用计算

* [ ] `SimStore` 持久化到 `Documents/Simulation/sim.json`，含 `schemaVersion`；`sim.json` 已存在时不重新播种、不清空用户数据

* [ ] 首次启动播种 3 个示例账户（主策略 / 打板 / 低吸）与示例持仓、委托、成交、资金流水、操作日志

* [ ] 账户之间资金与持仓完全隔离，「全部账户汇总」为只读聚合视图

* [ ] 下单校验：资金不足 / 可卖不足（T+1）/ 非 100 股整数倍 / 超出涨跌停 均被拒绝且不产生任何数据写入，提示文案明确

* [ ] 交易时段外的委托状态为「待报」

* [ ] 撤单、改价、一键撤单、一键清仓都会更新持仓与资金并追加操作日志

* [ ] 账户汇总的总资产 / 可用 / 市值 / 仓位 / 当日盈亏 / 累计盈亏数值与持仓表一致（市值取 `MarketRowCache` 最新价）

* [ ] 跨日后当日买入股份变为可卖（`availableQty` 同步为 `qty`）

## 共享下单组件

* [ ] `TradeTicketView` 支持 `panel` / `bolt` / `full` 三种形态，共用同一套方向、报价类型、价格、数量、仓位、费用预览内核

* [ ] 面板、模拟页底部买卖条、全屏下单页三处入口都走同一套 `SimStore` 校验与写入路径

* [ ] 仓位快捷（1/4、1/3、半仓、全仓）按可用数量换算为 100 股整数倍

* [ ] 提交成功后回调关闭；提交失败展示拒绝原因且界面停留在下单态

## 快捷面板

* [ ] `FloatingAccessoryPanel` 按 `panelLayout` 分发 A/B/C 三套布局

* [ ] 面板高度：A ≈ 屏高 0.67、B ≈ 0.60、C ≈ 0.35，均不超过 660pt

* [ ] 面板底边贴物理屏幕底边，底部无灰色缝隙（保留贪婪 `frame(alignment:.bottom)` + `ignoresSafeArea(edges:.bottom)`）

* [ ] 面板呈现期间两个悬浮按钮隐藏且不响应命中，关闭后原位恢复

* [ ] 详情页态（`DetailRouter.shared.item != nil`）自动带入当前标的的名称 / 代码 / 最新价

* [ ] 列表页态（无标的）显示账户摘要与四个快捷入口，自选行内「买 / 卖」可在面板内原地切到下单卡，不跳页、不关闭面板

* [ ] 面板内下单后，模拟页「当日委托」「持仓」「资金流水」同步出现该笔记录

* [ ] 卖出类操作（一键清仓等）有二次确认

* [ ] `accessory.close` 无障碍标识保留，遮罩点击与「关闭」按钮都能关闭面板

* [ ] 方案 B 三个分段（交易 / 持仓 / 委托）可切换且角标数量正确

* [ ] 方案 C 默认市价、大字号数量控件步进 100 股，「展开」可进入完整下单卡

## 模拟页

* [ ] `SimulationView` 按 `simulationLayout` 分发 A/B/C 三套布局

* [ ] `simulation.subtitle` 无障碍标识仍存在（既有 UITest `test02` 通过）

* [ ] 方案 A：216pt 账户侧栏含「全部账户汇总」与「新建账户」；点账户后资产总览与五张表格即时过滤

* [ ] 方案 A：五模块（持仓 / 当日委托 / 当日成交 / 资金流水 / 操作日志）可切换；操作日志页显示日期范围 / 类型 / 关键词 / 导出工具条

* [ ] 方案 A：持仓表行内「买 / 卖」打开全屏下单页并带入标的与方向；委托表在途行可撤单 / 改价

* [ ] 方案 B：账户卡片横排（含迷你净值 + 新建卡）+ 2×2 模块摘要卡，模块卡「查看全部 →」进入全屏明细

* [ ] 方案 C：顶部下拉可切账户，一行资产指标 + 全宽大表 + 在途委托 / 当日成交两个小卡

* [ ] 三套布局底部都有常驻买入 / 卖出条，点开全屏下单页

* [ ] 模拟页所有元素使用语义化颜色（`Color(.systemBackground)` / `.primary` / `.secondarySystemBackground`），深色模式下可读

## 工程与交付

* [ ] 新增文件全部位于 `Kline/` 目录树内，无需手工改 `project.pbxproj`（依赖 `PBXFileSystemSynchronizedRootGroup`）

* [ ] 阶段一闭环命令返回 0 / 6 / 7，构建通过

* [ ] 阶段二闭环命令返回 0 / 6 / 7，构建通过

* [ ] 交付说明包含本轮 build 号、改动内容与真机验证路径；`git status` 无遗留未提交改动


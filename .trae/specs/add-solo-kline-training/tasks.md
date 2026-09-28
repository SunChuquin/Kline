# Tasks

- [x] Task 1: 训练数据模型与 sqlite 持久化仓库
  - [x] SubTask 1.1: 新增 `Kline/Training/TrainingModels.swift`：`TrainSessionRecord`（id / metaID / code / name / startDate / endDate / tradeCount / status / createdAt / updatedAt）与 `TrainTradeRecord`（id / sessionID / seq / direction / tradeDate / price / qty / amount / fee / pnl / note），以及会话状态枚举（running / finished）
  - [x] SubTask 1.2: 新增 `Kline/Training/TrainingStore.swift`（ObservableObject 单例）：独立串行队列 + 打开并建表 `Documents/Training/training.db`，参照 [LiveDataStore.swift](file:///Volumes/home/repositories/Kline2/Kline/Data/LiveDataStore.swift) 的「open → `CREATE TABLE IF NOT EXISTS` → 队列」三段式；表 `train_session`、`train_trade` 及 `train_trade(session_id)` 索引
  - [x] SubTask 1.3: 仓库 API（全部走串行队列、主线程发布）：`createSession`、`appendTrade`、`finishSession(id:endDate:)`、`sessions`（按 createdAt 倒序）、`trades(sessionID:)`、`deleteSession(id:)`、`deleteAll()`、`refresh()`
  - [x] SubTask 1.4: 编译通过（`xcodebuild` 非沙箱构建）

- [x] Task 2: 训练会话运行时控制器
  - [x] SubTask 2.1: 新增 `Kline/Training/TrainingSessionController.swift`（ObservableObject 单例）：状态 `meta`、`startDate`、`trainingDate`、`latestDate`、`trades`、`isActive`、`isFinished`
  - [x] SubTask 2.2: `begin(meta:startDate:)`：用 `DatabaseManager.fetchDailyData(metaId:)` 取全量日线（升序化）→ 吸附到实际交易日 → 经 `TrainingStore` 建会话落库 → 计算 `latestDate` → 初始化训练日
  - [x] SubTask 2.3: `advanceOneBar()`：训练日推进一根日线（= 一个交易日）；到达 `latestDate` 时自动结束（写库 + `isFinished = true`，`isActive` 保持，页面不关）
  - [x] SubTask 2.4: `close()`：仍 running 则以当前训练日为结束日期落库，然后清空运行时状态（页面随之关闭）
  - [x] SubTask 2.5: 训练持仓派生：`positionQty` / `avgCost` / `currentClose`（日线中 date ≤ trainingDate 的最后一根 close）/ `floatingPnl`
  - [x] SubTask 2.6: `placeTrade(direction:qty:note:)`：整手与可卖数量校验（不做空）→ 取训练价与手续费（`SimTradingRules.default.fee(amount:direction:)`）→ 计算平仓已实现盈亏 → 即时落库 → 更新内存交易与持仓
  - [x] SubTask 2.7: 编译通过

- [x] Task 3: K 线页训练态（右边界锁定 + 中心圆推进 + 禁切标的）
  - [x] SubTask 3.1: [KlineChartView.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/KlineChartView.swift) 新增 `trainingMaxDate: Int?` 参数（默认 nil）；新增 `trainingEndIndex`（用 `nearestIndex(to:)` 求训练日在 `sortedData` 中的索引）、`maxEndIndexUpperBound`，并把 `endIndex` 的**上界**改为 `maxEndIndexUpperBound` —— 这是唯一的右缘闸门（`endIndex` 为只读计算属性，所有渲染与时间轴都走 `startIndex/endIndex`，故各条 `endOffset` 路径无需逐个改钳制上界即可保证不越界）
  - [x] SubTask 3.2: 训练态打开时右缘停在训练起始日：`onAppear` 里 `endOffset = maxEndOffset`；`trainingMaxDate` 变化（及 `sortedData` 长度变化）后若新上界大于当前 `endIndex`，同步 `endOffset = maxEndOffset` 让右缘跟进
  - [x] SubTask 3.3: 训练态下「单击新辅助触控中心圆」改为推进训练日：在**生产端** [FloatingAccessoryWheel.swift](file:///Volumes/home/repositories/Kline2/Kline/App/FloatingAccessoryWheel.swift) 中心圆单击处判断训练态 → 调 `TrainingSessionController.shared.advanceOneBar()`，不再发 `nudgeWindow`（因此不存在多视图重复推进问题）
  - [x] SubTask 3.4: [KlineDetailView.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/KlineDetailView.swift) 新增 `isTraining: Bool = false`（带默认值，不破坏既有调用点）；训练态下在顶部工具栏下方插入训练指示条（标的名称与代码 / 起始日期 / 当前训练日 / 已交易笔数 / 已完成提示，`accessibilityIdentifier("training.indicator")`）
  - [x] SubTask 3.5: 训练态屏蔽「切换标的」入口：[ChartLegendKit.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/ChartLegendKit.swift) 副图二（`.bottom`）的 🔍 搜索按钮在训练态不显示；[ChartGestureHandlers.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/ChartGestureHandlers.swift) 副图二水平滑动切标的在训练态不触发，且 `subSwipeCanLeftRight` 返回 `(false, false)`（不显示滑动提示）；单图与联动每格（[LinkedKlineTile.swift](file:///Volumes/home/repositories/Kline2/Kline/Chart/LinkedKlineTile.swift)）同样处理
  - [x] SubTask 3.6: 训练态保留正常能力（未加任何限制）：副图一水平滑动切周期、K 线设置面板「行情周期」、联动多图（`dualLinkArea` / `LinkedKlineTile` / `LinkedViewStore` 配置）、十字光标与 `linkSync`、「联」「边」按钮、辅助触控转圈、主图拖动与双指缩放
  - [x] SubTask 3.7: 训练态右边界对联动各格生效：`trainingMaxDate` 经 `KlineDetailView` → `LinkedKlineTile` 透传到各格 `KlineChartView`，各格按其自身周期取「日期 ≤ 训练日」的最后一根作为上界
  - [x] SubTask 3.8: 返回结束：训练态点左上角返回时先结束会话（`ContentView` 的 `onClose: { trainer.close() }` 统一处理）
  - [x] SubTask 3.9: 编译通过

- [x] Task 4: 训练下单链路（快捷面板）
  - [x] SubTask 4.1: [TradeTicketView.swift](file:///Volumes/home/repositories/Kline2/Kline/Trading/TradeTicketView.swift) 新增训练分支：训练态下价格来源替换为 `TrainingSessionController.currentClose`，提交改走 `placeTrade`（不调 `store.submit`），可卖数量校验用训练持仓；训练价随 `$trainingDate` 刷新
  - [x] SubTask 4.2: 训练态下快捷面板在**面板层**分流（[FloatingAccessory.swift](file:///Volumes/home/repositories/Kline2/Kline/App/FloatingAccessory.swift) 的 `panelContent`）：训练态渲染 `QuickTrainingPanelView`（训练信息 + 持仓/均价/浮动盈亏 + 复用 `TradeTicketView(.panel)`），不再进入 A/B/C 三档内容 —— 因此账户条 / 模拟持仓 / 资金 / 委托 / 自选等区块天然不会出现，且三档布局的 `onAppear` 副作用不会执行
  - [x] SubTask 4.3: 编译通过

- [x] Task 5: 首页快捷入口 + 训练设置窗
  - [x] SubTask 5.1: [HomePageKit.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomePageKit.swift) 的 `HomeEntryKind` 新增 `training` case（插在 `layoutEditor` 之前），并补全 `title / subtitle / icon / tint / formulaKind` 五个 switch
  - [x] SubTask 5.2: 新增 `Kline/Training/TrainingSetupSheet.swift`：居中卡片浮层 + 半透明遮罩（点遮罩关闭）；分类五选一（全部 / 沪深主板 / ETF 指数 / 自选 / 我的分组，选「我的分组」时再出具体分组）、标的（随机抽取 / 搜索指定）、起始日期（随机 / 指定）、显示已选标的最新库日期与可选区间、开始 / 取消按钮
  - [x] SubTask 5.3: 分类数据源与随机池：全部 = `DatabaseManager.metaList`；沪深主板 = `type == "沪深主板"`；ETF 指数 = `type` 为「沪深京指数」或「扩展行情指数」；自选 = `FavoritesStore.resolveMetaItems(groupID: allGroupID)`；我的分组 = 按所选分组 id 取；随机池过滤掉 `firstDate > (lastDate − 65 天)` 的标的
  - [x] SubTask 5.4: [HomeView.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeView.swift) 的 `perform` 与 [HomeLayoutBView.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeLayoutBView.swift) / [HomeLayoutCView.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeLayoutCView.swift) / [HomeLayoutDView.swift](file:///Volumes/home/repositories/Kline2/Kline/Home/HomeLayoutDView.swift) 的 `perform` 新增 `.training` 分支 → 打开设置窗
  - [x] SubTask 5.5: 点「开始训练」→ 调 `TrainingSessionController.begin(meta:startDate:)`，成功后关闭设置窗，由 `ContentView` 根层呈现训练 K 线页
  - [x] SubTask 5.6: 编译通过

- [x] Task 6: 根呈现训练 K 线页
  - [x] SubTask 6.1: [ContentView.swift](file:///Volumes/home/repositories/Kline2/Kline/App/ContentView.swift) 观察 `TrainingSessionController.shared`，在根 ZStack 呈现训练态 `KlineDetailView(item:isTraining:onClose:)`；训练激活时清空 `DetailRouter.shared.item`（与普通详情页互斥）
  - [x] SubTask 6.2: 悬浮辅助触控按钮与快捷面板的显示条件扩展为「详情页打开 **或** 训练态激活」
  - [x] SubTask 6.3: 关闭训练页的闭包统一执行 `TrainingSessionController.shared.close()`
  - [x] SubTask 6.4: 编译通过

- [x] Task 7: 模拟页入口 + 训练记录管理页
  - [x] SubTask 7.1: 新增 `Kline/Training/TrainingRecordListView.swift`：44pt 三段导航栏（返回 / 标题「训练记录」/ 清空）+ 会话列表（`LazyVStack`，行 = 标的与代码、起止日期、交易笔数、创建时间、状态；右侧 `chevron.right` 看明细 + `trash` 删除）+ 空态 + `confirmationDialog` 二次确认（参照 [AlertRecordView.swift](file:///Volumes/home/repositories/Kline2/Kline/Simulation/AlertRecordView.swift)）
  - [x] SubTask 7.2: 明细视图：该会话每笔交易（序号 / 方向 / 日期 / 价格 / 数量 / 成交额 / 手续费 / 盈亏 / 备注），横向可滚动
  - [x] SubTask 7.3: [SimSharedViews.swift](file:///Volumes/home/repositories/Kline2/Kline/Simulation/SimSharedViews.swift) 新增训练记录入口按钮 `SimTrainingRecordEntryButton` 与独立的 `simTrainingRecordPresentation(_:)`（单个 `fullScreenCover`，避免与条件单入口冲突）
  - [x] SubTask 7.4: 模拟页三档布局（[A](file:///Volumes/home/repositories/Kline2/Kline/Simulation/SimulationLayoutAView.swift) / [B](file:///Volumes/home/repositories/Kline2/Kline/Simulation/SimulationLayoutBView.swift) / [C](file:///Volumes/home/repositories/Kline2/Kline/Simulation/SimulationLayoutCView.swift)）各挂一次入口
  - [x] SubTask 7.5: 编译通过

- [x] Task 8: 构建与设备验证
  - [x] SubTask 8.1: `xcodebuild` 非沙箱**全量 clean build 通过**，且不新增编译警告（除 `appintentsmetadataprocessor` 那条工具日志外 0 warning / 0 error）
  - [x] SubTask 8.2: 安装并启动到当前设备（iPad mini 5 模拟器，库内 3611 只标的 / 约 1400 万根日线，可实测），交付用户按验收清单验证

# Task Dependencies
- Task 2 依赖 Task 1
- Task 3 依赖 Task 2
- Task 4 依赖 Task 2
- Task 5 依赖 Task 2、Task 6（设置窗「开始训练」需要训练页呈现层就绪）
- Task 6 依赖 Task 3
- Task 7 依赖 Task 1
- Task 8 依赖 Task 1 ~ Task 7
- 实际执行顺序：1+2 → （3、4、7 并行）→ 5+6 → 8

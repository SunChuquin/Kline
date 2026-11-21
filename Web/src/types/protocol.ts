// Web↔Swift 桥接协议 v2（**单一事实源**）
// Swift 镜像：Kline/WebBridge/（WebBridgeEnvelope / WebMessageRouter）
// 对拍样例：KlineTests/Fixtures/bridge_protocol.json（解析测试 WebBridgeProtocolTests.swift）
//
// ## 信封
//   请求  { id, module, action, payload }   （Web → Swift，JSON 字符串经 messageHandler 传入）
//   响应  { id, ok, data | error }          （Swift → Web，按 id 配对；注入形态 JSON.parse 对象）
//   事件  { event, payload }                （Swift → Web，Store 变化广播）
//
// ## 写回模式（v2 核心）
//   1. Web 只发「动作」，不持有状态：action → 原生 Store 写入 → 响应 ok；
//   2. 写回动作**不回推快照**——状态变化统一由原生事件链路推送（单一数据流，避免双写竞态）；
//   3. set 类动作幂等（同值写入无害）；Web 端不乐观更新 UI，等事件回推后再变。
//
// ## 错误码表
//   bad_request      信封解析失败（缺 id/module/action）
//   unknown_module   module 未注册
//   unknown_action   action 未实现
//   invalid_payload  payload 字段缺失 / 类型不符
//   store_not_ready  目标 Store 未就绪（预留）
//   internal_error   原生侧意外失败（预留）
//
// ## 动作清单 v2（module.action）
//   app.ping          {clientTs} → {clientTs, serverMs}      延迟探针
//   app.reportRtt     {rttMs} → {}                           页面实测 RTT 落日志
//   app.memory        {} → {footprintMB}                     内存足迹（phys_footprint）
//   app.info          {} → {version, build}                  版本信息
//   app.jsdiag        {hasWindowBus, hasWebkitHandler} → {}  页面环境自报（排障）
//   app.jsError       {message, source?, line?} → {}         页面全局 JS 异常回报
//   theme.get         {} → {preference, mode}                主题读取（mode = 解析后实际外观）
//   theme.set         {preference} → {preference}            主题写回（v2 首个写回动作，幂等）
//   profile.snapshot  {} → ProfileSnapshot                   个人中心只读快照
//   nav.switchTab     {index} → {}                           Web 请求切 Tab（原生底栏 selectedTab；P2-0 stub、P2-1 接实装）
//   favorites.snapshot {} → FavoritesSnapshot                自选页快照（分组结构 + 行情行）
//   favorites.refresh  {group?} → {queued, count}            手动刷新（异步，完成推 favorites.changed）
//   favorites.openDetail {file} → {}                         进原生 K 线详情（DetailRouter）
//   favorites.setNote  {file, note} → {}                     备注写回（幂等；空串 = 删除）
//   favorites.setPinned {file, pinned, group?} → {}          固顶写回（幂等；「全部」虚拟分组显式报错）
//   favorites.moveTo   {file, where, group?} → {}            手动分组内移到最前/最后
//   favorites.removeFromGroup {file, group?} → {}            从手动分组移除
//   market.snapshot    {} → MarketSnapshot                   行情页快照（分类/渲染列/排序筛选后行，字段按可见列裁剪）
//   market.select      {menu?, second?} → {}                 切一级/二级分类（原生写状态 + scheduleRefresh）
//   market.refresh     {} → {queued, count}                  触发 scheduleRefresh（预取置顶优先）
//   market.openDetail  {file} → {}                           进原生 K 线详情（同 favorites.openDetail）
//   market.openSearch  {} → {}                               桥接原生全屏搜索页（HomeView 搜索模式）
//   market.openFormulaCenter {} → {}                         桥接原生公式管理中心（选股 Tab 入口）
//   market.groupInfo   {file} → {isFav, groups}              加自选浮层拉取（手动分组列表 + 成员态）
//   market.setFavorite {file, fav} → {}                      一键加/取消自选（目标态语义，幂等）
//   market.setInGroup  {file, groupID, member} → {}          加/移出手动分组（目标态语义，幂等）
//   market.createGroup {name} → {id}                         新建自定义分组
//   market.sortToggle  {field} → {}                          点击表头三击循环排序（降→升→取消）
//   market.configSnapshot {} → MarketConfigSnapshot          列配置快照（全部可配置列 + 排序 + 冻结数 + 筛选档）
//   market.configSet   {columns, sortRule?, frozenCount} → {} 整页配置写回（草稿提交，幂等）
//   market.configReset {} → {}                               恢复默认列配置
//   home.snapshot      {} → HomeSnapshot                     首页快照（入口清单/指数行/涨跌家数/自选Top5/模拟摘要/涨幅榜Top5）
//   home.openEntry     {kind} → {}                           快捷入口桥接（search/公式分段/条件单/训练/个人中心…；layoutEditor 退役不注册）
//   home.openDetail    {file, context?} → {}                 进 K 线详情（context = 副图左右切换上下文的 file 列表）
//   sim.snapshot       {} → SimSnapshot                      模拟页快照（账户/摘要/净值/持仓/委托/成交/流水/日志，时间字符串原生格式化）
//   sim.selectAccount  {accountID|null} → {}                 切换统计/下单账户（null = 全部账户汇总）
//   sim.selectModule   {module} → {}                         切业务模块（position/order/fill/cash/log）
//   sim.createAccount  {name, capital} → {toast}             新建模拟账户（引擎侧开户，失败 fail）
//   sim.cancelOrder    {orderID} → {}                        撤销在途委托（幂等目标态）
//   sim.amendPrice     {orderID, price} → {toast}            修改委托价（限价委托）
//   sim.refreshQuotes  {} → {toast}                          请求最新行情（prepareQuotes）
//   sim.openTicket     {direction, positionID?} → {}         桥接原生全屏下单页（带持仓入口预填；账户/标的不可用 fail）
//   sim.openCondEditor {positionID} → {}                     桥接原生条件单编辑器（异步组装可卖数量后呈现）
//   sim.openCondManage {} → {}                               桥接原生条件单管理页
//   sim.openStrategyFormulas {} → {}                         桥接原生公式管理中心（交易策略段）
//   sim.openTrainingRecords {} → {}                          桥接原生训练记录管理页
//   sim.exportLogs     {keyword, logModule?} → {toast}       导出操作日志 CSV（Documents/Simulation/）
//   sheet.close        {} → {}                               Web 弹层请求关闭（Swift 侧移除浮层遮罩并回写宿主弹层状态）
//   sheet.ready        {} → {}                               浮层 WebView 就绪拉取（补推 sheet.open——首次打开时事件早于 WebView 就绪会丢失）
//   chart.settings.snapshot {} → ChartSettingsSnapshot      K线设置快照（周期/类型/联动视图数/显示组/裸K/指标组合模式）
//   chart.settings.set {period?, chartStyle?, linkedViewCount?, showGap?, ..., activeMode?} → {} 设置写回（幂等目标态，即时生效图表）
//   chart.settings.resetLinked {} → {}                       重置当前标的联动视图配置
//   chart.search.query {keyword} → {results}                 图表搜索（DatabaseManager.searchMeta 同口径）
//   chart.search.pick  {file} → {}                           选中搜索结果（KlineDetailView 切标的并重新加载）
//   chart.indicators.snapshot {} → IndicatorsSnapshot         指标面板快照（主图指标/主图自定义/三副图槽位分组/自定义）
//   chart.indicators.toggleMain {id, on} → {}                主图指标开关（目标态，幂等）
//   chart.indicators.selectSub {slot, kind?|customID?} → {}  副图槽位选择（二选一；写回并重算）
//   chart.indicators.activateMainCustom {customID|null} → {} 激活/取消主图自定义指标
//   chart.indicators.resetBuiltin {} → {}                    重置内置指标（restoreAllBuiltin）
//   chart.indicators.openSystemEditor {isMain, subId?} → {}  关面板 + 桥接原生系统指标公式编辑器
//   chart.indicators.openCustomEditor {target} → {}          关面板 + 桥接原生自定义指标编辑器
//   preset.snapshot {} → PresetSnapshot                       指标组合快照（生效模式 + 五套组合完整按周期配置）
//   preset.setMode {id} → {}                                  切换生效组合（"local"=局部独立配置 / "p1".."p5"；幂等；图表即时重算）
//   preset.editCommit {presets:[5套]} → {}                    组合编辑页整包提交（生效中组合被改即重算）
//   chart.formula.snapshot {} → FormulaSnapshot                          tech 段三节快照（系统主图/副图分组/自定义）
//   chart.formula.deleteCustom {id} → {}                                 删除自定义指标
//   chart.formula.openCenter {} → {}                                     （回退链路）关面板 + 桥接原生公式中心
//   chart.formula.openEditor {target:"system", id, isMain?} | {target:"custom", id?} → {}
//                                                                        关面板 + 打开 Web 编辑器全屏页（id 缺省 custom = 新建）
//   formulaEdit.snapshot {} → FormulaEditSnapshot                        编辑器快照（system/custom(new|edit) 三形态；palette/colorHex）
//   formulaEdit.test {formula} → {queued}                                测试公式（异步求值，结果随 formulaEdit.changed(testResult) 推送）
//   formulaEdit.save {formula, name?, scope?, colorHex?, periods?} → {}  保存（system 写回 .tdx；custom 全量写回；成功即关页）
//   formulaEdit.restoreBuiltin {} → {formula}                            恢复编译时内容（仅系统指标；同步返回恢复后公式）
//   strategyEdit.snapshot {} → StrategyEditorSnapshot                    策略编辑器快照（doc 结构化 rows + 选股公式库 + 账户 + 规则目录）
//   strategyEdit.evaluate {doc, pickSyntaxError} → StrategyEvaluateResult 静态校验 + 语义预览（纯 Swift 同步直通）
//   strategyEdit.testPick {pickBody} → {queued}                          内嵌公式试算（异步，结果随 strategyEdit.changed(pickTest) 推送）
//   strategyEdit.save {doc, pickSyntaxError} → {queued}                  保存（静态校验先同步 fail；后台引擎终校 + 写库，结果随 changed(saveResult) 推送）
//   pickerEdit.snapshot {} → PickerEditSnapshot                          选股公式编辑快照（id/name/pickBody/hasData）
//   pickerEdit.testPick {pickBody} → {queued}                            公式试算（异步，结果随 pickerEdit.changed(pickTest) 推送）
//   pickerEdit.save {id, name, pickBody} → {id}                          保存（同步写库；名称非空校验；成功即关页；id 空串 = 新建）
//   strategyDetail.snapshot {} → StrategyDetailSnapshot                  策略详情快照（基础信息同步直出 + 一次性 toast；引擎取值经 changed(values) 推送）
//   strategyDetail.edit {} → {}                                          跳策略编辑器（Web 页内切 strategyEditor）
//   strategyDetail.backtest {} → {}                                      跳回测（Web 页内切 backtest，复用 backtest.* 页）
//   strategyDetail.runPick {pool} → {queued}                             跑选股（pool: market|favorites；进度/命中随 changed(pickPhase/pickHits) 推送）
//   strategyDetail.cancelPick {} → {}                                    取消跑选股（幂等）
//   strategyDetail.generate {metaIDs, includeEntry?} → {queued}          组装生成草稿（引擎校验；结果随 changed(genConfirm) 推送，文案占位→就绪重推）
//   strategyDetail.toggleEntry {includeEntry} → {queued}                 切换入场单开关重新组装（原生 recompute 同款）
//   strategyDetail.confirmGenerate {} → {queued}                         确认写入（成功暂存 toast 并切回 strategyDetail；失败 changed(genResult)）
//   ticket.snapshot {} → TicketSnapshot                                  全屏下单页票面快照（账户/标的/最新价/持仓/费率常量集；提交复用 trade.submit）
//   cond.list {} → CondListSnapshot                                      条件单管理页快照（三分段行卡片 + 投影文案；占位→就绪经 cond.changed(texts) 重推）
//   cond.editorContext {} → CondEditorContext                            编辑器上下文（draft 走 SimCondOrder 原生 JSON 口径 iso8601）
//   cond.evaluate {draft} → {queued}                                     引擎建单校验 + 文案投影（结果随 cond.changed(evaluate) 推送）
//   cond.save {draft} → {queued}                                         保存（引擎终校 fail-closed；成功切回管理页）
//   cond.cancel {id} → {}                                                撤销监控中单据（status → cancelled）
//   cond.edit {id} → {}                                                  管理页编辑 → 切编辑器页
//   cond.new {} → {}                                                     管理页新建 → 切编辑器页
//   search.query {keyword} → {results}                                   搜索页模糊搜索（searchMeta 同口径）
//   search.openDetail {file} → {}                                        选中结果进 K 线详情（关搜索页）
//   page.open {name} → {}                                                Web 页内切换另一全屏页（个人中心 → 本地更新等同 WebView 切换）
//   （testPage：测试页——纯静态 mock 演示复刻，零业务动作；模拟 Tab 双击入口改桥，无独立协议动作）
//   quick.snapshot {} → QuickSnapshot                        快捷面板快照（悬浮球；列表态/详情态/票面态三视图）
//   quick.selectAccount {accountID|null} → {}                切换账户（面板内 chips）
//   quick.pickTicket {file, direction} → {}                  列表态自选行买/卖 → 面板内切票面
//   quick.backToList {} → {}                                 票面态返回列表态
//   quick.cancelAll {} → {count}                             一键撤单（当前账户口径）
//   quick.closeAll {} → {count}                              一键清仓（详情标的）
//   trade.submit {accountID, metaID, direction, priceType, price?, qty} → {orderID}
//                                                            下单提交（SimStore.submit 精确校验，拒绝 fail 返回中文文案）
//   page.close        {} → {}                               Web 请求关闭全屏 Web 页（busy 时 fail 拒绝）
//   page.ready        {} → {}                               全屏页 WebView 就绪拉取（补推 page.open——首次打开时事件早于 WebView 就绪会丢失）
//   lan.snapshot      {} → LANSSnapshot                     联机同步快照（本机服务/暴露/扫描/对端/传输进度/配置数据；文案原生格式化）
//   lan.probe         {} → {}                               本机服务真实探测（异步，结果随 lan.changed 推送）
//   lan.setExposed    {on} → {}                             暴露开关（开=发布广播+授权；关=停止+吊销全部会话 token）
//   lan.scan          {} → {}                               扫描一次（约 4s 窗口，结果进快照）
//   lan.connect       {peerId?|address?} → {}               连接对端取 /sync/status（成功进配置页；失败 fail 中文文案）
//   lan.start         {selections:[{category, mode, childKeys?}]} → {}
//                                                           发起拉取（mode: all|children；phase/progress 随 lan.changed 推送）
//   update.snapshot   {} → UpdateSnapshot                   本地更新快照（服务/App 行/引擎行/清单自动更新/补缺口/基准缺失）
//   update.probeServer {} → {}                              在线服务探测（异步）
//   update.reconnectServer {} → {}                          强制重建监听并复探
//   update.checkApp   {} → {}                               检查 App 新版（GitHub Release）
//   update.installApp {} → {}                               归档旧 IPA + 下载最新 + 拉起 TrollStore 安装
//   update.checkEngine {} → {}                              检查引擎包新版（引擎 Release 固定 tag）
//   update.installEngine {} → {}                            下载引擎 .tipa（双校验）+ 拉起 TrollStore 安装
//   update.syncNow    {} → {}                               清单标的立即更新（设备侧腾讯直连）
//   update.runGapBackfill {} → {}                           补一次缺口（主库最新日 → 今天）
//   update.queryBaselineMissing {} → {}                     查询基准缺失名单（结果随 update.changed(baselineReady) 进快照）
//   lab.snapshot      {} → LabSnapshot                      Python 引擎实验室快照（引擎状态/操作/输出行）
//   lab.refresh       {} → LabSnapshot                      刷新引擎状态（响应直接带快照）
//   lab.download      {} → {}                               下载引擎包 .tipa（sha256 校验）
//   lab.install       {} → {}                               拉起 TrollStore 安装引擎
//   lab.loadEngine    {} → {}                               进程内 dlopen+Py_Initialize 计时加载
//   lab.runExp        {id: 1..4} → {}                       实验①-④（脚本/编排逻辑在桥内，输出行随 lab.changed 推送）
//   lab.cleanDownloads {} → {}                              清理已下载 tipa（Engine.app 由 TrollStore 管理）
//   lab.exportCrash   {} → {}                               导出崩溃报告到 Documents/crashlogs
//   backtest.snapshot {} → BacktestSnapshot                 回测快照（当前策略文档/执行 phase/进度/结果全量；策略详情页「回测」入口打开）
//   backtest.run      {days, initialCapital, pool, executeNextOpen, includeEntry} → {queued}
//                                                           发起回测（pool: market|favorites；period 固定日线；单任务，重跑先失效旧轮）
//   backtest.cancel   {} → {}                               取消回测（幂等；cancelled 后 Web 自动关页回策略详情，对齐原生）
//   training.setup.snapshot {} → TrainingSetupSnapshot       训练设置浮层快照（上次偏好 + 自选分组清单）
//   training.setPrefs  {accountType?, capitalText?, tradeMode?} → {}   偏好写回（幂等，对齐原生 @AppStorage 持久化）
//   training.search    {keyword} → {results}                 标的搜索（searchMeta 同口径，最多 20 条，带可训练标记）
//   training.pickRandom {category, groupID?, accountType, capital?} → {file, name, code, startDate}
//                                                           随机抽取（可训练池内；金额账户只在「2 手买得起」的标的里挑，引擎预检）
//   training.anchor    {file} → {minDate, maxDate, trainable}  选中标的的日期区间与可训练性（firstDate ~ 最新库日-65 天）
//   training.begin     {file, startDate, accountType, capital?, tradeMode} → {queued}
//                                                           开始训练（金额账户原生预检 2 手可买；结果经 changed 推送：
//                                                           begun=已开训→Web 关面板进训练态；beginFailed/beginReselect=文案）
//   training.records.snapshot {} → TrainingRecordsSnapshot  训练记录快照（会话列表倒序）
//   training.recordDetail {id} → TrainingRecordDetail       单会话明细（成交/条件单/预警；条件单文案经引擎投影，未就绪为占位）
//   training.deleteRecord {id} → {}                         删除单条训练记录
//   training.clearRecords {} → {}                           清空全部训练记录
//
// ## 事件清单 v2
//   theme.changed     {preference, mode}   主题偏好或系统外观变化（theme.set 后亦经此链路回推）
//   app.memory        {footprintMB}        页面就绪后一次
//   favorites.changed {reason}             自选数据/编辑变化（reason: refresh|edit）
//   market.changed    {reason}             行情数据/分类/配置变化（reason: data|config|edit；节流 ~0.8s 合并）
//   home.changed      {reason}             首页快照数据变化（reason: data|edit|sim；节流 ~0.8s 合并）
//   sim.changed       {reason}             模拟页快照数据变化（reason: data|trade；节流 ~0.8s 合并）
//   sheet.open        {name}               弹层打开指令（Swift→Web 弹层浮层 WebView，路由到对应面板）
//   page.open         {name}               全屏 Web 页打开指令（Swift→Web，route:"page" 定向推送）
//   lan.changed       {reason}             联机同步状态变化（reason: data|scan|connect|transfer|mainDBReplaced…）
//   update.changed    {reason}             本地更新状态变化（reason: server|remote|engine|watchlist|gap|baselineReady）
//   lab.changed       {reason}             引擎实验室状态/输出变化（reason: status|output|progress；节流 ~0.2s 合并）
//   backtest.changed  {reason}             回测 phase/进度变化（reason: phase|progress；节流 ~0.25s 合并）
//   training.changed  {reason}             训练状态变化（reason: begun|beginFailed|beginReselect|records|projection）
//   formulaEdit.changed {reason}           公式编辑器异步结果（reason: testResult|dataReady；route:"page" 定向推送）
//   strategyEdit.changed {reason}          策略编辑器异步结果（reason: pickTest|saveResult|dataReady；route:"page" 定向推送）
//   pickerEdit.changed {reason}            选股公式编辑器异步结果（reason: pickTest|dataReady；route:"page" 定向推送）
//   strategyDetail.changed {reason}        策略详情异步结果（reason: values|pickPhase|pickHits|genConfirm|genResult；route:"page" 定向推送）
//   cond.changed {reason}                  条件单异步结果（reason: evaluate|saveResult|list|texts|newFailed；route:"page" 定向推送）
//   preset.changed {reason}                指标组合变化（reason: mode|presets；route:"sheet" 定向推送）
//
// ## 预留（后续批次扩展，本版未实现；形状见 fixtures reserved 区块）
//   sheet.open / sheet.close …（P2-5 图表弹层浮层容器）
//   chart.settings.snapshot / chart.indicators.snapshot …（P2-5 图表弹层快照通道）

export interface BridgeRequest {
  id: string
  module: string
  action: string
  payload?: Record<string, unknown>
}

export interface BridgeError {
  code: string
  message: string
}

export interface BridgeResponse {
  id: string
  ok: boolean
  data?: Record<string, unknown>
  error?: BridgeError
}

export interface BridgeEvent {
  event: string
  payload?: Record<string, unknown>
}

export interface ProfileSnapshot {
  version: string
  build: string
  syncEnabled: boolean
  scheduleTimes: string[]
  tradingDaysOnly: boolean
  dbLoaded: boolean
}

/** market.snapshot 单行：数值按可见列裁剪（field key = MarketField.rawValue），无值 null */
export interface MarketRowSnapshot {
  file: string
  code: string
  name: string
  /** 一键自选标记（FavoritesStore.isFavorited） */
  fav: boolean
  /** 行情页全局固顶（置顶分区 + 浅灰背景） */
  pinned: boolean
  /** 着色基准：涨跌幅数值（可见列不含 changePct 时也恒发） */
  pct: number | null
  /** 可见列数值（不含 code/name——单独扁平字段） */
  values: Record<string, number | null>
}

/** market.snapshot 渲染列（相邻代码/名称已合并为双行单元格，field=name） */
export interface MarketColumn {
  field: string
  isNameCode: boolean
  title: string
  width: number
}

/** market.configSnapshot 单列（全部可配置列，含隐藏） */
export interface MarketConfigColumn {
  field: string
  title: string
  /** 固定列（代码/名称）：恒置顶恒可见，面板只展示不给开关 */
  fixed: boolean
  visible: boolean
  /** 用户覆盖列宽；null = 跟随默认宽 */
  widthOverride: number | null
  filterLabels: string[]
  /** 范围筛选档 label 列表；null = 该字段不支持筛选 */
  filterOptions: string[] | null
}

/** home.snapshot 快捷入口（Web 版裁掉 layoutEditor——布局编辑器随 JSON 布局引擎退役） */
export interface HomeEntry {
  id: string
  title: string
  subtitle: string
  /** 语义色 hex（对齐原生 HomeEntryKind.tint） */
  tint: string
}

/** home.snapshot 指数行 / 自选行 / 涨幅榜行的公共形状（未就绪数值为 null） */
export interface HomeQuote {
  file: string
  code: string
  name: string
  price: number | null
  pct: number | null
}

/** home.snapshot 自选行（closes = 迷你走势最近 20 根收盘价） */
export interface HomeFavQuote extends HomeQuote {
  closes: number[]
}

/** home.snapshot 模拟账户摘要（金额口径与 SimStore.SimAccountSummary 一致） */
export interface HomeSimSummary {
  totalAssets: number
  dayProfit: number
  dayProfitPct: number
  positionPct: number
}

/** home.snapshot 模拟持仓行 */
export interface HomeSimPosition {
  code: string
  name: string
  lastPrice: number
  profit: number
  profitPct: number
}

/** home.snapshot 涨跌家数（nil = 尚无有效聚合，界面显示加载中） */
export interface HomeBreadth {
  up: number
  down: number
  flat: number
  limitUp: number
  limitDown: number
}

/** sim.snapshot 账户项（badge 单字图标 / colorHex 单字底色，对齐 SimAccount） */
export interface SimAccountSnap {
  id: string
  name: string
  badge: string
  colorHex: string
}

/** sim.snapshot 资产摘要（口径与 SimStore.SimAccountSummary 一致） */
export interface SimSummarySnap {
  totalAssets: number
  cash: number
  marketValue: number
  positionPct: number
  dayProfit: number
  dayProfitPct: number
  totalProfit: number
  totalProfitPct: number
}

/** sim.snapshot 持仓行（lastPrice 引擎快照缺失时原生回落成本价） */
export interface SimPositionSnap {
  id: string
  code: string
  name: string
  qty: number
  availableQty: number
  costPrice: number
  lastPrice: number
  marketValue: number
  profit: number
  profitPct: number
}

/** sim.snapshot 委托行（时间字符串原生格式化；price null = 市价单） */
export interface SimOrderSnap {
  id: string
  time: string
  code: string
  name: string
  direction: 'buy' | 'sell'
  priceType: 'limit' | 'market'
  price: number | null
  qty: number
  filledQty: number
  status: 'pending' | 'reported' | 'partial' | 'filled' | 'cancelled'
  active: boolean
}

/** sim.snapshot 成交行 */
export interface SimFillSnap {
  id: string
  time: string
  code: string
  name: string
  direction: 'buy' | 'sell'
  price: number
  qty: number
  amount: number
  fee: number
  contract: string
}

/** sim.snapshot 资金流水行（amount 有符号：入金为正、买入为负） */
export interface SimLedgerSnap {
  id: string
  time: string
  kind: string
  note: string
  amount: number
  balance: number
  accountName: string
}

/** sim.snapshot 操作日志行（result 配色由 Web 端按关键词判定，对齐原生 simResultColor） */
export interface SimLogSnap {
  id: string
  time: string
  accountName: string
  module: string
  content: string
  result: string
}

/** chart.settings.snapshot：选项列表项（label 原生文案） */
export interface ChartOption {
  value: string
  label: string
}

/** chart.settings.snapshot 响应（P2-5 弹层三件套之 K线设置页） */
export interface ChartSettingsSnapshot {
  period: string
  periodOptions: ChartOption[]
  chartStyle: string
  styleOptions: ChartOption[]
  linkedViewCount: number
  viewCountOptions: ChartOption[]
  showGap: boolean
  gapDisappearAfterFill: boolean
  showLatestPriceLine: boolean
  indicatorNotSqueezeKline: boolean
  showBareK: boolean
  /** 指标组合：当前生效模式（"local"=局部独立配置 / "p1".."p5"） */
  activeMode: string
  /** 指标组合下拉选项（第一项恒为局部独立配置） */
  presetOptions: ChartOption[]
}

// ===== 指标组合（preset） =====

/** preset.snapshot 组合条目（按周期记录启用集合；不含参数——参数保持全局） */
export interface ChartPresetSnap {
  /** 固定槽位 "p1".."p5" */
  id: string
  name: string
  /** period rawValue（如"日线"）→ 主图启用指标 id 列表（缺 key = 默认 MA+CMK） */
  mainIndicatorsByPeriod: Record<string, string[]>
  /** period rawValue → 主图自定义指标 uuidString（缺 key = 无） */
  activeCustomByPeriod: Record<string, string>
  /** period rawValue → 三副图选择（缺 key 或数量≠3 = 默认 CDJ/COL/MACD） */
  subSelectionsByPeriod: Record<string, { kind: string; customID: string }[]>
}

/** preset.snapshot 响应（设置面板下拉 + 组合编辑页） */
export interface PresetSnapshot {
  /** 当前生效模式："local" / "p1".."p5" */
  mode: string
  modeOptions: ChartOption[]
  presets: ChartPresetSnap[]
}

/** chart.search.query 结果行 */
export interface ChartSearchResult {
  file: string
  code: string
  name: string
  type: string
}

/** chart.indicators.snapshot：主图指标项（on = 是否启用） */
export interface IndicatorDefSnap {
  id: string
  name: string
  on: boolean
}

/** chart.indicators.snapshot：自定义指标项（active = 当前是否激活） */
export interface CustomIndicatorSnap {
  id: string
  name: string
  colorHex: string
  active: boolean
}

/** chart.indicators.snapshot：副图槽位（groups 顺序对齐原生 subGroupOrder） */
export interface SubSlotSnap {
  slot: 'top' | 'bottom' | 'third'
  title: string
  /** 当前选中系统指标（isCustom 时为 null） */
  kind: string | null
  customID: string | null
  /** 当前选中指标是否可公式编辑（VOL/AMO 无模板不可） */
  hasTemplate: boolean
  groups: { group: string; kinds: string[] }[]
  customs: CustomIndicatorSnap[]
}

/** chart.indicators.snapshot 响应（P2-5b 指标控制面板） */
export interface IndicatorsSnapshot {
  period: string
  mainDefs: IndicatorDefSnap[]
  mainCustoms: CustomIndicatorSnap[]
  subSlots: SubSlotSnap[]
}

// ===== P2-6c-1 全屏 Web 页三件套（lan / update / lab） =====

/** lan.snapshot 对端设备行 */
export interface LANPeerSnap {
  id: string
  name: string
  host: string
  port: number
}

/** lan.snapshot 传输引擎状态（phase/progress 由原生 LANSyncTransfer 发布） */
export interface LANTransferSnap {
  phase: 'idle' | 'pairing' | 'transferring' | 'done' | 'failed'
  progress: number
  bytesPerSecond: number
  currentFile: string
  resultSummary: string
  backupDir: string | null
  needsRestart: boolean
  /** phase=failed 时的错误文案；其余为 null */
  failMessage: string | null
}

/** lan.snapshot 类别行（本机量 vs 对端量 / 子项数量文案原生格式化） */
export interface LANCategorySnap {
  key: string
  title: string
  localSummary: string
  remoteSummary: string
  /** 对端提供细粒度子项时为 true（显示展开箭头；旧版对端/整类类别 false） */
  hasChildren: boolean
  children: { key: string; name: string; quantity: string }[]
}

/** lan.snapshot 响应（P2-6c-1 联机同步页；configure 仅连接成功后非空） */
export interface LANSSnapshot {
  serverOnline: boolean
  probing: boolean
  port: number
  deviceName: string
  isExposed: boolean
  isBrowsing: boolean
  connecting: boolean
  peers: LANPeerSnap[]
  /** 传输引擎 busy（pairing/transferring）——期间禁止关闭页面 */
  busy: boolean
  transfer: LANTransferSnap
  configure: {
    peer: { name: string; host: string; port: number; appVersion: string }
    categories: LANCategorySnap[]
  } | null
}

/** update.snapshot 远程更新行（App 行 / 引擎行同构；state 机语义对齐原生 RemoteState） */
export interface UpdateRowSnap {
  state: 'idle' | 'checking' | 'latest' | 'outdated' | 'downloading' | 'failed'
  remoteBuild: number | null
  currentBuild: number | null
  /** 下载进度 0~100（downloading 态显示在圆圈里） */
  percent: number
  /** 行标题原生拼接（如「检查新版（最新#630 当前 #626）」） */
  title: string
}

/** update.snapshot 响应（P2-6c-1 本地更新页） */
export interface UpdateSnapshot {
  server: { ok: boolean; probing: boolean }
  app: UpdateRowSnap
  engine: UpdateRowSnap
  watchlist: {
    enabled: boolean
    isRunning: boolean
    stateText: string
    stateTone: 'gray' | 'yellow' | 'green' | 'red'
    lastResultText: string
    unionCount: number
    requestText: string
    lastTradeDate: string
    /** 各时刻最近结果（title 自带「盘中快照/收盘」语义标注，原生判定） */
    slots: { time: string; title: string; value: string }[]
    note: string
  }
  gap: {
    statusText: string
    coverageText: string
    baselineText: string
    baselineStale: boolean
    fetchText: string
    verdictText: string
    isRunning: boolean
    /** 基准缺失名单查询中（行图标转圈） */
    baselineLoading: boolean
    detailLines: string[]
  }
  /** 基准缺失名单（queryBaselineMissing 成功后非空，reason=baselineReady 通知） */
  baseline: {
    mainLatest: number
    items: { name: string; code: string; file: string; cause: string }[]
  } | null
}

/** lab.snapshot 响应（P2-6c-1 Python 引擎实验室） */
export interface LabSnapshot {
  status: 'notInstalled' | 'installed' | 'versionMismatch' | 'corrupted'
  /** versionMismatch 时的 api 版本；其余 null */
  apiVersion: number | null
  /** 状态行文案（原生拼接，含修复指引） */
  statusText: string
  source: string
  appPath: string
  manifest: string
  isLoaded: boolean
  isBusy: boolean
  busyText: string
  /** 下载进度 0~100 */
  downloadPercent: number
  /** 当前运行中的实验编号（0 = 空闲） */
  runningExp: number
  outputLines: string[]
}

// ===== P2-6c-2 回测（backtest） =====

/** backtest.snapshot 当前被回测的策略文档（「回测」入口打开时写入） */
export interface BacktestDocSnap {
  id: string
  name: string
  /** TRADE 段未配置（结果页只提示不阻断，语义同原生） */
  tradeEmpty: boolean
  /** 参数页默认初始资金（绑定账户初始资金，取不到 100000） */
  defaultCapital: number
}

/** backtest.snapshot 净值点（date = YYYYMMDD） */
export interface BacktestEquitySnap {
  date: number
  equity: number
}

/** backtest.snapshot 一笔成交（数值原样，Web 端按 SimFormat 语义格式化） */
export interface BacktestTradeSnap {
  /** 成交日（YYYYMMDD） */
  date: number
  name: string
  code: string
  direction: 'buy' | 'sell'
  /** 触发规则文案；入场信号为 null */
  rule: string | null
  qty: number
  price: number
  amount: number
  fee: number
  /** 已实现净盈亏（仅卖出，已扣卖出费用）；未平仓为 null */
  realizedPnL: number | null
  /** 持有自然日（仅卖出）；未平仓为 null */
  holdDays: number | null
}

/** backtest.snapshot 统计指标（比率字段为小数：0.15 = +15%） */
export interface BacktestStatsSnap {
  initialCapital: number
  finalEquity: number
  totalReturn: number
  annualized: number
  /** 0...1 */
  winRate: number
  /** Σ盈利 / |Σ亏损| */
  profitFactor: number
  /** 0...1（结果页展示取负值） */
  maxDrawdown: number
  tradeCount: number
  roundTrips: number
  avgHoldDays: number
}

/** backtest.snapshot 回测结果（finished 时非空；equity/trades 全量下发，Web 端折叠展示） */
export interface BacktestResultSnap {
  stats: BacktestStatsSnap
  equity: BacktestEquitySnap[]
  /** 最大回撤区间（equity 数组下标闭区间，画图高亮用）；null = 无 */
  maxDrawdownRange: [number, number] | null
  trades: BacktestTradeSnap[]
  scannedCount: number
  hitCount: number
  /** 未来函数 / 跳空可疑 / 口径说明 */
  warnings: string[]
  /** 取数失败等跳过明细 */
  skipped: string[]
}

/** backtest.snapshot 响应（P2-6c-2 回测页；phase/result 由 StrategyBacktestRunner 发布） */
export interface BacktestSnapshot {
  doc: BacktestDocSnap | null
  phase: 'idle' | 'preparing' | 'simulating' | 'finished' | 'cancelled' | 'failed'
  /** preparing 阶段进度（done/total）；其余 phase 为 null */
  progress: { done: number; total: number } | null
  /** failed 时的错误文案 */
  failMessage: string | null
  result: BacktestResultSnap | null
}

// ===== P2-6c-3 训练（training） =====

/** training.setup.snapshot 偏好（上次选择持久化，对齐原生 @AppStorage） */
export interface TrainingPrefsSnap {
  accountType: 'percent' | 'fixedAmount'
  capitalText: string
  tradeMode: 'sameDayClose' | 'nextDayClose'
}

/** training.setup.snapshot 响应（训练设置浮层） */
export interface TrainingSetupSnapshot {
  prefs: TrainingPrefsSnap
  /** 自选手动分组清单（「我的分组」分类 chips） */
  groups: { id: string; name: string }[]
}

/** training.search 结果行（trainable = firstDate ≤ 最新库日-65 天，可开训） */
export interface TrainingSearchResult {
  file: string
  name: string
  code: string
  trainable: boolean
}

/** training.pickRandom 成功结果（startDate = YYYYMMDD，实际交易日由 begin 吸附） */
export interface TrainingPickResult {
  file: string
  name: string
  code: string
  startDate: number
}

/** training.anchor 响应（选中标的的日期区间，自然日随机在此区间内做） */
export interface TrainingAnchorResult {
  minDate: number | null
  maxDate: number | null
  trainable: boolean
}

/** training.records.snapshot 会话行（日期格式化在 Web 端做 YYYYMMDD→YYYY-MM-DD） */
export interface TrainingSessionSnap {
  id: string
  name: string
  code: string
  startDate: number
  endDate: number | null
  tradeCount: number
  status: 'running' | 'finished'
  /** 创建时间文案（原生格式化 yyyy-MM-dd HH:mm） */
  createdAtText: string
}

/** training.records.snapshot 响应 */
export interface TrainingRecordsSnapshot {
  sessions: TrainingSessionSnap[]
}

/** training.recordDetail 成交行（数值原样；pnl 仅卖出非空） */
export interface TrainingTradeSnap {
  seq: number
  direction: 'buy' | 'sell'
  /** B / S / T（做 T） */
  mark: 'B' | 'S' | 'T'
  tradeDate: number
  price: number
  qty: number
  amount: number
  fee: number
  pnl: number | null
  /** 触发来源文案（手动 / 条件单·类型，原生拼好） */
  triggerText: string
  note: string
}

/** training.recordDetail 条件单行（summary/validity 经引擎投影，未就绪为「…」占位） */
export interface TrainingCondSnap {
  kindTitle: string
  statusTitle: string
  alertOnly: boolean
  createdDate: number
  summary: string
  validity: string
  lastMessage: string
}

/** training.recordDetail 预警行 */
export interface TrainingAlertSnap {
  tradeDate: number
  price: number
  message: string
}

/** training.recordDetail 响应 */
export interface TrainingRecordDetail {
  session: TrainingSessionSnap
  trades: TrainingTradeSnap[]
  conds: TrainingCondSnap[]
  alerts: TrainingAlertSnap[]
}

// ===== P2-8a tech 公式编辑器（formulaEdit） =====

/** formulaEdit.snapshot 颜色板项（option = COLORXXX 选项名，Web 端点击插入光标处） */
export interface FormulaEditColorSnap {
  name: string
  hex: string
  option: string
}

/** formulaEdit.snapshot 响应（编辑器初始字段与上下文；periods null = 全周期） */
export interface FormulaEditSnapshot {
  /** system = 系统指标（只编辑公式）；new/edit = 自定义指标新建/编辑 */
  mode: 'system' | 'new' | 'edit'
  /** 页头标题里的指标名（system = id） */
  displayName: string
  isMain: boolean
  name: string
  formula: string
  scope: 'main' | 'sub'
  colorHex: string
  /** 适用周期集合；null = 全周期（对齐原生 applicablePeriods = nil） */
  periods: string[] | null
  /** 仅系统指标 true（可恢复编译时内容） */
  canRestoreBuiltin: boolean
  /** 编辑上下文周期（system 写回目标 = Documents/indicator/<周期>/） */
  period: string
  periodOptions: string[]
  /** 样例行情是否就绪（测试公式用；未就绪时 test 推「暂无行情数据」） */
  hasData: boolean
  palette: FormulaEditColorSnap[]
}

// ===== P2-8b 策略公式编辑器（strategyEdit） =====

/** strategyEdit.snapshot 规则行（params 键值对；行文本由原生 StrategyRuleParser.line 序列化） */
export interface StrategyRuleRowSnap {
  kind: string
  params: Record<string, string>
}

/** strategyEdit.snapshot 规则参数规格（type 驱动 Web 端动态渲染输入控件） */
export interface StrategyParamSpecSnap {
  key: string
  title: string
  type: 'number' | 'percent' | 'integer' | 'text' | 'option'
  isOptional: boolean
  placeholder: string
  options: string[]
  unit: string
}

/** strategyEdit.snapshot 规则类型目录项 */
export interface StrategyKindSpecSnap {
  kind: string
  title: string
  conditionOrderTitle: string
  specs: StrategyParamSpecSnap[]
}

/** strategyEdit.snapshot 交易指令（has* 标记区分「未设置」与 0 值） */
export interface StrategyTradeSpecSnap {
  direction: string
  hasQty: boolean
  qty: number
  hasAmount: boolean
  amount: number
  hasOffset: boolean
  offsetTicks: number
  priceType: string
  validity: string
  /** YYYY-MM-DD 文本（与 TRADE 段 EXPIRES 序列化口径一致） */
  expiresAt: string
  accountIDs: string[]
}

/** strategyEdit.snapshot 响应（编辑对象 + 选股公式库 + 可绑定账户 + 规则目录） */
export interface StrategyEditorSnapshot {
  doc: {
    id: string
    name: string
    mode: 'inline' | 'reference'
    pickBody: string
    pickRef: string
    rows: StrategyRuleRowSnap[]
    parseErrors: string[]
    trade: StrategyTradeSpecSnap
  }
  pickers: { id: string; name: string; pickBody: string }[]
  accounts: { id: string; name: string; badge: string; colorHex: string; cash: number; archived: boolean }[]
  ruleCatalog: StrategyKindSpecSnap[]
  hasData: boolean
}

/** strategyEdit.evaluate 响应（静态校验 + 语义预览，同步直通） */
export interface StrategyEvaluateResult {
  ready: boolean
  issues: string[]
  preview: { trade: string; summary: string; executionNotice: string }
}

// ===== P2-9c 策略详情页（strategyDetail） =====

/** strategyDetail.snapshot 响应（基础信息同步直出；引擎取值经 changed(values) 推送） */
export interface StrategyDetailSnapshot {
  id: string
  name: string
  /** 已配置交易指令或绑定账户（false 时交易卡显示引导文案） */
  tradeConfigured: boolean
  /** 「生成条件单」可用性（须已配置交易指令且绑定账户） */
  canGenerate: boolean
  /** 绑定的有效账户名（按 accountIDs 顺序解析） */
  boundAccounts: string[]
  /** 绑定了但已失效的账户数 */
  missingCount: number
  valuesQueued: boolean
  /** 一次性 toast（生成条件单成功后的提示，取走即清） */
  toast: string
}

/** strategyDetail.changed(pickPhase) 推送（跑选股执行器 phase；StrategyPickRunner 转发） */
export interface StrategyPickPhaseSnap {
  state: 'idle' | 'preparing' | 'running' | 'finished' | 'cancelled'
  done?: number
  total?: number
}

/** strategyDetail.changed(pickHits) 推送的命中行（价格/涨跌幅 Web 端格式化，缺省 null = 无数据） */
export interface StrategyPickHitSnap {
  metaID: number
  code: string
  name: string
  lastPrice: number | null
  changePct: number | null
}

/** strategyDetail.changed(genConfirm) 推送（草稿按账户分组；文案为投影缓存直读，就绪后重推） */
export interface StrategyGenConfirmPayload {
  groups: { id: string; name: string; items: { draftID: string; name: string; code: string; kindTitle: string; sentence: string }[] }[]
  skips: { title: string; reason: string }[]
  draftCount: number
  skipCount: number
  truncatedByLimit: boolean
  /** 仅 TRADE 段配了方向时可见（原生 entryToggle 同口径） */
  canToggleEntry: boolean
  includeEntry: boolean
  metaCount: number
}

/** strategyDetail.changed(values) 推送（引擎取值；unavailable = 引擎不可用显式降级） */
export interface StrategyDetailValues {
  reason: 'values'
  pickSummary: string
  tradeSummary: string
  rules: { kindTitle: string; trigger: string }[]
  parseErrors: string[]
  unavailable: boolean
}

// ===== P2-9c 选股公式编辑器（pickerEdit） =====

/** pickerEdit.snapshot 响应（编辑对象 + 样例数据就绪标记；极简形态：只编辑名称 + 公式） */
export interface PickerEditSnapshot {
  /** 空串 = 新建（保存时由原生生成 PICK_<n>） */
  id: string
  name: string
  pickBody: string
  /** 样例行情就绪（testPick 可用；未就绪时试算走「暂无行情数据」旁路文案） */
  hasData: boolean
}

// ===== P2-9a 全屏下单页（ticket） =====

/** ticket.snapshot 响应（票面初始化；提交复用 trade.submit） */
export interface TicketSnapshot {
  account: { id: string; name: string; cash: number }
  meta: { metaID: number; code: string; name: string; file: string }
  /** 最新价（行情缓存未就绪为 null；委托价默认跟随） */
  lastPrice: number | null
  initialDirection: 'buy' | 'sell'
  /** 持仓行入口时非空（预填卖出与可卖数量） */
  position: { qty: number; availableQty: number; costPrice: number } | null
  /** 费率常量集（真源 sim_rules.py；费用/可买可卖由 Web 端按纯算术计算） */
  rules: {
    lotSize: number
    commissionRate: number
    commissionMin: number
    stampTaxRate: number
    priceTick: number
    limitPct: number
  }
}

// ===== P2-9a 条件单管理页 / 编辑器（cond） =====

/** cond.list 行卡片（文案为原生投影缓存直读，未就绪为占位"—"；缓存更新后 cond.changed(texts) 重推） */
export interface CondOrderSnap {
  id: string
  name: string
  code: string
  kind: string
  kindTitle: string
  status: string
  statusTitle: string
  isAlertOnly: boolean
  repeatable: boolean
  conditionSummary: string
  directiveLine: string
  progressDone: number
  /** repeatable 时有效；grid 未就绪为 -1 且 hasProgressTotal=false */
  progressTotal: number
  hasProgressTotal: boolean
  lastMessage: string
}

/** cond.list 响应（管理页） */
export interface CondListSnapshot {
  accountID: string
  engineReady: boolean
  orders: CondOrderSnap[]
}

/** cond.editorContext 响应（编辑器初始化；draft 走 SimCondOrder 原生 JSON 口径 iso8601） */
export interface CondEditorContext {
  account: { id: string; cash: number }
  meta: { metaID: number; code: string; name: string }
  lastPrice: number | null
  initial: { kind: string; direction: string; qty: number; price: number | null }
  /** 编辑既有单据时的完整 SimCondOrder JSON（新建为 null） */
  editing: Record<string, unknown> | null
  rules: { lotSize: number; priceTick: number }
}

/** cond.changed(evaluate) 推送（引擎校验 + 投影文案，占位→就绪两段式） */
export interface CondEvaluateResult {
  draftID: string
  ready: boolean
  rejection: string
  previewSentence: string
  conditionSummary: string
  directiveSummary: string
  validitySummary: string
}

// 已约定的 module.action 清单（协议 v2）
export const KnownActions = {
  app: ['ping', 'reportRtt', 'memory', 'info', 'jsdiag', 'jsError'],
  theme: ['get', 'set'],
  profile: ['snapshot'],
  nav: ['switchTab'],
  favorites: ['snapshot', 'refresh', 'openDetail', 'setNote', 'setPinned', 'moveTo', 'removeFromGroup'],
  market: [
    'snapshot', 'select', 'refresh', 'openDetail', 'openSearch', 'openFormulaCenter',
    'groupInfo', 'setFavorite', 'setInGroup', 'createGroup', 'sortToggle',
    'configSnapshot', 'configSet', 'configReset',
  ],
  home: ['snapshot', 'openEntry', 'openDetail'],
  sim: [
    'snapshot', 'selectAccount', 'selectModule', 'createAccount', 'cancelOrder',
    'amendPrice', 'refreshQuotes', 'openTicket', 'openCondEditor', 'openCondManage',
    'openStrategyFormulas', 'openTrainingRecords', 'exportLogs',
  ],
  sheet: ['close', 'ready'],
  chart: ['settings.snapshot', 'settings.set', 'settings.resetLinked', 'search.query', 'search.pick',
          'indicators.snapshot', 'indicators.toggleMain', 'indicators.selectSub',
          'indicators.activateMainCustom', 'indicators.resetBuiltin',
          'indicators.openSystemEditor', 'indicators.openCustomEditor',
          'formula.snapshot', 'formula.deleteCustom', 'formula.openCenter', 'formula.openEditor'],
  preset: ['snapshot', 'setMode', 'editCommit'],
  formulaEdit: ['snapshot', 'test', 'save', 'restoreBuiltin'],
  strategyEdit: ['snapshot', 'evaluate', 'testPick', 'save'],
  strategyDetail: ['snapshot', 'edit', 'backtest', 'runPick', 'cancelPick', 'generate', 'toggleEntry', 'confirmGenerate'],
  pickerEdit: ['snapshot', 'testPick', 'save'],
  ticket: ['snapshot'],
  cond: ['list', 'editorContext', 'evaluate', 'save', 'cancel', 'edit', 'new'],
  quick: ['snapshot', 'selectAccount', 'pickTicket', 'backToList', 'cancelAll', 'closeAll'],
  trade: ['submit'],
  page: ['close', 'ready', 'open'],
  search: ['query', 'openDetail'],
  lan: ['snapshot', 'probe', 'setExposed', 'scan', 'connect', 'start'],
  update: ['snapshot', 'probeServer', 'reconnectServer', 'checkApp', 'installApp',
           'checkEngine', 'installEngine', 'syncNow', 'runGapBackfill', 'queryBaselineMissing'],
  lab: ['snapshot', 'refresh', 'download', 'install', 'loadEngine', 'runExp', 'cleanDownloads', 'exportCrash'],
  backtest: ['snapshot', 'run', 'cancel'],
  training: ['setup.snapshot', 'setPrefs', 'search', 'pickRandom', 'anchor', 'begin',
             'records.snapshot', 'recordDetail', 'deleteRecord', 'clearRecords'],
} as const

// 已约定的 event 清单（协议 v2）
export const KnownEvents = {
  themeChanged: 'theme.changed',
  appMemory: 'app.memory',
  navTab: 'nav.tab',
  favoritesChanged: 'favorites.changed',
  marketChanged: 'market.changed',
  homeChanged: 'home.changed',
  simChanged: 'sim.changed',
  sheetOpen: 'sheet.open',
  pageOpen: 'page.open',
  lanChanged: 'lan.changed',
  updateChanged: 'update.changed',
  labChanged: 'lab.changed',
  backtestChanged: 'backtest.changed',
  trainingChanged: 'training.changed',
  formulaEditChanged: 'formulaEdit.changed',
  strategyEditChanged: 'strategyEdit.changed',
  strategyDetailChanged: 'strategyDetail.changed',
  pickerEditChanged: 'pickerEdit.changed',
  condChanged: 'cond.changed',
  presetChanged: 'preset.changed',
} as const

// 已约定的错误码（协议 v2 错误码表）
export const KnownErrorCodes = [
  'bad_request',
  'unknown_module',
  'unknown_action',
  'invalid_payload',
  'store_not_ready',
  'internal_error',
] as const

// 主题偏好取值（theme.set 的合法 payload.preference）
export const ThemePreferences = ['system', 'light', 'dark'] as const

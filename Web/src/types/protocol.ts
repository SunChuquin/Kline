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
//   chart.settings.snapshot {} → ChartSettingsSnapshot      K线设置快照（周期/类型/联动视图数/显示组/裸K）
//   chart.settings.set {period?, chartStyle?, linkedViewCount?, showGap?, ...} → {} 设置写回（幂等目标态，即时生效图表）
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
//
// ## 事件清单 v2
//   theme.changed     {preference, mode}   主题偏好或系统外观变化（theme.set 后亦经此链路回推）
//   app.memory        {footprintMB}        页面就绪后一次
//   favorites.changed {reason}             自选数据/编辑变化（reason: refresh|edit）
//   market.changed    {reason}             行情数据/分类/配置变化（reason: data|config|edit；节流 ~0.8s 合并）
//   home.changed      {reason}             首页快照数据变化（reason: data|edit|sim；节流 ~0.8s 合并）
//   sim.changed       {reason}             模拟页快照数据变化（reason: data|trade；节流 ~0.8s 合并）
//   sheet.open        {name}               弹层打开指令（Swift→Web 弹层浮层 WebView，路由到对应面板）
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
          'indicators.openSystemEditor', 'indicators.openCustomEditor'],
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

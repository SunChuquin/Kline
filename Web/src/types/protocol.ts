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
//
// ## 事件清单 v2
//   theme.changed     {preference, mode}   主题偏好或系统外观变化（theme.set 后亦经此链路回推）
//   app.memory        {footprintMB}        页面就绪后一次
//   favorites.changed {reason}             自选数据/编辑变化（reason: refresh|edit）
//   market.changed    {reason}             行情数据/分类/配置变化（reason: data|config|edit；节流 ~0.8s 合并）
//   home.changed      {reason}             首页快照数据变化（reason: data|edit|sim；节流 ~0.8s 合并）
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
} as const

// 已约定的 event 清单（协议 v2）
export const KnownEvents = {
  themeChanged: 'theme.changed',
  appMemory: 'app.memory',
  navTab: 'nav.tab',
  favoritesChanged: 'favorites.changed',
  marketChanged: 'market.changed',
  homeChanged: 'home.changed',
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

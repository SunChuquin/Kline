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
//
// ## 事件清单 v2
//   theme.changed     {preference, mode}   主题偏好或系统外观变化（theme.set 后亦经此链路回推）
//   app.memory        {footprintMB}        页面就绪后一次
//
// ## 预留（后续批次扩展，本版未实现；形状见 fixtures reserved 区块）
//   favorites.setNote   {file, note} → {}        备注写回（幂等）——P2-1b 实装
//   favorites.setPinned {file, pinned} → {}      固顶写回（幂等）——P2-1b 实装
//   market.snapshot / market.subscribe …（行情秒级快照推送通道）

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

// 已约定的 module.action 清单（协议 v2）
export const KnownActions = {
  app: ['ping', 'reportRtt', 'memory', 'info', 'jsdiag', 'jsError'],
  theme: ['get', 'set'],
  profile: ['snapshot'],
  nav: ['switchTab'],
  favorites: ['snapshot', 'refresh', 'openDetail'],
} as const

// 已约定的 event 清单（协议 v2）
export const KnownEvents = {
  themeChanged: 'theme.changed',
  appMemory: 'app.memory',
  navTab: 'nav.tab',
  favoritesChanged: 'favorites.changed',
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

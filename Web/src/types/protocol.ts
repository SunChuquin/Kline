// Web↔Swift 桥接协议 v1（单一事实源：与 Kline/WebBridge/WebBridgeEnvelope.swift 对齐）
// 信封形态见 .trae/documents/Kline-混合架构改造方案.md §4.1：
//   请求  { id, module, action, payload }   （Web → Swift）
//   响应  { id, ok, data | error }          （Swift → Web，按 id 配对）
//   事件  { event, payload }                （Swift → Web，Store 变化广播）
// P0 为宽松形态（payload 随试点页演化）；P1 引入类型化 schema + golden 测试锁定。

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

// 已约定的 module.action 清单（P0）
export const KnownActions = {
  app: ['ping', 'reportRtt', 'memory', 'info'],
  theme: ['get'],
  profile: ['snapshot'],
} as const

// 已约定的 event 清单（P0）
export const KnownEvents = {
  themeChanged: 'theme.changed',
  appMemory: 'app.memory',
} as const

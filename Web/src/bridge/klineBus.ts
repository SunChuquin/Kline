// klineBus：Web↔Swift 桥接客户端（对齐 WebHostView / WebMessageRouter）
//
// 传输三态（detect() 探测，页面挂载时调用一次）：
//   native — 真机 WKWebView：WKScriptMessageHandler 单 channel "kline"，
//            响应经 window.klineBus.dispatch(<JSON.parse 对象>) 注入回传
//   pc     — PC 调试桥：USB 隧道下 fetch('/bridge') 同步请求响应（同一 router 分发，
//            真数据真写回；无事件推送，写回后页面自行回读）
//   none   — 无桥接（占位演示模式）
//
// 事件仅 native 模式生效（pc 模式写回后由页面回读权威状态）。

import type { BridgeEvent, BridgeRequest, BridgeResponse } from '../types/protocol'

type ResponseHandler = (resp: BridgeResponse) => void
type EventHandler = (event: BridgeEvent) => void

export type Transport = 'native' | 'pc' | 'none'

const pending = new Map<string, ResponseHandler>()
const listeners = new Map<string, EventHandler[]>()
let seq = 0
let transport: Transport = 'none'

function nextId(): string {
  seq += 1
  return `req_${Date.now().toString(36)}_${seq}`
}

/// 真机 messageHandler 是否存在（native 通道前提）
function isNativeAvailable(): boolean {
  const webkit = (window as any).webkit
  return !!(webkit && webkit.messageHandlers && webkit.messageHandlers.kline)
}

function postNative(req: BridgeRequest): void {
  ;((window as any).webkit.messageHandlers.kline).postMessage(JSON.stringify(req))
}

async function postPC(req: BridgeRequest): Promise<BridgeResponse> {
  const resp = await fetch('/bridge', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(req),
  })
  return (await resp.json()) as BridgeResponse
}

export const klineBus = {
  /// 挂载时调用一次：探测传输通道；返回最终通道
  async detect(): Promise<Transport> {
    if (isNativeAvailable()) {
      transport = 'native'
      return transport
    }
    try {
      const resp = await postPC({ id: `probe_${Date.now().toString(36)}`, module: 'app', action: 'ping', payload: {} })
      transport = resp.ok === true ? 'pc' : 'none'
    } catch {
      transport = 'none'
    }
    return transport
  },

  get transport(): Transport {
    return transport
  },

  /// 是否有任何可用桥接（native / pc）
  isAvailable(): boolean {
    return transport !== 'none'
  },

  /// 发起一次请求；pc 模式为同步请求响应，native 模式按 id 配对等待注入
  request(
    module: string,
    action: string,
    payload?: Record<string, unknown>,
    timeoutMs = 6000,
  ): Promise<Record<string, unknown> | undefined> {
    if (transport === 'pc') {
      return postPC({ id: nextId(), module, action, payload }).then((resp) => {
        if (resp.ok) return resp.data
        const err = resp.error
        throw new Error(err ? `${err.code}: ${err.message}` : '桥接失败')
      })
    }
    return new Promise((resolve, reject) => {
      const id = nextId()
      const req: BridgeRequest = { id, module, action, payload }

      const timer = setTimeout(() => {
        pending.delete(id)
        reject(new Error(`桥接超时: ${module}.${action}`))
      }, timeoutMs)

      pending.set(id, (resp) => {
        clearTimeout(timer)
        if (resp.ok) {
          resolve(resp.data)
        } else {
          const err = resp.error
          reject(new Error(err ? `${err.code}: ${err.message}` : '桥接失败'))
        }
      })

      if (transport !== 'native') {
        clearTimeout(timer)
        pending.delete(id)
        reject(new Error('NO_BRIDGE'))
        return
      }
      postNative(req)
    })
  },

  /// 订阅 Swift → Web 事件推送（theme.changed / app.memory ...；仅 native 模式有推送）
  on(event: string, fn: EventHandler): void {
    const list = listeners.get(event) ?? []
    list.push(fn)
    listeners.set(event, list)
  },

  /// Swift 注入入口（native 模式）：响应（含 id/ok）与事件（含 event）共用同一分发。
  /// 防御：桥接边界兼容字符串入参（JSON 文本自动 parse）。
  dispatch(raw: unknown): void {
    if (!raw) return
    if (typeof raw === 'string') {
      try {
        raw = JSON.parse(raw)
      } catch {
        return
      }
    }
    if (!raw || typeof raw !== 'object') return
    const obj = raw as Record<string, unknown>
    if (typeof obj.id === 'string' && typeof obj.ok === 'boolean') {
      const handler = pending.get(obj.id)
      if (handler) {
        pending.delete(obj.id)
        handler(obj as unknown as BridgeResponse)
      }
      return
    }
    if (typeof obj.event === 'string') {
      const list = listeners.get(obj.event) ?? []
      list.forEach((fn) => fn(obj as unknown as BridgeEvent))
    }
  },
}

// 挂载到 window：Swift 经 evaluateJavaScript 调 window.klineBus.dispatch(...)。
// ES module 顶层导出不会自动出现在 window 上——缺失时每次注入都抛
// ReferenceError/TypeError（2026-11-18 真机排障）。
;(window as any).klineBus = klineBus

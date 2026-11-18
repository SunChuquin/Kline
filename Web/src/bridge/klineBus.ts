// klineBus：Web↔Swift 桥接客户端（对齐 WebHostView / WebMessageRouter）
// 通道：WKScriptMessageHandler 单 channel "kline"，消息体为 JSON 字符串；
// Swift → Web 通过 window.klineBus.dispatch(<JSON>) 注入（响应与事件同一入口）。

import type { BridgeEvent, BridgeRequest, BridgeResponse } from '../types/protocol'

type ResponseHandler = (resp: BridgeResponse) => void
type EventHandler = (event: BridgeEvent) => void

const pending = new Map<string, ResponseHandler>()
const listeners = new Map<string, EventHandler[]>()
let seq = 0

function nextId(): string {
  seq += 1
  return `req_${Date.now().toString(36)}_${seq}`
}

/// 桥接通道是否可用（PC 浏览器开发模式下不可用，页面降级为占位演示）
function isAvailable(): boolean {
  const webkit = (window as any).webkit
  return !!(webkit && webkit.messageHandlers && webkit.messageHandlers.kline)
}

function post(req: BridgeRequest): boolean {
  if (!isAvailable()) return false
  ;((window as any).webkit.messageHandlers.kline).postMessage(JSON.stringify(req))
  return true
}

export const klineBus = {
  isAvailable,

  /// 发起一次请求，按 id 配对等待响应；超时或 NO_BRIDGE 拒绝
  request(
    module: string,
    action: string,
    payload?: Record<string, unknown>,
    timeoutMs = 6000,
  ): Promise<Record<string, unknown> | undefined> {
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

      if (!post(req)) {
        clearTimeout(timer)
        pending.delete(id)
        reject(new Error('NO_BRIDGE'))
      }
    })
  },

  /// 订阅 Swift → Web 事件推送（theme.changed / app.memory ...）
  on(event: string, fn: EventHandler): void {
    const list = listeners.get(event) ?? []
    list.push(fn)
    listeners.set(event, list)
  },

  /// Swift 注入入口：响应（含 id/ok）与事件（含 event）共用同一分发。
  /// 防御：桥接边界兼容字符串入参（JSON 文本自动 parse），
  /// 但 Swift 侧标准形态是 JSON.parse 后的对象。
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

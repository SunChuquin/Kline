// fc/adapters/tab-profile.ts：我的（Web 试点）页（tab-profile）逻辑适配器。
// 迁移自 Web/src/pages/ProfilePilotPage.vue：只读快照 + 主题写回 + 桥接探针
// （app.ping 5s 轮询 + reportRtt 落 debug_log）+ Vant 验收（Toast/Dialog，不落 Store）。
import { klineBus } from '../../bridge/klineBus'
import { showToast, showDialog } from 'vant'
import type { BridgeEvent } from '../../types/protocol'
import type { FcApi, FcPageAdapter } from '../types'

declare const __BUILD_TS__: string

let bridgeOk = false
let pingTimer: number | undefined

function setCell(api: FcApi, name: string, value: string): void {
  try {
    api.updateRule(name, { props: { value } })
  } catch (e) {
    // 页面已卸载（tab 切换重挂载），忽略陈旧 api 调用
    console.warn('[fc] tab-profile setCell 跳过', name, e)
  }
}

function setDbState(api: FcApi, loaded: boolean): void {
  try {
    api.updateRule('cellDbLoaded', { style: { display: loaded ? '' : 'none' } })
    api.updateRule('cellDbNotLoaded', { style: { display: loaded ? 'none' : '' } })
  } catch (e) {
    console.warn('[fc] tab-profile setDbState 跳过', e)
  }
}

function applyTheme(api: FcApi, t: { preference?: unknown; mode?: unknown }): void {
  if (typeof t.preference === 'string') api.setValue({ themePreference: t.preference })
  if (typeof t.mode === 'string') {
    setCell(api, 'cellThemeMode', t.mode === 'dark' ? '夜间' : '日间')
    document.documentElement.setAttribute('data-theme', t.mode === 'dark' ? 'dark' : 'light')
  }
}

/** 主题写回（协议 v2 theme.set）：写回后状态由 theme.changed 事件回推，不乐观更新 */
async function setTheme(api: FcApi, value: unknown): Promise<void> {
  try {
    const data = await klineBus.request('theme', 'set', { preference: String(value) })
    // pc 模式无事件推送：用回读纠正权威状态（native 模式 theme.changed 事件亦会到，值一致无害）
    if (typeof data?.['preference'] === 'string') {
      const t = await klineBus.request('theme', 'get')
      applyTheme(api, (t ?? {}) as Record<string, unknown>)
    }
  } catch (e) {
    // 写回失败：回读真实主题纠正选择（不发额外事件，纯请求）
    console.error('主题写回失败', e)
    klineBus
      .request('theme', 'get')
      .then((t) => applyTheme(api, (t ?? {}) as Record<string, unknown>))
      .catch(() => {})
  }
}

async function pingOnce(api: FcApi): Promise<void> {
  const started = performance.now()
  try {
    await klineBus.request('app', 'ping', { clientTs: started })
    const rtt = performance.now() - started
    setCell(api, 'cellRtt', `${rtt.toFixed(1)} ms`)
    // 顺带把页面实测 RTT 报给原生侧落 debug_log（验收证据）
    klineBus.request('app', 'reportRtt', { rttMs: rtt }).catch(() => {})
  } catch {
    // 探针失败静默：顶部 banner 已提示桥接不可用
  }
}

async function pull(api: FcApi): Promise<void> {
  // 传输探测：native（真机）/ pc（USB 隧道调试桥，真数据真写回）/ none（占位）
  const t = await klineBus.detect()
  bridgeOk = t !== 'none'
  api.updateRule('bridgeWarn', { style: { display: bridgeOk ? 'none' : '' } })
  api.updateRule('cellBuild', { props: { value: __BUILD_TS__ } })
  if (!bridgeOk) {
    api.setValue({ themePreference: 'system', vSwitch: true })
    return
  }

  try {
    applyTheme(api, ((await klineBus.request('theme', 'get')) ?? {}) as Record<string, unknown>)
  } catch {
    // 主题读取失败保持默认
  }

  try {
    const s = ((await klineBus.request('profile', 'snapshot')) ?? {}) as Record<string, unknown>
    const version = typeof s.version === 'string' ? s.version : '—'
    const build = typeof s.build === 'string' ? s.build : '—'
    const syncEnabled = s.syncEnabled === true
    const scheduleTimes = Array.isArray(s.scheduleTimes) ? (s.scheduleTimes as string[]) : []
    const tradingDaysOnly = s.tradingDaysOnly !== false
    const dbLoaded = s.dbLoaded === true
    setCell(api, 'cellVersion', `${version} (${build})`)
    setCell(api, 'cellSyncEnabled', syncEnabled ? '开启' : '关闭')
    setCell(api, 'cellSchedule', scheduleTimes.length ? scheduleTimes.join(' / ') : '—')
    setCell(api, 'cellTradingDays', tradingDaysOnly ? '是' : '否')
    setCell(api, 'cellBridge', 'kline ✓')
    setDbState(api, dbLoaded)
  } catch {
    // 快照失败保持占位
  }

  void pingOnce(api)
  if (pingTimer !== undefined) window.clearInterval(pingTimer)
  pingTimer = window.setInterval(() => void pingOnce(api), 5000)
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    vantToast: () => {
      showToast({ message: 'Vant Toast 轻提示', duration: 1500 })
    },
    vantDialog: () => {
      showDialog({ title: 'Vant Dialog', message: '确认框演示：真机验证 Safari 15 渲染与交互。' })
    },
  },

  onChange: (field, value, api) => {
    if (field === 'themePreference' && typeof value === 'string') void setTheme(api, value)
  },

  subscribe: (api) => {
    if (!bridgeOk) return () => {}
    const themeHandler = (ev: BridgeEvent): void => {
      applyTheme(api, (ev.payload ?? {}) as Record<string, unknown>)
    }
    const memHandler = (ev: BridgeEvent): void => {
      const mb = Number((ev.payload ?? {})['footprintMB'])
      if (!Number.isNaN(mb)) setCell(api, 'cellMem', `${mb.toFixed(1)} MB`)
    }
    klineBus.on('theme.changed', themeHandler)
    klineBus.on('app.memory', memHandler)
    return () => {
      if (pingTimer !== undefined) {
        window.clearInterval(pingTimer)
        pingTimer = undefined
      }
    }
  },
}

export default adapter

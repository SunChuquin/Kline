// fc/adapters/tab-home.ts：首页（tab-home）逻辑适配器。
// 迁移自 Web/src/pages/HomePage.vue：home.snapshot 快照回读（入口清单/指数行/涨跌家数/
// 自选Top5/模拟摘要/涨幅榜Top5）、home.changed 事件回读（native 模式）、
// 快捷入口（home.openEntry，失败 Toast）、点行进详情（home.openDetail 带 context）、
// 卡片跳转（nav.switchTab）。主库未就绪（冷启动竞态）3s 后重试一次。
import { klineBus } from '../../bridge/klineBus'
import { showToast } from 'vant'
import type { BridgeEvent } from '../../types/protocol'
import type { FcApi, FcPageAdapter } from '../types'

interface HomeEntry {
  id: string
  title: string
  subtitle: string
  tint: string
}

interface HomeQuote {
  file: string
  code: string
  name: string
  price: number | null
  pct: number | null
}

interface HomeFavQuote extends HomeQuote {
  closes: number[]
}

interface HomeSimSummary {
  totalAssets: number
  dayProfit: number
  dayProfitPct: number
  positionPct: number
}

interface HomeSimPosition {
  code: string
  name: string
  lastPrice: number
  profit: number
  profitPct: number
}

interface HomeBreadth {
  up: number
  down: number
  flat: number
  limitUp: number
  limitDown: number
}

interface CardsValue {
  indices: HomeQuote[]
  breadth: HomeBreadth | null
  favorites: HomeFavQuote[]
  sim: HomeSimSummary
  simPositions: HomeSimPosition[]
  gainers: HomeQuote[]
  loaded: boolean
  hasMainBoard: boolean
  gainersReady: boolean
}

let bridgeOk = false
let retryTimer: number | undefined

function applySnapshot(api: FcApi, s: Record<string, unknown>): void {
  const mapEntry = (e: Record<string, unknown>): HomeEntry => ({
    id: String(e.id ?? ''),
    title: String(e.title ?? ''),
    subtitle: String(e.subtitle ?? ''),
    tint: String(e.tint ?? '#007aff'),
  })
  const mapQuote = (r: Record<string, unknown>): HomeQuote => ({
    file: String(r.file ?? ''),
    code: String(r.code ?? ''),
    name: String(r.name ?? ''),
    price: typeof r.price === 'number' ? r.price : null,
    pct: typeof r.pct === 'number' ? r.pct : null,
  })
  const simRaw = s.sim as Record<string, unknown> | undefined
  const cards: CardsValue = {
    loaded: s.loaded === true,
    hasMainBoard: s.hasMainBoard === true,
    indices: (Array.isArray(s.indices) ? (s.indices as Record<string, unknown>[]) : []).map(mapQuote),
    favorites: (Array.isArray(s.favorites) ? (s.favorites as Record<string, unknown>[]) : []).map((r) => ({
      ...mapQuote(r),
      closes: Array.isArray(r.closes) ? (r.closes as number[]) : [],
    })),
    sim: simRaw
      ? {
        totalAssets: typeof simRaw.totalAssets === 'number' ? simRaw.totalAssets : 0,
        dayProfit: typeof simRaw.dayProfit === 'number' ? simRaw.dayProfit : 0,
        dayProfitPct: typeof simRaw.dayProfitPct === 'number' ? simRaw.dayProfitPct : 0,
        positionPct: typeof simRaw.positionPct === 'number' ? simRaw.positionPct : 0,
      }
      : { totalAssets: 0, dayProfit: 0, dayProfitPct: 0, positionPct: 0 },
    simPositions: (Array.isArray(s.simPositions) ? (s.simPositions as Record<string, unknown>[]) : []).map((p) => ({
      code: String(p.code ?? ''),
      name: String(p.name ?? ''),
      lastPrice: typeof p.lastPrice === 'number' ? p.lastPrice : 0,
      profit: typeof p.profit === 'number' ? p.profit : 0,
      profitPct: typeof p.profitPct === 'number' ? p.profitPct : 0,
    })),
    gainers: (Array.isArray(s.gainers) ? (s.gainers as Record<string, unknown>[]) : []).map(mapQuote),
    gainersReady: s.gainersReady === true,
  }
  api.setValue({
    entries: { entries: (Array.isArray(s.entries) ? (s.entries as Record<string, unknown>[]) : []).map(mapEntry) },
    cards,
  })
}

async function pullSnapshot(api: FcApi): Promise<void> {
  try {
    const s = ((await klineBus.request('home', 'snapshot')) ?? {}) as Record<string, unknown>
    applySnapshot(api, s)
    // 主库未就绪（冷启动竞态）：3s 后重试一次
    if (s.loaded !== true) {
      if (retryTimer !== undefined) window.clearTimeout(retryTimer)
      retryTimer = window.setTimeout(() => void pullSnapshot(api), 3000)
    }
  } catch (e) {
    console.error('home.snapshot 失败', e)
  }
}

async function pull(api: FcApi): Promise<void> {
  const t = await klineBus.detect()
  bridgeOk = t !== 'none'
  api.updateRule('bridgeWarn', { style: { display: bridgeOk ? 'none' : '' } })
  if (!bridgeOk) {
    api.setValue({
      entries: { entries: [] },
      cards: {
        indices: [], breadth: null, favorites: [],
        sim: { totalAssets: 0, dayProfit: 0, dayProfitPct: 0, positionPct: 0 },
        simPositions: [], gainers: [], loaded: false, hasMainBoard: true, gainersReady: false,
      },
    })
    return
  }
  await pullSnapshot(api)
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    openEntry: (inj) => {
      const kind = inj.args[0]
      if (typeof kind !== 'string' || !kind) return
      klineBus.request('home', 'openEntry', { kind }).catch((e) => {
        showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
      })
    },

    openDetail: (inj) => {
      const payload = inj.args[0] as { file?: string; context?: string[] } | undefined
      if (!payload?.file) return
      klineBus.request('home', 'openDetail', {
        file: payload.file,
        context: Array.isArray(payload.context) ? payload.context : [payload.file],
      }).catch((e) => console.error(e))
    },

    switchTab: (inj) => {
      const index = inj.args[0]
      if (typeof index !== 'number') return
      klineBus.request('nav', 'switchTab', { index }).catch((e) => console.error(e))
    },
  },

  subscribe: (api) => {
    if (!bridgeOk) return () => {}
    // native 模式：数据变化事件触发回读（pc 模式由页面回读兜底）
    const handler = (_ev: BridgeEvent): void => void pullSnapshot(api)
    klineBus.on('home.changed', handler)
    return () => {
      if (retryTimer !== undefined) {
        window.clearTimeout(retryTimer)
        retryTimer = undefined
      }
    }
  },
}

export default adapter

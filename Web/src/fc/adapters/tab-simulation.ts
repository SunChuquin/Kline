// fc/adapters/tab-simulation.ts：模拟交易 Tab（tab-simulation）逻辑适配器。
// 快照：sim.snapshot → KSimulationView（field 'view'）；
// 动作：规则 emit 'action'（data-act=view）统一分发（账户/模块/开票/撤单/改价/建户/导出…）；
// changed：sim.changed 推送回读（页面挂载期监听，卸载经 alive 标记失效）。
import { showToast } from 'vant'
import { klineBus } from '../../bridge/klineBus'
import type { FcApi, FcInject, FcPageAdapter, HostContext } from '../types'

// ===== 协议形状（web/src/types/protocol.ts 对拍，与源 SimulationPage 一致） =====
export interface AccountSnap {
  id: string
  name: string
  badge: string
  colorHex: string
}

export interface SummarySnap {
  totalAssets: number
  cash: number
  marketValue: number
  positionPct: number
  dayProfit: number
  dayProfitPct: number
  totalProfit: number
  totalProfitPct: number
}

export interface PositionRow {
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

export interface OrderRow {
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

export interface FillRow {
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

export interface LedgerRow {
  id: string
  time: string
  kind: string
  note: string
  amount: number
  balance: number
  accountName: string
}

export interface LogRow {
  id: string
  time: string
  accountName: string
  module: string
  content: string
  result: string
}

/** field 'view' 的完整快照（KSimulationView modelValue） */
export interface SimViewSnapshot {
  bridgeOk: boolean
  selectedID: string | null
  accountName: string
  accounts: AccountSnap[]
  summary: SummarySnap
  netValue: number[]
  module: string
  positions: PositionRow[]
  orders: OrderRow[]
  fills: FillRow[]
  ledger: LedgerRow[]
  logs: LogRow[]
}

/** KSimulationView emit('action') 载荷 */
export interface SimActionPayload {
  name: string
  args?: Record<string, unknown>
}

function emptySnapshot(): SimViewSnapshot {
  return {
    bridgeOk: false,
    selectedID: null,
    accountName: '全部账户汇总',
    accounts: [],
    summary: {
      totalAssets: 0, cash: 0, marketValue: 0, positionPct: 0,
      dayProfit: 0, dayProfitPct: 0, totalProfit: 0, totalProfitPct: 0,
    },
    netValue: [],
    module: 'position',
    positions: [], orders: [], fills: [], ledger: [], logs: [],
  }
}

function setView(api: FcApi, snap: SimViewSnapshot): void {
  try {
    api.setValue({ view: snap })
  } catch (e) {
    // 面板已卸载（Tab 页重挂载），忽略陈旧 api 调用
    console.warn('[fc] tab-simulation setValue 跳过（宿主可能已卸载）', e)
  }
}

/** 快照回读（源 SimulationPage.pullSnapshot 平移） */
async function pullInto(api: FcApi): Promise<void> {
  let s: Record<string, unknown>
  try {
    s = ((await klineBus.request('sim', 'snapshot')) ?? {}) as Record<string, unknown>
  } catch (e) {
    console.error('sim.snapshot 失败', e)
    return
  }
  const num = (v: unknown): number => (typeof v === 'number' ? v : 0)
  const raw = s.summary as Record<string, unknown> | undefined
  const snap: SimViewSnapshot = {
    bridgeOk: true,
    selectedID: typeof s.selectedID === 'string' ? s.selectedID : null,
    accountName: String(s.accountName ?? '全部账户汇总'),
    accounts: (Array.isArray(s.accounts) ? (s.accounts as Record<string, unknown>[]) : []).map((a) => ({
      id: String(a.id ?? ''),
      name: String(a.name ?? ''),
      badge: String(a.badge ?? '?'),
      colorHex: String(a.colorHex ?? '#1E5FA8'),
    })),
    summary: {
      totalAssets: raw && typeof raw.totalAssets === 'number' ? raw.totalAssets : 0,
      cash: raw && typeof raw.cash === 'number' ? raw.cash : 0,
      marketValue: raw && typeof raw.marketValue === 'number' ? raw.marketValue : 0,
      positionPct: raw && typeof raw.positionPct === 'number' ? raw.positionPct : 0,
      dayProfit: raw && typeof raw.dayProfit === 'number' ? raw.dayProfit : 0,
      dayProfitPct: raw && typeof raw.dayProfitPct === 'number' ? raw.dayProfitPct : 0,
      totalProfit: raw && typeof raw.totalProfit === 'number' ? raw.totalProfit : 0,
      totalProfitPct: raw && typeof raw.totalProfitPct === 'number' ? raw.totalProfitPct : 0,
    },
    netValue: Array.isArray(s.netValue) ? (s.netValue as number[]) : [],
    module: typeof s.module === 'string' ? s.module : 'position',
    positions: (Array.isArray(s.positions) ? (s.positions as Record<string, unknown>[]) : []).map((p) => ({
      id: String(p.id ?? ''), code: String(p.code ?? ''), name: String(p.name ?? ''),
      qty: num(p.qty), availableQty: num(p.availableQty), costPrice: num(p.costPrice),
      lastPrice: num(p.lastPrice), marketValue: num(p.marketValue),
      profit: num(p.profit), profitPct: num(p.profitPct),
    })),
    orders: (Array.isArray(s.orders) ? (s.orders as Record<string, unknown>[]) : []).map((o) => ({
      id: String(o.id ?? ''), time: String(o.time ?? ''), code: String(o.code ?? ''), name: String(o.name ?? ''),
      direction: o.direction === 'sell' ? 'sell' : 'buy',
      priceType: o.priceType === 'market' ? 'market' : 'limit',
      price: typeof o.price === 'number' ? o.price : null,
      qty: num(o.qty), filledQty: num(o.filledQty),
      status: (['pending', 'reported', 'partial', 'filled', 'cancelled'].includes(String(o.status))
        ? String(o.status) : 'pending') as OrderRow['status'],
      active: o.active === true,
    })),
    fills: (Array.isArray(s.fills) ? (s.fills as Record<string, unknown>[]) : []).map((f) => ({
      id: String(f.id ?? ''), time: String(f.time ?? ''), code: String(f.code ?? ''), name: String(f.name ?? ''),
      direction: f.direction === 'sell' ? 'sell' : 'buy',
      price: num(f.price), qty: num(f.qty), amount: num(f.amount), fee: num(f.fee),
      contract: String(f.contract ?? ''),
    })),
    ledger: (Array.isArray(s.ledger) ? (s.ledger as Record<string, unknown>[]) : []).map((e) => ({
      id: String(e.id ?? ''), time: String(e.time ?? ''), kind: String(e.kind ?? ''), note: String(e.note ?? ''),
      amount: num(e.amount), balance: num(e.balance), accountName: String(e.accountName ?? ''),
    })),
    logs: (Array.isArray(s.logs) ? (s.logs as Record<string, unknown>[]) : []).map((l) => ({
      id: String(l.id ?? ''), time: String(l.time ?? ''), accountName: String(l.accountName ?? ''),
      module: String(l.module ?? ''), content: String(l.content ?? ''), result: String(l.result ?? ''),
    })),
  }
  setView(api, snap)
}

/** 通用动作（源 act()：toast 透出响应文案 + 回读快照） */
async function actAndPull(api: FcApi, action: string): Promise<void> {
  try {
    const data = await klineBus.request('sim', action, {})
    const toast = typeof data?.toast === 'string' ? data.toast : null
    if (toast) showToast({ message: toast, duration: 2000 })
    await pullInto(api)
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
  }
}

function toastError(e: unknown): void {
  showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
}

const adapter: FcPageAdapter = {
  pull: async (api: FcApi, _ctx: HostContext): Promise<void> => {
    const t = await klineBus.detect()
    const ok = t !== 'none'
    try {
      api.updateRule('simWarn', { style: { display: ok ? 'none' : '' } })
    } catch (e) {
      console.warn('[fc] tab-simulation simWarn 显隐更新跳过', e)
    }
    if (!ok) {
      setView(api, emptySnapshot())
      return
    }
    await pullInto(api)
  },

  actions: {
    /** KSimulationView 统一动作分发（emit('action', {name, args})） */
    view: (inj: FcInject, _ctx: HostContext): void => {
      const payload = inj.args[0] as SimActionPayload | undefined
      if (!payload || typeof payload.name !== 'string') return
      const api = inj.api
      const a = payload.args ?? {}
      switch (payload.name) {
        case 'selectAccount':
          // 源 selectAccount：写桥后回读（无 toast，异常 console）
          void (async () => {
            try {
              await klineBus.request('sim', 'selectAccount', { accountID: a.accountID ?? null })
              await pullInto(api)
            } catch (e) {
              console.error(e)
            }
          })()
          break
        case 'selectModule':
          // 源 selectModule：仅写桥（模块切换本地即时生效，快照随 changed 回读）
          void klineBus.request('sim', 'selectModule', { module: a.module ?? 'position' })
            .catch((e) => console.error(e))
          break
        case 'openCondManage':
        case 'openStrategyFormulas':
        case 'openTrainingRecords':
        case 'refreshQuotes':
          void actAndPull(api, payload.name)
          break
        case 'openTicket':
          // 源 openTicket：仅请求，失败 toast（票面页由原生/宿主路由打开）
          void klineBus.request('sim', 'openTicket', {
            direction: a.direction,
            ...(a.positionID ? { positionID: a.positionID } : {}),
          }).catch((e) => toastError(e))
          break
        case 'openCondEditor':
          void klineBus.request('sim', 'openCondEditor', { positionID: a.positionID })
            .catch((e) => toastError(e))
          break
        case 'cancelOrder':
          void (async () => {
            try {
              await klineBus.request('sim', 'cancelOrder', { orderID: a.orderID })
              showToast({ message: '撤单请求已提交', duration: 1600 })
              await pullInto(api)
            } catch (e) {
              toastError(e)
            }
          })()
          break
        case 'confirmCreateAccount':
          void (async () => {
            try {
              const data = await klineBus.request('sim', 'createAccount',
                { name: a.name, capital: a.capital })
              showToast({ message: typeof data?.toast === 'string' ? data.toast : '已创建账户', duration: 2000 })
              await pullInto(api)
            } catch (e) {
              toastError(e)
            }
          })()
          break
        case 'confirmAmend':
          void (async () => {
            try {
              const data = await klineBus.request('sim', 'amendPrice',
                { orderID: a.orderID, price: a.price })
              showToast({ message: typeof data?.toast === 'string' ? data.toast : '已改价', duration: 2000 })
              await pullInto(api)
            } catch (e) {
              toastError(e)
            }
          })()
          break
        case 'exportLogs':
          void (async () => {
            try {
              const data = await klineBus.request('sim', 'exportLogs', {
                keyword: a.keyword,
                logModule: a.logModule,
              })
              showToast({ message: typeof data?.toast === 'string' ? data.toast : '已导出', duration: 2400 })
            } catch (e) {
              toastError(e)
            }
          })()
          break
        default:
          console.warn(`[fc] tab-simulation 未注册视图动作: ${payload.name}`)
      }
    },
  },

  subscribe: (api: FcApi) => {
    // native 模式：数据变化事件触发回读（下单/成交/改价/行情快照均经 sim.changed 推送）；
    // klineBus 无 off API，卸载以 alive 标记使处理器失效
    let alive = true
    const handler = (): void => {
      if (alive) void pullInto(api)
    }
    klineBus.on('sim.changed', handler)
    return () => {
      alive = false
    }
  },
}

export default adapter

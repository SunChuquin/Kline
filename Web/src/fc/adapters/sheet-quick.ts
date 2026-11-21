// fc/adapters/sheet-quick.ts：快捷面板（sheet-quick，悬浮球）逻辑适配器。
// 三视图（list 列表态 / detail 详情票面 / picked 选中票面）由快照 view 切换行显隐；
// 快照：quick.snapshot；动作：quick.selectAccount / pickTicket / cancelAll / closeAll；
// 下单：trade.submit（卖出先本地预检 + 二次确认）。
import { klineBus } from '../../bridge/klineBus'
import { showToast } from 'vant'
import 'vant/es/toast/style'
import { fmtAmount, fmtPctRaw, fmtShares, fmtSigned0, profitClass } from '../format'
import type { FcApi, FcInject, FcPageAdapter, HostContext } from '../types'

interface QuickAccount { id: string; name: string; badge: string; colorHex: string }
interface QuickQuote { file: string; code: string; name: string; price: number | null; pct: number | null }
interface QuickSnapshot {
  trainingActive: boolean
  view: 'detail' | 'picked' | 'list'
  accounts: QuickAccount[]
  selectedName: string
  detail: {
    meta: QuickQuote
    accountName: string
    cash: number
    tradingPhase: string
    hasAccount: boolean
    ticket: { cash: number; lastPrice: number | null; position: { qty: number; availableQty: number; costPrice: number; lastPrice: number; profit: number; profitPct: number; sellableQty: number } | null } | null
  } | null
  list: {
    summary: { totalAssets: number; dayProfit: number; totalProfit: number }
    activeOrderCount: number
    watchlist: QuickQuote[]
    activeOrders: { id: string; name: string; direction: 'buy' | 'sell'; status: string; qty: number }[]
  } | null
}

const PULL_CTX = { domain: 'sheet', pageName: 'sheet-quick', close: () => {} } as const

let snap: QuickSnapshot | null = null
let ctxRef: HostContext | null = null

const DETAIL_ROWS = ['detailMeta', 'detailQuote', 'detailQuoteTitle', 'ticketField', 'posBlock', 'detailActions']
const LIST_ROWS = ['listMeta', 'listActions', 'watchlistTitle', 'watchlist', 'ordersTitle', 'orders']

function applyView(api: FcApi, view: string, hasAccount: boolean): void {
  const showDetail = hasAccount && (view === 'detail' || view === 'picked')
  const showList = hasAccount && view === 'list'
  for (const n of DETAIL_ROWS) setRowHidden(api, n, !showDetail)
  for (const n of LIST_ROWS) setRowHidden(api, n, !showList)
  setRowHidden(api, 'noAccountNote', hasAccount)
}

function setRowHidden(api: FcApi, name: string, hidden: boolean): void {
  api.updateRule(name, { style: { display: hidden ? 'none' : '' } })
}

async function pull(api: FcApi, ctx: HostContext): Promise<void> {
  ctxRef = ctx
  try {
    snap = ((await klineBus.request('quick', 'snapshot')) ?? {}) as QuickSnapshot
  } catch (e) {
    console.error('quick.snapshot 失败', e)
    return
  }
  const q = snap
  const view = String(q.view ?? 'list')
  applyView(api, view, !!(q.detail?.hasAccount || q.list))

  // 票面默认值跟随最新价（对齐原生 didEditPrice=false 时 price=lastPrice；数量默认 100）
  const last = q.detail?.ticket?.lastPrice ?? q.detail?.meta.price ?? null
  api.setValue({
    ticket: {
      direction: 'buy',
      priceType: 'limit',
      priceText: last !== null ? String(last) : '',
      qtyText: '100',
    },
    accPickerOpen: false,
    sellConfirmOpen: false,
    watchlist: { rows: q.list?.watchlist ?? [], buySell: true, emptyText: '暂无自选' },
    orders: { rows: q.list?.activeOrders ?? [], emptyText: '暂无在途委托' },
    detailQuote: { rows: q.detail?.meta ? [q.detail.meta] : [] },
  })

  if (q.detail?.hasAccount) {
    const pos = q.detail.ticket?.position ?? null
    api.updateRule('detailMeta', { props: {
      left: `${q.selectedName} ▾`,
      center: `可用 ${fmtAmount(q.detail.cash)}`,
      right: q.detail.tradingPhase ?? '',
    } })
    api.updateRule('ticketField', { props: { lastPrice: last } })
    if (pos) {
      api.updateRule('posBlock', { props: {
        left: `持仓 ${fmtShares(pos.qty)} · 可用 ${fmtShares(pos.availableQty)}`,
        center: `${fmtSigned0(pos.profit)} (${fmtPctRaw(pos.profitPct * 100)})`,
        centerTone: profitClass(pos.profit) as 'up' | 'down',
      } })
    } else {
      api.updateRule('posBlock', { props: { left: '', center: '', right: '' } })
    }
  }
  if (q.list) {
    api.updateRule('listMeta', { props: {
      left: `${q.selectedName} ▾`,
      center: `总资产 ${fmtAmount(q.list.summary.totalAssets)}`,
      right: '',
    } })
    api.updateRule('listActions', { props: { buttons: [
      { label: '切换账户', act: 'openAccPicker' },
      { label: `一键撤单 (${q.list.activeOrderCount})`, act: 'cancelAll', tone: 'danger', ariaLabel: 'quick.cancelAll' },
      { label: '关闭面板', act: 'closePanel' },
    ] } })
  }
}

/** 仓位 chips：买入按现金可买整手、卖出按可卖数量（提交时原生精确校验兜底） */
function applyPosition(inj: FcInject, ratio: number): void {
  const ticket = inj.api.getValue('ticket') as { direction: 'buy' | 'sell'; priceType: 'limit' | 'market'; priceText: string; qtyText: string }
  const last = snap?.detail?.ticket?.lastPrice ?? snap?.detail?.meta.price ?? null
  const cash = snap?.detail?.ticket?.cash ?? 0
  const sellable = snap?.detail?.ticket?.position?.availableQty ?? 0
  const price = ticket.priceType === 'limit'
    ? (parseFloat(ticket.priceText) || last || 0)
    : (last || 0)
  const qty = ticket.direction === 'buy'
    ? Math.floor(((cash * ratio) / Math.max(price, 0.01)) / 100) * 100
    : Math.floor(sellable * ratio)
  inj.api.setValue({ ticket: { ...ticket, qtyText: String(qty) } })
}

/** 提交前本地预检（对齐原生票面：限价需价格、整手数量），提交带卖出二次确认 */
function submitTicket(inj: FcApi): void {
  const ticket = inj.getValue('ticket') as { direction: 'buy' | 'sell'; priceType: 'limit' | 'market'; priceText: string; qtyText: string }
  const qty = parseInt(ticket.qtyText || '0', 10) || 0
  if (ticket.priceType === 'limit' && !(parseFloat(ticket.priceText) > 0)) {
    inj.updateRule('ticketField', { props: { error: '请输入有效的委托价' } })
    return
  }
  if (qty <= 0) {
    inj.updateRule('ticketField', { props: { error: '请输入委托数量' } })
    return
  }
  inj.updateRule('ticketField', { props: { error: '' } })
  if (ticket.direction === 'sell') {
    const name = snap?.detail?.meta.name ?? ''
    inj.updateRule('sellConfirmDialog', { props: { title: `确认卖出 ${name} ${fmtShares(qty)} 股？` } })
    inj.setValue({ sellConfirmOpen: true })
    return
  }
  void doSubmit(inj)
}

async function doSubmit(api: FcApi): Promise<void> {
  const meta = snap?.detail?.meta
  const accountID = snap?.accounts.find((a) => a.name === snap?.selectedName)?.id
  if (!meta || !accountID) {
    api.updateRule('ticketField', { props: { error: '请先选择有效的模拟账户' } })
    return
  }
  const ticket = api.getValue('ticket') as { direction: 'buy' | 'sell'; priceType: 'limit' | 'market'; priceText: string; qtyText: string }
  try {
    await klineBus.request('trade', 'submit', {
      accountID,
      direction: ticket.direction,
      priceType: ticket.priceType,
      price: ticket.priceType === 'limit' ? parseFloat(ticket.priceText) : null,
      qty: parseInt(ticket.qtyText || '0', 10) || 0,
      file: meta.file,
    })
    showToast({ message: '委托已提交', duration: 1800 })
    await pull(api, PULL_CTX)
  } catch (e) {
    api.updateRule('ticketField', { props: { error: String(e instanceof Error ? e.message : e).slice(0, 60) } })
  }
}

async function actQuick(api: FcApi, action: string, payload: Record<string, unknown>): Promise<void> {
  try {
    await klineBus.request('quick', action, payload)
    await pull(api, PULL_CTX)
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
  }
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    dispatchAction: (inj, ctx) => {
      const act = inj.args[0] as string
      const api = inj.api
      switch (act) {
        case 'closeAll':
          void actQuick(api, 'closeAll', {}).then(() => showToast({ message: '清仓请求已提交', duration: 1600 }))
          break
        case 'cancelAll':
          void actQuick(api, 'cancelAll', {}).then(() => showToast({ message: '撤单请求已提交', duration: 1600 }))
          break
        case 'closePanel':
          klineBus.request('sheet', 'close', {}).catch((e) => console.error(e))
          ctx.close()
          break
        case 'openAccPicker':
          api.setValue({ accPickerOpen: true })
          break
      }
    },

    openAccPicker: (inj) => {
      inj.api.setValue({ accPickerOpen: true })
    },

    accSelect: (inj) => {
      const action = inj.args[0] as { name: string; value: string } | undefined
      if (!action) return
      inj.api.setValue({ accPickerOpen: false })
      void actQuick(inj.api, 'selectAccount', { accountID: action.value })
    },

    applyPosition,

    pickTicket: (inj) => {
      const payload = inj.args[0] as { row: QuickQuote; direction: 'buy' | 'sell' } | undefined
      if (!payload) return
      inj.api.setValue({
        ticket: { direction: payload.direction, priceType: 'limit', priceText: '', qtyText: '' },
      })
      inj.api.updateRule('ticketField', { props: { error: '' } })
      void actQuick(inj.api, 'pickTicket', { file: payload.row.file, direction: payload.direction })
    },

    submitTicket: (inj) => {
      submitTicket(inj.api)
    },

    doSubmit: (inj) => {
      inj.api.setValue({ sellConfirmOpen: false })
      void doSubmit(inj.api)
    },
  },
}

export default adapter

// fc/adapters/page-ticket.ts：全屏下单页（page-ticket）逻辑适配器。
// 快照：ticket.snapshot；提交复用 trade.submit（快捷面板同款链路：
// 校验/费用/写入全在原生 SimStore.submit）。
// 费用合计 / 仓位快捷 / 可买可卖由 Web 端按 snapshot 下发的费率常量纯算术计算。
import { klineBus } from '../../bridge/klineBus'
import type { TicketSnapshot } from '../../types/protocol'
import type { FcApi, FcPageAdapter, HostContext } from '../types'
import { patchRule } from '../rule-patch'

interface TicketState {
  direction: 'buy' | 'sell'
  priceType: 'limit' | 'market'
  priceText: string
  qtyText: string
}

let snap: TicketSnapshot | null = null
let didEditPrice = false
let prevPriceText = ''
let ctxRef: HostContext | null = null

function moneyText(v: number): string {
  return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function fmtAmount(v: number): string {
  return Math.round(v).toLocaleString('en-US')
}

function ticketOf(api: FcApi): TicketState {
  return (api.getValue('ticket') as TicketState | undefined) ?? { direction: 'buy', priceType: 'limit', priceText: '', qtyText: '' }
}

function qtyOf(t: TicketState): number {
  return parseInt(t.qtyText || '0', 10) || 0
}

/** 生效价格：限价取输入、市价取最新价 */
function effectivePrice(t: TicketState): number {
  if (t.priceType === 'market') return snap?.lastPrice ?? 0
  return parseFloat(t.priceText) || 0
}

function amountOf(t: TicketState): number {
  return effectivePrice(t) * qtyOf(t)
}

/** 佣金：成交额 × 费率，不足最低按最低（对齐 SimTradingRules.commission） */
function commission(a: number): number {
  const rules = snap!.rules
  return Math.max(a * rules.commissionRate, rules.commissionMin)
}

/** 合计费用：佣金 + 印花税（仅卖出） */
function totalFeeOf(t: TicketState): number {
  if (!snap || amountOf(t) <= 0) return 0
  const rules = snap.rules
  const stamp = t.direction === 'sell' ? amountOf(t) * rules.stampTaxRate : 0
  return commission(amountOf(t)) + stamp
}

/** 可买整手：现金 / (价 × (1 + 佣金率)) 向下取整到整手（近似口径，提交易原生复核） */
function buyAvailText(t: TicketState): string {
  if (!snap) return '0'
  const p = effectivePrice(t)
  if (p <= 0) return '0'
  const rules = snap.rules
  const perLot = p * rules.lotSize * (1 + rules.commissionRate)
  const lots = Math.floor(snap.account.cash / Math.max(perLot, 0.01))
  return `${lots * rules.lotSize} 股`
}

/** 可卖数量：持仓入口的 availableQty（T+1 口径由原生维护） */
function sellable(): number {
  return snap?.position?.availableQty ?? 0
}

/** 费用 / 可买可卖 / 账户行文案回填（k-ticket-form props 注入） */
function syncDerived(api: FcApi, t: TicketState): void {
  const fee = totalFeeOf(t)
  const feeText = fee > 0 ? moneyText(fee) : ''
  let cashAfterText = ''
  if (snap && amountOf(t) > 0 && fee > 0) {
    const delta = t.direction === 'buy'
      ? snap.account.cash - amountOf(t) - fee
      : snap.account.cash + amountOf(t) - fee
    cashAfterText = moneyText(delta)
  }
  const p = effectivePrice(t)
  const showAvail = t.priceType === 'limit' && p > 0
  const availText = t.direction === 'buy' ? `可买 ${buyAvailText(t)}` : `可卖 ${sellable()}`
  patchRule(api, 'ticketForm', { props: { showAvail, availText, feeText, cashAfterText } })
}

async function pull(api: FcApi, ctx: HostContext): Promise<void> {
  ctxRef = ctx
  try {
    snap = ((await klineBus.request('ticket', 'snapshot')) ?? {}) as unknown as TicketSnapshot
  } catch (e) {
    console.error('ticket.snapshot 失败', e)
    patchRule(api, 'ticketForm', { props: { error: String(e instanceof Error ? e.message : e).slice(0, 60) } })
    return
  }
  didEditPrice = false
  prevPriceText = ''
  const t: TicketState = {
    direction: snap.initialDirection,
    priceType: 'limit',
    priceText: '',
    qtyText: '',
  }
  if (snap.lastPrice) t.priceText = snap.lastPrice.toFixed(2)
  api.setValue({ ticket: t, sellConfirm: false })
  patchRule(api, 'ticketForm', {
    props: {
      loaded: true,
      metaText: `${snap.meta.name} ${snap.meta.code}`,
      acctName: snap.account.name,
      acctCashText: fmtAmount(snap.account.cash),
      error: '',
    },
  })
  syncDerived(api, t)
}

/** 本地预检（对齐原生票面：限价需价格、整手数量） */
function precheck(api: FcApi): boolean {
  const t = ticketOf(api)
  const rules = snap!.rules
  if (t.priceType === 'limit' && !(parseFloat(t.priceText) > 0)) {
    patchRule(api, 'ticketForm', { props: { error: '请输入有效的委托价' } })
    return false
  }
  if (qtyOf(t) <= 0) {
    patchRule(api, 'ticketForm', { props: { error: '请输入委托数量' } })
    return false
  }
  if (qtyOf(t) % rules.lotSize !== 0) {
    patchRule(api, 'ticketForm', { props: { error: `委托数量需为 ${rules.lotSize} 股的整数倍` } })
    return false
  }
  patchRule(api, 'ticketForm', { props: { error: '' } })
  return true
}

async function doSubmit(api: FcApi): Promise<void> {
  if (!snap) return
  const t = ticketOf(api)
  try {
    await klineBus.request('trade', 'submit', {
      accountID: snap.account.id,
      metaID: '',
      direction: t.direction,
      priceType: t.priceType,
      price: t.priceType === 'limit' ? parseFloat(t.priceText) : null,
      qty: qtyOf(t),
      file: snap.meta.file,
    })
    // 成功即关页（对齐原生 fullScreenCover 提交成功关闭）
    ctxRef?.close()
  } catch (e) {
    patchRule(api, 'ticketForm', { props: { error: String(e instanceof Error ? e.message : e).slice(0, 60) } })
  }
}

/** 仓位快捷：买入按现金可买整手比例、卖出按可卖比例（对齐原生 positionChips 口径） */
function applyPosition(api: FcApi, ratio: number): void {
  if (!snap) return
  const rules = snap.rules
  const t = ticketOf(api)
  if (t.direction === 'buy') {
    const p = effectivePrice(t)
    if (p <= 0) return
    const perLot = p * rules.lotSize * (1 + rules.commissionRate)
    const lots = Math.floor((snap.account.cash * ratio) / Math.max(perLot, 0.01))
    api.setValue({ ticket: { ...t, qtyText: String(lots * rules.lotSize) } })
  } else {
    api.setValue({ ticket: { ...t, qtyText: String(Math.floor(sellable() * ratio)) } })
  }
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    submit: (inj) => {
      if (!snap) return
      if (!precheck(inj.api)) return
      const t = ticketOf(inj.api)
      if (t.direction === 'sell') {
        const name = snap.meta.name ?? ''
        patchRule(inj.api, 'sellDialog', { props: { title: `确认卖出 ${name} ${qtyOf(t)} 股？` } })
        inj.api.setValue({ sellConfirm: true })
        return
      }
      void doSubmit(inj.api)
    },

    doSubmit: (inj) => {
      inj.api.setValue({ sellConfirm: false })
      void doSubmit(inj.api)
    },

    applyPosition: (inj) => {
      const ratio = Number(inj.args[0] ?? 0)
      if (ratio > 0) applyPosition(inj.api, ratio)
    },
  },

  onChange: (field, value, api) => {
    if (field !== 'ticket') return
    const t = value as TicketState
    // 委托价默认跟随最新价：用户手动改过则不再跟随（didEditPrice 口径对齐源面板）
    if (t.priceText !== prevPriceText) {
      didEditPrice = true
      prevPriceText = t.priceText
    }
    // 数量仅保留数字（对齐 syncQty）
    const digits = t.qtyText.replace(/\D/g, '')
    if (digits !== t.qtyText) {
      api.setValue({ ticket: { ...t, qtyText: digits } })
      return
    }
    syncDerived(api, t)
  },
}

export default adapter

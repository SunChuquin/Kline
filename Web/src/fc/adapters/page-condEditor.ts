// fc/adapters/page-condEditor.ts：条件单编辑器（page-condEditor）逻辑适配器。
// 快照：cond.editorContext（draft 为 SimCondOrder 原生 JSON 口径 iso8601）；
// 校验/投影文案异步（cond.evaluate → changed(evaluate)，占位→就绪两段式）；
// 保存引擎终校 fail-closed（cond.save → changed(saveResult)）。
import { klineBus } from '../../bridge/klineBus'
import type { BridgeEvent } from '../../types/protocol'
import type { CondEditorContext, CondEvaluateResult } from '../../types/protocol'
import type { FcApi, FcPageAdapter, HostContext } from '../types'
import { patchRule } from '../rule-patch'

let ctxData: CondEditorContext | null = null
let editing: Record<string, any> | null = null
let draft: Record<string, any> | null = null
let kind = 'price'
let dir = 'sell'
let qtyTextStr = '100'
let priceType = 'market'
let offsetTicks = 0
let alertOnly = false
let validity = 'longTerm'
let expiryLocal = ''
let fireLocal = ''
let tpOn = true
let slOn = true
let errorText = ''
let evaluateResult: CondEvaluateResult | null = null
let evaluateTimer: ReturnType<typeof setTimeout> | null = null
let ctxRef: HostContext | null = null

const NUM_FIELDS = [
  'triggerPrice', 'basePrice', 'takeProfitPrice', 'stopLossPrice', 'breakoutPrice', 'trailPct',
  'floorPrice', 'changeThreshold', 'gridBase', 'gridLower', 'gridUpper', 'gridStepPct',
  'gridQtyPerLevel', 'batchTotalQty', 'batchFirstPrice', 'batchStepPct',
]

// ===== params 读写（JSON 口径：null = 未设置） =====
function params(): Record<string, any> {
  return draft?.params ?? {}
}

function num(key: string): number | null {
  const v = params()[key]
  return typeof v === 'number' ? v : null
}

function bool(key: string): boolean {
  return params()[key] === true
}

function str(key: string): string {
  return typeof params()[key] === 'string' ? params()[key] : ''
}

function numText(key: string): string {
  const v = num(key)
  if (v === null) return ''
  const intKeys = ['gridQtyPerLevel', 'batchTotalQty', 'maPeriod']
  const pctKeys = ['trailPct', 'gridStepPct', 'batchStepPct', 'changeThreshold']
  if (intKeys.includes(key)) return String(Math.round(v))
  if (pctKeys.includes(key)) return String(v)
  return v.toFixed(2)
}

/** 文本 → 数值（清洗非数值字符；无效落 null） */
function setNumText(key: string, text: string): void {
  const cleaned = text.replace(/[^\d.\-]/g, '')
  const v = parseFloat(cleaned)
  params()[key] = Number.isFinite(v) ? v : null
}

// ===== 快照拉取与初始化 =====
function isoToDateText(iso: unknown): string {
  if (typeof iso !== 'string' || !iso) return ''
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

/** ISO → datetime-local 文本（YYYY-MM-DDTHH:mm，本地时区） */
function isoToLocalInput(iso: unknown): string {
  if (typeof iso !== 'string' || !iso) return ''
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
}

function newDraft(): Record<string, any> {
  const now = new Date()
  return {
    id: '00000000-0000-0000-0000-000000000000',
    accountID: ctxData!.account.id,
    metaID: ctxData!.meta.metaID,
    code: ctxData!.meta.code,
    name: ctxData!.meta.name,
    kind,
    params: {},
    directive: { direction: dir, priceType: 'market', offsetTicks: 0, qty: ctxData!.initial.qty, alertOnly: null },
    validity: 'longTerm',
    expiresAt: null,
    createdAt: now.toISOString(),
    updatedAt: now.toISOString(),
    status: 'monitoring',
  }
}

/** 类型默认值（对齐原生 applyKindDefaults） */
function applyKindDefaults(): void {
  const p = params()
  const price = ctxData?.initial.price
  switch (kind) {
    case 'price':
      p['compareUp'] = true
      if (price != null) p['triggerPrice'] = price
      break
    case 'stopLoss':
      p['baseMode'] = 'price'
      p['basePrice'] = ctxData?.initial.price ?? null
      break
    case 'trailing':
      p['breakoutPrice'] = price ?? null
      p['floorEnabled'] = false
      break
    case 'time':
      p['fireDate'] = new Date(Date.now() + 3600_000).toISOString()
      fireLocal = isoToLocalInput(p['fireDate'])
      break
    case 'maCross':
      p['maPeriod'] = 20
      p['maAbove'] = true
      break
    case 'grid':
      p['gridBase'] = price ?? null
      p['gridMultiplier'] = 1
      p['gridQtyPerLevel'] = ctxData!.initial.qty > 0 ? ctxData!.initial.qty : null
      break
    case 'batch':
      p['batchCount'] = 3
      p['batchTotalQty'] = ctxData!.initial.qty > 0 ? ctxData!.initial.qty : null
      p['batchFirstPrice'] = price ?? null
      break
  }
}

function selectKind(k: string): void {
  if (k === kind) return
  kind = k
  draft!.params = {}
  draft!.kind = k
  tpOn = true
  slOn = true
  applyKindDefaults()
}

// ===== 草稿 → payload =====
function fireDateISO(): string | null {
  if (!fireLocal) return null
  const d = new Date(fireLocal)
  return Number.isNaN(d.getTime()) ? null : d.toISOString()
}

function draftPayload(): Record<string, any> {
  const d = JSON.parse(JSON.stringify(draft)) as Record<string, any>
  d.kind = kind
  d.params = JSON.parse(JSON.stringify(params()))
  d.directive = {
    direction: dir,
    priceType,
    offsetTicks: priceType === 'limit' ? offsetTicks : 0,
    qty: kind === 'grid' ? (num('gridQtyPerLevel') ?? 0) : (parseInt(qtyTextStr || '0', 10) || 0),
    alertOnly: alertOnly ? true : null,
  }
  d.validity = validity
  d.expiresAt = validity === 'untilDate' && expiryLocal
    ? new Date(expiryLocal + 'T00:00:00').toISOString() : null
  d.updatedAt = new Date().toISOString()
  if (kind === 'time') d.params['fireDate'] = fireDateISO()
  if (kind === 'stopLoss') {
    if (!tpOn) d.params['takeProfitPrice'] = null
    if (!slOn) d.params['stopLossPrice'] = null
  }
  if (kind === 'trailing' && !d.params['floorEnabled']) d.params['floorPrice'] = null
  return d
}

// ===== UI 回填 =====
function setRowHidden(api: FcApi, name: string, hidden: boolean): void {
  patchRule(api, name, { style: { display: hidden ? 'none' : '' } })
}

function setDim(api: FcApi, name: string, dim: boolean): void {
  patchRule(api, name, { style: { opacity: dim ? '0.4' : '', pointerEvents: dim ? 'none' : '' } })
}

function chipVal(api: FcApi, name: string, value: string): void {
  patchRule(api, name, { props: { modelValue: value } })
}

function canSave(): boolean {
  if (!evaluateResult) return false
  return evaluateResult.ready && !evaluateResult.rejection
}

function setError(api: FcApi, text: string): void {
  errorText = text
  patchRule(api, 'errLine', { props: { text }, style: { display: text ? '' : 'none' } })
}

function syncSave(api: FcApi): void {
  const ok = canSave()
  patchRule(api, 'navRow', { props: { rightDisabled: !ok } })
  patchRule(api, 'createBtn', { props: { disabled: !ok } })
  patchRule(api, 'saveBtn', { props: { disabled: !ok } })
}

function syncChips(api: FcApi): void {
  chipVal(api, 'dirChips', dir)
  chipVal(api, 'kindChips', kind)
  chipVal(api, 'compareUpChips', params()['compareUp'] === false ? '0' : '1')
  chipVal(api, 'baseModeChips', str('baseMode'))
  chipVal(api, 'tpOnChips', tpOn ? '1' : '0')
  chipVal(api, 'slOnChips', slOn ? '1' : '0')
  chipVal(api, 'floorChips', bool('floorEnabled') ? '1' : '0')
  chipVal(api, 'maPeriodChips', num('maPeriod') === null ? '' : String(num('maPeriod')))
  chipVal(api, 'maAboveChips', bool('maAbove') ? '1' : '0')
  chipVal(api, 'multiplierChips', num('gridMultiplier') === null ? '' : String(num('gridMultiplier')))
  chipVal(api, 'batchCountChips', num('batchCount') === null ? '' : String(num('batchCount')))
  chipVal(api, 'changeDirChips', (num('changeThreshold') ?? 0) >= 0 ? 'up' : 'down')
  chipVal(api, 'priceTypeChips', priceType)
  chipVal(api, 'offsetChips', String(offsetTicks))
  chipVal(api, 'validityChips', validity)
}

function syncVisibility(api: FcApi): void {
  const kindGroups: [string, string][] = [
    ['grpPrice', 'price'], ['grpStop', 'stopLoss'], ['grpTrail', 'trailing'], ['grpTime', 'time'],
    ['grpChange', 'changePct'], ['grpMa', 'maCross'], ['grpGrid', 'grid'], ['grpBatch', 'batch'],
  ]
  for (const [name, k] of kindGroups) setRowHidden(api, name, k !== kind)
  setRowHidden(api, 'gridDirNote', kind !== 'grid')
  setRowHidden(api, 'offsetRow', !(priceType === 'limit' && kind !== 'grid'))
  setRowHidden(api, 'gridOrderHint', kind !== 'grid')
  setRowHidden(api, 'qtyRow', kind === 'grid')
  setRowHidden(api, 'posRow', kind === 'grid')
  setRowHidden(api, 'expiryRow', validity !== 'untilDate')
  setDim(api, 'dirRow', kind === 'grid' || (alertOnly && kind !== 'batch'))
  setDim(api, 'orderCard', alertOnly)
  setDim(api, 'multiplierRow', alertOnly)
  patchRule(api, 'gridQtyInput', { props: { disabled: alertOnly } })
  patchRule(api, 'batchQtyInput', { props: { disabled: alertOnly } })
  patchRule(api, 'tpInput', { props: { disabled: !tpOn } })
  patchRule(api, 'slInput', { props: { disabled: !slOn } })
  patchRule(api, 'floorInput', { props: { disabled: !bool('floorEnabled') } })
  patchRule(api, 'trailRow', { props: { title: dir === 'sell' ? '回落幅度' : '反弹幅度' } })
}

function syncTexts(api: FcApi): void {
  patchRule(api, 'navRow', { props: { title: editing ? '编辑条件单' : '新建条件单' } })
  patchRule(api, 'headCard', {
    props: {
      title: ctxData?.meta.name ?? '',
      label: ctxData ? `${ctxData.meta.code} · 最新价` : '',
      value: ctxData?.lastPrice == null ? '—' : ctxData.lastPrice.toFixed(2),
    },
  })
  // 网格档位估算
  const base = num('gridBase'); const low = num('gridLower'); const high = num('gridUpper'); const step = num('gridStepPct')
  let levels: number | null = null
  if (base !== null && low !== null && high !== null && step !== null && step > 0 && high > low) {
    levels = Math.max(1, Math.round(Math.log(high / low) / Math.log(1 + step / 100)))
  }
  patchRule(api, 'gridLevelsHint', {
    props: { text: levels === null ? '' : `区间内约 ${levels} 档` },
    style: { display: levels === null ? 'none' : '' },
  })
  // 分批预览
  patchRule(api, 'batchHint', { props: { text: batchPreviewText() } })
  // 仅提醒提示
  patchRule(api, 'alertHint', {
    props: { text: alertOnly
      ? '开启后触发只记录时间 / 触发价 / 文案，不生成委托与成交；数量与持仓校验会跳过'
      : '关闭时触发后按下方委托指令下单（数量与可卖持仓会被校验）' },
  })
  // 网格下单提示
  patchRule(api, 'gridOrderHint', {
    props: { text: alertOnly ? '网格按「每格数量」下单；仅提醒不会下单' : '网格按「每格数量」下单' },
  })
  // 预览句（占位→就绪两段式）
  patchRule(api, 'previewText', { props: { text: evaluateResult?.previewSentence || '—' } })
  // 提交按钮：编辑/新建形态 + 仅提醒配色
  const color = alertOnly ? '#1989fa' : '#00b578'
  patchRule(api, 'createBtn', { style: { display: editing ? 'none' : '' }, props: { color } })
  patchRule(api, 'saveBtn', { style: { display: editing ? '' : 'none' }, props: { color } })
}

/** 分批建仓预览（对齐源面板 batchPreviewText） */
function batchPreviewText(): string {
  const count = num('batchCount'); const total = num('batchTotalQty')
  const first = num('batchFirstPrice'); const stepPct = num('batchStepPct')
  if (count === null || count < 2 || total === null || total <= 0 || first === null || stepPct === null || stepPct <= 0) {
    return '填齐参数后显示每批数量与末批目标价'
  }
  const lot = Math.max(ctxData?.rules.lotSize ?? 100, 1)
  const per = Math.floor(total / count / lot) * lot
  const offset = (stepPct / 100) * (count - 1)
  const last = dir === 'buy' ? first * (1 - offset) : first * (1 + offset)
  return `每批约 ${per} 股 · 末批目标 ${last.toFixed(2)} 元`
}

/** 表单文本字段回填（params/本地态 → 字段值） */
function refillFields(api: FcApi): void {
  api.setValue({
    triggerPrice: numText('triggerPrice'),
    basePrice: numText('basePrice'),
    takeProfitPrice: numText('takeProfitPrice'),
    stopLossPrice: numText('stopLossPrice'),
    breakoutPrice: numText('breakoutPrice'),
    trailPct: numText('trailPct'),
    floorPrice: numText('floorPrice'),
    changeThreshold: numText('changeThreshold'),
    gridBase: numText('gridBase'),
    gridLower: numText('gridLower'),
    gridUpper: numText('gridUpper'),
    gridStepPct: numText('gridStepPct'),
    gridQtyPerLevel: numText('gridQtyPerLevel'),
    batchTotalQty: numText('batchTotalQty'),
    batchFirstPrice: numText('batchFirstPrice'),
    batchStepPct: numText('batchStepPct'),
    qtyText: qtyTextStr,
    alertOnly,
    fireLocal,
    expiryLocal,
  })
}

function syncAll(api: FcApi): void {
  refillFields(api)
  syncChips(api)
  syncVisibility(api)
  syncTexts(api)
  syncSave(api)
}

async function pull(api: FcApi, ctx: HostContext): Promise<void> {
  ctxRef = ctx
  try {
    ctxData = ((await klineBus.request('cond', 'editorContext')) ?? {}) as unknown as CondEditorContext
  } catch (err) {
    console.error('cond.editorContext 失败', err)
    return
  }
  const e = ctxData.editing as Record<string, any> | null
  if (e) {
    editing = e
    draft = JSON.parse(JSON.stringify(e))
    kind = String(e.kind ?? 'price')
    dir = (e.directive?.direction === 'buy' ? 'buy' : 'sell')
    priceType = (e.directive?.priceType === 'limit' ? 'limit' : 'market')
    offsetTicks = Number(e.directive?.offsetTicks ?? 0)
    qtyTextStr = String(Number(e.directive?.qty ?? 0) || ctxData.initial.qty)
    alertOnly = e.directive?.alertOnly === true
    validity = String(e.validity ?? 'longTerm')
    expiryLocal = isoToDateText(e.expiresAt)
    fireLocal = isoToLocalInput(e.params?.fireDate)
    tpOn = e.params?.takeProfitPrice != null
    slOn = e.params?.stopLossPrice != null
  } else {
    editing = null
    draft = newDraft()
    kind = ctxData.initial.kind
    dir = ctxData.initial.direction
    qtyTextStr = String(ctxData.initial.qty)
    alertOnly = false
    validity = 'longTerm'
    expiryLocal = ''
    fireLocal = ''
    tpOn = true
    slOn = true
    applyKindDefaults()
  }
  evaluateResult = null
  setError(api, '')
  syncAll(api)
  void evaluateNow(api)
}

// ===== evaluate（防抖） =====
function scheduleEvaluate(api: FcApi): void {
  if (evaluateTimer) clearTimeout(evaluateTimer)
  evaluateTimer = setTimeout(() => void evaluateNow(api), 300)
}

async function evaluateNow(api: FcApi): Promise<void> {
  if (!draft) return
  try {
    const d = ((await klineBus.request('cond', 'evaluate', { draft: draftPayload() })) ?? {}) as Record<string, unknown>
    if (d.queued !== true) return
    // 结果随 cond.changed(evaluate) 推送；这里不直接更新（异步链路单一出口）
  } catch (e) {
    console.error('cond.evaluate 失败', e)
  }
}

/** changed 推送 → 结果/保存结果 UI（陈旧 api 静默跳过） */
function handleChanged(api: FcApi, payload: Record<string, unknown> | undefined): void {
  const reason = String(payload?.['reason'] ?? '')
  if (reason === 'evaluate') {
    const draftID = String(payload?.['draftID'] ?? '')
    if (draft && draftID !== draft.id) return   // 旧请求晚到不覆盖
    evaluateResult = payload as unknown as CondEvaluateResult
    setError(api, '')
    syncTexts(api)
    syncSave(api)
  } else if (reason === 'saveResult') {
    if (payload?.['ok'] === true) ctxRef?.close()   // 原生已切回管理页
    else setError(api, String(payload?.['error'] ?? '保存失败'))
  }
}

// ===== 交互动作 =====
function schedule(api: FcApi): void {
  syncChips(api)
  syncVisibility(api)
  syncTexts(api)
  scheduleEvaluate(api)
}

/** 仓位快捷：可买/可卖上限 × 比例整手（近似口径；提交由原生引擎复核） */
function applyPositionRatio(api: FcApi, ratio: number): void {
  if (!ctxData) return
  const lot = Math.max(ctxData.rules.lotSize, 1)
  const price = ctxData.lastPrice ?? 0
  if (dir === 'buy' && price > 0) {
    // 近似：现金 / (价 × (1 + 佣金率))
    const perLot = price * lot * 1.0003
    const lots = Math.floor((ctxData.account.cash * ratio) / Math.max(perLot, 0.01))
    qtyTextStr = String(lots * lot)
  } else if (dir === 'sell') {
    // 可卖来自编辑上下文的持仓（快照未下发时保持 0，引擎校验兜底）
    const available = 0
    qtyTextStr = String(Math.floor(available * ratio))
  }
  api.setValue({ qtyText: qtyTextStr })
  scheduleEvaluate(api)
}

async function save(api: FcApi): Promise<void> {
  if (!canSave()) return
  setError(api, '')
  try {
    await klineBus.request('cond', 'save', { draft: draftPayload() })
    // 结果随 changed(saveResult) 推送（成功原生切回管理页）
  } catch (e) {
    setError(api, String(e instanceof Error ? e.message : e).replace(/^invalid_payload: /, ''))
  }
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    pickDir: (inj) => {
      const d = String(inj.args[0] ?? '')
      if (kind === 'grid') return
      if (alertOnly && kind !== 'batch') return
      if (d !== 'buy' && d !== 'sell') return
      dir = d
      schedule(inj.api)
    },

    selectKind: (inj) => {
      const k = String(inj.args[0] ?? '')
      if (k === kind || !k) return
      selectKind(k)
      syncAll(inj.api)
      scheduleEvaluate(inj.api)
    },

    setCompareUp: (inj) => {
      params()['compareUp'] = String(inj.args[0] ?? '') === '1'
      schedule(inj.api)
    },

    setBaseMode: (inj) => {
      params()['baseMode'] = String(inj.args[0] ?? '')
      schedule(inj.api)
    },

    toggleTp: (inj) => {
      tpOn = !tpOn
      schedule(inj.api)
    },

    toggleSl: (inj) => {
      slOn = !slOn
      schedule(inj.api)
    },

    setFloor: (inj) => {
      params()['floorEnabled'] = String(inj.args[0] ?? '') === '1'
      schedule(inj.api)
    },

    setMaPeriod: (inj) => {
      const v = Number(inj.args[0] ?? 0)
      if (v > 0) params()['maPeriod'] = v
      schedule(inj.api)
    },

    setMaAbove: (inj) => {
      params()['maAbove'] = String(inj.args[0] ?? '') === '1'
      schedule(inj.api)
    },

    setMultiplier: (inj) => {
      const v = Number(inj.args[0] ?? 0)
      if (v > 0) params()['gridMultiplier'] = v
      schedule(inj.api)
    },

    setBatchCount: (inj) => {
      const v = Number(inj.args[0] ?? 0)
      if (v >= 2) params()['batchCount'] = v
      schedule(inj.api)
    },

    setChangeDir: (inj) => {
      const rise = String(inj.args[0] ?? '') === 'up'
      const magnitude = Math.abs(num('changeThreshold') ?? 0)
      params()['changeThreshold'] = rise ? magnitude : -magnitude
      schedule(inj.api)
    },

    pickPriceType: (inj) => {
      const pt = String(inj.args[0] ?? '')
      if (pt !== 'market' && pt !== 'limit') return
      priceType = pt
      if (pt === 'market') offsetTicks = 0
      schedule(inj.api)
    },

    pickOffset: (inj) => {
      const v = Number(inj.args[0] ?? 0)
      if (Number.isFinite(v)) offsetTicks = v
      schedule(inj.api)
    },

    pickValidity: (inj) => {
      const v = String(inj.args[0] ?? '')
      if (!v) return
      validity = v
      schedule(inj.api)
    },

    applyPosition: (inj) => {
      const ratio = Number(inj.args[0] ?? 0)
      if (ratio > 0) applyPositionRatio(inj.api, ratio)
    },

    save: (inj) => {
      void save(inj.api)
    },
  },

  onChange: (field, value, api) => {
    if (NUM_FIELDS.includes(field)) {
      setNumText(field, String(value ?? ''))
      syncTexts(api)
      scheduleEvaluate(api)
      return
    }
    if (field === 'qtyText') {
      const digits = String(value ?? '').replace(/\D/g, '')
      qtyTextStr = digits
      if (digits !== value) api.setValue({ qtyText: digits })
      scheduleEvaluate(api)
      return
    }
    if (field === 'alertOnly') {
      alertOnly = value === true
      setError(api, '')
      syncVisibility(api)
      syncTexts(api)
      scheduleEvaluate(api)
      return
    }
    if (field === 'fireLocal') {
      fireLocal = String(value ?? '')
      const d = new Date(fireLocal)
      if (!Number.isNaN(d.getTime())) params()['fireDate'] = d.toISOString()
      scheduleEvaluate(api)
      return
    }
    if (field === 'expiryLocal') {
      expiryLocal = String(value ?? '')
      scheduleEvaluate(api)
    }
  },

  subscribe: (api, ctx) => {
    ctxRef = ctx
    // evaluate / saveResult 推送（占位→就绪两段式；klineBus 无 off，陈旧 api 静默跳过）
    const handler = (ev: BridgeEvent): void => {
      try {
        handleChanged(api, ev.payload)
      } catch (e) {
        console.warn('[fc] condEditor changed 跳过（面板可能已关闭）', e)
      }
    }
    klineBus.on('cond.changed', handler)
    return () => {}
  },
}

export default adapter

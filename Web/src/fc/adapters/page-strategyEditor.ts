// fc/adapters/page-strategyEditor.ts：策略公式编辑器（page-strategyEditor）逻辑适配器。
// 快照：strategyEdit.snapshot；静态校验/语义预览同步直通（strategyEdit.evaluate）；
// 内嵌公式测试/语法校验异步（testPick → changed(pickTest)，600ms 防抖）；
// 保存走引擎终校 fail-closed（changed(saveResult)）。
import { klineBus } from '../../bridge/klineBus'
import type { BridgeEvent } from '../../types/protocol'
import type {
  StrategyEditorSnapshot,
  StrategyEvaluateResult,
  StrategyRuleRowSnap,
  StrategyTradeSpecSnap,
} from '../../types/protocol'
import type { FcApi, FcPageAdapter, HostContext } from '../types'
import { patchRule } from '../rule-patch'

let snap: StrategyEditorSnapshot | null = null
let nameStr = ''
let mode: 'inline' | 'reference' = 'inline'
let pickBody = ''
let pickRef = ''
let rows: StrategyRuleRowSnap[] = []
let parseErrors: string[] = []
let trade: StrategyTradeSpecSnap = {
  direction: '', hasQty: false, qty: 0, hasAmount: false, amount: 0,
  hasOffset: false, offsetTicks: 0, priceType: '', validity: '', expiresAt: '', accountIDs: [],
}
let sizeMode: 'qty' | 'amount' = 'qty'
let qtyText = ''
let amountText = ''
let offsetText = ''
let expiryText = ''
let testMessage = ''
let testIsError = false
let pickSyntaxError = ''
let issues: string[] | null = null
let preview: StrategyEvaluateResult['preview'] | null = null
let saveError = ''
let evaluateTimer: ReturnType<typeof setTimeout> | null = null
let pickTestTimer: ReturnType<typeof setTimeout> | null = null
let selectReqSeq = 0
let ctxRef: HostContext | null = null

function oneLine(body: string): string {
  const s = body.split('\n').map((x) => x.trim()).filter(Boolean).join(' ')
  return s || '（空公式）'
}

function fmtAmount(v: number): string {
  return Math.round(v).toLocaleString('en-US')
}

function plainNumber(v: number): string {
  if (v === Math.round(v)) return String(Math.round(v))
  return String(v)
}

function kindOf(kind: string) {
  return snap?.ruleCatalog.find((k) => k.kind === kind)
}

/** 规则行内 ORD* 指令覆盖摘要（原生 StrategyTradeParser.override 语义的 Web 侧简化展示） */
function overrideSummary(row: StrategyRuleRowSnap): string {
  const p = row.params
  const dir = p['ORDDIR']
  const qty = p['ORDQTY']
  const amount = p['ORDAMT']
  const pt = p['ORDPT']
  const off = p['ORDOFF']
  const qtyOrAmount = qty ? `${qty} 股` : (amount ? `${amount} 元` : undefined)
  const parts: string[] = []
  if (dir) parts.push(qtyOrAmount ? `${dir === 'buy' ? '买入' : '卖出'} ${qtyOrAmount}` : (dir === 'buy' ? '买入' : '卖出'))
  else if (qtyOrAmount) parts.push(qtyOrAmount)
  if (pt) parts.push(pt === 'limit' ? (off ? `限价 ${Number(off) >= 0 ? '+' : ''}${off} 档` : '限价委托') : '市价委托')
  else if (off) parts.push(`${Number(off) >= 0 ? '+' : ''}${off} 档`)
  return parts.length ? parts.join(' ') : ''
}

// ===== 校验/保存判定 =====
function canSave(): boolean {
  if (!issues) return false   // 引擎/静态校验未就绪 → 不可保存
  return issues.length === 0 && !!nameStr.trim()
}

function staleAccountCount(): number {
  if (!snap) return 0
  return trade.accountIDs.filter((id) => {
    const a = snap!.accounts.find((x) => x.id === id)
    return !a || a.archived
  }).length
}

function docPayload(): Record<string, unknown> {
  return {
    id: snap?.doc.id ?? '',
    name: nameStr,
    mode,
    pickBody,
    pickRef,
    rows: rows.map((r) => ({ kind: r.kind, params: { ...r.params } })),
    trade: { ...trade },
  }
}

// ===== UI 回填 =====
function setRowHidden(api: FcApi, name: string, hidden: boolean): void {
  patchRule(api, name, { style: { display: hidden ? 'none' : '' } })
}

function chipVal(api: FcApi, name: string, value: string): void {
  patchRule(api, name, { props: { modelValue: value } })
}

function syncChips(api: FcApi): void {
  chipVal(api, 'modeChips', mode)
  chipVal(api, 'dirChips', trade.direction)
  chipVal(api, 'sizeModeChips', sizeMode)
  chipVal(api, 'qtyChips', trade.hasQty && [100, 500, 1000].includes(trade.qty) ? String(trade.qty) : '')
  chipVal(api, 'priceTypeChips', trade.priceType)
  chipVal(api, 'validityChips', trade.validity)
}

function syncVisibility(api: FcApi): void {
  setRowHidden(api, 'inlineBlock', mode !== 'inline')
  setRowHidden(api, 'refBlock', mode === 'inline')
  setRowHidden(api, 'qtyInline', sizeMode !== 'qty')
  setRowHidden(api, 'amountBlock', sizeMode === 'qty')
  setRowHidden(api, 'offsetInline', trade.priceType !== 'limit')
  setRowHidden(api, 'expiryInline', trade.validity !== 'untilDate')
  setRowHidden(api, 'dirWarn', !!trade.direction)
  const stale = staleAccountCount()
  patchRule(api, 'staleWarn', {
    props: { text: `${stale} 个已归档/失效账户已自动跳过` },
    style: { display: stale > 0 ? '' : 'none' },
  })
}

function syncTestMsg(api: FcApi): void {
  patchRule(api, 'testMsg', {
    props: { text: testMessage, danger: testIsError, plain: !testIsError },
    style: { display: testMessage ? '' : 'none' },
  })
}

function syncTexts(api: FcApi): void {
  // 样例行情未就绪提示
  setRowHidden(api, 'dataNote', !(snap?.hasData === false && !!pickBody.trim()))
  syncTestMsg(api)
  // 静态解析错误
  patchRule(api, 'parseErrs', {
    props: { text: parseErrors.join('\n') },
    style: { display: parseErrors.length > 0 ? '' : 'none', whiteSpace: 'pre-line' },
  })
  // 预览卡 / 校验中占位
  const hasPreview = preview !== null
  patchRule(api, 'pvTrade', { props: { text: preview?.trade ?? '' }, style: { display: hasPreview ? '' : 'none' } })
  patchRule(api, 'pvSummary', { props: { text: preview?.summary ?? '' }, style: { display: hasPreview ? '' : 'none' } })
  patchRule(api, 'pvNotice', { props: { text: preview?.executionNotice ?? '' }, style: { display: hasPreview ? '' : 'none' } })
  setRowHidden(api, 'pendingNote', hasPreview)
  // 校验红字（issues + saveError）
  const lines = [...(issues ?? [])]
  if (saveError) lines.push(saveError)
  patchRule(api, 'issuesLine', {
    props: { text: lines.join('\n') },
    style: { display: lines.length > 0 ? '' : 'none', whiteSpace: 'pre-line' },
  })
  syncSave(api)
}

function syncSave(api: FcApi): void {
  const ok = canSave()
  patchRule(api, 'navRow', { props: { rightDisabled: !ok } })
  patchRule(api, 'saveBtn', { props: { disabled: !ok } })
}

/** 规则行视图模型（目录 specs + 行参数值） */
function rebuildRuleRows(api: FcApi): void {
  api.setValue({
    ruleRows: {
      rows: rows.map((r) => {
        const k = kindOf(r.kind)
        return {
          kind: r.kind,
          mapping: k?.conditionOrderTitle ?? '',
          summary: overrideSummary(r),
          specs: (k?.specs ?? []).map((s) => ({
            key: s.key, title: s.title, type: s.type,
            placeholder: s.placeholder, options: s.options, unit: s.unit,
            value: r.params[s.key] ?? '',
          })),
        }
      }),
      catalog: (snap?.ruleCatalog ?? []).map((k) => ({ kind: k.kind, title: k.title })),
    },
  })
}

function rebuildPickers(api: FcApi): void {
  api.setValue({
    pickerList: {
      rows: (snap?.pickers ?? []).map((p) => ({
        id: p.id, title: p.name, subtitle: oneLine(p.pickBody), checked: pickRef === p.id,
      })),
      emptyText: '公式库还没有选股公式，请先到「选股指标」段新建',
    },
  })
}

function rebuildAccounts(api: FcApi): void {
  api.setValue({
    accountList: {
      rows: (snap?.accounts ?? []).map((a) => ({
        id: a.id,
        title: a.name,
        subtitle: `可买资金 ${fmtAmount(a.cash)}`,
        dotColor: a.colorHex,
        dotText: a.badge,
        checked: a.archived ? undefined : trade.accountIDs.includes(a.id),
        disabled: a.archived,
        trailing: a.archived ? '已归档' : undefined,
      })),
      emptyText: '还没有模拟账户，请先到模拟页创建',
    },
  })
}

function refill(api: FcApi): void {
  api.setValue({ name: nameStr, pickBody, qtyText, amountText, offsetText, expiryText })
}

async function pull(api: FcApi, ctx: HostContext): Promise<void> {
  ctxRef = ctx
  try {
    const d = ((await klineBus.request('strategyEdit', 'snapshot')) ?? {}) as Record<string, unknown>
    const doc = (d.doc ?? {}) as Record<string, unknown>
    snap = {
      doc: doc as unknown as StrategyEditorSnapshot['doc'],
      pickers: (d.pickers ?? []) as StrategyEditorSnapshot['pickers'],
      accounts: (d.accounts ?? []) as StrategyEditorSnapshot['accounts'],
      ruleCatalog: (d.ruleCatalog ?? []) as StrategyEditorSnapshot['ruleCatalog'],
      hasData: d.hasData === true,
    }
    const td = doc.trade as StrategyTradeSpecSnap | undefined
    nameStr = String(doc.name ?? '')
    mode = (doc.mode === 'reference' ? 'reference' : 'inline')
    pickBody = String(doc.pickBody ?? '')
    pickRef = String(doc.pickRef ?? '')
    rows = (doc.rows ?? []) as StrategyRuleRowSnap[]
    parseErrors = (doc.parseErrors ?? []) as string[]
    trade = td ?? trade
    sizeMode = td?.hasQty ? 'qty' : (td?.hasAmount ? 'amount' : 'qty')
    qtyText = td?.hasQty ? String(td.qty) : ''
    amountText = td?.hasAmount ? plainNumber(td.amount) : ''
    offsetText = td?.hasOffset ? String(td.offsetTicks) : ''
    expiryText = String(td?.expiresAt ?? '')
    testMessage = ''
    testIsError = false
    pickSyntaxError = ''
    saveError = ''
    issues = null
    preview = null
    rebuildRuleRows(api)
    rebuildPickers(api)
    rebuildAccounts(api)
    refill(api)
    syncChips(api)
    syncVisibility(api)
    syncTexts(api)
    // 内嵌模式且有正文 → 打开即做一次语法校验（对齐原生 onAppear schedulePickSyntaxCheck）
    if (mode === 'inline' && pickBody.trim()) runTest(api)
    else void evaluateNow(api)
  } catch (e) {
    console.error('strategyEdit.snapshot 失败', e)
  }
}

// ===== evaluate（防抖）=====
function scheduleEvaluate(api: FcApi): void {
  if (evaluateTimer) clearTimeout(evaluateTimer)
  evaluateTimer = setTimeout(() => void evaluateNow(api), 300)
}

async function evaluateNow(api: FcApi): Promise<void> {
  try {
    const d = ((await klineBus.request('strategyEdit', 'evaluate', {
      doc: docPayload(),
      pickSyntaxError,
    })) ?? {}) as unknown as StrategyEvaluateResult
    issues = d.issues
    preview = d.preview
    syncTexts(api)
  } catch (e) {
    console.error('strategyEdit.evaluate 失败', e)
  }
}

function runTest(api: FcApi): void {
  testMessage = '计算中…'
  testIsError = false
  syncTestMsg(api)
  void klineBus.request('strategyEdit', 'testPick', { pickBody }).catch((e) => {
    testMessage = `✗ ${String(e instanceof Error ? e.message : e).slice(0, 60)}`
    testIsError = true
    syncTestMsg(api)
  })
}

function schedulePickTest(api: FcApi): void {
  if (pickTestTimer) clearTimeout(pickTestTimer)
  pickTestTimer = setTimeout(() => runTest(api), 600)
}

async function save(api: FcApi): Promise<void> {
  if (!canSave()) return
  saveError = ''
  try {
    await klineBus.request('strategyEdit', 'save', {
      doc: docPayload(),
      pickSyntaxError,
    })
    // 静态校验过 → 原生后台引擎终校 + 写库；结果随 changed(saveResult) 推送（成功原生关页）
  } catch (e) {
    saveError = String(e instanceof Error ? e.message : e).replace(/^invalid_payload: /, '')
    syncTexts(api)
  }
}

function handleChanged(api: FcApi, payload: Record<string, unknown> | undefined): void {
  const reason = String(payload?.['reason'] ?? '')
  if (reason === 'pickTest') {
    pickSyntaxError = String(payload?.['syntaxError'] ?? '')
    testMessage = String(payload?.['testMessage'] ?? '')
    testIsError = payload?.['testIsError'] === true
    syncTestMsg(api)
    void evaluateNow(api)
  } else if (reason === 'saveResult') {
    if (payload?.['ok'] === true) {
      ctxRef?.close()   // 原生已关页，本地同步清理
    } else {
      saveError = String(payload?.['error'] ?? '保存失败')
      syncTexts(api)
    }
  } else if (reason === 'dataReady') {
    if (snap) snap.hasData = true
    if (mode === 'inline' && pickBody.trim()) runTest(api)
  }
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    setMode: (inj) => {
      const m = String(inj.args[0] ?? '')
      if ((m !== 'inline' && m !== 'reference') || m === mode) return
      mode = m
      syncChips(inj.api)
      syncVisibility(inj.api)
      if (mode === 'inline' && pickBody.trim()) runTest(inj.api)
      else void evaluateNow(inj.api)
    },

    pickTool: (inj) => {
      const tool = String(inj.args[0] ?? '')
      const api = inj.api
      if (tool === 'selectAll') {
        selectReqSeq += 1
        patchRule(api, 'pickInput', { props: { selectReq: selectReqSeq } })
      } else if (tool === 'clearPick') {
        pickBody = ''
        testMessage = ''
        testIsError = false
        api.setValue({ pickBody })
        syncTestMsg(api)
      } else if (tool === 'runTest') {
        runTest(api)
      }
    },

    toggleDir: (inj) => {
      const d = String(inj.args[0] ?? '')
      if (d !== 'buy' && d !== 'sell') return
      trade.direction = trade.direction === d ? '' : d
      syncChips(inj.api)
      syncVisibility(inj.api)
      scheduleEvaluate(inj.api)
    },

    pickSizeMode: (inj) => {
      const m = String(inj.args[0] ?? '')
      if ((m !== 'qty' && m !== 'amount') || m === sizeMode) return
      sizeMode = m
      if (m === 'qty') { trade.hasAmount = false; trade.amount = 0; amountText = '' }
      else { trade.hasQty = false; trade.qty = 0; qtyText = '' }
      inj.api.setValue({ qtyText, amountText })
      syncChips(inj.api)
      syncVisibility(inj.api)
      scheduleEvaluate(inj.api)
    },

    setQty: (inj) => {
      const v = Number(inj.args[0] ?? 0)
      if (![100, 500, 1000].includes(v)) return
      trade.hasQty = true
      trade.qty = v
      qtyText = String(v)
      inj.api.setValue({ qtyText })
      syncChips(inj.api)
      scheduleEvaluate(inj.api)
    },

    pickPriceType: (inj) => {
      const pt = String(inj.args[0] ?? '')
      if ((pt !== 'market' && pt !== 'limit') || pt === trade.priceType) return
      trade.priceType = pt
      if (pt === 'market') { trade.hasOffset = false; trade.offsetTicks = 0; offsetText = '' }
      else if (!trade.hasOffset) { trade.hasOffset = true; trade.offsetTicks = 0; offsetText = '0' }
      inj.api.setValue({ offsetText })
      syncChips(inj.api)
      syncVisibility(inj.api)
      scheduleEvaluate(inj.api)
    },

    pickValidity: (inj) => {
      const v = String(inj.args[0] ?? '')
      if (!v || v === trade.validity) return
      trade.validity = v
      if (v !== 'untilDate') trade.expiresAt = ''
      syncChips(inj.api)
      syncVisibility(inj.api)
      scheduleEvaluate(inj.api)
    },

    pickRefToggle: (inj) => {
      const id = String(inj.args[0] ?? '')
      if (!id) return
      pickRef = id
      rebuildPickers(inj.api)
      scheduleEvaluate(inj.api)
    },

    toggleAccount: (inj) => {
      const id = String(inj.args[0] ?? '')
      if (!id) return
      const list = trade.accountIDs
      const idx = list.indexOf(id)
      if (idx >= 0) list.splice(idx, 1)
      else list.push(id)
      rebuildAccounts(inj.api)
      scheduleEvaluate(inj.api)
    },

    addRule: (inj) => {
      rows.push({ kind: 'PRICE', params: {} })
      rebuildRuleRows(inj.api)
      scheduleEvaluate(inj.api)
    },

    ruleKind: (inj) => {
      const p = inj.args[0] as { idx: number; kind: string } | undefined
      if (!p || !rows[p.idx]) return
      rows[p.idx].kind = p.kind
      rows[p.idx].params = {}
      rebuildRuleRows(inj.api)
      scheduleEvaluate(inj.api)
    },

    ruleParam: (inj) => {
      const p = inj.args[0] as { idx: number; key: string; value: string } | undefined
      if (!p || !rows[p.idx]) return
      rows[p.idx].params[p.key] = p.value
      scheduleEvaluate(inj.api)
    },

    ruleDel: (inj) => {
      const p = inj.args[0] as { idx: number } | undefined
      if (!p || !rows[p.idx]) return
      rows.splice(p.idx, 1)
      rebuildRuleRows(inj.api)
      scheduleEvaluate(inj.api)
    },

    save: (inj) => {
      void save(inj.api)
    },
  },

  onChange: (field, value, api) => {
    if (field === 'name') {
      nameStr = String(value ?? '')
      syncSave(api)
      scheduleEvaluate(api)
      return
    }
    if (field === 'pickBody') {
      pickBody = String(value ?? '')
      scheduleEvaluate(api)
      // 正文变化 → 重新做语法校验/测试（防抖）
      schedulePickTest(api)
      return
    }
    if (field === 'qtyText') {
      const digits = String(value ?? '').replace(/\D/g, '')
      qtyText = digits
      trade.hasQty = digits.length > 0
      trade.qty = digits.length > 0 ? parseInt(digits, 10) : 0
      if (digits !== value) api.setValue({ qtyText: digits })
      syncChips(api)
      scheduleEvaluate(api)
      return
    }
    if (field === 'amountText') {
      amountText = String(value ?? '')
      const v = parseFloat(amountText)
      trade.hasAmount = Number.isFinite(v) && v > 0
      trade.amount = trade.hasAmount ? v : 0
      scheduleEvaluate(api)
      return
    }
    if (field === 'offsetText') {
      offsetText = String(value ?? '').trim()
      trade.hasOffset = offsetText.length > 0
      trade.offsetTicks = offsetText.length > 0 ? (parseInt(offsetText, 10) || 0) : 0
      scheduleEvaluate(api)
      return
    }
    if (field === 'expiryText') {
      expiryText = String(value ?? '')
      trade.expiresAt = expiryText
      scheduleEvaluate(api)
    }
  },

  subscribe: (api, ctx) => {
    ctxRef = ctx
    // pickTest / saveResult / dataReady 推送（陈旧 api 静默跳过）
    const handler = (ev: BridgeEvent): void => {
      try {
        handleChanged(api, ev.payload)
      } catch (e) {
        console.warn('[fc] strategyEditor changed 跳过（面板可能已关闭）', e)
      }
    }
    klineBus.on('strategyEdit.changed', handler)
    return () => {}
  },
}

export default adapter

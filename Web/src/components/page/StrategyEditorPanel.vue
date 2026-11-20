<template>
  <div class="sep">
    <!-- 页头：取消 ｜ 标题 ｜ 保存（对齐原生 header 令牌） -->
    <div class="nav-line">
      <button class="nav-link" aria-label="strategyEditor.cancel" @click="onBack">取消</button>
      <span class="nav-center">策略公式</span>
      <button
        class="nav-link save"
        aria-label="strategyEditor.save"
        :disabled="!canSave"
        @click="save"
      >保存</button>
    </div>

    <div class="sep-body" v-if="snap">
      <!-- 名称 -->
      <div class="sep-field">
        <div class="sep-label">名称</div>
        <input v-model="name" class="sep-input" placeholder="例如：趋势回踩策略" />
      </div>

      <!-- 选股条件（内嵌 / 引用 二选一） -->
      <div class="sep-field">
        <div class="sep-label">选股条件</div>
        <div class="seg-bar">
          <button
            v-for="m in pickModes"
            :key="m.value"
            class="seg-item"
            :class="{ on: mode === m.value }"
            @click="mode = m.value"
          >{{ m.title }}</button>
        </div>

        <template v-if="mode === 'inline'">
          <textarea
            ref="pickEl"
            class="sep-formula"
            :value="pickBody"
            aria-label="strategyEditor.pickBody"
            spellcheck="false"
            autocapitalize="characters"
            autocorrect="off"
            @input="onPickInput"
          ></textarea>
          <div class="tool-row">
            <button class="tool-link" @click="selectAllPick">全选</button>
            <button class="tool-link" @click="pickBody = ''; testMessage = ''">清空</button>
            <button class="tool-link" aria-label="strategyEditor.testPick" @click="runTest">测试选股公式</button>
          </div>
          <div v-if="snap.hasData === false && pickBody.trim()" class="sep-note">
            样例行情未就绪，语法校验待行情到达后进行
          </div>
          <div v-if="testMessage" class="sep-test" :class="{ err: testIsError }">{{ testMessage }}</div>
        </template>

        <template v-else>
          <div v-if="snap.pickers.length === 0" class="block-empty">
            公式库还没有选股公式，请先到「选股指标」段新建
          </div>
          <div v-else class="ref-list">
            <button
              v-for="p in snap.pickers"
              :key="p.id"
              class="ref-row"
              @click="pickRef = p.id"
            >
              <span class="ref-check">{{ pickRef === p.id ? '☑' : '☐' }}</span>
              <span class="ref-text">
                <span class="ref-name">{{ p.name }}</span>
                <span class="ref-body">{{ oneLine(p.pickBody) }}</span>
              </span>
            </button>
          </div>
        </template>
      </div>

      <!-- 交易指令 -->
      <div class="sep-field">
        <div class="sep-label">交易指令</div>
        <div class="trade-card">
          <div class="t-row">
            <span class="t-cap">方向</span>
            <span v-if="!trade.direction" class="t-warn">请选择</span>
          </div>
          <div class="seg-bar tight">
            <button class="seg-item" :class="{ on: trade.direction === 'buy', buy: trade.direction === 'buy' }" @click="toggleDir('buy')">买入</button>
            <button class="seg-item" :class="{ on: trade.direction === 'sell', sell: trade.direction === 'sell' }" @click="toggleDir('sell')">卖出</button>
          </div>

          <div class="t-row"><span class="t-cap">数量 / 金额</span></div>
          <div class="seg-bar tight">
            <button class="seg-item" :class="{ on: sizeMode === 'qty' }" @click="pickSizeMode('qty')">按数量</button>
            <button class="seg-item" :class="{ on: sizeMode === 'amount' }" @click="pickSizeMode('amount')">按金额</button>
          </div>
          <div v-if="sizeMode === 'qty'" class="t-inline">
            <input v-model="qtyText" class="t-input qty" inputmode="numeric" placeholder="100" @input="syncQty" />
            <span class="t-unit">股</span>
            <button v-for="v in [100, 500, 1000]" :key="v" class="mini-chip" :class="{ on: trade.hasQty && trade.qty === v }" @click="setQty(v)">{{ v }}</button>
          </div>
          <template v-else>
            <div class="t-inline">
              <input v-model="amountText" class="t-input amount" inputmode="decimal" placeholder="50000" @input="syncAmount" />
              <span class="t-unit">元</span>
            </div>
            <div class="sep-note">生成条件单时按最新价折算并向下取整到 100 股</div>
          </template>

          <div class="t-row"><span class="t-cap">报价方式</span></div>
          <div class="seg-bar tight">
            <button class="seg-item" :class="{ on: trade.priceType === 'market' }" @click="pickPriceType('market')">市价</button>
            <button class="seg-item" :class="{ on: trade.priceType === 'limit' }" @click="pickPriceType('limit')">限价</button>
          </div>
          <div v-if="trade.priceType === 'limit'" class="t-inline col">
            <div class="t-inline">
              <input v-model="offsetText" class="t-input offset" inputmode="numeric" placeholder="0" @input="syncOffset" />
              <span class="t-unit">档</span>
            </div>
            <div class="sep-note">触达触发价 ± N 档委托</div>
          </div>

          <div class="t-row"><span class="t-cap">有效期</span></div>
          <div class="chip-row">
            <button v-for="v in validityChips" :key="v.value" class="mini-chip" :class="{ on: trade.validity === v.value }" @click="pickValidity(v.value)">{{ v.title }}</button>
          </div>
          <div v-if="trade.validity === 'untilDate'" class="t-inline">
            <span class="t-unit">到期日</span>
            <input v-model="expiryText" type="date" class="t-date" @change="syncExpiry" />
          </div>
        </div>
      </div>

      <!-- 绑定账户（可多选） -->
      <div class="sep-field">
        <div class="sep-label">绑定账户（可多选）</div>
        <div v-if="staleAccountCount > 0" class="warn-line">{{ staleAccountCount }} 个已归档/失效账户已自动跳过</div>
        <div v-if="snap.accounts.length === 0" class="block-empty">还没有模拟账户，请先到模拟页创建</div>
        <div v-else class="ref-list">
          <button
            v-for="a in snap.accounts"
            :key="a.id"
            class="ref-row"
            :disabled="a.archived"
            :class="{ archived: a.archived }"
            @click="toggleAccount(a.id)"
          >
            <span class="acc-dot" :style="{ background: '#' + a.colorHex }">{{ a.badge }}</span>
            <span class="ref-text">
              <span class="ref-name" :class="{ dim: a.archived }">{{ a.name }}</span>
              <span class="ref-body">可买资金 {{ fmtAmount(a.cash) }}</span>
            </span>
            <span v-if="a.archived" class="archived-tag">已归档</span>
            <span v-else class="ref-check">{{ trade.accountIDs.includes(a.id) ? '☑' : '☐' }}</span>
          </button>
        </div>
        <div class="sep-note">生成条件单时会为每个账户各生成一套；多账户并行执行</div>
      </div>

      <!-- 交易规则（RULES） -->
      <div class="sep-field">
        <div class="rules-head">
          <span class="sep-label strong">交易规则（RULES）</span>
          <button class="tool-link" aria-label="strategyEditor.addRule" @click="addRow">＋ 添加规则</button>
        </div>
        <div v-if="parseErrors.length" class="parse-errors">
          <div v-for="(e, i) in parseErrors" :key="i" class="issue-line">✗ {{ e }}</div>
        </div>
        <div v-if="rows.length === 0" class="block-empty">还没有交易规则，点击右上「添加规则」新增一条</div>
        <div v-else class="rule-list">
          <div v-for="(row, idx) in rows" :key="idx" class="rule-card">
            <div class="rule-head">
              <select v-model="row.kind" class="rule-kind" @change="changeKind(idx)">
                <option v-for="k in snap.ruleCatalog" :key="k.kind" :value="k.kind">{{ k.title }}</option>
              </select>
              <span class="rule-mapping">{{ kindOf(row.kind)?.conditionOrderTitle }}</span>
              <button class="rule-del" :aria-label="`strategyEditor.delRule.${idx}`" @click="deleteRow(idx)">🗑</button>
            </div>
            <div v-if="overrideSummary(row)" class="sep-note">指令：{{ overrideSummary(row) }}</div>
            <template v-if="(kindOf(row.kind)?.specs.length ?? 0) > 0">
              <div v-for="spec in kindOf(row.kind)!.specs" :key="spec.key" class="param-row">
                <span class="param-cap">{{ spec.title }}</span>
                <select
                  v-if="spec.type === 'option'"
                  v-model="row.params[spec.key]"
                  class="param-select"
                >
                  <option value="">{{ spec.placeholder }}（未设置）</option>
                  <option v-for="o in spec.options" :key="o" :value="o">{{ o }}</option>
                </select>
                <input
                  v-else
                  v-model="row.params[spec.key]"
                  class="param-input"
                  :inputmode="spec.type === 'integer' ? 'numeric' : (spec.type === 'text' ? 'text' : 'decimal')"
                  :placeholder="spec.placeholder"
                />
                <span v-if="spec.unit" class="t-unit">{{ spec.unit }}</span>
              </div>
            </template>
            <div v-else class="sep-note">{{ placeholderText }} 参数加载中</div>
          </div>
        </div>
      </div>

      <!-- 预览卡 -->
      <div class="sep-field" v-if="preview">
        <div class="preview-card">
          <div class="pv-trade">{{ preview.trade }}</div>
          <div class="pv-summary">{{ preview.summary }}</div>
          <div class="pv-notice">{{ preview.executionNotice }}</div>
        </div>
      </div>
      <div class="sep-field" v-else>
        <div class="sep-note">{{ placeholderText }} 校验中</div>
      </div>

      <!-- 校验红字 -->
      <div v-if="issues && (issues.length || saveError)" class="issues-block">
        <div v-for="(e, i) in issues" :key="i" class="issue-line">✗ {{ e }}</div>
        <div v-if="saveError" class="issue-line">✗ {{ saveError }}</div>
      </div>

      <button class="save-big" :disabled="!canSave" @click="save">保存策略公式</button>
      <div style="height: 16px"></div>
    </div>

    <div v-else class="sep-loading">加载中…</div>
  </div>
</template>

<script setup lang="ts">
// P2-8b：策略公式编辑器 Web 页（strategyEditor）。编辑态为 Web 本地表单；
// 静态校验/语义预览同步直通（strategyEdit.evaluate）；内嵌公式测试/语法校验异步
// （testPick → changed(pickTest)）；保存走引擎终校 fail-closed（changed(saveResult)）。
import { computed, onMounted, ref } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type {
  StrategyEditorSnapshot,
  StrategyRuleRowSnap,
  StrategyTradeSpecSnap,
  StrategyEvaluateResult,
} from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const snap = ref<StrategyEditorSnapshot | null>(null)
const name = ref('')
const mode = ref<'inline' | 'reference'>('inline')
const pickBody = ref('')
const pickRef = ref('')
const rows = ref<StrategyRuleRowSnap[]>([])
const parseErrors = ref<string[]>([])
const trade = ref<StrategyTradeSpecSnap>({
  direction: '', hasQty: false, qty: 0, hasAmount: false, amount: 0,
  hasOffset: false, offsetTicks: 0, priceType: '', validity: '', expiresAt: '', accountIDs: [],
})
const sizeMode = ref<'qty' | 'amount'>('qty')
const qtyText = ref('')
const amountText = ref('')
const offsetText = ref('')
const expiryText = ref('')
const testMessage = ref('')
const testIsError = ref(false)
const pickSyntaxError = ref('')
const issues = ref<string[] | null>(null)
const preview = ref<StrategyEvaluateResult['preview'] | null>(null)
const saveError = ref('')
const placeholderText = 'Python 引擎计算中'

const pickModes = [
  { value: 'inline' as const, title: '内嵌公式' },
  { value: 'reference' as const, title: '引用选股公式' },
]
const validityChips = [
  { value: 'day', title: '当日' },
  { value: 'longTerm', title: '长期' },
  { value: 'untilDate', title: '指定日期' },
]

const pickEl = ref<HTMLTextAreaElement | null>(null)

function kindOf(kind: string) {
  return snap.value?.ruleCatalog.find((k) => k.kind === kind)
}

function oneLine(body: string): string {
  const s = body.split('\n').map((x) => x.trim()).filter(Boolean).join(' ')
  return s || '（空公式）'
}

function fmtAmount(v: number): string {
  return Math.round(v).toLocaleString('en-US')
}

// ===== 校验/保存判定 =====
const canSave = computed(() => {
  if (!issues.value) return false   // 引擎/静态校验未就绪 → 不可保存
  return issues.value.length === 0 && !!name.value.trim()
})

const staleAccountCount = computed(() => {
  if (!snap.value) return 0
  return trade.value.accountIDs.filter((id) => {
    const a = snap.value!.accounts.find((x) => x.id === id)
    return !a || a.archived
  }).length
})

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

// ===== 快照拉取与初始化 =====
async function pullSnapshot(): Promise<void> {
  try {
    const d = ((await klineBus.request('strategyEdit', 'snapshot')) ?? {}) as Record<string, unknown>
    const doc = (d.doc ?? {}) as Record<string, unknown>
    snap.value = {
      doc: doc as unknown as StrategyEditorSnapshot['doc'],
      pickers: (d.pickers ?? []) as StrategyEditorSnapshot['pickers'],
      accounts: (d.accounts ?? []) as StrategyEditorSnapshot['accounts'],
      ruleCatalog: (d.ruleCatalog ?? []) as StrategyEditorSnapshot['ruleCatalog'],
      hasData: d.hasData === true,
    }
    const td = doc.trade as StrategyTradeSpecSnap | undefined
    name.value = String(doc.name ?? '')
    mode.value = (doc.mode === 'reference' ? 'reference' : 'inline')
    pickBody.value = String(doc.pickBody ?? '')
    pickRef.value = String(doc.pickRef ?? '')
    rows.value = (doc.rows ?? []) as StrategyRuleRowSnap[]
    parseErrors.value = (doc.parseErrors ?? []) as string[]
    trade.value = td ?? trade.value
    sizeMode.value = td?.hasQty ? 'qty' : (td?.hasAmount ? 'amount' : 'qty')
    qtyText.value = td?.hasQty ? String(td.qty) : ''
    amountText.value = td?.hasAmount ? plainNumber(td.amount) : ''
    offsetText.value = td?.hasOffset ? String(td.offsetTicks) : ''
    expiryText.value = String(td?.expiresAt ?? '')
    testMessage.value = ''
    testIsError.value = false
    pickSyntaxError.value = ''
    saveError.value = ''
    // 内嵌模式且有正文 → 打开即做一次语法校验（对齐原生 onAppear schedulePickSyntaxCheck）
    if (mode.value === 'inline' && pickBody.value.trim()) runTest()
    else void evaluateNow()
  } catch (e) {
    console.error('strategyEdit.snapshot 失败', e)
  }
}

function plainNumber(v: number): string {
  if (v === Math.round(v)) return String(Math.round(v))
  return String(v)
}

// ===== evaluate（防抖）=====
let evaluateTimer: ReturnType<typeof setTimeout> | null = null

function scheduleEvaluate(): void {
  if (evaluateTimer) clearTimeout(evaluateTimer)
  evaluateTimer = setTimeout(() => void evaluateNow(), 300)
}

async function evaluateNow(): Promise<void> {
  try {
    const d = ((await klineBus.request('strategyEdit', 'evaluate', {
      doc: docPayload(),
      pickSyntaxError: pickSyntaxError.value,
    })) ?? {}) as StrategyEvaluateResult
    issues.value = d.issues
    preview.value = d.preview
  } catch (e) {
    console.error('strategyEdit.evaluate 失败', e)
  }
}

function docPayload(): Record<string, unknown> {
  return {
    id: snap.value?.doc.id ?? '',
    name: name.value,
    mode: mode.value,
    pickBody: pickBody.value,
    pickRef: pickRef.value,
    rows: rows.value.map((r) => ({ kind: r.kind, params: r.params })),
    trade: { ...trade.value },
  }
}

// ===== 表单交互 =====
function onPickInput(e: Event): void {
  const el = e.target as HTMLTextAreaElement
  const pos = el.selectionStart
  const up = el.value.toUpperCase()
  if (up !== el.value) {
    el.value = up
    if (pos !== null) el.setSelectionRange(pos, pos)
  }
  pickBody.value = up
  scheduleEvaluate()
  // 正文变化 → 重新做语法校验/测试（防抖）
  schedulePickTest()
}

let pickTestTimer: ReturnType<typeof setTimeout> | null = null

function schedulePickTest(): void {
  if (pickTestTimer) clearTimeout(pickTestTimer)
  pickTestTimer = setTimeout(() => runTest(), 600)
}

function selectAllPick(): void {
  const el = pickEl.value
  if (!el) return
  el.focus()
  el.setSelectionRange(0, pickBody.value.length)
}

function runTest(): void {
  testMessage.value = '计算中…'
  testIsError.value = false
  void klineBus.request('strategyEdit', 'testPick', { pickBody: pickBody.value }).catch((e) => {
    testMessage.value = `✗ ${String(e instanceof Error ? e.message : e).slice(0, 60)}`
    testIsError.value = true
  })
}

function toggleDir(d: 'buy' | 'sell'): void {
  trade.value.direction = trade.value.direction === d ? '' : d
  scheduleEvaluate()
}

function pickSizeMode(m: 'qty' | 'amount'): void {
  sizeMode.value = m
  if (m === 'qty') { trade.value.hasAmount = false; trade.value.amount = 0; amountText.value = '' }
  else { trade.value.hasQty = false; trade.value.qty = 0; qtyText.value = '' }
  scheduleEvaluate()
}

function syncQty(): void {
  const digits = qtyText.value.replace(/\D/g, '')
  trade.value.hasQty = digits.length > 0
  trade.value.qty = digits.length > 0 ? parseInt(digits, 10) : 0
  scheduleEvaluate()
}

function setQty(v: number): void {
  trade.value.hasQty = true
  trade.value.qty = v
  qtyText.value = String(v)
  scheduleEvaluate()
}

function syncAmount(): void {
  const v = parseFloat(amountText.value)
  trade.value.hasAmount = Number.isFinite(v) && v > 0
  trade.value.amount = trade.value.hasAmount ? v : 0
  scheduleEvaluate()
}

function pickPriceType(pt: 'market' | 'limit'): void {
  trade.value.priceType = pt
  if (pt === 'market') { trade.value.hasOffset = false; trade.value.offsetTicks = 0; offsetText.value = '' }
  else if (!trade.value.hasOffset) { trade.value.hasOffset = true; trade.value.offsetTicks = 0; offsetText.value = '0' }
  scheduleEvaluate()
}

function syncOffset(): void {
  const t = offsetText.value.trim()
  trade.value.hasOffset = t.length > 0
  trade.value.offsetTicks = t.length > 0 ? (parseInt(t, 10) || 0) : 0
  scheduleEvaluate()
}

function pickValidity(v: string): void {
  trade.value.validity = v
  if (v !== 'untilDate') { trade.value.expiresAt = '' }
  scheduleEvaluate()
}

function syncExpiry(): void {
  trade.value.expiresAt = expiryText.value
  scheduleEvaluate()
}

function toggleAccount(id: string): void {
  const list = trade.value.accountIDs
  const idx = list.indexOf(id)
  if (idx >= 0) list.splice(idx, 1)
  else list.push(id)
  scheduleEvaluate()
}

function addRow(): void {
  rows.value.push({ kind: 'PRICE', params: {} })
  scheduleEvaluate()
}

function changeKind(idx: number): void {
  rows.value[idx].params = {}
  scheduleEvaluate()
}

function deleteRow(idx: number): void {
  rows.value.splice(idx, 1)
  scheduleEvaluate()
}

// ===== 保存 =====
async function save(): Promise<void> {
  if (!canSave.value) return
  saveError.value = ''
  try {
    await klineBus.request('strategyEdit', 'save', {
      doc: docPayload(),
      pickSyntaxError: pickSyntaxError.value,
    })
    // 静态校验过 → 原生后台引擎终校 + 写库；结果随 changed(saveResult) 推送（成功原生关页）
  } catch (e) {
    saveError.value = String(e instanceof Error ? e.message : e).replace(/^invalid_payload: /, '')
  }
}

function onBack(): void {
  emit('close')
}

// ===== 事件 =====
function handleChanged(payload: Record<string, unknown> | undefined): void {
  const reason = String(payload?.['reason'] ?? '')
  if (reason === 'pickTest') {
    pickSyntaxError.value = String(payload?.['syntaxError'] ?? '')
    testMessage.value = String(payload?.['testMessage'] ?? '')
    testIsError.value = payload?.['testIsError'] === true
    void evaluateNow()
  } else if (reason === 'saveResult') {
    if (payload?.['ok'] === true) {
      emit('close')   // 原生已关页，本地同步清理
    } else {
      saveError.value = String(payload?.['error'] ?? '保存失败')
    }
  } else if (reason === 'dataReady') {
    if (snap.value) snap.value.hasData = true
    if (mode.value === 'inline' && pickBody.value.trim()) runTest()
  }
}

onMounted(async () => {
  klineBus.on('strategyEdit.changed', (ev) => handleChanged(ev.payload))
  await pullSnapshot()
})
</script>

<style scoped>
.nav-line {
  display: flex;
  align-items: center;
  height: 48px;
  padding: 0 8px;
  border-bottom: 0.5px solid var(--k-border);
  flex-shrink: 0;
}

.nav-link {
  border: none;
  background: none;
  color: var(--k-text-tertiary);
  font-size: 13px;
  cursor: pointer;
  padding: 8px 10px;
  min-width: 44px;
  min-height: 44px;
}

.nav-link.save {
  color: #ffffff;
  background: var(--k-accent, #1989fa);
  border-radius: 6px;
  font-weight: 600;
  min-height: 32px;
}

.nav-link.save:disabled {
  background: var(--k-bg-secondary);
  color: var(--k-text-tertiary);
  cursor: default;
}

.nav-center {
  flex: 1;
  text-align: center;
  font-size: 16px;
  font-weight: 700;
  color: var(--k-text);
}

.sep {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  color: var(--k-text);
}

.sep-body {
  flex: 1;
  overflow-y: auto;
  padding: 14px 16px;
}

.sep-field { margin-bottom: 14px; }

.sep-label {
  font-size: 13px;
  font-weight: 500;
  color: var(--k-text);
  margin-bottom: 6px;
}

.sep-label.strong { font-weight: 600; }

.sep-input {
  width: 100%;
  height: 38px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 14px;
  padding: 0 10px;
  outline: none;
  box-sizing: border-box;
}

.sep-formula {
  width: 100%;
  min-height: 140px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 13px;
  line-height: 1.5;
  padding: 8px;
  outline: none;
  resize: vertical;
  box-sizing: border-box;
  text-transform: uppercase;
}

.sep-note {
  font-size: 11px;
  color: var(--k-text-tertiary);
  margin-top: 4px;
}

.seg-bar {
  display: flex;
  gap: 4px;
  background: var(--k-bg-secondary);
  border-radius: 8px;
  padding: 3px;
  margin-bottom: 8px;
}

.seg-bar.tight { margin-bottom: 6px; }

.seg-item {
  flex: 1;
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 13px;
  height: 32px;
  min-height: 44px;
  border-radius: 8px;
  cursor: pointer;
}

.seg-item.on {
  background: var(--k-bg);
  font-weight: 600;
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.1);
}

.seg-item.buy.on { color: #ff4d4f; }
.seg-item.sell.on { color: #00b578; }

.tool-row {
  display: flex;
  gap: 12px;
  margin: 8px 0 4px;
}

.tool-link {
  border: none;
  background: none;
  color: #1989fa;
  font-size: 12px;
  font-weight: 500;
  cursor: pointer;
  padding: 8px 4px;
  min-height: 44px;
}

.sep-test {
  font-size: 12px;
  color: var(--k-text);
  padding: 8px;
  border-radius: 6px;
  background: rgba(0, 180, 100, 0.1);
  white-space: pre-wrap;
  word-break: break-all;
}

.sep-test.err {
  background: rgba(238, 10, 36, 0.1);
  color: #ee0a24;
}

.block-empty {
  font-size: 12px;
  color: var(--k-text-tertiary);
  padding: 12px;
  border-radius: 10px;
  background: var(--k-bg-secondary);
}

.ref-list {
  border-radius: 10px;
  overflow: hidden;
  background: var(--k-bg-secondary);
}

.ref-row {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 10px;
  border: none;
  background: none;
  text-align: left;
  padding: 0 12px;
  min-height: 44px;
  cursor: pointer;
  color: var(--k-text);
}

.ref-row:disabled { cursor: default; }

.ref-row.archived { opacity: 0.6; }

.ref-check {
  font-size: 16px;
  color: #1989fa;
  flex-shrink: 0;
}

.ref-text {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}

.ref-name {
  font-size: 14px;
  font-weight: 500;
  color: var(--k-text);
}

.ref-name.dim { color: var(--k-text-tertiary); }

.ref-body {
  font-size: 11px;
  color: var(--k-text-tertiary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.acc-dot {
  width: 24px;
  height: 24px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #ffffff;
  font-size: 11px;
  font-weight: 600;
  flex-shrink: 0;
}

.archived-tag {
  font-size: 11px;
  color: var(--k-text-tertiary);
  flex-shrink: 0;
}

.trade-card {
  background: var(--k-bg-secondary);
  border-radius: 10px;
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.t-row {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 13px;
  color: var(--k-text);
}

.t-cap { font-size: 13px; }

.t-warn {
  font-size: 11px;
  color: #ff9500;
}

.t-inline {
  display: flex;
  align-items: center;
  gap: 8px;
}

.t-inline.col { flex-direction: column; align-items: stretch; }

.t-input {
  height: 36px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg);
  color: var(--k-text);
  font-size: 14px;
  padding: 0 10px;
  outline: none;
  box-sizing: border-box;
}

.t-input.qty { width: 84px; }
.t-input.amount { width: 140px; }
.t-input.offset { width: 96px; }

.t-date {
  height: 36px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg);
  color: var(--k-text);
  font-size: 14px;
  padding: 0 10px;
  outline: none;
}

.t-unit {
  font-size: 13px;
  color: var(--k-text-tertiary);
}

.chip-row {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.mini-chip {
  border: none;
  background: var(--k-bg);
  color: var(--k-text);
  font-size: 12.5px;
  height: 32px;
  min-height: 44px;
  padding: 0 10px;
  border-radius: 8px;
  cursor: pointer;
}

.mini-chip.on {
  background: #1989fa;
  color: #ffffff;
  font-weight: 600;
}

.warn-line {
  font-size: 11px;
  color: #ff9500;
  margin-bottom: 6px;
}

.rules-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 6px;
}

.parse-errors { margin-bottom: 8px; }

.rule-list {
  display: flex;
  flex-direction: column;
  border-radius: 10px;
  background: var(--k-bg-secondary);
}

.rule-card {
  padding: 10px 12px;
  border-bottom: 0.5px solid var(--k-border);
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.rule-card:last-child { border-bottom: none; }

.rule-head {
  display: flex;
  align-items: center;
  gap: 8px;
}

.rule-kind {
  height: 44px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg);
  color: var(--k-text);
  font-size: 13px;
  font-weight: 500;
  padding: 0 10px;
  outline: none;
}

.rule-mapping {
  flex: 1;
  font-size: 11px;
  color: var(--k-text-tertiary);
}

.rule-del {
  width: 44px;
  height: 44px;
  border: none;
  background: none;
  font-size: 14px;
  cursor: pointer;
}

.param-row {
  display: flex;
  align-items: center;
  gap: 8px;
}

.param-cap {
  width: 68px;
  font-size: 12px;
  color: var(--k-text);
  flex-shrink: 0;
}

.param-select {
  height: 36px;
  min-width: 120px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg);
  color: var(--k-text);
  font-size: 13px;
  padding: 0 8px;
  outline: none;
}

.param-input {
  height: 36px;
  width: 140px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg);
  color: var(--k-text);
  font-size: 13px;
  padding: 0 8px;
  outline: none;
  box-sizing: border-box;
}

.preview-card {
  background: var(--k-bg-secondary);
  border-radius: 10px;
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.pv-trade {
  font-size: 13px;
  color: var(--k-text-secondary);
  line-height: 1.5;
}

.pv-summary {
  font-size: 13px;
  color: var(--k-text);
  line-height: 1.5;
}

.pv-notice {
  font-size: 11px;
  color: var(--k-text-tertiary);
  line-height: 1.5;
}

.issues-block {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin-bottom: 12px;
}

.issue-line {
  font-size: 12px;
  color: #ee0a24;
  line-height: 1.5;
}

.save-big {
  width: 100%;
  height: 50px;
  border: none;
  border-radius: 10px;
  background: var(--k-accent, #1989fa);
  color: #ffffff;
  font-size: 16px;
  font-weight: 600;
  cursor: pointer;
}

.save-big:disabled {
  background: var(--k-bg-secondary);
  color: var(--k-text-tertiary);
  cursor: default;
}

.sep-loading {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  color: var(--k-text-tertiary);
}
</style>

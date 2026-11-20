<template>
  <div class="cep">
    <div class="nav-line">
      <button class="nav-link" aria-label="condEditor.cancel" @click="emit('close')">取消</button>
      <span class="nav-center">{{ editing ? '编辑条件单' : '新建条件单' }}</span>
      <button class="nav-link save" aria-label="condEditor.save" :disabled="!canSave" @click="save">保存</button>
    </div>

    <div class="cep-body" v-if="ctx && draft">
      <!-- 标的头卡 -->
      <div class="head-card">
        <div class="head-left">
          <div class="h-name">{{ ctx.meta.name }}</div>
          <div class="h-code">{{ ctx.meta.code }}</div>
        </div>
        <div class="head-right">
          <div class="h-price">{{ fmtPrice(lastPrice) }}</div>
          <div class="h-note">最新价</div>
        </div>
      </div>

      <!-- 方向大分段（网格 / 仅提醒置灰） -->
      <div class="dir-seg" :class="{ dim: kind === 'grid' || (alertOnly && kind !== 'batch') }">
        <button class="dir-btn buy" :class="{ on: dir === 'buy' }" @click="pickDir('buy')">买入</button>
        <button class="dir-btn sell" :class="{ on: dir === 'sell' }" @click="pickDir('sell')">卖出</button>
      </div>
      <div v-if="kind === 'grid'" class="sep-note px">网格交易按档位自动双向：下跌买入、上涨卖出</div>

      <!-- 类型 chips -->
      <div class="kind-scroll">
        <button
          v-for="k in kinds"
          :key="k.value"
          class="kind-chip"
          :class="{ on: kind === k.value }"
          @click="selectKind(k.value)"
        >{{ k.title }}</button>
      </div>

      <!-- 类型参数卡 -->
      <div class="param-card">
        <!-- 价格条件 -->
        <template v-if="kind === 'price'">
          <div class="p-row"><span class="p-cap">触发方向</span>
            <div class="seg-mini">
              <button class="sm" :class="{ on: num('compareUp') !== false }" @click="setBool('compareUp', true)">现价 ≥</button>
              <button class="sm" :class="{ on: num('compareUp') === false }" @click="setBool('compareUp', false)">现价 ≤</button>
            </div>
          </div>
          <div class="p-row"><span class="p-cap">触发价</span>
            <input class="p-input" :value="numText('triggerPrice')" inputmode="decimal" @input="setNum('triggerPrice', $event)" />
            <span class="p-unit">元</span>
          </div>
        </template>

        <!-- 止盈止损 -->
        <template v-else-if="kind === 'stopLoss'">
          <div class="p-row"><span class="p-cap">基准价</span>
            <input class="p-input" :value="numText('basePrice')" inputmode="decimal" @input="setNum('basePrice', $event)" />
            <span class="p-unit">元</span>
          </div>
          <div class="p-row"><span class="p-cap">涨跌基准</span>
            <select class="p-select" :value="str('baseMode')" @change="setStr('baseMode', ($event.target as HTMLSelectElement).value)">
              <option value="price">按价格</option>
              <option value="percent">按百分比</option>
              <option value="diff">按差价</option>
            </select>
          </div>
          <div class="p-row"><span class="p-cap">止盈</span>
            <input class="p-input" :value="numText('takeProfitPrice')" inputmode="decimal" :disabled="!takeProfitOn" @input="setNum('takeProfitPrice', $event)" />
            <span class="p-unit">元</span>
            <button class="tgl" :class="{ on: takeProfitOn }" @click="takeProfitOn = !takeProfitOn">{{ takeProfitOn ? '开' : '关' }}</button>
          </div>
          <div class="p-row"><span class="p-cap">止损</span>
            <input class="p-input" :value="numText('stopLossPrice')" inputmode="decimal" :disabled="!stopLossOn" @input="setNum('stopLossPrice', $event)" />
            <span class="p-unit">元</span>
            <button class="tgl" :class="{ on: stopLossOn }" @click="stopLossOn = !stopLossOn">{{ stopLossOn ? '开' : '关' }}</button>
          </div>
          <div class="hint-row">两条同时设置时以先触发为准，另一条自动失效</div>
        </template>

        <!-- 回落卖出 -->
        <template v-else-if="kind === 'trailing'">
          <div class="p-row"><span class="p-cap">突破价</span>
            <input class="p-input" :value="numText('breakoutPrice')" inputmode="decimal" @input="setNum('breakoutPrice', $event)" />
            <span class="p-unit">元</span>
          </div>
          <div class="p-row"><span class="p-cap">{{ dir === 'sell' ? '回落幅度' : '反弹幅度' }}</span>
            <input class="p-input" :value="numText('trailPct')" inputmode="decimal" @input="setNum('trailPct', $event)" />
            <span class="p-unit">%</span>
          </div>
          <div class="p-row"><span class="p-cap">保底价触发</span>
            <button class="tgl" :class="{ on: bool('floorEnabled') }" @click="setBool('floorEnabled', !bool('floorEnabled'))">{{ bool('floorEnabled') ? '开' : '关' }}</button>
          </div>
          <div class="p-row"><span class="p-cap">保底价</span>
            <input class="p-input" :value="numText('floorPrice')" inputmode="decimal" :disabled="!bool('floorEnabled')" @input="setNum('floorPrice', $event)" />
            <span class="p-unit">元</span>
          </div>
        </template>

        <!-- 时间条件 -->
        <template v-else-if="kind === 'time'">
          <div class="p-row"><span class="p-cap">触发时间</span>
            <input class="p-date" type="datetime-local" v-model="fireLocal" @change="syncFireDate" />
          </div>
          <div class="hint-row">仅在交易日时段内提交，非交易时段会落为待报</div>
        </template>

        <!-- 涨跌幅 -->
        <template v-else-if="kind === 'changePct'">
          <div class="p-row"><span class="p-cap">触发幅度</span>
            <input class="p-input" :value="numText('changeThreshold')" inputmode="text" @input="setNum('changeThreshold', $event)" />
            <span class="p-unit">%</span>
          </div>
          <div class="p-row"><span class="p-cap">方向</span>
            <div class="seg-mini">
              <button class="sm" :class="{ on: (num('changeThreshold') ?? 0) >= 0 }" @click="setChangeDir(true)">日涨幅 ≥</button>
              <button class="sm" :class="{ on: (num('changeThreshold') ?? 0) < 0 }" @click="setChangeDir(false)">日跌幅 ≤</button>
            </div>
          </div>
        </template>

        <!-- 均线条件 -->
        <template v-else-if="kind === 'maCross'">
          <div class="p-row"><span class="p-cap">均线周期</span>
            <div class="seg-mini">
              <button v-for="p in [5, 10, 20, 60]" :key="p" class="sm" :class="{ on: num('maPeriod') === p }" @click="setNum('maPeriod', { num: p })">MA{{ p }}</button>
            </div>
          </div>
          <div class="p-row"><span class="p-cap">穿越方向</span>
            <div class="seg-mini">
              <button class="sm" :class="{ on: bool('maAbove') }" @click="setBool('maAbove', true)">上穿</button>
              <button class="sm" :class="{ on: !bool('maAbove') }" @click="setBool('maAbove', false)">下破</button>
            </div>
          </div>
        </template>

        <!-- 网格交易 -->
        <template v-else-if="kind === 'grid'">
          <div class="p-row"><span class="p-cap">基准价</span>
            <input class="p-input" :value="numText('gridBase')" inputmode="decimal" @input="setNum('gridBase', $event)" />
            <span class="p-unit">元</span>
          </div>
          <div class="p-row"><span class="p-cap">价格区间</span>
            <input class="p-input sm2" :value="numText('gridLower')" inputmode="decimal" @input="setNum('gridLower', $event)" />
            <span>~</span>
            <input class="p-input sm2" :value="numText('gridUpper')" inputmode="decimal" @input="setNum('gridUpper', $event)" />
            <span class="p-unit">元</span>
          </div>
          <div class="p-row"><span class="p-cap">网格间距</span>
            <input class="p-input" :value="numText('gridStepPct')" inputmode="decimal" @input="setNum('gridStepPct', $event)" />
            <span class="p-unit">%</span>
          </div>
          <div class="p-row"><span class="p-cap">每格数量</span>
            <input class="p-input" :value="numText('gridQtyPerLevel')" inputmode="numeric" :disabled="alertOnly" @input="setNum('gridQtyPerLevel', $event)" />
            <span class="p-unit">股</span>
          </div>
          <div class="p-row"><span class="p-cap">倍数委托</span>
            <div class="seg-mini" :class="{ dim: alertOnly }">
              <button v-for="m in [1, 2, 3, 5]" :key="m" class="sm" :class="{ on: (num('gridMultiplier') ?? 1) === m }" @click="setNum('gridMultiplier', { num: m })">{{ m }}×</button>
            </div>
          </div>
          <div class="hint-row" v-if="gridLevels !== null">区间内约 {{ gridLevels }} 档</div>
        </template>

        <!-- 分批建仓 -->
        <template v-else-if="kind === 'batch'">
          <div class="p-row"><span class="p-cap">总数量</span>
            <input class="p-input" :value="numText('batchTotalQty')" inputmode="numeric" :disabled="alertOnly" @input="setNum('batchTotalQty', $event)" />
            <span class="p-unit">股</span>
          </div>
          <div class="p-row"><span class="p-cap">分批笔数</span>
            <div class="seg-mini">
              <button v-for="n in [2, 3, 4, 5]" :key="n" class="sm" :class="{ on: num('batchCount') === n }" @click="setNum('batchCount', { num: n })">{{ n }} 笔</button>
            </div>
          </div>
          <div class="p-row"><span class="p-cap">首批价格</span>
            <input class="p-input" :value="numText('batchFirstPrice')" inputmode="decimal" @input="setNum('batchFirstPrice', $event)" />
            <span class="p-unit">元</span>
          </div>
          <div class="p-row"><span class="p-cap">每批价差</span>
            <input class="p-input" :value="numText('batchStepPct')" inputmode="decimal" @input="setNum('batchStepPct', $event)" />
            <span class="p-unit">%</span>
          </div>
          <div class="hint-row">{{ batchPreviewText }}</div>
        </template>
      </div>

      <!-- 仅提醒开关 -->
      <div class="switch-card">
        <label class="sw-row">
          <span>仅提醒（不下单）</span>
          <van-switch v-model="alertOnly" size="22px" @change="onAlertOnlyChange" />
        </label>
        <div class="hint-row">{{ alertOnly ? '开启后触发只记录时间 / 触发价 / 文案，不生成委托与成交；数量与持仓校验会跳过' : '关闭时触发后按下方委托指令下单（数量与可卖持仓会被校验）' }}</div>
      </div>

      <!-- 触发后委托指令 -->
      <div class="param-card" :class="{ dim: alertOnly }">
        <div class="p-row"><span class="p-cap">触发后报价</span>
          <div class="seg-mini">
            <button class="sm" :class="{ on: priceType === 'market' }" @click="pickPriceType('market')">市价</button>
            <button class="sm" :class="{ on: priceType === 'limit' }" @click="pickPriceType('limit')">触发价限价</button>
          </div>
        </div>
        <div v-if="showOffsetRow" class="p-row"><span class="p-cap">价格偏移</span>
          <div class="seg-mini">
            <button v-for="o in offsetOptions" :key="o.value" class="sm" :class="{ on: offsetTicks === o.value }" @click="offsetTicks = o.value">{{ o.title }}</button>
          </div>
        </div>
        <div v-if="kind === 'grid'" class="hint-row">{{ alertOnly ? '网格按「每格数量」下单；仅提醒不会下单' : '网格按「每格数量」下单' }}</div>
        <template v-else>
          <div class="p-row"><span class="p-cap">数量</span>
            <input class="p-input" v-model="qtyText" inputmode="numeric" @input="syncQty" />
            <span class="p-unit">股</span>
          </div>
          <div class="p-row"><span class="p-cap">仓位快捷</span>
            <div class="pos-chips">
              <button v-for="r in [0.25, 0.5, 0.75, 1]" :key="r" class="pos-chip" @click="applyPosition(r)">{{ r * 100 }}%</button>
            </div>
          </div>
        </template>
      </div>

      <!-- 有效期 -->
      <div class="param-card">
        <div class="p-row"><span class="p-cap">有效期</span>
          <div class="seg-mini">
            <button v-for="v in validityChips" :key="v.value" class="sm" :class="{ on: validity === v.value }" @click="pickValidity(v.value)">{{ v.title }}</button>
          </div>
        </div>
        <div v-if="validity === 'untilDate'" class="p-row"><span class="p-cap">到期日期</span>
          <input class="p-date" type="date" v-model="expiryLocal" @change="syncExpiry" />
        </div>
      </div>

      <!-- 预览 -->
      <div class="preview-card">
        <div class="pv-cap">预览</div>
        <div class="pv-text">{{ previewSentence || placeholderText }}</div>
      </div>

      <div v-if="errorText" class="err-line">✗ {{ errorText }}</div>

      <button class="submit-btn" :class="{ alert: alertOnly }" :disabled="!canSave" @click="save">
        {{ editing ? '保存修改' : '创建条件单' }}
      </button>
      <div style="height: 14px"></div>
    </div>

    <div v-else class="cep-loading">加载中…</div>
  </div>
</template>

<script setup lang="ts">
// P2-9a：条件单编辑器 Web 版（condEditor）。draft 为 SimCondOrder 原生 JSON 口径
// （iso8601 日期），Web 端改字段原样回传；引擎建单校验/投影文案异步
// （cond.evaluate → changed(evaluate)，占位→就绪两段式）；保存引擎终校 fail-closed。
import { computed, onMounted, ref } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { CondEditorContext, CondEvaluateResult } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const ctx = ref<CondEditorContext | null>(null)
const editing = ref<Record<string, any> | null>(null)
const draft = ref<Record<string, any> | null>(null)
const kind = ref('price')
const dir = ref('sell')
const qtyText = ref('100')
const priceType = ref('market')
const offsetTicks = ref(0)
const alertOnly = ref(false)
const validity = ref('longTerm')
const expiryLocal = ref('')
const fireLocal = ref('')
const takeProfitOn = ref(true)
const stopLossOn = ref(true)
const errorText = ref('')
const evaluateResult = ref<CondEvaluateResult | null>(null)
const placeholderText = '—'

const kinds = [
  { value: 'price', title: '价格条件' },
  { value: 'stopLoss', title: '止盈止损' },
  { value: 'trailing', title: '回落卖出' },
  { value: 'time', title: '时间条件' },
  { value: 'changePct', title: '涨跌幅' },
  { value: 'maCross', title: '均线条件' },
  { value: 'grid', title: '网格交易' },
  { value: 'batch', title: '分批建仓' },
]
const validityChips = [
  { value: 'day', title: '当日' },
  { value: 'untilDate', title: '指定日期' },
  { value: 'longTerm', title: '长期' },
]
const offsetOptions = [
  { value: -2, title: '−2 档' }, { value: -1, title: '−1 档' }, { value: 0, title: '触发价' },
  { value: 1, title: '+1 档' }, { value: 2, title: '+2 档' },
]

const params = computed<Record<string, any>>(() => draft.value?.params ?? {})
const lastPrice = computed(() => ctx.value?.lastPrice ?? null)
const showOffsetRow = computed(() => priceType.value === 'limit' && kind.value !== 'grid')

const canSave = computed(() => {
  if (!evaluateResult.value) return false
  return evaluateResult.value.ready && !evaluateResult.value.rejection
})

const previewSentence = computed(() => evaluateResult.value?.previewSentence ?? '')
const gridLevels = computed(() => {
  const base = num('gridBase'); const low = num('gridLower'); const high = num('gridUpper'); const step = num('gridStepPct')
  if (base === null || low === null || high === null || step === null || step <= 0 || high <= low) return null
  return Math.max(1, Math.round(Math.log(high / low) / Math.log(1 + step / 100)))
})

const batchPreviewText = computed(() => {
  const count = num('batchCount'); const total = num('batchTotalQty')
  const first = num('batchFirstPrice'); const stepPct = num('batchStepPct')
  if (count === null || count < 2 || total === null || total <= 0 || first === null || stepPct === null || stepPct <= 0) {
    return '填齐参数后显示每批数量与末批目标价'
  }
  const lot = Math.max(ctx.value?.rules.lotSize ?? 100, 1)
  const per = Math.floor(total / count / lot) * lot
  const offset = (stepPct / 100) * (count - 1)
  const last = dir.value === 'buy' ? first * (1 - offset) : first * (1 + offset)
  return `每批约 ${per} 股 · 末批目标 ${last.toFixed(2)} 元`
})

// ===== params 读写（JSON 口径：null = 未设置） =====
function num(key: string): number | null {
  const v = params.value[key]
  return typeof v === 'number' ? v : null
}
function bool(key: string): boolean {
  return params.value[key] === true
}
function str(key: string): string {
  return typeof params.value[key] === 'string' ? params.value[key] : ''
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
function setNum(key: string, ev: { num?: number; target?: Event } | number | Event): void {
  if (typeof ev === 'number') { params.value[key] = ev; scheduleEvaluate(); return }
  const text = (ev as { target?: Event }).target
    ? ((ev as unknown as { target: HTMLInputElement }).target.value)
    : (ev as unknown as HTMLInputElement).value
  const cleaned = text.replace(/[^\d.\-]/g, '')
  const v = parseFloat(cleaned)
  params.value[key] = Number.isFinite(v) ? v : null
  scheduleEvaluate()
}
function setBool(key: string, v: boolean): void {
  params.value[key] = v
  scheduleEvaluate()
}
function setStr(key: string, v: string): void {
  params.value[key] = v
  scheduleEvaluate()
}

// ===== 快照拉取与初始化 =====
async function pullContext(): Promise<void> {
  try {
    ctx.value = ((await klineBus.request('cond', 'editorContext')) ?? {}) as CondEditorContext
    const e = ctx.value.editing
    if (e) {
      editing.value = e
      draft.value = JSON.parse(JSON.stringify(e))
      kind.value = String(e.kind ?? 'price')
      dir.value = (e.directive?.direction === 'buy' ? 'buy' : 'sell')
      priceType.value = (e.directive?.priceType === 'limit' ? 'limit' : 'market')
      offsetTicks.value = Number(e.directive?.offsetTicks ?? 0)
      qtyText.value = String(Number(e.directive?.qty ?? 0) || ctx.value.initial.qty)
      alertOnly.value = e.directive?.alertOnly === true
      validity.value = String(e.validity ?? 'longTerm')
      expiryLocal.value = isoToDateText(e.expiresAt)
      fireLocal.value = isoToLocalInput(e.params?.fireDate)
      takeProfitOn.value = e.params?.takeProfitPrice != null
      stopLossOn.value = e.params?.stopLossPrice != null
    } else {
      draft.value = newDraft()
      kind.value = ctx.value.initial.kind
      dir.value = ctx.value.initial.direction
      qtyText.value = String(ctx.value.initial.qty)
      alertOnly.value = false
      validity.value = 'longTerm'
      applyKindDefaults()
    }
    void evaluateNow()
  } catch (err) {
    console.error('cond.editorContext 失败', err)
  }
}

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
    accountID: ctx.value!.account.id,
    metaID: ctx.value!.meta.metaID,
    code: ctx.value!.meta.code,
    name: ctx.value!.meta.name,
    kind: kind.value,
    params: {},
    directive: { direction: dir.value, priceType: 'market', offsetTicks: 0, qty: ctx.value!.initial.qty, alertOnly: null },
    validity: 'longTerm',
    expiresAt: null,
    createdAt: now.toISOString(),
    updatedAt: now.toISOString(),
    status: 'monitoring',
  }
}

/** 类型默认值（对齐原生 applyKindDefaults） */
function applyKindDefaults(): void {
  const p = draft.value!.params
  const price = ctx.value?.initial.price
  switch (kind.value) {
    case 'price':
      p['compareUp'] = true
      if (price != null) p['triggerPrice'] = price
      break
    case 'stopLoss':
      p['baseMode'] = 'price'
      p['basePrice'] = ctx.value?.initial.price ?? null
      break
    case 'trailing':
      p['breakoutPrice'] = price ?? null
      p['floorEnabled'] = false
      break
    case 'time':
      p['fireDate'] = new Date(Date.now() + 3600_000).toISOString()
      fireLocal.value = isoToLocalInput(p['fireDate'])
      break
    case 'maCross':
      p['maPeriod'] = 20
      p['maAbove'] = true
      break
    case 'grid':
      p['gridBase'] = price ?? null
      p['gridMultiplier'] = 1
      p['gridQtyPerLevel'] = ctx.value!.initial.qty > 0 ? ctx.value!.initial.qty : null
      break
    case 'batch':
      p['batchCount'] = 3
      p['batchTotalQty'] = ctx.value!.initial.qty > 0 ? ctx.value!.initial.qty : null
      p['batchFirstPrice'] = price ?? null
      break
  }
}

function selectKind(k: string): void {
  if (k === kind.value) return
  kind.value = k
  draft.value!.params = {}
  draft.value!.kind = k
  takeProfitOn.value = true
  stopLossOn.value = true
  applyKindDefaults()
  scheduleEvaluate()
}

// ===== 草稿 → payload =====
function draftPayload(): Record<string, any> {
  const d = JSON.parse(JSON.stringify(draft.value))
  d.kind = kind.value
  d.params = params.value
  d.directive = {
    direction: dir.value,
    priceType: priceType.value,
    offsetTicks: priceType.value === 'limit' ? offsetTicks.value : 0,
    qty: kind.value === 'grid' ? (num('gridQtyPerLevel') ?? 0) : (parseInt(qtyText.value || '0', 10) || 0),
    alertOnly: alertOnly.value ? true : null,
  }
  d.validity = validity.value
  d.expiresAt = validity.value === 'untilDate' && expiryLocal.value
    ? new Date(expiryLocal.value + 'T00:00:00').toISOString() : null
  d.updatedAt = new Date().toISOString()
  if (kind.value === 'time') d.params['fireDate'] = fireDateISO()
  if (kind.value === 'stopLoss') {
    if (!takeProfitOn.value) d.params['takeProfitPrice'] = null
    if (!stopLossOn.value) d.params['stopLossPrice'] = null
  }
  if (kind.value === 'trailing' && !d.params['floorEnabled']) d.params['floorPrice'] = null
  return d
}

function fireDateISO(): string | null {
  if (!fireLocal.value) return null
  const d = new Date(fireLocal.value)
  return Number.isNaN(d.getTime()) ? null : d.toISOString()
}

// ===== evaluate（防抖） =====
let evaluateTimer: ReturnType<typeof setTimeout> | null = null

function scheduleEvaluate(): void {
  if (evaluateTimer) clearTimeout(evaluateTimer)
  evaluateTimer = setTimeout(() => void evaluateNow(), 300)
}

async function evaluateNow(): Promise<void> {
  if (!draft.value) return
  try {
    const d = ((await klineBus.request('cond', 'evaluate', { draft: draftPayload() })) ?? {}) as Record<string, unknown>
    if (d.queued !== true) return
    // 结果随 cond.changed(evaluate) 推送；这里不直接更新（异步链路单一出口）
  } catch (e) {
    console.error('cond.evaluate 失败', e)
  }
}

function handleChanged(payload: Record<string, unknown> | undefined): void {
  const reason = String(payload?.['reason'] ?? '')
  if (reason === 'evaluate') {
    const draftID = String(payload?.['draftID'] ?? '')
    if (draft.value && draftID !== draft.value.id) return   // 旧请求晚到不覆盖
    evaluateResult.value = payload as unknown as CondEvaluateResult
    errorText.value = ''
  } else if (reason === 'saveResult') {
    if (payload?.['ok'] === true) emit('close')   // 原生已切回管理页
    else errorText.value = String(payload?.['error'] ?? '保存失败')
  }
}

// ===== 交互 =====
function pickDir(d: 'buy' | 'sell'): void {
  if (kind.value === 'grid') return
  if (alertOnly.value && kind.value !== 'batch') return
  dir.value = d
  scheduleEvaluate()
}

function pickPriceType(pt: 'market' | 'limit'): void {
  priceType.value = pt
  if (pt === 'market') offsetTicks.value = 0
  scheduleEvaluate()
}

function pickValidity(v: string): void {
  validity.value = v
  scheduleEvaluate()
}

function onAlertOnlyChange(): void {
  errorText.value = ''
  scheduleEvaluate()
}

function setChangeDir(rise: boolean): void {
  const magnitude = Math.abs(num('changeThreshold') ?? 0)
  params.value['changeThreshold'] = rise ? magnitude : -magnitude
  scheduleEvaluate()
}

function syncQty(): void {
  qtyText.value = qtyText.value.replace(/\D/g, '')
  scheduleEvaluate()
}

/** 仓位快捷：可买/可卖上限 × 比例整手（近似口径；提交由原生引擎复核） */
function applyPosition(ratio: number): void {
  if (!ctx.value) return
  const lot = Math.max(ctx.value.rules.lotSize, 1)
  const price = lastPrice.value ?? 0
  if (dir.value === 'buy' && price > 0) {
    // 近似：现金 / (价 × (1 + 佣金率))
    const perLot = price * lot * 1.0003
    const lots = Math.floor((ctx.value.account.cash * ratio) / Math.max(perLot, 0.01))
    qtyText.value = String(lots * lot)
  } else if (dir.value === 'sell') {
    // 可卖来自编辑上下文的持仓（快照未下发时保持现值）
    const available = (editing.value?.metaID ? 0 : 0) || approximateSellable()
    qtyText.value = String(Math.floor(available * ratio))
  }
  syncQty()
}

/** 可卖近似：编辑态单据无持仓快照下发时按 0（引擎校验兜底） */
function approximateSellable(): number {
  return 0
}

function syncFireDate(): void {
  const d = new Date(fireLocal.value)
  if (!Number.isNaN(d.getTime())) params.value['fireDate'] = d.toISOString()
  scheduleEvaluate()
}

function syncExpiry(): void {
  scheduleEvaluate()
}

// ===== 保存 =====
async function save(): Promise<void> {
  if (!canSave.value) return
  errorText.value = ''
  try {
    await klineBus.request('cond', 'save', { draft: draftPayload() })
    // 结果随 changed(saveResult) 推送（成功原生切回管理页）
  } catch (e) {
    errorText.value = String(e instanceof Error ? e.message : e).replace(/^invalid_payload: /, '')
  }
}

onMounted(async () => {
  klineBus.on('cond.changed', (ev) => handleChanged(ev.payload))
  await pullContext()
})
</script>

<style scoped>
.nav-line {
  display: flex;
  align-items: center;
  height: 44px;
  padding: 0 8px;
  border-bottom: 0.5px solid var(--k-border);
  flex-shrink: 0;
}

.nav-link {
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 15px;
  cursor: pointer;
  padding: 8px 10px;
  min-width: 44px;
  min-height: 44px;
}

.nav-link.save {
  color: var(--k-accent, #1989fa);
  font-weight: 600;
}

.nav-link.save:disabled { color: var(--k-text-tertiary); cursor: default; }

.nav-center {
  flex: 1;
  text-align: center;
  font-size: 15px;
  font-weight: 600;
  color: var(--k-text);
}

.cep {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  color: var(--k-text);
}

.cep-body {
  flex: 1;
  overflow-y: auto;
  padding: 10px 16px 14px;
}

.head-card {
  display: flex;
  align-items: center;
  height: 60px;
  border-bottom: 0.5px solid var(--k-border);
  margin-bottom: 10px;
}

.head-left { flex: 1; }

.h-name { font-size: 14px; font-weight: 700; }

.h-code { font-size: 11px; color: var(--k-text-secondary); }

.head-right { text-align: right; }

.h-price { font-size: 17px; font-weight: 700; font-variant-numeric: tabular-nums; }

.h-note { font-size: 11px; color: var(--k-text-tertiary); }

.dir-seg {
  display: flex;
  gap: 8px;
  margin-bottom: 8px;
}

.dir-seg.dim { opacity: 0.4; pointer-events: none; }

.dir-btn {
  flex: 1;
  height: 44px;
  border: 1px solid var(--k-border);
  border-radius: 8px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 15px;
  font-weight: 600;
  cursor: pointer;
}

.dir-btn.buy.on { background: #ff4d4f; border-color: #ff4d4f; color: #fff; }
.dir-btn.sell.on { background: #00b578; border-color: #00b578; color: #fff; }

.kind-scroll {
  display: flex;
  gap: 8px;
  overflow-x: auto;
  padding: 4px 0 8px;
}

.kind-chip {
  border: 0.5px solid var(--k-border);
  background: var(--k-bg-secondary);
  color: var(--k-text-secondary);
  font-size: 12.5px;
  height: 44px;
  padding: 0 10px;
  border-radius: 6px;
  cursor: pointer;
  flex-shrink: 0;
}

.kind-chip.on {
  color: #1989fa;
  border-color: #1989fa;
  background: rgba(25, 137, 250, 0.08);
  font-weight: 600;
}

.param-card, .switch-card {
  background: var(--k-bg-secondary);
  border-radius: 10px;
  padding: 0 14px;
  margin-bottom: 10px;
}

.param-card.dim { opacity: 0.4; pointer-events: none; }

.p-row {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 46px;
  border-bottom: 0.5px solid var(--k-border);
}

.p-row:last-child { border-bottom: none; }

.p-cap {
  width: 84px;
  font-size: 13px;
  color: var(--k-text);
  flex-shrink: 0;
}

.p-input {
  flex: 1;
  min-width: 0;
  max-width: 96px;
  height: 36px;
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 16px;
  font-weight: 700;
  text-align: right;
  outline: none;
}

.p-input.sm2 { max-width: 72px; }

.p-input:disabled { color: var(--k-text-tertiary); }

.p-select {
  height: 36px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg);
  color: var(--k-text);
  font-size: 13px;
  padding: 0 8px;
  outline: none;
}

.p-date {
  height: 36px;
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 14px;
  outline: none;
}

.p-unit {
  font-size: 11px;
  color: var(--k-text-secondary);
  flex-shrink: 0;
}

.seg-mini {
  display: flex;
  gap: 4px;
  flex: 1;
}

.seg-mini.dim { opacity: 0.4; pointer-events: none; }

.sm {
  flex: 1;
  border: none;
  background: var(--k-bg);
  color: var(--k-text);
  font-size: 12px;
  height: 30px;
  border-radius: 6px;
  cursor: pointer;
}

.sm.on {
  background: var(--k-accent, #1989fa);
  color: #ffffff;
  font-weight: 600;
}

.tgl {
  width: 52px;
  height: 44px;
  border: none;
  background: none;
  color: var(--k-text-tertiary);
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  flex-shrink: 0;
}

.tgl.on { color: #1989fa; }

.hint-row {
  font-size: 11px;
  color: var(--k-text-secondary);
  padding: 7px 0;
  line-height: 1.5;
}

.sw-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 46px;
  font-size: 13px;
}

.pos-chips {
  display: flex;
  gap: 6px;
  flex: 1;
}

.pos-chip {
  flex: 1;
  border: 1px solid var(--k-border);
  border-radius: 6px;
  background: none;
  color: var(--k-text-secondary);
  font-size: 11.5px;
  padding: 6px 0;
  cursor: pointer;
}

.preview-card {
  background: var(--k-bg-secondary);
  border-radius: 10px;
  padding: 14px;
  margin-bottom: 10px;
}

.pv-cap {
  font-size: 11px;
  color: var(--k-text-tertiary);
  margin-bottom: 4px;
}

.pv-text {
  font-size: 12px;
  color: var(--k-text);
  line-height: 1.6;
  word-break: break-all;
}

.err-line {
  font-size: 11px;
  color: #ee0a24;
  padding: 6px 0;
  line-height: 1.5;
}

.submit-btn {
  width: 100%;
  height: 50px;
  border: none;
  border-radius: 10px;
  background: #00b578;
  color: #ffffff;
  font-size: 16px;
  font-weight: 700;
  cursor: pointer;
}

.submit-btn.alert { background: var(--k-accent, #1989fa); }

.submit-btn:disabled {
  background: var(--k-bg-secondary);
  color: var(--k-text-tertiary);
  cursor: default;
}

.cep-loading {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  color: var(--k-text-tertiary);
}

.px { padding: 0 16px 6px; }
</style>

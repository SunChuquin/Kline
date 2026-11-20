<template>
  <div class="prp">
    <!-- 页头：返回 ｜ 跑选股/生成条件单 ｜ 生成入口（清单态）或占位（确认态） -->
    <div class="nav-line">
      <button class="nav-link" aria-label="pickRun.back" @click="onBack">‹ 返回</button>
      <span class="nav-center">{{ stage === 'list' ? '跑选股' : '生成条件单' }}</span>
      <button
        v-if="stage === 'list'"
        class="nav-link save"
        aria-label="pickRun.generate"
        :disabled="selected.size === 0"
        @click="generate"
      >生成条件单</button>
      <span v-else style="width: 60px"></span>
    </div>

    <!-- ============ 清单态：池分段 + 进度 + 命中勾选 ============ -->
    <template v-if="stage === 'list'">
      <div class="prp-toolbar">
        <div class="chip-row">
          <button
            v-for="p in pools"
            :key="p.value"
            class="chip"
            :class="{ on: pool === p.value }"
            :disabled="running"
            @click="pool = p.value"
          >{{ p.label }}</button>
        </div>
        <button
          class="tool-link"
          aria-label="pickRun.toggleAll"
          :disabled="hits.length === 0"
          @click="toggleAll"
        >{{ isAllSelected ? '取消全选' : '全选' }}</button>
      </div>

      <!-- 进度区 -->
      <div class="progress-card">
        <template v-if="phase.state === 'idle'">
          <div class="progress-line">
            <span class="progress-text">点击开始跑选股</span>
            <button class="inline-btn" @click="start">开始跑选股</button>
          </div>
        </template>
        <template v-else-if="phase.state === 'preparing' || phase.state === 'running'">
          <div class="progress-text">
            {{ phase.state === 'preparing' ? `准备行情数据 ${phase.done}/${phase.total}` : `已扫描 ${phase.done}/${phase.total}` }}
          </div>
          <div class="progress-track"><div class="progress-fill" :style="{ width: ratio * 100 + '%' }"></div></div>
          <div class="progress-line" style="justify-content: flex-end">
            <button class="inline-btn" @click="cancelPick">取消</button>
          </div>
        </template>
        <template v-else-if="phase.state === 'finished'">
          <div class="progress-line">
            <span class="progress-text strong">命中 {{ hits.length }} 只</span>
            <button class="inline-btn" @click="start">重新跑选股</button>
          </div>
        </template>
        <template v-else>
          <div class="progress-line">
            <span class="progress-text warn">已取消</span>
            <button class="inline-btn" @click="start">重新跑选股</button>
          </div>
        </template>
      </div>

      <!-- 准备行情超时提示（仅跑完且本次曾超时，对齐原生） -->
      <div v-if="phase.state === 'finished' && prepareTimedOut" class="timeout-note">
        部分标的行情未就绪，本次结果可能遗漏命中（可稍后重跑）
      </div>

      <!-- 清单 / 空态 -->
      <div v-if="hits.length === 0" class="empty">
        <div class="empty-text">{{ emptyText }}</div>
        <div v-if="phase.state === 'finished'" class="empty-hint">命中 = 选股公式最后一条输出线的最新值 &gt; 0</div>
      </div>
      <div v-else class="hit-list">
        <button
          v-for="hit in hits"
          :key="hit.metaID"
          class="hit-row"
          :aria-label="`pickRun.hit.${hit.code}`"
          @click="toggle(hit.metaID)"
        >
          <span class="check" :class="{ on: selected.has(hit.metaID) }">{{ selected.has(hit.metaID) ? '●' : '○' }}</span>
          <span class="hit-name-block">
            <span class="hit-name">{{ hit.name }}</span>
            <span class="hit-code">{{ hit.code }}</span>
          </span>
          <span class="hit-price-block">
            <span class="hit-price">{{ fmtPrice(hit.lastPrice) }}</span>
            <span class="hit-pct" :class="pctClass(hit.changePct)">{{ fmtPct(hit.changePct) }}</span>
          </span>
        </button>
      </div>

      <div class="bottom-note">命中基于本地日线库最后一根，非实时盘中</div>
    </template>

    <!-- ============ 确认态：概览 + 入场单开关 + 草稿分组 + 跳过 ============ -->
    <template v-else-if="genConfirm">
      <div class="prp-body">
        <div v-if="genConfirm.truncatedByLimit" class="warn-line">
          本次已达生成上限（单次 200 条 / 单账户监控 1000 条），超出部分未生成
        </div>

        <div class="card">
          <div class="card-title">概览</div>
          <div class="card-text">将写入 {{ genConfirm.draftCount }} 条条件单 · 跳过 {{ genConfirm.skipCount }} 条</div>
          <div class="card-sub">来自 {{ genConfirm.metaCount }} 只勾选标的</div>
        </div>

        <div v-if="genConfirm.canToggleEntry" class="card">
          <div class="card-title">入场单</div>
          <label class="entry-toggle">
            <input v-model="entryOn" type="checkbox" @change="toggleEntry" />
            <span>同时生成入场单（PRICE ≥ 最新价）</span>
          </label>
          <div class="card-sub">命中清单本身就是今日已命中，入场单会按 TRADE 段的报价方式在盘中触发</div>
        </div>

        <template v-if="genConfirm.groups.length > 0">
          <div v-for="g in genConfirm.groups" :key="g.id" class="card">
            <div class="card-title">{{ g.name }}</div>
            <div v-for="item in g.items" :key="item.draftID" class="draft-row">
              <div class="draft-name">{{ item.name }} {{ item.code }}</div>
              <div class="draft-sentence">{{ item.kindTitle }} · {{ item.sentence }}</div>
            </div>
          </div>
        </template>
        <div v-else class="card">
          <div class="card-title">将生成的条件单</div>
          <div class="card-sub">没有可生成的条件单，请看下方跳过原因</div>
        </div>

        <div v-if="genConfirm.skips.length > 0" class="card">
          <button class="skip-toggle" @click="showSkips = !showSkips">
            跳过 {{ genConfirm.skips.length }} 条
            <span class="chev">{{ showSkips ? '▲' : '▼' }}</span>
          </button>
          <div v-if="showSkips">
            <div v-for="(s, i) in genConfirm.skips" :key="i" class="skip-row">{{ s.title }} —— {{ s.reason }}</div>
          </div>
        </div>

        <div style="height: 70px"></div>
      </div>

      <!-- 底部固定确认条 -->
      <div class="confirm-bar">
        <div v-if="genError" class="card-warn">{{ genError }}</div>
        <button
          class="confirm-btn"
          aria-label="pickRun.confirm"
          :disabled="genConfirm.draftCount === 0 || writing"
          @click="confirm"
        >{{ writing ? '写入中…' : `确认生成（${genConfirm.draftCount} 条）` }}</button>
      </div>
    </template>

    <div v-else class="prp-loading">加载中…</div>
  </div>
</template>

<script setup lang="ts">
// P2-9c-3：跑选股 + 生成确认 Web 页（pickRun）。清单态由 strategyDetail.changed(pickPhase/pickHits)
// 驱动（StrategyPickRunner 转发）；勾选后 generate 组装草稿 → changed(genConfirm) 切确认态
// （草稿文案投影缓存直读，就绪后重推）；confirmGenerate 一次性落盘，成功由原生切回
// strategyDetail（toast 经 snapshot 一次性带出）。口径对齐原生 StrategyPickListView /
// StrategyGenConfirmView。
import { computed, onMounted, ref } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { StrategyGenConfirmPayload, StrategyPickHitSnap, StrategyPickPhaseSnap } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

// 页内两态：清单 → 确认（确认态返回回清单）
const stage = ref<'list' | 'confirm'>('list')

// ===== 清单态 =====
const pools = [
  { value: 'market', label: '全市场' },
  { value: 'favorites', label: '自选' },
] as const
const pool = ref<'market' | 'favorites'>('market')
const phase = ref<StrategyPickPhaseSnap>({ state: 'idle' })
const prepareTimedOut = ref(false)
const hits = ref<StrategyPickHitSnap[]>([])
const selected = ref<Set<number>>(new Set())

const running = computed(() => phase.value.state === 'preparing' || phase.value.state === 'running')
const ratio = computed(() => {
  const p = phase.value
  if (!p.total) return 0
  return Math.min(Math.max((p.done ?? 0) / p.total, 0), 1)
})
const isAllSelected = computed(() => hits.value.length > 0 && selected.value.size === hits.value.length)

const emptyText = computed(() => {
  switch (phase.value.state) {
    case 'idle': return '点击开始跑选股'
    case 'preparing': return '正在准备行情数据…'
    case 'running': return '正在扫描…'
    case 'finished': return '当前没有命中的标的'
    case 'cancelled': return '已取消'
  }
})

// ===== 确认态 =====
const genConfirm = ref<StrategyGenConfirmPayload | null>(null)
const entryOn = ref(false)
const showSkips = ref(false)
const genError = ref('')
const writing = ref(false)

// ===== 行情格式化（与行情页同口径：价格两位 / 涨跌幅带符号） =====
function fmtPrice(v: number | null): string {
  return v == null ? '—' : v.toFixed(2)
}
function fmtPct(v: number | null): string {
  if (v == null) return '—'
  const s = (v * 100).toFixed(2)
  return v > 0 ? `+${s}%` : `${s}%`
}
function pctClass(v: number | null): string {
  if (v == null || v === 0) return 'flat'
  return v > 0 ? 'up' : 'down'
}

function start(): void {
  void klineBus.request('strategyDetail', 'runPick', { pool: pool.value })
    .catch((e) => console.error('strategyDetail.runPick 失败', e))
}

function cancelPick(): void {
  void klineBus.request('strategyDetail', 'cancelPick', {})
    .catch((e) => console.error('strategyDetail.cancelPick 失败', e))
}

function toggle(metaID: number): void {
  const next = new Set(selected.value)
  if (next.has(metaID)) next.delete(metaID)
  else next.add(metaID)
  selected.value = next
}

function toggleAll(): void {
  selected.value = isAllSelected.value ? new Set() : new Set(hits.value.map((h) => h.metaID))
}

/** 勾选标的交给生成（原生 onGenerate 口径） */
function generate(): void {
  if (selected.value.size === 0) return
  genError.value = ''
  void klineBus.request('strategyDetail', 'generate', {
    metaIDs: [...selected.value],
    includeEntry: false,
  }).catch((e) => {
    genError.value = String(e instanceof Error ? e.message : e).slice(0, 60)
  })
}

function toggleEntry(): void {
  void klineBus.request('strategyDetail', 'toggleEntry', { includeEntry: entryOn.value })
    .catch((e) => console.error('strategyDetail.toggleEntry 失败', e))
}

async function confirm(): Promise<void> {
  writing.value = true
  genError.value = ''
  try {
    await klineBus.request('strategyDetail', 'confirmGenerate', {})
    // 成功由原生切回 strategyDetail（本组件随 activeName 切换销毁）；失败收 changed(genResult)
  } catch (e) {
    genError.value = String(e instanceof Error ? e.message : e).slice(0, 60)
    writing.value = false
  }
}

/** 清单态返回 = 关页回 strategyDetail；确认态返回 = 回清单（草稿保留可重新勾选） */
function onBack(): void {
  if (stage.value === 'confirm') {
    stage.value = 'list'
  } else {
    emit('close')
  }
}

function handleChanged(payload: Record<string, unknown> | undefined): void {
  const reason = String(payload?.['reason'] ?? '')
  if (reason === 'pickPhase') {
    phase.value = {
      state: (payload?.['phase'] as StrategyPickPhaseSnap)?.state ?? 'idle',
      done: (payload?.['phase'] as StrategyPickPhaseSnap)?.done,
      total: (payload?.['phase'] as StrategyPickPhaseSnap)?.total,
    }
    prepareTimedOut.value = payload?.['prepareTimedOut'] === true
  } else if (reason === 'pickHits') {
    hits.value = (payload?.['hits'] ?? []) as StrategyPickHitSnap[]
    // 结果变化默认全选（原生 onChange(hits) 同款；用户已手动改过勾选则此处重置）
    selected.value = new Set(hits.value.map((h) => h.metaID))
  } else if (reason === 'genConfirm') {
    genConfirm.value = payload as unknown as StrategyGenConfirmPayload
    entryOn.value = genConfirm.value.includeEntry
    stage.value = 'confirm'
    writing.value = false
  } else if (reason === 'genResult') {
    writing.value = false
    genError.value = '写入失败，请稍后重试'
  }
}

onMounted(async () => {
  klineBus.on('strategyDetail.changed', (ev) => handleChanged(ev.payload))
  // 清单态初值：读执行器当前状态（进入前可能已有上一轮结果——start 会先清空）
  try {
    await klineBus.request('page', 'ready', {})
  } catch { /* 事件拉取失败不阻断 */ }
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
  color: var(--k-text);
  font-size: 15px;
  font-weight: 500;
  cursor: pointer;
  padding: 8px 10px;
}

.nav-link.save {
  color: #1989fa;
  font-weight: 600;
}

.nav-link.save:disabled {
  color: var(--k-text-tertiary);
  cursor: default;
}

.nav-center {
  flex: 1;
  text-align: center;
  font-size: 16px;
  font-weight: 600;
  color: var(--k-text);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.prp {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  color: var(--k-text);
}

.prp-body {
  flex: 1;
  overflow-y: auto;
  padding: 14px 16px;
}

.prp-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 10px 16px 6px;
}

.chip-row {
  display: flex;
  gap: 8px;
}

.chip {
  border: none;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 12px;
  height: 30px;
  padding: 0 12px;
  border-radius: 8px;
  cursor: pointer;
}

.chip.on {
  background: #1989fa;
  color: #ffffff;
  font-weight: 600;
}

.chip:disabled {
  opacity: 0.5;
  cursor: default;
}

.tool-link {
  border: none;
  background: none;
  color: #1989fa;
  font-size: 12.5px;
  font-weight: 500;
  cursor: pointer;
  padding: 8px;
}

.tool-link:disabled {
  color: var(--k-text-tertiary);
  cursor: default;
}

.progress-card {
  margin: 0 16px 8px;
  padding: 12px;
  border-radius: 10px;
  background: var(--k-bg-secondary);
}

.progress-line {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.progress-text {
  font-size: 12px;
  color: var(--k-text-tertiary);
}

.progress-text.strong {
  font-size: 12.5px;
  font-weight: 600;
  color: var(--k-text);
}

.progress-text.warn {
  font-size: 12.5px;
  font-weight: 500;
  color: #ff9500;
}

.progress-track {
  height: 3px;
  border-radius: 2px;
  background: rgba(128, 128, 128, 0.2);
  margin-top: 8px;
  overflow: hidden;
}

.progress-fill {
  height: 100%;
  background: #1989fa;
  transition: width 0.2s ease;
}

.inline-btn {
  border: none;
  background: none;
  color: #1989fa;
  font-size: 12.5px;
  font-weight: 600;
  cursor: pointer;
  padding: 8px 12px;
}

.timeout-note {
  margin: 0 16px 8px;
  font-size: 11px;
  color: #ff9500;
}

.empty {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 10px;
}

.empty-text {
  font-size: 13px;
  color: var(--k-text-tertiary);
}

.empty-hint {
  font-size: 11px;
  color: var(--k-text-tertiary);
  opacity: 0.7;
}

.hit-list {
  flex: 1;
  overflow-y: auto;
  padding-bottom: 8px;
}

.hit-row {
  display: flex;
  align-items: center;
  width: 100%;
  gap: 10px;
  padding: 0 16px;
  height: 48px;
  border: none;
  background: none;
  cursor: pointer;
  text-align: left;
}

.check {
  font-size: 16px;
  color: var(--k-text-tertiary);
  flex-shrink: 0;
}

.check.on {
  color: #1989fa;
}

.hit-name-block {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 2px;
  overflow: hidden;
}

.hit-name {
  font-size: 14px;
  font-weight: 500;
  color: var(--k-text);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.hit-code {
  font-size: 11px;
  color: var(--k-text-tertiary);
}

.hit-price-block {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 2px;
  flex-shrink: 0;
}

.hit-price {
  font-size: 13px;
  font-weight: 500;
  color: var(--k-text);
}

.hit-pct {
  font-size: 11px;
  color: var(--k-text-tertiary);
}

.hit-pct.up { color: #ee0a24; }
.hit-pct.down { color: #07c160; }
.hit-pct.flat { color: var(--k-text-tertiary); }

.bottom-note {
  padding: 0 16px;
  height: 36px;
  display: flex;
  align-items: center;
  font-size: 11px;
  color: var(--k-text-tertiary);
  border-top: 0.5px solid var(--k-border);
  flex-shrink: 0;
}

.card {
  background: var(--k-bg-secondary);
  border-radius: 10px;
  padding: 12px;
  margin-bottom: 14px;
}

.card-title {
  font-size: 13px;
  font-weight: 600;
  margin-bottom: 8px;
}

.card-text {
  font-size: 14px;
  font-weight: 500;
  color: var(--k-text);
}

.card-sub {
  font-size: 11px;
  color: var(--k-text-tertiary);
  margin-top: 4px;
}

.card-warn {
  font-size: 12px;
  color: #ee0a24;
  padding: 4px 0 8px;
}

.warn-line {
  font-size: 12px;
  color: #ff9500;
  margin-bottom: 10px;
}

.entry-toggle {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
  color: var(--k-text);
  min-height: 32px;
}

.draft-row {
  padding: 4px 0;
}

.draft-name {
  font-size: 13px;
  font-weight: 500;
  color: var(--k-text);
}

.draft-sentence {
  font-size: 12px;
  color: var(--k-text-tertiary);
  margin-top: 2px;
}

.skip-toggle {
  display: flex;
  align-items: center;
  gap: 4px;
  border: none;
  background: none;
  color: #ff9500;
  font-size: 12.5px;
  font-weight: 500;
  cursor: pointer;
  padding: 4px 0;
}

.chev {
  font-size: 10px;
}

.skip-row {
  font-size: 12px;
  color: #ff9500;
  padding: 4px 0;
}

.confirm-bar {
  position: fixed;
  bottom: 0;
  left: 0;
  right: 0;
  padding: 10px 16px;
  background: var(--k-bg);
  border-top: 0.5px solid var(--k-border);
}

.confirm-btn {
  width: 100%;
  border: none;
  border-radius: 10px;
  height: 44px;
  font-size: 15px;
  font-weight: 600;
  cursor: pointer;
  background: #1989fa;
  color: #ffffff;
}

.confirm-btn:disabled {
  background: var(--k-bg-secondary);
  color: var(--k-text-tertiary);
  cursor: default;
}

.prp-loading {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  color: var(--k-text-tertiary);
}
</style>

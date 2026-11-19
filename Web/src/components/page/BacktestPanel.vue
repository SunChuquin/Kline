<template>
  <div class="bp">
    <!-- 顶部栏（对齐原生：返回胶囊 + 居中标题 + 右侧动作） -->
    <div class="nav-bar">
      <button class="nav-pill" @click="back">‹ 返回</button>
      <span class="nav-title">{{ subPage === 'result' ? '回测结果' : '历史回测' }}</span>
      <button v-if="subPage === 'params'" class="nav-run" :disabled="running" @click="run">开始回测</button>
      <span v-else class="nav-spacer"></span>
    </div>

    <div class="bp-body">
      <!-- ① 参数页（对齐原生 BacktestParamView） -->
      <template v-if="subPage === 'params'">
        <div v-if="snap?.doc?.tradeEmpty" class="warn-line">建议先在编辑里配置交易指令（方向 / 数量）</div>

        <div class="card-title">回测参数</div>
        <div class="card">
          <div class="p-row">
            <span class="p-label">回测区间</span>
            <div class="seg">
              <button
                v-for="d in dayOptions"
                :key="d"
                class="seg-item"
                :class="{ on: days === d }"
                @click="days = d"
              >{{ d }}</button>
            </div>
          </div>
          <div class="p-divider"></div>
          <div class="p-row">
            <span class="p-label">初始资金</span>
            <div class="capital-box">
              <input v-model="capitalText" class="capital-input" inputmode="decimal" placeholder="100000" />
              <span class="p-unit">元</span>
            </div>
          </div>
          <div class="p-chips">
            <button v-for="c in capitalChips" :key="c.value" class="p-chip" @click="capitalText = String(c.value)">
              {{ c.title }}
            </button>
          </div>
          <div class="p-divider"></div>
          <div class="p-row">
            <span class="p-label">候选池</span>
            <div class="seg">
              <button
                v-for="p in poolOptions"
                :key="p.value"
                class="seg-item"
                :class="{ on: pool === p.value }"
                @click="pool = p.value"
              >{{ p.title }}</button>
            </div>
          </div>
          <div class="p-divider"></div>
          <div class="toggle-block">
            <div class="toggle-line">
              <span class="toggle-title">信号次日开盘成交</span>
              <van-switch :model-value="executeNextOpen" size="22px" @update:model-value="(v: boolean) => executeNextOpen = v" />
            </div>
            <div class="toggle-note">关闭则按信号当日收盘价成交；开启更贴近实盘，避免用当日收盘决定当日成交的前视偏差</div>
          </div>
          <div class="p-divider"></div>
          <div class="toggle-block">
            <div class="toggle-line">
              <span class="toggle-title">把选股命中当作买入信号</span>
              <van-switch :model-value="includeEntry" size="22px" @update:model-value="(v: boolean) => includeEntry = v" />
            </div>
            <div class="toggle-note">关闭则只回测已有持仓上的规则（本策略无持仓来源时结果会为空）</div>
          </div>
        </div>
        <div class="foot-note">
          回测基于本地日线库；不还原盘中路径，回落卖出按 bar 内先高后低假设；条件单实盘只吃行情快照，触发必然晚于回测
        </div>
      </template>

      <!-- ② 进度页（对齐原生 backtestProgressPage：准备 / 逐日 / 失败） -->
      <template v-else-if="subPage === 'progress'">
        <div class="card progress-card">
          <template v-if="snap?.phase === 'preparing'">
            <div class="progress-title">准备行情数据 {{ snap?.progress?.done ?? 0 }}/{{ snap?.progress?.total ?? 0 }}</div>
            <van-progress :percentage="preparePct" stroke-width="4" :show-pivot="false" />
            <div class="action-line">
              <button class="inline-action" @click="cancelAndClose">取消</button>
            </div>
          </template>
          <template v-else-if="snap?.phase === 'simulating'">
            <div class="progress-title">正在逐日回测…</div>
            <van-progress :percentage="0" stroke-width="4" :show-pivot="false" />
            <div class="action-line">
              <button class="inline-action" @click="cancelAndClose">取消</button>
            </div>
          </template>
          <template v-else-if="snap?.phase === 'failed'">
            <div class="fail-line">{{ snap?.failMessage ?? '回测失败' }}</div>
            <div class="action-line">
              <button class="inline-action" @click="closePage">返回</button>
            </div>
          </template>
          <template v-else>
            <div class="progress-title">…</div>
          </template>
        </div>
      </template>

      <!-- ③ 结果页（对齐原生 BacktestResultView：指标 / 净值 / 明细 / 提示） -->
      <template v-else-if="subPage === 'result' && result">
        <div class="card-title">指标</div>
        <div class="card stats-card">
          <div class="stats-firstline">
            初始资金 {{ fmtAmount0(result.stats.initialCapital) }} → 期末净值 {{ fmtAmount0(result.stats.finalEquity) }}
            · 平仓 {{ result.stats.roundTrips }} 笔
          </div>
          <div class="stats-grid">
            <div class="metric-cell">
              <div class="metric-title">总收益</div>
              <div class="metric-value" :class="changeClass(result.stats.totalReturn)">{{ fmtPct(result.stats.totalReturn) }}</div>
            </div>
            <div class="metric-cell">
              <div class="metric-title">年化</div>
              <div class="metric-value" :class="changeClass(result.stats.annualized)">{{ fmtPct(result.stats.annualized) }}</div>
            </div>
            <div class="metric-cell">
              <div class="metric-title">最大回撤</div>
              <div class="metric-value tone-green">{{ fmtPct(-Math.abs(result.stats.maxDrawdown)) }}</div>
            </div>
            <div class="metric-cell">
              <div class="metric-title">胜率</div>
              <div class="metric-value">{{ fmtPct(result.stats.winRate) }}</div>
            </div>
            <div class="metric-cell">
              <div class="metric-title">盈亏比</div>
              <div class="metric-value">{{ result.stats.profitFactor.toFixed(2) }}</div>
            </div>
            <div class="metric-cell">
              <div class="metric-title">成交 / 平均持仓</div>
              <div class="metric-value">{{ result.stats.tradeCount }} 笔 · {{ result.stats.avgHoldDays.toFixed(1) }} 天</div>
            </div>
          </div>
        </div>

        <div class="card-title">净值曲线</div>
        <div class="card chart-card">
          <div class="chart-range">区间 {{ fmtDate(firstDate) }} ~ {{ fmtDate(lastDate) }}</div>
          <!-- SVG 手绘净值曲线：等距 x + 归一化 y（含基线），对齐原生 NetValueChartView -->
          <svg
            v-if="result.equity.length > 0"
            ref="chartRef"
            class="net-chart"
            :viewBox="`0 0 ${chartW} ${chartH}`"
            preserveAspectRatio="none"
          >
            <rect
              v-if="ddRect"
              :x="ddRect.x" :y="0" :width="ddRect.w" :height="chartH"
              fill="rgba(255,59,48,0.12)"
            />
            <polygon :points="fillPoints" fill="url(#bpFill)" />
            <polyline :points="linePoints" fill="none" stroke="var(--k-accent)" stroke-width="1.5" vector-effect="non-scaling-stroke" />
            <line
              :x1="0" :y1="py(base)" :x2="chartW" :y2="py(base)"
              stroke="rgba(128,128,128,0.55)" stroke-width="1"
              stroke-dasharray="3 3" vector-effect="non-scaling-stroke"
            />
            <defs>
              <linearGradient id="bpFill" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0" stop-color="var(--k-accent)" stop-opacity="0.18" />
                <stop offset="1" stop-color="var(--k-accent)" stop-opacity="0" />
              </linearGradient>
            </defs>
          </svg>
          <div v-else class="chart-empty">暂无净值数据</div>
          <div class="axis-label axis-max">最高 {{ fmtAmount0(maxEquity) }}</div>
          <div class="axis-label axis-min">最低 {{ fmtAmount0(minEquity) }}</div>
        </div>

        <template v-if="result.trades.length === 0">
          <div class="empty-card">
            <div class="empty-main">本次区间内没有产生任何成交</div>
            <div class="empty-sub">请检查候选池 / 回测区间 / 入场信号开关</div>
          </div>
        </template>
        <template v-else>
          <div class="card-title">交易明细</div>
          <div class="card trades-card">
            <div class="trades-scroll">
              <div class="t-row t-head">
                <span class="tc" :style="tc(colDate)">日期</span>
                <span class="tc" :style="tc(colName)">标的</span>
                <span class="tc tc-c" :style="tc(colDir)">方向</span>
                <span class="tc tc-c" :style="tc(colRule)">规则</span>
                <span class="tc tc-r" :style="tc(colQty)">数量</span>
                <span class="tc tc-r" :style="tc(colPrice)">成交价</span>
                <span class="tc tc-r" :style="tc(colAmount)">金额</span>
                <span class="tc tc-r" :style="tc(colPnL)">盈亏</span>
              </div>
              <div class="t-divider"></div>
              <template v-for="trade in visibleTrades" :key="`${trade.date}-${trade.code}-${trade.direction}`">
                <div class="t-row">
                  <span class="tc t-date" :style="tc(colDate)">{{ fmtDate(trade.date) }}</span>
                  <span class="tc" :style="tc(colName)">{{ trade.name }} {{ trade.code }}</span>
                  <span class="tc tc-c" :class="trade.direction === 'buy' ? 'tone-red' : 'tone-green'" :style="tc(colDir)">
                    {{ trade.direction === 'buy' ? '买入' : '卖出' }}
                  </span>
                  <span class="tc tc-c t-sec" :style="tc(colRule)">{{ trade.rule ?? '—' }}</span>
                  <span class="tc tc-r" :style="tc(colQty)">{{ fmtShares(trade.qty) }}</span>
                  <span class="tc tc-r" :style="tc(colPrice)">{{ fmtPrice(trade.price) }}</span>
                  <span class="tc tc-r" :style="tc(colAmount)">{{ fmtAmount(trade.amount) }}</span>
                  <span v-if="trade.realizedPnL !== null" class="tc tc-r" :class="changeClass(trade.realizedPnL)" :style="tc(colPnL)">
                    {{ fmtSigned(trade.realizedPnL) }}
                  </span>
                  <span v-else class="tc tc-r t-sec" :style="tc(colPnL)">{{ trade.direction === 'buy' ? '持仓中' : '—' }}</span>
                </div>
                <div class="t-divider"></div>
              </template>
            </div>
            <button
              v-if="result.trades.length > tradeLimit && !showAllTrades"
              class="expand-btn"
              @click="showAllTrades = true"
            >展开全部（共 {{ result.trades.length }} 条）</button>
          </div>
        </template>

        <div class="card-title">提示</div>
        <div class="card notice-card">
          <div class="scan-line">扫描 {{ result.scannedCount }} 只 · 命中 {{ result.hitCount }} 只</div>
          <div v-for="(w, i) in result.warnings" :key="`w${i}`" class="warn-line">{{ w }}</div>
          <template v-if="result.skipped.length > 0">
            <button class="skip-toggle" @click="showSkips = !showSkips">
              跳过 {{ result.skipped.length }} 条 {{ showSkips ? '▴' : '▾' }}
            </button>
            <div v-if="showSkips" class="skip-box">
              <div v-for="(s, i) in result.skipped" :key="`s${i}`" class="skip-line">{{ s }}</div>
            </div>
          </template>
        </div>
        <div style="height: 16px"></div>
      </template>
    </div>
  </div>
</template>

<script setup lang="ts">
// 回测 Web 面板（P2-6c-2，对齐原生 BacktestParamView / backtestProgressPage / BacktestResultView）：
// 参数表单为 Web 本地态（run 时一次写回 backtest.run）；phase/result 由原生
// StrategyBacktestRunner 发布，backtest.changed 推送回读；净值曲线为 SVG 手绘
// （等距 x + 归一化 y + 回撤高亮 + 基线虚线，等价原生 GeometryReader+Path）。
import { computed, nextTick, onMounted, ref, watch } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { BacktestResultSnap, BacktestSnapshot } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const snap = ref<BacktestSnapshot | null>(null)
const subPage = ref<'params' | 'progress' | 'result'>('params')

// 参数表单（本地态；区间/资金/池/成交口径/入场信号，默认值对齐原生）
const dayOptions = [60, 120, 250, 500]
const capitalChips = [
  { title: '10 万', value: 100000 },
  { title: '50 万', value: 500000 },
  { title: '100 万', value: 1000000 },
]
const poolOptions = [
  { value: 'market', title: '全市场' },
  { value: 'favorites', title: '自选' },
]
const days = ref(250)
const capitalText = ref('100000')
const pool = ref('market')
const executeNextOpen = ref(true)
const includeEntry = ref(true)

// 结果页展示态
const showAllTrades = ref(false)
const showSkips = ref(false)
const tradeLimit = 50

// SVG 净值图
const chartRef = ref<SVGElement | null>(null)
const chartW = ref(600)
const chartH = 160

const running = computed(() => snap.value?.phase === 'preparing' || snap.value?.phase === 'simulating')
const result = computed(() => snap.value?.result ?? null)
const preparePct = computed(() => {
  const p = snap.value?.progress
  if (!p || p.total <= 0) return 0
  return Math.min(100, Math.round((p.done / p.total) * 100))
})

const firstDate = computed(() => result.value?.equity[0]?.date ?? 0)
const lastDate = computed(() => result.value?.equity.at(-1)?.date ?? 0)
const maxEquity = computed(() => Math.max(...(result.value?.equity.map((p) => p.equity) ?? [0])))
const minEquity = computed(() => Math.min(...(result.value?.equity.map((p) => p.equity) ?? [0])))
const base = computed(() => result.value?.stats.initialCapital ?? 0)
const visibleTrades = computed(() => {
  const trades = result.value?.trades ?? []
  return showAllTrades.value ? trades : trades.slice(0, tradeLimit)
})

async function pull(): Promise<void> {
  try {
    snap.value = (await klineBus.request('backtest', 'snapshot')) as unknown as BacktestSnapshot
    // 打开时按策略绑定账户初始化默认资金（对齐原生 init）
    const cap = snap.value?.doc?.defaultCapital
    if (cap && capitalText.value === '100000') capitalText.value = plainNumber(cap)
  } catch (e) {
    console.error('backtest.snapshot 失败', e)
  }
}

function act(action: string, payload?: Record<string, unknown>): Promise<Record<string, unknown> | undefined> {
  return klineBus.request('backtest', action, payload)
}

function run(): void {
  const capital = Number.parseFloat(capitalText.value.trim())
  void act('run', {
    days: days.value,
    initialCapital: Number.isFinite(capital) && capital > 0 ? capital : 100000,
    pool: pool.value,
    executeNextOpen: executeNextOpen.value,
    includeEntry: includeEntry.value,
  })
    .then(() => { subPage.value = 'progress' })
    .catch((e) => console.error('backtest.run 失败', e))
}

function cancelAndClose(): void {
  // 对齐原生 closeBacktestRun：运行中先取消，再回详情页
  void act('cancel').catch(() => {})
  emit('close')
}

function back(): void {
  // 原生：参数页/进度页/结果页的返回都是回策略详情页（进度页返回会先取消）
  if (subPage.value === 'progress') {
    cancelAndClose()
    return
  }
  emit('close')
}

onMounted(async () => {
  await klineBus.detect()
  klineBus.on('backtest.changed', () => void pull())
  await pull()
  // 取消后自动回策略详情（对齐原生 handleBacktestPhase .cancelled）——
  // 仅从运行态转入 cancelled 才关页（初始挂载即 cancelled 是上一轮残留，不触发）
  let prevPhase = snap.value?.phase
  watch(() => snap.value?.phase, (phase) => {
    const prev = prevPhase
    prevPhase = phase
    if (phase === 'finished' && snap.value?.result) {
      subPage.value = 'result'
      // 净值图按容器实测宽度绘制（一次即可；全屏 WebView 宽度稳定）
      void nextTick(() => {
        const w = chartRef.value?.getBoundingClientRect().width
        if (w && w > 40) chartW.value = Math.round(w)
      })
    }
    if (phase === 'cancelled' && (prev === 'preparing' || prev === 'simulating')) {
      emit('close')
    }
  })
  // 已有 finished 结果时（例如返回后重进）直接进结果页
  if (snap.value?.phase === 'finished' && snap.value?.result) {
    subPage.value = 'result'
  }
})

// ===== SVG 几何（等价原生 NetValueChartView 的 px/py 归一化） =====

const values = computed(() => result.value?.equity.map((p) => p.equity) ?? [])
const minV = computed(() => {
  const vs = values.value
  if (!vs.length) return 0
  return Math.min(Math.min(...vs), base.value)
})
const maxV = computed(() => {
  const vs = values.value
  if (!vs.length) return 0
  return Math.max(Math.max(...vs), base.value)
})
const span = computed(() => maxV.value - minV.value)
const n = computed(() => values.value.length)

function px(i: number): number {
  return n.value <= 1 ? 0 : (i / (n.value - 1)) * chartW.value
}
function py(v: number): number {
  return span.value <= 0 ? chartH / 2 : chartH - ((v - minV.value) / span.value) * chartH
}

const linePoints = computed(() =>
  values.value.map((v, i) => `${px(i).toFixed(2)},${py(v).toFixed(2)}`).join(' '))

const fillPoints = computed(() => {
  if (!n.value) return ''
  const top = values.value.map((v, i) => `${px(i).toFixed(2)},${py(v).toFixed(2)}`).join(' ')
  return `${top} ${px(n.value - 1).toFixed(2)},${chartH} ${px(0).toFixed(2)},${chartH}`
})

const ddRect = computed(() => {
  const range = result.value?.maxDrawdownRange
  if (!range || !n.value) return null
  const i0 = Math.min(Math.max(range[0], 0), n.value - 1)
  const i1 = Math.min(Math.max(range[1], 0), n.value - 1)
  if (i1 < i0) return null
  const x0 = px(i0)
  return { x: x0, w: Math.max(px(i1) - x0, 2) }
})

// ===== 格式化（对齐 SimFormat：红涨绿跌、千分位、带符号） =====

function plainNumber(v: number): string {
  return v === Math.round(v) ? String(Math.round(v)) : String(v)
}

function fmtAmount0(v: number): string {
  return Math.round(v).toLocaleString('en-US')
}

function fmtAmount(v: number): string {
  return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function fmtSigned(v: number): string {
  return (v < 0 ? '-' : '+') + fmtAmount(Math.abs(v))
}

function fmtPct(ratio: number): string {
  const v = ratio * 100
  return (v < 0 ? '-' : '+') + Math.abs(v).toFixed(2) + '%'
}

function fmtShares(v: number): string {
  return v.toLocaleString('en-US')
}

function fmtPrice(v: number): string {
  return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function fmtDate(v: number): string {
  if (v <= 0) return '—'
  const text = String(v)
  if (text.length !== 8) return text
  return `${text.slice(0, 4)}-${text.slice(4, 6)}-${text.slice(6, 8)}`
}

/** A 股语义：盈利红 / 亏损绿 */
function changeClass(v: number): string {
  if (v < 0) return 'tone-green'
  if (v > 0) return 'tone-red'
  return ''
}

// 明细列宽（对齐原生 colDate 等）
const colDate = 84, colName = 116, colDir = 40, colRule = 68,
      colQty = 54, colPrice = 62, colAmount = 84, colPnL = 78
function tc(width: number): Record<string, string> {
  return { width: `${width}px`, flex: 'none' }
}
</script>

<style scoped>
.bp {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
}

.nav-bar {
  display: flex;
  align-items: center;
  height: 52px;
  flex-shrink: 0;
  background: var(--k-bg);
  padding: 0 16px;
}

.nav-pill {
  border: none;
  background: rgba(128, 128, 128, 0.12);
  border-radius: 8px;
  color: var(--k-text);
  font-size: 15px;
  font-weight: 500;
  padding: 6px 10px;
  min-height: 44px;
  cursor: pointer;
}

.nav-title {
  flex: 1;
  text-align: center;
  font-size: 17px;
  font-weight: 600;
  color: var(--k-text);
}

.nav-run {
  border: none;
  background: none;
  color: var(--k-accent);
  font-size: 13px;
  font-weight: 600;
  min-height: 44px;
  padding: 0 10px;
  cursor: pointer;
}

.nav-run:disabled { color: var(--k-text-tertiary); cursor: default; }

.nav-spacer { width: 66px; }

.bp-body {
  flex: 1;
  overflow-y: auto;
  padding: 14px 16px;
  border-top: 0.5px solid var(--k-divider, #c6c6c8);
}

.card-title {
  font-size: 13px;
  font-weight: 600;
  color: var(--k-text);
  padding: 8px 2px;
}

.card {
  background: var(--k-bg-secondary);
  border-radius: 12px;
  padding: 12px;
  margin-bottom: 12px;
}

.divider, .p-divider, .t-divider {
  height: 0.5px;
  background: var(--k-divider, #c6c6c8);
}

.warn-line {
  font-size: 12px;
  color: #ff9500;
  padding: 2px 0 8px;
}

/* 参数表单 */
.p-row {
  display: flex;
  align-items: center;
  min-height: 44px;
  gap: 8px;
}

.p-label {
  font-size: 13px;
  color: var(--k-text-secondary);
  flex-shrink: 0;
}

.seg {
  display: flex;
  margin-left: auto;
  background: var(--k-bg);
  border-radius: 8px;
  padding: 2px;
}

.seg-item {
  border: none;
  background: none;
  color: var(--k-text-secondary);
  font-size: 13px;
  min-height: 32px;
  padding: 0 14px;
  border-radius: 6px;
  cursor: pointer;
}

.seg-item.on {
  background: var(--k-accent);
  color: #ffffff;
  font-weight: 600;
}

.capital-box {
  margin-left: auto;
  display: flex;
  align-items: baseline;
  gap: 4px;
}

.capital-input {
  width: 120px;
  border: none;
  background: var(--k-bg);
  border-radius: 8px;
  color: var(--k-text);
  font-size: 15px;
  font-weight: 500;
  text-align: right;
  padding: 6px 10px;
  outline: none;
}

.p-unit {
  font-size: 13px;
  color: var(--k-text-secondary);
}

.p-chips {
  display: flex;
  justify-content: flex-end;
  gap: 6px;
  min-height: 44px;
  align-items: center;
}

.p-chip {
  border: none;
  background: var(--k-bg);
  color: var(--k-accent);
  font-size: 11.5px;
  font-weight: 500;
  height: 32px;
  padding: 0 10px;
  border-radius: 6px;
  cursor: pointer;
}

.toggle-block {
  padding: 4px 0;
}

.toggle-line {
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 44px;
}

.toggle-title {
  font-size: 13px;
  color: var(--k-text);
}

.toggle-note {
  font-size: 11px;
  color: var(--k-text-secondary);
  line-height: 1.5;
}

.foot-note {
  font-size: 11px;
  color: var(--k-text-secondary);
  line-height: 1.5;
  padding: 10px 0;
}

/* 进度页 */
.progress-card { margin-top: 8px; }

.progress-title {
  font-size: 12.5px;
  font-weight: 500;
  color: var(--k-text-secondary);
  margin-bottom: 10px;
}

.action-line {
  display: flex;
  justify-content: flex-end;
  margin-top: 10px;
}

.inline-action {
  border: 1px solid var(--k-accent);
  border-radius: 6px;
  background: none;
  color: var(--k-accent);
  font-size: 12.5px;
  font-weight: 600;
  height: 32px;
  padding: 0 12px;
  min-width: 44px;
  cursor: pointer;
}

.fail-line {
  font-size: 12.5px;
  color: #ff9500;
  line-height: 1.5;
}

/* 指标卡 */
.stats-firstline {
  font-size: 12px;
  color: var(--k-text-secondary);
  margin-bottom: 10px;
  line-height: 1.5;
}

.stats-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 10px;
}

.metric-cell {
  background: var(--k-bg);
  border-radius: 8px;
  padding: 10px;
}

.metric-title {
  font-size: 11px;
  color: var(--k-text-secondary);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.metric-value {
  font-size: 16px;
  font-weight: 700;
  color: var(--k-text);
  margin-top: 4px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* 净值曲线 */
.chart-card { position: relative; }

.chart-range {
  font-size: 11px;
  color: var(--k-text-secondary);
  text-align: right;
}

.net-chart {
  width: 100%;
  height: 160px;
  margin-top: 4px;
  display: block;
}

.chart-empty {
  height: 160px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 12px;
  color: var(--k-text-secondary);
}

.axis-label {
  position: absolute;
  font-size: 11px;
  color: var(--k-text-secondary);
}

.axis-max { top: 22px; left: 2px; }
.axis-min { bottom: 6px; right: 2px; }

/* 交易明细 */
.trades-card { padding: 12px 0 0; }

.trades-scroll {
  overflow-x: auto;
  padding: 0 12px;
}

.t-row {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 8px 0;
}

.t-head { padding: 6px 0; }

.tc {
  font-size: 12px;
  color: var(--k-text);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.t-head .tc {
  font-size: 11px;
  color: var(--k-text-secondary);
}

.tc-c { text-align: center; }
.tc-r { text-align: right; }

.t-date, .t-sec { color: var(--k-text-secondary); }

.expand-btn {
  width: 100%;
  border: none;
  background: none;
  color: var(--k-accent);
  font-size: 12.5px;
  font-weight: 600;
  min-height: 44px;
  cursor: pointer;
}

/* 空态 / 提示 */
.empty-card {
  background: var(--k-bg-secondary);
  border-radius: 12px;
  padding: 28px 0;
  text-align: center;
  margin-bottom: 12px;
}

.empty-main {
  font-size: 13px;
  color: var(--k-text-secondary);
}

.empty-sub {
  font-size: 11px;
  color: var(--k-text-tertiary);
  margin-top: 8px;
}

.notice-card { margin-bottom: 0; }

.scan-line {
  font-size: 12px;
  font-weight: 500;
  color: var(--k-text);
}

.skip-toggle {
  border: none;
  background: none;
  color: var(--k-text-secondary);
  font-size: 12.5px;
  font-weight: 500;
  min-height: 44px;
  padding: 0;
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: 4px;
}

.skip-box {
  background: var(--k-bg);
  border-radius: 12px;
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.skip-line {
  font-size: 12px;
  color: var(--k-text-secondary);
  line-height: 1.5;
}

/* A 股语义色 */
.tone-red { color: #ff3b30; }
.tone-green { color: var(--k-ok); }
</style>

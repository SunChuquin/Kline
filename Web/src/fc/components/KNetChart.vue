<template>
  <div class="chart-card">
    <div v-if="modelValue.equity?.length" class="chart-range">区间 {{ fmtDate(firstDate) }} ~ {{ fmtDate(lastDate) }}</div>
    <!-- SVG 手绘净值曲线：等距 x + 归一化 y（含基线 + 回撤高亮），对齐原生 NetValueChartView -->
    <svg
      v-if="modelValue.equity?.length"
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
    <div v-if="modelValue.equity?.length" class="axis-label axis-max">最高 {{ fmtAmount0(maxEquity) }}</div>
    <div v-if="modelValue.equity?.length" class="axis-label axis-min">最低 {{ fmtAmount0(minEquity) }}</div>
  </div>
</template>

<script setup lang="ts">
// k-net-chart：回测净值曲线（SVG 手绘：等距 x + 归一化 y + 回撤区间高亮 + 基线虚线；
// 宽度按容器实测（ResizeObserver，v-show 子页首次显示时宽度才可用），对齐原生）。
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'

export interface EquityPoint {
  date: number
  equity: number
}

const props = withDefaults(defineProps<{
  modelValue?: { equity?: EquityPoint[]; initialCapital?: number; maxDrawdownRange?: [number, number] | null }
}>(), {
  modelValue: () => ({ equity: [], initialCapital: 0, maxDrawdownRange: null }),
})

const chartRef = ref<SVGElement | null>(null)
const chartW = ref(600)
const chartH = 160

let observer: ResizeObserver | null = null

function stopObserve(): void {
  observer?.disconnect()
}

function startObserve(el: SVGElement | null): void {
  stopObserve()
  if (el) observer?.observe(el)
}

onMounted(() => {
  observer = new ResizeObserver((entries) => {
    const w = entries[0]?.contentRect.width
    if (w && w > 40) chartW.value = Math.round(w)
  })
  startObserve(chartRef.value)
})

// svg 为 v-if 渲染：结果数据后到时需重新挂观察器
watch(chartRef, (el) => startObserve(el))

onBeforeUnmount(() => {
  stopObserve()
  observer = null
})

const values = computed(() => (props.modelValue.equity ?? []).map((p) => p.equity))
const base = computed(() => props.modelValue.initialCapital ?? 0)
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
  const range = props.modelValue.maxDrawdownRange
  if (!range || !n.value) return null
  const i0 = Math.min(Math.max(range[0], 0), n.value - 1)
  const i1 = Math.min(Math.max(range[1], 0), n.value - 1)
  if (i1 < i0) return null
  const x0 = px(i0)
  return { x: x0, w: Math.max(px(i1) - x0, 2) }
})

const firstDate = computed(() => props.modelValue.equity?.[0]?.date ?? 0)
const lastDate = computed(() => props.modelValue.equity?.at(-1)?.date ?? 0)
const maxEquity = computed(() => Math.max(...(props.modelValue.equity?.map((p) => p.equity) ?? [0])))
const minEquity = computed(() => Math.min(...(props.modelValue.equity?.map((p) => p.equity) ?? [0])))

function fmtAmount0(v: number): string {
  return Math.round(v).toLocaleString('en-US')
}

function fmtDate(v: number): string {
  if (v <= 0) return '—'
  const text = String(v)
  if (text.length !== 8) return text
  return `${text.slice(0, 4)}-${text.slice(4, 6)}-${text.slice(6, 8)}`
}
</script>

<style scoped>
.chart-card {
  position: relative;
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 12px;
  padding: 12px;
  margin-bottom: 12px;
}

.chart-range {
  font-size: 11px;
  color: var(--k-text-secondary, #6c6c70);
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
  color: var(--k-text-secondary, #6c6c70);
}

.axis-label {
  position: absolute;
  font-size: 11px;
  color: var(--k-text-secondary, #6c6c70);
}

.axis-max { top: 30px; left: 16px; }
.axis-min { bottom: 6px; right: 16px; }
</style>

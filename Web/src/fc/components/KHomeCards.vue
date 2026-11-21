<template>
  <div class="cards">
    <!-- 大盘概览 -->
    <div class="card">
      <div class="card-title">大盘概览</div>
      <div v-if="modelValue.indices.length === 0" class="block-empty">
        {{ modelValue.loaded ? '暂无指数数据' : '指数加载中' }}
      </div>
      <template v-else>
        <!-- 竖屏：每指数一行全宽（名称左 / 现价+涨跌幅胶囊右）；宽屏 4 列 -->
        <div class="indices">
          <div
            v-for="q in modelValue.indices"
            :key="q.file"
            class="index-row"
            @click="openDetail(q, modelValue.indices)"
          >
            <span class="index-name">{{ q.name }}</span>
            <span class="index-price" :class="pctClass(q)">{{ fmtPrice(q) }}</span>
            <span class="pct-pill" :class="pillClass(q)">{{ fmtPct(q) }}</span>
          </div>
        </div>
      </template>
      <div v-if="modelValue.breadth" class="breadth">
        <div class="breadth-line">
          <span class="up">涨 {{ modelValue.breadth.up }}</span><span class="sep">·</span>
          <span class="muted">平 {{ modelValue.breadth.flat }}</span><span class="sep">·</span>
          <span class="down">跌 {{ modelValue.breadth.down }}</span>
        </div>
        <div class="breadth-line">
          <span class="up">涨停 {{ modelValue.breadth.limitUp }}</span><span class="sep">/</span>
          <span class="down">跌停 {{ modelValue.breadth.limitDown }}</span>
        </div>
      </div>
      <div v-else class="block-empty">{{ modelValue.loaded && !modelValue.hasMainBoard ? '暂无涨跌数据' : '加载中' }}</div>
    </div>

    <!-- 双列：我的自选 + 模拟账户 -->
    <div class="two-col">
      <div class="card">
        <div class="card-title">我的自选</div>
        <div v-if="modelValue.favorites.length === 0" class="block-empty tap" @click="emit('switchTab', 1)">
          暂无自选，去自选页添加
        </div>
        <div v-else class="quote-rows">
          <div
            v-for="q in modelValue.favorites"
            :key="q.file"
            class="quote-row"
            @click="openDetail(q, modelValue.favorites)"
          >
            <div class="q-left">
              <div class="q-name">{{ q.name }}</div>
              <div class="q-code">{{ q.code }}</div>
            </div>
            <span class="q-price" :class="pctClass(q)">{{ fmtPrice(q) }}</span>
            <span class="pct-pill" :class="pillClass(q)">{{ fmtPct(q) }}</span>
            <svg v-if="q.closes && q.closes.length > 1" class="spark" viewBox="0 0 60 24" preserveAspectRatio="none">
              <polyline :points="sparkPoints(q.closes)" :stroke="sparkColor(q)" fill="none" stroke-width="1.5" />
            </svg>
          </div>
        </div>
      </div>

      <div class="card" @click="emit('switchTab', 3)">
        <div class="card-title">模拟账户</div>
        <div class="sim-asset">
          <div class="sim-label">总资产</div>
          <div class="sim-value">{{ fmtAmount(modelValue.sim.totalAssets) }}</div>
        </div>
        <div class="sim-metrics">
          <div class="sim-metric">
            <div class="sim-label">当日盈亏</div>
            <div class="sim-metric-value" :class="profitClass(modelValue.sim.dayProfit)">
              {{ fmtSigned0(modelValue.sim.dayProfit) }} <small>{{ fmtPctRaw(modelValue.sim.dayProfitPct * 100) }}</small>
            </div>
          </div>
          <div class="sim-metric">
            <div class="sim-label">持仓占比</div>
            <div class="sim-metric-value primary">{{ fmtPctRaw(modelValue.sim.positionPct * 100) }}</div>
          </div>
        </div>
        <div v-if="modelValue.simPositions.length === 0" class="block-empty">暂无持仓</div>
        <div v-else class="position-rows">
          <div v-for="p in modelValue.simPositions" :key="p.code" class="position-row">
            <div class="q-left">
              <div class="q-name">{{ p.name }}</div>
              <div class="q-code">{{ p.code }}</div>
            </div>
            <span class="q-price primary">{{ p.lastPrice.toFixed(2) }}</span>
            <div class="q-profit">
              <div class="q-profit-main" :class="profitClass(p.profit)">{{ fmtSigned(p.profit) }}</div>
              <div class="q-profit-pct" :class="profitClass(p.profitPct)">{{ fmtPctRaw(p.profitPct * 100) }}</div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- 涨幅榜 -->
    <div class="card">
      <div class="card-title">涨幅榜</div>
      <div v-if="modelValue.gainers.length === 0" class="block-empty">
        {{ modelValue.gainersReady || (modelValue.loaded && !modelValue.hasMainBoard) ? '暂无数据' : '数据加载中' }}
      </div>
      <div v-else class="quote-rows">
        <div
          v-for="q in modelValue.gainers"
          :key="q.file"
          class="quote-row"
          @click="openDetail(q, modelValue.gainers)"
        >
          <div class="q-left">
            <div class="q-name">{{ q.name }}</div>
            <div class="q-code">{{ q.code }}</div>
          </div>
          <span class="q-price" :class="pctClass(q)">{{ fmtPrice(q) }}</span>
          <span class="pct-pill" :class="pillClass(q)">{{ fmtPct(q) }}</span>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
// k-home-cards：首页卡片区（大盘概览 / 自选+模拟双列 / 涨幅榜，对齐 B 档默认布局）。
// 迁移自 HomePage.vue 卡片区（含迷你走势 SVG、模拟持仓、竖屏堆叠媒体查询）；
// 快照数据由 adapter 注入，行点击 openDetail({file, context}) 与 switchTab(index) 抛给 adapter。
export interface HomeQuote {
  file: string
  code: string
  name: string
  price: number | null
  pct: number | null
}

export interface HomeFavQuote extends HomeQuote {
  closes: number[]
}

export interface HomeSimSummary {
  totalAssets: number
  dayProfit: number
  dayProfitPct: number
  positionPct: number
}

export interface HomeSimPosition {
  code: string
  name: string
  lastPrice: number
  profit: number
  profitPct: number
}

export interface HomeBreadth {
  up: number
  down: number
  flat: number
  limitUp: number
  limitDown: number
}

import {
  fmtPrice, fmtPct, fmtPctRaw, fmtAmount, fmtSigned0, pctClass, pillClass, profitClass,
} from '../format'

withDefaults(defineProps<{
  modelValue?: {
    indices?: HomeQuote[]
    breadth?: HomeBreadth | null
    favorites?: HomeFavQuote[]
    sim?: HomeSimSummary
    simPositions?: HomeSimPosition[]
    gainers?: HomeQuote[]
    loaded?: boolean
    hasMainBoard?: boolean
    gainersReady?: boolean
  }
}>(), {
  modelValue: () => ({
    indices: [], breadth: null, favorites: [],
    sim: { totalAssets: 0, dayProfit: 0, dayProfitPct: 0, positionPct: 0 },
    simPositions: [], gainers: [], loaded: false, hasMainBoard: true, gainersReady: false,
  }),
})

const emit = defineEmits<{
  (e: 'openDetail', payload: { file: string; context: string[] }): void
  (e: 'switchTab', index: number): void
}>()

function fmtSigned(v: number): string {
  return `${v > 0 ? '+' : ''}${v.toFixed(2)}`
}

/** 点行进详情（context = 当前列表 file 顺序，详情页副图左右切换用） */
function openDetail(q: HomeQuote, list: HomeQuote[]): void {
  emit('openDetail', { file: q.file, context: list.map((x) => x.file) })
}

/** 迷你走势折线点集（60×24 viewBox，对齐 MarketSparkline 尺寸） */
function sparkPoints(closes: number[]): string {
  const min = Math.min(...closes)
  const max = Math.max(...closes)
  const range = max - min || 1
  const step = 60 / (closes.length - 1)
  return closes
    .map((c, i) => `${(i * step).toFixed(1)},${(22 - ((c - min) / range) * 20).toFixed(1)}`)
    .join(' ')
}

function sparkColor(q: HomeFavQuote): string {
  return (q.pct ?? 0) >= 0 ? '#ff4d4f' : '#00b578'
}
</script>

<style scoped>
.cards {
  padding: 4px 16px 0;
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.card {
  background: var(--k-bg-secondary);
  border-radius: 14px;
  padding: 12px 14px;
}

.two-col {
  display: flex;
  gap: 12px;
}

.two-col .card {
  flex: 1;
  min-width: 0;
}

.card-title {
  font-size: 15px;
  font-weight: 600;
  color: var(--k-text);
  margin-bottom: 10px;
}

.block-empty {
  font-size: 13px;
  color: var(--k-text-secondary);
  min-height: 44px;
  display: flex;
  align-items: center;
}

.block-empty.tap {
  cursor: pointer;
}

/* ===== 大盘概览 ===== */
.indices {
  display: flex;
}

.index-row {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-height: 52px;
  cursor: pointer;
}

.index-name {
  font-size: 11px;
  color: var(--k-text-secondary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.index-price {
  font-size: 15px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}

.index-row .pct-pill {
  align-self: flex-start;
}

/* 竖屏（<600，对齐原生 CompactWidth 阈值）：指数行垂直堆叠全宽 */
@media (max-width: 599px) {
  .indices {
    flex-direction: column;
  }

  .index-row {
    flex-direction: row;
    align-items: center;
    gap: 10px;
    min-height: 44px;
  }

  .index-name {
    font-size: 13px;
    font-weight: 500;
    color: var(--k-text);
    flex: 1;
  }

  .index-price {
    font-size: 15px;
  }

  .index-row .pct-pill {
    align-self: center;
  }

  .two-col {
    flex-direction: column;
  }
}

.breadth {
  margin-top: 8px;
  display: flex;
  flex-direction: column;
  gap: 3px;
}

.breadth-line {
  display: flex;
  gap: 6px;
  font-size: 12px;
}

.breadth .sep,
.breadth .muted {
  color: var(--k-text-secondary);
}

/* ===== 行情行（自选/涨幅榜共用，对齐 HomeQuoteRow） ===== */
.quote-rows {
  display: flex;
  flex-direction: column;
}

.quote-row {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: 48px;
  cursor: pointer;
}

.q-left {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.q-name {
  font-size: 14px;
  color: var(--k-text);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.q-code {
  font-size: 11px;
  color: var(--k-text-secondary);
}

.q-price {
  font-size: 14px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}

.q-price.primary,
.sim-metric-value.primary {
  color: var(--k-text);
}

.pct-pill {
  font-size: 12px;
  font-weight: 600;
  color: #ffffff;
  padding: 3px 7px;
  border-radius: 6px;
  font-variant-numeric: tabular-nums;
}

.pill-up {
  background: #ff4d4f;
}

.pill-down {
  background: #00b578;
}

.pill-flat {
  background: #8e8e93;
}

.up {
  color: #ff4d4f;
}

.down {
  color: #00b578;
}

.spark {
  width: 60px;
  height: 24px;
  flex-shrink: 0;
}

/* ===== 模拟账户 ===== */
.sim-asset {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.sim-label {
  font-size: 11px;
  color: var(--k-text-secondary);
}

.sim-value {
  font-size: 18px;
  font-weight: 600;
  color: var(--k-text);
  font-variant-numeric: tabular-nums;
}

.sim-metrics {
  display: flex;
  gap: 14px;
  margin-top: 10px;
}

@media (max-width: 599px) {
  .sim-metrics {
    flex-direction: column;
    gap: 8px;
  }
}

.sim-metric {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.sim-metric-value {
  font-size: 14px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}

.sim-metric-value small {
  font-size: 11px;
  font-weight: 400;
}

.position-rows {
  margin-top: 8px;
  display: flex;
  flex-direction: column;
}

.position-row {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: 44px;
}

.q-profit {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 2px;
}

.q-profit-main {
  font-size: 13px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}

.q-profit-pct {
  font-size: 11px;
  font-variant-numeric: tabular-nums;
}
</style>

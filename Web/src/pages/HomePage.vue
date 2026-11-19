<template>
  <div class="page">
    <div class="banner">首页 · Web 版（P2-3）</div>

    <div v-if="!bridgeOk" class="card-warn">桥接不可达：显示占位界面</div>

    <!-- 标题栏：软件图标 + 名称 + 登录胶囊（对齐 HomeHeaderBar） -->
    <div class="header">
      <div class="brand">
        <span class="brand-icon">📈</span>
        <!-- aria-label = UITest 锚点（KlineUITests/LANSyncUITests/GapBackfillUITests 首页判定） -->
        <span class="brand-name" aria-label="home.page">Kline</span>
      </div>
      <button class="profile-pill" aria-label="home.profileButton" @click="openEntry('profile')">
        <van-icon name="user-circle-o" class="profile-icon" />
        <span>登录</span>
      </button>
    </div>

    <!-- 横滑快捷入口行（对齐 HomeQuickEntryRow） -->
    <div class="entries">
      <button
        v-for="e in entries"
        :key="e.id"
        class="entry-chip"
        :style="{ '--tint': e.tint }"
        @click="openEntry(e.id)"
      >
        <span class="entry-icon">
          <van-icon v-if="iconFor(e.id)" :name="iconFor(e.id)!" />
          <b v-else>{{ textIconFor(e.id) }}</b>
        </span>
        <span class="entry-title">{{ e.title }}</span>
        <span class="entry-subtitle">{{ e.subtitle }}</span>
      </button>
    </div>

    <!-- 卡片区（对齐 B 档默认布局：概览 / 自选+模拟双列 / 涨幅榜） -->
    <div class="cards">
      <!-- 大盘概览 -->
      <div class="card">
        <div class="card-title">大盘概览</div>
        <div v-if="indices.length === 0" class="block-empty">
          {{ loaded ? '暂无指数数据' : '指数加载中' }}
        </div>
        <template v-else>
          <!-- 竖屏：每指数一行全宽（名称左 / 现价+涨跌幅胶囊右）；宽屏 4 列 -->
          <div class="indices">
            <div
              v-for="q in indices"
              :key="q.file"
              class="index-row"
              @click="openDetail(q, indices)"
            >
              <span class="index-name">{{ q.name }}</span>
              <span class="index-price" :class="pctClass(q)">{{ fmtPrice(q) }}</span>
              <span class="pct-pill" :class="pillClass(q)">{{ fmtPct(q) }}</span>
            </div>
          </div>
        </template>
        <div v-if="breadth" class="breadth">
          <div class="breadth-line">
            <span class="up">涨 {{ breadth.up }}</span><span class="sep">·</span>
            <span class="muted">平 {{ breadth.flat }}</span><span class="sep">·</span>
            <span class="down">跌 {{ breadth.down }}</span>
          </div>
          <div class="breadth-line">
            <span class="up">涨停 {{ breadth.limitUp }}</span><span class="sep">/</span>
            <span class="down">跌停 {{ breadth.limitDown }}</span>
          </div>
        </div>
        <div v-else class="block-empty">{{ loaded && !hasMainBoard ? '暂无涨跌数据' : '加载中' }}</div>
      </div>

      <!-- 双列：我的自选 + 模拟账户 -->
      <div class="two-col">
        <div class="card">
          <div class="card-title">我的自选</div>
          <div v-if="favorites.length === 0" class="block-empty tap" @click="switchTab(1)">
            暂无自选，去自选页添加
          </div>
          <div v-else class="quote-rows">
            <div
              v-for="q in favorites"
              :key="q.file"
              class="quote-row"
              @click="openDetail(q, favorites)"
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

        <div class="card" @click="switchTab(3)">
          <div class="card-title">模拟账户</div>
          <div class="sim-asset">
            <div class="sim-label">总资产</div>
            <div class="sim-value">{{ fmtAmount(sim.totalAssets) }}</div>
          </div>
          <div class="sim-metrics">
            <div class="sim-metric">
              <div class="sim-label">当日盈亏</div>
              <div class="sim-metric-value" :class="profitClass(sim.dayProfit)">
                {{ fmtSigned0(sim.dayProfit) }} <small>{{ fmtPctRaw(sim.dayProfitPct * 100) }}</small>
              </div>
            </div>
            <div class="sim-metric">
              <div class="sim-label">持仓占比</div>
              <div class="sim-metric-value primary">{{ fmtPctRaw(sim.positionPct * 100) }}</div>
            </div>
          </div>
          <div v-if="simPositions.length === 0" class="block-empty">暂无持仓</div>
          <div v-else class="position-rows">
            <div v-for="p in simPositions" :key="p.code" class="position-row">
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
        <div v-if="gainers.length === 0" class="block-empty">
          {{ gainersReady || (loaded && !hasMainBoard) ? '暂无数据' : '数据加载中' }}
        </div>
        <div v-else class="quote-rows">
          <div
            v-for="q in gainers"
            :key="q.file"
            class="quote-row"
            @click="openDetail(q, gainers)"
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
  </div>
</template>

<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { klineBus } from '../bridge/klineBus'
import { showToast } from 'vant'

// ===== 协议形状（web/src/types/protocol.ts 对拍） =====
interface HomeEntry {
  id: string
  title: string
  subtitle: string
  tint: string
}

interface HomeQuote {
  file: string
  code: string
  name: string
  price: number | null
  pct: number | null
}

interface HomeFavQuote extends HomeQuote {
  closes: number[]
}

interface HomeSimSummary {
  totalAssets: number
  dayProfit: number
  dayProfitPct: number
  positionPct: number
}

interface HomeSimPosition {
  code: string
  name: string
  lastPrice: number
  profit: number
  profitPct: number
}

interface HomeBreadth {
  up: number
  down: number
  flat: number
  limitUp: number
  limitDown: number
}

// ===== 页面状态 =====
const bridgeOk = ref(false)
const loaded = ref(false)
const hasMainBoard = ref(true)
const entries = ref<HomeEntry[]>([])
const indices = ref<HomeQuote[]>([])
const breadth = ref<HomeBreadth | null>(null)
const favorites = ref<HomeFavQuote[]>([])
const sim = ref<HomeSimSummary>({ totalAssets: 0, dayProfit: 0, dayProfitPct: 0, positionPct: 0 })
const simPositions = ref<HomeSimPosition[]>([])
const gainers = ref<HomeQuote[]>([])
const gainersReady = ref(false)

// ===== 入口图标映射（Vant 图标 + 文字替代；对齐 HomeEntryKind.icon 语义） =====
function iconFor(id: string): string | null {
  const map: Record<string, string> = {
    search: 'search',
    picker: 'filter-o',
    strategy: 'chart-trending-o',
    condOrder: 'bell',
    profile: 'user-circle-o',
    alertRecords: 'clock-o',
    training: 'medal-o',
    lanSync: 'exchange',
  }
  return map[id] ?? null
}

function textIconFor(id: string): string {
  if (id === 'tech') return 'ƒx'
  if (id === 'pythonLab') return 'Py'
  return '·'
}

// ===== 格式化（对齐原生 MarketRow.render / SimFormat） =====
function fmtPrice(q: HomeQuote): string {
  return q.price === null ? '—' : q.price.toFixed(2)
}

function fmtPct(q: HomeQuote): string {
  if (q.pct === null) return '—'
  return fmtPctRaw(q.pct)
}

function fmtPctRaw(v: number): string {
  return `${v > 0 ? '+' : ''}${v.toFixed(2)}%`
}

function fmtAmount(v: number): string {
  return Math.round(v).toLocaleString('en-US')
}

function fmtSigned0(v: number): string {
  return `${v > 0 ? '+' : ''}${Math.round(v).toLocaleString('en-US')}`
}

function fmtSigned(v: number): string {
  return `${v > 0 ? '+' : ''}${v.toFixed(2)}`
}

function pctClass(q: HomeQuote): string {
  const p = q.pct ?? 0
  return p > 0 ? 'up' : p < 0 ? 'down' : ''
}

function pillClass(q: HomeQuote): string {
  const p = q.pct ?? 0
  return p > 0 ? 'pill-up' : p < 0 ? 'pill-down' : 'pill-flat'
}

function profitClass(v: number): string {
  return v < 0 ? 'down' : 'up'
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

// ===== 快照回读 =====
async function pullSnapshot(): Promise<void> {
  try {
    const s = ((await klineBus.request('home', 'snapshot')) ?? {}) as Record<string, unknown>
    loaded.value = s.loaded === true
    hasMainBoard.value = s.hasMainBoard === true
    entries.value = (Array.isArray(s.entries) ? (s.entries as Record<string, unknown>[]) : []).map((e) => ({
      id: String(e.id ?? ''),
      title: String(e.title ?? ''),
      subtitle: String(e.subtitle ?? ''),
      tint: String(e.tint ?? '#007aff'),
    }))
    const mapQuote = (r: Record<string, unknown>): HomeQuote => ({
      file: String(r.file ?? ''),
      code: String(r.code ?? ''),
      name: String(r.name ?? ''),
      price: typeof r.price === 'number' ? r.price : null,
      pct: typeof r.pct === 'number' ? r.pct : null,
    })
    indices.value = (Array.isArray(s.indices) ? (s.indices as Record<string, unknown>[]) : []).map(mapQuote)
    favorites.value = (Array.isArray(s.favorites) ? (s.favorites as Record<string, unknown>[]) : []).map((r) => ({
      ...mapQuote(r),
      closes: Array.isArray(r.closes) ? (r.closes as number[]) : [],
    }))
    const simRaw = s.sim as Record<string, unknown> | undefined
    if (simRaw) {
      sim.value = {
        totalAssets: typeof simRaw.totalAssets === 'number' ? simRaw.totalAssets : 0,
        dayProfit: typeof simRaw.dayProfit === 'number' ? simRaw.dayProfit : 0,
        dayProfitPct: typeof simRaw.dayProfitPct === 'number' ? simRaw.dayProfitPct : 0,
        positionPct: typeof simRaw.positionPct === 'number' ? simRaw.positionPct : 0,
      }
    }
    simPositions.value = (Array.isArray(s.simPositions) ? (s.simPositions as Record<string, unknown>[]) : []).map((p) => ({
      code: String(p.code ?? ''),
      name: String(p.name ?? ''),
      lastPrice: typeof p.lastPrice === 'number' ? p.lastPrice : 0,
      profit: typeof p.profit === 'number' ? p.profit : 0,
      profitPct: typeof p.profitPct === 'number' ? p.profitPct : 0,
    }))
    gainers.value = (Array.isArray(s.gainers) ? (s.gainers as Record<string, unknown>[]) : []).map(mapQuote)
    gainersReady.value = s.gainersReady === true
  } catch (e) {
    console.error('home.snapshot 失败', e)
  }
}

// ===== 动作 =====
async function openEntry(kind: string): Promise<void> {
  try {
    await klineBus.request('home', 'openEntry', { kind })
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
  }
}

/** 点行进详情（context = 当前列表 file 顺序，详情页副图左右切换用） */
function openDetail(q: HomeQuote, list: HomeQuote[]): void {
  klineBus.request('home', 'openDetail', {
    file: q.file,
    context: list.map((x) => x.file),
  }).catch((e) => console.error(e))
}

function switchTab(index: number): void {
  klineBus.request('nav', 'switchTab', { index }).catch((e) => console.error(e))
}

onMounted(async () => {
  const t = await klineBus.detect()
  bridgeOk.value = t !== 'none'
  if (!bridgeOk.value) return

  // native 模式：数据变化事件触发回读（pc 模式由页面回读兜底）
  klineBus.on('home.changed', () => void pullSnapshot())

  await pullSnapshot()
  // 主库未就绪（冷启动竞态）：3s 后重试一次
  if (!loaded.value) {
    setTimeout(() => void pullSnapshot(), 3000)
  }
})
</script>

<style scoped>
.page {
  min-height: 100%;
  background: var(--k-bg);
  padding-bottom: 16px;
}

.banner {
  font-size: 12px;
  color: var(--k-text-secondary);
  padding: 6px 16px 0;
}

.card-warn {
  margin: 8px 16px 0;
  background: var(--k-bg-secondary);
  border-radius: 12px;
  padding: 12px 16px;
  font-size: 13px;
  color: #b25000;
}

/* ===== 标题栏 ===== */
.header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 56px;
  padding: 0 16px;
}

.brand {
  display: flex;
  align-items: center;
  gap: 6px;
}

.brand-icon {
  font-size: 22px;
}

.brand-name {
  font-size: 18px;
  font-weight: 700;
  color: var(--k-text);
}

.profile-pill {
  display: flex;
  align-items: center;
  gap: 5px;
  border: none;
  border-radius: 20px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 15px;
  padding: 4px 10px;
  cursor: pointer;
}

.profile-icon {
  font-size: 22px;
  color: #007aff;
}

/* ===== 横滑入口行 ===== */
.entries {
  display: flex;
  gap: 12px;
  padding: 12px 16px;
  overflow-x: auto;
  white-space: nowrap;
  scrollbar-width: none;
}

.entries::-webkit-scrollbar {
  display: none;
}

.entry-chip {
  flex-shrink: 0;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 4px;
  min-width: 168px;
  min-height: 68px;
  border: none;
  border-radius: 12px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  text-align: left;
  padding: 10px 14px;
  cursor: pointer;
}

.entry-icon {
  font-size: 20px;
  color: var(--tint);
  line-height: 1;
}

.entry-icon b {
  font-size: 15px;
  font-weight: 700;
}

.entry-title {
  font-size: 13px;
  font-weight: 600;
}

.entry-subtitle {
  font-size: 11px;
  color: var(--k-text-secondary);
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 150px;
}

/* ===== 卡片区 ===== */
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

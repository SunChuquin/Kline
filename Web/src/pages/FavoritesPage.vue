<template>
  <div class="page">
    <div class="banner">自选 · Web 版（P2-1）</div>

    <div v-if="!bridgeOk" class="card-warn">桥接不可达：显示占位界面</div>

    <!-- 分组 Tab（横滚 chips，对齐原生自选页分组条） -->
    <div class="tabs">
      <div
        v-for="(g, i) in groups"
        :key="g.id"
        class="tab-chip"
        :class="{ active: i === activeIdx }"
        @click="activeIdx = i"
      >
        {{ g.name }}<span v-if="g.count > 0" class="tab-count">{{ g.count }}</span>
      </div>
    </div>

    <van-pull-refresh v-model="refreshing" success-text="已刷新" @refresh="onRefresh">
      <div class="rows">
        <div v-for="row in currentRows" :key="row.file" class="fav-row" @click="openDetail(row)">
          <div class="row-left">
            <div class="row-name">
              {{ row.name }}
              <span v-if="row.pinned" class="pin-tag">顶</span>
            </div>
            <div class="row-code">{{ row.code }}</div>
          </div>
          <div class="row-right">
            <div class="row-price" :class="tintClass(row)">{{ fmtPrice(row) }}</div>
            <div class="row-pct" :class="tintClass(row)">{{ fmtPct(row) }}</div>
          </div>
        </div>
        <div v-if="currentRows.length === 0" class="empty">
          {{ loaded ? '该分组暂无自选' : '主库加载中，稍后自动重试…' }}
        </div>
      </div>
    </van-pull-refresh>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { klineBus } from '../bridge/klineBus'
import { KnownEvents } from '../types/protocol'

interface FavRow {
  file: string
  code: string
  name: string
  latestPrice: number | null
  change: number | null
  changePct: number | null
  volume: number | null
  turnover: number | null
  lastDate: string
  pinned: boolean
  note: string
}

interface FavGroup {
  id: string
  kind: 'manual' | 'formula'
  name: string
  rows: FavRow[]
}

const bridgeOk = ref(false)
const loaded = ref(false)
const refreshing = ref(false)
const activeIdx = ref(0)
const groups = ref<FavGroup[]>([])

const currentRows = computed<FavRow[]>(() => groups.value[activeIdx.value]?.rows ?? [])
const currentGroupId = computed(() => groups.value[activeIdx.value]?.id ?? null)

function fmtPrice(row: FavRow): string {
  return row.latestPrice === null ? '—' : row.latestPrice.toFixed(2)
}

function fmtPct(row: FavRow): string {
  if (row.changePct === null) return '—'
  const sign = row.changePct > 0 ? '+' : ''
  return `${sign}${row.changePct.toFixed(2)}%`
}

/** 红涨绿跌（对齐原生 tintColor：systemRed 涨 / systemGreen 跌） */
function tintClass(row: FavRow): string {
  const pct = row.changePct ?? 0
  if (pct > 0) return 'up'
  if (pct < 0) return 'down'
  return ''
}

async function pullSnapshot(): Promise<void> {
  try {
    const s = ((await klineBus.request('favorites', 'snapshot')) ?? {}) as Record<string, unknown>
    loaded.value = s.loaded === true
    const raw = Array.isArray(s.groups) ? (s.groups as Record<string, unknown>[]) : []
    groups.value = raw.map((g) => ({
      id: String(g.id ?? ''),
      kind: (g.kind === 'formula' ? 'formula' : 'manual') as FavGroup['kind'],
      name: String(g.name ?? ''),
      rows: (Array.isArray(g.rows) ? (g.rows as Record<string, unknown>[]) : []).map((r) => ({
        file: String(r.file ?? ''),
        code: String(r.code ?? ''),
        name: String(r.name ?? ''),
        latestPrice: typeof r.latestPrice === 'number' ? r.latestPrice : null,
        change: typeof r.change === 'number' ? r.change : null,
        changePct: typeof r.changePct === 'number' ? r.changePct : null,
        volume: typeof r.volume === 'number' ? r.volume : null,
        turnover: typeof r.turnover === 'number' ? r.turnover : null,
        lastDate: String(r.lastDate ?? ''),
        pinned: r.pinned === true,
        note: String(r.note ?? ''),
      })),
    }))
    // 选中分组失效时回首个 Tab
    if (activeIdx.value >= groups.value.length) activeIdx.value = 0
  } catch (e) {
    console.error('favorites.snapshot 失败', e)
  }
}

async function onRefresh(): Promise<void> {
  if (!bridgeOk.value) {
    refreshing.value = false
    return
  }
  try {
    await klineBus.request('favorites', 'refresh', { group: currentGroupId.value })
    // 刷新异步完成：定时回读两次兜底（数据落缓存时机不确定；native 模式另有 favorites.changed 事件）
    setTimeout(() => void pullSnapshot(), 1500)
    setTimeout(async () => {
      await pullSnapshot()
      refreshing.value = false
    }, 3500)
  } catch {
    refreshing.value = false
  }
}

function openDetail(row: FavRow): void {
  klineBus.request('favorites', 'openDetail', { file: row.file }).catch((e) => console.error(e))
}

onMounted(async () => {
  const t = await klineBus.detect()
  bridgeOk.value = t !== 'none'
  if (!bridgeOk.value) return

  // native 模式：数据变化事件触发回读（pc 模式由刷新后的定时回读兜底）
  klineBus.on('favorites.changed', () => void pullSnapshot())

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
  padding: 8px 0 16px;
  background: var(--k-bg);
}

.banner {
  font-size: 12px;
  color: var(--k-text-secondary);
  padding: 6px 12px 8px;
}

.card-warn {
  margin: 0 12px 10px;
  background: var(--k-bg-secondary);
  border-radius: 12px;
  padding: 12px 16px;
  font-size: 13px;
  color: #b25000;
}

/* 分组 Tab：横滚 chips */
.tabs {
  display: flex;
  gap: 8px;
  padding: 0 12px 10px;
  overflow-x: auto;
  white-space: nowrap;
}

.tab-chip {
  flex-shrink: 0;
  padding: 7px 14px;
  border-radius: 16px;
  font-size: 14px;
  color: var(--k-text-secondary);
  background: var(--k-bg-secondary);
}

.tab-chip.active {
  color: #ffffff;
  background: var(--k-accent);
}

.tab-count {
  margin-left: 4px;
  font-size: 11px;
  opacity: 0.85;
}

/* 行列表：高密度（44pt 触达 + 紧凑间距） */
.rows {
  padding: 0 12px;
}

.fav-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 52px;
  padding: 6px 12px;
  margin-bottom: 8px;
  background: var(--k-bg-secondary);
  border-radius: 10px;
  cursor: pointer;
}

.fav-row:active {
  opacity: 0.6;
}

.row-left {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.row-name {
  font-size: 15px;
  font-weight: 600;
  color: var(--k-text);
}

.pin-tag {
  display: inline-block;
  font-size: 10px;
  font-weight: 600;
  color: var(--k-accent);
  border: 1px solid var(--k-accent);
  border-radius: 4px;
  padding: 0 3px;
  margin-left: 4px;
  vertical-align: middle;
}

.row-code {
  font-size: 12px;
  color: var(--k-text-secondary);
}

.row-right {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 2px;
  font-variant-numeric: tabular-nums;
}

.row-price {
  font-size: 15px;
  font-weight: 600;
  color: var(--k-text);
}

.row-pct {
  font-size: 12px;
}

.row-price.up,
.row-pct.up {
  color: #ff4d4f;
}

.row-price.down,
.row-pct.down {
  color: #00b578;
}

.empty {
  text-align: center;
  font-size: 13px;
  color: var(--k-text-secondary);
  padding: 32px 0;
}
</style>

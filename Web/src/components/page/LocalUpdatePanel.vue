<template>
  <div class="lup">
    <!-- 顶部返回栏（对齐原生个人中心同款） -->
    <div class="nav-bar">
      <button class="nav-back" aria-label="page.back" @click="emit('close')">‹</button>
      <span class="nav-title">本地更新</span>
    </div>

    <div class="lup-body">
      <!-- ① 本地更新（在线服务 / 检查新版 / 更新引擎） -->
      <div class="sec-label">本地更新</div>
      <div class="card">
        <button
          class="row"
          :disabled="!!snap && (snap.server.ok || snap.server.probing)"
          @click="tapServerRow"
        >
          <span class="row-title">在线服务</span>
          <span class="st-icon" :class="serverClass">{{ serverGlyph }}</span>
        </button>
        <div class="divider"></div>
        <button
          class="row"
          :disabled="!!snap && (snap.app.state === 'checking' || snap.app.state === 'downloading')"
          @click="tapAppRow"
        >
          <span class="row-title">{{ snap?.app.title ?? '检查新版' }}</span>
          <span class="st-icon" :class="stateClass(snap?.app.state)">
            {{ snap?.app.state === 'downloading' ? snap?.app.percent : stateGlyph(snap?.app.state) }}
          </span>
        </button>
        <div class="divider"></div>
        <button
          class="row"
          :disabled="!!snap && (snap.engine.state === 'checking' || snap.engine.state === 'downloading')"
          @click="tapEngineRow"
        >
          <span class="row-title">{{ snap?.engine.title ?? '更新引擎' }}</span>
          <span class="st-icon" :class="stateClass(snap?.engine.state)">
            {{ snap?.engine.state === 'downloading' ? snap?.engine.percent : stateGlyph(snap?.engine.state) }}
          </span>
        </button>
      </div>

      <!-- ② 清单标的自动更新 -->
      <div class="sec-label">清单标的自动更新</div>
      <div class="card">
        <div class="row">
          <span class="row-title">状态</span>
          <span class="row-value" :class="`tone-${snap?.watchlist.stateTone ?? 'gray'}`">
            {{ snap?.watchlist.stateText ?? '—' }}
          </span>
          <span class="st-icon" :class="watchClass">{{ watchGlyph }}</span>
        </div>
        <div class="divider"></div>
        <div class="row">
          <span class="row-title">最近结果</span>
          <span class="row-value" :class="resultClass">{{ snap?.watchlist.lastResultText ?? '—' }}</span>
        </div>
        <div class="divider"></div>
        <div class="row">
          <span class="row-title">清单并集</span>
          <span class="row-value">{{ (snap?.watchlist.unionCount ?? 0) > 0 ? `${snap?.watchlist.unionCount} 只` : '—' }}</span>
        </div>
        <div class="divider"></div>
        <div class="row">
          <span class="row-title">本次请求</span>
          <span class="row-value">{{ snap?.watchlist.requestText ?? '—' }}</span>
        </div>
        <div class="divider"></div>
        <div class="row">
          <span class="row-title">当日交易日</span>
          <span class="row-value">{{ snap?.watchlist.lastTradeDate ?? '—' }}</span>
        </div>
        <div v-for="slot in snap?.watchlist.slots ?? []" :key="slot.time" class="slot-frag">
          <div class="divider"></div>
          <div class="row">
            <span class="row-title">{{ slot.title }}</span>
            <span class="row-value">{{ slot.value }}</span>
          </div>
        </div>
        <div class="divider"></div>
        <button
          class="row"
          :disabled="!snap?.watchlist.enabled || !!snap?.watchlist.isRunning"
          @click="act('syncNow')"
        >
          <span class="row-title" :class="{ dim: !snap?.watchlist.enabled || !!snap?.watchlist.isRunning }">立即更新</span>
          <span class="st-icon" :class="snap?.watchlist.isRunning ? 'state-yellow' : 'state-blue'">
            {{ snap?.watchlist.isRunning ? '◌' : '⟳' }}
          </span>
        </button>
        <div class="divider"></div>
        <div class="note-block">{{ snap?.watchlist.note ?? '' }}</div>
      </div>

      <!-- ③ 补缺口（主库最新日 → 今天） -->
      <div class="sec-label">补缺口（主库最新日 → 今天）</div>
      <div class="card">
        <div class="row">
          <span class="row-title">状态</span>
          <span class="row-value" :class="gapToneClass" :aria-label="'gapBackfill.status|' + (snap?.gap.statusText ?? '')">
            {{ snap?.gap.statusText ?? '—' }}
          </span>
        </div>
        <div class="divider"></div>
        <div class="row">
          <span class="row-title">主库 → 今日</span>
          <span class="row-value" :aria-label="'gapBackfill.coverage|' + (snap?.gap.coverageText ?? '')">{{ snap?.gap.coverageText ?? '—' }}</span>
        </div>
        <div class="divider"></div>
        <div class="row">
          <span class="row-title">主库基线</span>
          <span class="row-value" :class="{ 'tone-orange': snap?.gap.baselineStale }">{{ snap?.gap.baselineText ?? '—' }}</span>
        </div>
        <div class="divider"></div>
        <div class="row">
          <span class="row-title">补齐结果</span>
          <span class="row-value" :aria-label="'gapBackfill.fetch|' + (snap?.gap.fetchText ?? '')">{{ snap?.gap.fetchText ?? '—' }}</span>
        </div>
        <div class="divider"></div>
        <div class="row">
          <span class="row-title">结论</span>
          <span class="row-value" :class="gapToneClass" :aria-label="'gapBackfill.verdict|' + (snap?.gap.verdictText ?? '')">
            {{ snap?.gap.verdictText ?? '—' }}
          </span>
        </div>
        <div class="divider"></div>
        <button class="row" :disabled="!!snap?.gap.isRunning" aria-label="gapBackfill.run" @click="act('runGapBackfill')">
          <span class="row-title" :class="{ dim: !!snap?.gap.isRunning }">补一次缺口</span>
          <span class="st-icon" :class="snap?.gap.isRunning ? 'state-yellow' : 'state-blue'">
            {{ snap?.gap.isRunning ? '◌' : '⤓' }}
          </span>
        </button>
        <div class="divider"></div>
        <button class="row" :disabled="!!snap?.gap.baselineLoading" aria-label="gapBackfill.baselineMissing" @click="act('queryBaselineMissing')">
          <span class="row-title">基准缺失名单</span>
          <span class="st-icon" :class="snap?.gap.baselineLoading ? 'state-yellow' : 'state-blue'">
            {{ snap?.gap.baselineLoading ? '◌' : '≡' }}
          </span>
        </button>
        <template v-for="(line, i) in snap?.gap.detailLines ?? []" :key="i">
          <div class="divider"></div>
          <div class="detail-line" :aria-label="`gapBackfill.detail.${i}|${line}`">{{ line }}</div>
        </template>
      </div>
      <div style="height: 16px"></div>
    </div>

    <!-- 基准缺失名单弹层（对齐原生 BaselineMissingSheet） -->
    <van-popup v-model:show="baselineOpen" position="bottom" round class="bl-popup">
      <div class="bl-head">
        <span class="bl-title">基准缺失名单</span>
        <button class="bl-done" @click="baselineOpen = false">完成</button>
      </div>
      <div class="bl-summary">{{ baselineSummary }}</div>
      <div class="bl-list">
        <div v-for="(it, i) in snap?.baseline?.items ?? []" :key="i" class="bl-item">
          <div class="bl-line1">
            <span class="bl-name">{{ it.name }}</span>
            <span class="bl-code">{{ it.code }}</span>
            <span class="bl-cause">{{ it.cause }}</span>
          </div>
          <div class="bl-file">{{ it.file }}</div>
        </div>
        <div v-if="(snap?.baseline?.items.length ?? 0) === 0" class="bl-empty">（无记录）</div>
      </div>
    </van-popup>

    <van-dialog v-model:show="alertOpen" title="基准缺失名单" :message="alertMsg" confirm-button-text="好" />
  </div>
</template>

<script setup lang="ts">
// 本地更新 Web 面板（P2-6c-1，对齐原生 LocalUpdateView 四卡片组）：
// 远程更新状态机/下载进度/清单自动更新/补缺口全部原生，Web 经 update.snapshot 消费。
// 值行锚点用复合 aria-label（gapBackfill.<key>|<值>），GapBackfillUITests 前缀匹配读值。
import { computed, onMounted, ref } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { UpdateRowSnap, UpdateSnapshot } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const snap = ref<UpdateSnapshot | null>(null)
const baselineOpen = ref(false)
const alertOpen = ref(false)
const alertMsg = ref('')

const baselineSummary = computed(() => {
  const b = snap.value?.baseline
  if (!b) return ''
  const latest = b.mainLatest === 0 ? '-' : String(b.mainLatest)
  return `共 ${b.items.length} 只 · 主库最新 ${latest} · 缺自校准锚点，补缺口本轮跳过`
})

async function pull(): Promise<void> {
  try {
    snap.value = (await klineBus.request('update', 'snapshot')) as unknown as UpdateSnapshot
  } catch (e) {
    console.error('update.snapshot 失败', e)
  }
}

function act(action: string, payload?: Record<string, unknown>): void {
  void klineBus.request('update', action, payload).catch((e) => console.error(`update.${action} 失败`, e))
}

onMounted(async () => {
  await klineBus.detect()
  klineBus.on('update.changed', (ev) => {
    const p = ev.payload ?? {}
    const reason = String(p['reason'] ?? '')
    if (reason === 'baselineReady') baselineOpen.value = true
    if (reason === 'baselineFailed') {
      alertMsg.value = String(p['message'] ?? '')
      alertOpen.value = true
    }
    void pull()
  })
  await pull()
})

// ===== 行点击语义（对齐原生 onRemoteRowTap / onEngineRowTap） =====

function tapServerRow(): void {
  // 仅离线且非探测中可点 = 重连（onAppear 自动探测；回前台由原生通知驱动）
  if (!snap.value?.server.ok && !snap.value?.server.probing) act('reconnectServer')
}

function tapAppRow(): void {
  const st = snap.value?.app.state
  if (st === 'outdated') act('installApp')
  else if (st === 'idle' || st === 'latest' || st === 'failed') act('checkApp')
}

function tapEngineRow(): void {
  const st = snap.value?.engine.state
  if (st === 'outdated') act('installEngine')
  else if (st === 'idle' || st === 'latest' || st === 'failed') act('checkEngine')
}

// ===== 状态图标语义（对齐原生 serverIcon / remoteStateIcon / watchlistStateIcon） =====

function stateGlyph(state?: UpdateRowSnap['state']): string {
  switch (state) {
    case 'idle': return '='
    case 'checking': return '…'
    case 'latest': return '✓'
    case 'outdated':
    case 'failed': return '✕'
    default: return '='
  }
}

function stateClass(state?: UpdateRowSnap['state']): string {
  switch (state) {
    case 'checking':
    case 'downloading': return 'state-yellow'
    case 'latest': return 'state-green'
    case 'outdated':
    case 'failed': return 'state-red'
    default: return 'state-gray'
  }
}

const serverClass = computed(() => {
  if (snap.value?.server.probing) return 'state-yellow'
  return snap.value?.server.ok ? 'state-green' : 'state-red'
})

const serverGlyph = computed(() => {
  if (snap.value?.server.probing) return '='
  return snap.value?.server.ok ? '✓' : '✕'
})

const watchClass = computed(() => {
  const w = snap.value?.watchlist
  if (!w) return 'state-gray'
  if (!w.enabled) return 'state-gray'
  if (w.isRunning) return 'state-yellow'
  return w.stateTone === 'green' ? 'state-green' : w.stateTone === 'red' ? 'state-red' : 'state-gray'
})

const watchGlyph = computed(() => {
  const w = snap.value?.watchlist
  if (!w) return '='
  if (!w.enabled) return '='
  if (w.isRunning) return '…'
  return w.stateTone === 'green' ? '✓' : w.stateTone === 'red' ? '✕' : '='
})

const resultClass = computed(() => {
  const text = snap.value?.watchlist.lastResultText ?? ''
  if (text.startsWith('失败')) return 'tone-red'
  if (text.startsWith('成功')) return 'tone-green'
  return ''
})

const gapToneClass = computed(() => {
  const s = snap.value?.gap.statusText ?? ''
  const v = snap.value?.gap.verdictText ?? ''
  if (s === 'running' || snap.value?.gap.isRunning) return 'tone-yellow'
  if (v.startsWith('失败')) return 'tone-red'
  if (v.startsWith('完成') || v.includes('缺口已补') || v.includes('无缺口')) return 'tone-green'
  return ''
})
</script>

<style scoped>
.lup {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
}

.nav-bar {
  display: flex;
  align-items: center;
  height: 56px;
  flex-shrink: 0;
  background: var(--k-bg);
}

.nav-back {
  width: 44px;
  height: 44px;
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 24px;
  cursor: pointer;
  margin-left: 8px;
}

.nav-title {
  font-size: 20px;
  font-weight: 700;
  color: var(--k-text);
}

.lup-body {
  flex: 1;
  overflow-y: auto;
  padding: 12px;
  border-top: 0.5px solid var(--k-divider, #c6c6c8);
}

.sec-label {
  font-size: 13px;
  font-weight: 600;
  color: var(--k-text-secondary);
  padding: 10px 2px 6px;
}

.card {
  background: var(--k-bg-secondary);
  border-radius: 12px;
  overflow: hidden;
  margin-bottom: 6px;
}

.divider {
  height: 0.5px;
  background: var(--k-divider, #c6c6c8);
  margin-left: 16px;
}

.row {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  min-height: 48px;
  padding: 0 16px;
  border: none;
  background: none;
  cursor: pointer;
  text-align: left;
  color: var(--k-text);
}

.row:disabled { cursor: default; }

.row-title {
  font-size: 16px;
  color: var(--k-text);
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.row-title.dim { color: var(--k-text-tertiary); }

.row-value {
  font-size: 15px;
  color: var(--k-text-secondary);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 60%;
  text-align: right;
}

/* 状态图标（图标位固定 24x24，布局不随状态变形） */
.st-icon {
  width: 24px;
  height: 24px;
  border-radius: 50%;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 13px;
  font-weight: 600;
  flex-shrink: 0;
}

.state-gray { background: rgba(128, 128, 128, 0.25); color: #8e8e93; }
.state-yellow { background: rgba(255, 204, 0, 0.25); color: #cc9900; }
.state-green { background: rgba(52, 199, 89, 0.2); color: var(--k-ok); }
.state-red { background: rgba(255, 59, 48, 0.2); color: #ff3b30; }
.state-blue { background: rgba(0, 122, 255, 0.15); color: var(--k-accent); font-size: 16px; }

.tone-gray { color: var(--k-text-secondary); }
.tone-yellow { color: #cc9900; }
.tone-green { color: var(--k-ok); }
.tone-red { color: #ff3b30; }
.tone-orange { color: #ff9500; }

.note-block {
  font-size: 12px;
  color: var(--k-text-secondary);
  padding: 10px 16px;
  line-height: 1.5;
}

.detail-line {
  font-size: 12px;
  color: var(--k-text-secondary);
  padding: 8px 16px;
  line-height: 1.5;
  word-break: break-all;
}

/* 基准缺失名单弹层 */
.bl-popup {
  max-height: 70vh;
  display: flex;
  flex-direction: column;
}

.bl-head {
  display: flex;
  align-items: center;
  padding: 14px 16px;
}

.bl-title {
  flex: 1;
  font-size: 16px;
  font-weight: 600;
  color: var(--k-text);
}

.bl-done {
  border: none;
  background: none;
  color: var(--k-accent);
  font-size: 15px;
  font-weight: 600;
  cursor: pointer;
}

.bl-summary {
  font-size: 12px;
  color: var(--k-text-secondary);
  padding: 0 16px 10px;
}

.bl-list {
  flex: 1;
  overflow-y: auto;
  padding: 0 16px 16px;
}

.bl-item {
  padding: 8px 0;
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
}

.bl-line1 {
  display: flex;
  align-items: baseline;
  gap: 8px;
}

.bl-name {
  font-size: 15px;
  font-weight: 500;
  color: var(--k-text);
}

.bl-code {
  font-size: 12px;
  color: var(--k-text-secondary);
}

.bl-cause {
  font-size: 12px;
  color: var(--k-text-secondary);
  margin-left: auto;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.bl-file {
  font-size: 11px;
  color: var(--k-text-tertiary);
  margin-top: 2px;
  word-break: break-all;
}

.bl-empty {
  font-size: 13px;
  color: var(--k-text-tertiary);
  padding: 16px 0;
}
</style>

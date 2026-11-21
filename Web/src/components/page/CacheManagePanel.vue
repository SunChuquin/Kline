<template>
  <div class="cmp">
    <!-- 页头：返回 ｜ 缓存管理 ｜ -->
    <div class="nav-line">
      <button class="nav-link" aria-label="cacheManage.back" @click="emit('close')">‹ 返回</button>
      <span class="nav-center">缓存管理</span>
      <span style="width: 60px"></span>
    </div>

    <template v-if="stats">
      <div class="body">
        <!-- 六组合占用列表（多选清除） -->
        <div class="sec-title">指标缓存占用</div>
        <div class="combo-list">
          <button
            v-for="c in stats.combos"
            :key="c.comboKey"
            class="combo-row"
            :class="{ checked: selected.has(c.comboKey) }"
            :aria-label="`cacheManage.combo.${c.label}`"
            @click="toggle(c.comboKey)"
          >
            <span class="check">{{ selected.has(c.comboKey) ? '●' : '○' }}</span>
            <span class="combo-name">
              {{ c.label }}
              <span v-if="c.staleCount > 0" class="stale-badge">过期 {{ c.staleCount }}</span>
            </span>
            <span class="combo-stat">{{ c.count }} 项 · {{ fmtBytes(c.bytes) }}</span>
          </button>
        </div>

        <div class="action-row">
          <button class="act-btn danger" :disabled="selected.size === 0" @click="clearSelected">
            清除选中（{{ selected.size }}）
          </button>
          <button class="act-btn" :disabled="selected.size === 0" @click="clearStaleHint">刷新过期</button>
        </div>
        <div class="note">提示：点行勾选；「刷新过期」按选中组合重新生成（覆盖过期数据）。生成可选 6 个组合：局部独立配置 + 组合1~5。</div>

        <!-- 生成表单 -->
        <div class="sec-title" style="margin-top: 18px">生成指标缓存</div>
        <div class="form">
          <div class="form-row">
            <span class="form-cap">组合</span>
            <div class="chip-wrap">
              <button
                v-for="p in genCombos"
                :key="p.id"
                class="chip"
                :class="{ on: genSelected.has(p.id) }"
                @click="toggleGen(p.id)"
              >{{ p.name }}</button>
            </div>
          </div>
          <div class="form-row">
            <span class="form-cap">模式</span>
            <div class="chip-wrap">
              <button class="chip" :class="{ on: genMode === 'warm' }" @click="genMode = 'warm'">预热（最新 N 根近似）</button>
              <button class="chip" :class="{ on: genMode === 'full' }" @click="genMode = 'full'">全量（完整计算）</button>
            </div>
          </div>
          <div class="form-row" v-if="genMode === 'warm'">
            <span class="form-cap">根数</span>
            <input v-model.number="warmupNInput" type="number" class="n-input" min="20" max="1000" />
            <span class="form-cap">根（{{ stats.bufferNote }}）</span>
          </div>
          <div class="form-row">
            <span class="form-cap">周期</span>
            <div class="chip-wrap">
              <button class="chip on">日线</button>
              <span class="form-cap">（其他周期将随版本迭代开放）</span>
            </div>
          </div>
        </div>
        <div class="action-row">
          <button
            class="act-btn primary"
            aria-label="cacheManage.generate"
            :disabled="genSelected.size === 0 || running"
            @click="generate"
          >{{ running ? '生成中…' : '开始生成' }}</button>
          <button class="act-btn danger" :disabled="!running" @click="cancelGenerate">取消</button>
        </div>
        <div class="note">全市场 3354 只标的批量计算：预热模式约 6~17 分钟/组合，全量模式约 28~56 分钟/组合（后台低优先级分批跑，可中途取消）。</div>

        <!-- 进度 -->
        <div v-if="progress.state === 'running'" class="progress-card">
          <div class="progress-text">{{ progress.comboLabel }} · {{ progress.done }}/{{ progress.total }}</div>
          <div class="progress-track">
            <div class="progress-fill" :style="{ width: progressPct + '%' }"></div>
          </div>
        </div>
        <div style="height: 24px"></div>
      </div>
    </template>

    <div v-else class="loading">加载中…</div>
  </div>
</template>

<script setup lang="ts">
// P2 指标组合期4：缓存管理页（page 域 cacheManage）。六组合占用统计（多选清除）+
// 生成表单（组合多选 × 全量/预热 N 根 × 日线）→ 生成引擎后台批量，进度随
// cacheManage.changed(progress) 推送（订阅转发自 ChartPresetWarmunRunner）。
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { CacheComboStats, CacheProgressPayload, CacheStatsSnapshot } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const stats = ref<CacheStatsSnapshot | null>(null)
const selected = ref<Set<string>>(new Set())
const genSelected = ref<Set<string>>(new Set())
const genMode = ref<'warm' | 'full'>('warm')
const warmupNInput = ref(80)
const progress = ref<{ state: string; done?: number; total?: number; comboLabel?: string }>({ state: 'idle' })

const running = computed(() => progress.value.state === 'running')
const progressPct = computed(() => {
  const p = progress.value
  if (!p.total) return 0
  return Math.min(Math.max(((p.done ?? 0) / p.total) * 100, 0), 100)
})

/** 生成可选组合：local（局部独立配置）+ p1..p5 共 6 项（stats.combos 字段为
 *  comboKey/label，映射为 chip 用的 id/name） */
const genCombos = computed(() =>
  (stats.value?.combos ?? []).map((c) => ({ id: c.comboKey, name: c.label })),
)

function fmtBytes(b: number): string {
  if (b >= 1024 * 1024) return `${(b / 1024 / 1024).toFixed(1)} MB`
  if (b >= 1024) return `${(b / 1024).toFixed(1)} KB`
  return `${b} B`
}

function toggle(key: string): void {
  const next = new Set(selected.value)
  if (next.has(key)) next.delete(key)
  else next.add(key)
  selected.value = next
}

function toggleGen(id: string): void {
  const next = new Set(genSelected.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  genSelected.value = next
}

let warmupNInitialized = false

/** 拉取统计并把生成运行态快照同步到进度 UI（事件推送的兜底：即使 changed 事件
 *  丢失——route 定向推送在 WebView 未就绪时静默丢弃——页面也能 2s 轮询追上真实进度） */
async function pullStats(): Promise<void> {
  try {
    stats.value = ((await klineBus.request('cacheManage', 'stats')) ?? {}) as CacheStatsSnapshot
    if (!warmupNInitialized) {
      warmupNInput.value = stats.value.warmupN
      warmupNInitialized = true
    }
    const r = stats.value.running
    if (r.state === 'running') {
      progress.value = { state: 'running', done: r.done ?? 0, total: r.total ?? 0,
                         comboLabel: r.comboLabel ?? '' }
    } else if (r.state === 'finished' || r.state === 'cancelled') {
      progress.value = { state: r.state }
    } else if (progress.value.state === 'running') {
      // 快照已 idle 而本地还在 running（错过终态事件）→ 归位
      progress.value = { state: 'idle' }
    }
  } catch (e) {
    console.error('cacheManage.stats 失败', e)
  }
}

async function clearSelected(): Promise<void> {
  try {
    await klineBus.request('cacheManage', 'clear', { ids: [...selected.value] })
    selected.value = new Set()
    await pullStats()
  } catch (e) {
    console.error('cacheManage.clear 失败', e)
  }
}

/** 刷新过期：只重新生成选中组合下「过期行」的标的（预热覆盖，口径与徽标一致） */
function clearStaleHint(): void {
  if (selected.value.size === 0) return
  void klineBus.request('cacheManage', 'generate', {
    combos: [...selected.value],
    mode: 'warm',
    periods: ['日线'],
    warmupN: warmupNInput.value,
    onlyStale: true,
  }).catch((e) => console.error('cacheManage.generate(onlyStale) 失败', e))
}

function generate(): void {
  if (genSelected.value.size === 0) return
  // 本地立即反馈：不等 changed 推送（事件链路偶发丢失时按钮应有可见变化）
  progress.value = { state: 'running', done: 0, total: 0, comboLabel: '启动中…' }
  void klineBus.request('cacheManage', 'generate', {
    combos: [...genSelected.value],
    mode: genMode.value,
    periods: ['日线'],
    warmupN: warmupNInput.value,
  }).catch((e) => {
    console.error('cacheManage.generate 失败', e)
    progress.value = { state: 'idle' }
  })
}

function cancelGenerate(): void {
  void klineBus.request('cacheManage', 'cancelGenerate', {}).catch((e) => console.error(e))
}

function handleChanged(payload: Record<string, unknown> | undefined): void {
  const reason = String(payload?.['reason'] ?? '')
  if (reason === 'progress') {
    progress.value = { state: String(payload?.['state'] ?? 'running'),
                       done: Number(payload?.['done'] ?? 0),
                       total: Number(payload?.['total'] ?? 0),
                       comboLabel: String(payload?.['comboLabel'] ?? '') }
  } else if (reason === 'done' || reason === 'cancelled') {
    progress.value = { state: reason === 'done' ? 'finished' : 'cancelled' }
    void pullStats()
  } else if (reason === 'cleared') {
    void pullStats()
  }
}

let pollTimer: number | undefined

onMounted(async () => {
  klineBus.on('cacheManage.changed', (ev) => handleChanged(ev.payload))
  await pullStats()
  // 2s 轮询兜底：生成是分钟级后台任务，stats 查询 <5ms，开销可忽略
  pollTimer = window.setInterval(() => { void pullStats() }, 2000)
})

onUnmounted(() => {
  if (pollTimer !== undefined) window.clearInterval(pollTimer)
  // 页面关闭不自动取消生成（后台继续跑；重新进入即由快照恢复进度）
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

.nav-center {
  flex: 1;
  text-align: center;
  font-size: 16px;
  font-weight: 600;
  color: var(--k-text);
}

.cmp {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  color: var(--k-text);
}

.body {
  flex: 1;
  overflow-y: auto;
  padding: 14px 16px;
}

.sec-title {
  font-size: 13px;
  font-weight: 600;
  margin-bottom: 8px;
}

.combo-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.combo-row {
  display: flex;
  align-items: center;
  gap: 10px;
  border: none;
  background: var(--k-bg-secondary);
  border-radius: 10px;
  height: 48px;
  padding: 0 12px;
  cursor: pointer;
  text-align: left;
  width: 100%;
}

.combo-row.checked {
  box-shadow: inset 0 0 0 1.5px #1989fa;
}

.check {
  color: var(--k-text-tertiary);
  flex-shrink: 0;
}

.combo-row.checked .check {
  color: #1989fa;
}

.combo-name {
  flex: 1;
  font-size: 14px;
  font-weight: 500;
}

.stale-badge {
  font-size: 11px;
  color: #ff9500;
  margin-left: 6px;
}

.combo-stat {
  font-size: 12px;
  color: var(--k-text-tertiary);
  flex-shrink: 0;
}

.action-row {
  display: flex;
  gap: 10px;
  margin-top: 12px;
}

.act-btn {
  flex: 1;
  border: none;
  border-radius: 10px;
  height: 44px;
  font-size: 14px;
  font-weight: 500;
  cursor: pointer;
  background: rgba(25, 137, 250, 0.12);
  color: #1989fa;
}

.act-btn.primary {
  background: #1989fa;
  color: #ffffff;
  font-weight: 600;
}

.act-btn.danger {
  background: rgba(238, 10, 36, 0.08);
  color: #ee0a24;
}

.act-btn:disabled {
  opacity: 0.45;
  cursor: default;
}

.note {
  font-size: 11px;
  color: var(--k-text-tertiary);
  margin-top: 8px;
  line-height: 1.5;
}

.form-row {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 10px;
}

.form-cap {
  font-size: 13px;
  color: var(--k-text-tertiary);
  flex-shrink: 0;
}

.chip-wrap {
  display: flex;
  flex-wrap: wrap;
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

.n-input {
  width: 90px;
  height: 34px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 14px;
  padding: 0 10px;
  outline: none;
  box-sizing: border-box;
}

.progress-card {
  margin-top: 14px;
  padding: 12px;
  border-radius: 10px;
  background: var(--k-bg-secondary);
}

.progress-text {
  font-size: 12.5px;
  font-weight: 600;
}

.progress-track {
  height: 4px;
  border-radius: 2px;
  background: rgba(128, 128, 128, 0.2);
  margin-top: 8px;
  overflow: hidden;
}

.progress-fill {
  height: 100%;
  background: #1989fa;
  transition: width 0.3s ease;
}

.loading {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  color: var(--k-text-tertiary);
}
</style>

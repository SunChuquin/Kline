<template>
  <div>
    <!-- ③ running：配对 / 进度 / 完成 / 失败（phase 由原生传输引擎发布） -->
    <div v-if="!mv || mv.phase === 'idle'" class="phase-center">
      <div class="spinner">◌</div>
      <div class="phase-sub">正在准备…</div>
    </div>

    <div v-else-if="mv.phase === 'pairing'" class="phase-center">
      <div class="spinner">◌</div>
      <div class="phase-title">正在建立同步会话…</div>
      <div class="phase-sub">{{ mv.directionText }}</div>
    </div>

    <div v-else-if="mv.phase === 'transferring'" class="card progress-card">
      <div class="phase-title">{{ mv.directionText }}</div>
      <div class="progress-track">
        <div class="progress-fill" :style="{ width: progressPct + '%' }"></div>
      </div>
      <div class="progress-line">
        <span class="progress-pct">{{ progressPct }}%</span>
        <span class="progress-speed">{{ fmtSpeed(mv.bytesPerSecond) }}</span>
      </div>
      <div class="progress-file">当前文件：{{ mv.currentFile || '—' }}</div>
      <div class="progress-stage">当前阶段：{{ mv.currentStage || '—' }}</div>
    </div>

    <div v-else-if="mv.phase === 'done'" class="card done-card">
      <div class="result-head ok">✓ 同步完成</div>
      <div class="result-summary" :aria-label="'lansync.result.summary|' + mv.resultSummary">
        {{ mv.resultSummary }}
      </div>
      <div v-if="mv.backupDir" class="result-sub">已备份本机原文件到 Documents/{{ mv.backupDir }}</div>
      <div v-if="mv.needsRestart" class="result-warn">⚠ 主库已替换，请重启 App 生效</div>
      <button class="primary-btn" aria-label="lansync.done.button" @click="emit('done')">完成</button>
    </div>

    <div v-else class="card fail-card">
      <div class="result-head bad">✕ 同步失败</div>
      <div class="result-summary" :aria-label="'lansync.fail.message|' + (mv.failMessage ?? '')">
        {{ mv.failMessage ?? '' }}
      </div>
      <div class="result-sub">{{ mv.directionText }}</div>
      <button class="primary-btn" @click="emit('retry')">重试</button>
    </div>
  </div>
</template>

<script setup lang="ts">
// k-lan-running：联机同步 running 子页（phase 视图：idle/pairing/transferring/done/failed）。
// 哑组件：传输 phase/progress 由 lan.changed 推送 → adapter 回填 modelValue；
// done/retry 抛给 adapter 切子页。
import { computed } from 'vue'

export interface LanTransferState {
  phase: 'idle' | 'pairing' | 'transferring' | 'done' | 'failed'
  progress: number
  bytesPerSecond: number
  currentFile: string
  currentStage: string
  directionText: string
  resultSummary: string
  backupDir: string | null
  needsRestart: boolean
  failMessage: string | null
}

const props = withDefaults(defineProps<{
  modelValue?: LanTransferState
}>(), {
  modelValue: () => ({
    phase: 'idle',
    progress: 0,
    bytesPerSecond: 0,
    currentFile: '',
    currentStage: '',
    directionText: '',
    resultSummary: '',
    backupDir: null,
    needsRestart: false,
    failMessage: null,
  }),
})

const emit = defineEmits<{
  (e: 'done'): void
  (e: 'retry'): void
}>()

const mv = computed(() => props.modelValue)

const progressPct = computed(() => Math.round((props.modelValue.progress ?? 0) * 100))

function fmtSpeed(bps: number): string {
  return `${(bps / 1_048_576).toFixed(1)} MB/s`
}
</script>

<style scoped>
.card {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 12px;
  margin-bottom: 10px;
}

.phase-center {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  min-height: 160px;
  gap: 12px;
}

.spinner {
  font-size: 22px;
  color: var(--k-accent, #007aff);
  animation: lan-spin 1s linear infinite;
}

@keyframes lan-spin {
  to { transform: rotate(360deg); }
}

.phase-title {
  font-size: 17px;
  font-weight: 600;
  color: var(--k-text, #000);
}

.phase-sub {
  font-size: 13px;
  color: var(--k-text-secondary, #6c6c70);
}

.progress-card {
  padding: 16px;
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.progress-track {
  height: 6px;
  border-radius: 3px;
  background: rgba(128, 128, 128, 0.2);
  overflow: hidden;
}

.progress-fill {
  height: 100%;
  background: #1989fa;
  transition: width 0.3s ease;
}

.progress-line {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
}

.progress-pct {
  font-size: 30px;
  font-weight: 700;
  color: var(--k-text, #000);
}

.progress-speed {
  font-size: 14px;
  color: var(--k-text-secondary, #6c6c70);
}

.progress-file {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.progress-stage {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
  margin-top: 2px;
}

.done-card,
.fail-card {
  padding: 16px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.done-card { background: rgba(52, 199, 89, 0.12); }
.fail-card { background: rgba(255, 59, 48, 0.12); }

.result-head {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 17px;
  font-weight: 600;
  color: var(--k-text, #000);
}

.result-head.ok { color: var(--k-ok, #34c759); }
.result-head.bad { color: #ff3b30; }

.result-summary {
  font-size: 14px;
  color: var(--k-text, #000);
  word-break: break-all;
}

.result-sub {
  font-size: 13px;
  color: var(--k-text-secondary, #6c6c70);
}

.result-warn {
  font-size: 13px;
  color: var(--k-text, #000);
}
</style>

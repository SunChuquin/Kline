<template>
  <div class="progress-card">
    <template v-if="p.state === 'idle'">
      <div class="progress-line">
        <span class="progress-text">点击开始跑选股</span>
        <button class="inline-btn" @click="emit('start')">开始跑选股</button>
      </div>
    </template>
    <template v-else-if="p.state === 'preparing' || p.state === 'running'">
      <div class="progress-text">
        {{ p.state === 'preparing' ? `准备行情数据 ${p.done ?? 0}/${p.total ?? 0}` : `已扫描 ${p.done ?? 0}/${p.total ?? 0}` }}
      </div>
      <div class="progress-track"><div class="progress-fill" :style="{ width: ratio * 100 + '%' }"></div></div>
      <div class="progress-line" style="justify-content: flex-end">
        <button class="inline-btn" @click="emit('cancel')">取消</button>
      </div>
    </template>
    <template v-else-if="p.state === 'finished'">
      <div class="progress-line">
        <span class="progress-text strong">命中 {{ p.hitCount ?? 0 }} 只</span>
        <button class="inline-btn" @click="emit('start')">重新跑选股</button>
      </div>
    </template>
    <template v-else>
      <div class="progress-line">
        <span class="progress-text warn">已取消</span>
        <button class="inline-btn" @click="emit('start')">重新跑选股</button>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
// k-pick-progress：跑选股进度卡（idle 开始 / preparing+running 进度+取消 /
// finished 命中数+重跑 / cancelled 已取消+重跑，对齐原生 StrategyPickListView）。
import { computed } from 'vue'

export interface PickPhaseState {
  state: 'idle' | 'preparing' | 'running' | 'finished' | 'cancelled'
  done?: number
  total?: number
  hitCount?: number
}

const props = withDefaults(defineProps<{
  modelValue?: PickPhaseState
}>(), {
  modelValue: () => ({ state: 'idle' }),
})

const emit = defineEmits<{
  (e: 'start'): void
  (e: 'cancel'): void
}>()

const p = computed(() => props.modelValue)

const ratio = computed(() => {
  const v = p.value
  if (!v.total) return 0
  return Math.min(Math.max((v.done ?? 0) / v.total, 0), 1)
})
</script>

<style scoped>
.progress-card {
  margin: 0 0 8px;
  padding: 12px;
  border-radius: 10px;
  background: var(--k-bg-secondary, #f2f2f7);
}

.progress-line {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.progress-text {
  font-size: 12px;
  color: var(--k-text-tertiary, #c7c7cb);
}

.progress-text.strong {
  font-size: 12.5px;
  font-weight: 600;
  color: var(--k-text, #000);
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
</style>

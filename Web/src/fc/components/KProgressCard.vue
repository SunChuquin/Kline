<template>
  <div v-if="modelValue.state === 'running'" class="progress-card">
    <div class="progress-text">{{ modelValue.comboLabel }} · {{ modelValue.done }}/{{ modelValue.total }}</div>
    <div class="progress-track">
      <div class="progress-fill" :style="{ width: pct + '%' }"></div>
    </div>
  </div>
</template>

<script setup lang="ts">
// k-progress-card：后台任务进度卡（缓存生成/选股跑批），state!=running 时隐藏。
import { computed } from 'vue'

const props = withDefaults(defineProps<{
  modelValue?: { state?: string; done?: number; total?: number; comboLabel?: string }
}>(), {
  modelValue: () => ({ state: 'idle', done: 0, total: 0, comboLabel: '' }),
})

const pct = computed(() => {
  const p = props.modelValue
  if (!p.total) return 0
  return Math.min(Math.max(((p.done ?? 0) / p.total) * 100, 0), 100)
})
</script>

<style scoped>
.progress-card {
  margin-top: 14px;
  padding: 12px;
  border-radius: 10px;
  background: var(--k-bg-secondary, #f2f2f7);
}

.progress-text {
  font-size: 12.5px;
  font-weight: 600;
  color: var(--k-text, #000);
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
</style>

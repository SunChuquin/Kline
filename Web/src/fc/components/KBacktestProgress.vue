<template>
  <div class="bp-progress">
    <template v-if="p.state === 'preparing'">
      <div class="progress-title">准备行情数据 {{ p.done ?? 0 }}/{{ p.total ?? 0 }}</div>
      <div class="progress-track"><div class="progress-fill" :style="{ width: pct + '%' }"></div></div>
    </template>
    <template v-else-if="p.state === 'simulating'">
      <div class="progress-title">正在逐日回测…</div>
      <div class="progress-track"><div class="progress-fill" style="width: 0%"></div></div>
    </template>
    <template v-else>
      <div class="progress-title">…</div>
    </template>
  </div>
</template>

<script setup lang="ts">
// k-backtest-progress：回测进度卡（准备行情 / 逐日回测 / 失败占位；track 自绘
// 等价 van-progress stroke-width 4，对齐原生 backtestProgressPage）。
import { computed } from 'vue'

const props = withDefaults(defineProps<{
  modelValue?: { state?: 'idle' | 'preparing' | 'simulating' | 'failed'; done?: number; total?: number }
}>(), {
  modelValue: () => ({ state: 'idle', done: 0, total: 0 }),
})

const p = computed(() => props.modelValue)

const pct = computed(() => {
  const v = p.value
  if (!v.total) return 0
  return Math.min(100, Math.round(((v.done ?? 0) / v.total) * 100))
})
</script>

<style scoped>
.bp-progress {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 12px;
  padding: 12px;
  margin: 8px 0 12px;
}

.progress-title {
  font-size: 12.5px;
  font-weight: 500;
  color: var(--k-text-secondary, #6c6c70);
  margin-bottom: 10px;
}

.progress-track {
  height: 4px;
  border-radius: 2px;
  background: rgba(128, 128, 128, 0.2);
  overflow: hidden;
}

.progress-fill {
  height: 100%;
  background: #1989fa;
  transition: width 0.3s ease;
}
</style>

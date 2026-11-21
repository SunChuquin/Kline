<template>
  <div class="metric-card">
    <div v-if="modelValue.firstline" class="stats-firstline">{{ modelValue.firstline }}</div>
    <div class="stats-grid">
      <div v-for="(c, i) in modelValue.cells" :key="i" class="metric-cell">
        <div class="metric-title">{{ c.title }}</div>
        <div class="metric-value" :class="c.tone ?? ''">{{ c.value }}</div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
// k-metric-grid：回测指标卡（首行摘要 + 两列指标网格，tone 红涨绿跌）。
export interface MetricCell {
  title: string
  value: string
  tone?: 'up' | 'down' | ''
}

withDefaults(defineProps<{
  modelValue?: { firstline?: string; cells?: MetricCell[] }
}>(), {
  modelValue: () => ({ cells: [] }),
})
</script>

<style scoped>
.metric-card {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 12px;
  padding: 12px;
  margin-bottom: 12px;
}

.stats-firstline {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
  margin-bottom: 10px;
  line-height: 1.5;
}

.stats-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 10px;
}

.metric-cell {
  background: var(--k-bg, #ffffff);
  border-radius: 8px;
  padding: 10px;
}

.metric-title {
  font-size: 11px;
  color: var(--k-text-secondary, #6c6c70);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.metric-value {
  font-size: 16px;
  font-weight: 700;
  color: var(--k-text, #000);
  margin-top: 4px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.metric-value.up { color: #ff3b30; }
.metric-value.down { color: var(--k-ok, #00b578); }
</style>

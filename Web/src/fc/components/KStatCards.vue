<template>
  <div class="stat-cards">
    <div v-for="(c, i) in modelValue.cards" :key="i" class="stat-card">
      <div class="stat-label">{{ c.label }}</div>
      <div class="stat-value" :class="c.tone">{{ c.value }}</div>
    </div>
  </div>
</template>

<script setup lang="ts">
// k-stat-cards：概览统计卡组（label + value + 可选着色 tone）。
export interface StatCard {
  label: string
  value: string
  tone?: 'up' | 'down' | 'plain'
}

withDefaults(defineProps<{
  modelValue?: { cards?: StatCard[] }
}>(), {
  modelValue: () => ({ cards: [] }),
})
</script>

<style scoped>
.stat-cards {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.stat-card {
  flex: 1 1 calc(33.33% - 8px);
  min-width: 96px;
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 10px;
  padding: 10px 12px;
}

.stat-label {
  font-size: 11px;
  color: var(--k-text-secondary, #6c6c70);
}

.stat-value {
  font-size: 16px;
  font-weight: 600;
  margin-top: 4px;
  font-variant-numeric: tabular-nums;
  color: var(--k-text, #000);
}

.stat-value.up { color: #ff4d4f; }
.stat-value.down { color: #00b578; }
</style>

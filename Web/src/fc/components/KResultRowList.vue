<template>
  <div class="result-rows">
    <div v-for="r in modelValue.rows" :key="r.file" class="result-row" @click="emit('pick', r)">
      <span class="sr-name">{{ r.name }}</span>
      <span class="sr-code">{{ r.code }}</span>
      <span v-if="r.mark" class="sr-mark" :class="r.markTone ?? 'plain'">{{ r.mark }}</span>
      <span v-else-if="r.checked" class="sr-check">✓</span>
    </div>
    <div v-if="modelValue.rows.length === 0 && modelValue.emptyText" class="search-empty">{{ modelValue.emptyText }}</div>
  </div>
</template>

<script setup lang="ts">
// k-result-row-list：搜索/抽取结果行列表（名称 + 代码 + 可选标记/勾选）。
export interface ResultRow {
  file: string
  name: string
  code: string
  mark?: string
  markTone?: 'warn' | 'plain'
  checked?: boolean
}

withDefaults(defineProps<{
  modelValue?: { rows?: ResultRow[]; emptyText?: string }
}>(), {
  modelValue: () => ({ rows: [] }),
})

const emit = defineEmits<{
  (e: 'pick', row: ResultRow): void
}>()
</script>

<style scoped>
.result-rows {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 10px;
  overflow: hidden;
}

.result-row {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 9px 10px;
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
  cursor: pointer;
}

.result-row:last-child { border-bottom: none; }

.sr-name { font-size: 14px; color: var(--k-text, #000); }
.sr-code { font-size: 12px; color: var(--k-text-secondary, #6c6c70); }

.sr-mark {
  margin-left: auto;
  font-size: 11px;
}

.sr-mark.warn { color: #ff9500; }
.sr-mark.plain { color: var(--k-text-tertiary, #c7c7cb); }

.sr-check {
  margin-left: auto;
  color: var(--k-accent, #007aff);
  font-size: 12px;
}

.search-empty {
  font-size: 13px;
  color: var(--k-text-tertiary, #c7c7cb);
  padding: 12px;
}
</style>

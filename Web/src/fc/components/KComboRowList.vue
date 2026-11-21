<template>
  <div class="combo-list">
    <button
      v-for="c in modelValue.rows"
      :key="c.comboKey"
      class="combo-row"
      :class="{ checked: modelValue.checked.includes(c.comboKey) }"
      :aria-label="`cacheManage.combo.${c.label}`"
      @click="emit('toggle', c.comboKey)"
    >
      <span class="check">{{ modelValue.checked.includes(c.comboKey) ? '●' : '○' }}</span>
      <span class="combo-name">{{ c.label }}</span>
      <span class="combo-stat">{{ c.count }} 项 · {{ fmtBytes(c.bytes) }}</span>
    </button>
  </div>
</template>

<script setup lang="ts">
// k-combo-row-list：缓存组合占用行列表（勾选多选 + 名称 + 项数/字节统计）。
// 哑组件：checked 数组由 adapter 维护（toggle 事件抛出）。
export interface ComboRow {
  comboKey: string
  label: string
  count: number
  bytes: number
}

withDefaults(defineProps<{ modelValue?: { rows?: ComboRow[]; checked?: string[] } }>(), {
  modelValue: () => ({ rows: [], checked: [] }),
})

const emit = defineEmits<{
  (e: 'toggle', comboKey: string): void
}>()

function fmtBytes(b: number): string {
  if (b >= 1024 * 1024) return `${(b / 1024 / 1024).toFixed(1)} MB`
  if (b >= 1024) return `${(b / 1024).toFixed(1)} KB`
  return `${b} B`
}
</script>

<style scoped>
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
  background: var(--k-bg-secondary, #f2f2f7);
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
  color: var(--k-text-tertiary, #c7c7cb);
  flex-shrink: 0;
}

.combo-row.checked .check {
  color: #1989fa;
}

.combo-name {
  flex: 1;
  font-size: 14px;
  font-weight: 500;
  color: var(--k-text, #000);
}

.combo-stat {
  font-size: 12px;
  color: var(--k-text-tertiary, #c7c7cb);
  flex-shrink: 0;
}
</style>

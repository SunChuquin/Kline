<template>
  <div>
    <button
      v-for="(r, i) in modelValue.rows"
      :key="i"
      class="entry-card row"
      :aria-label="r.aria"
      @click="emit('act', r.act)"
    >
      <span class="entry-title">{{ r.title }}</span>
      <span class="chev">›</span>
    </button>
  </div>
</template>

<script setup lang="ts">
// k-entry-list：个人中心入口行列表（卡片行 + › 箭头，整行可点）。
// 哑组件：rows 由 adapter 注入；点击抛 act 字符串（openPage/openFormulaCenter 分发）。
export interface EntryRow {
  title: string
  aria?: string
  act: string
}

export interface EntryListState {
  rows: EntryRow[]
}

withDefaults(defineProps<{
  modelValue?: EntryListState
}>(), {
  modelValue: () => ({ rows: [] }),
})

const emit = defineEmits<{
  (e: 'act', act: string): void
}>()
</script>

<style scoped>
.entry-card {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 12px;
  margin-bottom: 14px;
}

.entry-card.row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 52px;
  width: 100%;
  border: none;
  cursor: pointer;
  text-align: left;
  color: var(--k-text, #000);
  font-size: 16px;
  padding: 6px 16px;
}

.entry-title { font-size: 16px; }

.chev { color: var(--k-text-tertiary, #c7c7cb); font-size: 14px; }
</style>

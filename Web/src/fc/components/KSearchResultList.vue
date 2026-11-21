<template>
  <div class="search-rows">
    <div
      v-for="(r, i) in modelValue.rows"
      :key="r.file"
      class="sh-row"
      :aria-label="`search.row.${i}`"
      @click="emit('pick', r)"
    >
      <span class="sr-name">{{ r.name }}</span>
      <span class="sr-code">{{ r.code }}</span>
      <span class="sr-type">{{ r.type }}</span>
    </div>
    <div v-if="modelValue.rows.length === 0 && modelValue.emptyText" class="sh-empty">{{ modelValue.emptyText }}</div>
  </div>
</template>

<script setup lang="ts">
// k-search-result-list：搜索页结果行列表（名称 + 代码 + 标的类型 + 空态）。
// 哑组件：rows/emptyText 由 adapter 注入（searchMeta 同口径查询）；
// 点击行抛 pick(row)，adapter 走 search.openDetail（原生关页进详情）。
export interface SearchResultRow {
  file: string
  name: string
  code: string
  type: string
}

export interface SearchResultState {
  rows: SearchResultRow[]
  emptyText?: string
}

withDefaults(defineProps<{
  modelValue?: SearchResultState
}>(), {
  modelValue: () => ({ rows: [] }),
})

const emit = defineEmits<{
  (e: 'pick', row: SearchResultRow): void
}>()
</script>

<style scoped>
.sh-row {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 11px 16px;
  cursor: pointer;
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
  min-height: 44px;
}

.sr-name {
  font-size: 14px;
  color: var(--k-text, #000);
  flex: 1;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.sr-code {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
  flex-shrink: 0;
}

.sr-type {
  font-size: 11px;
  color: var(--k-text-tertiary, #c7c7cb);
  flex-shrink: 0;
}

.sh-empty {
  font-size: 13px;
  color: var(--k-text-tertiary, #c7c7cb);
  padding: 16px;
  text-align: center;
}
</style>

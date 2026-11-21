<template>
  <div class="seg-bar">
    <button
      v-for="t in modelValue.tabs"
      :key="t.value"
      class="seg-item"
      :class="{ on: modelValue.value === t.value }"
      @click="emit('select', t.value)"
    >{{ t.title }} {{ t.count ?? 0 }}</button>
  </div>
</template>

<script setup lang="ts">
// k-seg-tabs：三段等宽分段条（成交/条件单/预警明细页；title 后缀计数）。
export interface SegTab {
  value: string
  title: string
  count?: number
}

withDefaults(defineProps<{
  modelValue?: { tabs?: SegTab[]; value?: string }
}>(), {
  modelValue: () => ({ tabs: [], value: '' }),
})

const emit = defineEmits<{
  (e: 'select', value: string): void
}>()
</script>

<style scoped>
.seg-bar {
  display: flex;
  gap: 6px;
  padding: 6px 12px;
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
}

.seg-item {
  flex: 1;
  border: none;
  background: var(--k-bg-secondary, #f2f2f7);
  color: var(--k-text-secondary, #6c6c70);
  font-size: 13px;
  height: 30px;
  border-radius: 8px;
  cursor: pointer;
}

.seg-item.on {
  background: var(--k-accent, #007aff);
  color: #ffffff;
  font-weight: 600;
}
</style>

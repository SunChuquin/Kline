<template>
  <div class="color-grid">
    <button
      v-for="c in modelValue.colors"
      :key="c.option"
      class="color-cell"
      :style="{ background: '#' + c.hex }"
      :aria-label="`formulaEditor.color.${c.name}`"
      @click="emit('pick', c.option)"
    ></button>
  </div>
</template>

<script setup lang="ts">
// k-color-grid：公式编辑器调色网格（点击在光标处插入 COLORXXX 关键字）。
export interface ColorCell {
  option: string
  name: string
  hex: string
}

withDefaults(defineProps<{
  modelValue?: { colors?: ColorCell[] }
}>(), {
  modelValue: () => ({ colors: [] }),
})

const emit = defineEmits<{
  (e: 'pick', option: string): void
}>()
</script>

<style scoped>
.color-grid {
  display: grid;
  grid-template-columns: repeat(9, 1fr);
  gap: 6px;
  margin-top: 8px;
}

.color-cell {
  height: 24px;
  border: 1px solid rgba(128, 128, 128, 0.3);
  border-radius: 5px;
  cursor: pointer;
  padding: 0;
}
</style>

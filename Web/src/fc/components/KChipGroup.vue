<template>
  <div class="chip-row" :role="multiple ? 'group' : 'radiogroup'">
    <button
      v-for="o in options"
      :key="o.value"
      class="chip"
      :class="{ on: isOn(o.value) }"
      :aria-label="o.ariaLabel ?? o.label"
      @click="select(o.value)"
    >{{ o.label }}</button>
  </div>
</template>

<script setup lang="ts">
// k-chip-group：chip 单/多选组（训练分类、账户类型、缓存组合多选等）。
// 表单输入语义：值即字段值；select 事件额外抛出（adapter 可即时写回桥）。
const props = withDefaults(defineProps<{
  modelValue?: string | string[] | null
  options: { label: string; value: string; ariaLabel?: string }[]
  multiple?: boolean
}>(), {
  modelValue: '',
})
const emit = defineEmits<{
  (e: 'update:modelValue', v: string | string[]): void
  (e: 'select', v: string): void
}>()

function isOn(v: string): boolean {
  if (props.multiple) return Array.isArray(props.modelValue) && props.modelValue.includes(v)
  return props.modelValue === v
}

function select(v: string): void {
  if (props.multiple) {
    const cur = Array.isArray(props.modelValue) ? [...props.modelValue] : []
    const idx = cur.indexOf(v)
    if (idx >= 0) cur.splice(idx, 1)
    else cur.push(v)
    emit('update:modelValue', cur)
  } else {
    emit('update:modelValue', v)
  }
  emit('select', v)
}
</script>

<style scoped>
.chip-row {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.chip {
  border: none;
  background: var(--k-bg-secondary, #f2f2f7);
  color: var(--k-text, #000);
  font-size: 13px;
  height: 32px;
  padding: 0 14px;
  border-radius: 16px;
  cursor: pointer;
}

.chip.on {
  background: var(--k-accent, #007aff);
  color: #ffffff;
  font-weight: 600;
}
</style>

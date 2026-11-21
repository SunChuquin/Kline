<template>
  <div class="chip-sections" :aria-label="ariaLabel">
    <template v-for="(sec, si) in modelValue.sections" :key="si">
      <div v-if="sec.title" class="group-cap">{{ sec.title }}</div>
      <div class="chip-wrap">
        <button
          v-for="o in sec.options"
          :key="o.value"
          class="opt-chip"
          :class="{ on: isOn(o.value) }"
          :aria-label="o.ariaLabel ?? o.label"
          @click="select(o.value)"
        >
          <span v-if="o.dot" class="dot" :style="{ background: '#' + o.dot }"></span>{{ o.label }}{{ o.mark ? ' ✓' : '' }}
        </button>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
// k-chip-sections：带分组标题/色点/生效标记的 chip 组（组合编辑器 tab/指标选项）。
export interface ChipSectionOption {
  label: string
  value: string
  dot?: string
  mark?: boolean
  ariaLabel?: string
}

export interface ChipSection {
  title: string
  options: ChipSectionOption[]
}

const props = withDefaults(defineProps<{
  modelValue?: { value?: string | string[]; sections?: ChipSection[]; multiple?: boolean }
  ariaLabel?: string
}>(), {
  modelValue: () => ({ value: '', sections: [] }),
})

const emit = defineEmits<{
  (e: 'update:modelValue', v: { value: string | string[]; sections: ChipSection[]; multiple?: boolean }): void
  (e: 'select', v: string): void
}>()

function isOn(v: string): boolean {
  const val = props.modelValue.value
  if (props.modelValue.multiple) return Array.isArray(val) && val.includes(v)
  return val === v
}

function select(v: string): void {
  const sections = props.modelValue.sections
  if (props.modelValue.multiple) {
    const cur = Array.isArray(props.modelValue.value) ? [...props.modelValue.value] : []
    const idx = cur.indexOf(v)
    if (idx >= 0) cur.splice(idx, 1)
    else cur.push(v)
    emit('update:modelValue', { ...props.modelValue, value: cur })
  } else {
    emit('update:modelValue', { ...props.modelValue, value: v })
  }
  emit('select', v)
}
</script>

<style scoped>
.chip-sections {
  display: flex;
  flex-direction: column;
}

.group-cap {
  font-size: 11px;
  color: var(--k-text-tertiary, #c7c7cb);
  padding: 4px 0 2px;
}

.chip-wrap {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
  margin-bottom: 6px;
}

.opt-chip {
  border: none;
  background: var(--k-bg-secondary, #f2f2f7);
  color: var(--k-text, #000);
  font-size: 12px;
  height: 30px;
  padding: 0 12px;
  border-radius: 8px;
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  gap: 5px;
}

.opt-chip.on {
  background: #1989fa;
  color: #ffffff;
  font-weight: 600;
}

.dot {
  width: 12px;
  height: 4px;
  border-radius: 2px;
  display: inline-block;
}
</style>

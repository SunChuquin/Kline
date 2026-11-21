<template>
  <div class="k-actions-row">
    <button
      v-for="b in modelValue.buttons"
      :key="b.act"
      class="act-btn"
      :class="b.tone"
      :disabled="b.disabled"
      :aria-label="b.ariaLabel ?? b.label"
      @click="emit('act', b.act)"
    >{{ b.label }}</button>
  </div>
</template>

<script setup lang="ts">
// k-actions-row：横排动作按钮组（tone: primary/danger/plain）。
export interface ActionButton {
  label: string
  act: string
  tone?: 'primary' | 'danger'
  disabled?: boolean
  ariaLabel?: string
}

withDefaults(defineProps<{
  modelValue?: { buttons?: ActionButton[] }
}>(), {
  modelValue: () => ({ buttons: [] }),
})

const emit = defineEmits<{
  (e: 'act', act: string): void
}>()
</script>

<style scoped>
.k-actions-row {
  display: flex;
  gap: 8px;
  padding: 8px 0;
}

.act-btn {
  flex: 1;
  height: 44px;
  border: none;
  border-radius: 10px;
  background: var(--k-bg-secondary, #f2f2f7);
  color: var(--k-text, #000);
  font-size: 14px;
  font-weight: 500;
  cursor: pointer;
}

.act-btn.primary {
  background: var(--k-accent, #007aff);
  color: #ffffff;
  font-weight: 600;
}

.act-btn.danger {
  background: rgba(238, 10, 36, 0.08);
  color: #ee0a24;
}

.act-btn:disabled {
  opacity: 0.45;
  cursor: default;
}
</style>

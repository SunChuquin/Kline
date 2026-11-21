<template>
  <div class="k-confirm-bar">
    <div v-if="modelValue.error" class="bar-warn">{{ modelValue.error }}</div>
    <button
      class="confirm-btn"
      :aria-label="ariaLabel"
      :disabled="modelValue.disabled"
      @click="emit('confirm')"
    >{{ modelValue.label }}</button>
  </div>
</template>

<script setup lang="ts">
// k-confirm-bar：底部固定确认条（生成条件单确认态；error 红 warn + 主按钮）。
withDefaults(defineProps<{
  modelValue?: { error?: string; label?: string; disabled?: boolean }
  ariaLabel?: string
}>(), {
  modelValue: () => ({}),
  ariaLabel: '',
})

const emit = defineEmits<{
  (e: 'confirm'): void
}>()
</script>

<style scoped>
.k-confirm-bar {
  position: fixed;
  bottom: 0;
  left: 0;
  right: 0;
  padding: 10px 16px;
  background: var(--k-bg, #ffffff);
  border-top: 0.5px solid var(--k-divider, #c6c6c8);
}

.bar-warn {
  font-size: 12px;
  color: #ee0a24;
  padding: 4px 0 8px;
}

.confirm-btn {
  width: 100%;
  border: none;
  border-radius: 10px;
  height: 44px;
  font-size: 15px;
  font-weight: 600;
  cursor: pointer;
  background: #1989fa;
  color: #ffffff;
}

.confirm-btn:disabled {
  background: var(--k-bg-secondary, #f2f2f7);
  color: var(--k-text-tertiary, #c7c7cb);
  cursor: default;
}
</style>

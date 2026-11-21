<template>
  <button class="tool-link" :aria-label="ariaLabel" :disabled="disabled" @click="emit('act')">{{ modelValue }}</button>
</template>

<script setup lang="ts">
// k-tool-link：工具条文本链接按钮（全选/取消全选等，蓝字纯文本）。
withDefaults(defineProps<{
  modelValue?: string
  disabled?: boolean
  ariaLabel?: string
}>(), {
  modelValue: '',
  disabled: false,
  ariaLabel: '',
})

const emit = defineEmits<{
  (e: 'act'): void
}>()
</script>

<style scoped>
.tool-link {
  border: none;
  background: none;
  color: #1989fa;
  font-size: 12.5px;
  font-weight: 500;
  cursor: pointer;
  padding: 8px;
}

.tool-link:disabled {
  color: var(--k-text-tertiary, #c7c7cb);
  cursor: default;
}
</style>

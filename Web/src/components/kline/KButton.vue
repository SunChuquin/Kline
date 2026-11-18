<template>
  <button class="k-button" :class="`k-button--${type}`" :disabled="disabled" type="button" @click="emit('click')">
    <slot />
  </button>
</template>

<script setup lang="ts">
// KButton 按钮
// 蓝本：Element Plus el-button 的 primary / default / text 三型语义与 disabled 态。
// 适配：min-height 44px 触达规范；primary 用 --k-accent（对齐 systemBlue）。
withDefaults(
  defineProps<{
    type?: 'primary' | 'default' | 'text'
    disabled?: boolean
    block?: boolean
  }>(),
  { type: 'default', disabled: false, block: false },
)

const emit = defineEmits<{ click: [] }>()
</script>

<style scoped>
.k-button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  min-height: 44px;
  padding: 0 18px;
  border: none;
  border-radius: 10px;
  font-size: 15px;
  font-weight: 600;
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  transition: opacity 0.1s ease;
}

.k-button:active {
  opacity: 0.6;
}

.k-button:disabled {
  opacity: 0.35;
}

.k-button--primary {
  background: var(--k-accent);
  color: #ffffff;
}

.k-button--default {
  background: var(--k-bg-secondary);
  color: var(--k-text);
}

.k-button--text {
  background: none;
  color: var(--k-accent);
  padding: 0 8px;
}
</style>

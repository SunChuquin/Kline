<template>
  <div class="nav-line">
    <button class="nav-link" :aria-label="backAria" @click="emit('back')">{{ backLabel }}</button>
    <span class="nav-center">{{ title }}</span>
    <button class="nav-link save" :aria-label="rightAria" :disabled="rightDisabled" @click="emit('right')">{{ rightLabel }}</button>
  </div>
</template>

<script setup lang="ts">
// k-editor-nav：编辑器页头（取消/返回 ｜ 标题 ｜ 保存）。保存按钮可禁用
// （canSave 驱动 rightDisabled），对齐各编辑器面板的 nav-line 结构。
withDefaults(defineProps<{
  title?: string
  backLabel?: string
  backAria?: string
  rightLabel?: string
  rightAria?: string
  rightDisabled?: boolean
}>(), {
  title: '',
  backLabel: '‹ 返回',
  backAria: '',
  rightLabel: '保存',
  rightAria: '',
  rightDisabled: false,
})

const emit = defineEmits<{
  (e: 'back'): void
  (e: 'right'): void
}>()
</script>

<style scoped>
.nav-line {
  display: flex;
  align-items: center;
  height: 48px;
  padding: 0 8px;
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
  flex-shrink: 0;
}

.nav-link {
  border: none;
  background: none;
  color: var(--k-text, #000);
  font-size: 15px;
  font-weight: 500;
  cursor: pointer;
  padding: 8px 10px;
  min-width: 44px;
  min-height: 44px;
}

.nav-link.save {
  color: var(--k-accent, #1989fa);
  font-weight: 600;
}

.nav-link.save:disabled {
  color: var(--k-text-tertiary, #c7c7cb);
  cursor: default;
}

.nav-center {
  flex: 1;
  text-align: center;
  font-size: 15px;
  font-weight: 600;
  color: var(--k-text, #000);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
</style>

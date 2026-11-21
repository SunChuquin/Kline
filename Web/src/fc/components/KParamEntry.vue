<template>
  <button class="param-entry" :aria-label="ariaLabel" @click="emit('act')">
    <span>{{ label }}</span>
    <span v-if="trailing" class="trail">{{ trailing }}</span>
  </button>
</template>

<script setup lang="ts">
// k-param-entry：蓝底入口按钮（⚙ 公式编辑 › / ＋ 新增/管理 ›）。
withDefaults(defineProps<{
  label: string
  ariaLabel?: string
  trailing?: string
}>(), {
  trailing: '›',
})

const emit = defineEmits<{
  (e: 'act'): void
}>()
</script>

<style scoped>
.param-entry {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  border: none;
  border-radius: 8px;
  background: rgba(25, 137, 250, 0.08);
  color: #1989fa;
  font-size: 13px;
  padding: 12px 14px;
  margin: 8px 0;
  cursor: pointer;
}

.trail { opacity: 0.7; }
</style>

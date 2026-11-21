<template>
  <div class="k-empty-block" :class="modelValue.size ?? 'sm'">
    <div v-if="modelValue.icon" class="empty-icon">{{ modelValue.icon }}</div>
    <div v-if="modelValue.title" class="empty-title">{{ modelValue.title }}</div>
    <div v-if="modelValue.sub" class="empty-sub">{{ modelValue.sub }}</div>
  </div>
</template>

<script setup lang="ts">
// k-empty-block：居中空态/详情块（sm=列表空态 34px 图标；lg=详情页 52px 大标题）。
withDefaults(defineProps<{
  modelValue?: { icon?: string; title?: string; sub?: string; size?: 'sm' | 'lg' }
}>(), {
  modelValue: () => ({}),
})
</script>

<style scoped>
.k-empty-block {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 10px;
  padding: 0 32px;
  text-align: center;
}

.empty-icon { font-size: 34px; }

.empty-title {
  font-size: 13px;
  color: var(--k-text-secondary, #6c6c70);
}

.empty-sub {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
  line-height: 1.5;
}

.k-empty-block.lg {
  gap: 16px;
}

.k-empty-block.lg .empty-icon { font-size: 52px; color: #1989fa; }

.k-empty-block.lg .empty-title {
  font-size: 20px;
  font-weight: 700;
  color: var(--k-text, #000);
}

.k-empty-block.lg .empty-sub {
  font-size: 14px;
  color: var(--k-text-tertiary, #c7c7cb);
  line-height: 1.6;
}
</style>

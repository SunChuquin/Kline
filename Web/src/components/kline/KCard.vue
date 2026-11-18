<template>
  <div class="k-card">
    <div v-if="title" class="k-card__header">{{ title }}</div>
    <div class="k-card__body">
      <slot />
    </div>
  </div>
</template>

<script setup lang="ts">
// KCard 卡片容器
// 蓝本：Element Plus el-card（header/body 分区、圆角容器语义）。
// 适配：圆角 12 对齐项目弹窗/卡片惯例；无阴影（列表内嵌场景），
// 深浅色经 --k-bg-secondary 自动跟随主题。
defineProps<{ title?: string }>()
</script>

<style scoped>
.k-card {
  background: var(--k-bg-secondary);
  border-radius: 12px;
  overflow: hidden;
}

.k-card__header {
  font-size: 13px;
  font-weight: 600;
  color: var(--k-text-secondary);
  padding: 10px 16px;
  border-bottom: 1px solid var(--k-divider);
}

.k-card__body {
  padding: 4px 16px 8px;
}
</style>

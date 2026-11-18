<template>
  <div class="page">
    <div class="banner">{{ batch }} 建设中（当前 Tab 内容仍为原生版）</div>
    <KCard title="路由骨架">
      <KCell label="路由" :value="path" />
      <KCell label="批次" :value="batch" />
    </KCard>
  </div>
</template>

<script setup lang="ts">
// Tab 页通用占位：P2 各批次逐页实装
import KCard from '../components/kline/KCard.vue'
import KCell from '../components/kline/KCell.vue'

defineProps<{ path: string; batch: string }>()
</script>

<style scoped>
.page {
  min-height: 100vh;
  padding: 14px 16px 24px;
  background: var(--k-bg);
}
.banner {
  font-size: 12px;
  color: var(--k-text-secondary);
  padding: 8px 0 14px;
}
.page > :deep(.k-card) {
  margin-bottom: 14px;
}
</style>

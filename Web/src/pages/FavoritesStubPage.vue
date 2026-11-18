<template>
  <div class="page">
    <div class="banner">自选页 · P2-1 建设中（当前 Tab 内容仍为原生版）</div>
    <KCard title="路由骨架">
      <KCell label="路由" value="/favorites" />
      <KCell label="批次" value="P2-1 Favorites" />
    </KCard>
  </div>
</template>

<script setup lang="ts">
import KCard from '../components/kline/KCard.vue'
import KCell from '../components/kline/KCell.vue'
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

<template>
  <div class="home-header">
    <div class="brand">
      <span class="brand-icon">📈</span>
      <!-- aria-label = UITest 锚点（KlineUITests/LANSyncUITests/GapBackfillUITests 首页判定） -->
      <span class="brand-name" aria-label="home.page">Kline</span>
    </div>
    <button class="profile-pill" aria-label="home.profileButton" @click="emit('open', 'profile')">
      <van-icon name="user-circle-o" class="profile-icon" />
      <span>登录</span>
    </button>
  </div>
</template>

<script setup lang="ts">
// k-home-header：首页标题栏（软件图标 + 名称 + 登录胶囊，对齐 HomeHeaderBar）。
// 迁移自 HomePage.vue 标题栏区；登录胶囊动作 open('profile') 抛给 adapter。
const emit = defineEmits<{
  (e: 'open', kind: string): void
}>()
</script>

<style scoped>
.home-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 56px;
  padding: 0 16px;
}

.brand {
  display: flex;
  align-items: center;
  gap: 6px;
}

.brand-icon {
  font-size: 22px;
}

.brand-name {
  font-size: 18px;
  font-weight: 700;
  color: var(--k-text);
}

.profile-pill {
  display: flex;
  align-items: center;
  gap: 5px;
  border: none;
  border-radius: 20px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 15px;
  padding: 4px 10px;
  cursor: pointer;
}

.profile-icon {
  font-size: 22px;
  color: #007aff;
}
</style>

<template>
  <div class="ppp-head">
    <div class="avatar">👤</div>
    <div class="user-name">Kline 用户</div>
    <div class="user-meta">v{{ modelValue.version }} ({{ modelValue.build }})</div>
  </div>
</template>

<script setup lang="ts">
// k-profile-header：个人中心头部（头像 / 用户名 / 版本号）。
// 哑组件：version/build 由 adapter 从 profile.snapshot 注入。
export interface ProfileHeadState {
  version: string
  build: string
}

withDefaults(defineProps<{
  modelValue?: ProfileHeadState
}>(), {
  modelValue: () => ({ version: '', build: '' }),
})
</script>

<style scoped>
.ppp-head {
  margin-bottom: 14px;
}

.avatar {
  font-size: 64px;
  text-align: center;
  padding: 8px 0 4px;
}

.user-name {
  font-size: 20px;
  font-weight: 700;
  text-align: center;
  color: var(--k-text, #000);
}

.user-meta {
  font-size: 13px;
  color: var(--k-text-secondary, #6c6c70);
  text-align: center;
  margin: 4px 0 16px;
}
</style>

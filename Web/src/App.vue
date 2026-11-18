<template>
  <!-- Tab 页 keep-alive：切换不销毁状态 -->
  <router-view v-slot="{ Component }">
    <keep-alive>
      <component :is="Component" />
    </keep-alive>
  </router-view>
</template>

<script setup lang="ts">
</script>

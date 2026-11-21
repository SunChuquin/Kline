<template>
  <div class="k-sec-title" :class="{ danger }">{{ text }}</div>
</template>

<script setup lang="ts">
// k-sec-title：分节标题（danger 桁红色）。
defineProps<{
  text: string
  danger?: boolean
}>()
</script>

<style scoped>
.k-sec-title {
  font-size: 13px;
  color: var(--k-text-secondary, #6c6c70);
  padding: 8px 2px 6px;
  font-weight: 600;
}

.k-sec-title.danger { color: #ee0a24; }
</style>

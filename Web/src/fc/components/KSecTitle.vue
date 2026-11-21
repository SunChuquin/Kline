<template>
  <div class="k-sec-title" :class="{ danger, plain, warn }">{{ text }}</div>
</template>

<script setup lang="ts">
// k-sec-title：分节标题（danger 红 / warn 橙 / plain 弱化为普通说明文字）。
defineProps<{
  text: string
  danger?: boolean
  warn?: boolean
  plain?: boolean
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

.k-sec-title.warn { color: #ff9500; }

.k-sec-title.plain {
  font-weight: 400;
  font-size: 12px;
  line-height: 1.5;
}
</style>

<template>
  <div class="notice-card">
    <div v-if="modelValue.scanned" class="scan-line">{{ modelValue.scanned }}</div>
    <div v-for="(w, i) in modelValue.warnings" :key="`w${i}`" class="warn-line">{{ w }}</div>
    <template v-if="(modelValue.skipped ?? []).length > 0">
      <button class="skip-toggle" @click="showSkips = !showSkips">
        跳过 {{ modelValue.skipped!.length }} 条 {{ showSkips ? '▴' : '▾' }}
      </button>
      <div v-if="showSkips" class="skip-box">
        <div v-for="(s, i) in modelValue.skipped" :key="`s${i}`" class="skip-line">{{ s }}</div>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
// k-notice-card：回测提示卡（扫描/命中统计 + 警告行 + 跳过明细折叠）。
import { ref } from 'vue'

withDefaults(defineProps<{
  modelValue?: { scanned?: string; warnings?: string[]; skipped?: string[] }
}>(), {
  modelValue: () => ({}),
})

const showSkips = ref(false)
</script>

<style scoped>
.notice-card {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 12px;
  padding: 12px;
  margin-bottom: 12px;
}

.scan-line {
  font-size: 12px;
  font-weight: 500;
  color: var(--k-text, #000);
}

.warn-line {
  font-size: 12px;
  color: #ff9500;
  padding: 2px 0 8px;
}

.skip-toggle {
  border: none;
  background: none;
  color: var(--k-text-secondary, #6c6c70);
  font-size: 12.5px;
  font-weight: 500;
  min-height: 44px;
  padding: 0;
  cursor: pointer;
  display: flex;
  align-items: center;
  gap: 4px;
}

.skip-box {
  background: var(--k-bg, #ffffff);
  border-radius: 12px;
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.skip-line {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
  line-height: 1.5;
}
</style>

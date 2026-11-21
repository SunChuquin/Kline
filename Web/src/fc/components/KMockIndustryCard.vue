<template>
  <div class="card">
    <div class="card-head">
      <span class="card-title">{{ modelValue.title }}</span>
      <span v-if="modelValue.updateTime" class="card-time">{{ modelValue.updateTime }}</span>
      <span v-else-if="modelValue.showMore" class="card-more">›</span>
    </div>
    <div class="h-scroll">
      <button
        v-for="item in modelValue.items"
        :key="item.title"
        class="text-chip"
        :aria-label="`testPage.item.${item.title}`"
        @click="emit('pick', item.title)"
      >
        <span class="text-chip-title">{{ item.title }}</span>
        <span class="text-chip-sub" :class="item.isUp ? 'up' : 'down'">{{ item.subtitle }}</span>
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
// k-mock-industry-card：热门行业横滑卡（文字 chip 红涨绿跌，对齐 MockData.swift）。
export interface MockIndustryItem {
  title: string
  subtitle: string
  isUp: boolean
}

withDefaults(defineProps<{
  modelValue?: { title?: string; showMore?: boolean; updateTime?: string | null; items?: MockIndustryItem[] }
}>(), {
  modelValue: () => ({}),
})

const emit = defineEmits<{
  (e: 'pick', title: string): void
}>()
</script>

<style scoped>
.card {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 12px;
  padding: 12px;
  margin-bottom: 16px;
}

.card-head {
  display: flex;
  align-items: center;
  margin-bottom: 12px;
}

.card-title {
  font-size: 15px;
  font-weight: 700;
}

.card-time {
  margin-left: auto;
  font-size: 12px;
  color: var(--k-text-tertiary, #c7c7cb);
}

.card-more {
  margin-left: auto;
  font-size: 15px;
  color: var(--k-text-tertiary, #c7c7cb);
}

.h-scroll {
  display: flex;
  gap: 12px;
  overflow-x: auto;
  padding-bottom: 2px;
}

.text-chip {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  border: none;
  background: var(--k-bg, #ffffff);
  border-radius: 8px;
  padding: 10px 16px;
  cursor: pointer;
  flex-shrink: 0;
}

.text-chip-title {
  font-size: 13px;
  color: var(--k-text, #000);
}

.text-chip-sub {
  font-size: 12px;
  font-weight: 500;
}

.text-chip-sub.up { color: #ee0a24; }
.text-chip-sub.down { color: #07c160; }
</style>

<template>
  <div v-for="card in modelValue.cards" :key="card.title" class="card">
    <div class="card-head">
      <span class="card-title">{{ card.title }}</span>
      <span v-if="card.updateTime" class="card-time">{{ card.updateTime }}</span>
      <span v-else-if="card.showMore" class="card-more">›</span>
    </div>
    <!-- 图标卡（SF Symbols 以 emoji 等价呈现） -->
    <div v-if="card.kind === 'icons'" class="h-scroll">
      <button
        v-for="item in card.items"
        :key="item.title"
        class="icon-item"
        :class="{ bare: !card.iconBg }"
        :aria-label="`testPage.item.${item.title}`"
        @click="emit('pick', item.title)"
      >
        <span class="icon">{{ item.icon }}</span>
        <span class="icon-title">{{ item.title }}</span>
      </button>
    </div>
    <!-- 列表卡（rank + badge） -->
    <div v-else class="list">
      <button
        v-for="item in card.items"
        :key="item.title"
        class="list-row"
        :aria-label="`testPage.item.${item.title}`"
        @click="emit('pick', item.title)"
      >
        <span class="rank" :class="{ top: (item.rank ?? 9) <= 3 }">{{ item.rank }}</span>
        <span class="list-title">{{ item.title }}</span>
        <span v-if="item.badge" class="badge" :class="item.badgeTone">{{ item.badge }}</span>
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
// k-mock-column：测试页左右分栏卡片列（图标卡 / 榜单卡混排，对齐 MockData.swift）。
export interface MockListItem {
  title: string
  icon?: string
  rank?: number
  badge?: string | null
  badgeTone?: string
}

export interface MockCard {
  kind: 'icons' | 'list'
  title: string
  showMore: boolean
  updateTime: string | null
  iconBg?: boolean
  items: MockListItem[]
}

withDefaults(defineProps<{
  modelValue?: { cards?: MockCard[] }
}>(), {
  modelValue: () => ({ cards: [] }),
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

.icon-item {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 8px;
  border: none;
  background: none;
  cursor: pointer;
  flex-shrink: 0;
  padding: 0;
}

.icon-item .icon {
  width: 52px;
  height: 52px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 26px;
  border-radius: 12px;
  background: var(--k-bg, #ffffff);
}

.icon-item.bare .icon {
  background: transparent;
}

.icon-title {
  font-size: 12px;
  color: var(--k-text, #000);
}

.list {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.list-row {
  display: flex;
  align-items: center;
  gap: 12px;
  border: none;
  background: none;
  cursor: pointer;
  padding: 0;
  text-align: left;
  width: 100%;
}

.rank {
  width: 24px;
  text-align: center;
  font-size: 14px;
  font-weight: 700;
  color: var(--k-text-tertiary, #c7c7cb);
  flex-shrink: 0;
}

.rank.top {
  color: #ee0a24;
}

.list-title {
  font-size: 14px;
  color: var(--k-text, #000);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  flex: 1;
}

.badge {
  font-size: 11px;
  color: #ffffff;
  padding: 2px 6px;
  border-radius: 4px;
  flex-shrink: 0;
}

.badge.red { background: #ee0a24; }
.badge.orange { background: #ff976a; }
.badge.green { background: #07c160; }
.badge.gray { background: var(--k-text-tertiary, #c7c7cb); }
</style>

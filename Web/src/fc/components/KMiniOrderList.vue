<template>
  <div class="mini-orders">
    <div v-for="o in modelValue.rows" :key="o.id" class="mini-order">
      <span class="dir-tag" :class="o.direction === 'buy' ? 'tag-buy' : 'tag-sell'">{{ o.direction === 'buy' ? '买入' : '卖出' }}</span>
      <span class="q-name">{{ o.name }}</span>
      <span class="q-code">{{ fmtShares(o.qty) }} 股 · {{ o.status }}</span>
    </div>
    <div v-if="modelValue.rows.length === 0" class="block-empty">{{ modelValue.emptyText ?? '暂无在途委托' }}</div>
  </div>
</template>

<script setup lang="ts">
// k-mini-order-list：在途委托行列表（方向标记 + 名称 + 数量/状态）。
export interface MiniOrder {
  id: string
  name: string
  direction: 'buy' | 'sell'
  status: string
  qty: number
}

import { fmtShares } from '../format'

withDefaults(defineProps<{
  modelValue?: { rows?: MiniOrder[]; emptyText?: string }
}>(), {
  modelValue: () => ({ rows: [] }),
})
</script>

<style scoped>
.mini-orders {
  display: flex;
  flex-direction: column;
}

.mini-order {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 36px;
  font-size: 12.5px;
  color: var(--k-text, #000);
}

.dir-tag {
  font-size: 10px;
  font-weight: 600;
  padding: 1px 5px;
  border-radius: 4px;
  flex-shrink: 0;
}

.tag-buy { color: #ff4d4f; background: rgba(255, 77, 79, 0.10); }
.tag-sell { color: #00b578; background: rgba(0, 181, 120, 0.10); }

.q-name {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.q-code {
  color: var(--k-text-secondary, #6c6c70);
  flex-shrink: 0;
}

.block-empty {
  font-size: 12px;
  color: var(--k-text-tertiary, #c7c7cb);
  padding: 8px 0;
  text-align: center;
}
</style>

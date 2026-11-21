<template>
  <div class="quote-rows">
    <div v-for="q in modelValue.rows" :key="q.file" class="quote-row" @click="emit('open', q)">
      <div class="q-left">
        <div class="q-name">{{ q.name }}</div>
        <div class="q-code">{{ q.code }}</div>
      </div>
      <span class="q-price" :class="pctClass(q)">{{ fmtPrice(q.price) }}</span>
      <span class="pct-pill" :class="pillClass(q)">{{ fmtPct(q) }}</span>
      <button v-if="modelValue.buySell" class="mini-btn buy" :aria-label="`quick.buy.${q.code}`" @click.stop="emit('pick', { row: q, direction: 'buy' })">买</button>
      <button v-if="modelValue.buySell" class="mini-btn sell" :aria-label="`quick.sell.${q.code}`" @click.stop="emit('pick', { row: q, direction: 'sell' })">卖</button>
    </div>
    <div v-if="modelValue.rows.length === 0" class="block-empty">{{ modelValue.emptyText ?? '暂无数据' }}</div>
  </div>
</template>

<script setup lang="ts">
// k-quote-list：行情行列表（名称/代码/价格/涨幅 pill + 可选买卖小按钮）。
// 哑组件：rows 由 adapter 注入；open/pick 抛给 adapter。
export interface QuoteRow {
  file: string
  code: string
  name: string
  price: number | null
  pct: number | null
}

import { fmtPrice, fmtPct, pctClass, pillClass } from '../format'

withDefaults(defineProps<{
  modelValue?: { rows?: QuoteRow[]; buySell?: boolean; emptyText?: string }
}>(), {
  modelValue: () => ({ rows: [] }),
})

const emit = defineEmits<{
  (e: 'open', row: QuoteRow): void
  (e: 'pick', payload: { row: QuoteRow; direction: 'buy' | 'sell' }): void
}>()
</script>

<style scoped>
.quote-rows {
  display: flex;
  flex-direction: column;
}

.quote-row {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 9px 10px;
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
  cursor: pointer;
}

.quote-row:last-child {
  border-bottom: none;
}

.q-left {
  flex: 1;
  min-width: 0;
}

.q-name {
  font-size: 14px;
  color: var(--k-text, #000);
}

.q-code {
  font-size: 11px;
  color: var(--k-text-secondary, #6c6c70);
}

.q-price {
  font-size: 14px;
  font-variant-numeric: tabular-nums;
  color: var(--k-text, #000);
}

.block-empty {
  font-size: 12px;
  color: var(--k-text-tertiary, #c7c7cb);
  padding: 10px;
  text-align: center;
}

.up { color: #ff4d4f; }
.down { color: #00b578; }

.pct-pill {
  font-size: 11px;
  font-weight: 600;
  padding: 2px 6px;
  border-radius: 4px;
  font-variant-numeric: tabular-nums;
}

.pill-up { color: #ff4d4f; background: rgba(255, 77, 79, 0.10); }
.pill-down { color: #00b578; background: rgba(0, 181, 120, 0.10); }
.pill-flat { color: var(--k-text-secondary, #6c6c70); background: rgba(128, 128, 128, 0.10); }

.mini-btn {
  width: 30px;
  height: 24px;
  flex-shrink: 0;
  border: none;
  border-radius: 5px;
  color: #ffffff;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
}

.mini-btn.buy { background: #ff4d4f; }
.mini-btn.sell { background: #00b578; }
</style>

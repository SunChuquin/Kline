<template>
  <div class="trades-card">
    <div class="trades-scroll">
      <div class="t-row t-head">
        <span class="tc" :style="tc(colDate)">日期</span>
        <span class="tc" :style="tc(colName)">标的</span>
        <span class="tc tc-c" :style="tc(colDir)">方向</span>
        <span class="tc tc-c" :style="tc(colRule)">规则</span>
        <span class="tc tc-r" :style="tc(colQty)">数量</span>
        <span class="tc tc-r" :style="tc(colPrice)">成交价</span>
        <span class="tc tc-r" :style="tc(colAmount)">金额</span>
        <span class="tc tc-r" :style="tc(colPnL)">盈亏</span>
      </div>
      <div class="t-divider"></div>
      <template v-for="trade in visibleTrades" :key="`${trade.date}-${trade.code}-${trade.direction}`">
        <div class="t-row">
          <span class="tc t-date" :style="tc(colDate)">{{ fmtDate(trade.date) }}</span>
          <span class="tc" :style="tc(colName)">{{ trade.name }} {{ trade.code }}</span>
          <span class="tc tc-c" :class="trade.direction === 'buy' ? 'tone-red' : 'tone-green'" :style="tc(colDir)">
            {{ trade.direction === 'buy' ? '买入' : '卖出' }}
          </span>
          <span class="tc tc-c t-sec" :style="tc(colRule)">{{ trade.rule ?? '—' }}</span>
          <span class="tc tc-r" :style="tc(colQty)">{{ fmtShares(trade.qty) }}</span>
          <span class="tc tc-r" :style="tc(colPrice)">{{ fmtPrice(trade.price) }}</span>
          <span class="tc tc-r" :style="tc(colAmount)">{{ fmtAmount(trade.amount) }}</span>
          <span v-if="trade.realizedPnL !== null" class="tc tc-r" :class="changeClass(trade.realizedPnL)" :style="tc(colPnL)">
            {{ fmtSigned(trade.realizedPnL) }}
          </span>
          <span v-else class="tc tc-r t-sec" :style="tc(colPnL)">{{ trade.direction === 'buy' ? '持仓中' : '—' }}</span>
        </div>
        <div class="t-divider"></div>
      </template>
    </div>
    <button
      v-if="rows.length > LIMIT && !showAll"
      class="expand-btn"
      @click="showAll = true"
    >展开全部（共 {{ rows.length }} 条）</button>
  </div>
</template>

<script setup lang="ts">
// k-trade-table：回测交易明细表（横向滚动 8 列，默认 50 条 + 展开全部；
// 盈亏红涨绿跌、未平仓显示持仓中，对齐原生明细列宽）。
import { computed, ref } from 'vue'
import { fmtShares } from '../format'

export interface TradeRow {
  date: number
  name: string
  code: string
  direction: 'buy' | 'sell'
  rule: string | null
  qty: number
  price: number
  amount: number
  realizedPnL: number | null
}

const props = withDefaults(defineProps<{
  modelValue?: { rows?: TradeRow[] }
}>(), {
  modelValue: () => ({ rows: [] }),
})

const showAll = ref(false)
const LIMIT = 50

const rows = computed(() => props.modelValue.rows ?? [])
const visibleTrades = computed(() => (showAll.value ? rows.value : rows.value.slice(0, LIMIT)))

// 明细列宽（对齐原生 colDate 等）
const colDate = 84, colName = 116, colDir = 40, colRule = 68,
  colQty = 54, colPrice = 62, colAmount = 84, colPnL = 78
function tc(width: number): Record<string, string> {
  return { width: `${width}px`, flex: 'none' }
}

function fmtAmount(v: number): string {
  return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}
function fmtSigned(v: number): string {
  return (v < 0 ? '-' : '+') + fmtAmount(Math.abs(v))
}
function fmtPrice(v: number): string {
  return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}
function fmtDate(v: number): string {
  if (v <= 0) return '—'
  const text = String(v)
  if (text.length !== 8) return text
  return `${text.slice(0, 4)}-${text.slice(4, 6)}-${text.slice(6, 8)}`
}
/** A 股语义：盈利红 / 亏损绿 */
function changeClass(v: number): string {
  if (v < 0) return 'tone-green'
  if (v > 0) return 'tone-red'
  return ''
}
</script>

<style scoped>
.trades-card {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 12px;
  padding: 12px 0 0;
  margin-bottom: 12px;
}

.trades-scroll {
  overflow-x: auto;
  padding: 0 12px;
}

.t-row {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 8px 0;
}

.t-head { padding: 6px 0; }

.tc {
  font-size: 12px;
  color: var(--k-text, #000);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.t-head .tc {
  font-size: 11px;
  color: var(--k-text-secondary, #6c6c70);
}

.tc-c { text-align: center; }
.tc-r { text-align: right; }

.t-date, .t-sec { color: var(--k-text-secondary, #6c6c70); }

.t-divider {
  height: 0.5px;
  background: var(--k-divider, #c6c6c8);
}

.expand-btn {
  width: 100%;
  border: none;
  background: none;
  color: var(--k-accent, #007aff);
  font-size: 12.5px;
  font-weight: 600;
  min-height: 44px;
  cursor: pointer;
}

.tone-red { color: #ff3b30; }
.tone-green { color: var(--k-ok, #00b578); }
</style>

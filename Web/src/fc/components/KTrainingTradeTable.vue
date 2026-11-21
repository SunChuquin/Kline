<template>
  <div class="trades-tab">
    <div v-if="rows.length === 0" class="list-empty">暂无交易明细</div>
    <div v-else class="trades-scroll">
      <div class="t-row t-head">
        <span class="tc" :style="tc(colSeq)">序号</span>
        <span class="tc tc-c" :style="tc(colDir)">方向</span>
        <span class="tc tc-c" :style="tc(colMark)">标记</span>
        <span class="tc" :style="tc(colDate)">成交日期</span>
        <span class="tc tc-r" :style="tc(colPrice)">成交价</span>
        <span class="tc tc-r" :style="tc(colQty)">数量</span>
        <span class="tc tc-r" :style="tc(colAmount)">成交额</span>
        <span class="tc tc-r" :style="tc(colFee)">手续费</span>
        <span class="tc tc-r" :style="tc(colPnl)">盈亏</span>
        <span class="tc" :style="tc(colTrigger)">触发来源</span>
        <span class="tc" :style="tc(colNote)">备注</span>
      </div>
      <div class="t-divider"></div>
      <template v-for="t in rows" :key="t.seq">
        <div class="t-row">
          <span class="tc mono t-sec" :style="tc(colSeq)">{{ t.seq }}</span>
          <span class="tc tc-c" :class="t.direction === 'buy' ? 'tone-red' : 'tone-green'" :style="tc(colDir)">
            {{ t.direction === 'buy' ? '买入' : '卖出' }}
          </span>
          <span class="tc tc-c" :class="markClass(t.mark)" :style="tc(colMark)">{{ t.mark }}</span>
          <span class="tc mono t-sec" :style="tc(colDate)">{{ ymd(t.tradeDate) }}</span>
          <span class="tc mono tc-r" :style="tc(colPrice)">{{ t.price.toFixed(2) }}</span>
          <span class="tc mono tc-r" :style="tc(colQty)">{{ t.qty }}</span>
          <span class="tc mono tc-r" :style="tc(colAmount)">{{ t.amount.toFixed(2) }}</span>
          <span class="tc mono tc-r t-sec" :style="tc(colFee)">{{ t.fee.toFixed(2) }}</span>
          <span class="tc mono tc-r" :class="pnlClass(t.pnl)" :style="tc(colPnl)">
            {{ t.pnl === null ? '—' : (t.pnl >= 0 ? '+' : '') + t.pnl.toFixed(2) }}
          </span>
          <span class="tc" :class="t.triggerText.startsWith('条件单') ? 'tone-blue' : 't-sec'" :style="tc(colTrigger)">
            {{ t.triggerText }}
          </span>
          <span class="tc t-sec" :style="tc(colNote)">{{ t.note || '—' }}</span>
        </div>
        <div class="t-divider"></div>
      </template>
    </div>
  </div>
</template>

<script setup lang="ts">
// k-training-trade-table：训练明细成交表（横向滚动 11 列，对齐原生列宽；
// 方向/标记/盈亏红涨绿跌、条件单触发蓝字）。
import { computed } from 'vue'

export interface TrainingTradeRow {
  seq: number
  direction: 'buy' | 'sell'
  mark: 'B' | 'S' | 'T'
  tradeDate: number
  price: number
  qty: number
  amount: number
  fee: number
  pnl: number | null
  triggerText: string
  note: string
}

const props = withDefaults(defineProps<{
  modelValue?: { rows?: TrainingTradeRow[] }
}>(), {
  modelValue: () => ({ rows: [] }),
})

const rows = computed(() => props.modelValue.rows ?? [])

// 明细列宽（对齐原生 Col）
const colSeq = 44, colDir = 52, colMark = 44, colDate = 92, colPrice = 84,
  colQty = 64, colAmount = 96, colFee = 72, colPnl = 88, colTrigger = 132, colNote = 140
function tc(width: number): Record<string, string> {
  return { width: `${width}px`, flex: 'none' }
}

function ymd(v: number | null): string {
  if (v === null || v <= 0) return '—'
  const s = String(v)
  return s.length === 8 ? `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}` : s
}

function markClass(mark: 'B' | 'S' | 'T'): string {
  return mark === 'B' ? 'tone-red' : mark === 'S' ? 'tone-green' : 'tone-blue'
}

function pnlClass(pnl: number | null): string {
  if (pnl === null) return 't-sec'
  return pnl > 0 ? 'tone-red' : pnl < 0 ? 'tone-green' : 't-sec'
}
</script>

<style scoped>
.trades-tab {
  flex: 1;
  overflow: auto;
}

.list-empty {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 200px;
  font-size: 13px;
  color: var(--k-text-secondary, #6c6c70);
}

.trades-scroll {
  min-width: 100%;
  width: max-content;
}

.t-row {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 0 8px;
  height: 44px;
}

.t-head {
  height: 34px;
  background: var(--k-bg-secondary, #f2f2f7);
}

.tc {
  font-size: 12.5px;
  color: var(--k-text, #000);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.t-head .tc {
  font-size: 11.5px;
  font-weight: 600;
  color: var(--k-text-secondary, #6c6c70);
}

.tc-c { text-align: center; }
.tc-r { text-align: right; }
.mono { font-variant-numeric: tabular-nums; }
.t-sec { color: var(--k-text-secondary, #6c6c70); }

.t-divider {
  height: 0.5px;
  background: var(--k-divider, #c6c6c8);
  margin-left: 8px;
}

/* A 股语义色 */
.tone-red { color: #ff3b30; font-weight: 600; }
.tone-green { color: var(--k-ok, #00b578); font-weight: 600; }
.tone-blue { color: var(--k-accent, #007aff); }
</style>

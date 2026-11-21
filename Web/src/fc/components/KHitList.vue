<template>
  <div class="hit-list">
    <button
      v-for="hit in modelValue.rows"
      :key="hit.metaID"
      class="hit-row"
      :aria-label="`pickRun.hit.${hit.code}`"
      @click="emit('toggle', hit.metaID)"
    >
      <span class="check" :class="{ on: modelValue.selected.includes(hit.metaID) }">{{ modelValue.selected.includes(hit.metaID) ? '●' : '○' }}</span>
      <span class="hit-name-block">
        <span class="hit-name">{{ hit.name }}</span>
        <span class="hit-code">{{ hit.code }}</span>
      </span>
      <span class="hit-price-block">
        <span class="hit-price">{{ fmtPrice(hit.lastPrice) }}</span>
        <span class="hit-pct" :class="pctClass(hit.changePct)">{{ fmtPct(hit.changePct) }}</span>
      </span>
    </button>
  </div>
</template>

<script setup lang="ts">
// k-hit-list：跑选股命中勾选列表（○/● + 名称/代码 + 最新价/涨跌幅；
// selected 数组由 adapter 维护，toggle 抛出 metaID）。
export interface HitRow {
  metaID: number
  code: string
  name: string
  lastPrice: number | null
  changePct: number | null
}

withDefaults(defineProps<{
  modelValue?: { rows?: HitRow[]; selected?: number[] }
}>(), {
  modelValue: () => ({ rows: [], selected: [] }),
})

const emit = defineEmits<{
  (e: 'toggle', metaID: number): void
}>()

// 行情格式化（与行情页同口径：价格两位 / 涨跌幅带符号，ratio ×100）
function fmtPrice(v: number | null): string {
  return v == null ? '—' : v.toFixed(2)
}
function fmtPct(v: number | null): string {
  if (v == null) return '—'
  const s = (v * 100).toFixed(2)
  return v > 0 ? `+${s}%` : `${s}%`
}
function pctClass(v: number | null): string {
  if (v == null || v === 0) return 'flat'
  return v > 0 ? 'up' : 'down'
}
</script>

<style scoped>
.hit-list {
  flex: 1;
  overflow-y: auto;
  padding-bottom: 8px;
}

.hit-row {
  display: flex;
  align-items: center;
  width: 100%;
  gap: 10px;
  padding: 0 16px;
  height: 48px;
  border: none;
  background: none;
  cursor: pointer;
  text-align: left;
}

.check {
  font-size: 16px;
  color: var(--k-text-tertiary, #c7c7cb);
  flex-shrink: 0;
}

.check.on {
  color: #1989fa;
}

.hit-name-block {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 2px;
  overflow: hidden;
}

.hit-name {
  font-size: 14px;
  font-weight: 500;
  color: var(--k-text, #000);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.hit-code {
  font-size: 11px;
  color: var(--k-text-tertiary, #c7c7cb);
}

.hit-price-block {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 2px;
  flex-shrink: 0;
}

.hit-price {
  font-size: 13px;
  font-weight: 500;
  color: var(--k-text, #000);
}

.hit-pct {
  font-size: 11px;
  color: var(--k-text-tertiary, #c7c7cb);
}

.hit-pct.up { color: #ee0a24; }
.hit-pct.down { color: #07c160; }
.hit-pct.flat { color: var(--k-text-tertiary, #c7c7cb); }
</style>

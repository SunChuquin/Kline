<template>
  <div class="card-list">
    <div v-if="rows.length === 0" class="list-empty">本会话暂无预警记录</div>
    <div v-else class="cond-list">
      <div v-for="(a, i) in rows" :key="i" class="cond-card">
        <div class="cond-line1">
          <span class="alert-bell">🔔</span>
          <span class="alert-date">训练日 {{ ymd(a.tradeDate) }}</span>
          <span class="alert-price">{{ a.price.toFixed(2) }}</span>
        </div>
        <div class="alert-msg">{{ a.message }}</div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
// k-alert-cards：训练明细预警记录卡片（🔔 + 训练日 + 触发价 + 消息）。
import { computed } from 'vue'

export interface AlertRow {
  tradeDate: number
  price: number
  message: string
}

const props = withDefaults(defineProps<{
  modelValue?: { rows?: AlertRow[] }
}>(), {
  modelValue: () => ({ rows: [] }),
})

const rows = computed(() => props.modelValue.rows ?? [])

function ymd(v: number | null): string {
  if (v === null || v <= 0) return '—'
  const s = String(v)
  return s.length === 8 ? `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}` : s
}
</script>

<style scoped>
.card-list {
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

.cond-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 12px;
}

.cond-card {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 10px;
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 5px;
}

.cond-line1 {
  display: flex;
  align-items: center;
  gap: 6px;
}

.alert-bell { font-size: 12px; }

.alert-date {
  font-size: 12px;
  font-weight: 600;
  color: var(--k-text, #000);
  flex: 1;
}

.alert-price {
  font-size: 12px;
  font-weight: 600;
  color: var(--k-text, #000);
}

.alert-msg {
  font-size: 12.5px;
  color: var(--k-text-secondary, #6c6c70);
  line-height: 1.4;
}
</style>

<template>
  <div class="card-list">
    <div v-if="rows.length === 0" class="list-empty">{{ emptyText }}</div>
    <div v-else class="cond-list">
      <div v-for="(c, i) in rows" :key="i" class="cond-card">
        <div class="cond-line1">
          <span class="kind-chip">{{ c.kindTitle }}</span>
          <span class="cond-summary">{{ c.summary }}</span>
          <span v-if="c.alertOnly" class="alert-badge">仅提醒</span>
          <span class="status-tag">{{ c.statusTitle }}</span>
        </div>
        <div class="cond-sub">创建训练日 {{ ymd(c.createdDate) }} · {{ c.validity }}</div>
        <div v-if="c.lastMessage" class="cond-msg">{{ c.lastMessage }}</div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
// k-cond-cards：训练明细条件单卡片（类型 chip + 摘要 + 仅提醒/状态标记；
// summary/validity 经引擎投影，未就绪为「…」占位）。
import { computed } from 'vue'

export interface CondRow {
  kindTitle: string
  statusTitle: string
  alertOnly: boolean
  createdDate: number
  summary: string
  validity: string
  lastMessage: string
}

const props = withDefaults(defineProps<{
  modelValue?: { rows?: CondRow[] }
  emptyText?: string
}>(), {
  modelValue: () => ({ rows: [] }),
  emptyText: '本会话暂无条件单',
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

.kind-chip {
  font-size: 11px;
  font-weight: 600;
  color: var(--k-accent, #007aff);
  background: rgba(0, 122, 255, 0.12);
  border-radius: 4px;
  padding: 2px 6px;
  flex-shrink: 0;
}

.cond-summary {
  flex: 1;
  font-size: 12.5px;
  color: var(--k-text, #000);
  line-height: 1.4;
}

.alert-badge {
  font-size: 11px;
  color: #ff9500;
  border: 1px solid #ff9500;
  border-radius: 4px;
  padding: 1px 5px;
  flex-shrink: 0;
}

.status-tag {
  font-size: 11px;
  color: var(--k-text-secondary, #6c6c70);
  background: var(--k-bg, #ffffff);
  border-radius: 4px;
  padding: 2px 6px;
  flex-shrink: 0;
}

.cond-sub {
  font-size: 11px;
  color: var(--k-text-secondary, #6c6c70);
}

.cond-msg {
  font-size: 11px;
  color: var(--k-text-secondary, #6c6c70);
  line-height: 1.4;
}
</style>

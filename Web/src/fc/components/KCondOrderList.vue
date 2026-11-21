<template>
  <div class="cond-list">
    <div v-for="o in modelValue.rows" :key="o.id" class="cond-card" @click="emit('open', o)">
      <div class="card-line1">
        <span class="c-name">{{ o.name }}</span>
        <span class="c-code">{{ o.code }}</span>
        <span v-if="o.isAlertOnly" class="alert-badge">提醒</span>
        <span class="status-tag" :class="o.status">{{ o.statusTitle }}</span>
        <button class="row-btn" :aria-label="`cond.edit.${o.name}`" @click.stop="emit('open', o)">编辑</button>
        <button v-if="o.showCancel" class="row-btn cancel" @click.stop="emit('cancel', o)">撤销</button>
      </div>
      <div class="card-line2">
        <span class="kind-chip">{{ o.kindTitle }}</span>
        <span class="c-summary">{{ o.conditionSummary }}</span>
      </div>
      <div class="card-line3">{{ o.directiveLine }}</div>
      <div v-if="o.repeatable && o.hasProgressTotal" class="progress-line">
        <div class="p-bar"><div class="p-fill" :style="{ width: pct(o) + '%' }"></div></div>
        <span class="p-text">{{ o.progressDone }} / {{ o.progressTotal }}</span>
      </div>
      <div v-if="o.lastMessage && o.status !== 'monitoring'" class="last-msg">{{ o.lastMessage }}</div>
    </div>
  </div>
</template>

<script setup lang="ts">
// k-cond-order-list：条件单管理卡片列表（状态标签 + 投影文案 + 进度条 + 编辑/撤销）。
// 哑组件：rows 由 adapter 按分段过滤注入；open/cancel 抛给 adapter 走 cond.edit/cancel。
export interface CondCardRow {
  id: string
  name: string
  code: string
  kindTitle: string
  status: string
  statusTitle: string
  isAlertOnly: boolean
  repeatable: boolean
  conditionSummary: string
  directiveLine: string
  progressDone: number
  progressTotal: number
  hasProgressTotal: boolean
  lastMessage: string
  showCancel: boolean
}

withDefaults(defineProps<{
  modelValue?: { rows?: CondCardRow[] }
}>(), {
  modelValue: () => ({ rows: [] }),
})

const emit = defineEmits<{
  (e: 'open', row: CondCardRow): void
  (e: 'cancel', row: CondCardRow): void
}>()

function pct(o: CondCardRow): number {
  if (!o.hasProgressTotal || o.progressTotal <= 0) return 0
  return Math.min(100, Math.round((o.progressDone / o.progressTotal) * 100))
}
</script>

<style scoped>
.cond-list {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.cond-card {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 10px;
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 6px;
  cursor: pointer;
}

.card-line1 {
  display: flex;
  align-items: center;
  gap: 6px;
}

.c-name {
  font-size: 14px;
  font-weight: 700;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.c-code {
  font-size: 11px;
  color: var(--k-text-secondary, #6c6c70);
}

.alert-badge {
  font-size: 10px;
  color: #ff9500;
  border: 1px solid #ff9500;
  border-radius: 4px;
  padding: 0 4px;
  flex-shrink: 0;
}

.status-tag {
  font-size: 10px;
  border-radius: 4px;
  padding: 1px 5px;
  background: var(--k-bg, #ffffff);
  color: var(--k-text-secondary, #6c6c70);
  flex-shrink: 0;
}

.status-tag.monitoring { color: #1989fa; }
.status-tag.triggered, .status-tag.completed { color: #00b578; }
.status-tag.expired, .status-tag.cancelled, .status-tag.rejected { color: var(--k-text-tertiary, #c7c7cb); }

.row-btn {
  width: 44px;
  height: 44px;
  border: none;
  background: none;
  color: #1989fa;
  font-size: 12px;
  cursor: pointer;
  flex-shrink: 0;
}

.row-btn.cancel { color: var(--k-text-tertiary, #c7c7cb); }

.card-line2 {
  display: flex;
  align-items: flex-start;
  gap: 6px;
}

.kind-chip {
  font-size: 11px;
  color: #1989fa;
  background: rgba(25, 137, 250, 0.08);
  border-radius: 4px;
  padding: 1px 6px;
  flex-shrink: 0;
}

.c-summary {
  font-size: 13px;
  color: var(--k-text, #000);
  line-height: 1.5;
  word-break: break-all;
}

.card-line3 {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
  line-height: 1.5;
  word-break: break-all;
}

.progress-line {
  display: flex;
  align-items: center;
  gap: 8px;
}

.p-bar {
  flex: 1;
  height: 6px;
  border-radius: 3px;
  background: var(--k-bg, #ffffff);
  overflow: hidden;
}

.p-fill {
  height: 100%;
  background: var(--k-accent, #1989fa);
  border-radius: 3px;
}

.p-text {
  font-size: 11px;
  color: var(--k-text-secondary, #6c6c70);
  font-variant-numeric: tabular-nums;
  flex-shrink: 0;
}

.last-msg {
  font-size: 11px;
  color: var(--k-text-secondary, #6c6c70);
  line-height: 1.5;
}
</style>

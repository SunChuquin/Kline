<template>
  <div class="session-list">
    <template v-for="(s, i) in modelValue.rows" :key="s.id">
      <div class="session-row">
        <div class="session-text">
          <div class="session-line1">
            <span class="session-name">{{ s.name }}</span>
            <span class="session-code">{{ s.code }}</span>
          </div>
          <div class="session-sub">{{ s.sub }}</div>
          <div class="session-time">{{ s.time }}</div>
        </div>
        <button class="row-btn" :aria-label="`trainingRecord.detail.${i}`" @click="emit('open', s, i)">›</button>
        <button class="row-btn" :aria-label="`trainingRecord.delete.${i}`" @click="emit('del', s, i)">🗑</button>
      </div>
      <div class="divider"></div>
    </template>
    <div style="height: 12px"></div>
  </div>
</template>

<script setup lang="ts">
// k-session-rows：训练记录会话行列表（名称/代码 + 起止·笔数·状态 + 时间 + 进入/删除）。
// sub/time 由 adapter 组装（ymd 格式化口径对齐原生）。
export interface SessionRow {
  id: string
  name: string
  code: string
  sub: string
  time: string
}

withDefaults(defineProps<{
  modelValue?: { rows?: SessionRow[] }
}>(), {
  modelValue: () => ({ rows: [] }),
})

const emit = defineEmits<{
  (e: 'open', row: SessionRow, index: number): void
  (e: 'del', row: SessionRow, index: number): void
}>()
</script>

<style scoped>
.session-list {
  flex: 1;
  overflow-y: auto;
}

.session-row {
  display: flex;
  align-items: center;
  gap: 4px;
  min-height: 78px;
  padding-left: 12px;
}

.session-text { flex: 1; min-width: 0; }

.session-line1 {
  display: flex;
  align-items: baseline;
  gap: 5px;
}

.session-name {
  font-size: 15px;
  color: var(--k-text, #000);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.session-code {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
}

.session-sub {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
  margin-top: 3px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.session-time {
  font-size: 11px;
  color: var(--k-text-tertiary, #c7c7cb);
  margin-top: 2px;
}

.row-btn {
  width: 44px;
  height: 44px;
  border: none;
  background: none;
  color: var(--k-text-tertiary, #c7c7cb);
  font-size: 15px;
  cursor: pointer;
}

.divider {
  height: 0.5px;
  background: var(--k-divider, #c6c6c8);
  margin-left: 12px;
}
</style>

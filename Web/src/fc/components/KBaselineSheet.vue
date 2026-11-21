<template>
  <div v-if="modelValue.show" class="bl-mask" @click.self="emit('close')">
    <div class="bl-popup">
      <div class="bl-head">
        <span class="bl-title">基准缺失名单</span>
        <button class="bl-done" @click="emit('close')">完成</button>
      </div>
      <div class="bl-summary">{{ modelValue.summary }}</div>
      <div class="bl-list">
        <div v-for="(it, i) in modelValue.items" :key="i" class="bl-item">
          <div class="bl-line1">
            <span class="bl-name">{{ it.name }}</span>
            <span class="bl-code">{{ it.code }}</span>
            <span class="bl-cause">{{ it.cause }}</span>
          </div>
          <div class="bl-file">{{ it.file }}</div>
        </div>
        <div v-if="modelValue.items.length === 0" class="bl-empty">（无记录）</div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
// k-baseline-sheet：基准缺失名单底部弹层（对齐原生 BaselineMissingSheet）。
// 哑组件：show/summary/items 由 adapter 从 update.snapshot 组装注入；完成按钮抛 close。
export interface BaselineItem {
  name: string
  code: string
  file: string
  cause: string
}

export interface BaselineSheetState {
  show: boolean
  summary: string
  items: BaselineItem[]
}

withDefaults(defineProps<{
  modelValue?: BaselineSheetState
}>(), {
  modelValue: () => ({ show: false, summary: '', items: [] }),
})

const emit = defineEmits<{
  (e: 'close'): void
}>()
</script>

<style scoped>
.bl-mask {
  position: fixed;
  inset: 0;
  z-index: 2000;
  background: rgba(0, 0, 0, 0.45);
  display: flex;
  align-items: flex-end;
}

.bl-popup {
  width: 100%;
  max-height: 70vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg, #ffffff);
  border-radius: 16px 16px 0 0;
  padding-bottom: 12px;
}

.bl-head {
  display: flex;
  align-items: center;
  padding: 14px 16px;
}

.bl-title {
  flex: 1;
  font-size: 16px;
  font-weight: 600;
  color: var(--k-text, #000);
}

.bl-done {
  border: none;
  background: none;
  color: var(--k-accent, #007aff);
  font-size: 15px;
  font-weight: 600;
  cursor: pointer;
}

.bl-summary {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
  padding: 0 16px 10px;
}

.bl-list {
  flex: 1;
  overflow-y: auto;
  padding: 0 16px 16px;
}

.bl-item {
  padding: 8px 0;
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
}

.bl-line1 {
  display: flex;
  align-items: baseline;
  gap: 8px;
}

.bl-name {
  font-size: 15px;
  font-weight: 500;
  color: var(--k-text, #000);
}

.bl-code {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
}

.bl-cause {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
  margin-left: auto;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.bl-file {
  font-size: 11px;
  color: var(--k-text-tertiary, #c7c7cb);
  margin-top: 2px;
  word-break: break-all;
}

.bl-empty {
  font-size: 13px;
  color: var(--k-text-tertiary, #c7c7cb);
  padding: 16px 0;
}
</style>

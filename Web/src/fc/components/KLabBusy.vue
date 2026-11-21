<template>
  <div v-if="modelValue.show" class="busy-hint">
    <span class="busy-spinner">◌</span>
    <span>{{ modelValue.text }}</span>
    <span v-if="modelValue.pct !== null && modelValue.pct !== undefined" class="busy-pct">{{ modelValue.pct }}%</span>
  </div>
</template>

<script setup lang="ts">
// k-lab-busy：引擎实验室忙指示行（说明当前阶段 + 可选下载进度，避免用户以为卡死）。
// 哑组件：show/text/pct 由 adapter 从 lab.snapshot 组装注入。
export interface LabBusyState {
  show: boolean
  text: string
  pct: number | null
}

withDefaults(defineProps<{
  modelValue?: LabBusyState
}>(), {
  modelValue: () => ({ show: false, text: '', pct: null }),
})
</script>

<style scoped>
.busy-hint {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
  color: var(--k-text-secondary, #6c6c70);
  padding: 6px 4px;
}

.busy-spinner {
  color: var(--k-accent, #007aff);
  animation: lab-spin 1s linear infinite;
}

@keyframes lab-spin {
  to { transform: rotate(360deg); }
}

.busy-pct {
  font-size: 12px;
  font-variant-numeric: tabular-nums;
}
</style>

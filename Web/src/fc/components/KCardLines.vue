<template>
  <div class="k-card" :aria-label="ariaLabel">
    <div v-if="modelValue.title" class="card-title">{{ modelValue.title }}</div>
    <template v-if="modelValue.linesBefore"><slot /></template>
    <div
      v-for="(line, i) in modelValue.lines"
      :key="i"
      class="card-line"
      :class="line.tone ?? 'text'"
    >
      <span v-if="line.idx" class="line-idx">{{ line.idx }}</span>
      <span class="line-text">{{ line.text }}</span>
    </div>
    <template v-if="!modelValue.linesBefore"><slot /></template>
  </div>
</template>

<script setup lang="ts">
// k-card-lines：信息卡（标题 + 多 tone 文本行 + 默认插槽）。linesBefore 控制插槽
// 渲染在文本行之前（入场单卡：开关行在前、说明在后）。
export interface CardLine {
  idx?: string
  text: string
  tone?: 'text' | 'rule' | 'sub' | 'sec' | 'warn' | 'err'
}

withDefaults(defineProps<{
  modelValue?: { title?: string; lines?: CardLine[]; linesBefore?: boolean }
  ariaLabel?: string
}>(), {
  modelValue: () => ({ lines: [] }),
  ariaLabel: '',
})
</script>

<style scoped>
.k-card {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 10px;
  padding: 12px;
  margin-bottom: 14px;
}

.card-title {
  font-size: 13px;
  font-weight: 600;
  color: var(--k-text, #000);
  margin-bottom: 8px;
}

.card-line {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  margin-top: 4px;
  word-break: break-all;
}

.line-idx {
  font-size: 13px;
  color: var(--k-text-tertiary, #c7c7cb);
  flex-shrink: 0;
}

.line-text {
  white-space: pre-wrap;
}

.card-line.text .line-text {
  font-size: 14px;
  line-height: 1.5;
  color: var(--k-text, #000);
}

.card-line.rule .line-text {
  font-size: 13px;
  line-height: 1.5;
  color: var(--k-text, #000);
}

.card-line.sub .line-text,
.card-line.sec .line-text {
  font-size: 12px;
  line-height: 1.5;
  color: var(--k-text-tertiary, #c7c7cb);
}

.card-line.sec .line-text {
  font-size: 13px;
}

.card-line.warn .line-text {
  font-size: 12px;
  line-height: 1.5;
  color: #ff9500;
}

.card-line.err .line-text {
  font-size: 12px;
  line-height: 1.5;
  color: #ee0a24;
}
</style>

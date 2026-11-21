<template>
  <div ref="outRef" class="out-console">
    <div v-if="modelValue.lines.length === 0" class="out-empty">（暂无输出）</div>
    <div v-for="(line, i) in modelValue.lines" :key="i" class="out-line">{{ line }}</div>
  </div>
</template>

<script setup lang="ts">
// k-out-console：实验输出控制台（等宽字体逐行展示，行数变化自动滚底，
// 对齐原生 ScrollViewReader.scrollTo）。
// 哑组件：lines 由 adapter 从 lab.snapshot 注入。
import { nextTick, ref, watch } from 'vue'

export interface OutConsoleState {
  lines: string[]
}

const props = withDefaults(defineProps<{
  modelValue?: OutConsoleState
}>(), {
  modelValue: () => ({ lines: [] }),
})

const outRef = ref<HTMLDivElement | null>(null)

watch(() => props.modelValue.lines.length, async () => {
  await nextTick()
  outRef.value?.scrollTo({ top: outRef.value.scrollHeight })
})
</script>

<style scoped>
.out-console {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 12px;
  padding: 10px;
  max-height: 280px;
  overflow-y: auto;
  font-family: ui-monospace, Menlo, monospace;
}

.out-empty {
  font-size: 12px;
  color: var(--k-text-tertiary, #c7c7cb);
}

.out-line {
  font-size: 11px;
  color: var(--k-text-secondary, #6c6c70);
  line-height: 1.5;
  word-break: break-all;
}
</style>

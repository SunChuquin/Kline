<template>
  <div v-if="rows.length > 0" class="skips-card">
    <button class="skip-toggle" @click="showSkips = !showSkips">
      跳过 {{ rows.length }} 条
      <span class="chev">{{ showSkips ? '▲' : '▼' }}</span>
    </button>
    <div v-if="showSkips">
      <div v-for="(s, i) in rows" :key="i" class="skip-row">{{ s.title }} —— {{ s.reason }}</div>
    </div>
  </div>
</template>

<script setup lang="ts">
// k-skip-list：生成确认跳过原因卡（折叠开关 + 标题——原因行，对齐原生）。
import { computed, ref } from 'vue'

export interface SkipRow {
  title: string
  reason: string
}

const props = withDefaults(defineProps<{
  modelValue?: { rows?: SkipRow[] }
}>(), {
  modelValue: () => ({}),
})

const showSkips = ref(false)
const rows = computed(() => props.modelValue.rows ?? [])
</script>

<style scoped>
.skips-card {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 10px;
  padding: 12px;
  margin-bottom: 14px;
}

.skip-toggle {
  display: flex;
  align-items: center;
  gap: 4px;
  border: none;
  background: none;
  color: #ff9500;
  font-size: 12.5px;
  font-weight: 500;
  cursor: pointer;
  padding: 4px 0;
}

.chev {
  font-size: 10px;
}

.skip-row {
  font-size: 12px;
  color: #ff9500;
  padding: 4px 0;
}
</style>

<template>
  <div class="entries">
    <button
      v-for="e in modelValue.entries"
      :key="e.id"
      class="entry-chip"
      :style="{ '--tint': e.tint }"
      @click="emit('open', e.id)"
    >
      <span class="entry-icon">
        <van-icon v-if="iconFor(e.id)" :name="iconFor(e.id)!" />
        <b v-else>{{ textIconFor(e.id) }}</b>
      </span>
      <span class="entry-title">{{ e.title }}</span>
      <span class="entry-subtitle">{{ e.subtitle }}</span>
    </button>
  </div>
</template>

<script setup lang="ts">
// k-home-entries：首页横滑快捷入口行（图标/文字图标 + 标题 + 副标题，对齐 HomeQuickEntryRow）。
// 迁移自 HomePage.vue 入口行区；入口清单由 adapter 注入，open(id) 抛给 adapter。
export interface HomeEntry {
  id: string
  title: string
  subtitle: string
  tint: string
}

withDefaults(defineProps<{
  modelValue?: { entries?: HomeEntry[] }
}>(), {
  modelValue: () => ({ entries: [] }),
})

const emit = defineEmits<{
  (e: 'open', id: string): void
}>()

// 入口图标映射（Vant 图标 + 文字替代；对齐 HomeEntryKind.icon 语义）
function iconFor(id: string): string | null {
  const map: Record<string, string> = {
    search: 'search',
    picker: 'filter-o',
    strategy: 'chart-trending-o',
    condOrder: 'bell',
    profile: 'user-circle-o',
    alertRecords: 'clock-o',
    training: 'medal-o',
    lanSync: 'exchange',
  }
  return map[id] ?? null
}

function textIconFor(id: string): string {
  if (id === 'tech') return 'ƒx'
  if (id === 'pythonLab') return 'Py'
  return '·'
}
</script>

<style scoped>
.entries {
  display: flex;
  gap: 12px;
  padding: 12px 16px;
  overflow-x: auto;
  white-space: nowrap;
  scrollbar-width: none;
}

.entries::-webkit-scrollbar {
  display: none;
}

.entry-chip {
  flex-shrink: 0;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 4px;
  min-width: 168px;
  min-height: 68px;
  border: none;
  border-radius: 12px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  text-align: left;
  padding: 10px 14px;
  cursor: pointer;
}

.entry-icon {
  font-size: 20px;
  color: var(--tint);
  line-height: 1;
}

.entry-icon b {
  font-size: 15px;
  font-weight: 700;
}

.entry-title {
  font-size: 13px;
  font-weight: 600;
}

.entry-subtitle {
  font-size: 11px;
  color: var(--k-text-secondary);
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 150px;
}
</style>

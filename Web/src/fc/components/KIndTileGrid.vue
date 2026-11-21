<template>
  <div class="ind-sections">
    <template v-for="(g, gi) in modelValue.sections" :key="g.title">
      <div class="sec-title">{{ g.title }}</div>
      <div class="ind-grid">
        <button
          v-for="t in g.tiles"
          :key="t.id"
          class="ind-tile"
          :class="{ on: t.on }"
          :aria-label="t.ariaLabel ?? t.label"
          @click="emit('toggle', t.id)"
        >
          <span v-if="modelValue.checkable" class="ind-check">{{ t.on ? '☑' : '☐' }}</span>
          <span class="ind-name">{{ t.label }}</span>
        </button>
      </div>
    </template>
    <div v-if="modelValue.sections.length === 0" class="block-empty">暂无指标</div>
  </div>
</template>

<script setup lang="ts">
// k-ind-tile-grid：指标 tile 网格（分节标题 + ☑/☐ 四列瓦片）。
// 哑组件：toggle(id) 抛给 adapter（主图勾选/副图单选由 adapter 分派写回）。
export interface IndTile {
  id: string
  label: string
  on: boolean
  ariaLabel?: string
}

export interface IndSection {
  title: string
  tiles: IndTile[]
}

withDefaults(defineProps<{
  modelValue?: { sections?: IndSection[]; checkable?: boolean }
}>(), {
  modelValue: () => ({ sections: [] }),
})

const emit = defineEmits<{
  (e: 'toggle', id: string): void
}>()
</script>

<style scoped>
.sec-title {
  font-size: 13px;
  color: var(--k-text-secondary, #6c6c70);
  padding: 8px 2px 6px;
}

.ind-grid {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  padding: 0 0 6px;
}

.ind-tile {
  flex: 1 1 calc(25% - 8px);
  min-width: 80px;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  border: 1px solid rgba(128, 128, 128, 0.25);
  border-radius: 8px;
  background: var(--k-bg-secondary, #f2f2f7);
  opacity: 0.45;
  color: var(--k-text, #000);
  font-size: 13px;
  padding: 12px 4px;
  cursor: pointer;
}

.ind-tile.on {
  opacity: 1;
  border-color: #1989fa;
  background: var(--k-bg-secondary, #f2f2f7);
  font-weight: 600;
  color: #1989fa;
}

.ind-check { font-size: 14px; }

.block-empty {
  font-size: 12px;
  color: var(--k-text-tertiary, #c7c7cb);
  padding: 8px 0;
}
</style>

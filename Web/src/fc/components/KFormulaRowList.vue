<template>
  <div class="formula-sections">
    <template v-for="g in modelValue.sections" :key="g.title">
      <div class="sec-title">{{ g.title }}</div>
      <div class="formula-rows">
        <div v-for="d in g.rows" :key="d.id" class="formula-row">
          <span class="q-name">{{ d.name }}</span>
          <button
            v-if="d.hasTemplate"
            class="tool-btn"
            :aria-label="`formulaCenter.edit.${d.name}`"
            @click="emit('edit', d)"
          >编辑</button>
        </div>
      </div>
    </template>
    <div v-if="modelValue.sections.length === 0" class="block-empty">暂无公式</div>
  </div>
</template>

<script setup lang="ts">
// k-formula-row-list：公式中心系统指标行（分组标题 + 名称 + 编辑按钮）。
export interface FormulaRow {
  id: string
  name: string
  hasTemplate: boolean
}

export interface FormulaSection {
  title: string
  rows: FormulaRow[]
}

withDefaults(defineProps<{
  modelValue?: { sections?: FormulaSection[] }
}>(), {
  modelValue: () => ({ sections: [] }),
})

const emit = defineEmits<{
  (e: 'edit', row: FormulaRow): void
}>()
</script>

<style scoped>
.sec-title {
  font-size: 13px;
  color: var(--k-text-secondary, #6c6c70);
  padding: 8px 2px 6px;
  font-weight: 600;
}

.formula-rows {
  display: flex;
  flex-direction: column;
}

.formula-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 40px;
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
}

.formula-row:last-child { border-bottom: none; }

.q-name {
  font-size: 14px;
  color: var(--k-text, #000);
}

.tool-btn {
  border: 1px solid var(--k-divider, #c6c6c8);
  border-radius: 6px;
  background: none;
  color: #1989fa;
  font-size: 12px;
  width: 44px;
  height: 28px;
  cursor: pointer;
}

.block-empty {
  font-size: 12px;
  color: var(--k-text-tertiary, #c7c7cb);
  padding: 8px 0;
}
</style>

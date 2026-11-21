<template>
  <div class="rule-list">
    <div v-for="(row, idx) in modelValue.rows" :key="idx" class="rule-card">
      <div class="rule-head">
        <select
          class="rule-kind"
          :value="row.kind"
          @change="emit('kindchange', { idx, kind: ($event.target as HTMLSelectElement).value })"
        >
          <option v-for="k in modelValue.catalog" :key="k.kind" :value="k.kind">{{ k.title }}</option>
        </select>
        <span class="rule-mapping">{{ row.mapping }}</span>
        <button class="rule-del" :aria-label="`strategyEditor.delRule.${idx}`" @click="emit('del', { idx })">🗑</button>
      </div>
      <div v-if="row.summary" class="sep-note">指令：{{ row.summary }}</div>
      <template v-if="row.specs.length > 0">
        <div v-for="spec in row.specs" :key="spec.key" class="param-row">
          <span class="param-cap">{{ spec.title }}</span>
          <select
            v-if="spec.type === 'option'"
            class="param-select"
            :value="spec.value"
            @change="emit('param', { idx, key: spec.key, value: ($event.target as HTMLSelectElement).value })"
          >
            <option value="">{{ spec.placeholder }}（未设置）</option>
            <option v-for="o in spec.options" :key="o" :value="o">{{ o }}</option>
          </select>
          <input
            v-else
            class="param-input"
            :value="spec.value"
            :inputmode="spec.type === 'integer' ? 'numeric' : (spec.type === 'text' ? 'text' : 'decimal')"
            :placeholder="spec.placeholder"
            @input="emit('param', { idx, key: spec.key, value: ($event.target as HTMLInputElement).value })"
          />
          <span v-if="spec.unit" class="t-unit">{{ spec.unit }}</span>
        </div>
      </template>
      <div v-else class="sep-note">Python 引擎计算中 参数加载中</div>
    </div>
    <div v-if="!modelValue.rows || modelValue.rows.length === 0" class="block-empty">{{ modelValue.emptyText ?? '还没有交易规则，点击右上「添加规则」新增一条' }}</div>
  </div>
</template>

<script setup lang="ts">
// k-rule-row-list：策略公式交易规则行（类型下拉 + 条件单映射 + 参数输入 + 删除）。
// 哑组件：rows/catalog 由 adapter 注入；kindchange/param/del 抛回 adapter 更新规则行。
export interface RuleParamSpecVM {
  key: string
  title: string
  type: string
  placeholder?: string
  options?: string[]
  unit?: string
  value: string
}

export interface RuleRowVM {
  kind: string
  mapping?: string
  summary?: string
  specs: RuleParamSpecVM[]
}

withDefaults(defineProps<{
  modelValue?: { rows?: RuleRowVM[]; catalog?: { kind: string; title: string }[]; emptyText?: string }
}>(), {
  modelValue: () => ({ rows: [], catalog: [] }),
})

const emit = defineEmits<{
  (e: 'kindchange', p: { idx: number; kind: string }): void
  (e: 'param', p: { idx: number; key: string; value: string }): void
  (e: 'del', p: { idx: number }): void
}>()
</script>

<style scoped>
.rule-list {
  display: flex;
  flex-direction: column;
  border-radius: 10px;
  background: var(--k-bg-secondary, #f2f2f7);
}

.rule-card {
  padding: 10px 12px;
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.rule-card:last-child { border-bottom: none; }

.rule-head {
  display: flex;
  align-items: center;
  gap: 8px;
}

.rule-kind {
  height: 44px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg, #ffffff);
  color: var(--k-text, #000);
  font-size: 13px;
  font-weight: 500;
  padding: 0 10px;
  outline: none;
}

.rule-mapping {
  flex: 1;
  font-size: 11px;
  color: var(--k-text-tertiary, #c7c7cb);
}

.rule-del {
  width: 44px;
  height: 44px;
  border: none;
  background: none;
  font-size: 14px;
  cursor: pointer;
}

.param-row {
  display: flex;
  align-items: center;
  gap: 8px;
}

.param-cap {
  width: 68px;
  font-size: 12px;
  color: var(--k-text, #000);
  flex-shrink: 0;
}

.param-select {
  height: 36px;
  min-width: 120px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg, #ffffff);
  color: var(--k-text, #000);
  font-size: 13px;
  padding: 0 8px;
  outline: none;
}

.param-input {
  height: 36px;
  width: 140px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg, #ffffff);
  color: var(--k-text, #000);
  font-size: 13px;
  padding: 0 8px;
  outline: none;
  box-sizing: border-box;
}

.t-unit {
  font-size: 13px;
  color: var(--k-text-tertiary, #c7c7cb);
}

.sep-note {
  font-size: 11px;
  color: var(--k-text-tertiary, #c7c7cb);
}

.block-empty {
  font-size: 12px;
  color: var(--k-text-tertiary, #c7c7cb);
  padding: 12px;
}
</style>

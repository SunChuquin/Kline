<template>
  <div class="ref-list">
    <button
      v-for="r in modelValue.rows"
      :key="r.id"
      class="ref-row"
      :class="{ archived: r.disabled }"
      :disabled="r.disabled"
      @click="emit('toggle', r.id)"
    >
      <span
        v-if="r.dotColor || r.dotText"
        class="acc-dot"
        :style="{ background: r.dotColor ? '#' + r.dotColor : 'transparent' }"
      >{{ r.dotText ?? '' }}</span>
      <span class="ref-text">
        <span class="ref-name" :class="{ dim: r.disabled }">{{ r.title }}</span>
        <span v-if="r.subtitle" class="ref-body">{{ r.subtitle }}</span>
      </span>
      <span v-if="r.trailing" class="archived-tag">{{ r.trailing }}</span>
      <span v-if="r.checked !== undefined" class="ref-check">{{ r.checked ? '☑' : '☐' }}</span>
    </button>
    <div v-if="!modelValue.rows || modelValue.rows.length === 0" class="block-empty">{{ modelValue.emptyText ?? '暂无数据' }}</div>
  </div>
</template>

<script setup lang="ts">
// k-ref-row-list：引用行列表（选股公式引用单选 / 绑定账户多选共用）。
// 色点徽标 + 名称 + 副标题 + 勾选态；toggle 抛给 adapter（单选/多选语义由 adapter 决定）。
export interface RefRow {
  id: string
  title: string
  subtitle?: string
  /** undefined = 不显示勾选位（已归档账户行） */
  checked?: boolean
  disabled?: boolean
  dotColor?: string
  dotText?: string
  trailing?: string
}

withDefaults(defineProps<{
  modelValue?: { rows?: RefRow[]; emptyText?: string }
}>(), {
  modelValue: () => ({ rows: [] }),
})

const emit = defineEmits<{
  (e: 'toggle', id: string): void
}>()
</script>

<style scoped>
.ref-list {
  border-radius: 10px;
  overflow: hidden;
  background: var(--k-bg-secondary, #f2f2f7);
}

.ref-row {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 10px;
  border: none;
  background: none;
  text-align: left;
  padding: 0 12px;
  min-height: 44px;
  cursor: pointer;
  color: var(--k-text, #000);
}

.ref-row:disabled { cursor: default; }

.ref-row.archived { opacity: 0.6; }

.ref-check {
  font-size: 16px;
  color: #1989fa;
  flex-shrink: 0;
}

.ref-text {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}

.ref-name {
  font-size: 14px;
  font-weight: 500;
  color: var(--k-text, #000);
}

.ref-name.dim { color: var(--k-text-tertiary, #c7c7cb); }

.ref-body {
  font-size: 11px;
  color: var(--k-text-tertiary, #c7c7cb);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.acc-dot {
  width: 24px;
  height: 24px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #ffffff;
  font-size: 11px;
  font-weight: 600;
  flex-shrink: 0;
}

.archived-tag {
  font-size: 11px;
  color: var(--k-text-tertiary, #c7c7cb);
  flex-shrink: 0;
}

.block-empty {
  font-size: 12px;
  color: var(--k-text-tertiary, #c7c7cb);
  padding: 12px;
}
</style>

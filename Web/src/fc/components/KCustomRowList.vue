<template>
  <div class="custom-rows">
    <div v-for="c in modelValue.rows" :key="c.id" class="custom-row">
      <button v-if="modelValue.showActivate !== false" class="custom-main" @click="emit('activate', c)">
        <span class="custom-check" :class="{ on: c.active }">{{ c.active ? '◉' : '○' }}</span>
        <span class="custom-color" :style="{ background: '#' + c.colorHex }"></span>
        <span class="custom-name">{{ c.name }}</span>
        <span v-if="c.active && modelValue.showCurrent" class="custom-current">当前</span>
        <span v-if="c.note" class="custom-note">{{ c.note }}</span>
      </button>
      <span v-else class="custom-main static">
        <span class="custom-color" :style="{ background: '#' + c.colorHex }"></span>
        <span class="custom-name">{{ c.name }}</span>
        <span v-if="c.note" class="custom-note">{{ c.note }}</span>
      </span>
      <button v-if="modelValue.showEdit" class="custom-edit" :aria-label="modelValue.editAria ? `${modelValue.editAria}.${c.name}` : `custom.edit.${c.name}`" @click="emit('edit', c)">✎</button>
      <button v-if="modelValue.showDelete" class="inline-btn cancel" :aria-label="modelValue.deleteAria ? `${modelValue.deleteAria}.${c.name}` : `custom.delete.${c.name}`" @click="emit('delete', c)">删除</button>
    </div>
    <div v-if="modelValue.rows.length === 0" class="block-empty">{{ modelValue.emptyText ?? '暂无数据' }}</div>
  </div>
</template>

<script setup lang="ts">
// k-custom-row-list：自定义指标/公式行列表（色条 + 名称 + 单选态 + 编辑）。
// 哑组件：activate/edit 抛给 adapter（激活互斥、删除、跳编辑器由 adapter 处理）。
export interface CustomRow {
  id: string
  name: string
  colorHex: string
  active: boolean
  note?: string
}

withDefaults(defineProps<{
  modelValue?: { rows?: CustomRow[]; showCurrent?: boolean; showActivate?: boolean; showEdit?: boolean; showDelete?: boolean; editAria?: string; deleteAria?: string; emptyText?: string }
}>(), {
  modelValue: () => ({ rows: [], showActivate: true, showEdit: true, showDelete: false }),
})

const emit = defineEmits<{
  (e: 'activate', row: CustomRow): void
  (e: 'edit', row: CustomRow): void
  (e: 'delete', row: CustomRow): void
}>()
</script>

<style scoped>
.custom-rows {
  display: flex;
  flex-direction: column;
}

.custom-row {
  display: flex;
  align-items: center;
  min-height: 42px;
}

.custom-main {
  flex: 1;
  display: flex;
  align-items: center;
  gap: 10px;
  border: none;
  background: none;
  color: var(--k-text, #000);
  font-size: 14px;
  padding: 9px 0;
  cursor: pointer;
  text-align: left;
}

.custom-check {
  font-size: 15px;
  color: var(--k-text-tertiary, #c7c7cb);
}

.custom-check.on { color: #1989fa; }

.custom-color {
  width: 14px;
  height: 5px;
  border-radius: 2px;
  flex-shrink: 0;
}

.custom-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.custom-current {
  font-size: 10px;
  color: #1989fa;
}

.custom-main.static {
  cursor: default;
}

.custom-note {
  font-size: 11px;
  color: var(--k-text-tertiary, #c7c7cb);
  margin-left: auto;
  flex-shrink: 0;
}

.custom-edit {
  width: 32px;
  height: 32px;
  border: none;
  background: none;
  color: var(--k-text-tertiary, #c7c7cb);
  font-size: 13px;
  cursor: pointer;
}

.inline-btn {
  width: 44px;
  height: 30px;
  flex-shrink: 0;
  border: 1px solid var(--k-divider, #c6c6c8);
  border-radius: 6px;
  background: none;
  color: #1989fa;
  font-size: 12px;
  cursor: pointer;
  margin-left: 6px;
}

.inline-btn.cancel {
  color: #ee0a24;
}

.block-empty {
  font-size: 12px;
  color: var(--k-text-tertiary, #c7c7cb);
  padding: 8px 0;
}
</style>

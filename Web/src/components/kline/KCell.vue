<template>
  <div
    class="k-cell"
    :class="{ 'k-cell--clickable': clickable }"
    :role="clickable ? 'button' : undefined"
    @click="clickable && emit('click')"
  >
    <div class="k-cell__label">
      <slot name="label">{{ label }}</slot>
    </div>
    <div class="k-cell__value">
      <slot name="value">{{ value }}</slot>
      <span v-if="arrow" class="k-cell__arrow">›</span>
    </div>
  </div>
</template>

<script setup lang="ts">
// KCell 设置行（label 左 / value+控件 右）
// 蓝本：Element Plus el-form-item 的 label/control 两栏布局规格。
// 适配：min-height 44px 触达规范；点击态整行命中（contentShape 等效）；
// value 槽位可放 KSwitch / KSelect 等控件或纯文本。
withDefaults(
  defineProps<{
    label?: string
    value?: string
    arrow?: boolean
    clickable?: boolean
  }>(),
  { label: '', value: '', arrow: false, clickable: false },
)

const emit = defineEmits<{ click: [] }>()
</script>

<style scoped>
.k-cell {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  min-height: 44px;
  font-size: 15px;
}

.k-cell--clickable {
  cursor: pointer;
}

.k-cell--clickable:active {
  opacity: 0.55;
}

.k-cell__label {
  color: var(--k-text);
  flex-shrink: 0;
}

.k-cell__value {
  display: flex;
  align-items: center;
  gap: 6px;
  color: var(--k-text-secondary);
  text-align: right;
}

.k-cell__arrow {
  font-size: 17px;
  font-weight: 600;
  color: var(--k-text-tertiary);
}
</style>

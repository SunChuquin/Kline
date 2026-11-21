<template>
  <div class="k-text-row">
    <span v-if="leftClickable" class="left click" :aria-label="leftAria" @click="emit('left')">{{ left }}</span>
    <span v-else class="left">{{ left }}</span>
    <span class="center" :class="centerTone">{{ center }}</span>
    <span class="right">{{ right }}</span>
  </div>
</template>

<script setup lang="ts">
// k-text-row：三段横排（左可点账户名 / 中数值 / 右说明）。
withDefaults(defineProps<{
  left?: string
  center?: string
  right?: string
  leftClickable?: boolean
  leftAria?: string
  centerTone?: '' | 'up' | 'down'
}>(), {
  left: '',
  center: '',
  right: '',
})

const emit = defineEmits<{
  (e: 'left'): void
}>()
</script>

<style scoped>
.k-text-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  font-size: 12px;
  padding: 6px 0;
}

.left {
  font-weight: 600;
  color: var(--k-accent, #007aff);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.left.click { cursor: pointer; }

.center {
  color: var(--k-text, #000);
  font-variant-numeric: tabular-nums;
}

.center.up { color: #ff4d4f; }
.center.down { color: #00b578; }

.right {
  color: var(--k-text-secondary, #6c6c70);
  flex-shrink: 0;
}
</style>

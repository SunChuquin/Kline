<template>
  <div class="nav-line">
    <button v-if="backLabel !== null" class="nav-link" :aria-label="backAria ?? 'page.back'" :disabled="backDisabled" @click="emit('back')">{{ backLabel }}</button>
    <span class="nav-center">{{ title }}</span>
    <span class="nav-right-slot">
      <span v-if="rightText && rightTone === 'plain'" class="nav-plain" :aria-label="rightAria">{{ rightText }}</span>
      <button
        v-else-if="rightText"
        class="nav-link"
        :class="{ danger: rightTone === 'danger' }"
        :aria-label="rightAria"
        :disabled="rightDisabled"
        @click="emit('right')"
      >{{ rightText }}</button>
      <span v-else style="width: 60px; display: inline-block"></span>
    </span>
  </div>
</template>

<script setup lang="ts">
// k-nav-row：全屏页页头（‹ 返回 ｜ 标题 ｜ 右动作）。backLabel=null 隐藏返回键。
// rightTone：默认黑字链接；danger 红字（清空等破坏性动作）；plain 纯文本（不可点）。
withDefaults(defineProps<{
  title: string
  backLabel?: string | null
  backAria?: string
  backDisabled?: boolean
  rightText?: string
  rightAria?: string
  rightDisabled?: boolean
  rightTone?: '' | 'danger' | 'plain'
}>(), {
  backLabel: '‹ 返回',
  backDisabled: false,
  rightDisabled: false,
  rightTone: '',
})

const emit = defineEmits<{
  (e: 'back'): void
  (e: 'right'): void
}>()
</script>

<style scoped>
.nav-line {
  display: flex;
  align-items: center;
  height: 48px;
  padding: 0 8px;
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
  flex-shrink: 0;
}

.nav-link {
  border: none;
  background: none;
  color: var(--k-text, #000);
  font-size: 15px;
  font-weight: 500;
  cursor: pointer;
  padding: 8px 10px;
}

.nav-link.danger {
  color: #ee0a24;
}

.nav-link:disabled {
  color: var(--k-text-tertiary, #c7c7cb);
  cursor: default;
}

.nav-plain {
  font-size: 13px;
  color: var(--k-text-secondary, #6c6c70);
  max-width: 140px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.nav-center {
  flex: 1;
  text-align: center;
  font-size: 16px;
  font-weight: 600;
  color: var(--k-text, #000);
}

.nav-right-slot {
  display: flex;
  justify-content: flex-end;
  min-width: 60px;
}
</style>

<template>
  <div class="nav-line">
    <button v-if="backLabel !== null" class="nav-link" :aria-label="backAria ?? 'page.back'" @click="emit('back')">{{ backLabel }}</button>
    <span class="nav-center">{{ title }}</span>
    <span class="nav-right-slot">
      <button v-if="rightText" class="nav-link" :aria-label="rightAria" @click="emit('right')">{{ rightText }}</button>
      <span v-else style="width: 60px; display: inline-block"></span>
    </span>
  </div>
</template>

<script setup lang="ts">
// k-nav-row：全屏页页头（‹ 返回 ｜ 标题 ｜ 右动作）。backLabel=null 隐藏返回键。
withDefaults(defineProps<{
  title: string
  backLabel?: string | null
  backAria?: string
  rightText?: string
  rightAria?: string
}>(), {
  backLabel: '‹ 返回',
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

<template>
  <div v-if="modelValue" class="toast-bar">{{ modelValue }}</div>
</template>

<script setup lang="ts">
// k-toast-bar：页内浅蓝提示条（生成成功 toast，text 为空时隐藏；对齐原生 showToast）。
withDefaults(defineProps<{
  modelValue?: string
}>(), {
  modelValue: '',
})
</script>

<style scoped>
.toast-bar {
  position: absolute;
  top: 52px;
  left: 16px;
  right: 16px;
  z-index: 10;
  padding: 10px 12px;
  border-radius: 8px;
  background: rgba(25, 137, 250, 0.14);
  color: #1989fa;
  font-size: 13px;
}
</style>

<template>
  <div v-show="modelValue" class="k-subpage">
    <slot />
  </div>
</template>

<script setup lang="ts">
// k-subpage：页内子页显隐包装（清单/确认、参数/进度/结果等多态页共用；
// v-show 保持子页挂载，adapter setValue 切换 field 值）。
withDefaults(defineProps<{
  modelValue?: boolean
}>(), {
  modelValue: false,
})
</script>

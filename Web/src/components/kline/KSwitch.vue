<template>
  <button
    class="k-switch"
    :class="{ 'k-switch--on': modelValue, 'k-switch--disabled': disabled }"
    type="button"
    :disabled="disabled"
    :aria-checked="modelValue"
    role="switch"
    @click="toggle"
  >
    <span class="k-switch__track"><span class="k-switch__thumb" /></span>
  </button>
</template>

<script setup lang="ts">
// KSwitch 开关
// 蓝本：Element Plus el-switch 的 on/off/disabled 三态语义与 aria-checked 可达性。
// 适配：视觉尺寸对齐 iOS UISwitch（51×31 轨道），外层按钮撑满 44px 命中区；
// 选中色用 --k-ok（绿）对齐系统开关观感。
const props = withDefaults(defineProps<{ modelValue?: boolean; disabled?: boolean }>(), {
  modelValue: false,
  disabled: false,
})

const emit = defineEmits<{ 'update:modelValue': [boolean]; change: [boolean] }>()

function toggle(): void {
  if (props.disabled) return
  const next = !props.modelValue
  emit('update:modelValue', next)
  emit('change', next)
}
</script>

<style scoped>
.k-switch {
  padding: 6px 0; /* 44px 命中区：31px 轨道 + 上下 6px */
  background: none;
  border: none;
  -webkit-tap-highlight-color: transparent;
  cursor: pointer;
}

.k-switch--disabled {
  opacity: 0.35;
}

.k-switch__track {
  display: flex;
  align-items: center; /* 垂直居中强制生效：真机 Safari 下 button 内 margin 布局有亚像素偏差 */
  width: 51px;
  height: 31px;
  border-radius: 15.5px;
  background: var(--k-divider);
  transition: background 0.2s ease;
}

.k-switch--on .k-switch__track {
  background: var(--k-ok);
}

.k-switch__thumb {
  display: block;
  flex-shrink: 0;
  width: 27px;
  height: 27px;
  margin-left: 2px;
  border-radius: 50%;
  background: #ffffff;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.25);
  transition: transform 0.2s ease;
}

.k-switch--on .k-switch__thumb {
  transform: translateX(20px);
}
</style>

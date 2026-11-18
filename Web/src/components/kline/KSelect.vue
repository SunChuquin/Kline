<template>
  <div class="k-select">
    <button class="k-select__trigger" type="button" :disabled="disabled" @click="open = true">
      <span class="k-select__label">{{ currentLabel }}</span>
      <span class="k-select__caret" :class="{ 'k-select__caret--open': open }">⌄</span>
    </button>

    <!-- 居中面板：对齐现有 FilterOptionsPanel / KlineThemeOptionsPanel 惯例
         （210pt 固定宽、行内 padding、checkmark 选中、底部「完成」、遮罩） -->
    <Teleport to="body">
      <transition name="k-select-fade">
        <div v-if="open" class="k-select__mask" @click.self="open = false">
          <div class="k-select__panel">
            <div class="k-select__options">
              <button
                v-for="opt in options"
                :key="String(opt.value)"
                class="k-select__option"
                type="button"
                @click="pick(opt.value)"
              >
                <span>{{ opt.label }}</span>
                <span v-if="opt.value === modelValue" class="k-select__check">✓</span>
              </button>
            </div>
            <button class="k-select__done" type="button" @click="open = false">完成</button>
          </div>
        </div>
      </transition>
    </Teleport>
  </div>
</template>

<script setup lang="ts">
// KSelect 下拉选择
// 蓝本：Element Plus el-select（options/modelValue/选中态语义）。
// 适配：浮层改为居中面板（触屏下拉浮层定位不稳），规格对齐项目既有
// 弹窗惯例（遮罩 black 25%、210pt 宽、行 padding 12/10、蓝 checkmark、底部「完成」）。
import { computed, ref } from 'vue'

export interface KSelectOption {
  label: string
  value: string | number
}

const props = withDefaults(
  defineProps<{
    options: KSelectOption[]
    modelValue: string | number
    disabled?: boolean
  }>(),
  { disabled: false },
)

const emit = defineEmits<{ 'update:modelValue': [string | number]; change: [string | number] }>()

const open = ref(false)
const currentLabel = computed(
  () => props.options.find((o) => o.value === props.modelValue)?.label ?? String(props.modelValue),
)

function pick(value: string | number): void {
  open.value = false
  if (value === props.modelValue) return
  emit('update:modelValue', value)
  emit('change', value)
}
</script>

<style scoped>
.k-select__trigger {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  min-height: 44px;
  padding: 0 2px;
  background: none;
  border: none;
  font-size: 14px;
  color: var(--k-accent);
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
}

.k-select__caret {
  font-size: 14px;
  transition: transform 0.15s ease;
}

.k-select__caret--open {
  transform: rotate(180deg);
}

.k-select__mask {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.25);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
}

.k-select__panel {
  width: 210px;
  background: var(--k-bg);
  border-radius: 12px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.2);
  overflow: hidden;
}

.k-select__options {
  max-height: 320px;
  overflow-y: auto;
}

.k-select__option {
  display: flex;
  align-items: center;
  justify-content: space-between;
  width: 100%;
  padding: 10px 12px;
  background: none;
  border: none;
  border-bottom: 1px solid var(--k-divider);
  font-size: 15px;
  color: var(--k-text);
  text-align: left;
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
}

.k-select__option:last-child {
  border-bottom: none;
}

.k-select__check {
  color: var(--k-accent);
  font-weight: 600;
}

.k-select__done {
  width: 100%;
  padding: 11px 0;
  background: none;
  border: none;
  border-top: 1px solid var(--k-divider);
  font-size: 15px;
  font-weight: 600;
  color: var(--k-accent);
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
}

.k-select-fade-enter-active,
.k-select-fade-leave-active {
  transition: opacity 0.15s ease-out;
}

.k-select-fade-enter-from,
.k-select-fade-leave-to {
  opacity: 0;
}
</style>

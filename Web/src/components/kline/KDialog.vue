<template>
  <Teleport to="body">
    <transition name="k-dialog-fade">
      <div v-if="open" class="k-dialog__mask" @click.self="dismiss">
        <div class="k-dialog__panel" :style="{ width: typeof width === 'number' ? width + 'px' : width }">
          <div v-if="title" class="k-dialog__title">{{ title }}</div>
          <div class="k-dialog__body"><slot /></div>
        </div>
      </div>
    </transition>
  </Teleport>
</template>

<script setup lang="ts">
// KDialog 居中弹窗容器
// 蓝本：Element Plus el-dialog（遮罩/居中/标题/受控 open 语义）。
// 适配：遮罩 black 25% + 点遮罩关闭、transition opacity 0.15s、
// 面板样式对齐项目弹窗惯例（systemBackground 底、cornerRadius 12、shadow）。
const props = withDefaults(
  defineProps<{
    open: boolean
    title?: string
    width?: number | string
    /** 点击遮罩是否关闭（默认开） */
    maskClose?: boolean
  }>(),
  { title: '', width: 320, maskClose: true },
)

const emit = defineEmits<{ 'update:open': [boolean]; close: [] }>()

function dismiss(): void {
  if (!props.maskClose) return
  emit('update:open', false)
  emit('close')
}
</script>

<style scoped>
.k-dialog__mask {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.25);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
}

.k-dialog__panel {
  max-width: calc(100vw - 32px);
  max-height: calc(100vh - 64px);
  overflow: hidden;
  background: var(--k-bg);
  border-radius: 12px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.2);
  display: flex;
  flex-direction: column;
}

.k-dialog__title {
  font-size: 15px;
  font-weight: 600;
  color: var(--k-text);
  padding: 14px 16px 8px;
}

.k-dialog__body {
  padding: 8px 16px 16px;
  overflow-y: auto;
}

.k-dialog-fade-enter-active,
.k-dialog-fade-leave-active {
  transition: opacity 0.15s ease-out;
}

.k-dialog-fade-enter-from,
.k-dialog-fade-leave-to {
  opacity: 0;
}
</style>

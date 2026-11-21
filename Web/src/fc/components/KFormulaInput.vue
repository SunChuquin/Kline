<template>
  <textarea
    ref="taEl"
    class="k-formula-input"
    :value="modelValue"
    :aria-label="ariaLabel"
    :placeholder="placeholder"
    :rows="rows"
    :style="{ minHeight }"
    spellcheck="false"
    autocapitalize="characters"
    autocorrect="off"
    @input="onInput"
  ></textarea>
</template>

<script setup lang="ts">
// k-formula-input：公式/选股公式多行输入（对齐原生 FormulaTextView：
// 等宽 + 输入自动转大写且光标不跳；insertReq/selectReq 驱动光标处插入与全选）。
import { nextTick, ref, watch } from 'vue'

const props = withDefaults(defineProps<{
  modelValue?: string
  ariaLabel?: string
  placeholder?: string
  rows?: number
  minHeight?: string
  /** 插入请求：seq 变化时在光标处插入 text（内容大写），完成后回抛 update:modelValue */
  insertReq?: { seq: number; text: string }
  /** 全选请求：seq 变化时聚焦并全选文本 */
  selectReq?: number
}>(), {
  modelValue: '',
  ariaLabel: '',
  placeholder: '',
  rows: 6,
  minHeight: '140px',
  insertReq: () => ({ seq: 0, text: '' }),
  selectReq: 0,
})

const emit = defineEmits<{
  (e: 'update:modelValue', v: string): void
}>()

const taEl = ref<HTMLTextAreaElement | null>(null)

function onInput(e: Event): void {
  const ta = e.target as HTMLTextAreaElement
  const pos = ta.selectionStart
  const up = ta.value.toUpperCase()
  if (up !== ta.value) {
    ta.value = up
    if (pos !== null) ta.setSelectionRange(pos, pos)
  }
  emit('update:modelValue', up)
}

watch(() => props.insertReq, (req) => {
  if (!req || !req.seq || !req.text) return
  const ta = taEl.value
  const cur = props.modelValue
  const start = ta?.selectionStart ?? cur.length
  const end = ta?.selectionEnd ?? start
  const next = cur.slice(0, start) + req.text + cur.slice(end)
  emit('update:modelValue', next)
  void nextTick(() => {
    const el = taEl.value
    if (!el) return
    el.focus()
    el.value = next
    const pos = start + req.text.length
    el.setSelectionRange(pos, pos)
  })
})

watch(() => props.selectReq, (seq) => {
  if (!seq) return
  const ta = taEl.value
  if (!ta) return
  ta.focus()
  ta.setSelectionRange(0, props.modelValue.length)
})
</script>

<style scoped>
.k-formula-input {
  width: 100%;
  min-height: 140px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg-secondary, #f2f2f7);
  color: var(--k-text, #000);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 13px;
  line-height: 1.5;
  padding: 8px;
  outline: none;
  resize: vertical;
  box-sizing: border-box;
  text-transform: uppercase;
}
</style>

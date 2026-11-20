<template>
  <div class="pep">
    <!-- 页头：返回（dirty 确认）｜ 标题 ｜ 保存（对齐原生选股编辑器头部动作） -->
    <div class="nav-line">
      <button class="nav-link" aria-label="pickerEdit.back" @click="onBack">‹ 返回</button>
      <span class="nav-center">选股公式</span>
      <button
        class="nav-link save"
        aria-label="pickerEdit.save"
        :disabled="!canSave"
        @click="save"
      >保存</button>
    </div>

    <template v-if="snap">
      <div class="pep-body">
        <!-- 工具条：全选 / 清空 / 测试公式（对齐原生 FormulaEditorView 工具条） -->
        <div class="pep-toolbar" aria-label="pickerEdit.toolbar">
          <button class="tool-link" @click="selectAll">全选</button>
          <button class="tool-link" @click="clearFormula">清空</button>
          <button class="tool-link" aria-label="pickerEdit.test" @click="runTest">测试公式</button>
        </div>

        <div class="pep-field">
          <div class="pep-label">名称</div>
          <input v-model="name" class="pep-input" placeholder="例如：放量突破" />
        </div>

        <!-- 公式（textarea 等价原生 UITextView：等宽 + 自动大写 + 光标处插入） -->
        <div class="pep-field">
          <div class="pep-label">选股公式</div>
          <textarea
            ref="formulaEl"
            class="pep-formula"
            :value="pickBody"
            aria-label="pickerEdit.formula"
            spellcheck="false"
            autocapitalize="characters"
            autocorrect="off"
            @input="onFormulaInput"
          ></textarea>
          <div class="pep-note">支持：MA/EMA/SMA/REF/HHV/LLV/ABS/MAX/MIN/SUM/STD/COUNT/IF/CROSS/BARSLAST/AND/OR/NOT，数据 C/H/L/O/V/AMOUNT，运算符 + - * / &lt; &gt; &lt;= &gt;= == !=</div>
          <div class="pep-note">最后一根输出值 &gt; 0 视为命中（公式选股口径）</div>
        </div>

        <!-- 常用符号（点击插入光标处） -->
        <div class="pep-field">
          <div class="pep-label">常用符号</div>
          <div class="chip-row">
            <button v-for="s in symbols" :key="s" class="chip mono" @click="insert(s)">{{ s }}</button>
          </div>
        </div>

        <!-- 测试结果（原文案展示，成功绿底 / 失败红底，对齐原生 testMessage） -->
        <div v-if="testMessage" class="pep-test" :class="{ err: testError }">{{ testMessage }}</div>
        <div style="height: 24px"></div>
      </div>
    </template>

    <div v-else class="pep-loading">加载中…</div>

    <!-- 取消确认（有未保存修改时，对齐原生「继续编辑/取消修改」对话框） -->
    <van-dialog
      v-model:show="confirmOpen"
      title="存在修改未保存，是否取消修改？"
      show-cancel-button
      cancel-button-text="继续编辑"
      confirm-button-text="取消修改"
      confirm-button-color="#ee0a24"
      @confirm="reallyClose"
    />
  </div>
</template>

<script setup lang="ts">
// P2-9c：选股公式编辑器 Web 页（pickerEditor）。编辑对象由原生 pickerEdit.snapshot
// 下发（id/name/pickBody）；公式文本为 Web 本地态，testPick 走 pickerEdit.testPick
// （异步，结果随 pickerEdit.changed(pickTest) 推送）；保存走 pickerEdit.save
// （同步写库，成功由原生关页）。极简形态对齐原生 FormulaEditorView isPicker 模式。
import { computed, nextTick, onMounted, ref } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { PickerEditSnapshot } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const snap = ref<PickerEditSnapshot | null>(null)
const formulaEl = ref<HTMLTextAreaElement | null>(null)

// 表单本地态（snapshot 初始化；原生同款字段）
const name = ref('')
const pickBody = ref('')
const testMessage = ref('')
const testError = ref(false)
const confirmOpen = ref(false)

const symbols = [':=', ';', ',', '：', '（', '）', '{', '}', '=', '+', '-', '!', '*', '/', '<', '>', 'AND', 'OR']

/** 名称与公式均非空才允许保存（对齐原生选股模式 canSave） */
const canSave = computed(() => {
  if (!snap.value) return false
  return name.value.trim().length > 0 && pickBody.value.trim().length > 0
})

/** 相对初始快照是否有未保存修改（对齐原生选股模式 hasChanges） */
const hasChanges = computed(() => {
  const s = snap.value
  if (!s) return false
  if (s.id === '') {
    return name.value.trim().length > 0 || pickBody.value.trim().length > 0
  }
  return name.value !== s.name || pickBody.value !== s.pickBody
})

async function pullSnapshot(): Promise<void> {
  try {
    const d = ((await klineBus.request('pickerEdit', 'snapshot')) ?? {}) as Record<string, unknown>
    snap.value = {
      id: String(d.id ?? ''),
      name: String(d.name ?? ''),
      pickBody: String(d.pickBody ?? ''),
      hasData: d.hasData === true,
    }
    name.value = snap.value.name
    pickBody.value = snap.value.pickBody
    testMessage.value = ''
    testError.value = false
  } catch (e) {
    console.error('pickerEdit.snapshot 失败', e)
  }
}

// ===== 公式输入（等价原生 FormulaTextView：输入自动转大写且光标不跳） =====
function onFormulaInput(e: Event): void {
  const el = e.target as HTMLTextAreaElement
  const pos = el.selectionStart
  const up = el.value.toUpperCase()
  if (up !== el.value) {
    el.value = up
    if (pos !== null) el.setSelectionRange(pos, pos)
  }
  pickBody.value = up
}

/** 光标处插入（等价 FormulaInputController.insert；插入内容均大写） */
function insert(text: string): void {
  if (!text) return
  const el = formulaEl.value
  const cur = pickBody.value
  const start = el?.selectionStart ?? cur.length
  const end = el?.selectionEnd ?? start
  pickBody.value = cur.slice(0, start) + text + cur.slice(end)
  void nextTick(() => {
    if (!el) return
    el.focus()
    const pos = start + text.length
    el.setSelectionRange(pos, pos)
  })
}

function selectAll(): void {
  const el = formulaEl.value
  if (!el) return
  el.focus()
  el.setSelectionRange(0, pickBody.value.length)
}

function clearFormula(): void {
  pickBody.value = ''
}

// ===== 动作 =====
function runTest(): void {
  testMessage.value = '计算中…'
  testError.value = false
  void klineBus.request('pickerEdit', 'testPick', { pickBody: pickBody.value }).catch((e) => {
    testMessage.value = `✗ ${String(e instanceof Error ? e.message : e).slice(0, 60)}`
    testError.value = true
  })
}

async function save(): Promise<void> {
  if (!canSave.value) return
  try {
    await klineBus.request('pickerEdit', 'save', {
      id: snap.value?.id ?? '',
      name: name.value.trim(),
      pickBody: pickBody.value,
    })
    // 成功后原生已关页（同步保存链路）；本地同步清理兜底
    emit('close')
  } catch (e) {
    testMessage.value = `✗ ${String(e instanceof Error ? e.message : e).slice(0, 60)}`
    testError.value = true
  }
}

function onBack(): void {
  if (hasChanges.value) {
    confirmOpen.value = true
  } else {
    reallyClose()
  }
}

function reallyClose(): void {
  emit('close')
}

function handleChanged(payload: Record<string, unknown> | undefined): void {
  const reason = String(payload?.['reason'] ?? '')
  if (reason === 'pickTest') {
    testMessage.value = String(payload?.['testMessage'] ?? '')
    testError.value = payload?.['testIsError'] === true
  } else if (reason === 'dataReady') {
    if (snap.value) snap.value.hasData = true
  }
}

onMounted(async () => {
  klineBus.on('pickerEdit.changed', (ev) => handleChanged(ev.payload))
  await pullSnapshot()
})
</script>

<style scoped>
.nav-line {
  display: flex;
  align-items: center;
  height: 48px;
  padding: 0 8px;
  border-bottom: 0.5px solid var(--k-border);
  flex-shrink: 0;
}

.nav-link {
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 15px;
  font-weight: 500;
  cursor: pointer;
  padding: 8px 10px;
}

.nav-link.save {
  color: #1989fa;
  font-weight: 600;
}

.nav-link.save:disabled {
  color: var(--k-text-tertiary);
  cursor: default;
}

.nav-center {
  flex: 1;
  text-align: center;
  font-size: 16px;
  font-weight: 600;
  color: var(--k-text);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.pep {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  color: var(--k-text);
}

.pep-toolbar {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 6px 12px;
  border-bottom: 0.5px solid var(--k-border);
  flex-shrink: 0;
}

.tool-link {
  border: none;
  background: none;
  color: #1989fa;
  font-size: 12px;
  cursor: pointer;
  padding: 6px 8px;
}

.pep-body {
  flex: 1;
  overflow-y: auto;
  padding: 12px 16px;
}

.pep-field {
  margin-bottom: 14px;
}

.pep-label {
  font-size: 13px;
  font-weight: 500;
  color: var(--k-text);
  margin-bottom: 6px;
}

.pep-input {
  width: 100%;
  height: 38px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 14px;
  padding: 0 10px;
  outline: none;
  box-sizing: border-box;
}

.pep-formula {
  width: 100%;
  min-height: 180px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 13px;
  line-height: 1.5;
  padding: 8px;
  outline: none;
  resize: vertical;
  box-sizing: border-box;
  text-transform: uppercase;
}

.pep-note {
  font-size: 10px;
  color: var(--k-text-tertiary);
  margin-top: 5px;
}

.chip-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
}

.chip {
  border: none;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 11px;
  height: 28px;
  padding: 0 10px;
  border-radius: 6px;
  cursor: pointer;
}

.chip.mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12px;
}

.pep-test {
  font-size: 12px;
  color: var(--k-text);
  padding: 8px;
  border-radius: 6px;
  background: rgba(0, 180, 100, 0.1);
  white-space: pre-wrap;
  word-break: break-all;
}

.pep-test.err {
  background: rgba(238, 10, 36, 0.1);
  color: #ee0a24;
}

.pep-loading {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  color: var(--k-text-tertiary);
}
</style>

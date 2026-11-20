<template>
  <div class="fep">
    <!-- 页头：返回（dirty 确认）｜ 标题 ｜ 保存（对齐原生 IndicatorEditSheet 头部动作） -->
    <div class="nav-line">
      <button class="nav-link" aria-label="formulaEditor.back" @click="onBack">‹ 返回</button>
      <span class="nav-center">公式编辑器[{{ snap?.displayName ?? '' }}]</span>
      <button
        class="nav-link save"
        aria-label="formulaEditor.save"
        :disabled="!canSave"
        @click="save"
      >保存</button>
    </div>

    <template v-if="snap">
      <!-- 工具条：全选 / 清空 / 测试公式 / 恢复编译时内容（仅系统指标） -->
      <div class="fep-toolbar" aria-label="formulaEditor.toolbar">
        <button class="tool-link" @click="selectAll">全选</button>
        <button class="tool-link" @click="clearFormula">清空</button>
        <button class="tool-link" aria-label="formulaEditor.test" @click="runTest">测试公式</button>
        <button
          v-if="snap.canRestoreBuiltin"
          class="tool-link restore"
          @click="restoreBuiltin"
        >恢复编译时内容</button>
      </div>

      <div class="fep-body">
        <!-- 名称 + 作用域 + 适用范围（系统指标模式隐藏，对齐原生 isSystemIndicator） -->
        <template v-if="snap.mode !== 'system'">
          <div class="fep-field">
            <div class="fep-label">名称</div>
            <input v-model="name" class="fep-input" placeholder="例如：双均线" />
          </div>
          <div class="fep-field">
            <div class="fep-label">作用域</div>
            <div class="chip-row">
              <button class="chip" :class="{ on: scope === 'main' }" @click="scope = 'main'">主图指标</button>
              <button class="chip" :class="{ on: scope === 'sub' }" @click="scope = 'sub'">副图指标</button>
            </div>
          </div>
          <div class="fep-field">
            <div class="fep-label">适用范围</div>
            <div class="chip-row">
              <button class="chip" :class="{ on: periods === null }" @click="periods = null">全周期</button>
              <button
                v-for="p in snap.periodOptions"
                :key="p"
                class="chip"
                :class="{ on: periods?.includes(p) }"
                @click="togglePeriod(p)"
              >{{ p }}</button>
            </div>
            <div class="fep-note">选择该指标可用的周期。不同周期各有一份独立参数副本（USER_&lt;名称&gt;.tdx），可单独编辑</div>
          </div>
        </template>

        <!-- 公式（textarea 等价原生 UITextView：等宽 + 自动大写 + 光标处插入） -->
        <div class="fep-field">
          <div class="fep-label">公式（{{ snap.period }}）</div>
          <textarea
            ref="formulaEl"
            class="fep-formula"
            :value="formula"
            aria-label="formulaEditor.formula"
            spellcheck="false"
            autocapitalize="characters"
            autocorrect="off"
            @input="onFormulaInput"
          ></textarea>
          <div class="fep-note">支持：MA/EMA/SMA/REF/HHV/LLV/ABS/MAX/MIN/SUM/STD/COUNT/IF/CROSS/BARSLAST/AND/OR/NOT，数据 C/H/L/O/V/AMOUNT，运算符 + - * / &lt; &gt; &lt;= &gt;= == !=</div>
        </div>

        <!-- 常用符号（点击插入光标处） -->
        <div class="fep-field">
          <div class="fep-label">常用符号</div>
          <div class="chip-row">
            <button v-for="s in symbols" :key="s" class="chip mono" @click="insert(s)">{{ s }}</button>
          </div>
        </div>

        <!-- 输出线条样式（系统指标模式隐藏；样式/粗细插入关键字，颜色插入 COLORXXX） -->
        <template v-if="snap.mode !== 'system'">
          <div class="fep-field">
            <div class="fep-label">输出线条样式（通达信选项）</div>
            <div class="chip-row">
              <span class="chip-cap">样式</span>
              <button
                v-for="st in styleChips"
                :key="st.value"
                class="chip"
                :class="{ on: style === st.value }"
                @click="pickStyle(st)"
              >{{ st.label }}</button>
            </div>
            <div class="chip-row">
              <span class="chip-cap">粗细</span>
              <button
                v-for="t in [1, 2, 3, 4]"
                :key="t"
                class="chip"
                :class="{ on: thickness === t }"
                @click="pickThickness(t)"
              >×{{ t }}</button>
            </div>
            <div class="color-grid">
              <button
                v-for="c in snap.palette"
                :key="c.option"
                class="color-cell"
                :style="{ background: '#' + c.hex }"
                :aria-label="`formulaEditor.color.${c.name}`"
                @click="insert(c.option)"
              ></button>
            </div>
            <div class="fep-note">点击样式/粗细/颜色会在光标处插入对应关键字，例如插入 DOTLINE / LINETHICK2 / COLORRED</div>
          </div>
        </template>

        <!-- 测试结果（原文案展示，成功绿底 / 失败红底，对齐原生 testMessage） -->
        <div v-if="testMessage" class="fep-test" :class="{ err: testError }">{{ testMessage }}</div>
        <div style="height: 24px"></div>
      </div>
    </template>

    <div v-else class="fep-loading">加载中…</div>

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
// P2-8a：tech 公式编辑器 Web 页（formulaEditor）。编辑对象与上下文由原生
// formulaEdit.snapshot 下发（system/custom(new|edit) 三形态）；公式文本/表单为
// Web 本地态，test/save/restoreBuiltin 走 formulaEdit.* 动作。保存成功由原生关页。
import { computed, nextTick, onMounted, ref } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { FormulaEditSnapshot } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const snap = ref<FormulaEditSnapshot | null>(null)
const formulaEl = ref<HTMLTextAreaElement | null>(null)

// 表单本地态（snapshot 初始化；原生同款字段）
const name = ref('')
const formula = ref('')
const scope = ref<'main' | 'sub'>('sub')
const colorHex = ref('1E88E5')
/** 适用周期集合；null = 全周期（协议语义对齐原生 applicablePeriods = nil） */
const periods = ref<string[] | null>(null)
const style = ref<'solid' | 'dotline' | 'pointdot' | 'stick' | 'nodraw'>('solid')
const thickness = ref(1)
const testMessage = ref('')
const testError = ref(false)
const confirmOpen = ref(false)

const symbols = [':=', ';', ',', '：', '（', '）', '{', '}', '=', '+', '-', '!', '*', '/', '<', '>', 'AND', 'OR']

const styleChips = [
  { value: 'solid', label: '实线', keyword: '' },
  { value: 'dotline', label: '虚线', keyword: 'DOTLINE' },
  { value: 'pointdot', label: '圆点', keyword: 'POINTDOT' },
  { value: 'stick', label: '柱状', keyword: 'STICK' },
  { value: 'nodraw', label: '不绘制', keyword: 'NODRAW' },
] as const

/** 名称与公式均非空才允许保存（系统指标只看公式，对齐原生 canSave） */
const canSave = computed(() => {
  if (!snap.value) return false
  const f = formula.value.trim().length > 0
  if (snap.value.mode === 'system') return f
  return name.value.trim().length > 0 && f
})

/** 周期集合无序比较（用户 toggle 顺序与快照顺序无关） */
function samePeriods(a: string[] | null, b: string[] | null): boolean {
  if ((a === null) !== (b === null)) return false
  if (a === null || b === null) return true
  return a.length === b.length && [...a].sort().join(',') === [...b].sort().join(',')
}

/** 相对初始快照是否有未保存修改（对齐原生 hasChanges） */
const hasChanges = computed(() => {
  const s = snap.value
  if (!s) return false
  if (s.mode === 'system') return formula.value !== s.formula
  if (s.mode === 'new') {
    return name.value.trim().length > 0 || formula.value.trim().length > 0
  }
  return name.value !== s.name
    || formula.value !== s.formula
    || scope.value !== s.scope
    || colorHex.value !== s.colorHex
    || !samePeriods(periods.value, s.periods)
})

async function pullSnapshot(): Promise<void> {
  try {
    const d = ((await klineBus.request('formulaEdit', 'snapshot')) ?? {}) as Record<string, unknown>
    snap.value = {
      mode: (d.mode as FormulaEditSnapshot['mode']) ?? 'new',
      displayName: String(d.displayName ?? ''),
      isMain: d.isMain === true,
      name: String(d.name ?? ''),
      formula: String(d.formula ?? ''),
      scope: d.scope === 'main' ? 'main' : 'sub',
      colorHex: String(d.colorHex ?? '1E88E5'),
      periods: (d.periods ?? null) as string[] | null,
      canRestoreBuiltin: d.canRestoreBuiltin === true,
      period: String(d.period ?? ''),
      periodOptions: (d.periodOptions ?? []) as string[],
      hasData: d.hasData === true,
      palette: (d.palette ?? []) as FormulaEditSnapshot['palette'],
    }
    name.value = snap.value.name
    formula.value = snap.value.formula
    scope.value = snap.value.scope
    colorHex.value = snap.value.colorHex
    periods.value = snap.value.periods
    testMessage.value = ''
    testError.value = false
  } catch (e) {
    console.error('formulaEdit.snapshot 失败', e)
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
  formula.value = up
}

/** 光标处插入（等价 FormulaInputController.insert；插入内容均大写） */
function insert(text: string): void {
  if (!text) return
  const el = formulaEl.value
  const cur = formula.value
  const start = el?.selectionStart ?? cur.length
  const end = el?.selectionEnd ?? start
  formula.value = cur.slice(0, start) + text + cur.slice(end)
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
  el.setSelectionRange(0, formula.value.length)
}

function clearFormula(): void {
  formula.value = ''
}

// ===== 适用范围（对齐原生 toggleApplicable：全周期 null ↔ 周期集合） =====
function togglePeriod(p: string): void {
  const cur = periods.value
  if (cur === null) {
    periods.value = [p]
  } else if (cur.includes(p)) {
    periods.value = cur.filter((x) => x !== p)
  } else {
    periods.value = [...cur, p]
  }
}

// ===== 线条样式 chips（本地选中态 + 光标处插入关键字，对齐原生 styleChip/appendOption） =====
function pickStyle(chip: (typeof styleChips)[number]): void {
  style.value = chip.value
  insert(chip.keyword)
}

function pickThickness(t: number): void {
  thickness.value = t
  insert(t === 1 ? '' : `LINETHICK${t}`)
}

// ===== 动作 =====
function runTest(): void {
  testMessage.value = '计算中…'
  testError.value = false
  void klineBus.request('formulaEdit', 'test', { formula: formula.value }).catch((e) => {
    testMessage.value = `✗ ${String(e instanceof Error ? e.message : e).slice(0, 60)}`
    testError.value = true
  })
}

async function restoreBuiltin(): Promise<void> {
  try {
    const d = (await klineBus.request('formulaEdit', 'restoreBuiltin', {})) as Record<string, unknown>
    formula.value = String(d.formula ?? formula.value)
    testMessage.value = ''
    testError.value = false
  } catch (e) {
    console.error('formulaEdit.restoreBuiltin 失败', e)
  }
}

async function save(): Promise<void>
{
  if (!canSave.value) return
  const payload: Record<string, unknown> = { formula: formula.value }
  if (snap.value?.mode !== 'system') {
    payload.name = name.value.trim()
    payload.scope = scope.value
    payload.colorHex = colorHex.value
    payload.periods = periods.value
  }
  try {
    await klineBus.request('formulaEdit', 'save', payload)
    // 成功后原生已关页（保存即关闭，对齐原生公式中心）；本地同步清理兜底
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
  if (reason === 'testResult') {
    testMessage.value = String(payload?.['message'] ?? '')
    testError.value = payload?.['isError'] === true
  } else if (reason === 'dataReady') {
    if (snap.value) snap.value.hasData = true
  }
}

onMounted(async () => {
  klineBus.on('formulaEdit.changed', (ev) => handleChanged(ev.payload))
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

.fep {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  color: var(--k-text);
}

.fep-toolbar {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 6px 12px;
  border-bottom: 0.5px solid var(--k-border);
  flex-shrink: 0;
  flex-wrap: wrap;
}

.tool-link {
  border: none;
  background: none;
  color: #1989fa;
  font-size: 12px;
  cursor: pointer;
  padding: 6px 8px;
}

.tool-link.restore {
  color: #ff9500;
}

.fep-body {
  flex: 1;
  overflow-y: auto;
  padding: 12px 16px;
}

.fep-field {
  margin-bottom: 14px;
}

.fep-label {
  font-size: 13px;
  font-weight: 500;
  color: var(--k-text);
  margin-bottom: 6px;
}

.fep-input {
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

.fep-formula {
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

.fep-note {
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

.chip-cap {
  font-size: 11px;
  color: var(--k-text-tertiary);
  flex-shrink: 0;
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

.chip.on {
  background: #1989fa;
  color: #ffffff;
  font-weight: 600;
}

.color-grid {
  display: grid;
  grid-template-columns: repeat(9, 1fr);
  gap: 6px;
  margin-top: 8px;
}

.color-cell {
  height: 24px;
  border: 1px solid rgba(128, 128, 128, 0.3);
  border-radius: 5px;
  cursor: pointer;
  padding: 0;
}

.fep-test {
  font-size: 12px;
  color: var(--k-text);
  padding: 8px;
  border-radius: 6px;
  background: rgba(0, 180, 100, 0.1);
  white-space: pre-wrap;
  word-break: break-all;
}

.fep-test.err {
  background: rgba(238, 10, 36, 0.1);
  color: #ee0a24;
}

.fep-loading {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  color: var(--k-text-tertiary);
}
</style>

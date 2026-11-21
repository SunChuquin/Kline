// fc/adapters/page-formulaEditor.ts：tech 公式编辑器（page-formulaEditor）逻辑适配器。
// 快照：formulaEdit.snapshot（system/custom(new|edit) 三形态）；公式文本/表单为
// Web 本地态；test/save/restoreBuiltin 走 formulaEdit.* 动作；保存成功由原生关页。
import { klineBus } from '../../bridge/klineBus'
import type { BridgeEvent } from '../../types/protocol'
import type { FormulaEditSnapshot } from '../../types/protocol'
import type { FcApi, FcPageAdapter, HostContext } from '../types'
import { patchRule } from '../rule-patch'

let snap: FormulaEditSnapshot | null = null
let nameStr = ''
let formula = ''
let scope: 'main' | 'sub' = 'sub'
let colorHex = '1E88E5'
/** 适用周期集合；null = 全周期（协议语义对齐原生 applicablePeriods = nil） */
let periods: string[] | null = null
let style: 'solid' | 'dotline' | 'pointdot' | 'stick' | 'nodraw' = 'solid'
let thickness = 1
let testMessage = ''
let testIsError = false
let selectReqSeq = 0
let insertReqSeq = 0
let ctxRef: HostContext | null = null

const STYLE_KEYWORDS: Record<string, string> = {
  solid: '',
  dotline: 'DOTLINE',
  pointdot: 'POINTDOT',
  stick: 'STICK',
  nodraw: 'NODRAW',
}

/** 名称与公式均非空才允许保存（系统指标只看公式，对齐原生 canSave） */
function canSave(): boolean {
  if (!snap) return false
  const f = formula.trim().length > 0
  if (snap.mode === 'system') return f
  return nameStr.trim().length > 0 && f
}

/** 周期集合无序比较（用户 toggle 顺序与快照顺序无关） */
function samePeriods(a: string[] | null, b: string[] | null): boolean {
  if ((a === null) !== (b === null)) return false
  if (a === null || b === null) return true
  return a.length === b.length && [...a].sort().join(',') === [...b].sort().join(',')
}

/** 相对初始快照是否有未保存修改（对齐原生 hasChanges） */
function hasChanges(): boolean {
  const s = snap
  if (!s) return false
  if (s.mode === 'system') return formula !== s.formula
  if (s.mode === 'new') {
    return nameStr.trim().length > 0 || formula.trim().length > 0
  }
  return nameStr !== s.name
    || formula !== s.formula
    || scope !== s.scope
    || colorHex !== s.colorHex
    || !samePeriods(periods, s.periods)
}

function setRowHidden(api: FcApi, name: string, hidden: boolean): void {
  patchRule(api, name, { style: { display: hidden ? 'none' : '' } })
}

function chipVal(api: FcApi, name: string, value: string): void {
  patchRule(api, name, { props: { modelValue: value } })
}

function syncTestMsg(api: FcApi): void {
  patchRule(api, 'testMsg', {
    props: { text: testMessage, danger: testIsError, plain: !testIsError },
    style: { display: testMessage ? '' : 'none' },
  })
}

function syncSave(api: FcApi): void {
  patchRule(api, 'navRow', { props: { rightDisabled: !canSave() } })
}

function syncChips(api: FcApi): void {
  chipVal(api, 'styleChips', style)
  chipVal(api, 'thicknessChips', String(thickness))
}

/** 工具条选项：恢复编译时内容仅系统指标（canRestoreBuiltin） */
function syncToolbar(api: FcApi): void {
  const options: { label: string; value: string; ariaLabel?: string }[] = [
    { label: '全选', value: 'selectAll' },
    { label: '清空', value: 'clearPick' },
    { label: '测试公式', value: 'runTest', ariaLabel: 'formulaEditor.test' },
  ]
  if (snap?.canRestoreBuiltin) options.push({ label: '恢复编译时内容', value: 'restore' })
  patchRule(api, 'toolChips', { props: { options } })
}

/** 光标处插入（经 k-formula-input insertReq 驱动，插入内容大写） */
function insert(api: FcApi, text: string): void {
  if (!text) return
  insertReqSeq += 1
  patchRule(api, 'formulaInput', { props: { insertReq: { seq: insertReqSeq, text } } })
}

async function pull(api: FcApi, ctx: HostContext): Promise<void> {
  ctxRef = ctx
  try {
    const d = ((await klineBus.request('formulaEdit', 'snapshot')) ?? {}) as Record<string, unknown>
    snap = {
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
    nameStr = snap.name
    formula = snap.formula
    scope = snap.scope
    colorHex = snap.colorHex
    periods = snap.periods
    testMessage = ''
    testIsError = false
    // 页头/分节文案
    patchRule(api, 'navRow', { props: { title: `公式编辑器[${snap.displayName}]` } })
    patchRule(api, 'formulaCap', { props: { text: `公式（${snap.period}）` } })
    // 适用周期选项（全周期 + 各周期）
    patchRule(api, 'periodChips', {
      props: {
        multiple: true,
        options: [
          { label: '全周期', value: '__all__' },
          ...snap.periodOptions.map((p) => ({ label: p, value: p })),
        ],
      },
    })
    // 调色网格
    api.setValue({
      name: nameStr,
      formula,
      scope,
      periodChips: periods === null ? ['__all__'] : [...periods],
      colorGrid: { colors: snap.palette },
      confirmOpen: false,
    })
    syncToolbar(api)
    syncChips(api)
    syncTestMsg(api)
    syncSave(api)
    // 系统指标模式隐藏名称/作用域/适用范围/线条样式（对齐原生 isSystemIndicator）
    const system = snap.mode === 'system'
    setRowHidden(api, 'nameRow', system)
    setRowHidden(api, 'scopeRow', system)
    setRowHidden(api, 'periodRow', system)
    setRowHidden(api, 'styleSection', system)
  } catch (e) {
    console.error('formulaEdit.snapshot 失败', e)
  }
}

function runTest(api: FcApi): void {
  testMessage = '计算中…'
  testIsError = false
  syncTestMsg(api)
  void klineBus.request('formulaEdit', 'test', { formula }).catch((e) => {
    testMessage = `✗ ${String(e instanceof Error ? e.message : e).slice(0, 60)}`
    testIsError = true
    syncTestMsg(api)
  })
}

async function restoreBuiltin(api: FcApi): Promise<void> {
  try {
    const d = (await klineBus.request('formulaEdit', 'restoreBuiltin', {})) as Record<string, unknown>
    formula = String(d.formula ?? formula)
    api.setValue({ formula })
    testMessage = ''
    testIsError = false
    syncTestMsg(api)
    syncSave(api)
  } catch (e) {
    console.error('formulaEdit.restoreBuiltin 失败', e)
  }
}

async function save(api: FcApi): Promise<void> {
  if (!canSave()) return
  const payload: Record<string, unknown> = { formula }
  if (snap?.mode !== 'system') {
    payload.name = nameStr.trim()
    payload.scope = scope
    payload.colorHex = colorHex
    payload.periods = periods
  }
  try {
    await klineBus.request('formulaEdit', 'save', payload)
    // 成功后原生已关页（保存即关闭，对齐原生公式中心）；本地同步清理兜底
    ctxRef?.close()
  } catch (e) {
    testMessage = `✗ ${String(e instanceof Error ? e.message : e).slice(0, 60)}`
    testIsError = true
    syncTestMsg(api)
  }
}

function handleChanged(api: FcApi, payload: Record<string, unknown> | undefined): void {
  const reason = String(payload?.['reason'] ?? '')
  if (reason === 'testResult') {
    testMessage = String(payload?.['message'] ?? '')
    testIsError = payload?.['isError'] === true
    syncTestMsg(api)
  } else if (reason === 'dataReady') {
    if (snap) snap.hasData = true
  }
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    onBack: (inj) => {
      if (hasChanges()) inj.api.setValue({ confirmOpen: true })
      else ctxRef?.close()
    },

    pickTool: (inj) => {
      const tool = String(inj.args[0] ?? '')
      const api = inj.api
      if (tool === 'selectAll') {
        selectReqSeq += 1
        patchRule(api, 'formulaInput', { props: { selectReq: selectReqSeq } })
      } else if (tool === 'clearPick') {
        formula = ''
        api.setValue({ formula })
        testMessage = ''
        testIsError = false
        syncTestMsg(api)
        syncSave(api)
      } else if (tool === 'runTest') {
        runTest(api)
      } else if (tool === 'restore') {
        void restoreBuiltin(api)
      }
    },

    insertSymbol: (inj) => {
      insert(inj.api, String(inj.args[0] ?? ''))
    },

    pickStyle: (inj) => {
      const v = String(inj.args[0] ?? '') as typeof style
      if (!(v in STYLE_KEYWORDS)) return
      style = v
      syncChips(inj.api)
      insert(inj.api, STYLE_KEYWORDS[v])
    },

    pickThickness: (inj) => {
      const t = Number(inj.args[0] ?? 0)
      if (![1, 2, 3, 4].includes(t)) return
      thickness = t
      syncChips(inj.api)
      insert(inj.api, t === 1 ? '' : `LINETHICK${t}`)
    },

    colorPick: (inj) => {
      insert(inj.api, String(inj.args[0] ?? ''))
    },

    save: (inj) => {
      void save(inj.api)
    },
  },

  onChange: (field, value, api) => {
    if (field === 'name') {
      nameStr = String(value ?? '')
      syncSave(api)
      return
    }
    if (field === 'formula') {
      formula = String(value ?? '')
      syncSave(api)
      return
    }
    if (field === 'scope') {
      scope = value === 'main' ? 'main' : 'sub'
      return
    }
    if (field === 'periodChips') {
      const arr = Array.isArray(value) ? value.map(String) : []
      // 全周期互斥：含 __all__ → null；否则周期集合（[] 保留，协议语义对齐原生）
      periods = arr.includes('__all__') ? null : arr
      const stabilized = periods === null ? ['__all__'] : [...periods]
      if (JSON.stringify(stabilized) !== JSON.stringify(value)) {
        api.setValue({ periodChips: stabilized })
      }
    }
  },

  subscribe: (api, ctx) => {
    ctxRef = ctx
    // testResult / dataReady 推送（陈旧 api 静默跳过）
    const handler = (ev: BridgeEvent): void => {
      try {
        handleChanged(api, ev.payload)
      } catch (e) {
        console.warn('[fc] formulaEditor changed 跳过（面板可能已关闭）', e)
      }
    }
    klineBus.on('formulaEdit.changed', handler)
    return () => {}
  },
}

export default adapter

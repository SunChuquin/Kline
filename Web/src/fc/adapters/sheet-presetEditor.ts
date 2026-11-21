// fc/adapters/sheet-presetEditor.ts：指标组合编辑页（sheet-presetEditor）逻辑适配器。
// preset.snapshot 一次下发五套组合完整按周期配置 + 全周期指标目录；本地深拷贝编辑
// （组合 tab × 周期 tab × 主图多选 / 主图自定义单选 / 三副图单选），保存 preset.editCommit 整包提交。
import { klineBus } from '../../bridge/klineBus'
import type { FcApi, FcInject, FcPageAdapter, HostContext } from '../types'

interface PresetSnap {
  id: string
  name: string
  mainIndicatorsByPeriod: Record<string, string[]>
  activeCustomByPeriod: Record<string, string>
  subSelectionsByPeriod: Record<string, { kind: string; customID: string }[]>
}
interface CatalogPeriod {
  period: string
  mainDefs: { id: string; name: string }[]
  subGroups: { group: string; kinds: string[] }[]
  customs: { id: string; name: string; colorHex: string; scope: 'main' | 'sub' }[]
}

const SLOT_KEYS = ['top', 'bottom', 'third'] as const
const SLOT_DEFAULTS: Record<string, string> = { top: 'CDJ', bottom: 'COL', third: 'MACD' }

let snap: { mode: string; presets: PresetSnap[]; catalog: { periods: CatalogPeriod[] } } | null = null
let draft: PresetSnap[] = []
let activePresetID = 'p1'
let activePeriod = '日线'
let expandedSlot = -1
let ctxRef: HostContext | null = null

function activePreset(): PresetSnap | undefined {
  return draft.find((p) => p.id === activePresetID) ?? draft[0]
}

function activeCatalog(): CatalogPeriod | undefined {
  return snap?.catalog.periods.find((c) => c.period === activePeriod) ?? snap?.catalog.periods[0]
}

function setRowHidden(api: FcApi, name: string, hidden: boolean): void {
  api.updateRule(name, { style: { display: hidden ? 'none' : '' } })
}

/** 主图启用集合（缺 key 以默认 MA+CMK 初始化口径展示） */
function mainSet(): string[] {
  const p = activePreset()
  const cat = activeCatalog()
  const explicit = p?.mainIndicatorsByPeriod[activePeriod]
  if (explicit) return explicit
  return (cat?.mainDefs ?? []).filter((d) => ['MA', 'CMK'].includes(d.id)).map((d) => d.id)
}

function activeCustomID(): string {
  return activePreset()?.activeCustomByPeriod[activePeriod] ?? ''
}

function slotSelection(idx: number): { kind: string; customID: string } {
  const p = activePreset()
  const sels = p?.subSelectionsByPeriod[activePeriod]
  if (sels && sels.length === 3) {
    const s = sels[idx]
    return { kind: s.customID ? '' : s.kind, customID: s.customID ?? '' }
  }
  return { kind: SLOT_DEFAULTS[SLOT_KEYS[idx]] ?? '', customID: '' }
}

function slotCurrentLabel(idx: number): string {
  const sel = slotSelection(idx)
  if (sel.customID) {
    const c = snap?.catalog.periods.flatMap((p) => p.customs).find((x) => x.id === sel.customID)
    return `自定义「${c?.name ?? sel.customID.slice(0, 8)}」`
  }
  return sel.kind || '未选择'
}

function chipValue(api: FcApi, field: string, value: string | string[]): void {
  const cur = api.getValue(field) as { value?: string | string[]; sections?: unknown[]; multiple?: boolean } | undefined
  api.setValue({ [field]: { ...(cur ?? {}), value } })
}

function chipSections(api: FcApi, field: string, sections: unknown, multiple?: boolean): void {
  const cur = api.getValue(field) as Record<string, unknown> | undefined
  api.setValue({ [field]: { ...(cur ?? {}), sections, ...(multiple === undefined ? {} : { multiple }) } })
}

/** 由 draft 状态刷新全部派生视图（tab/名称/主图/自定义/三槽位） */
function refresh(api: FcApi): void {
  const p = activePreset()
  const cat = activeCatalog()
  // tab + 名称
  chipSections(api, 'presetTabs', [{
    title: '',
    options: draft.map((x) => ({ label: x.name, value: x.id, mark: snap?.mode === x.id })),
  }])
  chipValue(api, 'presetTabs', activePresetID)
  api.setValue({ presetName: p?.name ?? '' })
  api.updateRule('nameField', { props: { 'aria-label': `presetEditor.name.${activePresetID}` } })
  // 周期 tab
  chipSections(api, 'periodTabs', [{
    title: '',
    options: (cat?.period ? [cat] : (snap?.catalog.periods ?? [])).map((c) => ({ label: c.period, value: c.period })),
  }])
  chipValue(api, 'periodTabs', activePeriod)
  // 主图多选
  chipSections(api, 'mainMulti', [{
    title: '',
    options: (cat?.mainDefs ?? []).map((d) => ({ label: d.name, value: d.id, ariaLabel: `presetEditor.main.${d.id}` })),
  }])
  chipValue(api, 'mainMulti', mainSet())
  // 主图自定义单选
  const customs = cat?.customs ?? []
  chipSections(api, 'mainCustom', [{
    title: '',
    options: [
      { label: '无', value: '', ariaLabel: 'presetEditor.mainCustom.none' },
      ...customs.filter((c) => c.scope === 'main').map((c) => ({
        label: c.name, value: c.id, dot: c.colorHex, ariaLabel: `presetEditor.mainCustom.${c.name}`,
      })),
    ],
  }])
  chipValue(api, 'mainCustom', activeCustomID())
  // 三副图槽位
  const subCustoms = customs.filter((c) => c.scope === 'sub')
  SLOT_KEYS.forEach((_, idx) => {
    const sel = slotSelection(idx)
    api.updateRule(`slot${idx}Current`, { props: { title: `当前：${slotCurrentLabel(idx)}` } })
    chipSections(api, `slot${idx}`, [
      ...(cat?.subGroups ?? []).map((g) => ({
        title: g.group,
        options: (g.kinds ?? []).map((k) => ({ label: k, value: k, ariaLabel: `presetEditor.sub.${idx}.${k}` })),
      })),
      ...(subCustoms.length > 0 ? [{
        title: '自定义',
        options: subCustoms.map((c) => ({
          label: c.name, value: c.id, dot: c.colorHex, ariaLabel: `presetEditor.sub.${idx}.custom.${c.name}`,
        })),
      }] : []),
    ])
    chipValue(api, `slot${idx}`, sel.customID || sel.kind)
    setRowHidden(api, `slot${idx}Opts`, expandedSlot !== idx)
  })
}

function writeMain(id: string): void {
  const p = activePreset()
  if (!p) return
  if (!p.mainIndicatorsByPeriod[activePeriod]) {
    p.mainIndicatorsByPeriod[activePeriod] = [...mainSet()].sort()
  }
  const arr = p.mainIndicatorsByPeriod[activePeriod]
  const idx = arr.indexOf(id)
  if (idx >= 0) arr.splice(idx, 1)
  else arr.push(id)
  p.mainIndicatorsByPeriod[activePeriod] = [...arr].sort()
}

function writeCustom(id: string): void {
  const p = activePreset()
  if (!p) return
  if (id === '') delete p.activeCustomByPeriod[activePeriod]
  else p.activeCustomByPeriod[activePeriod] = id
}

function writeSub(idx: number, sel: { kind: string; customID: string }): void {
  const p = activePreset()
  if (!p) return
  const sels = p.subSelectionsByPeriod[activePeriod]
    ?? [{ kind: 'CDJ', customID: '' }, { kind: 'COL', customID: '' }, { kind: 'MACD', customID: '' }]
  sels[idx] = sel
  p.subSelectionsByPeriod[activePeriod] = sels
}

function hasChanges(): boolean {
  if (!snap) return false
  return JSON.stringify(draft) !== JSON.stringify(snap.presets)
}

async function pull(api: FcApi, ctx: HostContext): Promise<void> {
  ctxRef = ctx
  try {
    snap = ((await klineBus.request('preset', 'snapshot')) ?? {}) as typeof snap
    draft = JSON.parse(JSON.stringify(snap?.presets ?? [])) as PresetSnap[]
    // 生效中的组合优先为首个编辑目标
    if (snap?.mode !== 'local' && draft.some((p) => p.id === snap?.mode)) {
      activePresetID = snap.mode
    } else {
      activePresetID = draft[0]?.id ?? 'p1'
    }
    activePeriod = '日线'
    expandedSlot = -1
  } catch (e) {
    console.error('preset.snapshot 失败', e)
    return
  }
  refresh(api)
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    selectPreset: (inj) => {
      const v = inj.args[0] as string
      activePresetID = v
      expandedSlot = -1
      refresh(inj.api)
    },

    selectPeriod: (inj) => {
      const v = inj.args[0] as string
      activePeriod = v
      expandedSlot = -1
      refresh(inj.api)
    },

    toggleMain: (inj) => {
      const v = inj.args[0] as string
      writeMain(v)
      chipValue(inj.api, 'mainMulti', mainSet())
    },

    selectMainCustom: (inj) => {
      const v = inj.args[0] as string
      writeCustom(v)
      chipValue(inj.api, 'mainCustom', activeCustomID())
    },

    toggleSlot0: (inj) => { expandedSlot = expandedSlot === 0 ? -1 : 0; refresh(inj.api) },
    toggleSlot1: (inj) => { expandedSlot = expandedSlot === 1 ? -1 : 1; refresh(inj.api) },
    toggleSlot2: (inj) => { expandedSlot = expandedSlot === 2 ? -1 : 2; refresh(inj.api) },

    selectSub0: (inj) => { selectSub(inj, 0) },
    selectSub1: (inj) => { selectSub(inj, 1) },
    selectSub2: (inj) => { selectSub(inj, 2) },

    onBack: (inj) => {
      if (hasChanges()) inj.api.setValue({ confirmOpen: true })
      else ctxRef?.close()
    },

    reallyClose: (_inj, ctx) => {
      ctx.close()
    },

    save: (inj) => {
      if (!snap || !inj.api) return
      inj.api.updateRule('peNav', { props: { rightText: '保存中…' } })
      void klineBus.request('preset', 'editCommit', { presets: draft }).then(() => {
        // 成功后本弹层关闭（对齐原生编辑链路；设置面板重开即见最新名称）
        ctxRef?.close()
      }).catch((e) => {
        console.error('preset.editCommit 失败', e)
        inj.api.updateRule('peNav', { props: { rightText: '保存' } })
      })
    },
  },

  onChange: (field, value, api) => {
    if (field === 'presetName') {
      const p = activePreset()
      if (p) p.name = String(value ?? '')
    }
  },
}

function selectSub(inj: FcInject, idx: number): void {
  const v = inj.args[0] as string
  // 自定义 id 以 c 开头（UUID）；系统指标 kind 直接匹配目录 kinds
  const isCustom = !(activeCatalog()?.subGroups ?? []).some((g) => (g.kinds ?? []).includes(v))
  writeSub(idx, isCustom ? { kind: '', customID: v } : { kind: v, customID: '' })
  refresh(inj.api)
}

export default adapter
